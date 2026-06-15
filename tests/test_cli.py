from __future__ import annotations

import subprocess
import tempfile
import json
import shutil
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out" / "bin" / "dxt"


@pytest.fixture(scope="session", autouse=True)
def build_dxt():
    with tempfile.TemporaryDirectory(prefix="dxt-zig-cache-") as cache_root:
        subprocess.run(
            [
                "zig",
                "build",
                "--cache-dir",
                str(Path(cache_root) / "local"),
                "--global-cache-dir",
                str(Path(cache_root) / "global"),
            ],
            cwd=ROOT,
            check=True,
        )
        subprocess.run(
            [
                "zig",
                "build",
                "test",
                "--cache-dir",
                str(Path(cache_root) / "local"),
                "--global-cache-dir",
                str(Path(cache_root) / "global"),
            ],
            cwd=ROOT,
            check=True,
        )
    assert DXT.exists()


def test_version_command():
    result = subprocess.run([DXT, "version"], cwd=ROOT, check=True, text=True, capture_output=True)
    assert result.stdout.strip() == "0.0.0"
    assert result.stderr == ""


def copy_fixture(tmp_path: Path, name: str) -> Path:
    source = ROOT / "tests" / "fixtures" / name
    dest = tmp_path / name
    shutil.copytree(source, dest)
    return dest


def test_compile_placeholder_still_returns_nonzero():
    result = subprocess.run(
        [DXT, "compile", "--project-dir", "fixture", "--select", "tag:nightly"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "planned but not implemented" in result.stdout
    assert "PLAN.md" in result.stdout
    assert result.stderr == ""


def test_parse_writes_minimal_manifest(tmp_path: Path):
    project = copy_fixture(tmp_path, "single_model")
    target = tmp_path / "manifest-target"
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    manifest_path = target / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    assert_partial_manifest_schema(manifest)
    assert sorted(manifest["nodes"]) == ["model.single_model.customers"]
    node = manifest["nodes"]["model.single_model.customers"]
    assert node["name"] == "customers"
    assert node["path"] == "customers.sql"
    assert node["original_file_path"] == "models/customers.sql"
    assert 'quoted "value" with backslash \\ marker' in node["raw_code"]
    assert manifest["parent_map"]["model.single_model.customers"] == []
    assert str(project) not in manifest_path.read_text()


def assert_partial_manifest_schema(manifest: dict) -> None:
    assert set(manifest) >= {
        "metadata",
        "dxt_metadata",
        "nodes",
        "sources",
        "macros",
        "docs",
        "exposures",
        "metrics",
        "groups",
        "selectors",
        "disabled",
        "parent_map",
        "child_map",
    }
    assert manifest["metadata"]["dbt_schema_version"] is None
    assert manifest["metadata"]["generated_by"] == "dxt"
    assert manifest["dxt_metadata"]["artifact_kind"] == "partial_manifest"
    assert manifest["dxt_metadata"]["compatibility_target"] == "dbt-manifest-v12-slice"
    for unique_id, node in manifest["nodes"].items():
        assert unique_id == node["unique_id"]
        assert node["resource_type"] == "model"
        assert set(node) >= {
            "unique_id",
            "resource_type",
            "package_name",
            "name",
            "path",
            "original_file_path",
            "language",
            "raw_code",
            "config",
            "depends_on",
        }
        assert not Path(node["original_file_path"]).is_absolute()
        assert set(node["depends_on"]) == {"macros", "nodes"}
    for unique_id, source in manifest["sources"].items():
        assert unique_id == source["unique_id"]
        assert source["resource_type"] == "source"
        assert not Path(source["original_file_path"]).is_absolute()


def test_parse_ref_dependency_maps_are_deterministic(tmp_path: Path):
    project = copy_fixture(tmp_path, "model_ref")
    command = [DXT, "parse", "--project-dir", str(project), "--target-path", "target-dxt"]
    first = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    assert first.returncode == 0, first.stderr
    manifest_path = project / "target-dxt" / "manifest.json"
    first_manifest = manifest_path.read_text()
    second = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    assert second.returncode == 0, second.stderr
    assert manifest_path.read_text() == first_manifest

    manifest = json.loads(first_manifest)
    customer = manifest["nodes"]["model.model_ref.customers"]
    assert customer["depends_on"]["nodes"] == ["model.model_ref.stg_customers"]
    assert manifest["parent_map"]["model.model_ref.customers"] == ["model.model_ref.stg_customers"]
    assert manifest["child_map"]["model.model_ref.stg_customers"] == ["model.model_ref.customers"]


def test_parse_source_dependency(tmp_path: Path):
    project = copy_fixture(tmp_path, "source_ref")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", "target-dxt"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    manifest = json.loads((project / "target-dxt" / "manifest.json").read_text())
    assert sorted(manifest["sources"]) == ["source.source_ref.raw.customers", "source.source_ref.raw.orders"]
    assert "source.source_ref.raw.customer_id" not in manifest["sources"]
    node = manifest["nodes"]["model.source_ref.stg_customers"]
    assert node["depends_on"]["nodes"] == ["source.source_ref.raw.customers"]


def test_ls_text_json_and_tag_selection(tmp_path: Path):
    project = copy_fixture(tmp_path, "inline_config")
    text_result = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "tag:nightly"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert text_result.returncode == 0, text_result.stderr
    assert text_result.stdout.splitlines() == ["model.inline_config.orders"]
    assert not (project / "target").exists()

    json_result = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--output", "json", "--resource-type", "model"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert json_result.returncode == 0, json_result.stderr
    assert json.loads(json_result.stdout) == [
        {"unique_id": "model.inline_config.orders", "resource_type": "model", "name": "orders"}
    ]

    excluded = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "orders", "--exclude", "orders"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert excluded.returncode == 0, excluded.stderr
    assert excluded.stdout == ""


def test_ls_rejects_unsupported_resource_type_and_selector(tmp_path: Path):
    project = copy_fixture(tmp_path, "single_model")
    unsupported_type = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--resource-type", "seed"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert unsupported_type.returncode == 2
    assert "--resource-type supports only model or source" in unsupported_type.stderr

    unsupported_selector = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "config.materialized:view"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert unsupported_selector.returncode == 2
    assert "selector syntax is not supported" in unsupported_selector.stderr


def test_dynamic_ref_fails_loudly(tmp_path: Path):
    project = copy_fixture(tmp_path, "unsupported_dynamic_ref")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "unsupported dynamic ref" in result.stderr


def test_unsupported_macro_call_fails_loudly(tmp_path: Path):
    project = copy_fixture(tmp_path, "unsupported_macro_call")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "unsupported or malformed Jinja" in result.stderr


def test_implemented_parse_rejects_ignored_dbt_flags(tmp_path: Path):
    project = copy_fixture(tmp_path, "single_model")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--vars", "{}"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "not supported" in result.stderr


def test_duplicate_model_name_fails(tmp_path: Path):
    project = copy_fixture(tmp_path, "duplicate_model_name")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "duplicate model name" in result.stderr


def test_missing_project_file_fails(tmp_path: Path):
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(tmp_path)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "missing dbt_project.yml" in result.stderr


def test_docs_generate_placeholder():
    result = subprocess.run(
        [DXT, "docs", "generate", "--target-path", "target-dxt"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "dxt docs generate" in result.stdout


def test_unknown_option_is_rejected():
    result = subprocess.run([DXT, "parse", "--unknown"], cwd=ROOT, text=True, capture_output=True)
    assert result.returncode == 2
    assert "unsupported option" in result.stderr


def test_subcommand_help_exits_successfully():
    result = subprocess.run([DXT, "parse", "--help"], cwd=ROOT, text=True, capture_output=True)
    assert result.returncode == 0
    assert "Usage: dxt parse" in result.stdout
    assert result.stderr == ""

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


def test_root_help_uses_canonical_name():
    result = subprocess.run([DXT, "--help"], cwd=ROOT, check=True, text=True, capture_output=True)
    assert "Data Transformation eXecutor" in result.stdout
    assert "Data eXecution & Transformation" not in result.stdout
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
    assert "dxt_metadata" not in manifest
    assert manifest["metadata"]["dbt_schema_version"] is None
    assert manifest["metadata"]["generated_by"] == "dxt"
    for unique_id, node in manifest["nodes"].items():
        assert unique_id == node["unique_id"]
        assert node["resource_type"] in {"model", "seed", "test"}
        common_keys = {
            "unique_id",
            "resource_type",
            "package_name",
            "name",
            "path",
            "original_file_path",
            "config",
            "depends_on",
        }
        assert set(node) >= common_keys
        if node["resource_type"] == "model":
            assert set(node) >= {
                "patch_path",
                "language",
                "raw_code",
                "description",
                "doc_blocks",
                "columns",
            }
            if node["patch_path"] is not None:
                assert not Path(node["patch_path"]).is_absolute()
        assert not Path(node["original_file_path"]).is_absolute()
        assert set(node["depends_on"]) == {"macros", "nodes"}
    for unique_id, source in manifest["sources"].items():
        assert unique_id == source["unique_id"]
        assert source["resource_type"] == "source"
        assert not Path(source["original_file_path"]).is_absolute()
    for unique_id, exposure in manifest["exposures"].items():
        assert unique_id == exposure["unique_id"]
        assert exposure["resource_type"] == "exposure"
        assert set(exposure) >= {
            "unique_id",
            "resource_type",
            "package_name",
            "name",
            "type",
            "owner",
            "depends_on",
            "refs",
            "sources",
            "path",
            "original_file_path",
        }
        assert set(exposure["depends_on"]) == {"macros", "nodes"}
        assert not Path(exposure["original_file_path"]).is_absolute()
    for unique_id, doc in manifest["docs"].items():
        assert unique_id == doc["unique_id"]
        assert doc["resource_type"] == "doc"
        assert set(doc) == {
            "unique_id",
            "resource_type",
            "package_name",
            "name",
            "path",
            "original_file_path",
            "block_contents",
        }
        assert not Path(doc["original_file_path"]).is_absolute()


def test_parse_model_properties_and_columns(tmp_path: Path):
    project = copy_fixture(tmp_path, "model_properties")
    command = [DXT, "parse", "--project-dir", str(project), "--target-path", "target-dxt"]
    first = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    assert first.returncode == 0, first.stderr
    manifest_path = project / "target-dxt" / "manifest.json"
    first_manifest = manifest_path.read_text()
    second = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    assert second.returncode == 0, second.stderr
    assert manifest_path.read_text() == first_manifest

    manifest = json.loads(first_manifest)
    expected_tests = [
        "test.model_properties.not_null_customers_customer_id.5c9bf9911d",
        "test.model_properties.unique_customers_.ccc5343706",
        "test.model_properties.unique_customers_customer_id.c5af1ff4b1",
    ]
    assert sorted(manifest["nodes"]) == ["model.model_properties.customers", *expected_tests]
    node = manifest["nodes"]["model.model_properties.customers"]
    assert node["description"] == "Customer dimension"
    assert node["patch_path"] == "model_properties://models/schema.yml"
    assert node["config"]["enabled"] is True
    assert node["config"]["materialized"] == "table"
    assert node["config"]["tags"] == ["nightly", "published"]
    assert "tests" not in node
    assert sorted(node["columns"]) == ["customer_id", "customer_name"]
    assert node["columns"]["customer_id"]["description"] == "Stable customer identifier"
    assert "tests" not in node["columns"]["customer_id"]
    assert node["columns"]["customer_name"]["description"] == "Display name"

    model_test = manifest["nodes"]["test.model_properties.unique_customers_.ccc5343706"]
    assert model_test["resource_type"] == "test"
    assert model_test["name"] == "unique_customers_"
    assert model_test["path"] == "unique_customers_.sql"
    assert model_test["original_file_path"] == "models/schema.yml"
    assert model_test["raw_code"] == "{{ test_unique(**_dbt_generic_test_kwargs) }}"
    assert model_test["attached_node"] == "model.model_properties.customers"
    assert model_test["column_name"] is None
    assert model_test["depends_on"]["macros"] == ["macro.dbt.test_unique"]
    assert model_test["depends_on"]["nodes"] == ["model.model_properties.customers"]
    assert model_test["test_metadata"] == {
        "name": "unique",
        "kwargs": {"model": "{{ get_where_subquery(ref('customers')) }}"},
        "namespace": None,
    }
    assert model_test["config"]["materialized"] == "test"
    assert model_test["config"]["schema"] == "dbt_test__audit"

    column_test = manifest["nodes"]["test.model_properties.not_null_customers_customer_id.5c9bf9911d"]
    assert column_test["resource_type"] == "test"
    assert column_test["name"] == "not_null_customers_customer_id"
    assert column_test["path"] == "not_null_customers_customer_id.sql"
    assert column_test["original_file_path"] == "models/schema.yml"
    assert column_test["raw_code"] == "{{ test_not_null(**_dbt_generic_test_kwargs) }}"
    assert column_test["attached_node"] == "model.model_properties.customers"
    assert column_test["column_name"] == "customer_id"
    assert column_test["depends_on"]["macros"] == ["macro.dbt.test_not_null"]
    assert column_test["depends_on"]["nodes"] == ["model.model_properties.customers"]
    assert column_test["test_metadata"] == {
        "name": "not_null",
        "kwargs": {
            "model": "{{ get_where_subquery(ref('customers')) }}",
            "column_name": "customer_id",
        },
        "namespace": None,
    }
    assert manifest["parent_map"][column_test["unique_id"]] == ["model.model_properties.customers"]
    assert manifest["child_map"]["model.model_properties.customers"] == expected_tests
    assert manifest["child_map"][column_test["unique_id"]] == []

    ls_result = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "tag:published"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_result.returncode == 0, ls_result.stderr
    assert ls_result.stdout.splitlines() == ["model.model_properties.customers"]

    ls_tests = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--resource-type", "test", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_tests.returncode == 0, ls_tests.stderr
    assert json.loads(ls_tests.stdout) == [
        {
            "unique_id": "test.model_properties.not_null_customers_customer_id.5c9bf9911d",
            "resource_type": "test",
            "name": "not_null_customers_customer_id",
        },
        {
            "unique_id": "test.model_properties.unique_customers_.ccc5343706",
            "resource_type": "test",
            "name": "unique_customers_",
        },
        {
            "unique_id": "test.model_properties.unique_customers_customer_id.c5af1ff4b1",
            "resource_type": "test",
            "name": "unique_customers_customer_id",
        },
    ]

def test_parse_generic_test_arguments(tmp_path: Path):
    project = copy_fixture(tmp_path, "generic_test_arguments")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", "target-dxt"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr

    manifest = json.loads((project / "target-dxt" / "manifest.json").read_text())
    accepted_id = "test.generic_test_arguments.accepted_values_orders_status__placed__shipped__completed__return_pending__returned.be6b5b5ec3"
    accepted_block_id = "test.generic_test_arguments.accepted_values_orders_status_block__placed__shipped.62277f9bb9"
    relationships_id = "test.generic_test_arguments.relationships_orders_customer_id__customer_id__ref_customers_.c6ec7f58f2"
    unique_id = "test.generic_test_arguments.unique_customers_customer_id.c5af1ff4b1"
    assert sorted(manifest["nodes"]) == [
        "model.generic_test_arguments.customers",
        "model.generic_test_arguments.orders",
        accepted_id,
        accepted_block_id,
        relationships_id,
        unique_id,
    ]

    accepted = manifest["nodes"][accepted_id]
    assert accepted["name"] == "accepted_values_orders_status__placed__shipped__completed__return_pending__returned"
    assert accepted["alias"] == "accepted_values_orders_1ce6ab157c285f7cd2ac656013faf758"
    assert accepted["path"] == "accepted_values_orders_1ce6ab157c285f7cd2ac656013faf758.sql"
    assert accepted["raw_code"] == '{{ test_accepted_values(**_dbt_generic_test_kwargs) }}{{ config(alias="accepted_values_orders_1ce6ab157c285f7cd2ac656013faf758") }}'
    assert accepted["column_name"] == "status"
    assert accepted["depends_on"]["macros"] == [
        "macro.dbt.test_accepted_values",
        "macro.dbt.get_where_subquery",
    ]
    assert accepted["depends_on"]["nodes"] == ["model.generic_test_arguments.orders"]
    assert accepted["test_metadata"] == {
        "name": "accepted_values",
        "kwargs": {
            "model": "{{ get_where_subquery(ref('orders')) }}",
            "column_name": "status",
            "values": ["placed", "shipped", "completed", "return_pending", "returned"],
        },
        "namespace": None,
    }

    accepted_block = manifest["nodes"][accepted_block_id]
    assert accepted_block["name"] == "accepted_values_orders_status_block__placed__shipped"
    assert accepted_block["alias"] == "accepted_values_orders_status_block__placed__shipped"
    assert accepted_block["path"] == "accepted_values_orders_status_block__placed__shipped.sql"
    assert accepted_block["column_name"] == "status_block"
    assert accepted_block["test_metadata"]["kwargs"]["values"] == ["placed", "shipped"]

    relationships = manifest["nodes"][relationships_id]
    assert relationships["name"] == "relationships_orders_customer_id__customer_id__ref_customers_"
    assert relationships["alias"] == "relationships_orders_customer_id__customer_id__ref_customers_"
    assert relationships["path"] == "relationships_orders_customer_id__customer_id__ref_customers_.sql"
    assert relationships["raw_code"] == "{{ test_relationships(**_dbt_generic_test_kwargs) }}"
    assert relationships["column_name"] == "customer_id"
    assert relationships["depends_on"]["macros"] == [
        "macro.dbt.test_relationships",
        "macro.dbt.get_where_subquery",
    ]
    assert relationships["depends_on"]["nodes"] == [
        "model.generic_test_arguments.customers",
        "model.generic_test_arguments.orders",
    ]
    assert relationships["test_metadata"] == {
        "name": "relationships",
        "kwargs": {
            "model": "{{ get_where_subquery(ref('orders')) }}",
            "column_name": "customer_id",
            "to": "ref('customers')",
            "field": "customer_id",
        },
        "namespace": None,
    }
    assert manifest["parent_map"][relationships_id] == [
        "model.generic_test_arguments.customers",
        "model.generic_test_arguments.orders",
    ]
    assert manifest["child_map"]["model.generic_test_arguments.customers"] == [
        relationships_id,
        unique_id,
    ]
    assert manifest["child_map"]["model.generic_test_arguments.orders"] == [
        accepted_id,
        accepted_block_id,
        relationships_id,
    ]


def test_parse_macro_artifacts_and_model_macro_dependency(tmp_path: Path):
    project = copy_fixture(tmp_path, "macro_artifacts")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", "target-dxt"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr

    manifest = json.loads((project / "target-dxt" / "manifest.json").read_text())
    assert sorted(manifest["nodes"]) == ["model.macro_artifacts.customers"]
    macro_id = "macro.macro_artifacts.format_id"
    dependent_macro_id = "macro.macro_artifacts.outer_id"
    nested_macro_id = "macro.macro_artifacts.wrap_optional"
    assert sorted(manifest["macros"]) == [macro_id, dependent_macro_id, nested_macro_id]
    assert manifest["macros"][macro_id] == {
        "unique_id": macro_id,
        "resource_type": "macro",
        "package_name": "macro_artifacts",
        "name": "format_id",
        "path": "macros/format_id.sql",
        "original_file_path": "macros/format_id.sql",
        "macro_sql": "{% macro format_id(column_name) %}\n    cast({{ column_name }} as varchar)\n{% endmacro %}",
        "depends_on": {"macros": []},
        "description": "",
        "meta": {},
        "docs": {"show": True, "node_color": None},
        "patch_path": None,
        "arguments": [],
        "supported_languages": None,
    }
    assert manifest["macros"][dependent_macro_id]["depends_on"]["macros"] == [macro_id]
    assert manifest["macros"][nested_macro_id]["macro_sql"] == (
        "{% macro wrap_optional(column_name, enabled=true) %}\n"
        "    {% if enabled %}\n"
        "        coalesce({{ column_name }}, 'unknown')\n"
        "    {% else %}\n"
        "        {{ column_name }}\n"
        "    {% endif %}\n"
        "{% endmacro %}"
    )
    node = manifest["nodes"]["model.macro_artifacts.customers"]
    assert node["depends_on"]["macros"] == [macro_id]
    assert manifest["parent_map"]["model.macro_artifacts.customers"] == []
    assert macro_id not in manifest["parent_map"]
    assert macro_id not in manifest["child_map"]

    ls_default = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_default.returncode == 0, ls_default.stderr
    assert json.loads(ls_default.stdout) == [
        {
            "unique_id": "model.macro_artifacts.customers",
            "resource_type": "model",
            "name": "customers",
        }
    ]


def test_parse_package_macro_namespaces(tmp_path: Path):
    project = copy_fixture(tmp_path, "package_macro_namespace")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", "target-dxt"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr

    manifest_path = project / "target-dxt" / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    root_macro_id = "macro.package_macro_namespace.format_id"
    root_external_macro_id = "macro.package_macro_namespace.wrap_external_id"
    package_macro_id = "macro.util_pkg.format_id"
    package_outer_macro_id = "macro.util_pkg.outer_id"
    assert sorted(manifest["macros"]) == [
        root_macro_id,
        root_external_macro_id,
        package_macro_id,
        package_outer_macro_id,
    ]
    assert manifest["macros"][package_macro_id]["package_name"] == "util_pkg"
    assert manifest["macros"][package_macro_id]["path"] == "custom_macros/format_id.sql"
    assert manifest["macros"][package_macro_id]["original_file_path"] == "custom_macros/format_id.sql"
    assert "dbt_packages" not in manifest["macros"][package_macro_id]["path"]
    assert "macro.util_pkg.ignored" not in manifest["macros"]
    assert manifest["nodes"]["model.package_macro_namespace.customers"]["depends_on"]["macros"] == [
        package_macro_id
    ]
    assert manifest["nodes"]["model.package_macro_namespace.local_customers"]["depends_on"]["macros"] == [
        root_macro_id
    ]
    assert manifest["macros"][root_external_macro_id]["depends_on"]["macros"] == [package_macro_id]
    assert manifest["macros"][package_outer_macro_id]["depends_on"]["macros"] == [package_macro_id]
    assert package_macro_id not in manifest["parent_map"]
    assert package_outer_macro_id not in manifest["child_map"]
    assert str(project) not in manifest_path.read_text()


def test_macro_paths_replace_default_macro_directory(tmp_path: Path):
    project = copy_fixture(tmp_path, "macro_paths_custom")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", "target-dxt"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr

    manifest = json.loads((project / "target-dxt" / "manifest.json").read_text())
    assert sorted(manifest["macros"]) == ["macro.macro_paths_custom.kept_macro"]
    macro = manifest["macros"]["macro.macro_paths_custom.kept_macro"]
    assert macro["path"] == "custom_macros/kept.sql"
    assert macro["original_file_path"] == "custom_macros/kept.sql"
    assert "macro.macro_paths_custom.ignored_macro" not in manifest["macros"]


def test_parse_macro_property_yaml(tmp_path: Path):
    project = copy_fixture(tmp_path, "macro_properties")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", "target-dxt"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr

    manifest = json.loads((project / "target-dxt" / "manifest.json").read_text())
    macro = manifest["macros"]["macro.macro_properties.format_id"]
    assert macro["description"] == "Format an identifier expression."
    assert macro["patch_path"] == "macro_properties://macros/schema.yml"
    assert macro["arguments"] == [
        {
            "name": "column_name",
            "type": "string",
            "description": "Column expression to cast.",
        },
        {
            "name": "optional_suffix",
            "type": None,
            "description": "Optional suffix value.",
        },
    ]


def test_duplicate_macro_property_fails_loudly(tmp_path: Path):
    project = copy_fixture(tmp_path, "duplicate_macro_property")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", "target-dxt"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "duplicate macro property patch" in result.stderr


def test_disabled_model_is_not_active_but_is_represented(tmp_path: Path):
    project = copy_fixture(tmp_path, "disabled_model")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", "target-dxt"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    manifest = json.loads((project / "target-dxt" / "manifest.json").read_text())
    assert sorted(manifest["nodes"]) == ["model.disabled_model.active"]
    disabled_id = "model.disabled_model.disabled_customers"
    assert disabled_id not in manifest["nodes"]
    assert disabled_id not in manifest["parent_map"]
    assert disabled_id not in manifest["child_map"]
    assert list(manifest["disabled"]) == [disabled_id]
    disabled_node = manifest["disabled"][disabled_id][0]
    assert disabled_node["config"]["enabled"] is False
    assert disabled_node["description"] == "Disabled model should stay out of active graph"

    ls_result = subprocess.run(
        [DXT, "ls", "--project-dir", str(project)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_result.returncode == 0, ls_result.stderr
    assert ls_result.stdout.splitlines() == ["model.disabled_model.active"]


def test_ref_to_disabled_model_fails_loudly(tmp_path: Path):
    project = copy_fixture(tmp_path, "disabled_ref")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "ref targets a disabled model" in result.stderr


def test_unmatched_model_property_warns_and_continues(tmp_path: Path):
    project = copy_fixture(tmp_path, "unmatched_model_property")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", "target-dxt"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0
    assert "did not find matching node for model property" in result.stderr
    manifest = json.loads((project / "target-dxt" / "manifest.json").read_text())
    assert sorted(manifest["nodes"]) == ["model.unmatched_model_property.customers"]


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
    assert node["description"] == "Staged raw customers"
    assert node["patch_path"] == "source_ref://models/schema.yml"
    assert node["config"]["tags"] == ["staging"]
    assert node["depends_on"]["nodes"] == ["source.source_ref.raw.customers"]


def test_parse_seed_ref_dependency_and_ls_seed(tmp_path: Path):
    project = copy_fixture(tmp_path, "seed_ref")
    command = [DXT, "parse", "--project-dir", str(project), "--target-path", "target-dxt"]
    first = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    assert first.returncode == 0, first.stderr
    manifest_path = project / "target-dxt" / "manifest.json"
    first_manifest = manifest_path.read_text()
    second = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    assert second.returncode == 0, second.stderr
    assert manifest_path.read_text() == first_manifest

    manifest = json.loads(first_manifest)
    assert_partial_manifest_schema(manifest)
    assert sorted(manifest["nodes"]) == [
        "model.seed_ref.stg_customers",
        "seed.seed_ref.raw_customers",
    ]
    seed = manifest["nodes"]["seed.seed_ref.raw_customers"]
    assert seed["resource_type"] == "seed"
    assert seed["path"] == "raw_customers.csv"
    assert seed["original_file_path"] == "seeds/raw_customers.csv"
    assert seed["config"]["enabled"] is True
    assert seed["config"]["materialized"] == "seed"
    model = manifest["nodes"]["model.seed_ref.stg_customers"]
    assert model["depends_on"]["nodes"] == ["seed.seed_ref.raw_customers"]
    assert manifest["parent_map"]["model.seed_ref.stg_customers"] == ["seed.seed_ref.raw_customers"]
    assert manifest["child_map"]["seed.seed_ref.raw_customers"] == ["model.seed_ref.stg_customers"]

    ls_result = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--resource-type", "seed", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_result.returncode == 0, ls_result.stderr
    assert json.loads(ls_result.stdout) == [
        {"unique_id": "seed.seed_ref.raw_customers", "resource_type": "seed", "name": "raw_customers"}
    ]


def test_parse_docs_blocks_and_literal_doc_descriptions(tmp_path: Path):
    project = copy_fixture(tmp_path, "docs_blocks")
    command = [DXT, "parse", "--project-dir", str(project), "--target-path", "target-dxt"]
    first = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    assert first.returncode == 0, first.stderr
    manifest_path = project / "target-dxt" / "manifest.json"
    first_manifest = manifest_path.read_text()
    second = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    assert second.returncode == 0, second.stderr
    assert manifest_path.read_text() == first_manifest

    manifest = json.loads(first_manifest)
    assert_partial_manifest_schema(manifest)
    assert sorted(manifest["docs"]) == [
        "doc.docs_blocks.customer_id",
        "doc.docs_blocks.customer_model",
    ]
    model_doc = manifest["docs"]["doc.docs_blocks.customer_model"]
    assert model_doc == {
        "unique_id": "doc.docs_blocks.customer_model",
        "resource_type": "doc",
        "package_name": "docs_blocks",
        "name": "customer_model",
        "path": "docs.md",
        "original_file_path": "models/docs.md",
        "block_contents": "Customer model docs.",
    }
    column_doc = manifest["docs"]["doc.docs_blocks.customer_id"]
    assert column_doc["block_contents"] == "Customer id docs."

    node = manifest["nodes"]["model.docs_blocks.customers"]
    assert node["description"] == "Customer model docs."
    assert node["doc_blocks"] == ["doc.docs_blocks.customer_model"]
    assert node["columns"]["customer_id"]["description"] == "Customer id docs."
    assert node["columns"]["customer_id"]["doc_blocks"] == ["doc.docs_blocks.customer_id"]
    assert all(not key.startswith("doc.") for key in manifest["parent_map"])
    assert all(not key.startswith("doc.") for key in manifest["child_map"])
    assert str(project) not in first_manifest


def test_parse_exposure_artifacts_and_graph_maps(tmp_path: Path):
    project = copy_fixture(tmp_path, "exposure_artifacts")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", "target-dxt"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr

    manifest = json.loads((project / "target-dxt" / "manifest.json").read_text())
    exposure_id = "exposure.exposure_artifacts.weekly_kpis"
    disabled_exposure_id = "exposure.exposure_artifacts.hidden_dashboard"
    model_id = "model.exposure_artifacts.orders"
    source_id = "source.exposure_artifacts.raw.customers"
    assert sorted(manifest["exposures"]) == [exposure_id]
    assert disabled_exposure_id not in manifest["parent_map"]
    assert disabled_exposure_id not in manifest["child_map"]
    exposure = manifest["exposures"][exposure_id]
    assert exposure["unique_id"] == exposure_id
    assert exposure["resource_type"] == "exposure"
    assert exposure["package_name"] == "exposure_artifacts"
    assert exposure["name"] == "weekly_kpis"
    assert exposure["path"] == "schema.yml"
    assert exposure["original_file_path"] == "models/schema.yml"
    assert exposure["fqn"] == ["exposure_artifacts", "weekly_kpis"]
    assert exposure["type"] == "dashboard"
    assert exposure["maturity"] == "high"
    assert exposure["url"] == "https://example.com/weekly"
    assert exposure["description"] == "Weekly KPI dashboard."
    assert exposure["depends_on"] == {"macros": [], "nodes": [source_id, model_id]}
    assert exposure["refs"] == [{"name": "orders", "package": None, "version": None}]
    assert exposure["sources"] == [["raw", "customers"]]
    assert exposure["owner"] == {
        "email": "analytics@example.com",
        "name": "Analytics Team",
    }
    assert exposure["tags"] == ["bi"]
    assert exposure["meta"] == {"audited": True, "priority": 7}
    assert exposure["config"] == {
        "enabled": True,
        "tags": ["bi"],
        "meta": {"audited": True, "priority": 7},
    }
    assert isinstance(exposure["created_at"], float)
    assert manifest["parent_map"][exposure_id] == [model_id, source_id]
    assert manifest["child_map"][model_id] == [exposure_id]
    assert manifest["child_map"][source_id] == [exposure_id]
    assert manifest["child_map"][exposure_id] == []
    assert str(project) not in (project / "target-dxt" / "manifest.json").read_text()

    ls_default = subprocess.run(
        [DXT, "ls", "--project-dir", str(project)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_default.returncode == 0, ls_default.stderr
    assert ls_default.stdout.splitlines() == [
        exposure_id,
        model_id,
        source_id,
    ]

    ls_exposure = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--resource-type", "exposure", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_exposure.returncode == 0, ls_exposure.stderr
    assert json.loads(ls_exposure.stdout) == [
        {"unique_id": exposure_id, "resource_type": "exposure", "name": "weekly_kpis"}
    ]

    ls_parents = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "+weekly_kpis"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_parents.returncode == 0, ls_parents.stderr
    assert ls_parents.stdout.splitlines() == [
        exposure_id,
        model_id,
        source_id,
    ]

    ls_children = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "orders+"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_children.returncode == 0, ls_children.stderr
    assert ls_children.stdout.splitlines() == [exposure_id, model_id]

    ls_tag = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "tag:bi"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_tag.returncode == 0, ls_tag.stderr
    assert ls_tag.stdout.splitlines() == [exposure_id]


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


def test_ls_config_materialized_and_comma_intersection(tmp_path: Path):
    project = copy_fixture(tmp_path, "inline_config")

    def ls_text(*args: str) -> list[str]:
        result = subprocess.run(
            [DXT, "ls", "--project-dir", str(project), *args],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        assert result.returncode == 0, result.stderr
        return result.stdout.splitlines()

    assert ls_text("--select", "config.materialized:table") == ["model.inline_config.orders"]
    assert ls_text("--select", "config.materialized:view") == []
    assert ls_text("--select", "tag:nightly,config.materialized:table") == [
        "model.inline_config.orders"
    ]
    assert ls_text("--select", "tag:nightly,config.materialized:view") == []
    assert ls_text("--select", "orders,config.materialized:table") == ["model.inline_config.orders"]
    assert ls_text("--select", "tag:nightly", "--exclude", "orders,config.materialized:table") == []

    default_project = copy_fixture(tmp_path, "single_model")
    default_result = subprocess.run(
        [DXT, "ls", "--project-dir", str(default_project), "--select", "config.materialized:view"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert default_result.returncode == 0, default_result.stderr
    assert default_result.stdout.splitlines() == ["model.single_model.customers"]


def test_ls_graph_plus_selectors(tmp_path: Path):
    project = copy_fixture(tmp_path, "selector_graph")

    def ls_json(*args: str) -> list[str]:
        result = subprocess.run(
            [DXT, "ls", "--project-dir", str(project), "--output", "json", *args],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        assert result.returncode == 0, result.stderr
        return [item["unique_id"] for item in json.loads(result.stdout)]

    assert ls_json("--select", "customers") == ["model.selector_graph.customers"]
    assert ls_json("--select", "+customers") == [
        "model.selector_graph.customers",
        "model.selector_graph.stg_customers",
    ]
    assert ls_json("--select", "customers+") == [
        "model.selector_graph.customers",
        "model.selector_graph.orders",
    ]
    assert ls_json("--select", "+customers+") == [
        "model.selector_graph.customers",
        "model.selector_graph.orders",
        "model.selector_graph.stg_customers",
    ]
    assert ls_json("--select", "+customers+", "--exclude", "customers+") == [
        "model.selector_graph.stg_customers"
    ]
    assert ls_json("--select", "+customers+", "--exclude", "customers") == [
        "model.selector_graph.orders",
        "model.selector_graph.stg_customers",
    ]
    assert ls_json("--select", "customers+,config.materialized:view") == [
        "model.selector_graph.customers"
    ]
    assert ls_json("--select", "customers+,config.materialized:table") == [
        "model.selector_graph.orders"
    ]
    assert ls_json("--select", "+orders,config.materialized:view") == [
        "model.selector_graph.customers",
        "model.selector_graph.stg_customers",
    ]


def test_ls_rejects_unsupported_resource_type_and_selector(tmp_path: Path):
    project = copy_fixture(tmp_path, "single_model")
    unsupported_type = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--resource-type", "snapshot"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert unsupported_type.returncode == 2
    assert "--resource-type supports only model, seed, source, exposure, or test" in unsupported_type.stderr

    for selector in [
        "state:modified",
        "config.schema:audit",
        "tag:nightly,",
        "config.materialized:",
        "tag:nightly, config.materialized:view",
        "++customers",
        "customers++",
        "++customers++",
    ]:
        unsupported_selector = subprocess.run(
            [DXT, "ls", "--project-dir", str(project), "--select", selector],
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


def test_dynamic_doc_fails_loudly(tmp_path: Path):
    project = copy_fixture(tmp_path, "unsupported_dynamic_doc")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "unsupported dynamic doc" in result.stderr


def test_missing_doc_reference_fails_loudly(tmp_path: Path):
    project = copy_fixture(tmp_path, "missing_doc_ref")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "unresolved doc reference" in result.stderr


def test_duplicate_doc_name_fails_loudly(tmp_path: Path):
    project = copy_fixture(tmp_path, "duplicate_doc_name")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "duplicate docs block name" in result.stderr


def test_malformed_docs_block_fails_loudly(tmp_path: Path):
    project = copy_fixture(tmp_path, "malformed_docs_block")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "malformed docs block" in result.stderr


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


def test_missing_package_macro_fails_loudly(tmp_path: Path):
    project = copy_fixture(tmp_path, "missing_package_macro")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "unresolved macro reference" in result.stderr


def test_missing_package_macro_in_macro_body_fails_loudly(tmp_path: Path):
    project = copy_fixture(tmp_path, "missing_package_macro_in_macro")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "unresolved macro reference" in result.stderr


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


def test_duplicate_seed_name_fails(tmp_path: Path):
    project = copy_fixture(tmp_path, "duplicate_seed_name")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "duplicate seed name" in result.stderr


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

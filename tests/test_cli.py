from __future__ import annotations

import subprocess
import tempfile
import json
import shutil
import importlib.util
import copy
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out" / "bin" / "dxt"
SCHEMA_VALIDATOR_PATH = ROOT / "scripts" / "validate_manifest_schema.py"
CATALOG_SCHEMA = ROOT / "tests" / "schemas" / "dbt_catalog_v1_docs_slice.schema.json"
SCHEMA_SPEC = importlib.util.spec_from_file_location("validate_manifest_schema", SCHEMA_VALIDATOR_PATH)
assert SCHEMA_SPEC is not None
assert SCHEMA_SPEC.loader is not None
schema_validator = importlib.util.module_from_spec(SCHEMA_SPEC)
SCHEMA_SPEC.loader.exec_module(schema_validator)


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
    assert "Data eXecution & Transformation" in result.stdout
    assert "Data Transformation eXecutor" not in result.stdout
    assert result.stderr == ""


def copy_fixture(tmp_path: Path, name: str) -> Path:
    source = ROOT / "tests" / "fixtures" / name
    dest = tmp_path / name
    shutil.copytree(source, dest)
    return dest


def test_compile_writes_compiled_sql_and_manifest_fields(tmp_path: Path):
    project = copy_fixture(tmp_path, "compile_basic")
    target = tmp_path / "compile-target"
    result = subprocess.run(
        [DXT, "compile", "--project-dir", str(project), "--target-path", str(target), "--threads", "4"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    assert "Compiled 3 model(s)" in result.stdout

    compiled_root = target / "compiled" / "compile_basic" / "models"
    assert (compiled_root / "customers.sql").read_text().strip() == "select 1 as customer_id"
    orders_sql = (compiled_root / "orders.sql").read_text()
    assert "config(" not in orders_sql
    assert 'from "main"."customers"' in orders_sql
    assert (compiled_root / "from_source.sql").read_text().strip() == 'select *\nfrom "raw"."payments"'

    manifest_path = target / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    assert_partial_manifest_schema(manifest)
    assert_manifest_schema_slice(manifest_path)
    orders = manifest["nodes"]["model.compile_basic.orders"]
    assert orders["compiled"] is True
    assert orders["compiled_code"] == orders_sql
    assert orders["compiled_path"].endswith("/compiled/compile_basic/models/orders.sql")
    assert orders["relation_name"] == '"main"."orders"'
    assert orders["extra_ctes"] == []
    assert orders["extra_ctes_injected"] is False


def test_compile_select_limits_compiled_models_but_keeps_graph_context(tmp_path: Path):
    project = copy_fixture(tmp_path, "compile_basic")
    target = tmp_path / "compile-target"
    result = subprocess.run(
        [DXT, "compile", "--project-dir", str(project), "--target-path", str(target), "--select", "orders"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Compiled 1 model(s)" in result.stdout

    compiled_root = target / "compiled" / "compile_basic" / "models"
    assert not (compiled_root / "customers.sql").exists()
    assert not (compiled_root / "from_source.sql").exists()
    assert 'from "main"."customers"' in (compiled_root / "orders.sql").read_text()

    manifest = json.loads((target / "manifest.json").read_text())
    assert manifest["nodes"]["model.compile_basic.orders"]["compiled"] is True
    assert "compiled" not in manifest["nodes"]["model.compile_basic.customers"]
    assert "compiled" not in manifest["nodes"]["model.compile_basic.from_source"]


def test_compile_rejects_selection_without_models(tmp_path: Path):
    project = copy_fixture(tmp_path, "compile_basic")
    result = subprocess.run(
        [DXT, "compile", "--project-dir", str(project), "--select", "source:raw.payments"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "compile currently supports only selected SQL model resources" in result.stderr


def test_compile_uses_selected_node_package_for_compiled_path(tmp_path: Path):
    project = copy_fixture(tmp_path, "package_ref_selector")
    target = tmp_path / "compile-target"
    result = subprocess.run(
        [
            DXT,
            "compile",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "package:util_pkg,pkg_customers",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert (target / "compiled" / "util_pkg" / "models" / "pkg_customers.sql").exists()
    assert not (target / "compiled" / "package_ref_selector" / "models" / "pkg_customers.sql").exists()
    manifest = json.loads((target / "manifest.json").read_text())
    package_node = manifest["nodes"]["model.util_pkg.pkg_customers"]
    assert package_node["compiled_path"].endswith("/compiled/util_pkg/models/pkg_customers.sql")
    assert "compiled" not in manifest["nodes"]["model.package_ref_selector.pkg_customers"]


def test_run_prepare_compiles_selected_model_but_does_not_execute(tmp_path: Path):
    project = copy_fixture(tmp_path, "compile_basic")
    target = tmp_path / "run-target"
    result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "orders", "--threads", "4"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "Prepared 1 model(s) for execution" in result.stdout
    assert "model execution requires a DuckDB adapter and materialization runner" in result.stderr
    assert not (target / "run_results.json").exists()

    compiled_root = target / "compiled" / "compile_basic" / "models"
    assert not (compiled_root / "customers.sql").exists()
    assert (compiled_root / "orders.sql").exists()
    assert not (compiled_root / "from_source.sql").exists()
    manifest = json.loads((target / "manifest.json").read_text())
    assert manifest["nodes"]["model.compile_basic.orders"]["compiled"] is True
    assert "compiled" not in manifest["nodes"]["model.compile_basic.customers"]


def test_run_prepare_rejects_non_model_selection(tmp_path: Path):
    project = copy_fixture(tmp_path, "compile_basic")
    target = tmp_path / "run-target"
    result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "source:raw.payments"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "run currently supports only selected SQL model resources before execution" in result.stderr
    assert not (target / "run_results.json").exists()


def test_build_prepare_compiles_model_then_stops_before_execution(tmp_path: Path):
    project = copy_fixture(tmp_path, "compile_basic")
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "orders"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "Prepared 1 selected resource(s), including 1 compiled model(s)" in result.stdout
    assert "model execution requires a DuckDB adapter and materialization runner" in result.stderr
    assert not (target / "run_results.json").exists()
    assert (target / "compiled" / "compile_basic" / "models" / "orders.sql").exists()
    manifest = json.loads((target / "manifest.json").read_text())
    assert manifest["nodes"]["model.compile_basic.orders"]["compiled"] is True


def test_build_prepare_reports_seed_execution_boundary(tmp_path: Path):
    project = copy_fixture(tmp_path, "seed_ref")
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "raw_customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "Prepared 1 selected resource(s), including 0 compiled model(s)" in result.stdout
    assert "seed execution requires a DuckDB adapter and seed runner" in result.stderr
    assert not (target / "run_results.json").exists()
    manifest = json.loads((target / "manifest.json").read_text())
    assert sorted(manifest["nodes"]) == [
        "model.seed_ref.stg_customers",
        "seed.seed_ref.raw_customers",
    ]


def test_build_prepare_reports_test_execution_boundary(tmp_path: Path):
    project = copy_fixture(tmp_path, "generic_test_arguments")
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "test_type:generic"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "Prepared " in result.stdout
    assert "including 0 compiled model(s)" in result.stdout
    assert "test execution requires a DuckDB adapter and test runner" in result.stderr
    assert not (target / "run_results.json").exists()
    manifest = json.loads((target / "manifest.json").read_text())
    assert "compiled" not in manifest["nodes"]["model.generic_test_arguments.customers"]
    assert sorted(manifest["child_map"]["model.generic_test_arguments.customers"])


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
    assert_manifest_schema_slice(manifest_path)
    assert sorted(manifest["nodes"]) == ["model.single_model.customers"]
    node = manifest["nodes"]["model.single_model.customers"]
    assert node["name"] == "customers"
    assert node["path"] == "customers.sql"
    assert node["original_file_path"] == "models/customers.sql"
    assert 'quoted "value" with backslash \\ marker' in node["raw_code"]
    assert node["docs"] == {"show": True, "node_color": None}
    assert node["config"]["docs"] == {"show": True, "node_color": None}
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
        "group_map",
        "saved_queries",
        "semantic_models",
        "unit_tests",
        "disabled",
        "parent_map",
        "child_map",
    }
    assert "dxt_metadata" not in manifest
    assert isinstance(manifest["metadata"].get("project_name"), str)
    assert "generated_by" not in manifest["metadata"]
    assert manifest["group_map"] == {}
    assert manifest["saved_queries"] == {}
    assert manifest["semantic_models"] == {}
    assert manifest["unit_tests"] == {}
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


def assert_manifest_schema_slice(manifest_path: Path) -> None:
    manifest = json.loads(manifest_path.read_text())
    schema = schema_validator.load_json(schema_validator.DEFAULT_SCHEMA)
    errors = schema_validator.validate_manifest(manifest, schema)
    assert errors == []


def assert_catalog_schema_slice(catalog_path: Path) -> None:
    catalog = json.loads(catalog_path.read_text())
    schema = schema_validator.load_json(CATALOG_SCHEMA)
    errors = schema_validator.validate_manifest(catalog, schema)
    assert errors == []


def test_manifest_schema_validator_rejects_missing_required_key(tmp_path: Path):
    manifest_path = tmp_path / "manifest.json"
    manifest_path.write_text(json.dumps({"metadata": {}}), encoding="utf-8")

    result = subprocess.run(
        ["python", "scripts/validate_manifest_schema.py", str(manifest_path)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 1
    assert "missing required property 'nodes'" in result.stderr


def test_manifest_schema_validator_rejects_unexpected_resource_field(tmp_path: Path):
    project = copy_fixture(tmp_path, "single_model")
    target = tmp_path / "manifest-target"
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr

    manifest = json.loads((target / "manifest.json").read_text())
    invalid = copy.deepcopy(manifest)
    invalid["nodes"]["model.single_model.customers"]["dxt_private_field"] = True

    schema = schema_validator.load_json(schema_validator.DEFAULT_SCHEMA)
    errors = schema_validator.validate_manifest(invalid, schema)
    assert any("unexpected property 'dxt_private_field'" in error for error in errors)


def test_manifest_schema_validator_rejects_missing_model_field(tmp_path: Path):
    project = copy_fixture(tmp_path, "single_model")
    target = tmp_path / "manifest-target"
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr

    manifest = json.loads((target / "manifest.json").read_text())
    invalid = copy.deepcopy(manifest)
    del invalid["nodes"]["model.single_model.customers"]["raw_code"]

    schema = schema_validator.load_json(schema_validator.DEFAULT_SCHEMA)
    errors = schema_validator.validate_manifest(invalid, schema)
    assert any("missing required property 'raw_code'" in error for error in errors)


def test_manifest_schema_validator_rejects_missing_generic_test_field(tmp_path: Path):
    project = copy_fixture(tmp_path, "model_properties")
    target = tmp_path / "manifest-target"
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr

    manifest = json.loads((target / "manifest.json").read_text())
    invalid = copy.deepcopy(manifest)
    del invalid["nodes"]["test.model_properties.unique_customers_.ccc5343706"]["test_metadata"]

    schema = schema_validator.load_json(schema_validator.DEFAULT_SCHEMA)
    errors = schema_validator.validate_manifest(invalid, schema)
    assert any("missing required property 'test_metadata'" in error for error in errors)


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
    assert_manifest_schema_slice(manifest_path)
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

    ls_schema_path = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "path:models/*.yml", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_schema_path.returncode == 0, ls_schema_path.stderr
    assert [item["unique_id"] for item in json.loads(ls_schema_path.stdout)] == [
        "model.model_properties.customers",
        *expected_tests,
    ]

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
    assert model_test["refs"] == [{"name": "customers", "package": None, "version": None}]
    assert model_test["sources"] == []
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
    assert column_test["refs"] == [{"name": "customers", "package": None, "version": None}]
    assert column_test["sources"] == []
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
    assert ls_result.stdout.splitlines() == ["model.model_properties.customers", *expected_tests]
    tag_wildcard = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "tag:pub*", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert tag_wildcard.returncode == 0, tag_wildcard.stderr
    assert [item["unique_id"] for item in json.loads(tag_wildcard.stdout)] == [
        "model.model_properties.customers",
        *expected_tests,
    ]

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

    ls_resource_type_tests = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "resource_type:test", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_resource_type_tests.returncode == 0, ls_resource_type_tests.stderr
    assert json.loads(ls_resource_type_tests.stdout) == json.loads(ls_tests.stdout)

    ls_package_tests = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "package:model_properties,resource_type:test", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_package_tests.returncode == 0, ls_package_tests.stderr
    assert json.loads(ls_package_tests.stdout) == json.loads(ls_tests.stdout)

    ls_package_all = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "package:model_properties", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_package_all.returncode == 0, ls_package_all.stderr
    assert [item["unique_id"] for item in json.loads(ls_package_all.stdout)] == [
        "model.model_properties.customers",
        *expected_tests,
    ]

    ls_generic_tests = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "test_type:generic", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_generic_tests.returncode == 0, ls_generic_tests.stderr
    assert json.loads(ls_generic_tests.stdout) == json.loads(ls_tests.stdout)

    ls_model_and_tests = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "customers test_type:generic", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_model_and_tests.returncode == 0, ls_model_and_tests.stderr
    assert [item["unique_id"] for item in json.loads(ls_model_and_tests.stdout)] == [
        "model.model_properties.customers",
        "test.model_properties.not_null_customers_customer_id.5c9bf9911d",
        "test.model_properties.unique_customers_.ccc5343706",
        "test.model_properties.unique_customers_customer_id.c5af1ff4b1",
    ]
    for model_selector in ("customers", "customers*", "model_properties.customers", "model_properties.customers*"):
        ls_indirect_tests = subprocess.run(
            [DXT, "ls", "--project-dir", str(project), "--select", model_selector, "--output", "json"],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        assert ls_indirect_tests.returncode == 0, ls_indirect_tests.stderr
        assert [item["unique_id"] for item in json.loads(ls_indirect_tests.stdout)] == [
            "model.model_properties.customers",
            "test.model_properties.not_null_customers_customer_id.5c9bf9911d",
            "test.model_properties.unique_customers_.ccc5343706",
            "test.model_properties.unique_customers_customer_id.c5af1ff4b1",
        ]
    ls_nested_model_selector = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "model_properties.customers.*", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_nested_model_selector.returncode == 0, ls_nested_model_selector.stderr
    assert json.loads(ls_nested_model_selector.stdout) == []

    ls_singular_tests = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "test_type:singular"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_singular_tests.returncode == 0, ls_singular_tests.stderr
    assert ls_singular_tests.stdout == ""

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
    assert_manifest_schema_slice(project / "target-dxt" / "manifest.json")
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
    assert accepted["refs"] == [{"name": "orders", "package": None, "version": None}]
    assert accepted["sources"] == []
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
    assert accepted_block["refs"] == [{"name": "orders", "package": None, "version": None}]
    assert accepted_block["sources"] == []
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
    assert relationships["refs"] == [
        {"name": "customers", "package": None, "version": None},
        {"name": "orders", "package": None, "version": None},
    ]
    assert relationships["sources"] == []
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
    assert_manifest_schema_slice(project / "target-dxt" / "manifest.json")
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


def test_parse_macro_block_variants(tmp_path: Path):
    project = copy_fixture(tmp_path, "macro_block_variants")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", "target-dxt"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr

    manifest = json.loads((project / "target-dxt" / "manifest.json").read_text())
    assert_manifest_schema_slice(project / "target-dxt" / "manifest.json")
    assert sorted(manifest["macros"]) == [
        "macro.macro_block_variants.format_id",
        "macro.macro_block_variants.materialization_empty_langs_default",
        "macro.macro_block_variants.materialization_incremental_default",
        "macro.macro_block_variants.materialization_snapshot_duckdb",
        "macro.macro_block_variants.materialization_table_default",
        "macro.macro_block_variants.materialization_tuple_langs_default",
        "macro.macro_block_variants.materialization_view_duckdb",
        "macro.macro_block_variants.test_positive_value",
    ]

    test_macro = manifest["macros"]["macro.macro_block_variants.test_positive_value"]
    assert test_macro["name"] == "test_positive_value"
    assert test_macro["macro_sql"] == (
        "{% test positive_value(model, column_name) %}\n"
        "    select * from {{ model }} where {{ column_name }} <= 0\n"
        "{% endtest %}"
    )
    assert test_macro["supported_languages"] is None

    default_materialization = manifest["macros"]["macro.macro_block_variants.materialization_table_default"]
    assert default_materialization["name"] == "materialization_table_default"
    assert default_materialization["supported_languages"] == ["sql"]

    no_option_materialization = manifest["macros"]["macro.macro_block_variants.materialization_incremental_default"]
    assert no_option_materialization["name"] == "materialization_incremental_default"
    assert no_option_materialization["supported_languages"] == ["sql"]

    reordered_materialization = manifest["macros"]["macro.macro_block_variants.materialization_snapshot_duckdb"]
    assert reordered_materialization["name"] == "materialization_snapshot_duckdb"
    assert reordered_materialization["supported_languages"] == ["sql"]
    assert reordered_materialization["macro_sql"] == (
        "{% materialization snapshot, supported_languages=['sql'], adapter='duckdb' %}\n"
        "    {{ return({'relations': []}) }}\n"
        "{% endmaterialization %}"
    )

    empty_langs_materialization = manifest["macros"]["macro.macro_block_variants.materialization_empty_langs_default"]
    assert empty_langs_materialization["name"] == "materialization_empty_langs_default"
    assert empty_langs_materialization["supported_languages"] == []

    tuple_langs_materialization = manifest["macros"]["macro.macro_block_variants.materialization_tuple_langs_default"]
    assert tuple_langs_materialization["name"] == "materialization_tuple_langs_default"
    assert tuple_langs_materialization["supported_languages"] == ["sql"]
    assert tuple_langs_materialization["macro_sql"] == (
        "{% materialization tuple_langs, supported_languages=('sql',), default %}\n"
        "    {{ return({'relations': []}) }}\n"
        "{% endmaterialization %}"
    )

    duckdb_materialization = manifest["macros"]["macro.macro_block_variants.materialization_view_duckdb"]
    assert duckdb_materialization["name"] == "materialization_view_duckdb"
    assert duckdb_materialization["supported_languages"] == ["sql", "python"]
    assert duckdb_materialization["macro_sql"] == (
        "{% materialization view, adapter='duckdb', supported_languages=['sql', 'python'] %}\n"
        "    {{ return({'relations': []}) }}\n"
        "{% endmaterialization %}"
    )


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
    assert_manifest_schema_slice(manifest_path)
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

    ls_root_package = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "package:package_macro_namespace", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_root_package.returncode == 0, ls_root_package.stderr
    assert [item["unique_id"] for item in json.loads(ls_root_package.stdout)] == [
        "model.package_macro_namespace.customers",
        "model.package_macro_namespace.local_customers",
    ]

    ls_macro_package = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "package:util_pkg", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_macro_package.returncode == 0, ls_macro_package.stderr
    assert json.loads(ls_macro_package.stdout) == []

    ls_unknown_package = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "package:not_a_package", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_unknown_package.returncode == 0, ls_unknown_package.stderr
    assert json.loads(ls_unknown_package.stdout) == []


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


def test_parse_installed_package_refs_and_resources(tmp_path: Path):
    project = copy_fixture(tmp_path, "package_ref_selector")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", "target-dxt"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr

    manifest_path = project / "target-dxt" / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    assert_manifest_schema_slice(manifest_path)
    root_same_name = "model.package_ref_selector.pkg_customers"
    root_customers = "model.package_ref_selector.root_customers"
    root_orders = "model.package_ref_selector.root_orders"
    root_pkg_source = "model.package_ref_selector.root_pkg_source"
    root_unqualified_package_only = "model.package_ref_selector.root_unqualified_package_only"
    package_from_source = "model.util_pkg.from_source"
    package_customers = "model.util_pkg.pkg_customers"
    package_only_customers = "model.util_pkg.pkg_only_customers"
    package_root_macro_customers = "model.util_pkg.root_macro_customers"
    package_seeded_customers = "model.util_pkg.pkg_seeded_customers"
    package_seed = "seed.util_pkg.raw_pkg_customers"
    root_macro = "macro.package_ref_selector.root_format_id"
    package_source = "source.util_pkg.raw.pkg_customers"
    package_macro = "macro.util_pkg.format_id"
    package_doc = "doc.util_pkg.pkg_customers_doc"
    package_exposure = "exposure.util_pkg.package_dashboard"
    assert sorted(manifest["nodes"]) == [
        root_same_name,
        root_customers,
        root_orders,
        root_pkg_source,
        root_unqualified_package_only,
        package_from_source,
        package_customers,
        package_only_customers,
        package_seeded_customers,
        package_root_macro_customers,
        package_seed,
    ]
    assert sorted(manifest["sources"]) == [package_source]
    assert sorted(manifest["docs"]) == [package_doc]
    assert sorted(manifest["exposures"]) == [package_exposure]
    assert manifest["sources"][package_source]["package_name"] == "util_pkg"
    assert manifest["docs"][package_doc]["package_name"] == "util_pkg"
    assert manifest["docs"][package_doc]["block_contents"] == "Package customers from the installed utility package."
    assert manifest["exposures"][package_exposure]["package_name"] == "util_pkg"
    assert manifest["exposures"][package_exposure]["fqn"] == ["util_pkg", "package_dashboard"]
    assert manifest["exposures"][package_exposure]["depends_on"]["nodes"] == [package_customers]
    assert manifest["nodes"][root_same_name]["package_name"] == "package_ref_selector"
    assert manifest["nodes"][root_same_name]["description"] == "Root model with the same name as a package model."
    assert manifest["nodes"][root_same_name]["config"]["materialized"] == "table"
    assert manifest["nodes"][root_customers]["package_name"] == "package_ref_selector"
    assert manifest["nodes"][root_customers]["refs"] == [
        {"name": "pkg_customers", "package": "util_pkg", "version": None}
    ]
    assert manifest["nodes"][root_customers]["depends_on"]["nodes"] == [package_customers]
    assert manifest["nodes"][root_orders]["depends_on"]["nodes"] == [root_customers]
    assert manifest["nodes"][root_pkg_source]["depends_on"]["nodes"] == [package_source]
    assert manifest["nodes"][root_pkg_source]["sources"] == [["raw", "pkg_customers"]]
    assert manifest["nodes"][root_unqualified_package_only]["refs"] == [
        {"name": "pkg_only_customers", "package": None, "version": None}
    ]
    assert manifest["nodes"][root_unqualified_package_only]["depends_on"]["nodes"] == [package_only_customers]
    assert manifest["nodes"][package_customers]["package_name"] == "util_pkg"
    assert manifest["nodes"][package_customers]["path"] == "pkg_customers.sql"
    assert manifest["nodes"][package_customers]["patch_path"] == "util_pkg://models/sources.yml"
    assert manifest["nodes"][package_customers]["description"] == "Package customers from the installed utility package."
    assert manifest["nodes"][package_customers]["doc_blocks"] == [package_doc]
    assert manifest["nodes"][package_customers]["columns"]["customer_id"]["description"] == "Package customer identifier."
    assert manifest["nodes"][package_customers]["config"]["materialized"] == "incremental"
    assert manifest["nodes"][package_only_customers]["package_name"] == "util_pkg"
    assert manifest["nodes"][package_only_customers]["config"]["materialized"] == "incremental"
    assert manifest["nodes"][package_root_macro_customers]["package_name"] == "util_pkg"
    assert manifest["nodes"][package_root_macro_customers]["depends_on"]["macros"] == [root_macro]
    assert manifest["macros"][root_macro]["description"] == ""
    assert manifest["macros"][package_macro]["description"] == "Format an identifier in the utility package."
    assert manifest["macros"][package_macro]["patch_path"] == "util_pkg://macros/schema.yml"
    assert manifest["macros"][package_macro]["arguments"] == [
        {
            "name": "column_name",
            "type": "string",
            "description": "Identifier expression to cast.",
        }
    ]
    assert manifest["nodes"][package_from_source]["package_name"] == "util_pkg"
    assert manifest["nodes"][package_from_source]["depends_on"]["nodes"] == [package_source]
    assert manifest["nodes"][package_from_source]["sources"] == [["raw", "pkg_customers"]]
    assert manifest["nodes"][package_seeded_customers]["package_name"] == "util_pkg"
    assert manifest["nodes"][package_seeded_customers]["refs"] == [
        {"name": "raw_pkg_customers", "package": None, "version": None}
    ]
    assert manifest["nodes"][package_seeded_customers]["depends_on"] == {
        "macros": [package_macro],
        "nodes": [package_seed],
    }
    assert manifest["nodes"][package_seed]["package_name"] == "util_pkg"
    assert manifest["nodes"][package_seed]["path"] == "raw_pkg_customers.csv"
    assert manifest["nodes"][package_seed]["docs"]["node_color"] == "green"
    assert manifest["parent_map"][root_customers] == [package_customers]
    assert manifest["parent_map"][root_pkg_source] == [package_source]
    assert manifest["parent_map"][root_unqualified_package_only] == [package_only_customers]
    assert manifest["parent_map"][package_from_source] == [package_source]
    assert manifest["parent_map"][package_exposure] == [package_customers]
    assert manifest["child_map"][package_source] == [root_pkg_source, package_from_source]
    assert manifest["child_map"][package_customers] == [root_customers, package_exposure]
    assert manifest["child_map"][package_only_customers] == [root_unqualified_package_only]
    assert manifest["parent_map"][package_seeded_customers] == [package_seed]
    assert manifest["child_map"][package_seed] == [package_seeded_customers]
    assert str(project) not in manifest_path.read_text()

    ls_package = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "package:util_pkg", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_package.returncode == 0, ls_package.stderr
    assert [item["unique_id"] for item in json.loads(ls_package.stdout)] == [
        package_exposure,
        package_from_source,
        package_customers,
        package_only_customers,
        package_seeded_customers,
        package_root_macro_customers,
        package_seed,
        package_source,
    ]

    ls_package_models = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "package:util_pkg,resource_type:model", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_package_models.returncode == 0, ls_package_models.stderr
    assert [item["unique_id"] for item in json.loads(ls_package_models.stdout)] == [
        package_from_source,
        package_customers,
        package_only_customers,
        package_seeded_customers,
        package_root_macro_customers,
    ]

    ls_root = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "package:this", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_root.returncode == 0, ls_root.stderr
    assert [item["unique_id"] for item in json.loads(ls_root.stdout)] == [
        root_same_name,
        root_customers,
        root_orders,
        root_pkg_source,
        root_unqualified_package_only,
    ]

    ls_package_exclude = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "package:util_pkg", "--exclude", "pkg_seeded_customers", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_package_exclude.returncode == 0, ls_package_exclude.stderr
    assert [item["unique_id"] for item in json.loads(ls_package_exclude.stdout)] == [
        package_exposure,
        package_from_source,
        package_customers,
        package_only_customers,
        package_root_macro_customers,
        package_seed,
        package_source,
    ]


def test_installed_package_configs_do_not_reconfigure_siblings(tmp_path: Path):
    project = tmp_path / "root"
    package_a = project / "dbt_packages" / "pkg_a"
    package_b = project / "dbt_packages" / "pkg_b"
    (project / "models").mkdir(parents=True)
    (package_a / "models").mkdir(parents=True)
    (package_b / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: root_proj
version: "1.0"
profile: default
model-paths: ["models"]
target-path: target
"""
    )
    (package_a / "dbt_project.yml").write_text(
        """name: pkg_a
version: "1.0"
profile: default
model-paths: ["models"]
models:
  pkg_b:
    +materialized: incremental
"""
    )
    (package_b / "dbt_project.yml").write_text(
        """name: pkg_b
version: "1.0"
profile: default
model-paths: ["models"]
models:
  pkg_b:
    +materialized: table
"""
    )
    (package_b / "models" / "b.sql").write_text("select 1 as id\n")

    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", "target-dxt"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    manifest = json.loads((project / "target-dxt" / "manifest.json").read_text())
    assert manifest["nodes"]["model.pkg_b.b"]["config"]["materialized"] == "table"


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
    assert customer["refs"] == [{"name": "stg_customers", "package": None, "version": None}]
    assert customer["sources"] == []
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
    assert node["refs"] == []
    assert node["sources"] == [["raw", "customers"]]


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
    assert_manifest_schema_slice(manifest_path)
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
    assert_manifest_schema_slice(manifest_path)
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
    assert_manifest_schema_slice(project / "target-dxt" / "manifest.json")
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

    ls_package_all = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "package:exposure_artifacts", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_package_all.returncode == 0, ls_package_all.stderr
    assert [item["unique_id"] for item in json.loads(ls_package_all.stdout)] == [
        exposure_id,
        model_id,
        source_id,
    ]

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

    ls_tag_wildcard = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "tag:b*"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_tag_wildcard.returncode == 0, ls_tag_wildcard.stderr
    assert ls_tag_wildcard.stdout.splitlines() == [exposure_id]


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


def test_ls_multi_argv_and_repeated_selector_flags(tmp_path: Path):
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

    expected_pair = [
        "model.selector_graph.customers",
        "model.selector_graph.orders",
    ]
    assert ls_json("--select", "customers orders") == expected_pair
    assert ls_json("--select", "customers", "orders") == expected_pair
    assert ls_json("--select", "customers", "--select", "orders") == expected_pair
    assert ls_json("--select", "customers", "orders", "--resource-type", "model") == expected_pair
    assert ls_json("--select", "+customers+", "--exclude", "orders", "stg_customers") == [
        "model.selector_graph.customers"
    ]
    assert ls_json("--select", "+customers+", "--exclude", "orders", "--exclude", "stg_customers") == [
        "model.selector_graph.customers"
    ]
    assert ls_json("--select", "stg_*") == ["model.selector_graph.stg_customers"]
    assert ls_json("--select", "*customers") == [
        "model.selector_graph.customers",
        "model.selector_graph.stg_customers",
    ]
    assert ls_json("--select", "selector_graph.*customers") == [
        "model.selector_graph.customers",
        "model.selector_graph.stg_customers",
    ]
    assert ls_json("--select", "model.selector_graph.*customers") == []
    assert ls_json("--select", "path:models/stg_*") == ["model.selector_graph.stg_customers"]
    assert ls_json("--select", "path:*orders.sql") == []
    assert ls_json("--select", "path:models?orders.sql") == []
    assert ls_json("--select", "path:models/stg?customers.sql") == ["model.selector_graph.stg_customers"]
    assert ls_json("--select", "path:models/*orders.sql") == ["model.selector_graph.orders"]
    assert ls_json("--select", "+stg_*") == ["model.selector_graph.stg_customers"]
    assert ls_json("--select", "stg_*+") == [
        "model.selector_graph.customers",
        "model.selector_graph.orders",
        "model.selector_graph.stg_customers",
    ]


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
    assert ls_text("--select", "resource_type:model,config.materialized:table") == [
        "model.inline_config.orders"
    ]
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


def test_project_model_path_configs_apply_below_inline_and_yaml_configs(tmp_path: Path):
    project = copy_fixture(tmp_path, "project_model_path_config")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", "target-dxt"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr

    manifest_path = project / "target-dxt" / "manifest.json"
    assert_manifest_schema_slice(manifest_path)
    manifest = json.loads(manifest_path.read_text())
    nodes = manifest["nodes"]
    assert nodes["model.project_model_path_config.customers"]["config"]["materialized"] == "table"
    assert nodes["model.project_model_path_config.stg_customers"]["config"]["materialized"] == "view"
    assert nodes["model.project_model_path_config.orders"]["config"]["materialized"] == "table"
    assert nodes["model.project_model_path_config.orders"]["config"]["tags"] == ["published", "root"]
    assert nodes["model.project_model_path_config.inline_orders"]["config"]["materialized"] == "incremental"
    assert nodes["model.project_model_path_config.inline_orders"]["config"]["tags"] == [
        "inline",
        "published",
        "root",
        "yaml_inline",
    ]
    assert nodes["model.project_model_path_config.yaml_orders"]["config"]["materialized"] == "view"
    assert nodes["model.project_model_path_config.yaml_orders"]["config"]["tags"] == [
        "published",
        "root",
        "yaml",
    ]
    assert nodes["model.project_model_path_config.customers"]["docs"] == {
        "show": True,
        "node_color": "gold",
    }
    assert nodes["model.project_model_path_config.customers"]["config"]["docs"] == {
        "show": True,
        "node_color": "gold",
    }
    assert nodes["model.project_model_path_config.stg_customers"]["docs"] == {
        "show": True,
        "node_color": "silver",
    }
    assert nodes["model.project_model_path_config.orders"]["docs"] == {
        "show": True,
        "node_color": "gold",
    }
    assert nodes["seed.project_model_path_config.raw_customers"]["docs"] == {
        "show": True,
        "node_color": "#cd7f32",
    }
    assert nodes["seed.project_model_path_config.raw_customers"]["config"]["docs"] == {
        "show": True,
        "node_color": "#cd7f32",
    }

    def ls_text(*args: str) -> list[str]:
        ls_result = subprocess.run(
            [DXT, "ls", "--project-dir", str(project), *args],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        assert ls_result.returncode == 0, ls_result.stderr
        return ls_result.stdout.splitlines()

    assert ls_text("--select", "config.materialized:table") == [
        "model.project_model_path_config.customers",
        "model.project_model_path_config.orders",
    ]
    assert ls_text("--select", "tag:published") == [
        "model.project_model_path_config.inline_orders",
        "model.project_model_path_config.orders",
        "model.project_model_path_config.yaml_orders",
    ]
    assert ls_text("--select", "tag:root") == [
        "model.project_model_path_config.customers",
        "model.project_model_path_config.inline_orders",
        "model.project_model_path_config.orders",
        "model.project_model_path_config.stg_customers",
        "model.project_model_path_config.yaml_orders",
    ]
    assert ls_text("--select", "project_model_path_config.marts.*orders") == [
        "model.project_model_path_config.inline_orders",
        "model.project_model_path_config.orders",
        "model.project_model_path_config.yaml_orders",
    ]
    assert ls_text("--select", "marts.*orders") == [
        "model.project_model_path_config.inline_orders",
        "model.project_model_path_config.orders",
        "model.project_model_path_config.yaml_orders",
    ]
    assert ls_text("--select", "path:models/*") == [
        "model.project_model_path_config.customers",
        "model.project_model_path_config.inline_orders",
        "model.project_model_path_config.orders",
        "model.project_model_path_config.stg_customers",
        "model.project_model_path_config.yaml_orders",
    ]


def test_ls_resource_type_selectors_for_sources_and_exposures(tmp_path: Path):
    source_project = copy_fixture(tmp_path, "source_ref")
    source_result = subprocess.run(
        [DXT, "ls", "--project-dir", str(source_project), "--select", "resource_type:source", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert source_result.returncode == 0, source_result.stderr
    assert [item["unique_id"] for item in json.loads(source_result.stdout)] == [
        "source.source_ref.raw.customers",
        "source.source_ref.raw.orders",
    ]
    source_union = subprocess.run(
        [DXT, "ls", "--project-dir", str(source_project), "--select", "source:raw.customers source:raw.orders", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert source_union.returncode == 0, source_union.stderr
    assert [item["unique_id"] for item in json.loads(source_union.stdout)] == [
        "source.source_ref.raw.customers",
        "source.source_ref.raw.orders",
    ]
    source_wildcard = subprocess.run(
        [DXT, "ls", "--project-dir", str(source_project), "--select", "source:raw.*", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert source_wildcard.returncode == 0, source_wildcard.stderr
    assert [item["unique_id"] for item in json.loads(source_wildcard.stdout)] == [
        "source.source_ref.raw.customers",
        "source.source_ref.raw.orders",
    ]
    source_package_wildcard = subprocess.run(
        [DXT, "ls", "--project-dir", str(source_project), "--select", "source:source_ref.raw.*", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert source_package_wildcard.returncode == 0, source_package_wildcard.stderr
    assert [item["unique_id"] for item in json.loads(source_package_wildcard.stdout)] == [
        "source.source_ref.raw.customers",
        "source.source_ref.raw.orders",
    ]
    source_name_wildcard = subprocess.run(
        [DXT, "ls", "--project-dir", str(source_project), "--select", "source:raw*", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert source_name_wildcard.returncode == 0, source_name_wildcard.stderr
    assert [item["unique_id"] for item in json.loads(source_name_wildcard.stdout)] == [
        "source.source_ref.raw.customers",
        "source.source_ref.raw.orders",
    ]
    source_table_without_source = subprocess.run(
        [DXT, "ls", "--project-dir", str(source_project), "--select", "source:*orders", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert source_table_without_source.returncode == 0, source_table_without_source.stderr
    assert json.loads(source_table_without_source.stdout) == []
    for bare_source_selector in ("orders", "*orders", "source_ref.raw.*", "source.source_ref.raw.orders"):
        bare_source = subprocess.run(
            [DXT, "ls", "--project-dir", str(source_project), "--select", bare_source_selector, "--output", "json"],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        assert bare_source.returncode == 0, bare_source.stderr
        assert json.loads(bare_source.stdout) == []
    source_path = subprocess.run(
        [DXT, "ls", "--project-dir", str(source_project), "--select", "path:models/*.yml", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert source_path.returncode == 0, source_path.stderr
    assert [item["unique_id"] for item in json.loads(source_path.stdout)] == [
        "model.source_ref.stg_customers",
        "source.source_ref.raw.customers",
        "source.source_ref.raw.orders",
    ]
    source_package = subprocess.run(
        [
            DXT,
            "ls",
            "--project-dir",
            str(source_project),
            "--select",
            "package:source_ref,resource_type:source",
            "--output",
            "json",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert source_package.returncode == 0, source_package.stderr
    assert [item["unique_id"] for item in json.loads(source_package.stdout)] == [
        "source.source_ref.raw.customers",
        "source.source_ref.raw.orders",
    ]

    exposure_project = copy_fixture(tmp_path, "exposure_artifacts")
    exposure_result = subprocess.run(
        [DXT, "ls", "--project-dir", str(exposure_project), "--select", "resource_type:exposure", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert exposure_result.returncode == 0, exposure_result.stderr
    assert json.loads(exposure_result.stdout) == [
        {
            "unique_id": "exposure.exposure_artifacts.weekly_kpis",
            "resource_type": "exposure",
            "name": "weekly_kpis",
        }
    ]
    exposure_union = subprocess.run(
        [DXT, "ls", "--project-dir", str(exposure_project), "--select", "orders weekly_kpis", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert exposure_union.returncode == 0, exposure_union.stderr
    assert [item["unique_id"] for item in json.loads(exposure_union.stdout)] == [
        "exposure.exposure_artifacts.weekly_kpis",
        "model.exposure_artifacts.orders",
    ]
    exposure_wildcard = subprocess.run(
        [DXT, "ls", "--project-dir", str(exposure_project), "--select", "exposure:weekly_*", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert exposure_wildcard.returncode == 0, exposure_wildcard.stderr
    assert [item["unique_id"] for item in json.loads(exposure_wildcard.stdout)] == [
        "exposure.exposure_artifacts.weekly_kpis"
    ]
    exposure_package_wildcard = subprocess.run(
        [DXT, "ls", "--project-dir", str(exposure_project), "--select", "exposure:exposure_artifacts.weekly_*", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert exposure_package_wildcard.returncode == 0, exposure_package_wildcard.stderr
    assert [item["unique_id"] for item in json.loads(exposure_package_wildcard.stdout)] == [
        "exposure.exposure_artifacts.weekly_kpis"
    ]
    exposure_prefixed_unique_id = subprocess.run(
        [DXT, "ls", "--project-dir", str(exposure_project), "--select", "exposure:exposure.exposure_artifacts.weekly_kpis", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert exposure_prefixed_unique_id.returncode == 0, exposure_prefixed_unique_id.stderr
    assert json.loads(exposure_prefixed_unique_id.stdout) == []
    bare_exposure_unique_id = subprocess.run(
        [DXT, "ls", "--project-dir", str(exposure_project), "--select", "exposure.exposure_artifacts.weekly_kpis", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert bare_exposure_unique_id.returncode == 0, bare_exposure_unique_id.stderr
    assert json.loads(bare_exposure_unique_id.stdout) == []
    exposure_path = subprocess.run(
        [DXT, "ls", "--project-dir", str(exposure_project), "--select", "path:models/*.yml", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert exposure_path.returncode == 0, exposure_path.stderr
    assert [item["unique_id"] for item in json.loads(exposure_path.stdout)] == [
        "exposure.exposure_artifacts.weekly_kpis",
        "source.exposure_artifacts.raw.customers",
    ]
    exposure_package = subprocess.run(
        [
            DXT,
            "ls",
            "--project-dir",
            str(exposure_project),
            "--select",
            "package:exposure_artifacts,resource_type:exposure",
            "--output",
            "json",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert exposure_package.returncode == 0, exposure_package.stderr
    assert json.loads(exposure_package.stdout) == [
        {
            "unique_id": "exposure.exposure_artifacts.weekly_kpis",
            "resource_type": "exposure",
            "name": "weekly_kpis",
        }
    ]


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
    assert ls_json("--select", "customers orders") == [
        "model.selector_graph.customers",
        "model.selector_graph.orders",
    ]
    assert ls_json("--select", "  customers   orders  ") == [
        "model.selector_graph.customers",
        "model.selector_graph.orders",
    ]
    assert ls_json("--select", "+customers orders") == [
        "model.selector_graph.customers",
        "model.selector_graph.orders",
        "model.selector_graph.stg_customers",
    ]
    assert ls_json("--select", "customers+,config.materialized:table +orders,config.materialized:view") == [
        "model.selector_graph.customers",
        "model.selector_graph.orders",
        "model.selector_graph.stg_customers",
    ]
    assert ls_json("--select", "+customers+", "--exclude", "orders stg_customers") == [
        "model.selector_graph.customers"
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
        "resource_type:snapshot",
        "test_type:unit",
        "tag:nightly,",
        "config.materialized:",
        "package:",
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

    missing_selector = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert missing_selector.returncode == 2
    assert "option `--select` requires a value" in missing_selector.stderr

    unsupported_in_list = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "customers", "state:modified"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert unsupported_in_list.returncode == 2
    assert "selector syntax is not supported" in unsupported_in_list.stderr


def test_parse_accepts_selector_argv_lists_without_filtering_manifest(tmp_path: Path):
    project = copy_fixture(tmp_path, "single_model")
    result = subprocess.run(
        [
            DXT,
            "parse",
            "--project-dir",
            str(project),
            "--select",
            "customers",
            "tag:nightly",
            "--exclude",
            "tag:skip",
            "--target-path",
            "target-dxt",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    manifest = json.loads((project / "target-dxt" / "manifest.json").read_text())
    assert list(manifest["nodes"]) == ["model.single_model.customers"]


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


def test_docs_generate_writes_manifest_catalog_and_compiled_sql(tmp_path: Path):
    project = copy_fixture(tmp_path, "docs_blocks")
    target = tmp_path / "docs-target"
    result = subprocess.run(
        [
            DXT,
            "docs",
            "generate",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--threads",
            "4",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    assert "Generated docs artifacts for 1 compiled model(s)" in result.stdout

    compiled_path = target / "compiled" / "docs_blocks" / "models" / "customers.sql"
    assert compiled_path.read_text().strip() == "select 1 as customer_id"

    manifest_path = target / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    assert_partial_manifest_schema(manifest)
    assert_manifest_schema_slice(manifest_path)
    assert manifest["nodes"]["model.docs_blocks.customers"]["compiled"] is True
    assert manifest["nodes"]["model.docs_blocks.customers"]["compiled_path"].endswith(
        "/compiled/docs_blocks/models/customers.sql"
    )
    assert sorted(manifest["docs"]) == [
        "doc.docs_blocks.customer_id",
        "doc.docs_blocks.customer_model",
    ]
    assert manifest["docs"]["doc.docs_blocks.customer_model"]["block_contents"] == "Customer model docs."

    catalog_path = target / "catalog.json"
    catalog = json.loads(catalog_path.read_text())
    assert_catalog_schema_slice(catalog_path)
    assert catalog["metadata"]["dbt_schema_version"] == "https://schemas.getdbt.com/dbt/catalog/v1.json"
    assert catalog["metadata"]["dbt_version"] == "0.0.0"
    assert catalog["metadata"]["invocation_id"] is None
    assert catalog["metadata"]["invocation_started_at"] is None
    assert catalog["metadata"]["env"] == {}
    assert catalog["nodes"] == {}
    assert catalog["sources"] == {}
    assert catalog["errors"] is None
    assert str(project) not in catalog_path.read_text()


def test_docs_generate_applies_select_and_exclude_to_compiled_models(tmp_path: Path):
    project = copy_fixture(tmp_path, "compile_basic")
    target = tmp_path / "docs-target"
    result = subprocess.run(
        [
            DXT,
            "docs",
            "generate",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "orders",
            "--exclude",
            "from_source",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Generated docs artifacts for 1 compiled model(s)" in result.stdout
    compiled_root = target / "compiled" / "compile_basic" / "models"
    assert not (compiled_root / "customers.sql").exists()
    assert (compiled_root / "orders.sql").exists()
    assert not (compiled_root / "from_source.sql").exists()
    manifest = json.loads((target / "manifest.json").read_text())
    assert manifest["nodes"]["model.compile_basic.orders"]["compiled"] is True
    assert "compiled" not in manifest["nodes"]["model.compile_basic.customers"]
    assert "compiled" not in manifest["nodes"]["model.compile_basic.from_source"]


def test_docs_generate_fails_loudly_on_unsupported_compile_jinja(tmp_path: Path):
    project = copy_fixture(tmp_path, "unsupported_macro_call")
    result = subprocess.run(
        [DXT, "docs", "generate", "--project-dir", str(project)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "unsupported or malformed Jinja" in result.stderr


def test_unknown_option_is_rejected():
    result = subprocess.run([DXT, "parse", "--unknown"], cwd=ROOT, text=True, capture_output=True)
    assert result.returncode == 2
    assert "unsupported option" in result.stderr


def test_subcommand_help_exits_successfully():
    result = subprocess.run([DXT, "parse", "--help"], cwd=ROOT, text=True, capture_output=True)
    assert result.returncode == 0
    assert "Usage: dxt parse" in result.stdout
    assert result.stderr == ""

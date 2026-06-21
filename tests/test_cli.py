from __future__ import annotations

import subprocess
import tempfile
import json
import hashlib
import shutil
import importlib.util
import copy
import socket
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out" / "bin" / "dxt"
SCHEMA_VALIDATOR_PATH = ROOT / "scripts" / "validate_manifest_schema.py"
CATALOG_SCHEMA = ROOT / "tests" / "schemas" / "dbt_catalog_v1_docs_slice.schema.json"
RUN_RESULTS_SCHEMA = ROOT / "tests" / "schemas" / "dbt_run_results_v6_m3_slice.schema.json"
SOURCES_SCHEMA = ROOT / "tests" / "schemas" / "dbt_sources_v3_m3_slice.schema.json"
DUCKDB = shutil.which("duckdb")
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
    assert "Load supported selected DuckDB CSV seeds." in result.stdout
    assert "Execute supported selected DuckDB seeds, models, and tests." in result.stdout
    assert "Preflight selected seeds, models, and tests without running SQL." not in result.stdout
    assert result.stderr == ""


def copy_fixture(tmp_path: Path, name: str) -> Path:
    source = ROOT / "tests" / "fixtures" / name
    dest = tmp_path / name
    shutil.copytree(source, dest)
    return dest


def duckdb_scalar(db_path: Path, sql: str) -> str:
    result = subprocess.run(
        [DUCKDB, str(db_path), "-csv", "-noheader", "-batch", "-bail", "-c", sql],
        cwd=ROOT,
        check=True,
        text=True,
        capture_output=True,
    )
    return result.stdout.strip()


def dbt_sha256_text(value: str) -> dict[str, str]:
    return {"name": "sha256", "checksum": hashlib.sha256(value.rstrip("\r\n").encode()).hexdigest()}


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
    assert orders["database"] == "memory"
    assert orders["schema"] == "main"
    assert orders["alias"] == "orders"
    assert orders["fqn"] == ["compile_basic", "orders"]
    assert orders["checksum"] == dbt_sha256_text((project / "models" / "orders.sql").read_text())
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


def test_compile_renders_root_project_model_column_custom_generic_tests(tmp_path: Path):
    project = copy_fixture(tmp_path, "custom_generic_test_compile")
    target = tmp_path / "compile-target"
    result = subprocess.run(
        [DXT, "compile", "--project-dir", str(project), "--target-path", str(target), "--select", "test_type:generic"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Compiled 0 model(s) and 2 test(s)" in result.stdout

    positive_sql = (target / "compiled" / "custom_generic_test_compile" / "positive_amount_orders_amount.sql").read_text()
    nonzero_sql = (target / "compiled" / "custom_generic_test_compile" / "nonzero_amount_orders_discount.sql").read_text()
    assert "select amount" in positive_sql
    assert 'from "main"."orders"' in positive_sql
    assert "where amount < 0" in positive_sql
    assert "select discount" in nonzero_sql
    assert 'from "main"."orders"' in nonzero_sql
    assert "where discount = 0" in nonzero_sql
    assert "{{" not in positive_sql + nonzero_sql
    assert "{%" not in positive_sql + nonzero_sql

    manifest_path = target / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    assert_partial_manifest_schema(manifest)
    assert_manifest_schema_slice(manifest_path)
    tests_by_name = {node["test_metadata"]["name"]: node for node in manifest["nodes"].values() if node["resource_type"] == "test"}

    positive = tests_by_name["positive_amount"]
    assert positive["raw_code"] == "{{ test_positive_amount(**_dbt_generic_test_kwargs) }}"
    assert positive["test_metadata"]["kwargs"]["model"] == "{{ get_where_subquery(ref('orders')) }}"
    assert positive["test_metadata"]["kwargs"]["column_name"] == "amount"
    assert positive["attached_node"] == "model.custom_generic_test_compile.orders"
    assert positive["depends_on"]["nodes"] == ["model.custom_generic_test_compile.orders"]
    assert positive["depends_on"]["macros"] == [
        "macro.custom_generic_test_compile.test_positive_amount",
        "macro.dbt.get_where_subquery",
    ]
    assert positive["compiled"] is True
    assert positive["compiled_code"] == positive_sql
    assert positive["compiled_path"].endswith("/compiled/custom_generic_test_compile/positive_amount_orders_amount.sql")

    nonzero = tests_by_name["nonzero_amount"]
    assert nonzero["raw_code"] == "{{ test_nonzero_amount(**_dbt_generic_test_kwargs) }}"
    assert nonzero["test_metadata"]["kwargs"]["column_name"] == "discount"
    assert nonzero["depends_on"]["macros"] == [
        "macro.custom_generic_test_compile.test_nonzero_amount",
        "macro.dbt.get_where_subquery",
    ]
    assert nonzero["compiled"] is True
    assert nonzero["compiled_code"] == nonzero_sql


def test_compile_renders_installed_package_model_column_custom_generic_tests(tmp_path: Path):
    project = copy_fixture(tmp_path, "package_custom_generic_test_compile")
    target = tmp_path / "compile-target"
    result = subprocess.run(
        [DXT, "compile", "--project-dir", str(project), "--target-path", str(target), "--select", "test_type:generic"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Compiled 0 model(s) and 2 test(s)" in result.stdout

    compiled_root = target / "compiled" / "package_custom_generic_test_compile"
    positive_sql = (compiled_root / "util_pkg_positive_amount_orders_amount.sql").read_text()
    nonzero_sql = (compiled_root / "util_pkg_nonzero_amount_orders_discount.sql").read_text()
    assert "select amount" in positive_sql
    assert 'from "main"."orders"' in positive_sql
    assert "where amount < 0" in positive_sql
    assert "select discount" in nonzero_sql
    assert 'from "main"."orders"' in nonzero_sql
    assert "where discount = 0" in nonzero_sql
    assert "{{" not in positive_sql + nonzero_sql
    assert "{%" not in positive_sql + nonzero_sql

    manifest_path = target / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    assert_partial_manifest_schema(manifest)
    assert_manifest_schema_slice(manifest_path)
    tests_by_name = {node["test_metadata"]["name"]: node for node in manifest["nodes"].values() if node["resource_type"] == "test"}

    positive = tests_by_name["positive_amount"]
    assert positive["package_name"] == "package_custom_generic_test_compile"
    assert positive["name"] == "util_pkg_positive_amount_orders_amount"
    assert positive["raw_code"] == "{{ util_pkg.test_positive_amount(**_dbt_generic_test_kwargs) }}"
    assert positive["test_metadata"] == {
        "name": "positive_amount",
        "kwargs": {
            "model": "{{ get_where_subquery(ref('orders')) }}",
            "column_name": "amount",
        },
        "namespace": "util_pkg",
    }
    assert positive["attached_node"] == "model.package_custom_generic_test_compile.orders"
    assert positive["depends_on"]["nodes"] == ["model.package_custom_generic_test_compile.orders"]
    assert positive["depends_on"]["macros"] == [
        "macro.util_pkg.test_positive_amount",
        "macro.dbt.get_where_subquery",
    ]
    assert positive["compiled"] is True
    assert positive["compiled_code"] == positive_sql
    assert positive["compiled_path"].endswith(
        "/compiled/package_custom_generic_test_compile/util_pkg_positive_amount_orders_amount.sql"
    )

    nonzero = tests_by_name["nonzero_amount"]
    assert nonzero["raw_code"] == "{{ util_pkg.test_nonzero_amount(**_dbt_generic_test_kwargs) }}"
    assert nonzero["test_metadata"]["namespace"] == "util_pkg"
    assert nonzero["test_metadata"]["kwargs"]["column_name"] == "discount"
    assert nonzero["depends_on"]["macros"] == [
        "macro.util_pkg.test_nonzero_amount",
        "macro.dbt.get_where_subquery",
    ]
    assert nonzero["compiled"] is True
    assert nonzero["compiled_code"] == nonzero_sql

    try:
        has_dbt_core = importlib.util.find_spec("dbt.cli.main") is not None
        has_dbt_duckdb = importlib.util.find_spec("dbt.adapters.duckdb") is not None
    except ModuleNotFoundError:
        has_dbt_core = False
        has_dbt_duckdb = False

    if has_dbt_core and has_dbt_duckdb:
        from dbt.cli.main import dbtRunner
        import dbt_common.events.base_types as dbt_event_base_types
        import google.protobuf.json_format as protobuf_json_format

        (project / "models" / "schema.yml").write_text(
            """version: 2

models:
  - name: orders
    columns:
      - name: amount
        data_tests:
          - util_pkg.positive_amount
"""
        )
        (project / "dbt_packages" / "util_pkg" / "macros" / "custom_tests.sql").write_text(
            """{% test positive_amount(model, column_name) %}
select {{ column_name }}
from {{ model }}
where {{ column_name }} < 0
{% endtest %}
"""
        )
        dbt_profiles = tmp_path / "dbt-profiles"
        dbt_profiles.mkdir()
        (dbt_profiles / "profiles.yml").write_text(
            "\n".join(
                [
                    "package_custom_generic_test_compile:",
                    "  target: dev",
                    "  outputs:",
                    "    dev:",
                    "      type: duckdb",
                    f"      path: {tmp_path / 'oracle.duckdb'}",
                    "      schema: main",
                ]
            )
            + "\n"
        )
        dbt_target = tmp_path / "dbt-target"
        original_message_to_json = protobuf_json_format.MessageToJson
        original_event_message_to_json = dbt_event_base_types.MessageToJson

        def compatible_message_to_json(message, *args, always_print_fields_with_no_presence=None, **kwargs):
            if always_print_fields_with_no_presence is not None and "including_default_value_fields" not in kwargs:
                kwargs["including_default_value_fields"] = always_print_fields_with_no_presence
            return original_message_to_json(message, *args, **kwargs)

        protobuf_json_format.MessageToJson = compatible_message_to_json
        dbt_event_base_types.MessageToJson = compatible_message_to_json
        try:
            dbt_result = dbtRunner().invoke(
                [
                    "compile",
                    "--project-dir",
                    str(project),
                    "--profiles-dir",
                    str(dbt_profiles),
                    "--target-path",
                    str(dbt_target),
                    "--select",
                    "test_type:generic",
                ]
            )
        finally:
            protobuf_json_format.MessageToJson = original_message_to_json
            dbt_event_base_types.MessageToJson = original_event_message_to_json
        assert dbt_result.success, dbt_result.exception
        dbt_manifest = json.loads((dbt_target / "manifest.json").read_text())
        dbt_tests = {node["test_metadata"]["name"]: node for node in dbt_manifest["nodes"].values() if node["resource_type"] == "test"}
        dbt_positive = dbt_tests["positive_amount"]
        assert positive["unique_id"] == dbt_positive["unique_id"]
        assert positive["raw_code"] == dbt_positive["raw_code"]
        assert positive["test_metadata"] == dbt_positive["test_metadata"]
        assert positive["depends_on"] == dbt_positive["depends_on"]
        assert positive["compiled"] == dbt_positive["compiled"]
        assert "where amount < 0" in dbt_positive["compiled_code"]
        assert "{{" not in dbt_positive["compiled_code"]
        assert "{%" not in dbt_positive["compiled_code"]


def test_compile_renders_source_and_seed_column_custom_generic_tests(tmp_path: Path):
    project = copy_fixture(tmp_path, "source_seed_custom_generic_test_compile")
    target = tmp_path / "compile-target"
    result = subprocess.run(
        [DXT, "compile", "--project-dir", str(project), "--target-path", str(target), "--select", "test_type:generic"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Compiled 0 model(s) and 2 test(s)" in result.stdout

    compiled_root = target / "compiled" / "source_seed_custom_generic_test_compile"
    source_sql = (compiled_root / "source_positive_amount_raw_orders_src_amount.sql").read_text()
    seed_sql = (compiled_root / "util_pkg_nonzero_amount_orders_seed_amount.sql").read_text()
    assert "select amount" in source_sql
    assert 'from "raw"."orders_src"' in source_sql
    assert "where amount < 0" in source_sql
    assert "select amount" in seed_sql
    assert 'from "main"."orders_seed"' in seed_sql
    assert "where amount = 0" in seed_sql
    assert "{{" not in source_sql + seed_sql
    assert "{%" not in source_sql + seed_sql

    manifest_path = target / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    assert_partial_manifest_schema(manifest)
    assert_manifest_schema_slice(manifest_path)
    tests_by_name = {node["test_metadata"]["name"]: node for node in manifest["nodes"].values() if node["resource_type"] == "test"}

    source_test = tests_by_name["positive_amount"]
    assert source_test["name"] == "source_positive_amount_raw_orders_src_amount"
    assert source_test["raw_code"] == "{{ test_positive_amount(**_dbt_generic_test_kwargs) }}"
    assert source_test["test_metadata"] == {
        "name": "positive_amount",
        "kwargs": {
            "model": "{{ get_where_subquery(source('raw', 'orders_src')) }}",
            "column_name": "amount",
        },
        "namespace": None,
    }
    assert source_test["attached_node"] is None
    assert source_test["depends_on"]["nodes"] == ["source.source_seed_custom_generic_test_compile.raw.orders_src"]
    assert source_test["depends_on"]["macros"] == [
        "macro.source_seed_custom_generic_test_compile.test_positive_amount",
        "macro.dbt.get_where_subquery",
    ]
    assert source_test["sources"] == [["raw", "orders_src"]]
    assert source_test["compiled"] is True
    assert source_test["compiled_code"] == source_sql

    seed_test = tests_by_name["nonzero_amount"]
    assert seed_test["name"] == "util_pkg_nonzero_amount_orders_seed_amount"
    assert seed_test["raw_code"] == "{{ util_pkg.test_nonzero_amount(**_dbt_generic_test_kwargs) }}"
    assert seed_test["test_metadata"] == {
        "name": "nonzero_amount",
        "kwargs": {
            "model": "{{ get_where_subquery(ref('orders_seed')) }}",
            "column_name": "amount",
        },
        "namespace": "util_pkg",
    }
    assert seed_test["attached_node"] == "seed.source_seed_custom_generic_test_compile.orders_seed"
    assert seed_test["depends_on"]["nodes"] == ["seed.source_seed_custom_generic_test_compile.orders_seed"]
    assert seed_test["depends_on"]["macros"] == [
        "macro.util_pkg.test_nonzero_amount",
        "macro.dbt.get_where_subquery",
    ]
    assert seed_test["compiled"] is True
    assert seed_test["compiled_code"] == seed_sql

    try:
        has_dbt_core = importlib.util.find_spec("dbt.cli.main") is not None
        has_dbt_duckdb = importlib.util.find_spec("dbt.adapters.duckdb") is not None
    except ModuleNotFoundError:
        has_dbt_core = False
        has_dbt_duckdb = False

    if has_dbt_core and has_dbt_duckdb:
        from dbt.cli.main import dbtRunner
        import dbt_common.events.base_types as dbt_event_base_types
        import google.protobuf.json_format as protobuf_json_format

        (project / "dbt_packages" / "util_pkg" / "macros" / "custom_tests.sql").write_text(
            """{% test nonzero_amount(model, column_name) %}
select {{ column_name }}
from {{ model }}
where {{ column_name }} = 0
{% endtest %}
"""
        )
        dbt_profiles = tmp_path / "dbt-profiles"
        dbt_profiles.mkdir()
        (dbt_profiles / "profiles.yml").write_text(
            "\n".join(
                [
                    "source_seed_custom_generic_test_compile:",
                    "  target: dev",
                    "  outputs:",
                    "    dev:",
                    "      type: duckdb",
                    f"      path: {tmp_path / 'oracle.duckdb'}",
                    "      schema: main",
                ]
            )
            + "\n"
        )
        dbt_target = tmp_path / "dbt-target"
        original_message_to_json = protobuf_json_format.MessageToJson
        original_event_message_to_json = dbt_event_base_types.MessageToJson

        def compatible_message_to_json(message, *args, always_print_fields_with_no_presence=None, **kwargs):
            if always_print_fields_with_no_presence is not None and "including_default_value_fields" not in kwargs:
                kwargs["including_default_value_fields"] = always_print_fields_with_no_presence
            return original_message_to_json(message, *args, **kwargs)

        protobuf_json_format.MessageToJson = compatible_message_to_json
        dbt_event_base_types.MessageToJson = compatible_message_to_json
        try:
            dbt_result = dbtRunner().invoke(
                [
                    "compile",
                    "--project-dir",
                    str(project),
                    "--profiles-dir",
                    str(dbt_profiles),
                    "--target-path",
                    str(dbt_target),
                    "--select",
                    "test_type:generic",
                ]
            )
        finally:
            protobuf_json_format.MessageToJson = original_message_to_json
            dbt_event_base_types.MessageToJson = original_event_message_to_json
        assert dbt_result.success, dbt_result.exception
        dbt_manifest = json.loads((dbt_target / "manifest.json").read_text())
        dbt_tests = {node["test_metadata"]["name"]: node for node in dbt_manifest["nodes"].values() if node["resource_type"] == "test"}
        dbt_source = dbt_tests["positive_amount"]
        dbt_seed = dbt_tests["nonzero_amount"]
        for dxt_node, dbt_node in [(source_test, dbt_source), (seed_test, dbt_seed)]:
            assert dxt_node["unique_id"] == dbt_node["unique_id"]
            assert dxt_node["raw_code"] == dbt_node["raw_code"]
            assert dxt_node["test_metadata"] == dbt_node["test_metadata"]
            assert dxt_node["attached_node"] == dbt_node["attached_node"]
            assert dxt_node["depends_on"] == dbt_node["depends_on"]
            assert dxt_node["compiled"] == dbt_node["compiled"]
            assert "{{" not in dbt_node["compiled_code"]
            assert "{%" not in dbt_node["compiled_code"]


def test_compile_rejects_unsupported_custom_generic_test_body(tmp_path: Path):
    project = copy_fixture(tmp_path, "custom_generic_test_compile")
    (project / "macros" / "custom_tests.sql").write_text(
        """{% test positive_amount(model, column_name) %}
{% if true %}
select {{ column_name }} from {{ model }}
{% endif %}
{% endtest %}
"""
    )
    target = tmp_path / "compile-target"
    result = subprocess.run(
        [DXT, "compile", "--project-dir", str(project), "--target-path", str(target), "--select", "positive_amount_orders_amount"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "custom generic test compilation currently supports only model, seed, or source column test blocks" in result.stderr


def test_test_and_build_reject_custom_generic_tests_before_runtime(tmp_path: Path):
    project = copy_fixture(tmp_path, "custom_generic_test_compile")
    test_target = tmp_path / "test-target"
    test_result = subprocess.run(
        [DXT, "test", "--project-dir", str(project), "--target-path", str(test_target), "--select", "test_type:generic"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert test_result.returncode == 2
    assert "test/build currently executes only selected DuckDB singular SQL tests" in test_result.stderr
    assert not (test_target / "run_results.json").exists()

    build_target = tmp_path / "build-target"
    build_result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(build_target), "--select", "test_type:generic"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert build_result.returncode == 2
    assert "test/build currently executes only selected DuckDB singular SQL tests" in build_result.stderr
    assert not (build_target / "run_results.json").exists()


def test_test_and_build_reject_package_custom_generic_tests_before_runtime(tmp_path: Path):
    project = copy_fixture(tmp_path, "package_custom_generic_test_compile")
    test_target = tmp_path / "test-target"
    test_result = subprocess.run(
        [DXT, "test", "--project-dir", str(project), "--target-path", str(test_target), "--select", "test_type:generic"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert test_result.returncode == 2
    assert "test/build currently executes only selected DuckDB singular SQL tests" in test_result.stderr
    assert not (test_target / "run_results.json").exists()

    build_target = tmp_path / "build-target"
    build_result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(build_target), "--select", "test_type:generic"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert build_result.returncode == 2
    assert "test/build currently executes only selected DuckDB singular SQL tests" in build_result.stderr
    assert not (build_target / "run_results.json").exists()


def test_test_and_build_reject_source_seed_custom_generic_tests_before_runtime(tmp_path: Path):
    project = copy_fixture(tmp_path, "source_seed_custom_generic_test_compile")
    test_target = tmp_path / "test-target"
    test_result = subprocess.run(
        [DXT, "test", "--project-dir", str(project), "--target-path", str(test_target), "--select", "test_type:generic"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert test_result.returncode == 2
    assert "test/build currently executes only selected DuckDB singular SQL tests" in test_result.stderr
    assert not (test_target / "run_results.json").exists()

    build_target = tmp_path / "build-target"
    build_result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(build_target), "--select", "test_type:generic"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert build_result.returncode == 2
    assert "test/build currently executes only selected DuckDB singular SQL tests" in build_result.stderr
    assert not (build_target / "run_results.json").exists()


def test_compile_injects_ephemeral_ctes_and_manifest_fields(tmp_path: Path):
    project = copy_fixture(tmp_path, "ephemeral_cte")
    target = tmp_path / "compile-target"
    result = subprocess.run(
        [DXT, "compile", "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Compiled 2 model(s)" in result.stdout

    compiled_root = target / "compiled" / "ephemeral_cte" / "models"
    assert not (compiled_root / "base_ephemeral.sql").exists()
    assert not (compiled_root / "filtered_ephemeral.sql").exists()
    one_level_sql = (compiled_root / "final_one_level.sql").read_text()
    chain_sql = (compiled_root / "final_chain.sql").read_text()
    assert one_level_sql.count("__dbt__cte__base_ephemeral as") == 1
    assert "from __dbt__cte__base_ephemeral" in one_level_sql
    assert "__dbt__cte__base_ephemeral as" in chain_sql
    assert "__dbt__cte__filtered_ephemeral as" in chain_sql
    assert chain_sql.index("__dbt__cte__base_ephemeral as") < chain_sql.index("__dbt__cte__filtered_ephemeral as")
    assert "from __dbt__cte__base_ephemeral" in chain_sql
    assert "from __dbt__cte__filtered_ephemeral" in chain_sql
    assert "{{" not in chain_sql
    assert "{%" not in chain_sql

    manifest_path = target / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    assert_manifest_schema_slice(manifest_path)
    assert manifest["nodes"]["model.ephemeral_cte.base_ephemeral"]["config"]["materialized"] == "ephemeral"
    assert manifest["nodes"]["model.ephemeral_cte.filtered_ephemeral"]["config"]["materialized"] == "ephemeral"
    assert "compiled" not in manifest["nodes"]["model.ephemeral_cte.base_ephemeral"]
    final_one = manifest["nodes"]["model.ephemeral_cte.final_one_level"]
    final_chain = manifest["nodes"]["model.ephemeral_cte.final_chain"]
    assert final_one["extra_ctes_injected"] is True
    assert [cte["id"] for cte in final_one["extra_ctes"]] == ["model.ephemeral_cte.base_ephemeral"]
    assert final_one["compiled_code"] == one_level_sql
    assert final_chain["extra_ctes_injected"] is True
    assert [cte["id"] for cte in final_chain["extra_ctes"]] == [
        "model.ephemeral_cte.base_ephemeral",
        "model.ephemeral_cte.filtered_ephemeral",
    ]
    assert final_chain["compiled_code"] == chain_sql
    assert final_chain["compiled_path"].endswith("/compiled/ephemeral_cte/models/final_chain.sql")


def test_docs_generate_uses_ephemeral_cte_compile_path(tmp_path: Path):
    project = copy_fixture(tmp_path, "ephemeral_cte")
    target = tmp_path / "docs-target"
    result = subprocess.run(
        [DXT, "docs", "generate", "--project-dir", str(project), "--target-path", str(target), "--select", "final_chain"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    compiled = (target / "compiled" / "ephemeral_cte" / "models" / "final_chain.sql").read_text()
    assert "__dbt__cte__base_ephemeral as" in compiled
    assert "__dbt__cte__filtered_ephemeral as" in compiled
    manifest = json.loads((target / "manifest.json").read_text())
    assert manifest["nodes"]["model.ephemeral_cte.final_chain"]["extra_ctes_injected"] is True


def test_parse_list_and_compile_analysis_resources(tmp_path: Path):
    project = copy_fixture(tmp_path, "analysis_basic")
    parse_target = tmp_path / "parse-target"
    parse_result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", str(parse_target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert parse_result.returncode == 0, parse_result.stderr
    assert "1 analysis(es)" in parse_result.stdout

    parse_manifest_path = parse_target / "manifest.json"
    parse_manifest = json.loads(parse_manifest_path.read_text())
    assert_partial_manifest_schema(parse_manifest)
    assert_manifest_schema_slice(parse_manifest_path)
    analysis_id = "analysis.analysis_basic.customer_report"
    analysis = parse_manifest["nodes"][analysis_id]
    assert analysis["resource_type"] == "analysis"
    assert analysis["database"] == "memory"
    assert analysis["schema"] == "main"
    assert analysis["alias"] == "customer_report"
    assert analysis["fqn"] == ["analysis_basic", "analysis", "customer_report"]
    assert analysis["checksum"] == dbt_sha256_text((project / "analyses" / "customer_report.sql").read_text())
    assert analysis["path"] == "analysis/customer_report.sql"
    assert analysis["original_file_path"] == "analyses/customer_report.sql"
    assert analysis["description"] == "Customer report analysis"
    assert analysis["config"]["materialized"] == "analysis"
    assert analysis["config"]["tags"] == ["reporting"]
    assert analysis["columns"]["customer_id"]["description"] == "Customer identifier"
    assert analysis["refs"] == [{"name": "customers", "package": None, "version": None}]
    assert analysis["sources"] == [["raw", "payments"]]
    assert analysis["depends_on"]["nodes"] == [
        "model.analysis_basic.customers",
        "source.analysis_basic.raw.payments",
    ]

    ls_result = subprocess.run(
        [
            DXT,
            "ls",
            "--project-dir",
            str(project),
            "--resource-type",
            "analysis",
            "--output",
            "json",
            "--output-keys",
            "unique_id",
            "resource_type",
            "name",
            "path",
            "config.materialized",
            "config.tags",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_result.returncode == 0, ls_result.stderr
    assert json.loads(ls_result.stdout) == [
        {
            "unique_id": analysis_id,
            "resource_type": "analysis",
            "name": "customer_report",
            "path": "analysis/customer_report.sql",
            "config.materialized": "analysis",
            "config.tags": ["reporting"],
        }
    ]

    compile_target = tmp_path / "compile-target"
    compile_result = subprocess.run(
        [
            DXT,
            "compile",
            "--project-dir",
            str(project),
            "--target-path",
            str(compile_target),
            "--select",
            "resource_type:analysis",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert compile_result.returncode == 0, compile_result.stderr
    assert "Compiled 0 model(s), 1 analysis(es), and 0 test(s)" in compile_result.stdout
    compiled_sql = (compile_target / "compiled" / "analysis_basic" / "analysis" / "customer_report.sql").read_text()
    assert 'from "main"."customers"' in compiled_sql
    assert 'from "raw"."payments"' in compiled_sql
    compile_manifest = json.loads((compile_target / "manifest.json").read_text())
    compiled_analysis = compile_manifest["nodes"][analysis_id]
    assert compiled_analysis["compiled"] is True
    assert compiled_analysis["compiled_code"] == compiled_sql
    assert compiled_analysis["compiled_path"].endswith("/compiled/analysis_basic/analysis/customer_report.sql")
    assert compiled_analysis["relation_name"] is None


def write_static_loop_project(project: Path) -> None:
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: static_loop_compile
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "payments.sql").write_text(
        """{{ config(materialized='table') }}
select 1 as order_id, 'credit_card' as payment_method, 10 as amount
union all
select 1 as order_id, 'coupon' as payment_method, 2 as amount
"""
    )
    (project / "models" / "orders.sql").write_text(
        """{{ config(materialized='table') }}
{% set payment_methods = ['credit_card', 'coupon'] %}
with payments as (
    select * from {{ ref('payments') }}
),
order_payments as (
    select
        order_id,
        {% for payment_method in payment_methods -%}
        sum(case when payment_method = '{{ payment_method }}' then amount else 0 end) as {{ payment_method }}_amount,
        {% endfor -%}
        sum(amount) as total_amount
    from payments
    group by order_id
)
select * from order_payments
"""
    )


def test_compile_expands_static_jinja_set_for_loop(tmp_path: Path):
    project = tmp_path / "static_loop_compile"
    write_static_loop_project(project)
    target = tmp_path / "compile-target"
    result = subprocess.run(
        [DXT, "compile", "--project-dir", str(project), "--target-path", str(target), "--select", "orders"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    compiled = (target / "compiled" / "static_loop_compile" / "models" / "orders.sql").read_text()
    assert "credit_card_amount" in compiled
    assert "coupon_amount" in compiled
    assert "{{" not in compiled
    assert "{%" not in compiled


def write_static_if_project(project: Path) -> None:
    (project / "models").mkdir(parents=True)
    (project / "models" / "schema.yml").write_text(
        """version: 2

sources:
  - name: raw
    tables:
      - name: events
"""
    )
    (project / "dbt_project.yml").write_text(
        """name: static_if_compile
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "customers.sql").write_text("select 1 as id\n")
    (project / "models" / "events.sql").write_text(
        """select 1 as id
{% if execute %}
union all select * from {{ ref('customers') }}
union all select * from {{ source('raw', 'events') }}
{% else %}
union all select 0 as id
{% endif %}
{% if not is_incremental() %}
where id >= 0
{% endif %}
"""
    )


def test_compile_renders_static_if_without_losing_parse_dependencies(tmp_path: Path):
    project = tmp_path / "static_if_compile"
    write_static_if_project(project)
    target = tmp_path / "compile-target"
    result = subprocess.run(
        [DXT, "compile", "--project-dir", str(project), "--target-path", str(target), "--select", "events"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr

    compiled = (target / "compiled" / "static_if_compile" / "models" / "events.sql").read_text()
    assert 'union all select * from "main"."customers"' in compiled
    assert 'union all select * from "raw"."events"' in compiled
    assert "where id >= 0" in compiled
    assert "union all select 0 as id" not in compiled
    assert "{{" not in compiled
    assert "{%" not in compiled

    manifest = json.loads((target / "manifest.json").read_text())
    events = manifest["nodes"]["model.static_if_compile.events"]
    assert events["depends_on"]["nodes"] == [
        "model.static_if_compile.customers",
        "source.static_if_compile.raw.events",
    ]
    assert events["refs"] == [{"name": "customers", "package": None, "version": None}]
    assert events["sources"] == [["raw", "events"]]


def test_parse_time_context_keeps_execute_false_boundary_and_static_dependencies(tmp_path: Path):
    project = copy_fixture(tmp_path, "parse_time_context")
    parse_target = tmp_path / "parse-target"
    parse_result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", str(parse_target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert parse_result.returncode == 0, parse_result.stderr

    parse_manifest_path = parse_target / "manifest.json"
    assert_manifest_schema_slice(parse_manifest_path)
    parse_manifest = json.loads(parse_manifest_path.read_text())
    parsed = parse_manifest["nodes"]["model.parse_time_context.context_orders"]
    assert parsed["config"]["materialized"] == "table"
    assert parsed["config"]["tags"] == ["parse_time"]
    assert parsed["depends_on"]["nodes"] == [
        "model.parse_time_context.customers",
        "source.parse_time_context.raw.events",
    ]
    assert parsed["refs"] == [{"name": "customers", "package": None, "version": None}]
    assert parsed["sources"] == [["raw", "events"]]

    compile_target = tmp_path / "compile-target"
    compile_result = subprocess.run(
        [DXT, "compile", "--project-dir", str(project), "--target-path", str(compile_target), "--select", "context_orders"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert compile_result.returncode == 0, compile_result.stderr

    compiled = (compile_target / "compiled" / "parse_time_context" / "models" / "context_orders.sql").read_text()
    assert 'union all select * from "main"."customers"' in compiled
    assert 'union all select * from "raw"."events"' not in compiled
    assert "{{" not in compiled
    assert "{%" not in compiled

    compile_manifest = json.loads((compile_target / "manifest.json").read_text())
    compiled_node = compile_manifest["nodes"]["model.parse_time_context.context_orders"]
    assert compiled_node["depends_on"]["nodes"] == parsed["depends_on"]["nodes"]


def write_source_identifier_project(project: Path) -> None:
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: source_identifier
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "schema.yml").write_text(
        """version: 2

sources:
  - name: raw
    schema: raw
    tables:
      - name: customers
        identifier: raw_customers
        loaded_at_field: loaded_at
        freshness:
          warn_after:
            count: 1
            period: hour
          error_after:
            count: 1
            period: day
        columns:
          - name: customer_id
"""
    )
    (project / "models" / "stg_customers.sql").write_text(
        """select *
from {{ source('raw', 'customers') }}
"""
    )


def write_source_relation_config_project(project: Path) -> None:
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: source_relation_config
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "schema.yml").write_text(
        """version: 2

sources:
  - name: raw
    database: ignored_catalog
    schema: Raw
    quoting:
      database: true
      schema: true
      identifier: true
    tables:
      - name: customers
        database: dxt
        identifier: RawCustomers
        quoting:
          database: false
          identifier: false
        loaded_at_field: loaded_at
        freshness:
          warn_after:
            count: 1
            period: hour
          error_after:
            count: 1
            period: day
        columns:
          - name: customer_id
            tests:
              - not_null
"""
    )
    (project / "models" / "stg_customers.sql").write_text(
        """select *
from {{ source('raw', 'customers') }}
"""
    )


def write_project_level_source_config_project(project: Path) -> None:
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: project_level_source_config
version: "1.0"
model-paths: ["models"]
target-path: target
sources:
  project_level_source_config:
    +database: dxt
    +quoting:
      database: false
      schema: true
      identifier: false
    raw:
      +schema: Raw
      +loaded_at_field: project_loaded_at
      +freshness:
        warn_after:
          count: 1
          period: hour
        error_after:
          count: 1
          period: day
      customers:
        +identifier: RawCustomers
      orders:
        +identifier: RawOrders
        +loaded_at_query: select max(project_loaded_at) from "Raw".RawOrders
        +freshness:
          warn_after:
            count: 3
            period: hour
"""
    )
    (project / "models" / "schema.yml").write_text(
        """version: 2

sources:
  - name: raw
    tables:
      - name: customers
        columns:
          - name: customer_id
            tests:
              - not_null
      - name: orders
        loaded_at_field: yaml_loaded_at
        freshness:
          error_after:
            count: 2
            period: day
        columns:
          - name: order_id
            tests:
              - not_null
"""
    )
    (project / "models" / "stg_sources.sql").write_text(
        """select customer_id as id, project_loaded_at as loaded_at
from {{ source('raw', 'customers') }}
union all
select order_id as id, yaml_loaded_at as loaded_at
from {{ source('raw', 'orders') }}
"""
    )


def test_source_identifier_compiles_physical_relation_and_preserves_logical_source_key(tmp_path: Path):
    project = tmp_path / "source_identifier"
    write_source_identifier_project(project)
    target = tmp_path / "compile-target"
    result = subprocess.run(
        [DXT, "compile", "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr

    compiled = (target / "compiled" / "source_identifier" / "models" / "stg_customers.sql").read_text()
    assert 'from "raw"."raw_customers"' in compiled
    assert 'from "raw"."customers"' not in compiled

    manifest_path = target / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    assert_manifest_schema_slice(manifest_path)
    source = manifest["sources"]["source.source_identifier.raw.customers"]
    assert source["name"] == "customers"
    assert source["identifier"] == "raw_customers"
    assert source["relation_name"] == '"raw"."raw_customers"'
    assert source["fqn"] == ["source_identifier", "raw", "customers"]
    model = manifest["nodes"]["model.source_identifier.stg_customers"]
    assert model["depends_on"]["nodes"] == ["source.source_identifier.raw.customers"]
    assert model["sources"] == [["raw", "customers"]]

    listed = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "source:raw.customers", "--output", "name"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert listed.returncode == 0, listed.stderr
    assert listed.stdout.splitlines() == ["raw.customers"]


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for source identifier execution coverage")
def test_source_identifier_drives_duckdb_catalog_and_freshness_relations(tmp_path: Path):
    project = tmp_path / "source_identifier"
    write_source_identifier_project(project)
    target = tmp_path / "target"
    target.mkdir()
    db_path = target / "dxt.duckdb"
    subprocess.run(
        [
            DUCKDB,
            str(db_path),
            "-batch",
            "-bail",
            "-c",
            "create schema raw; create table raw.raw_customers as select 1 as customer_id, current_timestamp as loaded_at;",
        ],
        cwd=ROOT,
        check=True,
        text=True,
        capture_output=True,
    )

    docs_result = subprocess.run(
        [
            DXT,
            "docs",
            "generate",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "source:raw.customers",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert docs_result.returncode == 0, docs_result.stderr
    catalog_path = target / "catalog.json"
    assert_catalog_schema_slice(catalog_path)
    catalog = json.loads(catalog_path.read_text())
    source_catalog = catalog["sources"]["source.source_identifier.raw.customers"]
    assert source_catalog["metadata"]["schema"] == "raw"
    assert source_catalog["metadata"]["name"] == "raw_customers"
    assert list(source_catalog["columns"]) == ["customer_id", "loaded_at"]

    freshness_result = subprocess.run(
        [
            DXT,
            "source",
            "freshness",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "source:raw.customers",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert freshness_result.returncode == 0, freshness_result.stderr
    sources_path = target / "sources.json"
    assert_sources_schema_slice(sources_path)
    sources = json.loads(sources_path.read_text())
    assert [row["unique_id"] for row in sources["results"]] == ["source.source_identifier.raw.customers"]
    assert sources["results"][0]["status"] == "pass"


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for source relation config execution coverage")
def test_source_database_and_quoting_drive_compile_catalog_freshness_and_tests(tmp_path: Path):
    project = tmp_path / "source_relation_config"
    write_source_relation_config_project(project)
    target = tmp_path / "target"
    target.mkdir()
    db_path = target / "dxt.duckdb"
    subprocess.run(
        [
            DUCKDB,
            str(db_path),
            "-batch",
            "-bail",
            "-c",
            'create schema "Raw"; create table "Raw"."RawCustomers" as select 1 as customer_id, current_timestamp as loaded_at;',
        ],
        cwd=ROOT,
        check=True,
        text=True,
        capture_output=True,
    )

    compile_result = subprocess.run(
        [DXT, "compile", "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert compile_result.returncode == 0, compile_result.stderr
    compiled = (target / "compiled" / "source_relation_config" / "models" / "stg_customers.sql").read_text()
    assert "from dxt.\"Raw\".RawCustomers" in compiled

    manifest_path = target / "manifest.json"
    assert_manifest_schema_slice(manifest_path)
    manifest = json.loads(manifest_path.read_text())
    source = manifest["sources"]["source.source_relation_config.raw.customers"]
    assert source["database"] == "dxt"
    assert source["schema"] == "Raw"
    assert source["identifier"] == "RawCustomers"
    assert source["relation_name"] == 'dxt."Raw".RawCustomers'
    assert source["quoting"] == {"database": False, "schema": True, "identifier": False, "column": None}

    docs_result = subprocess.run(
        [DXT, "docs", "generate", "--project-dir", str(project), "--target-path", str(target), "--select", "source:raw.customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert docs_result.returncode == 0, docs_result.stderr
    catalog_path = target / "catalog.json"
    assert_catalog_schema_slice(catalog_path)
    catalog = json.loads(catalog_path.read_text())
    source_catalog = catalog["sources"]["source.source_relation_config.raw.customers"]
    assert source_catalog["metadata"]["database"] == "dxt"
    assert source_catalog["metadata"]["schema"] == "Raw"
    assert source_catalog["metadata"]["name"] == "RawCustomers"
    assert list(source_catalog["columns"]) == ["customer_id", "loaded_at"]

    freshness_result = subprocess.run(
        [DXT, "source", "freshness", "--project-dir", str(project), "--target-path", str(target), "--select", "source:raw.customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert freshness_result.returncode == 0, freshness_result.stderr
    assert_sources_schema_slice(target / "sources.json")
    sources = json.loads((target / "sources.json").read_text())
    assert sources["results"][0]["unique_id"] == "source.source_relation_config.raw.customers"
    assert sources["results"][0]["status"] == "pass"

    test_result = subprocess.run(
        [DXT, "test", "--project-dir", str(project), "--target-path", str(target), "--select", "source_not_null_raw_customers_customer_id"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert test_result.returncode == 0, test_result.stderr
    run_results = json.loads((target / "run_results.json").read_text())
    source_tests = [row for row in run_results["results"] if row["unique_id"].startswith("test.source_relation_config.source_not_null_raw_customers_customer_id.")]
    assert len(source_tests) == 1
    assert "from dxt.\"Raw\".RawCustomers" in source_tests[0]["compiled_code"]


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for project-level source config execution coverage")
def test_project_level_source_config_inherits_into_freshness_docs_and_tests(tmp_path: Path):
    project = tmp_path / "project_level_source_config"
    write_project_level_source_config_project(project)
    target = tmp_path / "target"
    target.mkdir()
    db_path = target / "dxt.duckdb"
    subprocess.run(
        [
            DUCKDB,
            str(db_path),
            "-batch",
            "-bail",
            "-c",
            'create schema "Raw"; create table "Raw".RawCustomers as select 1 as customer_id, current_timestamp as project_loaded_at; create table "Raw".RawOrders as select 10 as order_id, current_timestamp as project_loaded_at, current_timestamp as yaml_loaded_at;',
        ],
        cwd=ROOT,
        check=True,
        text=True,
        capture_output=True,
    )

    compile_result = subprocess.run(
        [DXT, "compile", "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert compile_result.returncode == 0, compile_result.stderr
    compiled = (target / "compiled" / "project_level_source_config" / "models" / "stg_sources.sql").read_text()
    assert "from dxt.\"Raw\".RawCustomers" in compiled
    assert "from dxt.\"Raw\".RawOrders" in compiled

    manifest_path = target / "manifest.json"
    assert_manifest_schema_slice(manifest_path)
    manifest = json.loads(manifest_path.read_text())
    customers = manifest["sources"]["source.project_level_source_config.raw.customers"]
    assert customers["database"] == "dxt"
    assert customers["schema"] == "Raw"
    assert customers["identifier"] == "RawCustomers"
    assert customers["loaded_at_field"] == "project_loaded_at"
    assert customers["loaded_at_query"] is None
    assert customers["freshness"]["warn_after"] == {"count": 1, "period": "hour"}
    orders = manifest["sources"]["source.project_level_source_config.raw.orders"]
    assert orders["identifier"] == "RawOrders"
    assert orders["loaded_at_field"] == "yaml_loaded_at"
    assert orders["loaded_at_query"] is None
    assert orders["freshness"]["warn_after"] == {"count": 3, "period": "hour"}
    assert orders["freshness"]["error_after"] == {"count": 2, "period": "day"}

    docs_result = subprocess.run(
        [DXT, "docs", "generate", "--project-dir", str(project), "--target-path", str(target), "--select", "source:raw"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert docs_result.returncode == 0, docs_result.stderr
    catalog_path = target / "catalog.json"
    assert_catalog_schema_slice(catalog_path)
    catalog = json.loads(catalog_path.read_text())
    assert catalog["sources"]["source.project_level_source_config.raw.customers"]["metadata"]["name"] == "RawCustomers"
    assert catalog["sources"]["source.project_level_source_config.raw.orders"]["metadata"]["name"] == "RawOrders"

    freshness_result = subprocess.run(
        [DXT, "source", "freshness", "--project-dir", str(project), "--target-path", str(target), "--select", "source:raw"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert freshness_result.returncode == 0, freshness_result.stderr
    assert_sources_schema_slice(target / "sources.json")
    sources = json.loads((target / "sources.json").read_text())
    assert [row["unique_id"] for row in sources["results"]] == [
        "source.project_level_source_config.raw.customers",
        "source.project_level_source_config.raw.orders",
    ]
    assert {row["status"] for row in sources["results"]} == {"pass"}

    test_result = subprocess.run(
        [DXT, "test", "--project-dir", str(project), "--target-path", str(target), "--select", "source_not_null_raw_customers_customer_id"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert test_result.returncode == 0, test_result.stderr
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    source_tests = [row for row in run_results["results"] if row["unique_id"].startswith("test.project_level_source_config.source_not_null_raw_customers_customer_id.")]
    assert len(source_tests) == 1
    assert "from dxt.\"Raw\".RawCustomers" in source_tests[0]["compiled_code"]


def test_compile_and_docs_generate_render_jaffle_style_macro_dispatch(tmp_path: Path):
    project = copy_fixture(tmp_path, "macro_dispatch_compile")

    compile_target = tmp_path / "compile-target"
    compile_result = subprocess.run(
        [DXT, "compile", "--project-dir", str(project), "--target-path", str(compile_target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert compile_result.returncode == 0, compile_result.stderr
    compiled_path = compile_target / "compiled" / "macro_dispatch_compile" / "models" / "orders.sql"
    compiled = compiled_path.read_text()
    assert "(subtotal / 100)::numeric(16, 2)" in compiled
    assert "{{" not in compiled
    assert "{%" not in compiled

    manifest_path = compile_target / "manifest.json"
    assert_manifest_schema_slice(manifest_path)
    manifest = json.loads(manifest_path.read_text())
    assert manifest["nodes"]["model.macro_dispatch_compile.orders"]["depends_on"]["macros"] == [
        "macro.macro_dispatch_compile.cents_to_dollars"
    ]
    assert manifest["macros"]["macro.macro_dispatch_compile.cents_to_dollars"]["depends_on"]["macros"] == [
        "macro.macro_dispatch_compile.default__cents_to_dollars"
    ]
    assert manifest["nodes"]["model.macro_dispatch_compile.orders"]["compiled_code"] == compiled

    docs_target = tmp_path / "docs-target"
    docs_result = subprocess.run(
        [DXT, "docs", "generate", "--project-dir", str(project), "--target-path", str(docs_target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert docs_result.returncode == 0, docs_result.stderr
    docs_compiled = docs_target / "compiled" / "macro_dispatch_compile" / "models" / "orders.sql"
    assert "(subtotal / 100)::numeric(16, 2)" in docs_compiled.read_text()


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for macro-dispatch run/build execution coverage")
def test_run_and_build_execute_jaffle_style_macro_dispatch(tmp_path: Path):
    project = copy_fixture(tmp_path, "macro_dispatch_compile")
    for command in ("run", "build"):
        target = tmp_path / f"{command}-target"
        result = subprocess.run(
            [DXT, command, "--project-dir", str(project), "--target-path", str(target)],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        assert result.returncode == 0, result.stderr
        assert_run_results_schema_slice(target / "run_results.json")

        query = subprocess.run(
            [
                DUCKDB,
                str(target / "dxt.duckdb"),
                "-csv",
                "-noheader",
                "-c",
                'select order_id, subtotal from "main"."orders"',
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        assert query.returncode == 0, query.stderr
        assert query.stdout.strip() == "1,12.50"


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M2 static loop build execution coverage")
def test_build_executes_model_with_static_jinja_set_for_loop(tmp_path: Path):
    project = tmp_path / "static_loop_compile"
    write_static_loop_project(project)
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "+orders"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Built 2 model(s) and 0 test(s)" in result.stdout

    query = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-csv", "-noheader", "-c", 'select credit_card_amount, coupon_amount, total_amount from "main"."orders"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert query.returncode == 0, query.stderr
    assert query.stdout.strip() == "10,2,12"


def assert_profile_target_context_outputs(target: Path, command_name: str) -> None:
    compiled_root = target / "compiled" / "profile_target_context" / "models"
    current_sql = (compiled_root / "current_context.sql").read_text()
    assert "'profile_target_context' as profile_name" in current_sql
    assert "'pg' as target_name" in current_sql
    assert "'pg' as target_name_alias" in current_sql
    assert "'postgres' as adapter_type" in current_sql
    assert "'analytics' as target_schema" in current_sql
    assert "'analytics' as this_schema" in current_sql
    assert "'current_context' as this_name" in current_sql
    assert "'current_context' as this_table" in current_sql
    assert "'current_context' as this_identifier" in current_sql
    assert 'from "analytics"."current_context"' in current_sql
    assert (compiled_root / "downstream.sql").read_text().strip() == 'select *\nfrom "analytics"."current_context"'

    manifest_path = target / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    assert_partial_manifest_schema(manifest)
    assert_manifest_schema_slice(manifest_path)
    current = manifest["nodes"]["model.profile_target_context.current_context"]
    downstream = manifest["nodes"]["model.profile_target_context.downstream"]
    assert current["relation_name"] == '"analytics"."current_context"'
    assert downstream["compiled_code"].strip() == 'select *\nfrom "analytics"."current_context"'
    if command_name == "docs generate":
        assert (target / "catalog.json").exists()
    else:
        assert not (target / "run_results.json").exists()


def test_compile_docs_run_and_build_render_profile_target_and_this_context(tmp_path: Path):
    project = copy_fixture(tmp_path, "profile_target_context")
    commands = [
        ("compile", [DXT, "compile"], 0),
        ("docs generate", [DXT, "docs", "generate"], 0),
        ("run", [DXT, "run"], 2),
        ("build", [DXT, "build"], 2),
    ]
    for index, (command_name, command, expected_returncode) in enumerate(commands):
        target = tmp_path / f"profile-target-{index}"
        result = subprocess.run(
            [
                *command,
                "--project-dir",
                str(project),
                "--profiles-dir",
                str(project),
                "--target",
                "pg",
                "--target-path",
                str(target),
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        assert result.returncode == expected_returncode, result.stderr
        assert_profile_target_context_outputs(target, command_name)


def assert_inline_relation_outputs(target: Path, command_name: str) -> None:
    compiled_root = target / "compiled" / "inline_relation_config" / "models"
    orders_sql = (compiled_root / "orders.sql").read_text()
    assert "'analytics_mart' as this_schema" in orders_sql
    assert "'order_facts' as this_name" in orders_sql
    assert "'order_facts' as this_identifier" in orders_sql
    assert 'from "analytics_mart"."order_facts"' in orders_sql
    assert 'from "analytics"."base_orders"' in orders_sql
    assert (compiled_root / "uses_orders.sql").read_text().strip() == 'select *\nfrom "analytics_mart"."order_facts"'

    manifest_path = target / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    assert_partial_manifest_schema(manifest)
    assert_manifest_schema_slice(manifest_path)
    orders = manifest["nodes"]["model.inline_relation_config.orders"]
    uses_orders = manifest["nodes"]["model.inline_relation_config.uses_orders"]
    assert orders["database"] == "memory"
    assert orders["schema"] == "analytics_mart"
    assert orders["alias"] == "order_facts"
    assert orders["fqn"] == ["inline_relation_config", "orders"]
    assert orders["checksum"] == dbt_sha256_text((ROOT / "tests" / "fixtures" / "inline_relation_config" / "models" / "orders.sql").read_text())
    assert orders["relation_name"] == '"analytics_mart"."order_facts"'
    assert uses_orders["compiled_code"].strip() == 'select *\nfrom "analytics_mart"."order_facts"'
    if command_name == "docs generate":
        assert (target / "catalog.json").exists()
    elif command_name in {"run", "build"} and DUCKDB is not None:
        assert_run_results_schema_slice(target / "run_results.json")
        run_results = json.loads((target / "run_results.json").read_text())
        assert [item["unique_id"] for item in run_results["results"]] == [
            "model.inline_relation_config.base_orders",
            "model.inline_relation_config.orders",
            "model.inline_relation_config.uses_orders",
        ]
        assert [item["status"] for item in run_results["results"]] == ["success", "error", "skipped"]
        assert run_results["results"][1]["message"] == "DuckDB execution failed"
        assert run_results["results"][2]["message"] is None
    else:
        assert not (target / "run_results.json").exists()


def test_compile_docs_run_and_build_apply_inline_schema_and_alias_to_relations(tmp_path: Path):
    project = copy_fixture(tmp_path, "inline_relation_config")
    commands = [
        ("compile", [DXT, "compile"], 0),
        ("docs generate", [DXT, "docs", "generate"], 0),
        ("run", [DXT, "run"], 1 if DUCKDB is not None else 2),
        ("build", [DXT, "build"], 1 if DUCKDB is not None else 2),
    ]
    for index, (command_name, command, expected_returncode) in enumerate(commands):
        target = tmp_path / f"inline-relation-{index}"
        result = subprocess.run(
            [
                *command,
                "--project-dir",
                str(project),
                "--profiles-dir",
                str(project),
                "--target-path",
                str(target),
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        assert result.returncode == expected_returncode, result.stderr
        if expected_returncode == 0:
            assert result.stderr == ""
        assert_inline_relation_outputs(target, command_name)


def test_compile_docs_run_and_build_resolve_cli_vars(tmp_path: Path):
    project = copy_fixture(tmp_path, "dynamic_var_ref")

    compile_target = tmp_path / "compile-target"
    compile_result = subprocess.run(
        [
            DXT,
            "compile",
            "--project-dir",
            str(project),
            "--target-path",
            str(compile_target),
            "--select",
            "orders",
            "--vars",
            '{"customer_model": "alt_customers"}',
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert compile_result.returncode == 0, compile_result.stderr
    assert 'from "main"."alt_customers"' in (
        compile_target / "compiled" / "dynamic_var_ref" / "models" / "orders.sql"
    ).read_text()
    compile_manifest = json.loads((compile_target / "manifest.json").read_text())
    assert compile_manifest["nodes"]["model.dynamic_var_ref.orders"]["depends_on"]["nodes"] == [
        "model.dynamic_var_ref.alt_customers"
    ]

    docs_target = tmp_path / "docs-target"
    docs_result = subprocess.run(
        [
            DXT,
            "docs",
            "generate",
            "--project-dir",
            str(project),
            "--target-path",
            str(docs_target),
            "--select",
            "from_source",
            "--vars",
            '{"raw_table": "transactions"}',
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert docs_result.returncode == 0, docs_result.stderr
    assert 'from "raw"."transactions"' in (
        docs_target / "compiled" / "dynamic_var_ref" / "models" / "from_source.sql"
    ).read_text()

    run_target = tmp_path / "run-target"
    run_result = subprocess.run(
        [
            DXT,
            "run",
            "--project-dir",
            str(project),
            "--target-path",
            str(run_target),
            "--select",
            "+orders",
            "--vars",
            '{"customer_model": "alt_customers"}',
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    if DUCKDB is None:
        assert run_result.returncode == 2
        assert "DuckDB execution requires the duckdb CLI" in run_result.stderr
    else:
        assert run_result.returncode == 0, run_result.stderr
        assert "Ran 2 model(s)" in run_result.stdout
        assert_run_results_schema_slice(run_target / "run_results.json")
        query = subprocess.run(
            [DUCKDB, str(run_target / "dxt.duckdb"), "-csv", "-noheader", "-c", 'select customer_id from "main"."orders"'],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        assert query.returncode == 0, query.stderr
        assert query.stdout.strip() == "2"
    assert 'from "main"."alt_customers"' in (
        run_target / "compiled" / "dynamic_var_ref" / "models" / "orders.sql"
    ).read_text()

    build_target = tmp_path / "build-target"
    build_result = subprocess.run(
        [
            DXT,
            "build",
            "--project-dir",
            str(project),
            "--target-path",
            str(build_target),
            "--select",
            "+orders",
            "--vars",
            '{"customer_model": "alt_customers"}',
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    if DUCKDB is None:
        assert build_result.returncode == 2
        assert "DuckDB execution requires the duckdb CLI" in build_result.stderr
    else:
        assert build_result.returncode == 0, build_result.stderr
        assert "Built 2 model(s) and 0 test(s)" in build_result.stdout
        assert_run_results_schema_slice(build_target / "run_results.json")
    assert 'from "main"."alt_customers"' in (
        build_target / "compiled" / "dynamic_var_ref" / "models" / "orders.sql"
    ).read_text()


def test_compile_rejects_selection_without_models(tmp_path: Path):
    project = copy_fixture(tmp_path, "compile_basic")
    result = subprocess.run(
        [DXT, "compile", "--project-dir", str(project), "--select", "source:raw.payments"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "compile currently supports only selected SQL model or supported generic or singular SQL test resources" in result.stderr


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


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 run execution slice")
def test_run_executes_selected_duckdb_models_and_writes_run_results(tmp_path: Path):
    project = copy_fixture(tmp_path, "compile_basic")
    target = tmp_path / "run-target"
    result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "+orders", "--threads", "4"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Ran 2 model(s)" in result.stdout
    assert result.stderr == ""

    compiled_root = target / "compiled" / "compile_basic" / "models"
    assert (compiled_root / "customers.sql").exists()
    assert (compiled_root / "orders.sql").exists()
    assert not (compiled_root / "from_source.sql").exists()
    manifest = json.loads((target / "manifest.json").read_text())
    assert manifest["nodes"]["model.compile_basic.orders"]["compiled"] is True
    assert manifest["nodes"]["model.compile_basic.customers"]["compiled"] is True

    run_results_path = target / "run_results.json"
    assert_run_results_schema_slice(run_results_path)
    run_results = json.loads(run_results_path.read_text())
    assert [item["unique_id"] for item in run_results["results"]] == [
        "model.compile_basic.customers",
        "model.compile_basic.orders",
    ]
    assert [item["status"] for item in run_results["results"]] == ["success", "success"]
    assert run_results["results"][1]["relation_name"] == '"main"."orders"'

    query = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-csv", "-noheader", "-c", 'select customer_id, order_count from "main"."orders"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert query.returncode == 0, query.stderr
    assert query.stdout.strip() == "1,1"


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 run execution slice")
def test_run_executes_downstream_model_with_injected_ephemeral_ctes(tmp_path: Path):
    project = copy_fixture(tmp_path, "ephemeral_cte")
    target = tmp_path / "run-target"
    result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "+final_chain"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Ran 1 model(s)" in result.stdout

    manifest = json.loads((target / "manifest.json").read_text())
    assert manifest["nodes"]["model.ephemeral_cte.final_chain"]["extra_ctes_injected"] is True
    assert "compiled" not in manifest["nodes"]["model.ephemeral_cte.base_ephemeral"]
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == ["model.ephemeral_cte.final_chain"]

    query = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-csv", "-noheader", "-c", 'select customer_id, customer_name from "main"."final_chain"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert query.returncode == 0, query.stderr
    assert query.stdout.strip() == "1,ADA"
    relations = subprocess.run(
        [
            DUCKDB,
            str(target / "dxt.duckdb"),
            "-csv",
            "-noheader",
            "-c",
            "select table_name from information_schema.tables where table_schema = 'main' order by table_name",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert relations.returncode == 0, relations.stderr
    assert relations.stdout.strip().splitlines() == ["final_chain"]


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 run execution failure slice")
def test_run_writes_error_run_results_when_model_execution_fails(tmp_path: Path):
    project = copy_fixture(tmp_path, "compile_basic")
    (project / "models" / "orders.sql").write_text(
        "{{ config(materialized='table') }}\n"
        "select customers.customer_id\n"
        "from {{ ref('customers') }} as customers\n"
        "join missing_relation on missing_relation.customer_id = customers.customer_id\n"
    )
    target = tmp_path / "run-target"
    result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "+orders"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 1
    assert "Run failed after 2 result(s)" in result.stdout
    assert "one or more selected resources failed" in result.stderr
    assert_manifest_schema_slice(target / "manifest.json")
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == [
        "model.compile_basic.customers",
        "model.compile_basic.orders",
    ]
    assert [item["status"] for item in run_results["results"]] == ["success", "error"]
    assert run_results["results"][1]["message"] == "DuckDB execution failed"
    assert run_results["results"][1]["compiled"] is True
    assert "join missing_relation" in run_results["results"][1]["compiled_code"]
    assert run_results["results"][1]["relation_name"] == '"main"."orders"'

    query = subprocess.run(
        [
            DUCKDB,
            str(target / "dxt.duckdb"),
            "-csv",
            "-noheader",
            "-c",
            "select table_name from information_schema.tables where table_schema = 'main' order by table_name",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert query.returncode == 0, query.stderr
    assert query.stdout.strip().splitlines() == ["customers"]


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 run skipped-results slice")
def test_run_writes_skipped_run_results_for_blocked_selected_descendants(tmp_path: Path):
    project = copy_fixture(tmp_path, "compile_basic")
    (project / "models" / "customers.sql").write_text(
        "{{ config(materialized='table') }}\nselect * from missing_relation\n"
    )
    target = tmp_path / "run-target"
    result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "customers+"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 1
    assert "Run failed after 2 result(s)" in result.stdout
    assert "one or more selected resources failed" in result.stderr
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == [
        "model.compile_basic.customers",
        "model.compile_basic.orders",
    ]
    assert [item["status"] for item in run_results["results"]] == ["error", "skipped"]
    assert run_results["results"][0]["message"] == "DuckDB execution failed"
    assert run_results["results"][1]["message"] is None
    assert run_results["results"][1]["compiled"] is True
    assert run_results["results"][1]["relation_name"] == '"main"."orders"'

    query = subprocess.run(
        [
            DUCKDB,
            str(target / "dxt.duckdb"),
            "-csv",
            "-noheader",
            "-c",
            "select table_name from information_schema.tables where table_schema = 'main' order by table_name",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert query.returncode == 0, query.stderr
    assert query.stdout.strip() == ""


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 run skipped-results slice")
def test_run_skipped_results_honor_exclude(tmp_path: Path):
    project = copy_fixture(tmp_path, "compile_basic")
    (project / "models" / "customers.sql").write_text(
        "{{ config(materialized='table') }}\nselect * from missing_relation\n"
    )
    target = tmp_path / "run-target"
    result = subprocess.run(
        [
            DXT,
            "run",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "customers+",
            "--exclude",
            "orders",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 1
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == ["model.compile_basic.customers"]
    assert [item["status"] for item in run_results["results"]] == ["error"]


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 run execution slice")
def test_run_replaces_existing_relation_when_materialization_type_changes(tmp_path: Path):
    project = tmp_path / "run_replace_materialization"
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: run_replace_materialization
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    model_path = project / "models" / "customers.sql"
    model_path.write_text("{{ config(materialized='table') }}\nselect 1 as customer_id\n")
    target = tmp_path / "run-target"
    first = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert first.returncode == 0, first.stderr

    model_path.write_text("{{ config(materialized='view') }}\nselect 2 as customer_id\n")
    second = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert second.returncode == 0, second.stderr

    query = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-csv", "-noheader", "-c", 'select customer_id from "main"."customers"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert query.returncode == 0, query.stderr
    assert query.stdout.strip() == "2"


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 run execution slice")
def test_run_executes_model_with_trailing_sql_semicolon(tmp_path: Path):
    project = tmp_path / "run_trailing_semicolon"
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: run_trailing_semicolon
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "customers.sql").write_text("select 3 as customer_id; -- trailing note\n")
    target = tmp_path / "run-target"
    result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    query = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-csv", "-noheader", "-c", 'select customer_id from "main"."customers"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert query.returncode == 0, query.stderr
    assert query.stdout.strip() == "3"


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
    assert "run currently supports only selected SQL model resources" in result.stderr
    assert not (target / "run_results.json").exists()


def test_run_rejects_unsupported_model_materialization_before_duckdb(tmp_path: Path):
    project = tmp_path / "unsupported_run_materialization"
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: unsupported_run_materialization
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "events.sql").write_text(
        """{{ config(materialized='incremental') }}
select 1 as id
{% if is_incremental() %}
where id > 0
{% endif %}
"""
    )
    target = tmp_path / "run-target"
    result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "events"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "run currently supports only table and view model materializations" in result.stderr
    assert not (target / "run_results.json").exists()


def test_run_rejects_mixed_unsupported_materialization_without_database_side_effect(tmp_path: Path):
    project = tmp_path / "mixed_run_materialization"
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: mixed_run_materialization
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "a_table.sql").write_text("{{ config(materialized='table') }}\nselect 1 as id\n")
    (project / "models" / "z_incremental.sql").write_text("{{ config(materialized='incremental') }}\nselect 2 as id\n")
    target = tmp_path / "run-target"
    result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "run currently supports only table and view model materializations" in result.stderr
    assert not (target / "dxt.duckdb").exists()
    assert not (target / "run_results.json").exists()


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 run execution slice")
def test_run_executes_selected_models_in_dependency_order(tmp_path: Path):
    project = tmp_path / "run_dependency_order"
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: run_dependency_order
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "a_orders.sql").write_text("select * from {{ ref('z_customers') }}\n")
    (project / "models" / "z_customers.sql").write_text("select 7 as customer_id\n")
    target = tmp_path / "run-target"
    result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "+a_orders"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == [
        "model.run_dependency_order.z_customers",
        "model.run_dependency_order.a_orders",
    ]
    query = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-csv", "-noheader", "-c", 'select customer_id from "main"."a_orders"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert query.returncode == 0, query.stderr
    assert query.stdout.strip() == "7"


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 run execution slice")
def test_run_resolves_duckdb_profile_path_relative_to_profiles_dir(tmp_path: Path):
    project = tmp_path / "profile_path_project"
    profiles_dir = tmp_path / "profiles"
    (project / "models").mkdir(parents=True)
    profiles_dir.mkdir()
    (project / "dbt_project.yml").write_text(
        """name: profile_path_project
version: "1.0"
profile: profile_path_project
model-paths: ["models"]
target-path: target
"""
    )
    (profiles_dir / "profiles.yml").write_text(
        """profile_path_project:
  target: dev
  outputs:
    dev:
      type: duckdb
      schema: analytics
      path: profile-relative.duckdb
"""
    )
    (project / "models" / "customers.sql").write_text("select 11 as customer_id\n")
    target = tmp_path / "run-target"
    result = subprocess.run(
        [
            DXT,
            "run",
            "--project-dir",
            str(project),
            "--profiles-dir",
            str(profiles_dir),
            "--target-path",
            str(target),
            "--select",
            "customers",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert (profiles_dir / "profile-relative.duckdb").exists()
    assert not (project / "profile-relative.duckdb").exists()
    query = subprocess.run(
        [DUCKDB, str(profiles_dir / "profile-relative.duckdb"), "-csv", "-noheader", "-c", 'select customer_id from "analytics"."customers"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert query.returncode == 0, query.stderr
    assert query.stdout.strip() == "11"


def test_run_rejects_non_duckdb_profile_before_execution(tmp_path: Path):
    project = tmp_path / "postgres_run_profile"
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: postgres_run_profile
version: "1.0"
profile: postgres_run_profile
model-paths: ["models"]
target-path: target
"""
    )
    (project / "profiles.yml").write_text(
        """postgres_run_profile:
  target: dev
  outputs:
    dev:
      type: postgres
      schema: analytics
"""
    )
    (project / "models" / "customers.sql").write_text("select 1 as id\n")
    target = tmp_path / "run-target"
    result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "run currently executes only DuckDB SQL models" in result.stderr
    assert not (target / "run_results.json").exists()


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 model build execution slice")
def test_build_executes_selected_duckdb_models_and_writes_run_results(tmp_path: Path):
    project = copy_fixture(tmp_path, "compile_basic")
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "+orders"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Built 2 model(s) and 0 test(s)" in result.stdout
    assert (target / "compiled" / "compile_basic" / "models" / "orders.sql").exists()
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == [
        "model.compile_basic.customers",
        "model.compile_basic.orders",
    ]
    assert [item["status"] for item in run_results["results"]] == ["success", "success"]
    manifest = json.loads((target / "manifest.json").read_text())
    assert manifest["nodes"]["model.compile_basic.orders"]["compiled"] is True

    query = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-csv", "-noheader", "-c", 'select customer_id, order_count from "main"."orders"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert query.returncode == 0, query.stderr
    assert query.stdout.strip() == "1,1"


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 model build execution slice")
def test_build_executes_downstream_model_with_injected_ephemeral_ctes(tmp_path: Path):
    project = copy_fixture(tmp_path, "ephemeral_cte")
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "+final_chain"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Built 1 model(s) and 0 test(s)" in result.stdout
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == ["model.ephemeral_cte.final_chain"]
    assert run_results["results"][0]["compiled"] is True
    assert "__dbt__cte__filtered_ephemeral" in run_results["results"][0]["compiled_code"]

    query = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-csv", "-noheader", "-c", 'select count(*) from "main"."final_chain"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert query.returncode == 0, query.stderr
    assert query.stdout.strip() == "1"


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 model build execution failure slice")
def test_build_writes_error_run_results_when_model_execution_fails(tmp_path: Path):
    project = copy_fixture(tmp_path, "compile_basic")
    (project / "models" / "orders.sql").write_text(
        "{{ config(materialized='table') }}\n"
        "select customers.customer_id\n"
        "from {{ ref('customers') }} as customers\n"
        "join missing_relation on missing_relation.customer_id = customers.customer_id\n"
    )
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "+orders"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 1
    assert "Build failed after 2 result(s)" in result.stdout
    assert "one or more selected resources failed" in result.stderr
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == [
        "model.compile_basic.customers",
        "model.compile_basic.orders",
    ]
    assert [item["status"] for item in run_results["results"]] == ["success", "error"]
    assert run_results["results"][1]["message"] == "DuckDB execution failed"


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 build skipped-results slice")
def test_build_writes_skipped_run_results_for_blocked_selected_descendants(tmp_path: Path):
    project = copy_fixture(tmp_path, "compile_basic")
    (project / "models" / "customers.sql").write_text(
        "{{ config(materialized='table') }}\nselect * from missing_relation\n"
    )
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "customers+"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 1
    assert "Build failed after 2 result(s)" in result.stdout
    assert "one or more selected resources failed" in result.stderr
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == [
        "model.compile_basic.customers",
        "model.compile_basic.orders",
    ]
    assert [item["status"] for item in run_results["results"]] == ["error", "skipped"]
    assert run_results["results"][0]["message"] == "DuckDB execution failed"
    assert run_results["results"][1]["message"] is None
    assert run_results["results"][1]["compiled"] is True


def test_build_rejects_unsupported_model_materialization_before_duckdb(tmp_path: Path):
    project = tmp_path / "unsupported_build_materialization"
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: unsupported_build_materialization
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "events.sql").write_text(
        "{{ config(materialized='incremental') }}\nselect 1 as id\n"
    )
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "events"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "build currently supports only table and view model materializations" in result.stderr
    assert "run currently supports only table and view model materializations" not in result.stderr
    assert not (target / "run_results.json").exists()
    assert not (target / "dxt.duckdb").exists()
    assert (target / "manifest.json").exists()


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 seed build execution slice")
def test_seed_command_executes_selected_duckdb_seed_and_writes_run_results(tmp_path: Path):
    project = copy_fixture(tmp_path, "seed_ref")
    target = tmp_path / "seed-target"
    result = subprocess.run(
        [DXT, "seed", "--project-dir", str(project), "--target-path", str(target), "--select", "raw_customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Seeded 1 seed(s)" in result.stdout
    assert result.stderr == ""
    assert_manifest_schema_slice(target / "manifest.json")
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == ["seed.seed_ref.raw_customers"]
    assert run_results["results"][0]["compiled"] is None
    assert run_results["results"][0]["compiled_code"] is None
    assert run_results["results"][0]["relation_name"] is None

    query = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-csv", "-noheader", "-c", 'select id, name from "main"."raw_customers"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert query.returncode == 0, query.stderr
    assert query.stdout.strip() == "1,Ada"


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for seed quote_columns and column_types coverage")
def test_seed_command_honors_seed_quote_columns_and_column_types(tmp_path: Path):
    project = tmp_path / "seed_config_tests"
    write_seed_config_project(project)
    target = tmp_path / "seed-target"
    result = subprocess.run(
        [DXT, "seed", "--project-dir", str(project), "--target-path", str(target), "--select", "raw_customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert_manifest_schema_slice(target / "manifest.json")
    assert_run_results_schema_slice(target / "run_results.json")
    manifest = json.loads((target / "manifest.json").read_text())
    assert manifest["nodes"]["seed.seed_config_tests.raw_customers"]["config"]["quote_columns"] is True
    assert manifest["nodes"]["seed.seed_config_tests.raw_customers"]["config"]["column_types"]["amount"] == "decimal(10,2)"

    query = subprocess.run(
        [
            DUCKDB,
            str(target / "dxt.duckdb"),
            "-json",
            "-c",
            "select column_name, data_type from information_schema.columns where table_schema = 'main' and table_name = 'raw_customers' order by ordinal_position",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert query.returncode == 0, query.stderr
    assert json.loads(query.stdout) == [
        {"column_name": "Order ID", "data_type": "INTEGER"},
        {"column_name": "customer name", "data_type": "VARCHAR"},
        {"column_name": "amount", "data_type": "DECIMAL(10,2)"},
    ]


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 seed command execution slice")
def test_seed_command_filters_mixed_selection_to_seed_resources(tmp_path: Path):
    project = copy_fixture(tmp_path, "seed_ref")
    target = tmp_path / "seed-target"
    result = subprocess.run(
        [DXT, "seed", "--project-dir", str(project), "--target-path", str(target), "--select", "raw_customers", "stg_customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Seeded 1 seed(s)" in result.stdout
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == ["seed.seed_ref.raw_customers"]


def test_seed_command_rejects_non_seed_selection_before_duckdb(tmp_path: Path):
    project = copy_fixture(tmp_path, "seed_ref")
    target = tmp_path / "seed-target"
    result = subprocess.run(
        [DXT, "seed", "--project-dir", str(project), "--target-path", str(target), "--select", "stg_customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "seed currently supports only selected seed resources" in result.stderr
    assert not (target / "run_results.json").exists()
    assert not (target / "dxt.duckdb").exists()


def write_duckdb_profile(project: Path) -> None:
    (project / "profiles.yml").write_text(
        """default:
  target: dev
  outputs:
    dev:
      type: duckdb
      schema: main
"""
    )


def write_duckdb_profile_at(profiles_dir: Path, path: str | None = None) -> None:
    profiles_dir.mkdir()
    lines = [
        "default:",
        "  target: dev",
        "  outputs:",
        "    dev:",
        "      type: duckdb",
    ]
    if path is not None:
        lines.append(f"      path: {path}")
    lines.append("      schema: main")
    profiles_dir.joinpath("profiles.yml").write_text("\n".join(lines) + "\n")


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 package seed command execution slice")
def test_seed_command_executes_package_seed_selected_by_package_selector(tmp_path: Path):
    project = copy_fixture(tmp_path, "package_ref_selector")
    write_duckdb_profile(project)
    target = tmp_path / "seed-target"
    result = subprocess.run(
        [DXT, "seed", "--project-dir", str(project), "--target-path", str(target), "--select", "package:util_pkg"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Seeded 1 seed(s)" in result.stdout
    assert result.stderr == ""
    assert_manifest_schema_slice(target / "manifest.json")
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == ["seed.util_pkg.raw_pkg_customers"]
    assert run_results["results"][0]["compiled"] is None
    assert run_results["results"][0]["compiled_code"] is None
    assert run_results["results"][0]["relation_name"] is None
    assert str(project) not in (target / "manifest.json").read_text()
    assert str(project) not in (target / "run_results.json").read_text()

    query = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-csv", "-noheader", "-c", 'select customer_id, customer_name from "main"."raw_pkg_customers"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert query.returncode == 0, query.stderr
    assert query.stdout.strip() == "1,Ada"


def test_dbt_core_package_seed_manifest_and_run_results_oracle(tmp_path: Path):
    try:
        has_dbt_core = importlib.util.find_spec("dbt.cli.main") is not None
        has_dbt_duckdb = importlib.util.find_spec("dbt.adapters.duckdb") is not None
    except ModuleNotFoundError:
        has_dbt_core = False
        has_dbt_duckdb = False

    if not has_dbt_core:
        pytest.skip("dbt Core is not installed for the optional package seed oracle")
    if not has_dbt_duckdb:
        pytest.skip("dbt DuckDB adapter is not installed for the optional package seed oracle")

    from dbt.cli.main import dbtRunner
    import dbt_common.events.base_types as dbt_event_base_types
    import google.protobuf.json_format as protobuf_json_format

    project = copy_fixture(tmp_path, "package_ref_selector")
    dxt_profiles = tmp_path / "dxt-profiles"
    dbt_profiles = tmp_path / "dbt-profiles"
    write_duckdb_profile_at(dxt_profiles)
    write_duckdb_profile_at(dbt_profiles, str(tmp_path / "dbt-oracle.duckdb"))
    dxt_target = tmp_path / "dxt-target"
    dbt_target = tmp_path / "dbt-target"

    dxt_result = subprocess.run(
        [
            DXT,
            "seed",
            "--project-dir",
            str(project),
            "--profiles-dir",
            str(dxt_profiles),
            "--target-path",
            str(dxt_target),
            "--select",
            "raw_pkg_customers",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert dxt_result.returncode == 0, dxt_result.stderr

    original_message_to_json = protobuf_json_format.MessageToJson
    original_event_message_to_json = dbt_event_base_types.MessageToJson

    def compatible_message_to_json(message, *args, always_print_fields_with_no_presence=None, **kwargs):
        if always_print_fields_with_no_presence is not None and "including_default_value_fields" not in kwargs:
            kwargs["including_default_value_fields"] = always_print_fields_with_no_presence
        return original_message_to_json(message, *args, **kwargs)

    protobuf_json_format.MessageToJson = compatible_message_to_json
    dbt_event_base_types.MessageToJson = compatible_message_to_json
    try:
        dbt_result = dbtRunner().invoke(
            [
                "seed",
                "--project-dir",
                str(project),
                "--profiles-dir",
                str(dbt_profiles),
                "--target-path",
                str(dbt_target),
                "--select",
                "raw_pkg_customers",
            ]
        )
    finally:
        protobuf_json_format.MessageToJson = original_message_to_json
        dbt_event_base_types.MessageToJson = original_event_message_to_json
    if not dbt_result.success:
        pytest.skip(f"dbt Core package seed oracle unavailable: {dbt_result.exception!r}")

    dxt_manifest = json.loads((dxt_target / "manifest.json").read_text())
    dbt_manifest = json.loads((dbt_target / "manifest.json").read_text())
    dxt_run_results = json.loads((dxt_target / "run_results.json").read_text())
    dbt_run_results = json.loads((dbt_target / "run_results.json").read_text())
    unique_id = "seed.util_pkg.raw_pkg_customers"
    dxt_seed = dxt_manifest["nodes"][unique_id]
    dbt_seed = dbt_manifest["nodes"][unique_id]
    assert {
        key: dxt_seed[key]
        for key in ("unique_id", "resource_type", "package_name", "name", "path", "original_file_path")
    } == {
        key: dbt_seed[key]
        for key in ("unique_id", "resource_type", "package_name", "name", "path", "original_file_path")
    }

    assert [item["unique_id"] for item in dxt_run_results["results"]] == [unique_id]
    assert [item["unique_id"] for item in dbt_run_results["results"]] == [unique_id]
    dxt_result_row = dxt_run_results["results"][0]
    dbt_result_row = dbt_run_results["results"][0]
    assert dxt_result_row["status"] == dbt_result_row["status"] == "success"
    assert dxt_result_row["compiled"] == dbt_result_row.get("compiled")
    assert dxt_result_row["compiled_code"] == dbt_result_row.get("compiled_code")
    assert dxt_result_row["relation_name"] == dbt_result_row.get("relation_name")


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 package seed command execution slice")
def test_seed_command_executes_package_seed_selected_by_dependency_selector(tmp_path: Path):
    project = copy_fixture(tmp_path, "package_ref_selector")
    write_duckdb_profile(project)
    target = tmp_path / "seed-target"
    result = subprocess.run(
        [DXT, "seed", "--project-dir", str(project), "--target-path", str(target), "--select", "+pkg_seeded_customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Seeded 1 seed(s)" in result.stdout
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == ["seed.util_pkg.raw_pkg_customers"]


def test_parse_preserves_root_and_package_seed_quote_columns_and_column_types(tmp_path: Path):
    project = tmp_path / "seed_config_tests"
    write_seed_config_project(project)
    target = tmp_path / "parse-target"
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert_manifest_schema_slice(target / "manifest.json")
    manifest = json.loads((target / "manifest.json").read_text())

    root_config = manifest["nodes"]["seed.seed_config_tests.raw_customers"]["config"]
    assert root_config["quote_columns"] is True
    assert root_config["column_types"] == {
        "Order ID": "integer",
        "amount": "decimal(10,2)",
        "customer name": "varchar",
    }

    package_config = manifest["nodes"]["seed.util_pkg.raw_pkg_orders"]["config"]
    assert package_config["quote_columns"] is False
    assert package_config["column_types"] == {
        "amount": "decimal(10,2)",
        "order_id": "integer",
    }


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 seed build execution slice")
def test_build_executes_selected_duckdb_seed_and_writes_run_results(tmp_path: Path):
    project = copy_fixture(tmp_path, "seed_ref")
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "raw_customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Built 1 seed(s)" in result.stdout
    assert result.stderr == ""
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == ["seed.seed_ref.raw_customers"]
    assert run_results["results"][0]["compiled"] is None
    assert run_results["results"][0]["compiled_code"] is None
    assert run_results["results"][0]["relation_name"] is None
    manifest = json.loads((target / "manifest.json").read_text())
    assert sorted(manifest["nodes"]) == [
        "model.seed_ref.stg_customers",
        "seed.seed_ref.raw_customers",
    ]
    assert "compiled" not in manifest["nodes"]["seed.seed_ref.raw_customers"]

    query = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-csv", "-noheader", "-c", 'select id, name from "main"."raw_customers"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert query.returncode == 0, query.stderr
    assert query.stdout.strip() == "1,Ada"


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 package seed build execution slice")
def test_build_executes_selected_package_duckdb_seed_and_writes_run_results(tmp_path: Path):
    project = copy_fixture(tmp_path, "package_ref_selector")
    write_duckdb_profile(project)
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "package:util_pkg,resource_type:seed"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Built 1 seed(s)" in result.stdout
    assert result.stderr == ""
    assert_manifest_schema_slice(target / "manifest.json")
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == ["seed.util_pkg.raw_pkg_customers"]
    assert run_results["results"][0]["compiled"] is None
    assert run_results["results"][0]["compiled_code"] is None
    assert run_results["results"][0]["relation_name"] is None
    assert str(project) not in (target / "manifest.json").read_text()
    assert str(project) not in (target / "run_results.json").read_text()

    query = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-csv", "-noheader", "-c", 'select customer_id, customer_name from "main"."raw_pkg_customers"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert query.returncode == 0, query.stderr
    assert query.stdout.strip() == "1,Ada"


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for build seed quote_columns and column_types coverage")
def test_build_honors_package_seed_quote_columns_false_and_column_types(tmp_path: Path):
    project = tmp_path / "seed_config_tests"
    write_seed_config_project(project)
    write_duckdb_profile(project)
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "package:util_pkg,resource_type:seed"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert_manifest_schema_slice(target / "manifest.json")
    assert_run_results_schema_slice(target / "run_results.json")
    manifest = json.loads((target / "manifest.json").read_text())
    package_config = manifest["nodes"]["seed.util_pkg.raw_pkg_orders"]["config"]
    assert package_config["quote_columns"] is False
    assert package_config["column_types"] == {
        "amount": "decimal(10,2)",
        "order_id": "integer",
    }

    query = subprocess.run(
        [
            DUCKDB,
            str(target / "dxt.duckdb"),
            "-json",
            "-c",
            "select column_name, data_type from information_schema.columns where table_schema = 'main' and table_name = 'raw_pkg_orders' order by ordinal_position",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert query.returncode == 0, query.stderr
    assert json.loads(query.stdout) == [
        {"column_name": "order_id", "data_type": "INTEGER"},
        {"column_name": "amount", "data_type": "DECIMAL(10,2)"},
    ]


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 seed build execution slice")
def test_build_replaces_existing_view_with_seed_table(tmp_path: Path):
    project = copy_fixture(tmp_path, "seed_ref")
    target = tmp_path / "build-target"
    target.mkdir()
    prepare = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-batch", "-bail", "-c", 'create view "main"."raw_customers" as select 0 as id'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert prepare.returncode == 0, prepare.stderr

    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "raw_customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr

    query = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-csv", "-noheader", "-c", 'select id, name from "main"."raw_customers"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert query.returncode == 0, query.stderr
    assert query.stdout.strip() == "1,Ada"


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 seed+model build execution slice")
def test_build_executes_selected_duckdb_seed_and_dependent_model(tmp_path: Path):
    project = copy_fixture(tmp_path, "seed_ref")
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "+stg_customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Built 1 seed(s), 1 model(s), and 0 test(s)" in result.stdout
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == [
        "seed.seed_ref.raw_customers",
        "model.seed_ref.stg_customers",
    ]
    assert [item["status"] for item in run_results["results"]] == ["success", "success"]
    assert run_results["results"][0]["compiled"] is None
    assert run_results["results"][1]["compiled"] is True
    assert (target / "compiled" / "seed_ref" / "models" / "stg_customers.sql").exists()

    query = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-csv", "-noheader", "-c", 'select id, name from "main"."stg_customers"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert query.returncode == 0, query.stderr
    assert query.stdout.strip() == "1,Ada"


def test_build_prepare_reports_test_execution_boundary(tmp_path: Path):
    project = copy_fixture(tmp_path, "model_properties")
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "test_type:generic"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert result.stdout == ""
    assert "test/build currently executes only selected DuckDB singular SQL tests and model/seed/source not_null/unique/accepted_values/relationships column tests" in result.stderr
    assert not (target / "run_results.json").exists()
    manifest = json.loads((target / "manifest.json").read_text())
    assert "compiled" not in manifest["nodes"]["model.model_properties.customers"]
    assert sorted(manifest["child_map"]["model.model_properties.customers"])


def write_seed_model_test_project(project: Path, seed_csv: str, schema_tests: str | None = None) -> None:
    (project / "models").mkdir(parents=True)
    (project / "seeds").mkdir()
    (project / "dbt_project.yml").write_text(
        """name: build_seed_model_tests
version: "1.0"
model-paths: ["models"]
seed-paths: ["seeds"]
target-path: target
"""
    )
    (project / "seeds" / "raw_customers.csv").write_text(seed_csv)
    (project / "models" / "customers.sql").write_text(
        """{{ config(materialized='table') }}
select
  try_cast(customer_id as integer) as customer_id,
  customer_name
from {{ ref("raw_customers") }}
"""
    )
    tests = schema_tests or """          - not_null
          - unique
"""
    (project / "models" / "schema.yml").write_text(
        f"""version: 2
models:
  - name: customers
    columns:
      - name: customer_id
        tests:
{tests}"""
    )


def write_seed_column_test_project(project: Path, seed_csv: str, schema_tests: str | None = None) -> None:
    (project / "seeds").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: seed_column_tests
version: "1.0"
seed-paths: ["seeds"]
target-path: target
"""
    )
    (project / "seeds" / "raw_customers.csv").write_text(seed_csv)
    tests = schema_tests or """          - not_null
          - unique
          - accepted_values:
              arguments:
                values: [1, 2]
                quote: false
"""
    (project / "seeds" / "schema.yml").write_text(
        f"""version: 2
seeds:
  - name: raw_customers
    columns:
      - name: customer_id
        tests:
{tests}"""
    )


def write_seed_config_project(project: Path) -> None:
    (project / "seeds").mkdir(parents=True)
    (project / "dbt_packages" / "util_pkg" / "seeds").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: seed_config_tests
version: "1.0"
profile: default
seed-paths: ["seeds"]
target-path: target
"""
    )
    (project / "seeds" / "raw_customers.csv").write_text("Order ID,customer name,amount\n1,Ada,10.50\n")
    (project / "seeds" / "schema.yml").write_text(
        """version: 2
seeds:
  - name: raw_customers
    config:
      quote_columns: true
      column_types:
        Order ID: integer
        amount: decimal(10,2)
        customer name: varchar
"""
    )
    (project / "dbt_packages" / "util_pkg" / "dbt_project.yml").write_text(
        """name: util_pkg
version: "1.0"
seed-paths: ["seeds"]
"""
    )
    (project / "dbt_packages" / "util_pkg" / "seeds" / "raw_pkg_orders.csv").write_text("Order ID,amount\n1,10.50\n")
    (project / "dbt_packages" / "util_pkg" / "seeds" / "schema.yml").write_text(
        """version: 2
seeds:
  - name: raw_pkg_orders
    config:
      quote_columns: false
      column_types:
        amount: decimal(10,2)
        order_id: integer
"""
    )


def write_table_level_generic_test_project(project: Path) -> None:
    (project / "models").mkdir(parents=True)
    (project / "seeds").mkdir()
    (project / "dbt_project.yml").write_text(
        """name: table_level_generic_tests
version: "1.0"
model-paths: ["models"]
seed-paths: ["seeds"]
target-path: target
"""
    )
    (project / "seeds" / "raw_customers.csv").write_text(
        "customer_id,customer_name\n1,Ada\n2,Bob\n"
    )
    (project / "models" / "customers.sql").write_text(
        """{{ config(materialized='table') }}
select try_cast(customer_id as integer) as customer_id, customer_name
from {{ ref("raw_customers") }}
"""
    )
    (project / "models" / "schema.yml").write_text(
        """version: 2
models:
  - name: customers
    config:
      materialized: table
    data_tests:
      - not_null:
          arguments:
            column_name: customer_id
sources:
  - name: raw
    tables:
      - name: orders
        identifier: raw_orders
        data_tests:
          - accepted_values:
              arguments:
                column_name: customer_id
                values: [1, 2]
                quote: false
"""
    )
    (project / "seeds" / "schema.yml").write_text(
        """version: 2
seeds:
  - name: raw_customers
    data_tests:
      - unique:
          arguments:
            column_name: customer_id
"""
    )


def write_supported_model_test_project(project: Path, customers_sql: str) -> None:
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: build_model_tests
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "customers.sql").write_text(customers_sql)
    (project / "models" / "schema.yml").write_text(
        """version: 2
models:
  - name: customers
    config:
      materialized: table
    columns:
      - name: customer_id
        tests:
          - not_null
          - unique
"""
    )


def write_generic_test_config_project(
    project: Path,
    severity: str = "warn",
    error_if: str = "> 0",
    where: str = "status = 'checked'",
    store_failures: bool | None = None,
) -> None:
    (project / "models").mkdir(parents=True, exist_ok=True)
    (project / "seeds").mkdir(exist_ok=True)
    store_failures_line = "" if store_failures is None else f"                store_failures: {str(store_failures).lower()}\n"
    (project / "dbt_project.yml").write_text(
        """name: generic_test_config_tests
version: "1.0"
model-paths: ["models"]
seed-paths: ["seeds"]
target-path: target
"""
    )
    (project / "models" / "customers.sql").write_text(
        """{{ config(materialized='table') }}
select 1 as customer_id, 'checked' as status
union all select null as customer_id, 'checked' as status
union all select null as customer_id, 'checked' as status
union all select null as customer_id, 'ignored' as status
"""
    )
    (project / "seeds" / "raw_customers.csv").write_text("customer_id,status\n1,checked\n,checked\n")
    (project / "models" / "schema.yml").write_text(
        f"""version: 2
models:
  - name: customers
    columns:
      - name: customer_id
        tests:
          - not_null:
              config:
                where: "{where}"
                limit: 1
                severity: {severity}
                warn_if: "> 0"
                error_if: "{error_if}"
{store_failures_line}\
seeds:
  - name: raw_customers
    columns:
      - name: customer_id
        tests:
          - not_null:
              config:
                where: "status = 'checked'"
                limit: 2
                severity: error
                warn_if: "> 1"
                error_if: "> 2"
sources:
  - name: raw
    schema: main
    tables:
      - name: orders
        columns:
          - name: customer_id
            tests:
              - not_null:
                  config:
                    where: "status = 'checked'"
                    limit: 3
                    severity: warn
                    warn_if: "> 0"
                    error_if: "> 10"
"""
    )


def write_run_failure_continuation_project(project: Path) -> None:
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: run_failure_continue
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "bad_parent.sql").write_text(
        """{{ config(materialized='table') }}
select * from missing_relation
"""
    )
    (project / "models" / "bad_child.sql").write_text(
        """{{ config(materialized='table') }}
select * from {{ ref("bad_parent") }}
"""
    )
    (project / "models" / "independent.sql").write_text(
        """{{ config(materialized='table') }}
select 42 as answer
"""
    )


def write_build_failure_continuation_project(project: Path) -> None:
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: build_failure_continue
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "aa_bad_parent.sql").write_text(
        """{{ config(materialized='table') }}
select * from missing_relation
"""
    )
    (project / "models" / "ab_bad_child.sql").write_text(
        """{{ config(materialized='table') }}
select * from {{ ref("aa_bad_parent") }}
"""
    )
    (project / "models" / "zz_independent.sql").write_text(
        """{{ config(materialized='table') }}
select 42 as answer
"""
    )


def write_build_test_failure_continuation_project(project: Path) -> None:
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: build_test_failure_continue
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "customers.sql").write_text(
        """{{ config(materialized='table') }}
select null as customer_id, 'Ada' as customer_name
"""
    )
    (project / "models" / "orders.sql").write_text(
        """{{ config(materialized='table') }}
select customer_id, customer_name
from {{ ref("customers") }}
"""
    )
    (project / "models" / "zz_independent.sql").write_text(
        """{{ config(materialized='table') }}
select 42 as answer
"""
    )
    (project / "models" / "schema.yml").write_text(
        """version: 2
models:
  - name: customers
    columns:
      - name: customer_id
        tests:
          - not_null
"""
    )


def write_build_seed_failure_continuation_project(project: Path) -> None:
    (project / "models").mkdir(parents=True)
    (project / "seeds").mkdir()
    (project / "dbt_project.yml").write_text(
        """name: build_seed_failure_continue
version: "1.0"
model-paths: ["models"]
seed-paths: ["seeds"]
target-path: target
"""
    )
    (project / "seeds" / "aa_bad_seed.csv").write_text("customer_id,customer_name\nnot_an_int,Ada\n")
    (project / "seeds" / "zz_independent_seed.csv").write_text("customer_id,customer_name\n42,Indy\n")
    (project / "models" / "ab_bad_child.sql").write_text(
        """{{ config(materialized='table') }}
select try_cast(customer_id as integer) as customer_id, customer_name
from {{ ref("aa_bad_seed") }}
"""
    )
    (project / "seeds" / "schema.yml").write_text(
        """version: 2
seeds:
  - name: aa_bad_seed
    config:
      column_types:
        customer_id: integer
"""
    )
    (project / "models" / "zz_independent.sql").write_text(
        """{{ config(materialized='table') }}
select try_cast(customer_id as integer) as customer_id, customer_name
from {{ ref("zz_independent_seed") }}
"""
    )
    (project / "models" / "schema.yml").write_text(
        """version: 2
models:
  - name: ab_bad_child
    columns:
      - name: customer_id
        tests:
          - not_null
  - name: zz_independent
    columns:
      - name: customer_id
        tests:
          - not_null
"""
    )


def write_build_test_failure_downstream_project(project: Path) -> None:
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: build_test_failure_skip
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "customers.sql").write_text(
        """{{ config(materialized='table') }}
select null as customer_id, 'Ada' as customer_name
"""
    )
    (project / "models" / "orders.sql").write_text(
        """{{ config(materialized='table') }}
select customer_id, customer_name
from {{ ref("customers") }}
"""
    )
    (project / "models" / "schema.yml").write_text(
        """version: 2
models:
  - name: customers
    columns:
      - name: customer_id
        tests:
          - not_null
"""
    )


def write_seed_build_test_failure_downstream_project(project: Path) -> None:
    (project / "models").mkdir(parents=True)
    (project / "seeds").mkdir()
    (project / "dbt_project.yml").write_text(
        """name: build_seed_test_failure_skip
version: "1.0"
model-paths: ["models"]
seed-paths: ["seeds"]
target-path: target
"""
    )
    (project / "seeds" / "raw_customers.csv").write_text("customer_id,customer_name\n,Ada\n")
    (project / "models" / "customers.sql").write_text(
        """{{ config(materialized='table') }}
select try_cast(customer_id as integer) as customer_id, customer_name
from {{ ref("raw_customers") }}
"""
    )
    (project / "models" / "orders.sql").write_text(
        """{{ config(materialized='table') }}
select customer_id, customer_name
from {{ ref("customers") }}
"""
    )
    (project / "models" / "schema.yml").write_text(
        """version: 2
models:
  - name: customers
    columns:
      - name: customer_id
        tests:
          - not_null
"""
    )


def write_singular_test_project(project: Path, customers_sql: str, singular_sql: str) -> None:
    (project / "models").mkdir(parents=True)
    (project / "tests" / "generic").mkdir(parents=True)
    (project / "tests" / "fixtures").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: singular_tests
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "customers.sql").write_text(customers_sql)
    (project / "tests" / "assert_customers.sql").write_text(singular_sql)
    (project / "tests" / "generic" / "ignored_generic.sql").write_text(
        "{% test ignored_generic(model) %}select 1{% endtest %}\n"
    )
    (project / "tests" / "fixtures" / "ignored_fixture.sql").write_text("select 1 as should_not_parse\n")


def write_singular_test_config_project(
    project: Path,
    *,
    severity: str = "warn",
    error_if: str = "> 10",
    enabled: bool = True,
    store_failures: bool | None = None,
    inline_store_failures: bool = False,
) -> None:
    (project / "models").mkdir(parents=True, exist_ok=True)
    (project / "tests").mkdir(exist_ok=True)
    store_failures_line = "" if store_failures is None else f"      store_failures: {str(store_failures).lower()}\n"
    inline_config = "{{ config(store_failures=true) }}\n" if inline_store_failures else ""
    (project / "dbt_project.yml").write_text(
        """name: singular_test_configs
version: "1.0"
model-paths: ["models"]
test-paths: ["tests"]
target-path: target
"""
    )
    (project / "models" / "customers.sql").write_text(
        """{{ config(materialized='table') }}
select 1 as customer_id, 'checked' as status
union all select 2 as customer_id, 'checked' as status
union all select 3 as customer_id, 'ignored' as status
"""
    )
    (project / "tests" / "assert_customers.sql").write_text(
        f"{inline_config}select * from {{{{ ref('customers') }}}} where customer_id > 0;\n"
    )
    (project / "tests" / "disabled_assert.sql").write_text("select * from {{ ref('missing_model') }}\n")
    (project / "tests" / "schema.yml").write_text(
        f"""version: 2
data_tests:
  - name: assert_customers
    description: "patched singular test"
    config:
      enabled: {str(enabled).lower()}
      tags: [singular_yaml, nightly]
      where: "status = 'checked'"
      limit: 1
      severity: {severity}
      warn_if: "> 0"
      error_if: "{error_if}"
{store_failures_line}\
  - name: disabled_assert
    config:
      enabled: false
      tags: [disabled_yaml]
"""
    )


def test_singular_sql_test_paths_skip_generic_and_fixtures_with_trailing_slash(tmp_path: Path):
    project = tmp_path / "singular_trailing_slash"
    (project / "models").mkdir(parents=True)
    (project / "tests" / "generic").mkdir(parents=True)
    (project / "tests" / "fixtures").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: singular_trailing_slash
version: "1.0"
model-paths: ["models"]
test-paths: ["tests/"]
target-path: target
"""
    )
    (project / "models" / "customers.sql").write_text("select 1 as customer_id\n")
    (project / "tests" / "generic" / "ignored_generic.sql").write_text(
        "{% test ignored_generic(model) %}select 1{% endtest %}\n"
    )
    (project / "tests" / "fixtures" / "ignored_fixture.sql").write_text("select 1 as should_not_parse\n")
    target = tmp_path / "parse-target"

    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    manifest = json.loads((target / "manifest.json").read_text())
    assert sorted(unique_id for unique_id in manifest["nodes"] if unique_id.startswith("test.")) == []


def write_accepted_values_model_test_project(project: Path, customers_sql: str) -> None:
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: accepted_values_tests
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "customers.sql").write_text(customers_sql)
    (project / "models" / "schema.yml").write_text(
        """version: 2
models:
  - name: customers
    config:
      materialized: table
    columns:
      - name: customer_type
        tests:
          - accepted_values:
              arguments:
                values: ['new', 'returning']
"""
    )


def write_accepted_values_quote_false_model_test_project(project: Path, customers_sql: str) -> None:
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: accepted_values_quote_false_tests
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "customers.sql").write_text(customers_sql)
    (project / "models" / "schema.yml").write_text(
        """version: 2
models:
  - name: customers
    config:
      materialized: table
    columns:
      - name: customer_id
        tests:
          - accepted_values:
              arguments:
                values: [1, 2]
                quote: false
"""
    )


def write_source_column_test_project(project: Path) -> None:
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: source_column_tests
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "schema.yml").write_text(
        """version: 2
sources:
  - name: raw
    tables:
      - name: customers
        identifier: raw_customers
        columns:
          - name: customer_id
            tests: [not_null, unique]
          - name: customer_type
            data_tests:
              - accepted_values:
                  arguments:
                    values: ['new', 'returning']
"""
    )


def write_source_column_quote_false_test_project(project: Path) -> None:
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: source_column_quote_false_tests
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "schema.yml").write_text(
        """version: 2
sources:
  - name: raw
    tables:
      - name: customers
        identifier: raw_customers
        columns:
          - name: customer_id
            data_tests:
              - accepted_values:
                  arguments:
                    values: [1, 2]
                    quote: false
"""
    )


def write_source_relationships_test_project(project: Path) -> None:
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: source_relationship_tests
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "customers.sql").write_text(
        """{{ config(materialized='table') }}
select 1 as customer_id, 'Ada' as customer_name
union all
select 2 as customer_id, 'Bob' as customer_name
"""
    )
    (project / "models" / "schema.yml").write_text(
        """version: 2
models:
  - name: customers
    config:
      materialized: table
sources:
  - name: raw
    tables:
      - name: orders
        identifier: raw_orders
        columns:
          - name: customer_id
            tests:
              - relationships:
                  arguments:
                    to: ref('customers')
                    field: customer_id
"""
    )


def write_source_to_source_relationships_test_project(project: Path) -> None:
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: source_to_source_relationship_tests
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "schema.yml").write_text(
        """version: 2
sources:
  - name: raw
    schema: raw
    tables:
      - name: orders
        identifier: raw_orders
        columns:
          - name: customer_id
            tests:
              - relationships:
                  arguments:
                    to: source('raw', 'customers')
                    field: customer_id
      - name: customers
        identifier: raw_customers
        columns:
          - name: customer_id
"""
    )


def write_source_target_relationships_manifest_project(project: Path) -> None:
    (project / "models").mkdir(parents=True)
    (project / "seeds").mkdir()
    (project / "dbt_project.yml").write_text(
        """name: source_target_relationship_tests
version: "1.0"
model-paths: ["models"]
seed-paths: ["seeds"]
target-path: target
"""
    )
    (project / "models" / "orders_model.sql").write_text("select 1 as customer_id\n")
    (project / "seeds" / "orders_seed.csv").write_text("customer_id\n1\n")
    (project / "models" / "schema.yml").write_text(
        """version: 2
models:
  - name: orders_model
    columns:
      - name: customer_id
        tests:
          - relationships:
              arguments:
                to: source('raw', 'customers')
                field: customer_id
sources:
  - name: raw
    tables:
      - name: orders
        identifier: raw_orders
        columns:
          - name: customer_id
            tests:
              - relationships:
                  arguments:
                    to: source('raw', 'customers')
                    field: customer_id
      - name: customers
        identifier: raw_customers
        columns:
          - name: customer_id
"""
    )
    (project / "seeds" / "schema.yml").write_text(
        """version: 2
seeds:
  - name: orders_seed
    columns:
      - name: customer_id
        tests:
          - relationships:
              arguments:
                to: source('raw', 'customers')
                field: customer_id
"""
    )


def write_relationships_model_test_project(project: Path, customers_sql: str, orders_sql: str) -> None:
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: relationships_tests
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "customers.sql").write_text(customers_sql)
    (project / "models" / "orders.sql").write_text(orders_sql)
    (project / "models" / "schema.yml").write_text(
        """version: 2
models:
  - name: customers
    config:
      materialized: table
  - name: orders
    config:
      materialized: table
    columns:
      - name: customer_id
        tests:
          - relationships:
              arguments:
                to: ref('customers')
                field: customer_id
"""
    )


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 model+test build execution slice")
def test_build_executes_selected_duckdb_model_and_supported_generic_tests(tmp_path: Path):
    project = tmp_path / "build_model_tests"
    write_supported_model_test_project(
        project,
        "select 1 as customer_id, 'Ada' as customer_name\n",
    )
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Built 1 model(s) and 2 test(s)" in result.stdout
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == [
        "model.build_model_tests.customers",
        "test.build_model_tests.not_null_customers_customer_id.5c9bf9911d",
        "test.build_model_tests.unique_customers_customer_id.c5af1ff4b1",
    ]
    assert [item["status"] for item in run_results["results"]] == ["success", "pass", "pass"]
    assert [item["failures"] for item in run_results["results"]] == [None, 0, 0]
    assert run_results["results"][0]["relation_name"] == '"main"."customers"'
    assert all(item["relation_name"] is None for item in run_results["results"][1:])

    query = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-csv", "-noheader", "-c", 'select customer_id, customer_name from "main"."customers"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert query.returncode == 0, query.stderr
    assert query.stdout.strip() == "1,Ada"


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 model+test build execution failure slice")
def test_build_model_execution_failure_skips_selected_generic_tests(tmp_path: Path):
    project = tmp_path / "build_model_tests"
    write_supported_model_test_project(
        project,
        "select * from missing_relation\n",
    )
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 1
    assert "Build failed after 3 result(s)" in result.stdout
    assert "one or more selected resources failed" in result.stderr
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == [
        "model.build_model_tests.customers",
        "test.build_model_tests.not_null_customers_customer_id.5c9bf9911d",
        "test.build_model_tests.unique_customers_customer_id.c5af1ff4b1",
    ]
    assert [item["status"] for item in run_results["results"]] == ["error", "skipped", "skipped"]
    assert run_results["results"][0]["message"] == "DuckDB execution failed"
    assert run_results["results"][1]["message"] is None
    assert run_results["results"][2]["message"] is None


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 run failure continuation slice")
def test_run_continues_independent_model_after_execution_failure(tmp_path: Path):
    project = tmp_path / "run_failure_continue"
    write_run_failure_continuation_project(project)
    target = tmp_path / "run-target"
    result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 1
    assert "Run failed after 3 result(s)" in result.stdout
    assert "one or more selected resources failed" in result.stderr
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    results_by_id = {item["unique_id"]: item for item in run_results["results"]}
    assert results_by_id["model.run_failure_continue.bad_parent"]["status"] == "error"
    assert results_by_id["model.run_failure_continue.bad_parent"]["message"] == "DuckDB execution failed"
    assert results_by_id["model.run_failure_continue.bad_child"]["status"] == "skipped"
    assert results_by_id["model.run_failure_continue.bad_child"]["message"] is None
    assert results_by_id["model.run_failure_continue.independent"]["status"] == "success"

    query = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-csv", "-noheader", "-c", 'select answer from "main"."independent"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert query.returncode == 0, query.stderr
    assert query.stdout.strip() == "42"


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for build failure continuation coverage")
def test_build_continues_independent_model_after_execution_failure(tmp_path: Path):
    project = tmp_path / "build_failure_continue"
    write_build_failure_continuation_project(project)
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 1
    assert "Build failed after 3 result(s)" in result.stdout
    assert "one or more selected resources failed" in result.stderr
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == [
        "model.build_failure_continue.aa_bad_parent",
        "model.build_failure_continue.ab_bad_child",
        "model.build_failure_continue.zz_independent",
    ]
    assert [item["status"] for item in run_results["results"]] == ["error", "skipped", "success"]
    assert run_results["results"][0]["message"] == "DuckDB execution failed"
    assert run_results["results"][1]["message"] is None
    assert run_results["results"][2]["message"] is None

    independent = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-csv", "-noheader", "-c", 'select answer from "main"."zz_independent"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert independent.returncode == 0, independent.stderr
    assert independent.stdout.strip() == "42"

    blocked_child = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-batch", "-bail", "-c", 'select count(*) from "main"."ab_bad_child"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert blocked_child.returncode != 0


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for build test-failure continuation coverage")
def test_build_continues_independent_model_after_data_test_failure(tmp_path: Path):
    project = tmp_path / "build_test_failure_continue"
    write_build_test_failure_continuation_project(project)
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 1
    assert "Built 3 model(s) and 1 test(s)" in result.stdout
    assert "1 test(s) failed with 1 failure row(s)" in result.stdout
    assert "one or more tests failed" in result.stderr
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == [
        "model.build_test_failure_continue.customers",
        "test.build_test_failure_continue.not_null_customers_customer_id.5c9bf9911d",
        "model.build_test_failure_continue.orders",
        "model.build_test_failure_continue.zz_independent",
    ]
    assert [item["status"] for item in run_results["results"]] == ["success", "fail", "skipped", "success"]
    assert [item["failures"] for item in run_results["results"]] == [None, 1, None, None]

    independent = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-csv", "-noheader", "-c", 'select answer from "main"."zz_independent"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert independent.returncode == 0, independent.stderr
    assert independent.stdout.strip() == "42"

    blocked_orders = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-batch", "-bail", "-c", 'select count(*) from "main"."orders"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert blocked_orders.returncode != 0


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for build seed-failure continuation coverage")
def test_build_continues_independent_seed_model_test_after_seed_failure(tmp_path: Path):
    project = tmp_path / "build_seed_failure_continue"
    write_build_seed_failure_continuation_project(project)
    target = tmp_path / "build-target"
    result = subprocess.run(
        [
            DXT,
            "build",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "aa_bad_seed+ zz_independent_seed+",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )

    assert result.returncode == 1
    assert "Build failed after" in result.stdout
    assert "one or more selected resources failed" in result.stderr
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())

    results_by_id = {item["unique_id"]: item for item in run_results["results"]}
    assert results_by_id["seed.build_seed_failure_continue.aa_bad_seed"]["status"] == "error"
    assert results_by_id["seed.build_seed_failure_continue.aa_bad_seed"]["message"] == "DuckDB execution failed"
    assert results_by_id["model.build_seed_failure_continue.ab_bad_child"]["status"] == "skipped"
    assert results_by_id["model.build_seed_failure_continue.ab_bad_child"]["message"] is None
    assert results_by_id["seed.build_seed_failure_continue.zz_independent_seed"]["status"] == "success"
    assert results_by_id["model.build_seed_failure_continue.zz_independent"]["status"] == "success"

    skipped_test = next(
        item
        for item in run_results["results"]
        if item["unique_id"].startswith("test.build_seed_failure_continue.not_null_ab_bad_child_customer_id.")
    )
    assert skipped_test["status"] == "skipped"
    assert skipped_test["message"] is None
    passed_test = next(
        item
        for item in run_results["results"]
        if item["unique_id"].startswith("test.build_seed_failure_continue.not_null_zz_independent_customer_id.")
    )
    assert passed_test["status"] == "pass"
    assert passed_test["failures"] == 0

    failing_seed_index = next(
        index
        for index, item in enumerate(run_results["results"])
        if item["unique_id"] == "seed.build_seed_failure_continue.aa_bad_seed"
    )
    independent_model_index = next(
        index
        for index, item in enumerate(run_results["results"])
        if item["unique_id"] == "model.build_seed_failure_continue.zz_independent"
    )
    assert failing_seed_index < independent_model_index

    independent = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-csv", "-noheader", "-c", 'select customer_id, customer_name from "main"."zz_independent"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert independent.returncode == 0, independent.stderr
    assert independent.stdout.strip() == "42,Indy"

    blocked_child = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-batch", "-bail", "-c", 'select count(*) from "main"."ab_bad_child"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert blocked_child.returncode != 0


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 generic test command slice")
def test_test_command_executes_selected_duckdb_generic_tests(tmp_path: Path):
    project = tmp_path / "test_command_model_tests"
    write_supported_model_test_project(
        project,
        "select 1 as customer_id, 'Ada' as customer_name\n",
    )
    target = tmp_path / "test-target"
    run_result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert run_result.returncode == 0, run_result.stderr

    test_result = subprocess.run(
        [DXT, "test", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert test_result.returncode == 0, test_result.stderr
    assert "Tested 2 test(s)" in test_result.stdout
    assert_run_results_schema_slice(target / "run_results.json")
    assert_manifest_schema_slice(target / "manifest.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == [
        "test.build_model_tests.not_null_customers_customer_id.5c9bf9911d",
        "test.build_model_tests.unique_customers_customer_id.c5af1ff4b1",
    ]
    assert [item["status"] for item in run_results["results"]] == ["pass", "pass"]
    assert [item["failures"] for item in run_results["results"]] == [0, 0]
    assert all(item["compiled"] is True for item in run_results["results"])
    assert all(item["relation_name"] is None for item in run_results["results"])


def test_parse_emits_generic_test_config_for_model_seed_and_source_tests(tmp_path: Path):
    project = tmp_path / "generic_test_config_parse"
    write_generic_test_config_project(project)
    target = tmp_path / "parse-target"

    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert_manifest_schema_slice(target / "manifest.json")

    manifest = json.loads((target / "manifest.json").read_text())
    tests = {
        node["unique_id"]: node
        for node in manifest["nodes"].values()
        if node["resource_type"] == "test" and node["test_metadata"]["name"] == "not_null"
    }
    assert sorted(tests) == [
        "test.generic_test_config_tests.not_null_customers_customer_id.5c9bf9911d",
        "test.generic_test_config_tests.not_null_raw_customers_customer_id.ad2454198a",
        "test.generic_test_config_tests.source_not_null_raw_orders_customer_id.bbc5804683",
    ]
    model_test = tests["test.generic_test_config_tests.not_null_customers_customer_id.5c9bf9911d"]
    assert model_test["database"] == "memory"
    assert model_test["schema"] == "main_dbt_test__audit"
    assert model_test["alias"] == "not_null_customers_customer_id"
    assert model_test["fqn"] == ["generic_test_config_tests", "not_null_customers_customer_id"]
    assert model_test["checksum"] == {"name": "none", "checksum": ""}

    model_config = model_test["config"]
    assert model_config["where"] == "status = 'checked'"
    assert model_config["limit"] == 1
    assert model_config["severity"] == "warn"
    assert model_config["warn_if"] == "> 0"
    assert model_config["error_if"] == "> 0"
    assert model_config["store_failures"] is None

    seed_config = tests["test.generic_test_config_tests.not_null_raw_customers_customer_id.ad2454198a"]["config"]
    assert seed_config["where"] == "status = 'checked'"
    assert seed_config["limit"] == 2
    assert seed_config["severity"] == "error"
    assert seed_config["warn_if"] == "> 1"
    assert seed_config["error_if"] == "> 2"
    assert seed_config["store_failures"] is None

    source_config = tests["test.generic_test_config_tests.source_not_null_raw_orders_customer_id.bbc5804683"]["config"]
    assert source_config["where"] == "status = 'checked'"
    assert source_config["limit"] == 3
    assert source_config["severity"] == "warn"
    assert source_config["warn_if"] == "> 0"
    assert source_config["error_if"] == "> 10"
    assert source_config["store_failures"] is None


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for generic test config execution coverage")
def test_generic_test_configs_drive_test_and_build_statuses(tmp_path: Path):
    project = tmp_path / "generic_test_config_execution"
    write_generic_test_config_project(project, severity="warn", error_if="> 0")
    target = tmp_path / "test-target"

    run_result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert run_result.returncode == 0, run_result.stderr

    test_result = subprocess.run(
        [DXT, "test", "--project-dir", str(project), "--target-path", str(target), "--select", "not_null_customers_customer_id"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert test_result.returncode == 0, test_result.stderr
    assert "Tested 1 test(s)" in test_result.stdout
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    result = run_results["results"][0]
    assert result["status"] == "warn"
    assert result["failures"] == 1
    assert result["message"] == "Got 1 result, configured to warn if > 0"
    assert "from (select * from" in result["compiled_code"]
    assert "status = 'checked'" in result["compiled_code"]
    assert result["compiled_code"].endswith("limit 1")

    write_generic_test_config_project(project, severity="error", error_if="> 0")
    fail_target = tmp_path / "build-fail-target"
    fail_result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(fail_target), "--select", "customers+"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert fail_result.returncode == 1
    assert "1 test(s) failed with 1 failure row(s)" in fail_result.stdout
    assert "one or more tests failed" in fail_result.stderr
    fail_results = json.loads((fail_target / "run_results.json").read_text())
    assert [item["status"] for item in fail_results["results"]] == ["success", "fail"]
    assert fail_results["results"][1]["message"] == "Got 1 result, configured to fail if > 0"

    write_generic_test_config_project(project, severity="error", error_if="> 0", where="status = 'missing'")
    pass_target = tmp_path / "build-pass-target"
    pass_result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(pass_target), "--select", "customers+"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert pass_result.returncode == 0, pass_result.stderr
    pass_results = json.loads((pass_target / "run_results.json").read_text())
    assert [item["status"] for item in pass_results["results"]] == ["success", "pass"]
    assert pass_results["results"][1]["failures"] == 0


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for generic test store_failures coverage")
def test_generic_test_store_failures_materializes_and_drops_audit_relation(tmp_path: Path):
    project = tmp_path / "generic_test_store_failures"
    write_generic_test_config_project(project, severity="error", error_if="> 0", store_failures=True)
    target = tmp_path / "store-target"
    db_path = target / "dxt.duckdb"

    run_result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert run_result.returncode == 0, run_result.stderr

    test_result = subprocess.run(
        [DXT, "test", "--project-dir", str(project), "--target-path", str(target), "--select", "not_null_customers_customer_id"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert test_result.returncode == 1
    assert "1 test(s) failed with 1 failure row(s)" in test_result.stdout
    assert_run_results_schema_slice(target / "run_results.json")
    assert_manifest_schema_slice(target / "manifest.json")
    run_results = json.loads((target / "run_results.json").read_text())
    result = run_results["results"][0]
    assert result["status"] == "fail"
    assert result["relation_name"] == '"dbt_test__audit"."not_null_customers_customer_id"'
    assert result["compiled_code"].endswith("limit 1")
    manifest = json.loads((target / "manifest.json").read_text())
    test_node = manifest["nodes"][result["unique_id"]]
    assert test_node["config"]["store_failures"] is True
    assert duckdb_scalar(db_path, 'select count(*) from "dbt_test__audit"."not_null_customers_customer_id"') == "1"

    write_generic_test_config_project(
        project,
        severity="error",
        error_if="> 0",
        where="status = 'missing'",
        store_failures=True,
    )
    pass_result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "customers+"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert pass_result.returncode == 0, pass_result.stderr
    pass_results = json.loads((target / "run_results.json").read_text())
    assert [item["status"] for item in pass_results["results"]] == ["success", "pass"]
    assert pass_results["results"][1]["relation_name"] is None
    assert (
        duckdb_scalar(
            db_path,
            "select count(*) from information_schema.tables where table_schema = 'dbt_test__audit' and table_name = 'not_null_customers_customer_id'",
        )
        == "0"
    )


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 generic test command slice")
def test_test_command_does_not_build_missing_parent_relation(tmp_path: Path):
    project = tmp_path / "test_command_missing_parent"
    write_supported_model_test_project(
        project,
        "select 1 as customer_id, 'Ada' as customer_name\n",
    )
    target = tmp_path / "test-target"

    result = subprocess.run(
        [DXT, "test", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "DuckDB execution failed" in result.stderr
    assert (target / "manifest.json").exists()
    assert not (target / "run_results.json").exists()

    if (target / "dxt.duckdb").exists():
        query = subprocess.run(
            [
                DUCKDB,
                str(target / "dxt.duckdb"),
                "-csv",
                "-noheader",
                "-c",
                "select count(*) from information_schema.tables where table_schema = 'main' and table_name = 'customers'",
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        assert query.returncode == 0, query.stderr
        assert query.stdout.strip() == "0"


def test_parse_lists_singular_sql_tests_and_skips_generic_test_dirs(tmp_path: Path):
    project = tmp_path / "singular_tests"
    write_singular_test_project(
        project,
        "select 1 as customer_id\n",
        "select * from {{ ref('customers') }} where customer_id is null;\n",
    )
    target = tmp_path / "parse-target"

    parse_result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert parse_result.returncode == 0, parse_result.stderr
    assert_manifest_schema_slice(target / "manifest.json")
    manifest = json.loads((target / "manifest.json").read_text())
    test_ids = sorted(unique_id for unique_id in manifest["nodes"] if unique_id.startswith("test."))
    assert test_ids == ["test.singular_tests.assert_customers"]
    node = manifest["nodes"]["test.singular_tests.assert_customers"]
    assert node["resource_type"] == "test"
    assert node["name"] == "assert_customers"
    assert node["database"] == "memory"
    assert node["schema"] == "main_dbt_test__audit"
    assert node["alias"] == "assert_customers"
    assert node["fqn"] == ["singular_tests", "assert_customers"]
    assert node["checksum"] == dbt_sha256_text((project / "tests" / "assert_customers.sql").read_text())
    assert node["path"] == "assert_customers.sql"
    assert node["original_file_path"] == "tests/assert_customers.sql"
    assert "test_metadata" not in node
    assert "column_name" not in node
    assert "attached_node" not in node
    assert node["refs"] == [{"name": "customers", "package": None, "version": None}]
    assert manifest["parent_map"]["test.singular_tests.assert_customers"] == ["model.singular_tests.customers"]
    assert manifest["child_map"]["model.singular_tests.customers"] == ["test.singular_tests.assert_customers"]
    assert all("ignored" not in unique_id for unique_id in manifest["nodes"])

    list_result = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "test_type:singular", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert list_result.returncode == 0, list_result.stderr
    assert json.loads(list_result.stdout) == [
        {"unique_id": "test.singular_tests.assert_customers", "resource_type": "test", "name": "assert_customers"}
    ]

    generic_result = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "test_type:generic", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert generic_result.returncode == 0, generic_result.stderr
    assert json.loads(generic_result.stdout) == []

    data_result = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "test_type:data", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert data_result.returncode == 0, data_result.stderr
    assert json.loads(data_result.stdout) == [
        {"unique_id": "test.singular_tests.assert_customers", "resource_type": "test", "name": "assert_customers"}
    ]

    dependency_result = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "customers", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert dependency_result.returncode == 0, dependency_result.stderr
    assert json.loads(dependency_result.stdout) == [
        {"unique_id": "model.singular_tests.customers", "resource_type": "model", "name": "customers"},
        {"unique_id": "test.singular_tests.assert_customers", "resource_type": "test", "name": "assert_customers"},
    ]


def test_inline_disabled_singular_sql_test_is_not_active(tmp_path: Path):
    project = tmp_path / "singular_tests"
    write_singular_test_project(
        project,
        "select 1 as customer_id\n",
        "select * from {{ ref('customers') }} where customer_id is null;\n",
    )
    (project / "tests" / "disabled_missing_ref.sql").write_text(
        "{{ config(enabled=false) }}\nselect * from {{ ref('missing_model') }}\n"
    )
    target = tmp_path / "parse-target"

    parse_result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert parse_result.returncode == 0, parse_result.stderr
    manifest_path = target / "manifest.json"
    assert_manifest_schema_slice(manifest_path)
    manifest = json.loads(manifest_path.read_text())
    assert sorted(unique_id for unique_id in manifest["nodes"] if unique_id.startswith("test.")) == [
        "test.singular_tests.assert_customers"
    ]
    disabled_id = "test.singular_tests.disabled_missing_ref"
    assert disabled_id not in manifest["parent_map"]
    assert disabled_id not in manifest["child_map"]
    assert list(manifest["disabled"]) == [disabled_id]
    disabled_test = manifest["disabled"][disabled_id][0]
    assert disabled_test["database"] == "memory"
    assert disabled_test["schema"] == "main_dbt_test__audit"
    assert disabled_test["alias"] == "disabled_missing_ref"
    assert disabled_test["fqn"] == ["singular_tests", "disabled_missing_ref"]
    assert disabled_test["checksum"] == dbt_sha256_text((project / "tests" / "disabled_missing_ref.sql").read_text())
    assert disabled_test["config"]["enabled"] is False
    assert disabled_test["refs"] == [{"name": "missing_model", "package": None, "version": None}]
    assert disabled_test["depends_on"]["nodes"] == []

    list_result = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "test_type:singular", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert list_result.returncode == 0, list_result.stderr
    assert json.loads(list_result.stdout) == [
        {"unique_id": "test.singular_tests.assert_customers", "resource_type": "test", "name": "assert_customers"}
    ]

    compile_target = tmp_path / "compile-target"
    compile_result = subprocess.run(
        [DXT, "compile", "--project-dir", str(project), "--target-path", str(compile_target), "--select", "test_type:singular"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert compile_result.returncode == 0, compile_result.stderr
    assert "Compiled 0 model(s) and 1 test(s)" in compile_result.stdout
    compiled_root = compile_target / "compiled" / "singular_tests" / "tests"
    assert sorted(path.name for path in compiled_root.glob("*.sql")) == ["assert_customers.sql"]


def test_compile_writes_selected_singular_sql_test_artifacts_without_duckdb(tmp_path: Path):
    project = tmp_path / "singular_tests"
    write_singular_test_project(
        project,
        "select 1 as customer_id\n",
        "select * from {{ ref('customers') }} where customer_id is null;\n",
    )
    target = tmp_path / "compile-target"

    result = subprocess.run(
        [DXT, "compile", "--project-dir", str(project), "--target-path", str(target), "--select", "test_type:singular"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Compiled 0 model(s) and 1 test(s)" in result.stdout
    assert not (target / "dxt.duckdb").exists()

    compiled_path = target / "compiled" / "singular_tests" / "tests" / "assert_customers.sql"
    compiled_sql = compiled_path.read_text()
    assert compiled_sql.strip() == 'select * from "main"."customers" where customer_id is null;'

    manifest_path = target / "manifest.json"
    assert_manifest_schema_slice(manifest_path)
    manifest = json.loads(manifest_path.read_text())
    test_node = manifest["nodes"]["test.singular_tests.assert_customers"]
    assert test_node["compiled"] is True
    assert test_node["compiled_code"] == compiled_sql
    assert test_node["compiled_path"].endswith("/compiled/singular_tests/tests/assert_customers.sql")
    assert test_node["extra_ctes"] == []
    assert test_node["extra_ctes_injected"] is False
    assert "test_metadata" not in test_node
    assert "column_name" not in test_node
    assert "attached_node" not in test_node
    assert "compiled" not in manifest["nodes"]["model.singular_tests.customers"]


def test_parse_and_compile_apply_singular_sql_test_yaml_patches(tmp_path: Path):
    project = tmp_path / "singular_test_configs"
    write_singular_test_config_project(project)
    target = tmp_path / "parse-target"

    parse_result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert parse_result.returncode == 0, parse_result.stderr
    assert_manifest_schema_slice(target / "manifest.json")
    manifest = json.loads((target / "manifest.json").read_text())

    test_id = "test.singular_test_configs.assert_customers"
    disabled_id = "test.singular_test_configs.disabled_assert"
    assert sorted(unique_id for unique_id in manifest["nodes"] if unique_id.startswith("test.")) == [test_id]
    assert list(manifest["disabled"]) == [disabled_id]

    test_node = manifest["nodes"][test_id]
    assert test_node["description"] == "patched singular test"
    assert test_node["patch_path"] == "singular_test_configs://tests/schema.yml"
    assert test_node["tags"] == ["singular_yaml", "nightly"]
    assert test_node["config"]["enabled"] is True
    assert test_node["config"]["tags"] == ["singular_yaml", "nightly"]
    assert test_node["config"]["where"] == "status = 'checked'"
    assert test_node["config"]["limit"] == 1
    assert test_node["config"]["severity"] == "Warn"
    assert test_node["config"]["warn_if"] == "> 0"
    assert test_node["config"]["error_if"] == "> 10"
    assert "test_metadata" not in test_node
    assert "column_name" not in test_node
    assert "attached_node" not in test_node

    disabled_test = manifest["disabled"][disabled_id][0]
    assert disabled_test["config"]["enabled"] is False
    assert disabled_test["config"]["tags"] == ["disabled_yaml"]
    assert disabled_test["depends_on"]["nodes"] == []

    list_result = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "tag:singular_yaml", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert list_result.returncode == 0, list_result.stderr
    assert json.loads(list_result.stdout) == [
        {"unique_id": test_id, "resource_type": "test", "name": "assert_customers"}
    ]

    compile_target = tmp_path / "compile-target"
    compile_result = subprocess.run(
        [DXT, "compile", "--project-dir", str(project), "--target-path", str(compile_target), "--select", "tag:singular_yaml"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert compile_result.returncode == 0, compile_result.stderr
    assert "Compiled 0 model(s) and 1 test(s)" in compile_result.stdout
    compiled_sql = (compile_target / "compiled" / "singular_test_configs" / "tests" / "assert_customers.sql").read_text()
    assert compiled_sql.strip() == 'select * from "main"."customers" where customer_id > 0;'
    compiled_manifest = json.loads((compile_target / "manifest.json").read_text())
    compiled_test = compiled_manifest["nodes"][test_id]
    assert compiled_test["compiled"] is True
    assert compiled_test["config"]["where"] == "status = 'checked'"
    assert compiled_test["config"]["limit"] == 1


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for singular SQL test config execution coverage")
def test_singular_sql_test_yaml_configs_drive_test_and_build_statuses(tmp_path: Path):
    project = tmp_path / "singular_test_configs"
    write_singular_test_config_project(project, severity="warn", error_if="> 10")
    target = tmp_path / "warn-target"

    build_result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "customers+"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert build_result.returncode == 0, build_result.stderr
    assert "Built 1 model(s) and 1 test(s)" in build_result.stdout
    assert_run_results_schema_slice(target / "run_results.json")
    warn_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in warn_results["results"]] == [
        "model.singular_test_configs.customers",
        "test.singular_test_configs.assert_customers",
    ]
    assert [item["status"] for item in warn_results["results"]] == ["success", "warn"]
    warn_test = warn_results["results"][1]
    assert warn_test["failures"] == 1
    assert warn_test["message"] == "Got 1 result, configured to warn if > 0"
    assert "dbt_internal_test where status = 'checked'" in warn_test["compiled_code"]
    assert warn_test["compiled_code"].endswith("limit 1")

    test_result = subprocess.run(
        [DXT, "test", "--project-dir", str(project), "--target-path", str(target), "--select", "tag:singular_yaml"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert test_result.returncode == 0, test_result.stderr
    assert "Tested 1 test(s)" in test_result.stdout
    test_results = json.loads((target / "run_results.json").read_text())
    assert [item["status"] for item in test_results["results"]] == ["warn"]
    assert test_results["results"][0]["message"] == "Got 1 result, configured to warn if > 0"

    write_singular_test_config_project(project, severity="error", error_if="> 0")
    fail_target = tmp_path / "fail-target"
    fail_result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(fail_target), "--select", "customers+"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert fail_result.returncode == 1
    assert "1 test(s) failed with 1 failure row(s)" in fail_result.stdout
    assert "one or more tests failed" in fail_result.stderr
    fail_results = json.loads((fail_target / "run_results.json").read_text())
    assert [item["status"] for item in fail_results["results"]] == ["success", "fail"]
    assert fail_results["results"][1]["message"] == "Got 1 result, configured to fail if > 0"


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for singular SQL test store_failures coverage")
def test_singular_sql_test_store_failures_supports_inline_config_and_drop_on_pass(tmp_path: Path):
    project = tmp_path / "singular_store_failures"
    write_singular_test_config_project(
        project,
        severity="error",
        error_if="> 0",
        store_failures=False,
        inline_store_failures=True,
    )
    target = tmp_path / "store-target"
    db_path = target / "dxt.duckdb"

    build_result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "customers+"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert build_result.returncode == 1
    assert "1 test(s) failed with 1 failure row(s)" in build_result.stdout
    assert_run_results_schema_slice(target / "run_results.json")
    assert_manifest_schema_slice(target / "manifest.json")
    run_results = json.loads((target / "run_results.json").read_text())
    result = run_results["results"][1]
    assert result["unique_id"] == "test.singular_test_configs.assert_customers"
    assert result["status"] == "fail"
    assert result["relation_name"] == '"dbt_test__audit"."assert_customers"'
    manifest = json.loads((target / "manifest.json").read_text())
    assert manifest["nodes"][result["unique_id"]]["config"]["store_failures"] is True
    assert duckdb_scalar(db_path, 'select count(*) from "dbt_test__audit"."assert_customers"') == "1"

    (project / "tests" / "assert_customers.sql").write_text(
        "{{ config(store_failures=true) }}\nselect * from {{ ref('customers') }} where customer_id < 0;\n"
    )
    pass_result = subprocess.run(
        [DXT, "test", "--project-dir", str(project), "--target-path", str(target), "--select", "tag:singular_yaml"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert pass_result.returncode == 0, pass_result.stderr
    pass_results = json.loads((target / "run_results.json").read_text())
    assert [item["status"] for item in pass_results["results"]] == ["pass"]
    assert pass_results["results"][0]["relation_name"] is None
    assert (
        duckdb_scalar(
            db_path,
            "select count(*) from information_schema.tables where table_schema = 'dbt_test__audit' and table_name = 'assert_customers'",
        )
        == "0"
    )


def test_compile_writes_selected_generic_test_artifacts_without_duckdb(tmp_path: Path):
    project = copy_fixture(tmp_path, "generic_test_arguments")
    schema_path = project / "models" / "schema.yml"
    schema_path.write_text(schema_path.read_text().replace("          - unique\n", "          - unique\n          - not_null\n", 1))
    target = tmp_path / "compile-target"

    result = subprocess.run(
        [DXT, "compile", "--project-dir", str(project), "--target-path", str(target), "--select", "test_type:generic"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Compiled 0 model(s) and 5 test(s)" in result.stdout
    assert not (target / "dxt.duckdb").exists()
    assert not (target / "run_results.json").exists()

    manifest_path = target / "manifest.json"
    assert_manifest_schema_slice(manifest_path)
    manifest = json.loads(manifest_path.read_text())
    test_nodes = [
        node
        for node in manifest["nodes"].values()
        if node["resource_type"] == "test" and node["test_metadata"]["name"] in {"not_null", "unique", "relationships", "accepted_values"}
    ]
    assert len(test_nodes) == 5
    assert all(node["compiled"] is True for node in test_nodes)
    assert all(node["extra_ctes"] == [] for node in test_nodes)
    assert all(node["extra_ctes_injected"] is False for node in test_nodes)

    accepted_values = next(node for node in test_nodes if node["name"].startswith("accepted_values_orders_status__"))
    assert "with all_values as" in accepted_values["compiled_code"]
    assert "\"status\" as value_field" in accepted_values["compiled_code"]
    assert "value_field not in ('placed', 'shipped', 'completed', 'return_pending', 'returned')" in accepted_values["compiled_code"]
    compiled_path = Path(accepted_values["compiled_path"])
    assert compiled_path.exists()
    assert compiled_path.read_text() == accepted_values["compiled_code"]
    assert compiled_path.parent == target / "compiled" / "generic_test_arguments"
    assert compiled_path.name.startswith("accepted_values_orders_")
    assert compiled_path.suffix == ".sql"

    relationship = next(node for node in test_nodes if node["test_metadata"]["name"] == "relationships")
    assert "left join parent" in relationship["compiled_code"]
    assert '"main"."customers"' in relationship["compiled_code"]

    not_null = next(node for node in test_nodes if node["test_metadata"]["name"] == "not_null")
    assert 'from "main"."customers"' in not_null["compiled_code"]
    assert 'where "customer_id" is null' in not_null["compiled_code"]


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for singular SQL test execution coverage")
def test_build_and_test_execute_singular_sql_tests(tmp_path: Path):
    project = tmp_path / "singular_tests"
    write_singular_test_project(
        project,
        "select 1 as customer_id, 'Ada' as customer_name\n",
        "select * from {{ ref('customers') }} where customer_id is null;\n",
    )
    (project / "tests" / "disabled_missing_ref.sql").write_text(
        "{{ config(enabled=false) }}\nselect * from {{ ref('missing_model') }}\n"
    )
    target = tmp_path / "singular-target"

    build_result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "customers+"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert build_result.returncode == 0, build_result.stderr
    assert "Built 1 model(s) and 1 test(s)" in build_result.stdout
    assert_manifest_schema_slice(target / "manifest.json")
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == [
        "model.singular_tests.customers",
        "test.singular_tests.assert_customers",
    ]
    assert [item["status"] for item in run_results["results"]] == ["success", "pass"]
    assert run_results["results"][1]["failures"] == 0
    assert 'from "main"."customers"' in run_results["results"][1]["compiled_code"]

    (project / "tests" / "assert_customers.sql").write_text(
        "select * from {{ ref('customers') }} where customer_id = 1;\n"
    )
    test_result = subprocess.run(
        [DXT, "test", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert test_result.returncode == 1
    assert "1 test(s) failed with 1 failure row(s)" in test_result.stdout
    assert "one or more tests failed" in test_result.stderr
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == ["test.singular_tests.assert_customers"]
    assert run_results["results"][0]["status"] == "fail"
    assert run_results["results"][0]["failures"] == 1


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 accepted_values build execution slice")
def test_build_executes_selected_duckdb_accepted_values_generic_test(tmp_path: Path):
    project = tmp_path / "accepted_values_tests"
    write_accepted_values_model_test_project(
        project,
        "{{ config(materialized='table') }}\n"
        "select 1 as customer_id, 'new' as customer_type\n"
        "union all\n"
        "select 2 as customer_id, 'returning' as customer_type\n",
    )
    target = tmp_path / "build-target"
    run_result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert run_result.returncode == 0, run_result.stderr

    build_result = subprocess.run(
        [
            DXT,
            "build",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "accepted_values_customers_customer_type__new__returning",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert build_result.returncode == 0, build_result.stderr
    assert "Built 1 test(s)" in build_result.stdout
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert len(run_results["results"]) == 1
    result = run_results["results"][0]
    assert result["unique_id"].startswith(
        "test.accepted_values_tests.accepted_values_customers_customer_type__new__returning."
    )
    assert result["status"] == "pass"
    assert result["failures"] == 0
    assert result["compiled"] is True
    assert "with all_values as" in result["compiled_code"]
    assert "\"customer_type\" as value_field" in result["compiled_code"]
    assert "value_field not in ('new', 'returning')" in result["compiled_code"]
    assert "dbt_internal_test" not in result["compiled_code"]
    assert result["relation_name"] is None


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 accepted_values quote false build execution slice")
def test_build_executes_selected_duckdb_accepted_values_quote_false_generic_test(tmp_path: Path):
    project = tmp_path / "accepted_values_quote_false_tests"
    write_accepted_values_quote_false_model_test_project(
        project,
        "{{ config(materialized='table') }}\n"
        "select 1 as customer_id, 'Ada' as customer_name\n"
        "union all\n"
        "select 2 as customer_id, 'Bob' as customer_name\n",
    )
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Built 1 model(s) and 1 test(s)" in result.stdout
    assert_manifest_schema_slice(target / "manifest.json")
    manifest = json.loads((target / "manifest.json").read_text())
    test_nodes = [node for node in manifest["nodes"].values() if node["resource_type"] == "test"]
    assert len(test_nodes) == 1
    test_node = test_nodes[0]
    assert test_node["name"] == "accepted_values_customers_customer_id__False__1__2"
    assert (
        test_node["unique_id"]
        == "test.accepted_values_quote_false_tests.accepted_values_customers_customer_id__False__1__2.d3fda7ba1b"
    )
    assert test_node["test_metadata"]["kwargs"]["values"] == ["1", "2"]
    assert test_node["test_metadata"]["kwargs"]["quote"] is False
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["status"] for item in run_results["results"]] == ["success", "pass"]
    compiled_code = run_results["results"][1]["compiled_code"]
    assert "value_field not in (1, 2)" in compiled_code
    assert "value_field not in ('1', '2')" not in compiled_code


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 accepted_values build execution slice")
def test_build_reports_failing_duckdb_accepted_values_generic_test(tmp_path: Path):
    project = tmp_path / "accepted_values_tests"
    write_accepted_values_model_test_project(
        project,
        "{{ config(materialized='table') }}\n"
        "select 1 as customer_id, 'new' as customer_type\n"
        "union all\n"
        "select 2 as customer_id, 'legacy' as customer_type\n"
        "union all\n"
        "select 3 as customer_id, 'legacy' as customer_type\n",
    )
    target = tmp_path / "build-target"
    run_result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert run_result.returncode == 0, run_result.stderr

    build_result = subprocess.run(
        [
            DXT,
            "build",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "accepted_values_customers_customer_type__new__returning",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert build_result.returncode == 1
    assert "1 test(s) failed with 1 failure row(s)" in build_result.stdout
    assert "one or more tests failed" in build_result.stderr
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["status"] for item in run_results["results"]] == ["fail"]
    assert [item["failures"] for item in run_results["results"]] == [1]
    assert run_results["results"][0]["message"] == "Got 1 result, configured to fail if != 0"


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 accepted_values quote false build execution slice")
def test_build_reports_failing_duckdb_accepted_values_quote_false_generic_test(tmp_path: Path):
    project = tmp_path / "accepted_values_quote_false_tests"
    write_accepted_values_quote_false_model_test_project(
        project,
        "{{ config(materialized='table') }}\n"
        "select 1 as customer_id, 'Ada' as customer_name\n"
        "union all\n"
        "select 3 as customer_id, 'Cara' as customer_name\n",
    )
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 1
    assert "1 test(s) failed with 1 failure row(s)" in result.stdout
    assert "one or more tests failed" in result.stderr
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["status"] for item in run_results["results"]] == ["success", "fail"]
    assert [item["failures"] for item in run_results["results"]] == [None, 1]
    assert "value_field not in (1, 2)" in run_results["results"][1]["compiled_code"]


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 accepted_values model+test build execution slice")
def test_build_executes_selected_duckdb_model_and_accepted_values_generic_test(tmp_path: Path):
    project = tmp_path / "accepted_values_tests"
    write_accepted_values_model_test_project(
        project,
        "{{ config(materialized='table') }}\n"
        "select 1 as customer_id, 'new' as customer_type\n"
        "union all\n"
        "select 2 as customer_id, 'returning' as customer_type\n",
    )
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Built 1 model(s) and 1 test(s)" in result.stdout
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["status"] for item in run_results["results"]] == ["success", "pass"]
    assert run_results["results"][0]["unique_id"] == "model.accepted_values_tests.customers"
    assert run_results["results"][1]["unique_id"].startswith(
        "test.accepted_values_tests.accepted_values_customers_customer_type__new__returning."
    )


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 source column generic-test build execution slice")
def test_build_executes_selected_duckdb_source_column_generic_tests(tmp_path: Path):
    project = tmp_path / "source_column_tests"
    write_source_column_test_project(project)
    target = tmp_path / "build-target"
    target.mkdir()
    setup = subprocess.run(
        [
            DUCKDB,
            str(target / "dxt.duckdb"),
            "-batch",
            "-bail",
            "-c",
            (
                'create schema raw; '
                'create table raw.raw_customers as '
                "select 1 as customer_id, 'new' as customer_type union all "
                "select 2 as customer_id, 'returning' as customer_type"
            ),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert setup.returncode == 0, setup.stderr

    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "source:raw.customers+"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Built 3 source test(s)" in result.stdout
    assert_manifest_schema_slice(target / "manifest.json")
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["status"] for item in run_results["results"]] == ["pass", "pass", "pass"]
    assert [item["failures"] for item in run_results["results"]] == [0, 0, 0]
    assert all(item["relation_name"] is None for item in run_results["results"])
    assert all('"raw"."raw_customers"' in item["compiled_code"] for item in run_results["results"])
    assert run_results["results"][0]["unique_id"].startswith(
        "test.source_column_tests.source_accepted_values_raw_customers_customer_type__new__returning."
    )
    assert run_results["results"][1]["unique_id"].startswith(
        "test.source_column_tests.source_not_null_raw_customers_customer_id."
    )
    assert run_results["results"][2]["unique_id"].startswith(
        "test.source_column_tests.source_unique_raw_customers_customer_id."
    )

    manifest = json.loads((target / "manifest.json").read_text())
    source_node = manifest["sources"]["source.source_column_tests.raw.customers"]
    assert source_node["name"] == "customers"
    assert source_node["identifier"] == "raw_customers"
    assert sorted(source_node["columns"]) == ["customer_id", "customer_type"]
    assert source_node["columns"]["customer_id"]["name"] == "customer_id"
    assert source_node["columns"]["customer_type"]["name"] == "customer_type"
    source_test = manifest["nodes"][run_results["results"][1]["unique_id"]]
    assert source_test["resource_type"] == "test"
    assert source_test["attached_node"] is None
    assert source_test["sources"] == [["raw", "customers"]]
    assert source_test["refs"] == []
    assert source_test["depends_on"]["nodes"] == ["source.source_column_tests.raw.customers"]
    assert source_test["test_metadata"]["kwargs"]["model"] == "{{ get_where_subquery(source('raw', 'customers')) }}"
    assert "source.source_column_tests.raw.customers" in manifest["parent_map"][source_test["unique_id"]]
    assert source_test["unique_id"] in manifest["child_map"]["source.source_column_tests.raw.customers"]


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 source accepted_values quote false build execution slice")
def test_build_executes_selected_duckdb_source_accepted_values_quote_false_generic_test(tmp_path: Path):
    project = tmp_path / "source_column_quote_false_tests"
    write_source_column_quote_false_test_project(project)
    target = tmp_path / "build-target"
    target.mkdir()
    setup = subprocess.run(
        [
            DUCKDB,
            str(target / "dxt.duckdb"),
            "-batch",
            "-bail",
            "-c",
            "create schema raw; create table raw.raw_customers as select 1 as customer_id union all select 2 as customer_id",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert setup.returncode == 0, setup.stderr

    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "source:raw.customers+"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Built 1 source test(s)" in result.stdout
    assert_manifest_schema_slice(target / "manifest.json")
    manifest = json.loads((target / "manifest.json").read_text())
    test_nodes = [node for node in manifest["nodes"].values() if node["resource_type"] == "test"]
    assert len(test_nodes) == 1
    assert test_nodes[0]["name"] == "source_accepted_values_raw_customers_customer_id__False__1__2"
    assert test_nodes[0]["test_metadata"]["kwargs"]["quote"] is False
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["status"] for item in run_results["results"]] == ["pass"]
    assert "value_field not in (1, 2)" in run_results["results"][0]["compiled_code"]


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 source relationships build execution slice")
def test_build_executes_selected_duckdb_source_relationships_generic_test(tmp_path: Path):
    project = tmp_path / "source_relationship_tests"
    write_source_relationships_test_project(project)
    target = tmp_path / "build-target"
    target.mkdir()
    setup = subprocess.run(
        [
            DUCKDB,
            str(target / "dxt.duckdb"),
            "-batch",
            "-bail",
            "-c",
            (
                'create schema raw; '
                'create table raw.raw_orders as '
                "select 10 as order_id, 1 as customer_id union all "
                "select 11 as order_id, null as customer_id"
            ),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert setup.returncode == 0, setup.stderr
    run_result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert run_result.returncode == 0, run_result.stderr

    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "source:raw.orders+"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Built 1 source test(s)" in result.stdout
    assert_manifest_schema_slice(target / "manifest.json")
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["status"] for item in run_results["results"]] == ["pass"]
    assert [item["failures"] for item in run_results["results"]] == [0]
    assert '"raw"."raw_orders"' in run_results["results"][0]["compiled_code"]
    assert '"main"."customers"' in run_results["results"][0]["compiled_code"]

    manifest = json.loads((target / "manifest.json").read_text())
    test_nodes = [node for node in manifest["nodes"].values() if node["resource_type"] == "test"]
    assert len(test_nodes) == 1
    source_test = test_nodes[0]
    assert source_test["unique_id"] == (
        "test.source_relationship_tests."
        "source_relationships_raw_orders_customer_id__customer_id__ref_customers_.3e4b1c44ba"
    )
    assert source_test["name"] == "source_relationships_raw_orders_customer_id__customer_id__ref_customers_"
    assert source_test["alias"] == "source_relationships_raw_order_8c30d56dac3d54f4441e780eb728bb72"
    assert source_test["path"] == "source_relationships_raw_order_8c30d56dac3d54f4441e780eb728bb72.sql"
    assert source_test["raw_code"] == '{{ test_relationships(**_dbt_generic_test_kwargs) }}{{ config(alias="source_relationships_raw_order_8c30d56dac3d54f4441e780eb728bb72") }}'
    assert source_test["attached_node"] is None
    assert source_test["sources"] == [["raw", "orders"]]
    assert source_test["refs"] == [{"name": "customers", "package": None, "version": None}]
    assert source_test["depends_on"]["nodes"] == [
        "source.source_relationship_tests.raw.orders",
        "model.source_relationship_tests.customers",
    ]
    assert source_test["test_metadata"]["kwargs"] == {
        "model": "{{ get_where_subquery(source('raw', 'orders')) }}",
        "column_name": "customer_id",
        "to": "ref('customers')",
        "field": "customer_id",
    }
    assert source_test["unique_id"] in manifest["child_map"]["source.source_relationship_tests.raw.orders"]
    assert source_test["unique_id"] in manifest["child_map"]["model.source_relationship_tests.customers"]


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 source relationships build execution slice")
def test_build_reports_failing_duckdb_source_relationships_generic_test(tmp_path: Path):
    project = tmp_path / "source_relationship_tests"
    write_source_relationships_test_project(project)
    target = tmp_path / "build-target"
    target.mkdir()
    setup = subprocess.run(
        [
            DUCKDB,
            str(target / "dxt.duckdb"),
            "-batch",
            "-bail",
            "-c",
            "create schema raw; create table raw.raw_orders as select 10 as order_id, 99 as customer_id",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert setup.returncode == 0, setup.stderr
    run_result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert run_result.returncode == 0, run_result.stderr

    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "source:raw.orders+"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 1
    assert "Built 1 source test(s)" in result.stdout
    assert "1 test(s) failed with 1 failure row(s)" in result.stdout
    assert "one or more tests failed" in result.stderr
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["status"] for item in run_results["results"]] == ["fail"]
    assert [item["failures"] for item in run_results["results"]] == [1]


def test_parse_records_source_target_relationship_generic_tests(tmp_path: Path):
    project = tmp_path / "source_target_relationship_tests"
    write_source_target_relationships_manifest_project(project)
    target = tmp_path / "parse-target"
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert_manifest_schema_slice(target / "manifest.json")
    manifest = json.loads((target / "manifest.json").read_text())
    tests = {
        node["name"]: node
        for node in manifest["nodes"].values()
        if node["resource_type"] == "test"
    }
    assert sorted(tests) == [
        "relationships_orders_model_customer_id__customer_id__source_raw_customers_",
        "relationships_orders_seed_customer_id__customer_id__source_raw_customers_",
        "source_relationships_raw_orders_customer_id__customer_id__source_raw_customers_",
    ]

    model_test = tests["relationships_orders_model_customer_id__customer_id__source_raw_customers_"]
    assert model_test["attached_node"] == "model.source_target_relationship_tests.orders_model"
    assert model_test["refs"] == [{"name": "orders_model", "package": None, "version": None}]
    assert model_test["sources"] == [["raw", "customers"]]
    assert model_test["depends_on"]["nodes"] == [
        "source.source_target_relationship_tests.raw.customers",
        "model.source_target_relationship_tests.orders_model",
    ]
    assert model_test["test_metadata"]["kwargs"] == {
        "model": "{{ get_where_subquery(ref('orders_model')) }}",
        "column_name": "customer_id",
        "to": "source('raw', 'customers')",
        "field": "customer_id",
    }

    seed_test = tests["relationships_orders_seed_customer_id__customer_id__source_raw_customers_"]
    assert seed_test["attached_node"] == "seed.source_target_relationship_tests.orders_seed"
    assert seed_test["refs"] == [{"name": "orders_seed", "package": None, "version": None}]
    assert seed_test["sources"] == [["raw", "customers"]]
    assert seed_test["depends_on"]["nodes"] == [
        "source.source_target_relationship_tests.raw.customers",
        "seed.source_target_relationship_tests.orders_seed",
    ]
    assert seed_test["test_metadata"]["kwargs"]["model"] == "{{ get_where_subquery(ref('orders_seed')) }}"
    assert seed_test["test_metadata"]["kwargs"]["to"] == "source('raw', 'customers')"

    source_test = tests["source_relationships_raw_orders_customer_id__customer_id__source_raw_customers_"]
    assert source_test["attached_node"] is None
    assert source_test["refs"] == []
    assert source_test["sources"] == [["raw", "customers"], ["raw", "orders"]]
    assert source_test["depends_on"]["nodes"] == [
        "source.source_target_relationship_tests.raw.customers",
        "source.source_target_relationship_tests.raw.orders",
    ]
    assert source_test["test_metadata"]["kwargs"] == {
        "model": "{{ get_where_subquery(source('raw', 'orders')) }}",
        "column_name": "customer_id",
        "to": "source('raw', 'customers')",
        "field": "customer_id",
    }
    assert source_test["unique_id"] in manifest["child_map"]["source.source_target_relationship_tests.raw.orders"]
    assert source_test["unique_id"] in manifest["child_map"]["source.source_target_relationship_tests.raw.customers"]


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 source-target relationships build execution slice")
def test_build_executes_selected_duckdb_source_to_source_relationships_generic_test(tmp_path: Path):
    project = tmp_path / "source_to_source_relationship_tests"
    write_source_to_source_relationships_test_project(project)
    target = tmp_path / "build-target"
    target.mkdir()
    setup = subprocess.run(
        [
            DUCKDB,
            str(target / "dxt.duckdb"),
            "-batch",
            "-bail",
            "-c",
            (
                "create schema raw; "
                "create table raw.raw_customers as select 1 as customer_id union all select 2 as customer_id; "
                "create table raw.raw_orders as "
                "select 10 as order_id, 1 as customer_id union all "
                "select 11 as order_id, null as customer_id"
            ),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert setup.returncode == 0, setup.stderr

    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "source:raw.orders+"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Built 1 source test(s)" in result.stdout
    assert_manifest_schema_slice(target / "manifest.json")
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["status"] for item in run_results["results"]] == ["pass"]
    assert [item["failures"] for item in run_results["results"]] == [0]
    assert '"raw"."raw_orders"' in run_results["results"][0]["compiled_code"]
    assert '"raw"."raw_customers"' in run_results["results"][0]["compiled_code"]

    manifest = json.loads((target / "manifest.json").read_text())
    test_nodes = [node for node in manifest["nodes"].values() if node["resource_type"] == "test"]
    assert len(test_nodes) == 1
    source_test = test_nodes[0]
    assert source_test["name"] == "source_relationships_raw_orders_customer_id__customer_id__source_raw_customers_"
    assert source_test["attached_node"] is None
    assert source_test["refs"] == []
    assert source_test["sources"] == [["raw", "customers"], ["raw", "orders"]]
    assert source_test["depends_on"]["nodes"] == [
        "source.source_to_source_relationship_tests.raw.customers",
        "source.source_to_source_relationship_tests.raw.orders",
    ]
    assert source_test["test_metadata"]["kwargs"] == {
        "model": "{{ get_where_subquery(source('raw', 'orders')) }}",
        "column_name": "customer_id",
        "to": "source('raw', 'customers')",
        "field": "customer_id",
    }


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 relationships build execution slice")
def test_build_executes_selected_duckdb_relationships_generic_test(tmp_path: Path):
    project = tmp_path / "relationships_tests"
    write_relationships_model_test_project(
        project,
        "{{ config(materialized='table') }}\n"
        "select 1 as customer_id, 'Ada' as customer_name\n"
        "union all\n"
        "select 2 as customer_id, 'Bob' as customer_name\n",
        "{{ config(materialized='table') }}\n"
        "select 10 as order_id, 1 as customer_id\n"
        "union all\n"
        "select 11 as order_id, null as customer_id\n",
    )
    target = tmp_path / "build-target"
    run_result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "customers orders"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert run_result.returncode == 0, run_result.stderr

    build_result = subprocess.run(
        [
            DXT,
            "build",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "relationships_orders_customer_id__customer_id__ref_customers_",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert build_result.returncode == 0, build_result.stderr
    assert "Built 1 test(s)" in build_result.stdout
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    result = run_results["results"][0]
    assert result["unique_id"].startswith(
        "test.relationships_tests.relationships_orders_customer_id__customer_id__ref_customers_."
    )
    assert result["status"] == "pass"
    assert result["failures"] == 0
    assert result["compiled"] is True
    assert "with child as" in result["compiled_code"]
    assert "left join parent" in result["compiled_code"]
    assert "where parent.to_field is null" in result["compiled_code"]
    assert "dbt_internal_test" not in result["compiled_code"]


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 relationships build execution slice")
def test_build_reports_failing_duckdb_relationships_generic_test(tmp_path: Path):
    project = tmp_path / "relationships_tests"
    write_relationships_model_test_project(
        project,
        "{{ config(materialized='table') }}\n"
        "select 1 as customer_id, 'Ada' as customer_name\n",
        "{{ config(materialized='table') }}\n"
        "select 10 as order_id, 1 as customer_id\n"
        "union all\n"
        "select 11 as order_id, 999 as customer_id\n"
        "union all\n"
        "select 12 as order_id, null as customer_id\n",
    )
    target = tmp_path / "build-target"
    run_result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "customers orders"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert run_result.returncode == 0, run_result.stderr

    build_result = subprocess.run(
        [
            DXT,
            "build",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "relationships_orders_customer_id__customer_id__ref_customers_",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert build_result.returncode == 1
    assert "1 test(s) failed with 1 failure row(s)" in build_result.stdout
    assert "one or more tests failed" in build_result.stderr
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["status"] for item in run_results["results"]] == ["fail"]
    assert [item["failures"] for item in run_results["results"]] == [1]
    assert run_results["results"][0]["message"] == "Got 1 result, configured to fail if != 0"


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 generic test command failure coverage")
def test_test_command_reports_failing_duckdb_generic_test(tmp_path: Path):
    project = tmp_path / "test_command_relationships"
    write_relationships_model_test_project(
        project,
        "{{ config(materialized='table') }}\n"
        "select 1 as customer_id, 'Ada' as customer_name\n",
        "{{ config(materialized='table') }}\n"
        "select 10 as order_id, 1 as customer_id\n"
        "union all\n"
        "select 11 as order_id, 999 as customer_id\n",
    )
    target = tmp_path / "test-target"
    run_result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "customers orders"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert run_result.returncode == 0, run_result.stderr

    result = subprocess.run(
        [
            DXT,
            "test",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "relationships_orders_customer_id__customer_id__ref_customers_",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 1
    assert "1 test(s) failed with 1 failure row(s)" in result.stdout
    assert "one or more tests failed" in result.stderr
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["status"] for item in run_results["results"]] == ["fail"]
    assert [item["failures"] for item in run_results["results"]] == [1]
    assert run_results["results"][0]["message"] == "Got 1 result, configured to fail if != 0"


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 relationships model+test build execution slice")
def test_build_executes_selected_duckdb_models_and_relationships_generic_test(tmp_path: Path):
    project = tmp_path / "relationships_tests"
    write_relationships_model_test_project(
        project,
        "{{ config(materialized='table') }}\nselect 1 as customer_id, 'Ada' as customer_name\n",
        "{{ config(materialized='table') }}\nselect 10 as order_id, 1 as customer_id\n",
    )
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "customers orders"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Built 2 model(s) and 1 test(s)" in result.stdout
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"][:2]] == [
        "model.relationships_tests.customers",
        "model.relationships_tests.orders",
    ]
    assert run_results["results"][2]["unique_id"].startswith(
        "test.relationships_tests.relationships_orders_customer_id__customer_id__ref_customers_."
    )
    assert [item["status"] for item in run_results["results"]] == ["success", "success", "pass"]


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 seed+model+test build execution slice")
def test_build_executes_selected_duckdb_seed_model_and_supported_generic_tests(tmp_path: Path):
    project = tmp_path / "build_seed_model_tests"
    write_seed_model_test_project(
        project,
        "customer_id,customer_name\n1,Ada\n2,Bob\n",
    )
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "+customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Built 1 seed(s), 1 model(s), and 2 test(s)" in result.stdout
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == [
        "seed.build_seed_model_tests.raw_customers",
        "model.build_seed_model_tests.customers",
        "test.build_seed_model_tests.not_null_customers_customer_id.5c9bf9911d",
        "test.build_seed_model_tests.unique_customers_customer_id.c5af1ff4b1",
    ]
    assert [item["status"] for item in run_results["results"]] == ["success", "success", "pass", "pass"]
    assert [item["failures"] for item in run_results["results"]] == [None, None, 0, 0]

    query = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-csv", "-noheader", "-c", 'select customer_id, customer_name from "main"."customers" order by customer_id'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert query.returncode == 0, query.stderr
    assert query.stdout.strip() == "1,Ada\n2,Bob"


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 seed execution-failure slice")
def test_build_seed_execution_failure_skips_selected_model_and_generic_tests(tmp_path: Path):
    project = tmp_path / "build_seed_model_tests"
    write_seed_model_test_project(
        project,
        "customer_id,customer_name\nnot_an_int,Ada\n2,Bob\n",
    )
    (project / "seeds" / "schema.yml").write_text(
        """version: 2
seeds:
  - name: raw_customers
    config:
      column_types:
        customer_id: integer
"""
    )
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "+customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )

    assert result.returncode == 1
    assert "Build failed after 4 result(s)" in result.stdout
    assert "one or more selected resources failed" in result.stderr
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == [
        "seed.build_seed_model_tests.raw_customers",
        "model.build_seed_model_tests.customers",
        "test.build_seed_model_tests.not_null_customers_customer_id.5c9bf9911d",
        "test.build_seed_model_tests.unique_customers_customer_id.c5af1ff4b1",
    ]
    assert [item["status"] for item in run_results["results"]] == ["error", "skipped", "skipped", "skipped"]
    assert run_results["results"][0]["message"] == "DuckDB execution failed"
    assert [item["message"] for item in run_results["results"][1:]] == [None, None, None]
    assert run_results["results"][1]["compiled"] is True
    assert run_results["results"][1]["compiled_code"].strip().startswith("select")


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 table-level generic-test build slice")
def test_build_executes_table_level_model_and_seed_generic_tests(tmp_path: Path):
    project = tmp_path / "table_level_generic_tests"
    write_table_level_generic_test_project(project)
    target = tmp_path / "build-target"
    result = subprocess.run(
        [
            DXT,
            "build",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "raw_customers+ +customers+",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Built 1 seed(s), 1 model(s), and 2 test(s)" in result.stdout
    assert_manifest_schema_slice(target / "manifest.json")
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == [
        "seed.table_level_generic_tests.raw_customers",
        "model.table_level_generic_tests.customers",
        "test.table_level_generic_tests.not_null_customers_customer_id.5c9bf9911d",
        "test.table_level_generic_tests.unique_raw_customers_customer_id.4be8a71a17",
    ]
    assert [item["status"] for item in run_results["results"]] == ["success", "success", "pass", "pass"]
    manifest = json.loads((target / "manifest.json").read_text())
    model_test = manifest["nodes"]["test.table_level_generic_tests.not_null_customers_customer_id.5c9bf9911d"]
    seed_test = manifest["nodes"]["test.table_level_generic_tests.unique_raw_customers_customer_id.4be8a71a17"]
    assert model_test["column_name"] is None
    assert model_test["test_metadata"]["kwargs"]["column_name"] == "customer_id"
    assert seed_test["column_name"] is None
    assert seed_test["test_metadata"]["kwargs"]["column_name"] == "customer_id"


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 source table-level generic-test build slice")
def test_build_executes_table_level_source_generic_test(tmp_path: Path):
    project = tmp_path / "table_level_generic_tests"
    write_table_level_generic_test_project(project)
    target = tmp_path / "build-target"
    target.mkdir()
    setup = subprocess.run(
        [
            DUCKDB,
            str(target / "dxt.duckdb"),
            "-batch",
            "-bail",
            "-c",
            (
                'create schema raw; '
                'create table raw.raw_orders as '
                "select 1 as customer_id union all select 2 as customer_id"
            ),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert setup.returncode == 0, setup.stderr

    result = subprocess.run(
        [
            DXT,
            "build",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "source:raw.orders+",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Built 1 source test(s)" in result.stdout
    assert_manifest_schema_slice(target / "manifest.json")
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["status"] for item in run_results["results"]] == ["pass"]
    assert "value_field not in (1, 2)" in run_results["results"][0]["compiled_code"]
    manifest = json.loads((target / "manifest.json").read_text())
    test_nodes = [
        node
        for node in manifest["nodes"].values()
        if node["resource_type"] == "test" and node["sources"] == [["raw", "orders"]]
    ]
    assert len(test_nodes) == 1
    source_test = test_nodes[0]
    assert source_test["unique_id"] == (
        "test.table_level_generic_tests."
        "source_accepted_values_raw_orders_customer_id__False__1__2.8cc42f6023"
    )
    assert source_test["attached_node"] is None
    assert source_test["column_name"] is None
    assert source_test["sources"] == [["raw", "orders"]]
    assert source_test["test_metadata"]["kwargs"] == {
        "model": "{{ get_where_subquery(source('raw', 'orders')) }}",
        "column_name": "customer_id",
        "values": ["1", "2"],
        "quote": False,
    }


def test_parse_ignores_unsupported_source_table_generic_test_without_column_name(tmp_path: Path):
    project = tmp_path / "source_table_without_column"
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: source_table_without_column
version: "1.0"
model-paths: ["models"]
target-path: target
"""
    )
    (project / "models" / "schema.yml").write_text(
        """version: 2
sources:
  - name: raw
    tables:
      - name: orders
        data_tests:
          - not_null
"""
    )
    target = tmp_path / "parse-target"
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert_manifest_schema_slice(target / "manifest.json")
    manifest = json.loads((target / "manifest.json").read_text())
    assert [node for node in manifest["nodes"].values() if node["resource_type"] == "test"] == []
    assert manifest["child_map"]["source.source_table_without_column.raw.orders"] == []


def test_parse_seed_column_properties_and_tests(tmp_path: Path):
    project = tmp_path / "seed_column_tests"
    write_seed_column_test_project(project, "customer_id,customer_name\n1,Ada\n2,Bob\n")
    target = tmp_path / "parse-target"
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert_manifest_schema_slice(target / "manifest.json")
    manifest = json.loads((target / "manifest.json").read_text())

    seed = manifest["nodes"]["seed.seed_column_tests.raw_customers"]
    assert seed["patch_path"] == "seed_column_tests://seeds/schema.yml"
    assert sorted(seed["columns"]) == ["customer_id"]
    assert seed["columns"]["customer_id"]["name"] == "customer_id"

    test_nodes = [node for node in manifest["nodes"].values() if node["resource_type"] == "test"]
    assert [node["name"] for node in test_nodes] == [
        "accepted_values_raw_customers_customer_id__False__1__2",
        "not_null_raw_customers_customer_id",
        "unique_raw_customers_customer_id",
    ]
    accepted = test_nodes[0]
    assert accepted["attached_node"] == "seed.seed_column_tests.raw_customers"
    assert accepted["original_file_path"] == "seeds/schema.yml"
    assert accepted["refs"] == [{"name": "raw_customers", "package": None, "version": None}]
    assert accepted["test_metadata"]["kwargs"] == {
        "model": "{{ get_where_subquery(ref('raw_customers')) }}",
        "column_name": "customer_id",
        "values": ["1", "2"],
        "quote": False,
    }
    assert accepted["depends_on"]["nodes"] == ["seed.seed_column_tests.raw_customers"]
    assert manifest["child_map"]["seed.seed_column_tests.raw_customers"] == [node["unique_id"] for node in test_nodes]


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 seed column generic-test build slice")
def test_build_executes_selected_duckdb_seed_column_generic_tests(tmp_path: Path):
    project = tmp_path / "seed_column_tests"
    write_seed_column_test_project(project, "customer_id,customer_name\n1,Ada\n2,Bob\n")
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "raw_customers+"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Built 1 seed(s) and 3 test(s)" in result.stdout
    assert_manifest_schema_slice(target / "manifest.json")
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert run_results["results"][0]["unique_id"] == "seed.seed_column_tests.raw_customers"
    assert all(item["unique_id"].startswith("test.seed_column_tests.") for item in run_results["results"][1:])
    assert [item["status"] for item in run_results["results"]] == ["success", "pass", "pass", "pass"]
    assert [item["failures"] for item in run_results["results"]] == [None, 0, 0, 0]
    assert "value_field not in (1, 2)" in run_results["results"][1]["compiled_code"]


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 seed column accepted_values build slice")
def test_build_executes_selected_duckdb_seed_column_default_quoted_accepted_values(tmp_path: Path):
    project = tmp_path / "seed_column_tests"
    write_seed_column_test_project(
        project,
        "customer_id,customer_name\nA,Ada\nB,Bob\n",
        """          - accepted_values:
              arguments:
                values: [A, B]
""",
    )
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "raw_customers+"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Built 1 seed(s) and 1 test(s)" in result.stdout
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["status"] for item in run_results["results"]] == ["success", "pass"]
    assert "value_field not in ('A', 'B')" in run_results["results"][1]["compiled_code"]


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 seed column relationships generic-test build slice")
def test_build_executes_selected_duckdb_seed_relationships_generic_test(tmp_path: Path):
    project = tmp_path / "seed_relationship_tests"
    (project / "seeds").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: seed_relationship_tests
version: "1.0"
seed-paths: ["seeds"]
target-path: target
"""
    )
    (project / "seeds" / "raw_customers.csv").write_text("customer_id,customer_name\n1,Ada\n")
    (project / "seeds" / "raw_orders.csv").write_text("order_id,customer_id\n10,1\n")
    (project / "seeds" / "schema.yml").write_text(
        """version: 2
seeds:
  - name: raw_orders
    columns:
      - name: customer_id
        tests:
          - relationships:
              arguments:
                to: ref('raw_customers')
                field: customer_id
"""
    )
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "raw_customers raw_orders+"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Built 2 seed(s) and 1 test(s)" in result.stdout
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"][:2]] == [
        "seed.seed_relationship_tests.raw_customers",
        "seed.seed_relationship_tests.raw_orders",
    ]
    assert run_results["results"][2]["unique_id"].startswith(
        "test.seed_relationship_tests.relationships_raw_orders_customer_id__customer_id__ref_raw_customers_."
    )
    assert [item["status"] for item in run_results["results"]] == ["success", "success", "pass"]


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 seed column generic-test build slice")
def test_build_reports_failing_seed_column_generic_tests(tmp_path: Path):
    project = tmp_path / "seed_column_tests"
    write_seed_column_test_project(project, "customer_id,customer_name\n,Ada\n1,Bob\n1,Bea\n")
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "raw_customers+"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 1
    assert "Built 1 seed(s) and 3 test(s)" in result.stdout
    assert "2 test(s) failed with 2 failure row(s)" in result.stdout
    assert "one or more tests failed" in result.stderr
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["status"] for item in run_results["results"]] == ["success", "pass", "fail", "fail"]
    assert [item["failures"] for item in run_results["results"]] == [None, 0, 1, 1]


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 accepted_values seed+model+test build execution slice")
def test_build_executes_selected_duckdb_seed_model_and_accepted_values_generic_test(tmp_path: Path):
    project = tmp_path / "build_seed_model_tests"
    write_seed_model_test_project(
        project,
        "customer_id,customer_name\n1,Ada\n2,Bob\n",
        """          - accepted_values:
              arguments:
                values: ['1', '2']
""",
    )
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "+customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Built 1 seed(s), 1 model(s), and 1 test(s)" in result.stdout
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["status"] for item in run_results["results"]] == ["success", "success", "pass"]
    assert [item["unique_id"] for item in run_results["results"][:2]] == [
        "seed.build_seed_model_tests.raw_customers",
        "model.build_seed_model_tests.customers",
    ]
    assert run_results["results"][2]["unique_id"].startswith(
        "test.build_seed_model_tests.accepted_values_customers_customer_id__1__2."
    )


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 relationships seed+model+test build execution slice")
def test_build_executes_selected_duckdb_seed_model_and_relationships_generic_test(tmp_path: Path):
    project = tmp_path / "build_seed_model_relationships_tests"
    (project / "models").mkdir(parents=True)
    (project / "seeds").mkdir()
    (project / "dbt_project.yml").write_text(
        """name: build_seed_model_relationships_tests
version: "1.0"
model-paths: ["models"]
seed-paths: ["seeds"]
target-path: target
"""
    )
    (project / "seeds" / "raw_customers.csv").write_text("customer_id,customer_name\n1,Ada\n")
    (project / "seeds" / "raw_orders.csv").write_text("order_id,customer_id\n10,1\n")
    (project / "models" / "customers.sql").write_text(
        """{{ config(materialized='table') }}
select try_cast(customer_id as integer) as customer_id, customer_name
from {{ ref("raw_customers") }}
"""
    )
    (project / "models" / "orders.sql").write_text(
        """{{ config(materialized='table') }}
select try_cast(o.order_id as integer) as order_id, try_cast(o.customer_id as integer) as customer_id
from {{ ref("raw_orders") }} as o
left join {{ ref("customers") }} as c on try_cast(o.customer_id as integer) = c.customer_id
"""
    )
    (project / "models" / "schema.yml").write_text(
        """version: 2
models:
  - name: orders
    columns:
      - name: customer_id
        tests:
          - relationships:
              arguments:
                to: ref('customers')
                field: customer_id
"""
    )
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "+orders"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Built 2 seed(s), 2 model(s), and 1 test(s)" in result.stdout
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"][:4]] == [
        "seed.build_seed_model_relationships_tests.raw_customers",
        "seed.build_seed_model_relationships_tests.raw_orders",
        "model.build_seed_model_relationships_tests.customers",
        "model.build_seed_model_relationships_tests.orders",
    ]
    assert run_results["results"][4]["unique_id"].startswith(
        "test.build_seed_model_relationships_tests.relationships_orders_customer_id__customer_id__ref_customers_."
    )
    assert [item["status"] for item in run_results["results"]] == ["success", "success", "success", "success", "pass"]


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 seed+model+test build execution slice")
def test_build_reports_failing_seed_model_attached_generic_tests_in_run_results(tmp_path: Path):
    project = tmp_path / "build_seed_model_tests"
    write_seed_model_test_project(
        project,
        "customer_id,customer_name\n,Ada\n1,Bob\n1,Bea\n",
    )
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "+customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 1
    assert "Built 1 seed(s), 1 model(s), and 2 test(s)" in result.stdout
    assert "2 test(s) failed with 2 failure row(s)" in result.stdout
    assert "one or more tests failed" in result.stderr
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["status"] for item in run_results["results"]] == ["success", "success", "fail", "fail"]
    assert [item["failures"] for item in run_results["results"]] == [None, None, 1, 1]


def test_build_rejects_seed_model_with_unsupported_generic_test_before_duckdb(tmp_path: Path):
    project = tmp_path / "build_seed_model_tests"
    write_seed_model_test_project(
        project,
        "customer_id,customer_name\n1,Ada\n",
    )
    (project / "models" / "schema.yml").write_text(
        """version: 2
models:
  - name: customers
    tests:
      - unique
"""
    )
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "+customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "test/build currently executes only selected DuckDB singular SQL tests and model/seed/source not_null/unique/accepted_values/relationships column tests" in result.stderr
    assert not (target / "run_results.json").exists()
    assert not (target / "dxt.duckdb").exists()
    assert (target / "manifest.json").exists()


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 model+test build execution slice")
def test_build_reports_failing_model_attached_generic_tests_in_run_results(tmp_path: Path):
    project = tmp_path / "build_model_tests"
    write_supported_model_test_project(
        project,
        "select null as customer_id, 'Ada' as customer_name\n"
        "union all\n"
        "select 1 as customer_id, 'Bob' as customer_name\n"
        "union all\n"
        "select 1 as customer_id, 'Bea' as customer_name\n",
    )
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 1
    assert "Built 1 model(s) and 2 test(s)" in result.stdout
    assert "2 test(s) failed with 2 failure row(s)" in result.stdout
    assert "one or more tests failed" in result.stderr
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["status"] for item in run_results["results"]] == ["success", "fail", "fail"]
    assert [item["failures"] for item in run_results["results"]] == [None, 1, 1]
    assert all(item["message"] == "Got 1 result, configured to fail if != 0" for item in run_results["results"][1:])


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for build data-test failure skip coverage")
def test_build_data_test_failure_skips_selected_downstream_model(tmp_path: Path):
    project = tmp_path / "build_test_failure_skip"
    write_build_test_failure_downstream_project(project)
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "customers+"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 1
    assert "Built 2 model(s) and 1 test(s)" in result.stdout
    assert "1 test(s) failed with 1 failure row(s)" in result.stdout
    assert "one or more tests failed" in result.stderr
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == [
        "model.build_test_failure_skip.customers",
        "test.build_test_failure_skip.not_null_customers_customer_id.5c9bf9911d",
        "model.build_test_failure_skip.orders",
    ]
    assert [item["status"] for item in run_results["results"]] == ["success", "fail", "skipped"]
    assert [item["failures"] for item in run_results["results"]] == [None, 1, None]

    missing_orders = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-batch", "-bail", "-c", 'select count(*) from "main"."orders"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert missing_orders.returncode != 0


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for seed/model build data-test failure skip coverage")
def test_build_seed_model_data_test_failure_skips_selected_downstream_model(tmp_path: Path):
    project = tmp_path / "build_seed_test_failure_skip"
    write_seed_build_test_failure_downstream_project(project)
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "raw_customers+"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 1
    assert "Built 1 seed(s), 1 model(s), and 1 test(s)" in result.stdout
    assert "1 test(s) failed with 1 failure row(s)" in result.stdout
    assert "one or more tests failed" in result.stderr
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == [
        "seed.build_seed_test_failure_skip.raw_customers",
        "model.build_seed_test_failure_skip.customers",
        "test.build_seed_test_failure_skip.not_null_customers_customer_id.5c9bf9911d",
        "model.build_seed_test_failure_skip.orders",
    ]
    assert [item["status"] for item in run_results["results"]] == ["success", "success", "fail", "skipped"]
    assert [item["failures"] for item in run_results["results"]] == [None, None, 1, None]

    missing_orders = subprocess.run(
        [DUCKDB, str(target / "dxt.duckdb"), "-batch", "-bail", "-c", 'select count(*) from "main"."orders"'],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert missing_orders.returncode != 0


def test_build_rejects_model_selection_with_unsupported_generic_test_before_duckdb(tmp_path: Path):
    project = copy_fixture(tmp_path, "model_properties")
    target = tmp_path / "build-target"
    result = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert result.stdout == ""
    assert "test/build currently executes only selected DuckDB singular SQL tests and model/seed/source not_null/unique/accepted_values/relationships column tests" in result.stderr
    assert not (target / "run_results.json").exists()
    assert not (target / "dxt.duckdb").exists()
    assert (target / "manifest.json").exists()


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 generic test build execution slice")
def test_build_executes_selected_duckdb_generic_tests_and_writes_run_results(tmp_path: Path):
    project = copy_fixture(tmp_path, "model_properties")
    target = tmp_path / "build-target"
    run_result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert run_result.returncode == 0, run_result.stderr

    build_result = subprocess.run(
        [
            DXT,
            "build",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "not_null_customers_customer_id unique_customers_customer_id",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert build_result.returncode == 0, build_result.stderr
    assert "Built 2 test(s)" in build_result.stdout
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["unique_id"] for item in run_results["results"]] == [
        "test.model_properties.not_null_customers_customer_id.5c9bf9911d",
        "test.model_properties.unique_customers_customer_id.c5af1ff4b1",
    ]
    assert [item["status"] for item in run_results["results"]] == ["pass", "pass"]
    assert [item["failures"] for item in run_results["results"]] == [0, 0]
    assert all(item["compiled"] is True for item in run_results["results"])
    assert "is null" in run_results["results"][0]["compiled_code"]
    assert "having count(*) > 1" in run_results["results"][1]["compiled_code"]
    assert all("dbt_internal_test" not in item["compiled_code"] for item in run_results["results"])
    assert all(item["relation_name"] is None for item in run_results["results"])


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 generic test build execution slice")
def test_build_reports_failing_duckdb_generic_tests_in_run_results(tmp_path: Path):
    project = copy_fixture(tmp_path, "model_properties")
    (project / "models" / "customers.sql").write_text(
        "select null as customer_id, 'Ada' as customer_name\n"
        "union all\n"
        "select 1 as customer_id, 'Bob' as customer_name\n"
        "union all\n"
        "select 1 as customer_id, 'Bea' as customer_name\n"
    )
    target = tmp_path / "build-target"
    run_result = subprocess.run(
        [DXT, "run", "--project-dir", str(project), "--target-path", str(target), "--select", "customers"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert run_result.returncode == 0, run_result.stderr

    build_result = subprocess.run(
        [
            DXT,
            "build",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "not_null_customers_customer_id unique_customers_customer_id",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert build_result.returncode == 1
    assert "2 test(s) failed with 2 failure row(s)" in build_result.stdout
    assert "one or more tests failed" in build_result.stderr
    assert_run_results_schema_slice(target / "run_results.json")
    run_results = json.loads((target / "run_results.json").read_text())
    assert [item["status"] for item in run_results["results"]] == ["fail", "fail"]
    assert [item["failures"] for item in run_results["results"]] == [1, 1]
    assert all(item["message"] == "Got 1 result, configured to fail if != 0" for item in run_results["results"])


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


def test_parse_and_ls_include_read_only_unit_tests(tmp_path: Path):
    project = tmp_path / "unit_test_project"
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text(
        """name: unit_test_project
version: '1.0'
profile: unit_test_project
model-paths: ['models']
"""
    )
    (project / "models" / "orders.sql").write_text("select 1 as order_id, true as has_food\n")
    (project / "models" / "schema.yml").write_text(
        """version: 2
unit_tests:
  - name: assert_order_flags
    description: Orders preserve food flags.
    model: orders
    given:
      - input: ref('orders')
        rows:
          - {order_id: 1, has_food: true}
          - {
              order_id: 2,
              has_food: false,
            }
    expect:
      rows:
        - {order_id: 1, has_food: true}
"""
    )

    target = tmp_path / "unit-test-target"
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""

    manifest_path = target / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    assert_partial_manifest_schema(manifest)
    assert_manifest_schema_slice(manifest_path)
    assert not (target / "run_results.json").exists()

    unit_id = "unit_test.unit_test_project.orders.assert_order_flags"
    unit_test = manifest["unit_tests"][unit_id]
    assert unit_test["resource_type"] == "unit_test"
    assert unit_test["model"] == "orders"
    assert unit_test["path"] == "schema.yml"
    assert unit_test["original_file_path"] == "models/schema.yml"
    assert unit_test["description"] == "Orders preserve food flags."
    assert unit_test["given"][0]["input"] == "ref('orders')"
    assert unit_test["given"][0]["rows"][0] == {"order_id": 1, "has_food": True}
    assert unit_test["given"][0]["rows"][1] == {"order_id": 2, "has_food": False}
    assert unit_test["expect"]["rows"][0] == {"order_id": 1, "has_food": True}
    assert manifest["parent_map"][unit_id] == ["model.unit_test_project.orders"]
    assert unit_id in manifest["child_map"]["model.unit_test_project.orders"]

    list_json = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--resource-type", "unit_test", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert list_json.returncode == 0, list_json.stderr
    listed = json.loads(list_json.stdout)
    assert listed == [{"unique_id": unit_id, "resource_type": "unit_test", "name": "assert_order_flags"}]

    list_selector = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "resource_type:unit_test", "--output", "selector"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert list_selector.returncode == 0, list_selector.stderr
    assert list_selector.stdout.strip() == "unit_test:unit_test_project.assert_order_flags"

    build_target = tmp_path / "unit-test-build-target"
    build = subprocess.run(
        [DXT, "build", "--project-dir", str(project), "--target-path", str(build_target), "--select", "resource_type:unit_test"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert build.returncode != 0
    assert "unit test execution is not supported yet" in build.stderr
    assert (build_target / "manifest.json").exists()
    assert not (build_target / "run_results.json").exists()

    test_target = tmp_path / "unit-test-command-target"
    test = subprocess.run(
        [DXT, "test", "--project-dir", str(project), "--target-path", str(test_target), "--select", "resource_type:unit_test"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert test.returncode != 0
    assert "unit test execution is not supported yet" in test.stderr
    assert not (test_target / "run_results.json").exists()


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
    assert manifest["metadata"].get("dbt_schema_version") == "https://schemas.getdbt.com/dbt/manifest/v12.json"
    assert manifest["metadata"].get("dbt_version") == "0.0.0"
    assert isinstance(manifest["metadata"].get("generated_at"), str)
    assert manifest["metadata"].get("invocation_id") is None
    assert manifest["metadata"].get("invocation_started_at") is None
    assert manifest["metadata"].get("env") == {}
    assert isinstance(manifest["metadata"].get("project_name"), str)
    assert isinstance(manifest["metadata"].get("adapter_type"), str)
    assert "generated_by" not in manifest["metadata"]
    assert manifest["group_map"] == {}
    assert manifest["saved_queries"] == {}
    assert manifest["semantic_models"] == {}
    assert isinstance(manifest["unit_tests"], dict)
    for unique_id, unit_test in manifest["unit_tests"].items():
        assert unique_id == unit_test["unique_id"]
        assert unit_test["resource_type"] == "unit_test"
        assert unit_test["package_name"]
        assert unit_test["model"]
        assert isinstance(unit_test["given"], list)
        assert isinstance(unit_test["expect"], dict)
        assert isinstance(unit_test["depends_on"]["nodes"], list)
    for unique_id, node in manifest["nodes"].items():
        assert unique_id == node["unique_id"]
        assert node["resource_type"] in {"model", "analysis", "seed", "test"}
        common_keys = {
            "unique_id",
            "resource_type",
            "package_name",
            "name",
            "database",
            "schema",
            "alias",
            "fqn",
            "checksum",
            "path",
            "original_file_path",
            "config",
            "depends_on",
        }
        assert set(node) >= common_keys
        assert node["database"] in {"memory", None} or isinstance(node["database"], str)
        assert isinstance(node["schema"], str)
        assert isinstance(node["alias"], str)
        assert isinstance(node["fqn"], list)
        assert set(node["checksum"]) == {"name", "checksum"}
        assert isinstance(node["checksum"]["name"], str)
        assert isinstance(node["checksum"]["checksum"], str)
        if node["resource_type"] in {"model", "analysis"}:
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


def assert_run_results_schema_slice(run_results_path: Path) -> None:
    run_results = json.loads(run_results_path.read_text())
    schema = schema_validator.load_json(RUN_RESULTS_SCHEMA)
    errors = schema_validator.validate_manifest(run_results, schema)
    assert errors == []


def assert_sources_schema_slice(sources_path: Path) -> None:
    sources = json.loads(sources_path.read_text())
    schema = schema_validator.load_json(SOURCES_SCHEMA)
    errors = schema_validator.validate_manifest(sources, schema)
    assert errors == []


def write_sources_state(state_dir: Path, rows: dict[str, str]) -> Path:
    state_dir.mkdir(parents=True, exist_ok=True)
    artifact = {
        "metadata": {
            "dbt_schema_version": "https://schemas.getdbt.com/dbt/sources/v3.json",
            "dbt_version": "0.0.0",
            "generated_at": "1970-01-01T00:00:00Z",
            "invocation_id": None,
            "invocation_started_at": None,
            "env": {},
        },
        "results": [
            {
                "unique_id": unique_id,
                "max_loaded_at": "2026-06-17T12:00:00Z",
                "snapshotted_at": "2026-06-17T14:00:00Z",
                "max_loaded_at_time_ago_in_s": 7200.0,
                "status": status,
                "criteria": {
                    "warn_after": {"count": 1, "period": "hour"},
                    "error_after": {"count": 1, "period": "day"},
                    "filter": None,
                },
                "adapter_response": {},
                "timing": [{"name": "execute", "started_at": None, "completed_at": None}],
                "thread_id": "Thread-1",
                "execution_time": 0.0,
            }
            for unique_id, status in rows.items()
        ],
        "elapsed_time": 0.0,
    }
    path = state_dir / "sources.json"
    path.write_text(json.dumps(artifact), encoding="utf-8")
    assert_sources_schema_slice(path)
    return path


def write_run_results_state(state_dir: Path, rows: dict[str, str]) -> Path:
    state_dir.mkdir(parents=True, exist_ok=True)
    artifact = {
        "metadata": {
            "dbt_schema_version": "https://schemas.getdbt.com/dbt/run-results/v6.json",
            "dbt_version": "0.0.0",
            "generated_at": "1970-01-01T00:00:00Z",
            "invocation_id": None,
            "invocation_started_at": None,
            "env": {},
        },
        "results": [
            {
                "status": status,
                "timing": [
                    {"name": "compile", "started_at": None, "completed_at": None},
                    {"name": "execute", "started_at": None, "completed_at": None},
                ],
                "thread_id": "Thread-1",
                "execution_time": 0.0,
                "adapter_response": {},
                "message": None,
                "failures": 1 if status == "fail" else None,
                "unique_id": unique_id,
                "compiled": None,
                "compiled_code": None,
                "relation_name": None,
            }
            for unique_id, status in rows.items()
        ],
        "elapsed_time": 0.0,
    }
    path = state_dir / "run_results.json"
    path.write_text(json.dumps(artifact), encoding="utf-8")
    assert_run_results_schema_slice(path)
    return path


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
    ls_test_name = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "resource_type:test", "--output", "name"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_test_name.returncode == 0, ls_test_name.stderr
    assert ls_test_name.stdout.splitlines() == [
        "not_null_customers_customer_id",
        "unique_customers_",
        "unique_customers_customer_id",
    ]
    ls_test_path = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "resource_type:test", "--output", "path"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_test_path.returncode == 0, ls_test_path.stderr
    assert ls_test_path.stdout.splitlines() == [
        "models/schema.yml",
        "models/schema.yml",
        "models/schema.yml",
    ]
    ls_test_selector = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "resource_type:test", "--output", "selector"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_test_selector.returncode == 0, ls_test_selector.stderr
    assert ls_test_selector.stdout.splitlines() == [
        "model_properties.not_null_customers_customer_id",
        "model_properties.unique_customers_",
        "model_properties.unique_customers_customer_id",
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

    ls_tests_by_file = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "file:schema.yml", "--resource-type", "test", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_tests_by_file.returncode == 0, ls_tests_by_file.stderr
    assert json.loads(ls_tests_by_file.stdout) == json.loads(ls_tests.stdout)

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


def test_parse_macro_namespace_search_order(tmp_path: Path):
    project = copy_fixture(tmp_path, "macro_namespace_search_order")
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

    root_same = "macro.macro_namespace_search_order.same_name"
    root_only = "macro.macro_namespace_search_order.root_only"
    other_shared = "macro.other_pkg.shared"
    package_same = "macro.util_pkg.same_name"
    package_wrap = "macro.util_pkg.pkg_wrap"
    assert sorted(manifest["macros"]) == [
        root_only,
        root_same,
        other_shared,
        package_wrap,
        package_same,
    ]
    assert manifest["nodes"]["model.macro_namespace_search_order.root_local"]["depends_on"]["macros"] == [
        root_same
    ]
    assert manifest["nodes"]["model.macro_namespace_search_order.root_qualified_pkg"]["depends_on"]["macros"] == [
        package_same
    ]
    assert manifest["nodes"]["model.util_pkg.pkg_local"]["depends_on"]["macros"] == [package_same]
    assert manifest["nodes"]["model.util_pkg.pkg_root_fallback"]["depends_on"]["macros"] == [root_only]
    assert manifest["macros"][package_wrap]["depends_on"]["macros"] == [
        root_only,
        other_shared,
        package_same,
    ]
    assert str(project) not in manifest_path.read_text()


def test_parse_static_adapter_dispatch_dependencies(tmp_path: Path):
    project = copy_fixture(tmp_path, "adapter_dispatch_static")
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

    root_render = "macro.adapter_dispatch_static.default__render_value"
    root_package_value = "macro.adapter_dispatch_static.default__package_value"
    package_render = "macro.util_pkg.duckdb__render_value"
    package_value = "macro.util_pkg.duckdb__package_value"
    package_wrap = "macro.util_pkg.wrap_dispatch"

    assert sorted(manifest["macros"]) == [
        root_package_value,
        root_render,
        package_value,
        package_render,
        package_wrap,
    ]
    assert manifest["nodes"]["model.adapter_dispatch_static.root_dispatch"]["depends_on"]["macros"] == [
        root_render
    ]
    assert manifest["nodes"]["model.adapter_dispatch_static.root_dispatch_package"]["depends_on"]["macros"] == [
        root_package_value
    ]
    assert manifest["nodes"]["model.util_pkg.package_dispatch"]["depends_on"]["macros"] == [
        package_render
    ]
    assert manifest["macros"][package_wrap]["depends_on"]["macros"] == [
        root_package_value,
        package_render,
    ]
    assert str(project) not in manifest_path.read_text()


def test_parse_static_adapter_dispatch_uses_project_dispatch_config(tmp_path: Path):
    project = copy_fixture(tmp_path, "adapter_dispatch_project_config")
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

    assert sorted(manifest["macros"]) == [
        "macro.adapter_dispatch_project_config.default__render_value",
        "macro.override_pkg.duckdb__render_value",
        "macro.util_pkg.duckdb__render_value",
    ]
    assert manifest["nodes"]["model.adapter_dispatch_project_config.root_dispatch_config"]["depends_on"]["macros"] == [
        "macro.override_pkg.duckdb__render_value"
    ]
    assert str(project) not in manifest_path.read_text()


def test_parse_static_adapter_dispatch_uses_profile_adapter_type(tmp_path: Path):
    project = copy_fixture(tmp_path, "profile_adapter_dispatch")

    result = subprocess.run(
        [
            DXT,
            "parse",
            "--project-dir",
            str(project),
            "--profiles-dir",
            str(project),
            "--target-path",
            "target-dxt",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    manifest_path = project / "target-dxt" / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    assert_manifest_schema_slice(manifest_path)
    assert manifest["metadata"]["adapter_type"] == "postgres"
    assert manifest["nodes"]["model.profile_adapter_dispatch.profile_dispatch"]["depends_on"]["macros"] == [
        "macro.profile_adapter_dispatch.postgres__render_value"
    ]

    duck_result = subprocess.run(
        [
            DXT,
            "parse",
            "--project-dir",
            str(project),
            "--profiles-dir",
            str(project),
            "--target",
            "duck",
            "--target-path",
            "target-duck",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert duck_result.returncode == 0, duck_result.stderr
    duck_manifest = json.loads((project / "target-duck" / "manifest.json").read_text())
    assert duck_manifest["metadata"]["adapter_type"] == "duckdb"
    assert duck_manifest["nodes"]["model.profile_adapter_dispatch.profile_dispatch"]["depends_on"]["macros"] == [
        "macro.profile_adapter_dispatch.duckdb__render_value"
    ]

    redshift_result = subprocess.run(
        [
            DXT,
            "parse",
            "--project-dir",
            str(project),
            "--profiles-dir",
            str(project),
            "--target",
            "rs",
            "--target-path",
            "target-rs",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert redshift_result.returncode == 0, redshift_result.stderr
    redshift_manifest = json.loads((project / "target-rs" / "manifest.json").read_text())
    assert redshift_manifest["metadata"]["adapter_type"] == "redshift"
    assert redshift_manifest["nodes"]["model.profile_adapter_dispatch.profile_dispatch"]["depends_on"]["macros"] == [
        "macro.profile_adapter_dispatch.postgres__render_value"
    ]
    assert str(project) not in manifest_path.read_text()


def test_parse_missing_adapter_dispatch_fails(tmp_path: Path):
    project = copy_fixture(tmp_path, "adapter_dispatch_missing")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", "target-dxt"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode != 0
    assert "unresolved macro reference" in result.stderr


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
    assert_manifest_schema_slice(project / "target-dxt" / "manifest.json")
    macro = manifest["macros"]["macro.macro_properties.format_id"]
    assert macro["description"] == "Format an identifier expression."
    assert macro["docs"] == {"show": False, "node_color": "#336699"}
    assert macro["meta"] == {
        "audited": True,
        "owner": "analytics",
        "priority": 2,
    }
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


def test_parse_macro_validate_args_flag_emits_signature_args_and_warnings(tmp_path: Path):
    project = copy_fixture(tmp_path, "macro_validate_args")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", "target-dxt"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Argument wrong_name in yaml for macro bad_macro does not match the jinja definition." in result.stderr
    assert "The number of arguments in the yaml for macro bad_macro does not match the jinja definition." in result.stderr
    assert "Argument wrong_name in the yaml for macro bad_macro has an invalid type." in result.stderr

    manifest = json.loads((project / "target-dxt" / "manifest.json").read_text())
    assert_manifest_schema_slice(project / "target-dxt" / "manifest.json")
    assert manifest["macros"]["macro.macro_validate_args.plain_macro"]["arguments"] == [
        {"name": "column_name", "type": None, "description": ""},
        {"name": "optional_suffix", "type": None, "description": ""},
    ]
    assert manifest["macros"]["macro.macro_validate_args.patched_macro"]["arguments"] == [
        {
            "name": "column_name",
            "type": "string",
            "description": "Column expression.",
        },
        {
            "name": "quote",
            "type": "bool",
            "description": "Whether to quote.",
        },
    ]
    assert manifest["macros"]["macro.macro_validate_args.bad_macro"]["arguments"] == [
        {"name": "first_arg", "type": "string", "description": ""},
        {"name": "wrong_name", "type": "list", "description": ""},
        {"name": "extra_arg", "type": "optional[string]", "description": ""},
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
    assert disabled_node["database"] == "memory"
    assert disabled_node["schema"] == "main"
    assert disabled_node["alias"] == "disabled_customers"
    assert disabled_node["fqn"] == ["disabled_model", "disabled_customers"]
    assert disabled_node["checksum"] == dbt_sha256_text((project / "models" / "disabled_customers.sql").read_text())
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


def test_inline_config_enabled_false_model_is_disabled(tmp_path: Path):
    project = copy_fixture(tmp_path, "inline_disabled_model")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", "target-dxt"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    manifest = json.loads((project / "target-dxt" / "manifest.json").read_text())
    assert sorted(manifest["nodes"]) == ["model.inline_disabled_model.active"]
    disabled_id = "model.inline_disabled_model.disabled_customers"
    assert disabled_id not in manifest["nodes"]
    assert disabled_id not in manifest["parent_map"]
    assert disabled_id not in manifest["child_map"]
    assert list(manifest["disabled"]) == [disabled_id]
    disabled_node = manifest["disabled"][disabled_id][0]
    assert disabled_node["database"] == "memory"
    assert disabled_node["schema"] == "main"
    assert disabled_node["alias"] == "disabled_customers"
    assert disabled_node["fqn"] == ["inline_disabled_model", "disabled_customers"]
    assert disabled_node["checksum"] == dbt_sha256_text((project / "models" / "disabled_customers.sql").read_text())
    assert disabled_node["config"]["enabled"] is False
    assert disabled_node["description"] == "Inline-disabled model should stay out of active graph"

    ls_result = subprocess.run(
        [DXT, "ls", "--project-dir", str(project)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_result.returncode == 0, ls_result.stderr
    assert ls_result.stdout.splitlines() == ["model.inline_disabled_model.active"]

    compile_target = tmp_path / "compile-target"
    compile_result = subprocess.run(
        [DXT, "compile", "--project-dir", str(project), "--target-path", str(compile_target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert compile_result.returncode == 0, compile_result.stderr
    assert "Compiled 1 model(s)" in compile_result.stdout
    compiled_root = compile_target / "compiled" / "inline_disabled_model" / "models"
    assert sorted(path.name for path in compiled_root.glob("*.sql")) == ["active.sql"]
    assert (compiled_root / "active.sql").read_text().strip() == "select 1 as active_id"


def test_ref_to_inline_disabled_model_fails_loudly(tmp_path: Path):
    project = copy_fixture(tmp_path, "inline_disabled_ref")
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
    assert "did not find matching model node for property" in result.stderr
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


def test_parse_and_ls_resolve_vars_inside_ref_and_source(tmp_path: Path):
    project = copy_fixture(tmp_path, "dynamic_var_ref")
    result = subprocess.run(
        [
            DXT,
            "parse",
            "--project-dir",
            str(project),
            "--target-path",
            "target-dxt",
            "--vars",
            '{"raw_table": "transactions"}',
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    manifest = json.loads((project / "target-dxt" / "manifest.json").read_text())
    orders = manifest["nodes"]["model.dynamic_var_ref.orders"]
    assert orders["refs"] == [{"name": "customers", "package": None, "version": None}]
    assert orders["depends_on"]["nodes"] == ["model.dynamic_var_ref.customers"]
    from_source = manifest["nodes"]["model.dynamic_var_ref.from_source"]
    assert from_source["sources"] == [["raw", "transactions"]]
    assert from_source["depends_on"]["nodes"] == ["source.dynamic_var_ref.raw.transactions"]
    assert manifest["parent_map"]["model.dynamic_var_ref.orders"] == ["model.dynamic_var_ref.customers"]
    assert "model.dynamic_var_ref.orders" in manifest["child_map"]["model.dynamic_var_ref.customers"]

    ls_result = subprocess.run(
        [
            DXT,
            "ls",
            "--project-dir",
            str(project),
            "--select",
            "alt_customers+",
            "--vars",
            "{customer_model: alt_customers}",
            "--output",
            "json",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_result.returncode == 0, ls_result.stderr
    assert [item["unique_id"] for item in json.loads(ls_result.stdout)] == [
        "model.dynamic_var_ref.alt_customers",
        "model.dynamic_var_ref.orders",
    ]


def test_parse_and_ls_resolve_static_loop_ref_and_source_dependencies(tmp_path: Path):
    project = copy_fixture(tmp_path, "static_loop_deps")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--target-path", "target-dxt"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    manifest = json.loads((project / "target-dxt" / "manifest.json").read_text())
    looped = manifest["nodes"]["model.static_loop_deps.looped"]
    assert looped["refs"] == [
        {"name": "customers", "package": None, "version": None},
        {"name": "orders", "package": None, "version": None},
    ]
    assert looped["sources"] == [["raw", "events"], ["raw", "payments"]]
    assert looped["depends_on"]["nodes"] == [
        "model.static_loop_deps.customers",
        "model.static_loop_deps.orders",
        "source.static_loop_deps.raw.events",
        "source.static_loop_deps.raw.payments",
    ]
    assert manifest["parent_map"]["model.static_loop_deps.looped"] == [
        "model.static_loop_deps.customers",
        "model.static_loop_deps.orders",
        "source.static_loop_deps.raw.events",
        "source.static_loop_deps.raw.payments",
    ]
    assert "model.static_loop_deps.looped" in manifest["child_map"]["model.static_loop_deps.customers"]
    assert "model.static_loop_deps.looped" in manifest["child_map"]["source.static_loop_deps.raw.events"]

    upstream_result = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "+looped", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert upstream_result.returncode == 0, upstream_result.stderr
    assert [item["unique_id"] for item in json.loads(upstream_result.stdout)] == [
        "model.static_loop_deps.customers",
        "model.static_loop_deps.looped",
        "model.static_loop_deps.orders",
        "source.static_loop_deps.raw.events",
        "source.static_loop_deps.raw.payments",
    ]

    source_descendant_result = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "source:raw.events+", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert source_descendant_result.returncode == 0, source_descendant_result.stderr
    assert [item["unique_id"] for item in json.loads(source_descendant_result.stdout)] == [
        "model.static_loop_deps.looped",
        "source.static_loop_deps.raw.events",
    ]


def test_compile_resolves_static_loop_ref_and_source_relations(tmp_path: Path):
    project = copy_fixture(tmp_path, "static_loop_deps")
    target = tmp_path / "compile-target"
    result = subprocess.run(
        [DXT, "compile", "--project-dir", str(project), "--target-path", str(target), "--select", "looped"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    compiled = (target / "compiled" / "static_loop_deps" / "models" / "looped.sql").read_text()
    assert 'from "main"."customers"' in compiled
    assert 'from "main"."orders"' in compiled
    assert 'from "raw"."events"' in compiled
    assert 'from "raw"."payments"' in compiled
    assert "{{" not in compiled
    assert "{%" not in compiled

    manifest = json.loads((target / "manifest.json").read_text())
    looped = manifest["nodes"]["model.static_loop_deps.looped"]
    assert looped["compiled"] is True
    assert looped["compiled_code"] == compiled


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
    assert seed["database"] == "memory"
    assert seed["schema"] == "main"
    assert seed["alias"] == "raw_customers"
    assert seed["fqn"] == ["seed_ref", "raw_customers"]
    assert seed["checksum"] == dbt_sha256_text((project / "seeds" / "raw_customers.csv").read_text())
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

    ls_file_seed = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "file:raw_customers.csv", "--resource-type", "seed", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert ls_file_seed.returncode == 0, ls_file_seed.stderr
    assert json.loads(ls_file_seed.stdout) == json.loads(ls_result.stdout)


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

    name_result = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "tag:nightly", "--output", "name"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert name_result.returncode == 0, name_result.stderr
    assert name_result.stdout.splitlines() == ["orders"]

    path_result = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "tag:nightly", "--output", "path"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert path_result.returncode == 0, path_result.stderr
    assert path_result.stdout.splitlines() == ["models/orders.sql"]

    selector_result = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "tag:nightly", "--output", "selector"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert selector_result.returncode == 0, selector_result.stderr
    assert selector_result.stdout.splitlines() == ["inline_config.orders"]

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

    keyed_json = subprocess.run(
        [
            DXT,
            "ls",
            "--project-dir",
            str(project),
            "--output",
            "json",
            "--resource-type",
            "model",
            "--output-keys",
            "name",
            "path",
            "original_file_path",
            "selector",
            "unique_id",
            "missing",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert keyed_json.returncode == 0, keyed_json.stderr
    assert json.loads(keyed_json.stdout) == [
        {
            "name": "orders",
            "path": "orders.sql",
            "original_file_path": "models/orders.sql",
            "selector": "inline_config.orders",
            "unique_id": "model.inline_config.orders",
        }
    ]

    repeated_keyed_json = subprocess.run(
        [
            DXT,
            "ls",
            "--project-dir",
            str(project),
            "--output",
            "json",
            "--resource-type",
            "model",
            "--output-keys",
            "name",
            "--output-keys",
            "unique_id",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert repeated_keyed_json.returncode == 0, repeated_keyed_json.stderr
    assert json.loads(repeated_keyed_json.stdout) == [{"name": "orders", "unique_id": "model.inline_config.orders"}]

    package_keyed_json = subprocess.run(
        [
            DXT,
            "ls",
            "--project-dir",
            str(project),
            "--output",
            "json",
            "--resource-type",
            "model",
            "--output-keys",
            "package_name",
            "alias",
            "config.materialized",
            "config.tags",
            "non_existent_key",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert package_keyed_json.returncode == 0, package_keyed_json.stderr
    assert json.loads(package_keyed_json.stdout) == [
        {
            "package_name": "inline_config",
            "alias": "orders",
            "config.materialized": "table",
            "config.tags": ["finance", "nightly"],
        }
    ]

    alias_project = copy_fixture(tmp_path, "inline_relation_config")
    alias_keyed_json = subprocess.run(
        [
            DXT,
            "ls",
            "--project-dir",
            str(alias_project),
            "--output",
            "json",
            "--select",
            "orders",
            "--output-keys",
            "name",
            "alias",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert alias_keyed_json.returncode == 0, alias_keyed_json.stderr
    assert json.loads(alias_keyed_json.stdout) == [{"name": "orders", "alias": "order_facts"}]

    untagged_project = copy_fixture(tmp_path, "model_ref")
    untagged_keyed_json = subprocess.run(
        [
            DXT,
            "ls",
            "--project-dir",
            str(untagged_project),
            "--output",
            "json",
            "--select",
            "stg_customers",
            "--output-keys",
            "name",
            "alias",
            "config.materialized",
            "config.tags",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert untagged_keyed_json.returncode == 0, untagged_keyed_json.stderr
    assert json.loads(untagged_keyed_json.stdout) == [
        {"name": "stg_customers", "alias": "stg_customers", "config.materialized": "view", "config.tags": []}
    ]

    depends_keyed_json = subprocess.run(
        [
            DXT,
            "ls",
            "--project-dir",
            str(untagged_project),
            "--output",
            "json",
            "--select",
            "customers",
            "--output-keys",
            "name",
            "tags",
            "depends_on",
            "depends_on.nodes",
            "depends_on.macros",
            "config.enabled",
            "config.docs.show",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert depends_keyed_json.returncode == 0, depends_keyed_json.stderr
    assert json.loads(depends_keyed_json.stdout) == [
        {
            "name": "customers",
            "tags": [],
            "depends_on.nodes": ["model.model_ref.stg_customers"],
            "depends_on.macros": [],
            "config.enabled": True,
            "config.docs.show": True,
        }
    ]

    source_project = copy_fixture(tmp_path, "source_ref")
    source_keyed_json = subprocess.run(
        [
            DXT,
            "ls",
            "--project-dir",
            str(source_project),
            "--output",
            "json",
            "--resource-type",
            "source",
            "--select",
            "source:raw.customers",
            "--output-keys",
            "name",
            "source_name",
            "identifier",
            "alias",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert source_keyed_json.returncode == 0, source_keyed_json.stderr
    assert json.loads(source_keyed_json.stdout) == [
        {"name": "customers", "source_name": "raw", "identifier": "customers"}
    ]

    missing_output_key = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--output", "json", "--output-keys"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert missing_output_key.returncode == 2
    assert "requires a value" in missing_output_key.stderr

    excluded = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "orders", "--exclude", "orders"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert excluded.returncode == 0, excluded.stderr
    assert excluded.stdout == ""

    invalid_output = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--output", "wide"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert invalid_output.returncode == 2
    assert "--output must be text, json, name, path, or selector" in invalid_output.stderr


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
    assert ls_json("--select", "file:orders.sql") == ["model.selector_graph.orders"]
    assert ls_json("--select", "file:orders") == ["model.selector_graph.orders"]
    assert ls_json("--select", "file:ord[ea]rs.sql") == ["model.selector_graph.orders"]
    assert ls_json("--select", "file:stg_[a-z]*.sql") == ["model.selector_graph.stg_customers"]
    assert ls_json("--select", "file:ord[z-a]rs.sql") == []
    assert ls_json("--select", "file:*customers.sql") == [
        "model.selector_graph.customers",
        "model.selector_graph.stg_customers",
    ]
    assert ls_json("--select", "file:models/orders.sql") == []
    assert ls_json("--select", "path:models/stg_*") == ["model.selector_graph.stg_customers"]
    assert ls_json("--select", "path:models/[op]*.sql") == ["model.selector_graph.orders"]
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


def test_ls_root_selectors_yml_scalar_aliases(tmp_path: Path):
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

    assert ls_json("--selector", "customer_family") == ls_json("--select", "*customers")
    assert ls_json("--selector", "customer_and_descendants") == ls_json("--select", "customers+")
    assert ls_json("--selector", "staging_views") == ["model.selector_graph.stg_customers"]
    assert ls_json("--selector", "customer_union") == [
        "model.selector_graph.customers",
        "model.selector_graph.orders",
    ]
    assert ls_json("--selector", "staging_intersection") == ["model.selector_graph.stg_customers"]
    assert ls_json("--selector", "customer_without_staging") == ["model.selector_graph.customers"]
    assert ls_json("--selector", "customer_family", "--exclude", "stg_customers") == [
        "model.selector_graph.customers"
    ]
    assert ls_json("--selector", "customer_family", "--select", "orders") == [
        "model.selector_graph.customers",
        "model.selector_graph.orders",
        "model.selector_graph.stg_customers",
    ]


def test_dbt_core_root_selectors_yml_scalar_alias_oracle(tmp_path: Path, capsys: pytest.CaptureFixture[str]):
    try:
        has_dbt_core = importlib.util.find_spec("dbt.cli.main") is not None
        has_dbt_duckdb = importlib.util.find_spec("dbt.adapters.duckdb") is not None
    except ModuleNotFoundError:
        has_dbt_core = False
        has_dbt_duckdb = False

    if not has_dbt_core:
        pytest.skip("dbt Core is not installed for the optional selector alias oracle")
    if not has_dbt_duckdb:
        pytest.skip("dbt DuckDB adapter is not installed for the optional selector alias oracle")

    from dbt.cli.main import dbtRunner

    project = copy_fixture(tmp_path, "selector_graph")
    (project / "profiles.yml").write_text(
        "\n".join(
            [
                "default:",
                "  target: dev",
                "  outputs:",
                "    dev:",
                "      type: duckdb",
                "      path: oracle.duckdb",
                "      schema: main",
            ]
        )
        + "\n"
    )

    dxt_result = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--selector", "customer_without_staging", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert dxt_result.returncode == 0, dxt_result.stderr
    dxt_ids = [item["unique_id"] for item in json.loads(dxt_result.stdout)]

    dbt_result = dbtRunner().invoke(
        [
            "ls",
            "--project-dir",
            str(project),
            "--profiles-dir",
            str(project),
            "--selector",
            "customer_without_staging",
            "--output",
            "json",
        ]
    )
    dbt_stdout = capsys.readouterr().out
    dbt_ids = sorted(
        json.loads(line)["unique_id"]
        for line in dbt_stdout.splitlines()
        if line.strip().startswith("{")
    )
    if not dbt_result.success and not dbt_ids:
        pytest.skip(f"dbt Core selector oracle unavailable: {dbt_result.exception!r}")

    assert dxt_ids == dbt_ids


def test_ls_source_status_selects_sources_from_sources_json_state(tmp_path: Path):
    project = copy_fixture(tmp_path, "source_freshness")
    state_dir = tmp_path / "state"
    write_sources_state(
        state_dir,
        {
            "source.source_freshness.raw.customers": "warn",
            "source.source_freshness.raw.orders": "error",
            "source.source_freshness.raw.expression_customers": "pass",
        },
    )

    def selected_ids(status: str) -> list[str]:
        result = subprocess.run(
            [
                DXT,
                "ls",
                "--project-dir",
                str(project),
                "--state",
                str(state_dir),
                "--select",
                f"source_status:{status}",
                "--output",
                "json",
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        assert result.returncode == 0, result.stderr
        return [item["unique_id"] for item in json.loads(result.stdout)]

    assert selected_ids("error") == ["source.source_freshness.raw.orders"]
    assert selected_ids("warn") == ["source.source_freshness.raw.customers"]
    assert selected_ids("pass") == ["source.source_freshness.raw.expression_customers"]


def test_source_status_selector_reuses_shared_engine_for_compile(tmp_path: Path):
    project = copy_fixture(tmp_path, "source_ref")
    state_dir = tmp_path / "state"
    target = tmp_path / "compile-target"
    write_sources_state(state_dir, {"source.source_ref.raw.customers": "warn"})

    result = subprocess.run(
        [
            DXT,
            "compile",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--state",
            str(state_dir),
            "--select",
            "source_status:warn+",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Compiled 1 model(s)" in result.stdout
    compiled = target / "compiled" / "source_ref" / "models" / "stg_customers.sql"
    assert compiled.exists()
    assert 'from "raw"."customers"' in compiled.read_text()


def test_source_status_selector_reports_missing_malformed_and_version_mismatch(tmp_path: Path):
    project = copy_fixture(tmp_path, "source_ref")

    missing = subprocess.run(
        [
            DXT,
            "ls",
            "--project-dir",
            str(project),
            "--state",
            str(tmp_path / "missing-state"),
            "--select",
            "source_status:warn",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert missing.returncode == 2
    assert "directory containing sources.json" in missing.stderr

    no_state = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "source_status:warn"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert no_state.returncode == 2
    assert "source_status selectors require --state" in no_state.stderr

    malformed_state = tmp_path / "malformed"
    malformed_state.mkdir()
    (malformed_state / "sources.json").write_text("{\"metadata\":{},\"results\":[]}", encoding="utf-8")
    malformed = subprocess.run(
        [
            DXT,
            "ls",
            "--project-dir",
            str(project),
            "--state",
            str(malformed_state),
            "--select",
            "source_status:warn",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert malformed.returncode == 2
    assert "sources.json is malformed" in malformed.stderr

    version_state = tmp_path / "version"
    version_state.mkdir()
    (version_state / "sources.json").write_text(
        json.dumps(
            {
                "metadata": {"dbt_schema_version": "https://schemas.getdbt.com/dbt/sources/v2.json"},
                "results": [],
            }
        ),
        encoding="utf-8",
    )
    version = subprocess.run(
        [
            DXT,
            "ls",
            "--project-dir",
            str(project),
            "--state",
            str(version_state),
            "--select",
            "source_status:warn",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert version.returncode == 2
    assert "dbt Sources v3 schema" in version.stderr


def test_ls_result_selector_selects_resources_from_run_results_json_state(tmp_path: Path):
    project = copy_fixture(tmp_path, "selector_graph")
    (project / "models" / "schema.yml").write_text(
        "\n".join(
            [
                "version: 2",
                "models:",
                "  - name: customers",
                "    columns:",
                "      - name: customer_id",
                "        tests:",
                "          - not_null",
            ]
        )
        + "\n",
        encoding="utf-8",
    )

    tests_result = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--resource-type", "test", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert tests_result.returncode == 0, tests_result.stderr
    test_id = json.loads(tests_result.stdout)[0]["unique_id"]

    state_dir = tmp_path / "state"
    write_run_results_state(
        state_dir,
        {
            "model.selector_graph.stg_customers": "success",
            "model.selector_graph.customers": "error",
            "model.selector_graph.orders": "skipped",
            test_id: "fail",
        },
    )

    def selected_ids(status: str) -> list[str]:
        result = subprocess.run(
            [
                DXT,
                "ls",
                "--project-dir",
                str(project),
                "--state",
                str(state_dir),
                "--select",
                f"result:{status}",
                "--output",
                "json",
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        assert result.returncode == 0, result.stderr
        return [item["unique_id"] for item in json.loads(result.stdout)]

    assert selected_ids("success") == ["model.selector_graph.stg_customers"]
    assert selected_ids("error") == ["model.selector_graph.customers"]
    assert selected_ids("skipped") == ["model.selector_graph.orders"]
    assert selected_ids("fail") == [test_id]

    expanded = subprocess.run(
        [
            DXT,
            "ls",
            "--project-dir",
            str(project),
            "--state",
            str(state_dir),
            "--select",
            "result:error+",
            "--output",
            "json",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert expanded.returncode == 0, expanded.stderr
    assert [item["unique_id"] for item in json.loads(expanded.stdout)] == [
        "model.selector_graph.customers",
        "model.selector_graph.orders",
        test_id,
    ]


def test_result_selector_reports_missing_malformed_and_version_mismatch(tmp_path: Path):
    project = copy_fixture(tmp_path, "selector_graph")

    missing = subprocess.run(
        [
            DXT,
            "ls",
            "--project-dir",
            str(project),
            "--state",
            str(tmp_path / "missing-state"),
            "--select",
            "result:error",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert missing.returncode == 2
    assert "directory containing run_results.json" in missing.stderr

    no_state = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--select", "result:error"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert no_state.returncode == 2
    assert "result selectors require --state" in no_state.stderr

    malformed_state = tmp_path / "malformed"
    malformed_state.mkdir()
    (malformed_state / "run_results.json").write_text("{\"metadata\":{},\"results\":[]}", encoding="utf-8")
    malformed = subprocess.run(
        [
            DXT,
            "ls",
            "--project-dir",
            str(project),
            "--state",
            str(malformed_state),
            "--select",
            "result:error",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert malformed.returncode == 2
    assert "run_results.json is malformed" in malformed.stderr

    version_state = tmp_path / "version"
    version_state.mkdir()
    (version_state / "run_results.json").write_text(
        json.dumps(
            {
                "metadata": {"dbt_schema_version": "https://schemas.getdbt.com/dbt/run-results/v5.json"},
                "results": [],
            }
        ),
        encoding="utf-8",
    )
    version = subprocess.run(
        [
            DXT,
            "ls",
            "--project-dir",
            str(project),
            "--state",
            str(version_state),
            "--select",
            "result:error",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert version.returncode == 2
    assert "dbt Run Results v6 schema" in version.stderr


def test_dbt_core_result_selector_oracle(tmp_path: Path, capsys: pytest.CaptureFixture[str]):
    try:
        has_dbt_core = importlib.util.find_spec("dbt.cli.main") is not None
        has_dbt_duckdb = importlib.util.find_spec("dbt.adapters.duckdb") is not None
    except ModuleNotFoundError:
        has_dbt_core = False
        has_dbt_duckdb = False

    if not has_dbt_core:
        pytest.skip("dbt Core is not installed for the optional result selector oracle")
    if not has_dbt_duckdb:
        pytest.skip("dbt DuckDB adapter is not installed for the optional result selector oracle")

    from dbt.cli.main import dbtRunner

    project = copy_fixture(tmp_path, "selector_graph")
    (project / "profiles.yml").write_text(
        "\n".join(
            [
                "default:",
                "  target: dev",
                "  outputs:",
                "    dev:",
                "      type: duckdb",
                "      path: oracle.duckdb",
                "      schema: main",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    state_dir = tmp_path / "state"
    parse_result = dbtRunner().invoke(
        [
            "parse",
            "--project-dir",
            str(project),
            "--profiles-dir",
            str(project),
            "--target-path",
            str(state_dir),
        ]
    )
    capsys.readouterr()
    if not parse_result.success:
        pytest.skip(f"dbt Core result selector oracle parse unavailable: {parse_result.exception!r}")

    write_run_results_state(
        state_dir,
        {
            "model.selector_graph.customers": "error",
            "model.selector_graph.orders": "skipped",
            "model.selector_graph.stg_customers": "success",
        },
    )

    dxt_result = subprocess.run(
        [
            DXT,
            "ls",
            "--project-dir",
            str(project),
            "--state",
            str(state_dir),
            "--select",
            "result:error+",
            "--output",
            "json",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert dxt_result.returncode == 0, dxt_result.stderr
    dxt_ids = [item["unique_id"] for item in json.loads(dxt_result.stdout)]

    dbt_result = dbtRunner().invoke(
        [
            "ls",
            "--project-dir",
            str(project),
            "--profiles-dir",
            str(project),
            "--target-path",
            str(tmp_path / "dbt-target"),
            "--state",
            str(state_dir),
            "--select",
            "result:error+",
            "--output",
            "json",
        ]
    )
    dbt_stdout = capsys.readouterr().out
    dbt_ids = sorted(
        json.loads(line)["unique_id"]
        for line in dbt_stdout.splitlines()
        if line.strip().startswith("{")
    )
    if not dbt_result.success and not dbt_ids:
        pytest.skip(f"dbt Core result selector oracle unavailable: {dbt_result.exception!r}")

    assert dxt_ids == dbt_ids


def test_dbt_core_source_status_selector_oracle(tmp_path: Path, capsys: pytest.CaptureFixture[str]):
    try:
        has_dbt_core = importlib.util.find_spec("dbt.cli.main") is not None
        has_dbt_duckdb = importlib.util.find_spec("dbt.adapters.duckdb") is not None
    except ModuleNotFoundError:
        has_dbt_core = False
        has_dbt_duckdb = False

    if not has_dbt_core:
        pytest.skip("dbt Core is not installed for the optional source_status oracle")
    if not has_dbt_duckdb:
        pytest.skip("dbt DuckDB adapter is not installed for the optional source_status oracle")

    from dbt.cli.main import dbtRunner

    project = copy_fixture(tmp_path, "source_ref")
    state_dir = tmp_path / "state"
    write_sources_state(state_dir, {"source.source_ref.raw.customers": "warn"})
    (project / "profiles.yml").write_text(
        "\n".join(
            [
                "default:",
                "  target: dev",
                "  outputs:",
                "    dev:",
                "      type: duckdb",
                "      path: oracle.duckdb",
                "      schema: main",
            ]
        )
        + "\n",
        encoding="utf-8",
    )

    dxt_result = subprocess.run(
        [
            DXT,
            "ls",
            "--project-dir",
            str(project),
            "--state",
            str(state_dir),
            "--select",
            "source_status:warn",
            "--output",
            "json",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert dxt_result.returncode == 0, dxt_result.stderr
    dxt_ids = [item["unique_id"] for item in json.loads(dxt_result.stdout)]

    dbt_target = tmp_path / "dbt-target"
    dbt_target.mkdir()
    shutil.copy(state_dir / "sources.json", dbt_target / "sources.json")
    dbt_result = dbtRunner().invoke(
        [
            "ls",
            "--project-dir",
            str(project),
            "--profiles-dir",
            str(project),
            "--target-path",
            str(dbt_target),
            "--state",
            str(state_dir),
            "--select",
            "source_status:warn",
            "--output",
            "json",
        ]
    )
    dbt_stdout = capsys.readouterr().out
    dbt_ids = sorted(
        json.loads(line)["unique_id"]
        for line in dbt_stdout.splitlines()
        if line.strip().startswith("{")
    )
    if not dbt_result.success and not dbt_ids:
        pytest.skip(f"dbt Core source_status status oracle unavailable: {dbt_result.exception!r}")

    assert dxt_ids == dbt_ids


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
    source_file = subprocess.run(
        [DXT, "ls", "--project-dir", str(source_project), "--select", "file:schema.yml", "--resource-type", "source", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert source_file.returncode == 0, source_file.stderr
    assert [item["unique_id"] for item in json.loads(source_file.stdout)] == [
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
    source_selector_output = subprocess.run(
        [DXT, "ls", "--project-dir", str(source_project), "--select", "resource_type:source", "--output", "selector"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert source_selector_output.returncode == 0, source_selector_output.stderr
    assert source_selector_output.stdout.splitlines() == [
        "source:source_ref.raw.customers",
        "source:source_ref.raw.orders",
    ]
    source_name_output = subprocess.run(
        [DXT, "ls", "--project-dir", str(source_project), "--select", "resource_type:source", "--output", "name"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert source_name_output.returncode == 0, source_name_output.stderr
    assert source_name_output.stdout.splitlines() == [
        "raw.customers",
        "raw.orders",
    ]
    source_path_output = subprocess.run(
        [DXT, "ls", "--project-dir", str(source_project), "--select", "resource_type:source", "--output", "path"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert source_path_output.returncode == 0, source_path_output.stderr
    assert source_path_output.stdout.splitlines() == [
        "models/schema.yml",
        "models/schema.yml",
    ]
    source_keyed_json = subprocess.run(
        [
            DXT,
            "ls",
            "--project-dir",
            str(source_project),
            "--select",
            "source:raw.customers",
            "--output",
            "json",
            "--output-keys",
            "package_name",
            "source_name",
            "original_file_path",
            "path",
            "selector",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert source_keyed_json.returncode == 0, source_keyed_json.stderr
    assert json.loads(source_keyed_json.stdout) == [
        {
            "package_name": "source_ref",
            "source_name": "raw",
            "original_file_path": "models/schema.yml",
            "path": "models/schema.yml",
            "selector": "source:source_ref.raw.customers",
        }
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
    exposure_file = subprocess.run(
        [DXT, "ls", "--project-dir", str(exposure_project), "--select", "file:schema.yml", "--resource-type", "exposure", "--output", "json"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert exposure_file.returncode == 0, exposure_file.stderr
    assert [item["unique_id"] for item in json.loads(exposure_file.stdout)] == [
        "exposure.exposure_artifacts.weekly_kpis"
    ]
    exposure_selector_output = subprocess.run(
        [DXT, "ls", "--project-dir", str(exposure_project), "--select", "resource_type:exposure", "--output", "selector"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert exposure_selector_output.returncode == 0, exposure_selector_output.stderr
    assert exposure_selector_output.stdout.splitlines() == ["exposure:exposure_artifacts.weekly_kpis"]
    exposure_name_output = subprocess.run(
        [DXT, "ls", "--project-dir", str(exposure_project), "--select", "resource_type:exposure", "--output", "name"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert exposure_name_output.returncode == 0, exposure_name_output.stderr
    assert exposure_name_output.stdout.splitlines() == ["weekly_kpis"]
    exposure_path_output = subprocess.run(
        [DXT, "ls", "--project-dir", str(exposure_project), "--select", "resource_type:exposure", "--output", "path"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert exposure_path_output.returncode == 0, exposure_path_output.stderr
    assert exposure_path_output.stdout.splitlines() == ["models/schema.yml"]
    exposure_keyed_json = subprocess.run(
        [
            DXT,
            "ls",
            "--project-dir",
            str(exposure_project),
            "--select",
            "resource_type:exposure",
            "--output",
            "json",
            "--output-keys",
            "original_file_path",
            "path",
            "selector",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert exposure_keyed_json.returncode == 0, exposure_keyed_json.stderr
    assert json.loads(exposure_keyed_json.stdout) == [
        {
            "original_file_path": "models/schema.yml",
            "path": "schema.yml",
            "selector": "exposure:exposure_artifacts.weekly_kpis",
        }
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
    assert ls_json("--select", "1+orders") == [
        "model.selector_graph.customers",
        "model.selector_graph.orders",
    ]
    assert ls_json("--select", "2+orders") == [
        "model.selector_graph.customers",
        "model.selector_graph.orders",
        "model.selector_graph.stg_customers",
    ]
    assert ls_json("--select", "stg_customers+1") == [
        "model.selector_graph.customers",
        "model.selector_graph.stg_customers",
    ]
    assert ls_json("--select", "stg_customers+2") == [
        "model.selector_graph.customers",
        "model.selector_graph.orders",
        "model.selector_graph.stg_customers",
    ]
    assert ls_json("--select", "1+customers+1") == [
        "model.selector_graph.customers",
        "model.selector_graph.orders",
        "model.selector_graph.stg_customers",
    ]
    assert ls_json("--select", "1+orders,config.materialized:view") == [
        "model.selector_graph.customers"
    ]
    assert ls_json("--select", "@customers") == [
        "model.selector_graph.customers",
        "model.selector_graph.orders",
        "model.selector_graph.stg_customers",
    ]
    assert ls_json("--select", "@orders") == [
        "model.selector_graph.customers",
        "model.selector_graph.orders",
        "model.selector_graph.stg_customers",
    ]
    assert ls_json("--select", "@stg_customers") == [
        "model.selector_graph.customers",
        "model.selector_graph.orders",
        "model.selector_graph.stg_customers",
    ]
    assert ls_json("--select", "@customers,config.materialized:table") == [
        "model.selector_graph.orders"
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
    assert "--resource-type supports only model, analysis, seed, source, exposure, test, or unit_test" in unsupported_type.stderr

    for selector in [
        "state:modified",
        "config.schema:audit",
        "resource_type:snapshot",
        "tag:nightly,",
        "config.materialized:",
        "package:",
        "tag:nightly, config.materialized:view",
        "++customers",
        "1++customers",
        "customers++",
        "customers+1+",
        "++customers++",
        "@",
        "@@customers",
        "customers@",
        "@customers+",
        "@customers+1",
        "@+customers",
        "@1+customers",
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

    missing_alias = subprocess.run(
        [DXT, "ls", "--project-dir", str(project), "--selector", "customer_family"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert missing_alias.returncode == 2
    assert "selector syntax is not supported" in missing_alias.stderr

    duplicated_alias_project = copy_fixture(tmp_path / "duplicated_alias", "selector_graph")
    (duplicated_alias_project / "selectors.yml").write_text(
        "\n".join(
            [
                "selectors:",
                "  - name: duplicate",
                "    definition: customers",
                "  - name: duplicate",
                "    definition: orders",
            ]
        )
        + "\n"
    )
    duplicated_alias = subprocess.run(
        [DXT, "ls", "--project-dir", str(duplicated_alias_project), "--selector", "duplicate"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert duplicated_alias.returncode == 2
    assert "selector syntax is not supported" in duplicated_alias.stderr

    unsupported_yaml_alias_project = copy_fixture(tmp_path / "unsupported_yaml_alias", "selector_graph")
    (unsupported_yaml_alias_project / "selectors.yml").write_text(
        "\n".join(
            [
                "selectors:",
                "  - name: stateful",
                "    definition:",
                "      method: state",
                "      value: modified",
            ]
        )
        + "\n"
    )
    unsupported_yaml_alias = subprocess.run(
        [DXT, "ls", "--project-dir", str(unsupported_yaml_alias_project), "--selector", "stateful"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert unsupported_yaml_alias.returncode == 2
    assert "selector syntax is not supported" in unsupported_yaml_alias.stderr


def test_ls_at_selector_includes_descendant_parents(tmp_path: Path):
    project = copy_fixture(tmp_path, "selector_at_graph")

    def ls_json(*args: str) -> list[str]:
        result = subprocess.run(
            [DXT, "ls", "--project-dir", str(project), "--output", "json", *args],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        assert result.returncode == 0, result.stderr
        return [item["unique_id"] for item in json.loads(result.stdout)]

    assert ls_json("--select", "+customers+") == [
        "model.selector_at_graph.customers",
        "model.selector_at_graph.orders",
        "model.selector_at_graph.stg_customers",
    ]
    assert ls_json("--select", "@customers") == [
        "model.selector_at_graph.customers",
        "model.selector_at_graph.orders",
        "model.selector_at_graph.stg_customers",
        "model.selector_at_graph.stg_products",
    ]


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
    assert "unresolved var" in result.stderr


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


def test_parse_profile_flags_require_profiles_yml(tmp_path: Path):
    project = copy_fixture(tmp_path, "single_model")
    result = subprocess.run(
        [DXT, "parse", "--project-dir", str(project), "--profiles-dir", str(project)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 2
    assert "missing profiles.yml" in result.stderr


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


def write_clean_project(project: Path, clean_targets: list[str] | None = None) -> None:
    (project / "models").mkdir(parents=True)
    (project / "models" / "customers.sql").write_text("select 1 as customer_id")
    lines = [
        "name: clean_fixture",
        "target-path: target",
        "model-paths: [models]",
    ]
    if clean_targets is not None:
        if clean_targets:
            lines.append("clean-targets:")
            lines.extend(f"  - {target}" for target in clean_targets)
        else:
            lines.append("clean-targets: []")
    (project / "dbt_project.yml").write_text("\n".join(lines) + "\n")


def test_clean_removes_configured_project_relative_targets(tmp_path: Path):
    project = tmp_path / "clean_project"
    write_clean_project(project, ["target", "dbt_packages"])
    (project / "target" / "nested").mkdir(parents=True)
    (project / "target" / "nested" / "manifest.json").write_text("{}")
    (project / "dbt_packages").mkdir()
    (project / "dbt_packages" / "package.txt").write_text("installed")

    result = subprocess.run(
        [DXT, "clean", "--project-dir", str(project), "--profiles-dir", str(tmp_path / "empty-profiles")],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )

    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    assert "Finished cleaning 2 path(s)" in result.stdout
    assert not (project / "target").exists()
    assert not (project / "dbt_packages").exists()
    assert (project / "models" / "customers.sql").exists()

    project_again = tmp_path / "clean_project_again"
    write_clean_project(project_again, ["target"])
    (project_again / "target").mkdir()
    profiled_result = subprocess.run(
        [
            DXT,
            "clean",
            "--project-dir",
            str(project_again),
            "--profile",
            "default",
            "--target",
            "dev",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert profiled_result.returncode == 0, profiled_result.stderr
    assert not (project_again / "target").exists()


def test_clean_defaults_to_effective_target_path_and_ignores_missing_targets(tmp_path: Path):
    project = tmp_path / "clean_project"
    write_clean_project(project)
    (project / "custom-target").mkdir()
    (project / "target").mkdir()
    (project / "target" / "kept.txt").write_text("keep")

    result = subprocess.run(
        [
            DXT,
            "clean",
            "--project-dir",
            str(project),
            "--target-path",
            "custom-target",
            "--clean-project-files-only",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )

    assert result.returncode == 0, result.stderr
    assert not (project / "custom-target").exists()
    assert (project / "target" / "kept.txt").exists()

    second_result = subprocess.run(
        [DXT, "clean", "--project-dir", str(project), "--target-path", "missing-target"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert second_result.returncode == 0, second_result.stderr
    assert "Finished cleaning 1 path(s)" in second_result.stdout


@pytest.mark.parametrize(
    ("clean_target", "expected_error"),
    [
        ("models", "source paths"),
        ("tests", "source paths"),
        ("..", "outside the project"),
        (".", "outside the project"),
        ("/tmp/dxt-clean-outside", "outside the project"),
    ],
)
def test_clean_rejects_unsafe_targets_without_deleting(tmp_path: Path, clean_target: str, expected_error: str):
    project = tmp_path / "clean_project"
    write_clean_project(project, [clean_target])
    (project / "target").mkdir()
    (project / "target" / "kept.txt").write_text("keep")

    result = subprocess.run(
        [DXT, "clean", "--project-dir", str(project)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )

    assert result.returncode == 2
    assert expected_error in result.stderr
    assert (project / "target" / "kept.txt").exists()
    assert (project / "models" / "customers.sql").exists()


def test_clean_validates_all_targets_before_deleting_anything(tmp_path: Path):
    project = tmp_path / "clean_project"
    write_clean_project(project, ["target", "models"])
    (project / "target").mkdir()
    (project / "target" / "must_survive.txt").write_text("keep")

    result = subprocess.run(
        [DXT, "clean", "--project-dir", str(project)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )

    assert result.returncode == 2
    assert "source paths" in result.stderr
    assert (project / "target" / "must_survive.txt").exists()
    assert (project / "models" / "customers.sql").exists()


def test_clean_rejects_custom_source_paths_without_deleting(tmp_path: Path):
    project = tmp_path / "clean_project"
    (project / "models").mkdir(parents=True)
    (project / "models" / "customers.sql").write_text("select 1 as customer_id")
    (project / "data_tests").mkdir()
    (project / "data_tests" / "assert_customers.sql").write_text("select 1")
    (project / "marts").mkdir()
    (project / "marts" / "orders.sql").write_text("select 1")
    (project / "target").mkdir()
    (project / "target" / "must_survive.txt").write_text("keep")
    (project / "dbt_project.yml").write_text(
        "\n".join(
            [
                "name: clean_fixture",
                "target-path: target",
                "model-paths: [./marts]",
                "test-paths: [data_tests]",
                "clean-targets:",
                "  - target",
                "  - data_tests",
            ]
        )
        + "\n"
    )

    result = subprocess.run(
        [DXT, "clean", "--project-dir", str(project)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )

    assert result.returncode == 2
    assert "source paths" in result.stderr
    assert (project / "target" / "must_survive.txt").exists()
    assert (project / "data_tests" / "assert_customers.sql").exists()

    (project / "dbt_project.yml").write_text(
        "\n".join(
            [
                "name: clean_fixture",
                "target-path: target",
                "model-paths: [./marts]",
                "clean-targets: [marts]",
            ]
        )
        + "\n"
    )
    model_result = subprocess.run(
        [DXT, "clean", "--project-dir", str(project)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert model_result.returncode == 2
    assert "source paths" in model_result.stderr
    assert (project / "marts" / "orders.sql").exists()

    (project / "marts" / "generated").mkdir()
    (project / "marts" / "generated" / "must_survive.sql").write_text("select 1")
    (project / "dbt_project.yml").write_text(
        "\n".join(
            [
                "name: clean_fixture",
                "target-path: target",
                "model-paths: [marts/]",
                "clean-targets: [marts/generated]",
            ]
        )
        + "\n"
    )
    trailing_slash_result = subprocess.run(
        [DXT, "clean", "--project-dir", str(project)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert trailing_slash_result.returncode == 2
    assert "source paths" in trailing_slash_result.stderr
    assert (project / "marts" / "generated" / "must_survive.sql").exists()


def test_clean_skips_plain_files(tmp_path: Path):
    project = tmp_path / "clean_project"
    write_clean_project(project, ["target-file"])
    (project / "target-file").write_text("not a directory")

    result = subprocess.run(
        [DXT, "clean", "--project-dir", str(project)],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )

    assert result.returncode == 0, result.stderr
    assert (project / "target-file").read_text() == "not a directory"


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


def test_docs_serve_serves_generated_artifacts_without_mutating_them(tmp_path: Path):
    project = copy_fixture(tmp_path, "docs_blocks")
    target = tmp_path / "docs-target"
    generate_result = subprocess.run(
        [
            DXT,
            "docs",
            "generate",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert generate_result.returncode == 0, generate_result.stderr

    manifest_path = target / "manifest.json"
    catalog_path = target / "catalog.json"
    manifest_before = manifest_path.read_bytes()
    catalog_before = catalog_path.read_bytes()

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]

    server = subprocess.Popen(
        [
            DXT,
            "docs",
            "serve",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
            "--no-browser",
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        base_url = f"http://127.0.0.1:{port}"
        deadline = time.monotonic() + 10
        while True:
            if server.poll() is not None:
                stdout, stderr = server.communicate()
                raise AssertionError(f"docs serve exited early: stdout={stdout!r} stderr={stderr!r}")
            try:
                with urllib.request.urlopen(f"{base_url}/manifest.json", timeout=0.5) as response:
                    assert response.status == 200
                    served_manifest = response.read()
                break
            except (OSError, urllib.error.URLError):
                if time.monotonic() >= deadline:
                    raise AssertionError("docs serve did not start before timeout")
                time.sleep(0.05)

        assert served_manifest == manifest_before
        with urllib.request.urlopen(f"{base_url}/catalog.json", timeout=2) as response:
            assert response.status == 200
            assert response.headers["Content-Type"].startswith("application/json")
            assert response.read() == catalog_before
        with urllib.request.urlopen(f"{base_url}/", timeout=2) as response:
            assert response.status == 200
            assert "dxt docs" in response.read().decode()
        with pytest.raises(urllib.error.HTTPError) as exc_info:
            urllib.request.urlopen(f"{base_url}/../manifest.json", timeout=2)
        assert exc_info.value.code == 400
    finally:
        server.terminate()
        try:
            stdout, stderr = server.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            stdout, stderr = server.communicate(timeout=5)

    assert "Serving docs at" in stdout
    assert "Press Ctrl+C to exit." in stdout
    assert stderr == ""
    assert manifest_path.read_bytes() == manifest_before
    assert catalog_path.read_bytes() == catalog_before


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 docs catalog execution coverage")
def test_docs_generate_catalogs_existing_duckdb_relations(tmp_path: Path):
    project = copy_fixture(tmp_path, "compile_basic")
    target = tmp_path / "docs-target"
    build_result = subprocess.run(
        [
            DXT,
            "build",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "+orders",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert build_result.returncode == 0, build_result.stderr

    docs_result = subprocess.run(
        [
            DXT,
            "docs",
            "generate",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "+orders",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert docs_result.returncode == 0, docs_result.stderr
    assert "Generated docs artifacts for 2 compiled model(s)" in docs_result.stdout

    catalog_path = target / "catalog.json"
    catalog = json.loads(catalog_path.read_text())
    assert_catalog_schema_slice(catalog_path)
    assert sorted(catalog["nodes"]) == [
        "model.compile_basic.customers",
        "model.compile_basic.orders",
    ]
    customers = catalog["nodes"]["model.compile_basic.customers"]
    orders = catalog["nodes"]["model.compile_basic.orders"]
    assert customers["metadata"] == {
        "type": "VIEW",
        "schema": "main",
        "name": "customers",
        "database": None,
        "comment": None,
        "owner": None,
    }
    assert list(customers["columns"]) == ["customer_id"]
    assert customers["columns"]["customer_id"] == {
        "type": "INTEGER",
        "index": 1,
        "name": "customer_id",
        "comment": None,
    }
    assert orders["metadata"]["type"] == "BASE TABLE"
    assert orders["columns"]["customer_id"]["type"] == "INTEGER"
    assert orders["columns"]["order_count"]["type"] == "BIGINT"
    assert orders["stats"]["has_stats"]["include"] is False
    assert orders["unique_id"] == "model.compile_basic.orders"
    assert catalog["sources"] == {}
    assert catalog["errors"] is None
    assert str(project) not in catalog_path.read_text()


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 docs source catalog execution coverage")
def test_docs_generate_catalogs_selected_duckdb_sources(tmp_path: Path):
    project = copy_fixture(tmp_path, "source_ref")
    target = tmp_path / "docs-target"
    target.mkdir()
    db_path = target / "dxt.duckdb"
    subprocess.run(
        [
            DUCKDB,
            str(db_path),
            "-batch",
            "-bail",
            "-c",
            "create schema raw; create table raw.customers (customer_id integer, customer_name varchar);",
        ],
        cwd=ROOT,
        check=True,
        text=True,
        capture_output=True,
    )

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
            "source:raw.customers",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Generated docs artifacts for 0 compiled model(s)" in result.stdout

    catalog_path = target / "catalog.json"
    catalog = json.loads(catalog_path.read_text())
    assert_catalog_schema_slice(catalog_path)
    assert catalog["nodes"] == {}
    assert sorted(catalog["sources"]) == ["source.source_ref.raw.customers"]
    source = catalog["sources"]["source.source_ref.raw.customers"]
    assert source["metadata"] == {
        "type": "BASE TABLE",
        "schema": "raw",
        "name": "customers",
        "database": None,
        "comment": None,
        "owner": None,
    }
    assert list(source["columns"]) == ["customer_id", "customer_name"]
    assert source["columns"]["customer_id"] == {
        "type": "INTEGER",
        "index": 1,
        "name": "customer_id",
        "comment": None,
    }
    assert source["columns"]["customer_name"]["type"] == "VARCHAR"
    assert source["unique_id"] == "source.source_ref.raw.customers"
    assert str(project) not in catalog_path.read_text()


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 source freshness execution coverage")
def test_source_freshness_checks_selected_duckdb_source_and_writes_sources_json(tmp_path: Path):
    project = copy_fixture(tmp_path, "source_freshness")
    target = tmp_path / "freshness-target"
    target.mkdir()
    db_path = target / "dxt.duckdb"
    subprocess.run(
        [
            DUCKDB,
            str(db_path),
            "-batch",
            "-bail",
            "-c",
            "create schema raw; create table raw.customers as select 1 as customer_id, current_timestamp - interval '2 hours' as loaded_at;",
        ],
        cwd=ROOT,
        check=True,
        text=True,
        capture_output=True,
    )

    result = subprocess.run(
        [
            DXT,
            "source",
            "freshness",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "source:raw.customers",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Checked freshness for 1 source(s)" in result.stdout
    assert result.stderr == ""

    sources_path = target / "sources.json"
    assert_sources_schema_slice(sources_path)
    sources = json.loads(sources_path.read_text())
    assert sources["metadata"]["dbt_schema_version"] == "https://schemas.getdbt.com/dbt/sources/v3.json"
    assert sources["metadata"]["dbt_version"] == "0.0.0"
    assert sources["metadata"]["invocation_id"] is None
    assert sources["metadata"]["invocation_started_at"] is None
    assert sources["metadata"]["env"] == {}
    assert len(sources["results"]) == 1
    result_row = sources["results"][0]
    assert result_row["unique_id"] == "source.source_freshness.raw.customers"
    assert result_row["status"] == "warn"
    assert result_row["max_loaded_at"].endswith("Z")
    assert result_row["snapshotted_at"].endswith("Z")
    assert result_row["max_loaded_at_time_ago_in_s"] >= 3600
    assert result_row["criteria"] == {
        "warn_after": {"count": 1, "period": "hour"},
        "error_after": {"count": 1, "period": "day"},
        "filter": None,
    }
    assert result_row["adapter_response"] == {}
    assert result_row["timing"] == [{"name": "execute", "started_at": None, "completed_at": None}]
    assert result_row["thread_id"] == "Thread-1"
    assert result_row["execution_time"] == 0.0
    assert str(project) not in sources_path.read_text()
    assert (target / "manifest.json").exists()


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for source freshness inheritance coverage")
def test_source_freshness_inherits_source_config_and_applies_table_overrides(tmp_path: Path):
    project = copy_fixture(tmp_path, "source_freshness_inheritance")
    target = tmp_path / "freshness-target"
    target.mkdir()
    db_path = target / "dxt.duckdb"
    subprocess.run(
        [
            DUCKDB,
            str(db_path),
            "-batch",
            "-bail",
            "-c",
            (
                "create schema main_raw; "
                "create table main_raw.inherited_customers as select 1 as customer_id, current_timestamp - interval '2 hours' as loaded_at; "
                "create table main_raw.query_customers as select 1 as customer_id, current_timestamp - interval '2 hours' as loaded_at; "
                "create table main_raw.override_customers as select 1 as customer_id, current_timestamp - interval '4 hours' as override_loaded_at;"
            ),
        ],
        cwd=ROOT,
        check=True,
        text=True,
        capture_output=True,
    )

    result = subprocess.run(
        [
            DXT,
            "source",
            "freshness",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr
    assert "Checked freshness for 3 source(s)" in result.stdout

    sources_path = target / "sources.json"
    assert_sources_schema_slice(sources_path)
    rows = {row["unique_id"]: row for row in json.loads(sources_path.read_text())["results"]}
    assert sorted(rows) == [
        "source.source_freshness_inheritance.raw.inherited_customers",
        "source.source_freshness_inheritance.raw.override_customers",
        "source.source_freshness_inheritance.raw.query_customers",
    ]
    inherited = rows["source.source_freshness_inheritance.raw.inherited_customers"]
    assert inherited["status"] == "warn"
    assert inherited["criteria"] == {
        "warn_after": {"count": 1, "period": "hour"},
        "error_after": {"count": 1, "period": "day"},
        "filter": None,
    }
    query_override = rows["source.source_freshness_inheritance.raw.query_customers"]
    assert query_override["status"] == "warn"
    assert query_override["criteria"] == inherited["criteria"]
    table_override = rows["source.source_freshness_inheritance.raw.override_customers"]
    assert table_override["status"] == "warn"
    assert table_override["criteria"] == {
        "warn_after": {"count": 3, "period": "hour"},
        "error_after": {"count": 1, "period": "day"},
        "filter": None,
    }

    manifest_path = target / "manifest.json"
    assert_manifest_schema_slice(manifest_path)
    manifest_sources = json.loads(manifest_path.read_text())["sources"]
    null_source = manifest_sources["source.source_freshness_inheritance.raw.null_freshness_customers"]
    assert null_source["schema"] == "main_raw"
    assert null_source["relation_name"] == '"main_raw"."null_freshness_customers"'
    assert null_source["loaded_at_field"] == "loaded_at"
    assert null_source["loaded_at_query"] is None
    assert null_source["freshness"] is None
    assert null_source["config"]["freshness"] is None
    query_source = manifest_sources["source.source_freshness_inheritance.raw.query_customers"]
    assert query_source["loaded_at_field"] == "loaded_at"
    assert query_source["loaded_at_query"] == "select max(loaded_at) from main_raw.query_customers"


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 source freshness expression coverage")
def test_source_freshness_supports_loaded_at_field_sql_expression(tmp_path: Path):
    project = copy_fixture(tmp_path, "source_freshness")
    target = tmp_path / "freshness-target"
    target.mkdir()
    db_path = target / "dxt.duckdb"
    subprocess.run(
        [
            DUCKDB,
            str(db_path),
            "-batch",
            "-bail",
            "-c",
            "create schema raw; create table raw.expression_customers as select 1 as customer_id, current_timestamp - interval '2 hours' as loaded_at;",
        ],
        cwd=ROOT,
        check=True,
        text=True,
        capture_output=True,
    )

    result = subprocess.run(
        [
            DXT,
            "source",
            "freshness",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "source:raw.expression_customers",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr

    sources_path = target / "sources.json"
    assert_sources_schema_slice(sources_path)
    sources = json.loads(sources_path.read_text())
    assert len(sources["results"]) == 1
    result_row = sources["results"][0]
    assert result_row["unique_id"] == "source.source_freshness.raw.expression_customers"
    assert result_row["status"] == "warn"
    assert result_row["max_loaded_at_time_ago_in_s"] >= 3600


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 source freshness empty-table coverage")
def test_source_freshness_treats_empty_loaded_at_as_stale_result(tmp_path: Path):
    project = copy_fixture(tmp_path, "source_freshness")
    target = tmp_path / "freshness-target"
    target.mkdir()
    db_path = target / "dxt.duckdb"
    subprocess.run(
        [
            DUCKDB,
            str(db_path),
            "-batch",
            "-bail",
            "-c",
            "create schema raw; create table raw.empty_customers (customer_id integer, loaded_at timestamp);",
        ],
        cwd=ROOT,
        check=True,
        text=True,
        capture_output=True,
    )

    result = subprocess.run(
        [
            DXT,
            "source",
            "freshness",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "source:raw.empty_customers",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 1
    assert "one or more source freshness checks failed" in result.stderr

    sources_path = target / "sources.json"
    assert_sources_schema_slice(sources_path)
    sources = json.loads(sources_path.read_text())
    assert len(sources["results"]) == 1
    result_row = sources["results"][0]
    assert result_row["unique_id"] == "source.source_freshness.raw.empty_customers"
    assert result_row["status"] == "error"
    assert "error" not in result_row
    assert result_row["max_loaded_at"] == "0001-01-01T00:00:00Z"
    assert result_row["snapshotted_at"].endswith("Z")
    assert result_row["max_loaded_at_time_ago_in_s"] > 86400


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 source freshness filter coverage")
def test_source_freshness_applies_filter_sql(tmp_path: Path):
    project = copy_fixture(tmp_path, "source_freshness")
    target = tmp_path / "freshness-target"
    target.mkdir()
    db_path = target / "dxt.duckdb"
    subprocess.run(
        [
            DUCKDB,
            str(db_path),
            "-batch",
            "-bail",
            "-c",
            (
                "create schema raw; "
                "create table raw.filtered_customers as "
                "select 0 as customer_id, current_timestamp as loaded_at "
                "union all "
                "select 1 as customer_id, current_timestamp - interval '2 hours' as loaded_at;"
            ),
        ],
        cwd=ROOT,
        check=True,
        text=True,
        capture_output=True,
    )

    result = subprocess.run(
        [
            DXT,
            "source",
            "freshness",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "source:raw.filtered_customers",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr

    sources_path = target / "sources.json"
    assert_sources_schema_slice(sources_path)
    sources = json.loads(sources_path.read_text())
    assert len(sources["results"]) == 1
    result_row = sources["results"][0]
    assert result_row["unique_id"] == "source.source_freshness.raw.filtered_customers"
    assert result_row["status"] == "warn"
    assert result_row["max_loaded_at_time_ago_in_s"] >= 3600
    assert result_row["criteria"] == {
        "warn_after": {"count": 1, "period": "hour"},
        "error_after": {"count": 1, "period": "day"},
        "filter": "customer_id > 0",
    }


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 source freshness loaded-at-query coverage")
def test_source_freshness_executes_loaded_at_query(tmp_path: Path):
    project = copy_fixture(tmp_path, "source_freshness")
    target = tmp_path / "freshness-target"
    target.mkdir()
    db_path = target / "dxt.duckdb"
    subprocess.run(
        [
            DUCKDB,
            str(db_path),
            "-batch",
            "-bail",
            "-c",
            "create schema raw; create table raw.query_customers as select 1 as customer_id, current_timestamp - interval '2 hours' as loaded_at;",
        ],
        cwd=ROOT,
        check=True,
        text=True,
        capture_output=True,
    )

    result = subprocess.run(
        [
            DXT,
            "source",
            "freshness",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "source:raw.query_customers",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr

    sources_path = target / "sources.json"
    assert_sources_schema_slice(sources_path)
    sources = json.loads(sources_path.read_text())
    assert len(sources["results"]) == 1
    result_row = sources["results"][0]
    assert result_row["unique_id"] == "source.source_freshness.raw.query_customers"
    assert result_row["status"] == "warn"
    assert result_row["max_loaded_at"].endswith("Z")
    assert result_row["snapshotted_at"].endswith("Z")
    assert result_row["max_loaded_at_time_ago_in_s"] >= 3600
    assert result_row["criteria"] == {
        "warn_after": {"count": 1, "period": "hour"},
        "error_after": {"count": 1, "period": "day"},
        "filter": None,
    }


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 source freshness loaded-at-query coverage")
def test_source_freshness_loaded_at_query_owns_filtering(tmp_path: Path):
    project = copy_fixture(tmp_path, "source_freshness")
    target = tmp_path / "freshness-target"
    target.mkdir()
    db_path = target / "dxt.duckdb"
    subprocess.run(
        [
            DUCKDB,
            str(db_path),
            "-batch",
            "-bail",
            "-c",
            (
                "create schema raw; "
                "create table raw.query_filtered_customers as "
                "select 0 as customer_id, current_timestamp as loaded_at "
                "union all "
                "select 1 as customer_id, current_timestamp - interval '2 hours' as loaded_at;"
            ),
        ],
        cwd=ROOT,
        check=True,
        text=True,
        capture_output=True,
    )

    result = subprocess.run(
        [
            DXT,
            "source",
            "freshness",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "source:raw.query_filtered_customers",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr

    sources_path = target / "sources.json"
    assert_sources_schema_slice(sources_path)
    sources = json.loads(sources_path.read_text())
    assert len(sources["results"]) == 1
    result_row = sources["results"][0]
    assert result_row["unique_id"] == "source.source_freshness.raw.query_filtered_customers"
    assert result_row["status"] == "warn"
    assert result_row["max_loaded_at_time_ago_in_s"] >= 3600
    assert result_row["criteria"] == {
        "warn_after": {"count": 1, "period": "hour"},
        "error_after": {"count": 1, "period": "day"},
        "filter": "customer_id = 0",
    }


@pytest.mark.skipif(DUCKDB is None, reason="duckdb CLI is required for the M3 source freshness runtime-error coverage")
def test_source_freshness_writes_runtime_error_result_for_missing_loaded_at_field(tmp_path: Path):
    project = copy_fixture(tmp_path, "source_freshness")
    target = tmp_path / "freshness-target"
    target.mkdir()
    db_path = target / "dxt.duckdb"
    subprocess.run(
        [
            DUCKDB,
            str(db_path),
            "-batch",
            "-bail",
            "-c",
            "create schema raw; create table raw.orders (order_id integer);",
        ],
        cwd=ROOT,
        check=True,
        text=True,
        capture_output=True,
    )

    result = subprocess.run(
        [
            DXT,
            "source",
            "freshness",
            "--project-dir",
            str(project),
            "--target-path",
            str(target),
            "--select",
            "source:raw.orders",
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 1
    assert "Checked freshness for 1 source(s)" in result.stdout
    assert "one or more source freshness checks failed" in result.stderr

    sources_path = target / "sources.json"
    assert_sources_schema_slice(sources_path)
    sources = json.loads(sources_path.read_text())
    assert len(sources["results"]) == 1
    result_row = sources["results"][0]
    assert result_row == {
        "unique_id": "source.source_freshness.raw.orders",
        "error": "source freshness currently requires loaded_at_field or loaded_at_query",
        "status": "runtime error",
    }
    assert str(project) not in sources_path.read_text()


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


def test_docs_generate_reuses_file_selectors(tmp_path: Path):
    project = copy_fixture(tmp_path, "compile_basic")
    target = tmp_path / "docs-file-target"
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
            "file:orders.sql",
            "--exclude",
            "file:from_source.sql",
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

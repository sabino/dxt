from __future__ import annotations

import json
import inspect
import os
import shutil
import subprocess
from importlib.metadata import version
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out" / "bin" / "dxt"
DUCKDB = shutil.which("duckdb")
pytestmark = pytest.mark.skipif(DUCKDB is None, reason="DuckDB CLI is required")


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


@pytest.fixture
def core_runner(monkeypatch: pytest.MonkeyPatch):
    main = pytest.importorskip("dbt.cli.main", reason="optional pinned dbt Core error oracle")
    pytest.importorskip("dbt.adapters.duckdb", reason="optional pinned dbt DuckDB error oracle")
    assert version("dbt-core") == "1.10.5"
    assert version("dbt-duckdb") == "1.9.6"
    monkeypatch.setenv("DBT_SEND_ANONYMOUS_USAGE_STATS", "false")
    import dbt_common.events.base_types as events
    import google.protobuf.json_format as protobuf
    original = protobuf.MessageToJson
    parameters = inspect.signature(original).parameters
    options = ("always_print_fields_with_no_presence", "including_default_value_fields")
    supported = next(option for option in options if option in parameters)

    def compatible(message, *args, **kwargs):
        for option in options:
            if option != supported and option in kwargs:
                value = kwargs.pop(option)
                kwargs.setdefault(supported, value)
        return original(message, *args, **kwargs)

    monkeypatch.setattr(protobuf, "MessageToJson", compatible)
    monkeypatch.setattr(events, "MessageToJson", compatible)
    return main.dbtRunner()


def write_profile(directory: Path, database: Path) -> None:
    directory.mkdir()
    (directory / "profiles.yml").write_text(
        "error_outcomes:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n"
        f"      path: {database}\n      schema: main\n      threads: 1\n"
    )


def validate_core_artifact_schema(target: Path) -> None:
    from dbt.artifacts.schemas.run import RunResultsArtifact

    RunResultsArtifact.validate(json.loads((target / "run_results.json").read_text()))


def write_project(project: Path, files: dict[str, str]) -> None:
    project.mkdir()
    (project / "dbt_project.yml").write_text(
        "name: error_outcomes\nversion: '1.0'\nprofile: error_outcomes\n"
        "model-paths: ['models']\ntest-paths: ['tests']\n"
        "models:\n  error_outcomes:\n    +materialized: table\n"
    )
    for name, content in files.items():
        path = project / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)


def run_dxt(project: Path, target: Path, *args: str, env: dict[str, str] | None = None):
    return subprocess.run(
        [DXT, *args, "--project-dir", str(project), "--target-path", str(target)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        env=env,
    )


def results(target: Path) -> dict[str, dict]:
    manifest = json.loads((target / "manifest.json").read_text())
    artifact = json.loads((target / "run_results.json").read_text())
    rows = artifact["results"]
    assert len(rows) == len({row["unique_id"] for row in rows})
    assert all(row["unique_id"] in manifest["nodes"] or row["unique_id"] in manifest["unit_tests"] for row in rows)
    return {row["unique_id"]: row for row in rows}


def assert_error(row: dict, *, unit: bool = False, target: Path | None = None, diagnostic: tuple[str, ...] = ()) -> None:
    assert row["status"] == "error"
    assert row["failures"] is None
    if unit:
        assert row["message"] == "DuckDB execution failed"
    else:
        assert target is not None and diagnostic
        node = json.loads((target / "manifest.json").read_text())["nodes"][row["unique_id"]]
        assert row["message"].startswith(f"Runtime Error in {node['name']} ({node['original_file_path']}):\n")
        for fragment in diagnostic:
            assert fragment in row["message"]
    assert row["adapter_response"] == {}
    assert row["compiled"] is (None if unit else True)
    assert (row["compiled_code"] is None) is unit
    assert row["relation_name"] is None


def query(database: Path, sql: str) -> str:
    return subprocess.run(
        [DUCKDB, str(database), "-csv", "-noheader", "-batch", "-bail", "-c", sql],
        check=True,
        text=True,
        capture_output=True,
    ).stdout.strip()


@pytest.mark.parametrize("command", ["test", "build"])
@pytest.mark.parametrize("kind", ["not_null", "unique", "accepted_values", "relationships", "singular"])
def test_sql_errors_preserve_completed_tests_and_continue_independent_tests(tmp_path: Path, command: str, kind: str):
    files = {
        "models/orders.sql": "select 1 as id\n",
        "models/parents.sql": "select 1 as id\n",
        "tests/a_prior.sql": "select 1 where false\n",
        "tests/zz_independent.sql": "select 1 where false\n",
    }
    if kind == "singular":
        files["tests/m_broken.sql"] = "select from syntax_error\n"
    else:
        definition = kind
        if kind == "accepted_values":
            definition += ":\n              values: [1, 2]\n              quote: false"
        elif kind == "relationships":
            definition += ":\n              to: ref('parents')\n              field: id"
        files["models/schema.yml"] = (
            "version: 2\nmodels:\n  - name: orders\n    columns:\n"
            f"      - name: id\n        data_tests:\n          - {definition}\n"
        )
    project, target = tmp_path / "project", tmp_path / "target"
    write_project(project, files)
    outcome = run_dxt(project, target, command, "--select", "test_type:data")
    assert outcome.returncode == 1, outcome.stdout + outcome.stderr
    rows = results(target)
    assert len(rows) == 3
    assert rows["test.error_outcomes.a_prior"]["status"] == "pass"
    assert rows["test.error_outcomes.zz_independent"]["status"] == "pass"
    errors = [row for row in rows.values() if row["status"] == "error"]
    assert len(errors) == 1
    assert_error(errors[0], target=target, diagnostic=(
        ("Parser Error: SELECT clause without selection list",)
        if kind == "singular" else ("Catalog Error: Table with name orders does not exist!",)
    ))
    assert list(rows)[0] == "test.error_outcomes.a_prior"
    assert list(rows)[-1] == "test.error_outcomes.zz_independent"


def build_error_files(kind: str) -> dict[str, str]:
    files = {
        "models/parent.sql": "select 1 as id\n",
        "models/child.sql": "select * from {{ ref('parent') }}\n",
        "models/zz_independent.sql": "select 9 as id\n",
        "tests/a_prior.sql": "select 1 where false\n",
        "tests/zz_after.sql": "select 1 where false\n",
    }
    if kind == "generic":
        files["models/schema.yml"] = (
            "version: 2\nmodels:\n  - name: parent\n    columns:\n"
            "      - name: missing_column\n        data_tests: [not_null]\n"
            "  - name: child\n    columns:\n      - name: id\n        data_tests: [not_null]\n"
        )
    else:
        files["tests/m_broken.sql"] = "select missing_column from {{ ref('parent') }}\n"
        files["tests/n_child.sql"] = "select id from {{ ref('child') }} where id is null\n"
    return files


@pytest.mark.parametrize("kind", ["generic", "singular"])
def test_build_sql_error_blocks_descendants_and_continues_independent_models(tmp_path: Path, kind: str):
    project, target = tmp_path / "project", tmp_path / "target"
    write_project(project, build_error_files(kind))
    outcome = run_dxt(project, target, "build")
    assert outcome.returncode == 1, outcome.stdout + outcome.stderr
    rows = results(target)
    assert rows["model.error_outcomes.parent"]["status"] == "success"
    assert rows["model.error_outcomes.child"]["status"] == "skipped"
    assert rows["model.error_outcomes.zz_independent"]["status"] == "success"
    assert rows["test.error_outcomes.a_prior"]["status"] == "pass"
    assert rows["test.error_outcomes.zz_after"]["status"] == "pass"
    errors = [row for row in rows.values() if row["status"] == "error"]
    assert len(errors) == 1
    assert_error(errors[0], target=target, diagnostic=("Binder Error:", 'Referenced column "missing_column" not found in FROM clause!'))
    child_tests = [row for key, row in rows.items() if key.startswith("test.") and "child" in key]
    assert len(child_tests) == 1
    assert child_tests[0]["status"] == "skipped"
    for row in [rows["model.error_outcomes.child"], child_tests[0]]:
        assert row["compiled"] is False
        assert row["compiled_code"] is None
    assert rows["model.error_outcomes.child"]["relation_name"] == '"main"."child"'
    assert child_tests[0]["relation_name"] is None
    database = target / "dxt.duckdb"
    assert query(database, "select count(*) from duckdb_tables() where table_name = 'child'") == "0"
    assert query(database, "select id from zz_independent") == "9"


@pytest.mark.parametrize("kind", ["generic", "singular"])
def test_audit_relation_sql_errors_are_durable(tmp_path: Path, kind: str):
    files = {"models/orders.sql": "select null::integer as id\n", "tests/zz_independent.sql": "select 1 where false\n"}
    alias = "not_null_orders_id" if kind == "generic" else "m_broken"
    if kind == "generic":
        files["models/schema.yml"] = (
            "version: 2\nmodels:\n  - name: orders\n    columns:\n      - name: id\n"
            "        data_tests:\n          - not_null:\n              config:\n                store_failures: true\n"
        )
    else:
        files["tests/m_broken.sql"] = "{{ config(store_failures=true) }}select missing_column from {{ ref('orders') }}\n"
    project, target = tmp_path / "project", tmp_path / "target"
    write_project(project, files)
    target.mkdir()
    database = target / "dxt.duckdb"
    query(database, f"create table orders as select null::integer as missing_id; create schema main_dbt_test__audit; create view main_dbt_test__audit.{alias} as select 99 as id;")
    outcome = run_dxt(project, target, "test")
    assert outcome.returncode == 1, outcome.stdout + outcome.stderr
    rows = results(target)
    assert len(rows) == 2
    assert_error(next(row for row in rows.values() if row["status"] == "error"), target=target, diagnostic=(
        "Binder Error:", f'Referenced column "{"id" if kind == "generic" else "missing_column"}" not found in FROM clause!',
    ))
    assert rows["test.error_outcomes.zz_independent"]["status"] == "pass"
    assert query(database, f"select count(*) from information_schema.tables where table_schema='main_dbt_test__audit' and table_name='{alias}'") == "0"


def unit_error_files() -> dict[str, str]:
    return {
        "models/upstream.sql": "select '1' as id\n",
        "models/orders.sql": "select cast(id as integer) as id from {{ ref('upstream') }}\n",
        "models/zz_good.sql": "select cast(id as integer) as id from {{ ref('upstream') }}\n",
        "models/child.sql": "select * from {{ ref('orders') }}\n",
        "models/schema.yml": (
            "version: 2\nunit_tests:\n  - name: invalid_cast\n    model: orders\n"
            "    given:\n      - input: ref('upstream')\n        rows:\n          - {id: private_bad_integer}\n"
            "    expect:\n      rows:\n        - {id: 1}\n"
            "  - name: valid_cast\n    model: zz_good\n"
            "    given:\n      - input: ref('upstream')\n        rows:\n          - {id: '9'}\n"
            "    expect:\n      rows:\n        - {id: 9}\n"
        ),
    }


@pytest.mark.parametrize("command", ["test", "build"])
def test_unit_sql_errors_continue_and_leave_existing_target_views_intact(tmp_path: Path, command: str):
    project, target = tmp_path / "project", tmp_path / "target"
    write_project(project, unit_error_files())
    target.mkdir()
    database = target / "dxt.duckdb"
    query(database, "create view upstream as select '111' as id; create table orders as select 112 as id;")
    outcome = run_dxt(project, target, command, "--select", "test_type:unit")
    assert outcome.returncode == 1, outcome.stdout + outcome.stderr
    rows = results(target)
    assert len(rows) == 2
    assert_error(rows["unit_test.error_outcomes.orders.invalid_cast"], unit=True)
    assert rows["unit_test.error_outcomes.zz_good.valid_cast"]["status"] == "pass"
    assert query(database, "select id from upstream") == "111"
    assert query(database, "select id from orders") == "112"
    assert query(database, "select count(*) from duckdb_views() where view_name = 'upstream'") == "1"
    assert "private_bad_integer" not in outcome.stdout + outcome.stderr


def test_truncated_duckdb_error_output_is_sanitized_and_durable(tmp_path: Path):
    project, target = tmp_path / "project", tmp_path / "target"
    secret = "private_engine_error"
    sql = "select 1 as id where error(repeat('private_engine_error', 5000))\n"
    assert len(secret.encode()) * 5000 > 65536
    write_project(project, {"tests/m_broken.sql": sql, "tests/zz_independent.sql": "select 1 where false\n"})
    env = {**os.environ, "DXT_DUCKDB_BACKEND": "native", "DBT_ENV_SECRET_LONG_ENGINE_ERROR": secret}
    outcome = run_dxt(project, target, "test", env=env)
    assert outcome.returncode == 1, outcome.stdout + outcome.stderr
    rows = results(target)
    assert len(rows) == 2
    error = rows["test.error_outcomes.m_broken"]
    assert_error(error, target=target, diagnostic=("Invalid Input Error:", "*****"))
    assert 0 < len(error["message"].encode()) <= 65536
    assert rows["test.error_outcomes.zz_independent"]["status"] == "pass"
    public = outcome.stdout + outcome.stderr + (project / "logs/dbt.log").read_text() + error["message"]
    assert secret not in public
    assert "private" not in public  # The cut must not expose an incomplete secret prefix.
    assert all(secret not in (row["message"] or "") for row in rows.values())
    assert error["compiled_code"] == sql.rstrip("\n")  # Authored SQL is not a diagnostic projection.
    manifest = json.loads((target / "manifest.json").read_text())
    assert manifest["nodes"]["test.error_outcomes.m_broken"]["raw_code"] == sql.rstrip("\n")
    assert (project / "tests/m_broken.sql").read_text() == sql
    from validate_dbt_artifacts import assert_artifact
    assert_artifact(target / "manifest.json")
    assert_artifact(target / "run_results.json")


@pytest.mark.parametrize("kind", ["generic", "singular"])
def test_core_1105_build_error_and_skip_outcomes_oracle(tmp_path: Path, kind: str, core_runner):
    project, native_target, core_target = tmp_path / "project", tmp_path / "native", tmp_path / "core"
    write_project(project, build_error_files(kind))
    native_profiles, core_profiles = tmp_path / "native-profiles", tmp_path / "core-profiles"
    write_profile(native_profiles, tmp_path / "native.duckdb")
    write_profile(core_profiles, tmp_path / "core.duckdb")
    native = run_dxt(project, native_target, "build", "--profiles-dir", str(native_profiles))
    assert native.returncode == 1, native.stdout + native.stderr
    core = core_runner.invoke([
        "--quiet", "--no-use-colors", "build", "--project-dir", str(project),
        "--profiles-dir", str(core_profiles), "--target-path", str(core_target),
        "--log-path", str(tmp_path / "core-logs"), "--no-partial-parse",
    ])
    assert not core.success
    assert core.exception is None, core.exception
    native_rows, core_rows = results(native_target), results(core_target)
    validate_core_artifact_schema(native_target)
    validate_core_artifact_schema(core_target)
    native_manifest = json.loads((native_target / "manifest.json").read_text())
    core_manifest = json.loads((core_target / "manifest.json").read_text())
    assert {key: row["status"] for key, row in native_rows.items()} == {key: row["status"] for key, row in core_rows.items()}
    for key, oracle in core_rows.items():
        if oracle["status"] in ("error", "skipped"):
            native_row = native_rows[key]
            for field in ("failures", "compiled", "adapter_response"):
                assert native_row[field] == oracle[field]
            if oracle["status"] == "skipped":
                for field in ("message", "compiled_code"):
                    assert native_row[field] is None
                    assert oracle[field] is None
                # Each runner retains its parsed physical relation identity.
                # Core includes the named DuckDB catalog; dxt uses two parts.
                if key.startswith("model."):
                    assert native_row["relation_name"] == native_manifest["nodes"][key]["relation_name"]
                    assert oracle["relation_name"] == core_manifest["nodes"][key]["relation_name"]
                else:
                    assert native_row["relation_name"] == oracle["relation_name"]
            else:
                diagnostic = ("Binder Error:", 'Referenced column "missing_column" not found in FROM clause!')
                assert_error(native_row, target=native_target, diagnostic=diagnostic)
                node = core_manifest["nodes"][key]
                assert oracle["message"].startswith(f"Runtime Error in test {node['name']} ({node['original_file_path']})")
                for fragment in diagnostic:
                    assert fragment in oracle["message"]


def test_core_1105_unit_sql_error_outcomes_oracle(tmp_path: Path, core_runner):
    project, native_target, core_target = tmp_path / "project", tmp_path / "native", tmp_path / "core"
    write_project(project, unit_error_files())
    native_profiles, core_profiles = tmp_path / "native-profiles", tmp_path / "core-profiles"
    write_profile(native_profiles, tmp_path / "native.duckdb")
    write_profile(core_profiles, tmp_path / "core.duckdb")
    native_setup = run_dxt(project, native_target, "run", "--profiles-dir", str(native_profiles))
    assert native_setup.returncode == 0, native_setup.stdout + native_setup.stderr
    native = run_dxt(project, native_target, "test", "--profiles-dir", str(native_profiles), "--select", "test_type:unit")
    assert native.returncode == 1, native.stdout + native.stderr
    common = [
        "--project-dir", str(project), "--profiles-dir", str(core_profiles),
        "--target-path", str(core_target), "--log-path", str(tmp_path / "core-logs"),
    ]
    setup = core_runner.invoke(["--quiet", "--no-use-colors", "run", *common])
    assert setup.success, setup.exception
    core = core_runner.invoke(["--quiet", "--no-use-colors", "test", *common, "--select", "test_type:unit"])
    assert not core.success
    assert core.exception is None, core.exception
    native_rows, core_rows = results(native_target), results(core_target)
    validate_core_artifact_schema(native_target)
    validate_core_artifact_schema(core_target)
    assert {key: row["status"] for key, row in native_rows.items()} == {key: row["status"] for key, row in core_rows.items()}
    key = "unit_test.error_outcomes.orders.invalid_cast"
    assert_error(native_rows[key], unit=True)
    for field in ("failures", "compiled", "compiled_code", "adapter_response", "relation_name"):
        assert native_rows[key][field] == core_rows[key][field]
    assert query(tmp_path / "native.duckdb", "select id from orders") == "1"

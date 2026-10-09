from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out" / "bin" / "dxt"
DUCKDB = shutil.which("duckdb")
pytestmark = pytest.mark.skipif(DUCKDB is None, reason="DuckDB CLI is required")


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


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


def assert_error(row: dict, *, unit: bool = False) -> None:
    assert row["status"] == "error"
    assert row["failures"] is None
    assert row["message"] == "DuckDB execution failed"
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
    assert_error(errors[0])
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
    assert_error(errors[0])
    child_tests = [row for key, row in rows.items() if key.startswith("test.") and "child" in key]
    assert len(child_tests) == 1
    assert child_tests[0]["status"] == "skipped"
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
        files["tests/m_broken.sql"] = "{{ config(store_failures=true) }}select id from {{ ref('orders') }} where id is null\n"
    project, target = tmp_path / "project", tmp_path / "target"
    write_project(project, files)
    target.mkdir()
    database = target / "dxt.duckdb"
    query(database, f"create table orders as select null::integer as id; create schema dbt_test__audit; create view dbt_test__audit.{alias} as select 99 as id;")
    outcome = run_dxt(project, target, "test")
    assert outcome.returncode == 1, outcome.stdout + outcome.stderr
    rows = results(target)
    assert len(rows) == 2
    assert_error(next(row for row in rows.values() if row["status"] == "error"))
    assert rows["test.error_outcomes.zz_independent"]["status"] == "pass"
    assert query(database, f"select id from dbt_test__audit.{alias}") == "99"


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
    write_project(project, {"tests/m_broken.sql": "select 1 as id\n", "tests/zz_independent.sql": "select 1 where false\n"})
    tools = tmp_path / "tools"
    tools.mkdir()
    stub = tools / "duckdb"
    stub.write_text(
        f"#!{sys.executable}\nimport os, sys\n"
        "if 'select 1 as id' in sys.argv[-1]:\n"
        "    sys.stderr.write('private_engine_error' * 5000)\n    sys.exit(1)\n"
        f"os.execv({DUCKDB!r}, [{DUCKDB!r}, *sys.argv[1:]])\n"
    )
    stub.chmod(0o755)
    env = {**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"]}
    outcome = run_dxt(project, target, "test", env=env)
    assert outcome.returncode == 1, outcome.stdout + outcome.stderr
    rows = results(target)
    assert_error(rows["test.error_outcomes.m_broken"])
    assert rows["test.error_outcomes.zz_independent"]["status"] == "pass"
    assert "private_engine_error" not in (target / "run_results.json").read_text()
    assert "private_engine_error" not in outcome.stdout + outcome.stderr

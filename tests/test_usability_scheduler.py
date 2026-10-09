"""Native CLI and pinned-Core evidence for physical and unit-test scheduling."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out" / "bin" / "dxt"


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    result = subprocess.run(["zig", "build"], cwd=ROOT, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


@pytest.fixture(autouse=True)
def no_telemetry(monkeypatch):
    monkeypatch.setenv("DBT_SEND_ANONYMOUS_USAGE_STATS", "false")


def write_project(project, models, *, properties="", seed=False):
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text("name: scheduler_demo\nversion: '1.0'\nprofile: scheduler_demo\n")
    for name, sql in models.items():
        (project / "models" / f"{name}.sql").write_text(sql)
    if properties:
        (project / "models" / "schema.yml").write_text(properties)
    if seed:
        (project / "seeds").mkdir()
        (project / "seeds" / "z_raw.csv").write_text("id\n17\n")


def invoke(project, command="build", *selection):
    target = project / "target-dxt"
    argv = [str(DXT), command, "--project-dir", str(project), "--target-path", str(target)]
    if selection:
        argv.extend(["--select", *selection])
    result = subprocess.run(argv, cwd=ROOT, text=True, capture_output=True)
    assert (target / "run_results.json").exists(), result.stdout + result.stderr
    rows = json.loads((target / "run_results.json").read_text())["results"]
    return result, rows, target / "dxt.duckdb"


def query(database, sql):
    result = subprocess.run(["duckdb", str(database), "-json", "-batch", "-bail", "-c", sql], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout or "[]")


def status_map(rows):
    return {row["unique_id"]: row["status"] for row in rows}


def chain_models(base="select 17 as id"):
    return {
        "a_final": "{{ config(materialized='table') }} select * from {{ ref('e_one') }}",
        "e_one": "{{ config(materialized='ephemeral') }} select * from {{ ref('e_two') }}",
        "e_two": "{{ config(materialized='ephemeral') }} select * from {{ ref('z_base') }}",
        "z_base": base,
        "independent": "select 99 as id",
    }


@pytest.mark.parametrize("command", ["run", "build"])
def test_orders_physical_ancestors_behind_unselected_ephemerals(tmp_path, command):
    project = tmp_path / "physical"
    write_project(project, chain_models())
    result, rows, database = invoke(project, command, "a_final", "z_base")
    assert result.returncode == 0, result.stderr
    assert [row["unique_id"] for row in rows] == ["model.scheduler_demo.z_base", "model.scheduler_demo.a_final"]
    assert query(database, "select * from a_final") == [{"id": 17}]
    assert query(database, "select table_name from information_schema.tables where table_name like 'e_%'") == []


def test_seed_model_ancestry_order(tmp_path):
    project = tmp_path / "seed_chain"
    write_project(project, chain_models("select * from {{ ref('z_raw') }}"), seed=True)
    result, rows, database = invoke(project)
    assert result.returncode == 0, result.stderr
    ids = [row["unique_id"] for row in rows]
    assert ids.index("seed.scheduler_demo.z_raw") < ids.index("model.scheduler_demo.z_base") < ids.index("model.scheduler_demo.a_final")
    assert query(database, "select * from a_final") == [{"id": 17}]


@pytest.mark.parametrize("command", ["run", "build"])
def test_failure_blocks_ephemeral_descendants_and_keeps_independent_work(tmp_path, command):
    project = tmp_path / "failure_chain"
    write_project(project, chain_models("select * from missing_relation"))
    result, rows, database = invoke(project, command)
    assert result.returncode == 1
    assert status_map(rows) == {
        "model.scheduler_demo.z_base": "error",
        "model.scheduler_demo.a_final": "skipped",
        "model.scheduler_demo.independent": "success",
    }
    assert query(database, "select * from independent") == [{"id": 99}]
    assert query(database, "select table_name from information_schema.tables where table_name = 'a_final'") == []


def test_failing_data_test_blocks_ephemeral_descendants(tmp_path):
    project = tmp_path / "data_failure_chain"
    write_project(project, chain_models("select null::integer as id"), properties="""version: 2
models:
  - name: z_base
    columns:
      - name: id
        data_tests: [not_null]
  - name: a_final
    columns:
      - name: id
        data_tests: [not_null]
""")
    result, rows, database = invoke(project)
    assert result.returncode == 1
    statuses = status_map(rows)
    assert statuses["model.scheduler_demo.a_final"] == "skipped"
    assert statuses["model.scheduler_demo.independent"] == "success"
    assert next(row for row in rows if "not_null_z_base" in row["unique_id"])["status"] == "fail"
    assert next(row for row in rows if "not_null_a_final" in row["unique_id"])["status"] == "skipped"
    assert query(database, "select table_name from information_schema.tables where table_name = 'a_final'") == []


def unit_project(project, expected=17, *, second_unit=False):
    properties = f"""version: 2
models:
  - name: target_model
    columns:
      - name: id
        data_tests: [not_null]
unit_tests:
  - name: preserve_input
    model: target_model
    given:
      - input: ref('z_base')
        rows:
          - {{id: 17}}
    expect:
      rows:
        - {{id: {expected}}}
"""
    if second_unit:
        properties += """  - name: second_unit
    model: target_model
    given:
      - input: ref('z_base')
        rows:
          - {id: 17}
    expect:
      rows:
        - {id: 17}
"""
    models = {
        "z_base": "select id + 83 as id from {{ ref('z_raw') }}",
        "target_model": "{{ config(materialized='table') }} select * from {{ ref('z_base') }}",
        "e_parent": "{{ config(materialized='ephemeral') }} select * from {{ ref('target_model') }}",
        "a_descendant": "select * from {{ ref('e_parent') }}",
        "independent": "select 99 as id",
    }
    write_project(project, models, properties=properties, seed=True)


@pytest.mark.parametrize("expected", [17, 18])
def test_mixed_units_gate_model_and_preserve_real_view_inputs(tmp_path, expected):
    project = tmp_path / "unit_mix"
    unit_project(project, expected)
    # Real target data must survive a failing pre-materialization unit gate.
    database = project / "target-dxt" / "dxt.duckdb"
    database.parent.mkdir()
    query(database, "create table target_model as select 777 as id; select * from target_model")
    result, rows, database = invoke(project)
    assert result.returncode == (0 if expected == 17 else 1), result.stderr
    statuses = status_map(rows)
    unit_id = "unit_test.scheduler_demo.target_model.preserve_input"
    assert statuses[unit_id] == ("pass" if expected == 17 else "fail")
    assert statuses["model.scheduler_demo.independent"] == "success"
    assert statuses["seed.scheduler_demo.z_raw"] == "success"
    assert statuses["model.scheduler_demo.target_model"] == ("success" if expected == 17 else "skipped")
    assert statuses["model.scheduler_demo.a_descendant"] == ("success" if expected == 17 else "skipped")
    assert next(row for row in rows if "not_null_target_model" in row["unique_id"])["status"] == ("pass" if expected == 17 else "skipped")
    ids = [row["unique_id"] for row in rows]
    assert ids.index("model.scheduler_demo.z_base") < ids.index(unit_id) < ids.index("model.scheduler_demo.target_model")
    assert query(database, "select * from z_base") == [{"id": 100}]
    assert query(database, "select table_type from information_schema.tables where table_name = 'z_base'") == [{"table_type": "VIEW"}]
    assert query(database, "select * from target_model") == [{"id": 100 if expected == 17 else 777}]


def test_failing_unit_skips_later_sibling_units_like_core(tmp_path):
    project = tmp_path / "sibling_units"
    unit_project(project, 18, second_unit=True)
    result, rows, _ = invoke(project)
    assert result.returncode == 1
    statuses = status_map(rows)
    assert statuses["unit_test.scheduler_demo.target_model.preserve_input"] == "fail"
    assert statuses["unit_test.scheduler_demo.target_model.second_unit"] == "skipped"
    assert statuses["model.scheduler_demo.target_model"] == "skipped"


def test_selected_unit_without_selected_target_runs_in_mixed_build(tmp_path):
    project = tmp_path / "unit_without_target"
    unit_project(project)
    result, rows, database = invoke(project, "build", "z_raw", "independent", "resource_type:unit_test")
    assert result.returncode == 0, result.stderr
    assert status_map(rows) == {
        "seed.scheduler_demo.z_raw": "success",
        "model.scheduler_demo.independent": "success",
        "unit_test.scheduler_demo.target_model.preserve_input": "pass",
    }
    assert query(database, "select table_name from information_schema.tables where table_name in ('target_model', 'z_base')") == []


def test_unit_failure_blocks_selected_descendants_of_unselected_target(tmp_path):
    project = tmp_path / "unselected_unit_target"
    unit_project(project, 18)
    database = project / "target-dxt" / "dxt.duckdb"
    database.parent.mkdir()
    query(database, "create table target_model as select 777 as id; select * from target_model")
    result, rows, _ = invoke(project, "build", "a_descendant", "independent", "resource_type:unit_test")
    assert result.returncode == 1
    assert status_map(rows) == {
        "unit_test.scheduler_demo.target_model.preserve_input": "fail",
        "model.scheduler_demo.a_descendant": "skipped",
        "model.scheduler_demo.independent": "success",
    }
    assert query(database, "select * from target_model") == [{"id": 777}]
    assert query(database, "select table_name from information_schema.tables where table_name = 'a_descendant'") == []


def test_unit_sql_error_gates_mixed_build_without_losing_independent_results(tmp_path):
    project = tmp_path / "mixed_unit_error"
    unit_project(project)
    (project / "models" / "target_model.sql").write_text("{{ config(materialized='table') }} select cast(id as integer) as id from {{ ref('z_base') }}")
    properties = project / "models" / "schema.yml"
    properties.write_text(properties.read_text().replace("- {id: 17}", "- {id: 'invalid_integer'}", 1))
    result, rows, database = invoke(project)
    assert result.returncode == 1
    statuses = status_map(rows)
    assert statuses["unit_test.scheduler_demo.target_model.preserve_input"] == "error"
    assert statuses["model.scheduler_demo.target_model"] == "skipped"
    assert statuses["model.scheduler_demo.a_descendant"] == "skipped"
    assert statuses["model.scheduler_demo.independent"] == "success"
    assert query(database, "select * from z_base") == [{"id": 100}]


def test_failed_physical_parent_skips_unit_gate_and_descendants(tmp_path):
    project = tmp_path / "mixed_parent_error"
    unit_project(project)
    (project / "models" / "z_base.sql").write_text("select * from missing_relation")
    result, rows, _ = invoke(project)
    assert result.returncode == 1
    statuses = status_map(rows)
    assert statuses["model.scheduler_demo.z_base"] == "error"
    assert statuses["unit_test.scheduler_demo.target_model.preserve_input"] == "skipped"
    assert statuses["model.scheduler_demo.target_model"] == "skipped"
    assert statuses["model.scheduler_demo.a_descendant"] == "skipped"
    assert statuses["model.scheduler_demo.independent"] == "success"


@pytest.mark.parametrize("expected", [17, 18])
def test_mixed_unit_statuses_match_pinned_core(tmp_path, expected):
    dbt = shutil.which("dbt")
    if dbt is None:
        pytest.skip("pinned dbt-core and dbt-duckdb developer oracle required")
    project = tmp_path / "oracle"
    unit_project(project, expected)
    result, rows, _ = invoke(project)
    profiles = tmp_path / "profiles"
    profiles.mkdir()
    dbt_database = tmp_path / "core.duckdb"
    (profiles / "profiles.yml").write_text(f"scheduler_demo:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n      path: '{dbt_database.as_posix()}'\n      schema: main\n      threads: 1\n")
    env = dict(os.environ, DBT_SEND_ANONYMOUS_USAGE_STATS="false")
    oracle = subprocess.run([dbt, "build", "--project-dir", str(project), "--profiles-dir", str(profiles), "--target-path", "target-core"], cwd=ROOT, env=env, text=True, capture_output=True)
    core_rows = json.loads((project / "target-core" / "run_results.json").read_text())["results"]
    assert result.returncode == oracle.returncode, oracle.stdout + oracle.stderr
    assert status_map(rows) == status_map(core_rows)

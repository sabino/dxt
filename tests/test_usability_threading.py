"""Real native concurrent command workloads and durable failure evidence."""
from __future__ import annotations

import ctypes.util
import datetime as dt
import json
import os
import subprocess
from pathlib import Path

import pytest

from cli_helpers import json_lines

from test_usability_scheduler import chain_models, unit_project, write_project

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out" / "bin" / "dxt"


@pytest.fixture(scope="module", autouse=True)
def binary():
    result = subprocess.run(["zig", "build"], cwd=ROOT, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


@pytest.fixture(autouse=True)
def native_backend(monkeypatch):
    library = os.environ.get("DXT_DUCKDB_LIBRARY") or ctypes.util.find_library("duckdb")
    if not library:
        if os.environ.get("DXT_NATIVE_ADAPTER_CERTIFY") == "1":
            pytest.fail("Threading certification requires libduckdb")
        pytest.skip("Native concurrency requires libduckdb")
    monkeypatch.setenv("DXT_DUCKDB_LIBRARY", library)
    monkeypatch.setenv("DXT_DUCKDB_BACKEND", "native")
    monkeypatch.setenv("DBT_SEND_ANONYMOUS_USAGE_STATS", "false")


def invoke(project, command="build", *options):
    target = project / "target-dxt"
    result = subprocess.run([str(DXT), command, "--project-dir", str(project),
                             "--target-path", str(target), *options],
                            cwd=ROOT, capture_output=True, text=True, timeout=30)
    artifact = target / "run_results.json"
    return result, json.loads(artifact.read_text()) if artifact.exists() else None


def statuses(artifact):
    return {row["unique_id"]: row["status"] for row in artifact["results"]}


def execution_interval(row):
    timing = next(t for t in row["timing"] if t["name"] == "execute")
    return [dt.datetime.fromisoformat(timing[k].replace("Z", "+00:00"))
            for k in ["started_at", "completed_at"]]


@pytest.mark.parametrize("command", ["run", "build"])
def test_real_workers_overlap_independent_queries_and_keep_physical_order(tmp_path, command):
    project = tmp_path / "overlap"
    models = chain_models("select 17 as id")
    for name in ["slow_one", "slow_two"]:
        models[name] = "{{ config(materialized='table') }} select sum(sqrt(i * 1.0)) as amount from range(9000000) t(i)"
    write_project(project, models)
    result, artifact = invoke(project, command, "--threads", "3")
    assert result.returncode == 0, result.stderr
    rows = {row["unique_id"].split(".")[-1]: row for row in artifact["results"]}
    one, two = rows["slow_one"], rows["slow_two"]
    assert one["thread_id"] != two["thread_id"]
    a, b = execution_interval(one), execution_interval(two)
    assert max(a[0], b[0]) < min(a[1], b[1]), (a, b)
    base, final = execution_interval(rows["z_base"]), execution_interval(rows["a_final"])
    assert base[1] <= final[0]
    assert all(row["execution_time"] > 0 for row in artifact["results"])
    assert all(any(t["name"] == "compile" for t in row["timing"]) for row in artifact["results"])


@pytest.mark.parametrize("threads", ["1", "4"])
@pytest.mark.parametrize("expected", [17, 18])
def test_mixed_units_gate_target_and_descendants_with_independent_continuation(tmp_path, threads, expected):
    project = tmp_path / "units"
    unit_project(project, expected, second_unit=True)
    result, artifact = invoke(project, "build", "--threads", threads)
    assert result.returncode == (0 if expected == 17 else 1), result.stderr
    status = statuses(artifact)
    assert status["unit_test.scheduler_demo.target_model.preserve_input"] == ("pass" if expected == 17 else "fail")
    assert status["unit_test.scheduler_demo.target_model.second_unit"] == ("pass" if expected == 17 else "skipped")
    for name in ["target_model", "a_descendant"]:
        assert status[f"model.scheduler_demo.{name}"] == ("success" if expected == 17 else "skipped")
    assert status["model.scheduler_demo.independent"] == "success"
    assert status["seed.scheduler_demo.z_raw"] == "success"
    executed = [row for row in artifact["results"] if row["status"] != "skipped"]
    assert all(row["execution_time"] > 0 for row in executed)


@pytest.mark.parametrize("threads", ["1", "4"])
def test_failed_sibling_data_tests_both_run_and_gate_ephemeral_descendants(tmp_path, threads):
    project = tmp_path / "tests"
    write_project(project, chain_models("select null::integer as id"), properties="""version: 2
models:
  - name: z_base
    columns:
      - name: id
        data_tests: [not_null, unique]
""")
    result, artifact = invoke(project, "build", "--threads", threads)
    assert result.returncode == 1, result.stderr
    status = statuses(artifact)
    assert status["model.scheduler_demo.a_final"] == "skipped"
    assert status["model.scheduler_demo.independent"] == "success"
    test_rows = [row for row in artifact["results"] if row["unique_id"].startswith("test.")]
    assert len(test_rows) == 2
    assert {row["status"] for row in test_rows} == {"fail", "pass"}
    result, artifact = invoke(project, "test", "--threads", threads)
    assert result.returncode == 1
    assert {row["status"] for row in artifact["results"]} == {"fail", "pass"}


def test_fail_fast_cancels_live_native_query_and_skips_unstarted_work(tmp_path):
    project = tmp_path / "cancel"
    write_project(project, {
        "a_slow": "{{ config(materialized='table') }} select sum(a.i * b.i * 1.0) as n from range(50000) a(i) cross join range(50000) b(i)",
        "b_error": "select * from missing_native_table",
        "c_pending": "select 1 as id",
        "d_child": "select * from {{ ref('a_slow') }}",
    })
    result, artifact = invoke(project, "run", "--threads", "2", "--fail-fast", "--log-format", "json")
    assert result.returncode == 1, result.stderr
    status = statuses(artifact)
    assert status == {"model.scheduler_demo.a_slow": "error", "model.scheduler_demo.b_error": "error",
                      "model.scheduler_demo.c_pending": "skipped", "model.scheduler_demo.d_child": "skipped"}
    slow = next(row for row in artifact["results"] if row["unique_id"].endswith("a_slow"))
    assert "cancel" in slow["message"].lower()
    assert slow["execution_time"] > 0
    events = [json.loads(line) for line in result.stderr.splitlines() if line.startswith("{")]
    assert len([event for event in events if event["info"]["name"] == "NodeStart"]) == 2
    assert len([event for event in events if event["info"]["name"] == "NodeFinished"]) == 4
    assert {event["info"]["invocation_id"] for event in events} == {artifact["metadata"]["invocation_id"]}
    assert artifact["elapsed_time"] > 0


@pytest.mark.parametrize("threads", ["0", "-1", "1.5", "257", "invalid"])
def test_invalid_threads_fail_before_artifacts(tmp_path, threads):
    project = tmp_path / "invalid"
    write_project(project, {"model": "select 1 as id"})
    result, artifact = invoke(project, "run", "--threads", threads)
    assert result.returncode == 2
    assert "--threads must be an integer" in result.stderr
    assert artifact is None


def test_default_single_worker_dynamic_sql_uses_materialized_upstream(tmp_path):
    project = tmp_path / "dynamic"
    write_project(project, {
        "z_base": "{{ config(materialized='table') }} select 17 as id",
        "a_dynamic": "{% if execute %}{% set data = run_query('select id from main.z_base') %}select {{ data.rows[0][0] }} as id{% else %}select 0 as id{% endif %} -- {{ ref('z_base') }}",
    })
    result, artifact = invoke(project, "run")
    assert result.returncode == 0, result.stderr
    assert statuses(artifact) == {"model.scheduler_demo.z_base": "success", "model.scheduler_demo.a_dynamic": "success"}
    row = next(row for row in artifact["results"] if row["unique_id"].endswith("a_dynamic"))
    assert "select 17 as id" in row["compiled_code"]


def test_fail_fast_cancels_isolated_live_unit_fixture_connection(tmp_path):
    project = tmp_path / "unit_cancel"
    write_project(project, {
        "a_slow": "select sum(a.i * b.i * 1.0) as n from {{ ref('z_input') }} cross join range(50000) a(i) cross join range(50000) b(i)",
        "b_error": "select cast('invalid-integer' as integer) as n from {{ ref('z_input') }}",
        "z_input": "select 1 as id",
    }, properties="""version: 2
unit_tests:
  - name: a_slow_case
    model: a_slow
    given:
      - input: ref('z_input')
        rows:
          - {id: 1}
    expect:
      rows:
        - {n: 0}
  - name: b_error_case
    model: b_error
    given:
      - input: ref('z_input')
        rows:
          - {id: 1}
    expect:
      rows:
        - {n: 0}
""")
    result, artifact = invoke(project, "test", "--threads", "2", "--fail-fast")
    assert result.returncode == 1, result.stderr
    assert {row["status"] for row in artifact["results"]} == {"error"}
    slow = next(row for row in artifact["results"] if ".a_slow." in row["unique_id"])
    assert "cancel" in slow["message"].lower()
    assert slow["execution_time"] > 0
    assert any(t["name"] == "compile" for t in slow["timing"])


def test_profile_threads_and_shared_custom_schema_create_real_workers(tmp_path):
    project = tmp_path / "profile_workers"
    write_project(project, {f"m{i}": "{{ config(materialized='table', schema='custom') }} select 17 as id" for i in range(6)})
    (project / "profiles.yml").write_text("scheduler_demo:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n      schema: main\n      threads: 4\n")
    result, artifact = invoke(project, "run", "--log-format", "json")
    assert result.returncode == 0, result.stderr
    assert len({row["thread_id"] for row in artifact["results"]}) > 1
    assert {row["status"] for row in artifact["results"]} == {"success"}
    events = [json.loads(line) for line in result.stderr.splitlines()]
    assert events[0]["info"]["name"] == "CommandStart"
    assert events[-1]["info"]["name"] == "CommandFinished"


def test_json_logs_preserve_list_stdout_and_failure_diagnostics(tmp_path):
    project = tmp_path / "logged_parse"
    write_project(project, {"model": "select 1 as id"})
    result = subprocess.run([str(DXT), "ls", "--project-dir", str(project),
                             "--output", "json", "--log-format", "json"],
                            cwd=ROOT, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert [row["unique_id"] for row in json_lines(result.stdout)] == ["model.scheduler_demo.model"]
    assert [json.loads(line)["info"]["name"] for line in result.stderr.splitlines()] == ["CommandStart", "CommandFinished"]
    result, artifact = invoke(project, "run", "--threads", "0", "--log-format", "json")
    assert result.returncode == 2
    events = [json.loads(line) for line in result.stderr.splitlines()]
    assert events[-1]["data"]["status"] == "error"
    assert any("--threads" in event["data"].get("message", "") for event in events)
    assert artifact is None

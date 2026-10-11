"""Native dxt workflow evidence, grounded in SQLMesh b44fdf6 documentation.

These exercise actual warehouse transactions and artifacts; SQLMesh is a design
reference, while the dxt-specific commands deliberately have their own schema.
"""
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest

from test_cli import ROOT, DXT, build_dxt  # noqa: F401
from test_usability_adapters import (  # noqa: F401
    duckdb_environment, postgres_fixture, driver, invoke as native_invoke,
)


def project(tmp_path: Path, adapter="duckdb", postgres=None):
    root = tmp_path / f"workflow_{adapter}"
    (root / "models").mkdir(parents=True)
    (root / "dbt_project.yml").write_text("name: workflow\nversion: '1.0'\nconfig-version: 2\nprofile: default\n")
    if adapter == "duckdb":
        outputs = f"      type: duckdb\n      path: {root / 'warehouse.duckdb'}\n      schema: analytics\n"
    else:
        info = postgres.get_postmaster_info()
        outputs = f"      type: postgres\n      schema: analytics\n      host: '{info.socket_dir}'\n      port: {info.port}\n      dbname: postgres\n      user: postgres\n"
    (root / "profiles.yml").write_text("default:\n  target: dev\n  outputs:\n    dev:\n" + outputs)
    (root / "models/a.sql").write_text("select 1 as id\n")
    (root / "models/b.sql").write_text("select * from {{ ref('a') }}\n")
    return root


def invoke(root, environment, command, *args, ok=True):
    result = subprocess.run([str(DXT), command, "--project-dir", str(root), *map(str, args)],
                            cwd=ROOT, env=environment, text=True, capture_output=True, timeout=30)
    if ok:
        assert result.returncode == 0, result.stdout + result.stderr
        return json.loads(result.stdout)
    return result


def query(driver, root, environment, adapter, sql):
    result = native_invoke(driver, adapter, "query", root / "warehouse.duckdb", environment, sql)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def models(plan):
    return {item["model"]["name"]: item for item in plan["models"]}


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_native_plan_apply_isolation_reuse_upstream_promotion_and_rollback(
    tmp_path, request, driver, adapter,
):
    environment = request.getfixturevalue("duckdb_environment") if adapter == "duckdb" else request.getfixturevalue("postgres_fixture")[1]
    server = None if adapter == "duckdb" else request.getfixturevalue("postgres_fixture")[0]
    root = project(tmp_path, adapter, server)
    initial = invoke(root, environment, "plan")
    assert initial["schema_version"] == "dxt/plan/v1"
    assert {item["change"] for item in initial["models"]} == {"added"}
    if adapter == "duckdb":
        assert not (root / "warehouse.duckdb").exists()
    first = invoke(root, environment, "apply")
    assert first["built"] == 2 and first["reused"] == 0
    assert invoke(root, environment, "apply")["status"] == "already_applied"
    assert query(driver, root, environment, adapter, "select * from analytics.b") == [{"id": 1}]
    baseline = invoke(root, environment, "environment")
    assert baseline["schema_version"] == "dxt/environment/v1"
    noop = invoke(root, environment, "plan", "--environment", "preview")
    assert {item["change"] for item in noop["models"]} == {"unchanged"}
    reused = invoke(root, environment, "apply", "--environment", "preview")
    assert reused["built"] == 0 and reused["reused"] == 2
    assert query(driver, root, environment, adapter, "select * from analytics__preview.b") == [{"id": 1}]

    (root / "models/a.sql").write_text("select 2 as id\n")
    changed = invoke(root, environment, "plan", "--environment", "preview")
    assert models(changed)["a"]["change"] == "direct"
    assert models(changed)["b"]["change"] == "indirect"
    assert models(changed)["a"]["model"]["version"] != models(initial)["a"]["model"]["version"]
    assert invoke(root, environment, "apply", "--environment", "preview")["built"] == 2
    assert query(driver, root, environment, adapter, "select * from analytics.b") == [{"id": 1}]
    assert query(driver, root, environment, adapter, "select * from analytics__preview.b") == [{"id": 2}]
    promoted = invoke(root, environment, "promote", "--from-environment", "preview")
    assert promoted["built"] == 0
    assert query(driver, root, environment, adapter, "select * from analytics.b") == [{"id": 2}]
    invoke(root, environment, "rollback")
    assert query(driver, root, environment, adapter, "select * from analytics.b") == [{"id": 1}]
    assert invoke(root, environment, "environment")["plan_id"] == baseline["plan_id"]
    assert not (root / "target/manifest.json").exists()
    assert not (root / "target/run_results.json").exists()


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_blocking_audits_rollback_build_and_prevent_promotion(tmp_path, request, driver, adapter):
    environment = request.getfixturevalue("duckdb_environment") if adapter == "duckdb" else request.getfixturevalue("postgres_fixture")[1]
    server = None if adapter == "duckdb" else request.getfixturevalue("postgres_fixture")[0]
    root = project(tmp_path, adapter, server)
    (root / "models/schema.yml").write_text("version: 2\nmodels:\n  - name: a\n    columns:\n      - name: id\n        data_tests: [not_null]\n")
    invoke(root, environment, "plan")
    assert invoke(root, environment, "apply")["audits"][0]["status"] == "pass"
    baseline = invoke(root, environment, "environment")
    count = query(driver, root, environment, adapter, "select count(*) as n from _dxt.workflow_versions")[0]["n"]
    (root / "models/a.sql").write_text("select cast(null as integer) as id\n")
    invoke(root, environment, "plan")
    failed = invoke(root, environment, "apply", ok=False)
    assert failed.returncode == 1 and "blocking workflow audits" in failed.stderr
    artifact = json.loads((root / "target/dxt/run.json").read_text())
    assert artifact["status"] == "audit_failed" and artifact["audits"][0]["failures"] == 1
    assert invoke(root, environment, "environment")["plan_id"] == baseline["plan_id"]
    assert query(driver, root, environment, adapter, "select count(*) as n from _dxt.workflow_versions")[0]["n"] == count
    assert query(driver, root, environment, adapter, "select * from analytics.a") == [{"id": 1}]
    (root / "models/a.sql").write_text("select 2 as id\n")
    invoke(root, environment, "plan", "--environment", "preview")
    invoke(root, environment, "apply", "--environment", "preview")
    preview = invoke(root, environment, "environment", "--environment", "preview")
    relation = next(model["relation"] for model in preview["models"] if model["name"] == "a")
    query(driver, root, environment, adapter, f"update {relation} set id=null")
    failed = invoke(root, environment, "promote", "--from-environment", "preview", ok=False)
    assert failed.returncode == 1
    assert query(driver, root, environment, adapter, "select * from analytics.a") == [{"id": 1}]


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_half_open_interval_coverage_gaps_backfill_and_late_arrivals(tmp_path, request, driver, adapter):
    environment = request.getfixturevalue("duckdb_environment") if adapter == "duckdb" else request.getfixturevalue("postgres_fixture")[1]
    server = None if adapter == "duckdb" else request.getfixturevalue("postgres_fixture")[0]
    root = project(tmp_path, adapter, server)
    (root / "models/b.sql").unlink()
    (root / ".dxt").mkdir()
    (root / ".dxt/workflow.yml").write_text("models:\n  a:\n    time_column: ts\n    interval_unit: day\n    start: '2026-01-01'\n    lookback: 2\n")
    (root / "models/sources.yml").write_text("version: 2\nsources:\n  - name: raw\n    schema: raw\n    tables:\n      - name: events\n")
    (root / "models/a.sql").write_text("select * from {{ source('raw','events') }} where ts >= cast('{{ var('dxt_start') }}' as timestamp) and ts < cast('{{ var('dxt_end') }}' as timestamp)\n")
    query(driver, root, environment, adapter, "create schema if not exists raw; create table raw.events(id integer, ts timestamp); insert into raw.events values (1,'2026-01-01'), (3,'2026-01-03'), (4,'2026-01-04')")
    planned = invoke(root, environment, "plan", "--end", "2026-01-04")
    assert len(models(planned)["a"]["missing_intervals"]) == 1
    first_version = models(planned)["a"]["model"]["version"]
    invoke(root, environment, "apply")
    assert query(driver, root, environment, adapter, "select id from analytics.a order by id") == [{"id": 1}, {"id": 3}]
    assert len(invoke(root, environment, "intervals")["models"][0]["processed"]) == 1
    query(driver, root, environment, adapter, "insert into raw.events values (33,'2026-01-03 12:00:00'), (7,'2026-01-07')")
    planned = invoke(root, environment, "plan", "--end", "2026-01-05")
    assert models(planned)["a"]["model"]["version"] == first_version
    invoke(root, environment, "apply")
    assert query(driver, root, environment, adapter, "select id from analytics.a order by id") == [{"id": 1}, {"id": 3}, {"id": 4}, {"id": 33}]
    invoke(root, environment, "plan", "--start", "2026-01-06", "--end", "2026-01-08")
    invoke(root, environment, "apply")
    coverage = invoke(root, environment, "intervals")["models"][0]["processed"]
    assert len(coverage) == 2
    gap = invoke(root, environment, "plan", "--end", "2026-01-08")
    assert len(models(gap)["a"]["missing_intervals"]) == 1
    invoke(root, environment, "apply")
    assert len(invoke(root, environment, "intervals")["models"][0]["processed"]) == 1
    replay = invoke(root, environment, "plan", "--start", "2026-01-03", "--end", "2026-01-04", "--restate")
    assert models(replay)["a"]["missing_intervals"]
    invoke(root, environment, "apply")
    assert query(driver, root, environment, adapter, "select count(*) as n from analytics.a where id=33") == [{"n": 1}]
    # Coverage belongs to the shared physical version, so another environment's
    # backfill must be visible through the original environment's inspection.
    invoke(root, environment, "plan", "--environment", "preview", "--end", "2026-01-09")
    invoke(root, environment, "apply", "--environment", "preview")
    assert invoke(root, environment, "intervals")["models"][0]["processed"] == invoke(root, environment, "intervals", "--environment", "preview")["models"][0]["processed"]


def test_stale_changed_tampered_and_cross_gateway_plans_fail_before_mutation(tmp_path, duckdb_environment, driver):
    root = project(tmp_path)
    first_path, second_path = tmp_path / "first.json", tmp_path / "second.json"
    first = invoke(root, duckdb_environment, "plan", "--plan", first_path)
    (root / "models/a.sql").write_text("select 2 as id\n")
    changed = invoke(root, duckdb_environment, "apply", "--plan", first_path, ok=False)
    assert changed.returncode == 2 and "project changed" in changed.stderr
    assert not (root / "warehouse.duckdb").exists()
    invoke(root, duckdb_environment, "plan", "--plan", second_path)
    invoke(root, duckdb_environment, "apply", "--plan", second_path)
    stale = invoke(root, duckdb_environment, "apply", "--plan", first_path, ok=False)
    assert stale.returncode == 2 and "environment changed" in stale.stderr
    first["models"][0]["model"]["sql"] = "select 999 as id"
    first_path.write_text(json.dumps(first))
    tampered = invoke(root, duckdb_environment, "apply", "--plan", first_path, ok=False)
    assert tampered.returncode == 2 and "fingerprint" in tampered.stderr
    profile = (root / "profiles.yml").read_text()
    (root / "profiles.yml").write_text(profile.replace("warehouse.duckdb", "other.duckdb"))
    other = invoke(root, duckdb_environment, "apply", "--plan", second_path, ok=False)
    assert other.returncode == 2 and "WorkflowGatewayMismatch" in other.stderr
    assert not (root / "other.duckdb").exists()


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_native_workflow_seed_ephemeral_warning_audit_and_removed_views(tmp_path, request, driver, adapter):
    environment = request.getfixturevalue("duckdb_environment") if adapter == "duckdb" else request.getfixturevalue("postgres_fixture")[1]
    server = None if adapter == "duckdb" else request.getfixturevalue("postgres_fixture")[0]
    root = project(tmp_path, adapter, server)
    (root / "seeds").mkdir()
    (root / "seeds/raw.csv").write_text("id,name\n1,Alpha\n2,Beta\n")
    (root / "models/a.sql").write_text("{{ config(materialized='ephemeral') }} select * from {{ ref('raw') }}\n")
    (root / "models/b.sql").write_text("select * from {{ ref('a') }}\n")
    (root / "tests").mkdir()
    (root / "tests/warning.sql").write_text("{{ config(severity='warn') }} select * from {{ ref('b') }} where id=1\n")
    invoke(root, environment, "plan")
    applied = invoke(root, environment, "apply")
    assert applied["built"] == 2 and applied["audits"][0]["status"] == "warn"
    assert query(driver, root, environment, adapter, "select * from analytics.b order by id") == [{"id": 1, "name": "Alpha"}, {"id": 2, "name": "Beta"}]
    assert invoke(root, environment, "audit")["status"] == "success"
    (root / "tests/warning.sql").unlink()
    (root / "models/b.sql").unlink()
    changed = invoke(root, environment, "plan")
    assert changed["removed"] == ["model.workflow.b"]
    invoke(root, environment, "apply")
    assert query(driver, root, environment, adapter, "select count(*) as n from information_schema.views where table_schema='analytics' and table_name='b'") == [{"n": 0}]
    invoke(root, environment, "rollback")
    assert query(driver, root, environment, adapter, "select count(*) as n from analytics.b") == [{"n": 2}]


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_failed_sql_retains_environment_and_records_sanitized_run(tmp_path, request, driver, adapter):
    environment = request.getfixturevalue("duckdb_environment") if adapter == "duckdb" else request.getfixturevalue("postgres_fixture")[1]
    server = None if adapter == "duckdb" else request.getfixturevalue("postgres_fixture")[0]
    root = project(tmp_path, adapter, server)
    invoke(root, environment, "plan")
    invoke(root, environment, "apply")
    before = invoke(root, environment, "environment")
    (root / "models/a.sql").write_text("select missing_column from nonexistent_table\n")
    invoke(root, environment, "plan")
    failed = invoke(root, environment, "apply", ok=False)
    assert failed.returncode == 1 and "native workflow execution failed" in failed.stderr
    artifact = json.loads((root / "target/dxt/run.json").read_text())
    assert artifact["status"] == "execution_failed"
    assert artifact["failed_model"] == "model.workflow.a"
    assert artifact["error_code"] in {"DuckDbExecutionFailed", "PostgresExecutionFailed"}
    assert "nonexistent_table" not in (root / "target/dxt/run.json").read_text()
    assert invoke(root, environment, "environment")["plan_id"] == before["plan_id"]
    assert query(driver, root, environment, adapter, "select * from analytics.a") == [{"id": 1}]


def test_concurrent_postgres_apply_serializes_environment_revision(tmp_path, postgres_fixture, driver):
    server, environment = postgres_fixture
    root = project(tmp_path, "postgres", server)
    invoke(root, environment, "plan")
    invoke(root, environment, "apply")
    (root / "models/a.sql").write_text("select 2 as id from pg_sleep(0.5)\n")
    invoke(root, environment, "plan")
    argv = [str(DXT), "apply", "--project-dir", str(root)]
    processes = [subprocess.Popen(argv, cwd=ROOT, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(2)]
    outcomes = [(process, process.communicate(timeout=30)) for process in processes]
    assert any(process.returncode == 0 for process, _ in outcomes)
    for process, (stdout, stderr) in outcomes:
        if process.returncode == 0:
            assert json.loads(stdout)["status"] in {"success", "already_applied"}
        else:
            assert process.returncode == 2 and "environment changed" in stderr
    assert query(driver, root, environment, "postgres", "select * from analytics.b") == [{"id": 2}]


def test_concurrent_environment_backfills_preserve_shared_interval_coverage(tmp_path, postgres_fixture, driver):
    server, environment = postgres_fixture
    root = project(tmp_path, "postgres", server)
    (root / "models/b.sql").unlink()
    (root / ".dxt").mkdir()
    (root / ".dxt/workflow.yml").write_text("models:\n  a:\n    time_column: ts\n    interval_unit: day\n    start: '2026-01-01'\n")
    (root / "models/sources.yml").write_text("version: 2\nsources:\n  - name: raw\n    schema: raw\n    tables:\n      - name: events\n")
    (root / "models/a.sql").write_text("select id, ts from {{ source('raw','events') }}, pg_sleep(0.2) where ts >= cast('{{ var('dxt_start') }}' as timestamp) and ts < cast('{{ var('dxt_end') }}' as timestamp)\n")
    query(driver, root, environment, "postgres", "create schema if not exists raw; drop table if exists raw.events; create table raw.events(id integer, ts timestamp); insert into raw.events values (1,'2026-01-01'), (3,'2026-01-03'), (5,'2026-01-05')")
    invoke(root, environment, "plan", "--end", "2026-01-02")
    invoke(root, environment, "apply")
    plans = []
    for name, start, end in [("left", "2026-01-03", "2026-01-04"), ("right", "2026-01-05", "2026-01-06")]:
        path = tmp_path / f"{name}.json"
        invoke(root, environment, "plan", "--environment", name, "--start", start, "--end", end, "--plan", path)
        plans.append((name, path))
    processes = [subprocess.Popen([str(DXT), "apply", "--project-dir", str(root), "--environment", name, "--plan", str(path)],
                                  cwd=ROOT, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                 for name, path in plans]
    for process in processes:
        stdout, stderr = process.communicate(timeout=30)
        assert process.returncode == 0, stdout + stderr
    assert query(driver, root, environment, "postgres", "select id from analytics.a order by id") == [{"id": 1}, {"id": 3}, {"id": 5}]
    intervals = invoke(root, environment, "intervals")["models"][0]["processed"]
    assert len(intervals) == 3
    assert intervals == invoke(root, environment, "intervals", "--environment", "left")["models"][0]["processed"]
    assert intervals == invoke(root, environment, "intervals", "--environment", "right")["models"][0]["processed"]


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_audit_limits_definition_changes_and_query_error_artifacts(tmp_path, request, driver, adapter):
    environment = request.getfixturevalue("duckdb_environment") if adapter == "duckdb" else request.getfixturevalue("postgres_fixture")[1]
    server = None if adapter == "duckdb" else request.getfixturevalue("postgres_fixture")[0]
    root = project(tmp_path, adapter, server)
    (root / "tests").mkdir()
    warning = root / "tests/warning.sql"
    warning.write_text("{{ config(limit=1, error_if='> 1', warn_if='> 0') }} select 1 as id union all select 2 union all select 3\n")
    invoke(root, environment, "plan")
    applied = invoke(root, environment, "apply")
    assert applied["audits"][0]["failures"] == 1
    assert applied["audits"][0]["status"] == "warn"
    baseline = invoke(root, environment, "environment")
    invoke(root, environment, "plan")
    warning.write_text("select 1 as id\n")
    changed = invoke(root, environment, "apply", ok=False)
    assert changed.returncode == 2 and "project changed" in changed.stderr
    warning.write_text("{{ config(limit=1, error_if='> 1', warn_if='> 0') }} select 1 as id union all select 2 union all select 3\n")
    (root / "tests/zz_error.sql").write_text("select missing_column from nonexistent_audit_table\n")
    invoke(root, environment, "plan")
    failed = invoke(root, environment, "apply", ok=False)
    assert failed.returncode == 1
    artifact = json.loads((root / "target/dxt/run.json").read_text())
    assert artifact["status"] == "execution_failed"
    assert artifact["failed_model"] is None
    assert artifact["failed_audit"] == "test.workflow.zz_error"
    assert [row["status"] for row in artifact["audits"]] == ["warn", "error"]
    assert artifact["audits"][1]["failures"] is None
    assert artifact["audits"][1]["error_code"] in {"DuckDbExecutionFailed", "PostgresExecutionFailed"}
    assert "nonexistent_audit_table" not in (root / "target/dxt/run.json").read_text()
    assert invoke(root, environment, "environment")["plan_id"] == baseline["plan_id"]


def test_portable_csv_seed_types_values_and_quoting_match_pinned_core(tmp_path, duckdb_environment, driver):
    root = project(tmp_path)
    (root / "models/a.sql").unlink()
    (root / "models/b.sql").unlink()
    (root / "seeds").mkdir()
    (root / "seeds/raw.csv").write_text('id,amount,day,active,code,Camel,notes\n001,"$1,234.50",2024-02-29,true,001,Alpha,"comma, newline\nO\'Brien"\n2,2.00,2024-03-01,false,002,Beta,null\n')
    with (root / "dbt_project.yml").open("a") as handle:
        handle.write("seeds:\n  workflow:\n    raw:\n      +fast: false\n      +column_types: {code: 'varchar(8)'}\n")
    profile = (root / "profiles.yml").read_text()
    (root / "profiles.yml").write_text(profile + f"    core:\n      type: duckdb\n      path: {root / 'warehouse.duckdb'}\n      schema: oracle\n")
    invoke(root, duckdb_environment, "plan")
    invoke(root, duckdb_environment, "apply")
    result = subprocess.run(["dbt", "--quiet", "seed", "--project-dir", str(root), "--profiles-dir", str(root), "--target", "core", "--target-path", str(tmp_path / "core-target")],
                            cwd=root, env=dict(os.environ, DBT_SEND_ANONYMOUS_USAGE_STATS="false"), text=True, capture_output=True, timeout=60)
    assert result.returncode == 0, result.stdout + result.stderr
    actual = query(driver, root, duckdb_environment, "duckdb", "select * from analytics.raw order by id")
    expected = query(driver, root, duckdb_environment, "duckdb", "select * from oracle.raw order by id")
    assert actual == expected
    assert actual[0]["code"] == "001" and actual[0]["id"] == 1
    artifact = invoke(root, duckdb_environment, "environment")
    physical = artifact["models"][0]["relation"]
    actual_types = query(driver, root, duckdb_environment, "duckdb", f"describe {physical}")
    expected_types = query(driver, root, duckdb_environment, "duckdb", "describe oracle.raw")
    assert [(row["column_name"], row["column_type"]) for row in actual_types] == [(row["column_name"], row["column_type"]) for row in expected_types]

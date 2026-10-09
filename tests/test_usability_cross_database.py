"""Real native cross-database execution; Python owns developer fixtures only."""
from __future__ import annotations

import ctypes.util
import importlib.util
import json
import os
import subprocess
import time
from decimal import Decimal
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out" / "bin" / "dxt"
CERTIFY = os.environ.get("DXT_NATIVE_ADAPTER_CERTIFY") == "1"


@pytest.fixture(scope="module")
def native_environment():
    library = os.environ.get("DXT_DUCKDB_LIBRARY") or ctypes.util.find_library("duckdb")
    missing = [name for name in ("pgserver", "psycopg2", "duckdb")
               if importlib.util.find_spec(name) is None]
    if not library or missing:
        if CERTIFY:
            pytest.fail("Native cross-database certification requires DuckDB and PostgreSQL fixtures")
        pytest.skip("Native cross-database fixture requires libduckdb, duckdb, psycopg2 and pgserver")
    built = subprocess.run(["zig", "build"], cwd=ROOT, capture_output=True, text=True)
    assert built.returncode == 0, built.stderr
    return dict(os.environ, DXT_DUCKDB_LIBRARY=library, DXT_DUCKDB_BACKEND="native")


@pytest.fixture(scope="module")
def postgres(tmp_path_factory, native_environment):
    import pgserver
    import psycopg2
    with pgserver.get_server(tmp_path_factory.mktemp("cross-postgres") / "data") as server:
        connection = psycopg2.connect(server.get_uri())
        connection.autocommit = True
        yield connection
        connection.close()


@pytest.fixture
def project(tmp_path, postgres):
    import duckdb
    schema = "f_" + tmp_path.name.replace("-", "_")[-40:]
    with postgres.cursor() as cursor:
        cursor.execute(f'create schema "{schema}"')
        cursor.execute(f'''create table "{schema}".customers (
            id bigint, name text, amount decimal(20,4), enabled boolean,
            missing text, day date, payload bytea, uid uuid, document jsonb)''')
        cursor.execute(f'''insert into "{schema}".customers values
            (1,'O''Brien',1234567890123456.7890,true,null,'2024-02-29',
             decode('00ff275c','hex'),'12345678-1234-5678-1234-567812345678','{{"a":1}}'),
            (2,'second',2.0001,false,'present','2024-03-01',decode('4142','hex'),
             '22345678-1234-5678-1234-567812345678','{{"a":2}}')''')
    warehouse = tmp_path / "warehouse.duckdb"
    source = tmp_path / "source.duckdb"
    with duckdb.connect(str(warehouse)) as connection:
        connection.execute("create table orders as select * from (values (1,7),(2,9),(1,3)) t(customer_id, quantity)")
    with duckdb.connect(str(source)) as connection:
        connection.execute("create table typed as select 9223372036854775807::bigint id, "
                           "1234567890123456.7890::decimal(20,4) amount, true enabled, "
                           "null::text missing, date '2024-02-29' as day, from_hex('00ff275c') payload, "
                           "'12345678-1234-5678-1234-567812345678'::uuid uid")
    parameters = postgres.get_dsn_parameters()
    pg = {"type": "postgres", "schema": schema,
          **{key: parameters[key] for key in ("host", "port", "dbname", "user")}}
    profiles = {"cross": {"target": "warehouse", "outputs": {
        "warehouse": {"type": "duckdb", "path": str(warehouse), "schema": "marts"},
        "source": {"type": "duckdb", "path": str(source), "schema": "main"},
        "local": {"type": "duckdb", "path": ":memory:", "schema": "main"},
        "crm": pg,
    }}}
    (tmp_path / "profiles.yml").write_text(json.dumps(profiles))
    (tmp_path / "dbt_project.yml").write_text("name: cross\nversion: '1.0'\nprofile: cross\n")
    config = {"connections": {name: {"profile": "cross", "target": name}
                              for name in ("warehouse", "source", "local", "crm")},
              "models": {"joined": {"destination": "warehouse", "inputs": {
                  "customers": {"connection": "crm", "source": ["crm", "customers"],
                                "logical_id": "source.cross.crm.customers",
                                "relation": f"{schema}.customers", "columns": ["id", "name"],
                                "filter": "enabled", "estimated_rows": 1, "estimated_bytes": 16},
                  "orders": {"connection": "warehouse", "relation": "main.orders"}},
                  "sql": "select c.id, c.name, sum(o.quantity)::bigint quantity from "
                         "{{ source('crm','customers') }} c join {{ input('orders') }} o "
                         "on c.id=o.customer_id group by c.id,c.name"}}}
    yield tmp_path, config, schema, warehouse, source
    with postgres.cursor() as cursor:
        cursor.execute(f'drop schema "{schema}" cascade')


def invoke(project, config, environment, mode="run", *extra):
    root = project[0]
    (root / "dxt_connections.yml").write_text(json.dumps(config))
    return subprocess.run([str(DXT), "cross-database", mode, "--project-dir", str(root),
                           "--profiles-dir", str(root), *extra], cwd=ROOT, env=environment,
                          capture_output=True, text=True, timeout=25)


def state(project):
    files = sorted((project[0] / ".dxt" / "cross-runs").glob("*/state.json"),
                   key=lambda path: path.stat().st_mtime_ns)
    return files[-1], json.loads(files[-1].read_text())


@pytest.fixture(scope="module")
def query_driver(tmp_path_factory, native_environment):
    output = tmp_path_factory.mktemp("cross-driver") / "driver"
    command = ["zig", "build-exe", "-lc", "--dep", "cross",
               "-Mroot=tests/native_cross_database_driver.zig", "-Ivendor/libyaml/include",
               "-cflags", "-std=gnu99", '-DYAML_VERSION_STRING="0.2.5"',
               "-DYAML_VERSION_MAJOR=0", "-DYAML_VERSION_MINOR=2", "-DYAML_VERSION_PATCH=5", "--",
               *[f"vendor/libyaml/src/{name}.c" for name in ("api", "reader", "scanner", "parser")],
               "-Mcross=src/project/cross_database.zig", f"-femit-bin={output}"]
    built = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    assert built.returncode == 0, built.stderr
    return output


def invoke_query(driver, project, request, environment, mode="query"):
    (project[0] / "dxt_connections.yml").write_text(json.dumps(project[1]))
    path = project[0] / "query_request.json"
    path.write_text(json.dumps(request))
    return subprocess.run([str(driver), mode, str(project[0]), str(path)], cwd=ROOT,
                          env=environment, capture_output=True, text=True, timeout=25)


def duck_rows(path, query):
    import duckdb
    with duckdb.connect(str(path)) as connection:
        return connection.execute(query).fetchall()


def test_source_reduction_broadcast_and_secret_free_plan(project, native_environment):
    result = invoke(project, project[1], native_environment, "plan", "--allow-movement")
    assert result.returncode == 0, result.stderr
    plan_text = (project[0] / "target" / "dxt_plan.json").read_text()
    plan = json.loads(plan_text)
    model = plan["models"][0]
    assert model["strategy"] == "dimension_broadcast"
    assert model["permitted"] is True
    assert model["inputs"][0]["logical_id"] == "source.cross.crm.customers"
    assert 'where enabled' in model["inputs"][0]["query"]
    assert str(project[0]) not in plan_text
    assert 'connection_info' not in plan_text and 'password' not in plan_text
    result = invoke(project, project[1], native_environment, "run", "--allow-movement", "--plan-hash", plan["plan_hash"])
    assert result.returncode == 0, result.stderr
    assert "leaked" not in result.stderr
    assert duck_rows(project[3], "select * from marts.joined") == [(1, "O'Brien", 10)]
    _, artifact = state(project)
    assert artifact["models"][0]["rows_moved"] == 1
    assert artifact["models"][0]["cleanup"] == "complete"
    assert duck_rows(project[3], "select table_name from information_schema.tables where table_name like '__dxt_%'") == []


@pytest.mark.parametrize("direction", ["postgres_to_duckdb", "duckdb_to_postgres"])
def test_exact_native_movement_types(project, native_environment, postgres, direction):
    config, schema = project[1], project[2]
    if direction == "postgres_to_duckdb":
        input_config = {"connection": "crm", "relation": f"{schema}.customers",
                        "columns": ["id", "amount", "enabled", "missing", "day", "payload", "uid", "document"], "filter": "id=1"}
        destination = "warehouse"
    else:
        input_config = {"connection": "source", "relation": "main.typed", "columns": ["id", "amount", "enabled", "missing", "day", "payload", "uid"]}
        destination = "crm"
    config["models"] = {"typed": {"destination": destination, "inputs": {"typed": input_config},
                                  "sql": "select * from {{ input('typed') }}"}}
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode == 0, result.stderr
    assert "leaked" not in result.stderr
    if destination == "warehouse":
        row = duck_rows(project[3], "select id,amount,enabled,missing,day::text,hex(payload),uid::text from marts.typed")[0]
    else:
        with postgres.cursor() as cursor:
            cursor.execute(f'select id,amount,enabled,missing,day::text,upper(encode(payload,\'hex\')),uid::text from "{schema}".typed')
            row = cursor.fetchone()
    assert row == ((1 if destination == "warehouse" else 9223372036854775807),
                   Decimal("1234567890123456.7890"), True, None, "2024-02-29",
                   "00FF275C", "12345678-1234-5678-1234-567812345678")


def test_same_engine_pushdown_and_embedded_output_movement(project, native_environment, postgres):
    config = project[1]
    config["models"] = {"pushed": {"destination": "warehouse", "inputs": {"orders": {
        "connection": "warehouse", "relation": "main.orders", "projection": {"customer_id": "customer_id", "quantity": "sum(quantity)"}, "group_by": ["customer_id"]}},
        "sql": "select * from {{ input('orders') }}"}}
    result = invoke(project, config, native_environment)
    assert result.returncode == 0, result.stderr
    assert state(project)[1]["models"][0]["rows_moved"] == 0
    assert sorted(duck_rows(project[3], "select * from marts.pushed")) == [(1, 10), (2, 9)]
    config["models"]["pushed"].update(destination="crm", execution_connection="local")
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode == 0, result.stderr
    assert json.loads((project[0] / "target" / "dxt_plan.json").read_text())["models"][0]["strategy"] == "bounded_embedded_join"
    with postgres.cursor() as cursor:
        cursor.execute(f'select * from "{project[2]}".pushed order by customer_id')
        assert cursor.fetchall() == [(1, 10), (2, 9)]
    assert state(project)[1]["models"][0]["rows_moved"] == 4


@pytest.mark.parametrize("deny", ["movement", "rows", "bytes", "objects", "cost", "trust", "raw"])
def test_planning_denies_before_source_or_destination_execution(project, native_environment, deny):
    config = project[1]
    model = config["models"]["joined"]
    model["budget"] = {"max_rows": 100, "max_bytes": 1000, "max_objects": 8}
    flags = ["--allow-movement"]
    if deny == "movement": flags = []
    elif deny == "rows": model["budget"]["max_rows"] = 0
    elif deny == "bytes": model["budget"]["max_bytes"] = 0
    elif deny == "objects": model["budget"]["max_objects"] = 2
    elif deny == "cost":
        config["connections"]["crm"]["egress_per_gib"] = 1
        model["budget"]["max_cost"] = 0
    elif deny == "trust":
        model["inputs"]["customers"]["sensitivity"] = "restricted"
        config["connections"]["crm"]["trust_domain"] = "foreign"
        flags.append("--allow-sensitive")
    elif deny == "raw":
        del model["inputs"]["customers"]["columns"]
        del model["inputs"]["customers"]["filter"]
    # An unreachable source must never be contacted for a denied plan.
    profiles = json.loads((project[0] / "profiles.yml").read_text())
    profiles["cross"]["outputs"]["crm"]["host"] = "invalid.invalid"
    (project[0] / "profiles.yml").write_text(json.dumps(profiles))
    result = invoke(project, config, native_environment, "run", *flags)
    assert result.returncode != 0
    assert "denied before source execution" in result.stderr
    assert not (project[0] / ".dxt").exists()
    assert duck_rows(project[3], "select table_name from information_schema.tables where table_schema='marts'") == []


@pytest.mark.parametrize("budget", ["max_rows", "max_bytes", "max_cost"])
def test_observed_budget_rolls_back_existing_output_and_cleans_stages(project, native_environment, budget):
    config = project[1]
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode == 0, result.stderr
    model = config["models"]["joined"]
    for field in ("estimated_rows", "estimated_bytes"):
        model["inputs"]["customers"].pop(field)
    model["budget"] = {budget: 0}
    config["catalog"] = {"max_age_seconds": 0}
    if budget == "max_cost": config["connections"]["crm"]["egress_per_gib"] = 1
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode != 0, result.stdout
    assert "BudgetExceeded" in result.stderr
    assert "leaked" not in result.stderr
    assert duck_rows(project[3], "select * from marts.joined") == [(1, "O'Brien", 10)]
    path, artifact = state(project)
    assert artifact["models"][0]["status"] == "error"
    assert artifact["models"][0]["cleanup"] == "complete"
    assert not (path.parent / "spill").exists()


def test_commit_recovery_and_repeat_execution_are_idempotent(project, native_environment):
    config = project[1]
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode == 0, result.stderr
    path, artifact = state(project)
    artifact["models"][0]["status"] = "running"
    path.write_text(json.dumps(artifact))
    (path.parent / "spill").mkdir()
    (path.parent / "spill" / "orphan.bin").write_bytes(b"fixture")
    result = invoke(project, config, native_environment, "recover", "--allow-movement", "--run-id", artifact["run_id"])
    assert result.returncode == 0, result.stderr
    assert json.loads(path.read_text())["models"][0]["status"] == "success"
    assert json.loads(path.read_text())["models"][0]["rows_moved"] == 1
    assert not (path.parent / "spill").exists()
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode == 0, result.stderr
    assert duck_rows(project[3], "select * from marts.joined") == [(1, "O'Brien", 10)]


def test_shared_semantic_query_facade_binds_identity_and_returns_owned_rows(project, native_environment, query_driver):
    schema = project[2]
    request = {"options": {"connection": "warehouse", "policy": {"profiles_dir": str(project[0]), "allow_movement": True}},
               "sql": 'select c.id,sum(o.quantity)::bigint quantity from "logical"."customers" c '
                      'join "logical"."orders" o on c.id=o.customer_id group by c.id order by c.id;',
               "bindings": [{"logical_id": "semantic_model.cross.customers", "relation_name": '"logical"."customers"',
                             "source_relation": f"{schema}.customers", "connection": "crm",
                             "source_query": f'select id from "{schema}".customers where enabled'},
                            {"logical_id": "semantic_model.cross.orders", "relation_name": '"logical"."orders"',
                             "source_relation": "main.orders"}]}
    result = invoke_query(query_driver, project, request, native_environment)
    assert result.returncode == 0, result.stderr
    assert "leaked" not in result.stderr
    artifact = json.loads(result.stdout)
    assert artifact["result"] == [{"id": 1, "quantity": 10}]
    assert artifact["movement_plan"]["models"][0]["inputs"][0]["logical_id"] == "semantic_model.cross.customers"
    assert duck_rows(project[3], "select table_name from information_schema.tables where table_schema in ('marts','dxt_internal')") == []
    assert list((project[0] / ".dxt" / "cross-runs").glob("*/spill")) == []
    request["bindings"][0]["connection"] = "missing"
    result = invoke_query(query_driver, project, request, native_environment)
    assert result.returncode != 0
    assert "MissingCrossDatabaseConnection" in result.stderr


@pytest.mark.parametrize("direction", ["duckdb", "postgres"])
def test_oversized_native_payload_is_rejected_before_owned_copy(project, native_environment, direction):
    config = project[1]
    config["models"] = {"huge": {"destination": "crm" if direction == "duckdb" else "warehouse",
        "inputs": {"payload": {"connection": "source" if direction == "duckdb" else "crm",
                               "query": "select repeat('x', 1000000) as value"}},
        "sql": "select * from {{ input('payload') }}", "budget": {"max_memory_bytes": 33554432 if direction == "duckdb" else 1048576}}}
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode != 0
    assert "CrossDatabaseMemoryBudgetExceeded" in result.stderr
    assert "leaked" not in result.stderr
    path, artifact = state(project)
    assert artifact["models"][0]["bytes_moved"] == 1000000
    assert not (path.parent / "spill").exists()


def test_source_timeout_cancels_native_query_and_preserves_output(project, native_environment):
    config = project[1]
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode == 0, result.stderr
    model = config["models"]["joined"]
    model["inputs"] = {"payload": {"connection": "crm", "query": "select 1 as id from pg_sleep(10)"}}
    model["sql"] = "select * from {{ input('payload') }}"
    model["budget"] = {"max_query_seconds": 1}
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode != 0
    assert "leaked" not in result.stderr
    assert duck_rows(project[3], "select * from marts.joined") == [(1, "O'Brien", 10)]
    assert state(project)[1]["models"][0]["status"] == "error"


def test_profile_binding_change_invalidates_reviewed_plan(project, native_environment):
    result = invoke(project, project[1], native_environment, "plan", "--allow-movement")
    assert result.returncode == 0, result.stderr
    artifact = json.loads((project[0] / "target" / "dxt_plan.json").read_text())
    profiles = json.loads((project[0] / "profiles.yml").read_text())
    profiles["cross"]["outputs"]["warehouse"]["path"] = str(project[0] / "different.duckdb")
    (project[0] / "profiles.yml").write_text(json.dumps(profiles))
    result = invoke(project, project[1], native_environment, "run", "--allow-movement", "--plan-hash", artifact["plan_hash"])
    assert result.returncode != 0
    assert "CrossDatabasePlanChanged" in result.stderr
    assert not (project[0] / "different.duckdb").exists()


def test_source_partial_numeric_aggregation_and_multiple_stages(project, native_environment):
    config, schema = project[1], project[2]
    config["models"] = {"aggregate": {"destination": "warehouse", "inputs": {
        "amount": {"connection": "crm", "relation": f"{schema}.customers",
                   "projection": {"id": "id", "amount": "sum(amount)"}, "group_by": ["id"]},
        "flag": {"connection": "source", "relation": "main.typed", "columns": ["enabled"]}},
        "sql": "select a.id,a.amount,f.enabled from {{ input('amount') }} a cross join {{ input('flag') }} f order by a.id"}}
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode == 0, result.stderr
    assert "leaked" not in result.stderr
    plan = json.loads((project[0] / "target" / "dxt_plan.json").read_text())
    assert plan["models"][0]["strategy"] == "destination_staged_join"
    assert 'sum(amount)' in plan["models"][0]["inputs"][0]["query"]
    assert duck_rows(project[3], "select * from marts.aggregate order by id") == [
        (1, Decimal("1234567890123456.7890"), True), (2, Decimal("2.0001"), True)]
    assert state(project)[1]["models"][0]["rows_moved"] == 3


def test_unsupported_decimal_precision_fails_without_rounding_or_committing(project, native_environment, postgres):
    with postgres.cursor() as cursor:
        cursor.execute(f'alter table "{project[2]}".customers add column wide numeric')
        cursor.execute(f'update "{project[2]}".customers set wide=123456789012345678901234567890123456789')
    config = project[1]
    config["models"] = {"wide": {"destination": "warehouse", "inputs": {"data": {
        "connection": "crm", "relation": f"{project[2]}.customers", "columns": ["wide"]}},
        "sql": "select * from {{ input('data') }}"}}
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode != 0
    assert "CrossDatabaseDecimalPrecisionExceeded" in result.stderr
    assert "leaked" not in result.stderr
    assert duck_rows(project[3], "select table_name from information_schema.tables where table_name='wide'") == []


def test_source_readonly_transaction_rejects_side_effects_and_continues_independent_models(project, native_environment, postgres):
    with postgres.cursor() as cursor:
        cursor.execute(f'create sequence "{project[2]}".guard_sequence')
    config = project[1]
    config["models"] = {"denied": {"destination": "warehouse", "inputs": {"data": {
        "connection": "crm", "query": f"select nextval('{project[2]}.guard_sequence') as id"}},
        "sql": "select * from {{ input('data') }}"},
        "independent": {"destination": "warehouse", "inputs": {"data": {
            "connection": "warehouse", "relation": "main.orders"}}, "sql": "select count(*)::bigint n from {{ input('data') }}"}}
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode != 0
    assert "leaked" not in result.stderr
    artifact = state(project)[1]
    assert [item["status"] for item in artifact["models"]] == ["error", "success"]
    assert duck_rows(project[3], "select * from marts.independent") == [(3,)]
    with postgres.cursor() as cursor:
        cursor.execute(f'select is_called from "{project[2]}".guard_sequence')
        assert cursor.fetchone() == (False,)


def test_shared_query_facade_postgres_aggregate_and_embedded_execution(project, native_environment, query_driver):
    request = {"options": {"connection": "crm", "policy": {"profiles_dir": str(project[0])}},
               "sql": 'select sum(amount) as amount from "logical"."customer"',
               "bindings": [{"logical_id": "semantic.customer", "relation_name": '"logical"."customer"',
                             "source_relation": f"{project[2]}.customers"}]}
    result = invoke_query(query_driver, project, request, native_environment)
    assert result.returncode == 0, result.stderr
    assert "leaked" not in result.stderr
    assert json.loads(result.stdout, parse_float=Decimal)["result"] == [{"amount": Decimal("1234567890123458.7891")}]

    request["options"].update(execution_connection="local", policy={"profiles_dir": str(project[0]), "allow_movement": True})
    request["bindings"][0]["source_query"] = f'select amount from "{project[2]}".customers'
    result = invoke_query(query_driver, project, request, native_environment)
    assert result.returncode == 0, result.stderr
    assert "leaked" not in result.stderr
    assert json.loads(result.stdout, parse_float=Decimal)["result"] == [{"amount": Decimal("1234567890123458.7891")}]


def test_typed_metric_result_materializes_binary_decimal_uuid_and_timezone(project, native_environment, query_driver, postgres):
    request = {"options": {"connection": "crm", "execution_connection": "local",
                           "policy": {"profiles_dir": str(project[0]), "allow_movement": True}},
               "sql": 'select amount,payload,uid,timestamp with time zone \'2024-02-29 12:00:00+02\' stamp from "logical"."typed"',
               "bindings": [{"logical_id": "semantic.typed", "relation_name": '"logical"."typed"',
                             "connection": "source", "source_relation": "main.typed",
                             "source_query": "select amount,payload,uid from main.typed"}]}
    result = invoke_query(query_driver, project, request, native_environment, "export")
    assert result.returncode == 0, result.stderr
    assert "leaked" not in result.stderr
    with postgres.cursor() as cursor:
        cursor.execute("select amount,encode(payload,'hex'),uid::text,stamp::text from public.typed_metric_export")
        assert cursor.fetchone() == (Decimal("1234567890123456.7890"), "00ff275c",
                                     "12345678-1234-5678-1234-567812345678", "2024-02-29 10:00:00+00")
        cursor.execute("drop table public.typed_metric_export")


@pytest.mark.parametrize("destination", ["duckdb", "postgres"])
def test_process_owned_target_lock_rejects_overlap_and_recovers_after_termination(project, native_environment, destination, postgres):
    config = project[1]
    config["models"] = {"locked": {"destination": "warehouse" if destination == "duckdb" else "crm",
        "inputs": {"wait": {"connection": "crm", "query": "select 1::bigint as id from pg_sleep(10)"}},
        "sql": "select * from {{ input('wait') }}"}}
    if destination == "postgres":
        config["connections"]["crm_reader"] = {"profile": "cross", "target": "crm"}
        config["models"]["locked"]["inputs"]["wait"]["connection"] = "crm_reader"
    (project[0] / "dxt_connections.yml").write_text(json.dumps(config))
    args = [str(DXT), "cross-database", "run", "--project-dir", str(project[0]),
            "--profiles-dir", str(project[0]), "--allow-movement"]
    with postgres.cursor() as cursor:
        cursor.execute("select clock_timestamp()")
        launched_after = cursor.fetchone()[0]
    process = subprocess.Popen(args, cwd=ROOT, env=native_environment, text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        # PostgreSQL activity proves the first run owns its target lock and has
        # entered its source read; this avoids timing-only synchronization.
        import psycopg2
        profiles = json.loads((project[0] / "profiles.yml").read_text())
        output = profiles["cross"]["outputs"]["crm"]
        with psycopg2.connect(**{key: output[key] for key in ("host", "port", "dbname", "user")}) as monitor:
            for _ in range(100):
                with monitor.cursor() as cursor:
                    cursor.execute("select pg_stat_clear_snapshot()")
                    cursor.execute("select count(*) from pg_stat_activity where state='active' and query like 'fetch forward%%__dxt_extract%%' and backend_start >= %s", [launched_after])
                    if cursor.fetchone()[0]: break
                time.sleep(0.02)
            else: pytest.fail("First run did not reach its bounded source cursor")
        result = subprocess.run(args, cwd=ROOT, env=native_environment, capture_output=True, text=True, timeout=5)
        assert result.returncode != 0
        assert "CrossDatabaseTargetLocked" in result.stderr
    finally:
        process.terminate()
        process.communicate(timeout=5)
    config["models"]["locked"]["inputs"]["wait"]["query"] = "select 17::bigint as id"
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode == 0, result.stderr
    assert "leaked" not in result.stderr


@pytest.mark.parametrize("cached", [False, True])
def test_cross_source_incremental_recomputes_dimension_and_late_fact_keys_atomically(project, native_environment, postgres, cached):
    import duckdb
    config, schema = project[1], project[2]
    with postgres.cursor() as cursor:
        cursor.execute(f'alter table "{schema}".customers add column updated_at timestamp default \'2024-01-01\'')
        cursor.execute(f'update "{schema}".customers set updated_at=\'2024-01-10\' where id=1')
        cursor.execute(f'insert into "{schema}".customers(id,name,updated_at) values(3,\'unchanged\',\'2024-01-01\')')
    with duckdb.connect(str(project[3])) as connection:
        connection.execute("alter table orders add column updated_at timestamp default timestamp '2024-01-10'")
        connection.execute("insert into orders values(3,100,timestamp '2024-01-01')")
    if cached: retain(project)
    flags = ["--allow-movement", "--allow-retention"] if cached else ["--allow-movement"]
    model = config["models"]["joined"]
    model.update(materialized="incremental", unique_key="id")
    customer = model["inputs"]["customers"]
    customer.pop("filter")
    customer["columns"] = ["id", "name", "updated_at"]
    customer["incremental"] = {"key": "id", "watermark": "updated_at"}
    model["inputs"]["orders"]["incremental"] = {"key": "customer_id", "watermark": "updated_at", "lookback_seconds": 86400}
    result = invoke(project, config, native_environment, "run", *flags)
    assert result.returncode == 0, result.stderr
    assert "leaked" not in result.stderr
    assert duck_rows(project[3], "select * from marts.joined order by id") == [(1, "O'Brien", 10), (2, "second", 9), (3, "unchanged", 100)]
    initial = duck_rows(project[3], "select input,watermark from dxt_internal.cross_watermarks order by input")
    with postgres.cursor() as cursor:
        cursor.execute(f'update "{schema}".customers set name=\'changed\',updated_at=\'2024-01-11\' where id=1')
    with duckdb.connect(str(project[3])) as connection:
        connection.execute("insert into orders values(2,5,timestamp '2024-01-09 12:00:00')")
    result = invoke(project, config, native_environment, "run", *flags)
    assert result.returncode == 0, result.stderr
    assert "leaked" not in result.stderr
    assert duck_rows(project[3], "select * from marts.joined order by id") == [(1, "changed", 10), (2, "second", 14), (3, "unchanged", 100)]
    artifact = state(project)[1]["models"][0]
    assert artifact["affected_keys"] == 2
    assert artifact["watermarks_committed"] is True
    committed = duck_rows(project[3], "select input,watermark from dxt_internal.cross_watermarks order by input")
    assert committed != initial
    # Reconcile the commit/file crash window using the immutable per-run
    # watermark history, even when the file never recorded source progress.
    path, recovery = state(project)
    recovery["models"][0].update(status="running", source_watermarks=[], watermarks_committed=False)
    path.write_text(json.dumps(recovery))
    result = invoke(project, config, native_environment, "recover", *flags, "--run-id", recovery["run_id"])
    assert result.returncode == 0, result.stderr
    restored = json.loads(path.read_text())["models"][0]
    assert restored["watermarks_committed"] is True
    assert len(restored["source_watermarks"]) == 2
    with postgres.cursor() as cursor:
        cursor.execute(f'update "{schema}".customers set name=\'retry\',updated_at=\'2024-01-12\' where id=1')
    original = model["sql"]
    model["sql"] = f"{original} union all {original}"
    result = invoke(project, config, native_environment, "run", *flags)
    assert result.returncode != 0
    assert "CrossDatabaseIncrementalUniqueKeyViolation" in result.stderr
    assert "leaked" not in result.stderr
    assert duck_rows(project[3], "select input,watermark from dxt_internal.cross_watermarks order by input") == committed
    assert duck_rows(project[3], "select name from marts.joined where id=1") == [("changed",)]
    model["sql"] = original
    result = invoke(project, config, native_environment, "run", *flags)
    assert result.returncode == 0, result.stderr
    assert duck_rows(project[3], "select name from marts.joined where id=1") == [("retry",)]
    result = invoke(project, config, native_environment, "run", *flags)
    assert result.returncode == 0, result.stderr
    assert len(duck_rows(project[3], "select * from marts.joined")) == 3
    result = invoke(project, config, native_environment, "run", *flags, "--full-refresh")
    assert result.returncode == 0, result.stderr
    assert "leaked" not in result.stderr
    assert len(duck_rows(project[3], "select * from marts.joined")) == 3


@pytest.mark.parametrize("strategy", ["merge", "append", "insert_overwrite"])
def test_incremental_postgres_destination_preserves_unaffected_keys_and_retry_idempotence(project, native_environment, postgres, strategy):
    import duckdb
    with duckdb.connect(str(project[4])) as connection:
        connection.execute("create table events(id bigint,amount decimal(20,4),updated_at timestamp)")
        connection.execute("insert into events values(1,10,timestamp '2024-01-01'),(2,20,timestamp '2024-01-01')")
    config = project[1]
    config["models"] = {"events": {"destination": "crm", "materialized": "incremental",
        "unique_key": "id", "incremental_strategy": strategy, "inputs": {"source": {
            "connection": "source", "relation": "main.events", "columns": ["id", "amount", "updated_at"],
            "incremental": {"key": "id", "watermark": "updated_at"}}}, "sql": "select id,amount from {{ input('source') }}"}}
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode == 0, result.stderr
    with duckdb.connect(str(project[4])) as connection:
        connection.execute("update events set amount=15,updated_at=timestamp '2024-01-02' where id=1")
        connection.execute("insert into events values(3,30,timestamp '2024-01-02')")
    for _ in range(2):
        result = invoke(project, config, native_environment, "run", "--allow-movement")
        assert result.returncode == 0, result.stderr
        assert "leaked" not in result.stderr
        with postgres.cursor() as cursor:
            cursor.execute(f'select * from "{project[2]}".events order by id')
            assert cursor.fetchall() == [(1, Decimal(10 if strategy == "append" else 15)), (2, Decimal(20)), (3, Decimal(30))]


def test_insert_overwrite_replaces_whole_affected_partition(project, native_environment):
    import duckdb
    with duckdb.connect(str(project[4])) as connection:
        connection.execute("create table events(day date,id bigint,amount decimal(20,4),updated_at timestamp)")
        connection.execute("insert into events values(date '2024-01-01',1,10,timestamp '2024-01-10'),"
                           "(date '2024-01-01',2,20,timestamp '2024-01-10'),(date '2024-01-02',3,30,timestamp '2024-01-01')")
    config = project[1]
    config["models"] = {"events": {"destination": "warehouse", "materialized": "incremental",
        "unique_key": "day", "incremental_strategy": "insert_overwrite", "inputs": {"source": {
            "connection": "source", "relation": "main.events", "columns": ["day", "id", "amount", "updated_at"],
            "incremental": {"key": "day", "watermark": "updated_at"}}}, "sql": "select day,id,amount from {{ input('source') }}"}}
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode == 0, result.stderr
    with duckdb.connect(str(project[4])) as connection:
        connection.execute("insert into events values(date '2024-01-01',4,40,timestamp '2024-01-11')")
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode == 0, result.stderr
    assert "leaked" not in result.stderr
    assert state(project)[1]["models"][0]["affected_keys"] == 1
    assert duck_rows(project[3], "select id,amount from marts.events order by id") == [(1, Decimal(10)), (2, Decimal(20)), (3, Decimal(30)), (4, Decimal(40))]
    result = invoke(project, config, native_environment, "run", "--allow-movement", "--full-refresh")
    assert result.returncode == 0, result.stderr
    assert "leaked" not in result.stderr
    assert len(duck_rows(project[3], "select * from marts.events")) == 4


def test_incremental_missing_source_progress_is_rejected_before_database_open(project, native_environment):
    config = project[1]
    config["models"]["joined"].update(materialized="incremental", unique_key="id")
    result = invoke(project, config, native_environment, "plan", "--allow-movement")
    assert result.returncode != 0
    assert "MissingCrossDatabaseSourceWatermark" in result.stderr
    assert not (project[0] / ".dxt").exists()


def retain(project, mode="cached", version=None, ttl=3600):
    profiles = json.loads((project[0] / "profiles.yml").read_text())
    profiles["cross"]["outputs"]["cache"] = {"type": "duckdb", "path": str(project[0] / "cache.duckdb"), "schema": "dxt_stage"}
    (project[0] / "profiles.yml").write_text(json.dumps(profiles))
    config = project[1]
    config["connections"]["cache"] = {"profile": "cross", "target": "cache", "role": "stage", "allowed_destinations": ["warehouse"]}
    config["connections"]["crm"]["allowed_destinations"] = ["cache"]
    declaration = {"mode": mode, "connection": "cache", "ttl_seconds": ttl}
    if version is not None: declaration["version"] = version
    config["models"]["joined"]["inputs"]["customers"]["stage"] = declaration
    return config


def expire_retained(project):
    import duckdb
    with duckdb.connect(str(project[0] / "cache.duckdb")) as connection:
        rows = connection.execute("select key,manifest_json from dxt_stage.catalog where status='ready'").fetchall()
        for key, text in rows:
            manifest = json.loads(text)
            manifest["expires_epoch"] = 0
            connection.execute("update dxt_stage.catalog set expires_epoch=0,manifest_json=? where key=?", [json.dumps(manifest), key])


def test_retained_cache_freshness_reuse_refresh_and_credential_free_metadata(project, native_environment, postgres):
    config = retain(project)
    flags = ["--allow-movement", "--allow-retention"]
    result = invoke(project, config, native_environment, "run", *flags)
    assert result.returncode == 0, result.stderr
    assert "leaked" not in result.stderr
    first = state(project)[1]["models"][0]
    assert first["rows_moved"] == 2
    assert first["stage_artifacts"][0]["cache_hit"] is False
    assert str(project[0]) not in json.dumps(first["stage_artifacts"])
    with postgres.cursor() as cursor:
        cursor.execute(f'update "{project[2]}".customers set name=\'fresh\' where id=1')
    result = invoke(project, config, native_environment, "run", *flags)
    assert result.returncode == 0, result.stderr
    assert "leaked" not in result.stderr
    assert state(project)[1]["models"][0]["stage_artifacts"][0]["cache_hit"] is True
    assert state(project)[1]["models"][0]["rows_moved"] == 1
    assert duck_rows(project[3], "select name from marts.joined") == [("O'Brien",)]
    expire_retained(project)
    result = invoke(project, config, native_environment, "run", *flags)
    assert result.returncode == 0, result.stderr
    assert "leaked" not in result.stderr
    assert state(project)[1]["models"][0]["stage_artifacts"][0]["cache_hit"] is False
    assert duck_rows(project[3], "select name from marts.joined") == [("fresh",)]


def test_immutable_snapshot_version_expiry_cleanup_and_new_version(project, native_environment, postgres):
    config = retain(project, "snapshot", "v1")
    flags = ["--allow-movement", "--allow-retention"]
    result = invoke(project, config, native_environment, "run", *flags)
    assert result.returncode == 0, result.stderr
    with postgres.cursor() as cursor:
        cursor.execute(f'update "{project[2]}".customers set name=\'v2\' where id=1')
    result = invoke(project, config, native_environment, "run", *flags)
    assert result.returncode == 0, result.stderr
    assert duck_rows(project[3], "select name from marts.joined") == [("O'Brien",)]
    expire_retained(project)
    result = invoke(project, config, native_environment, "run", *flags)
    assert result.returncode != 0
    assert "CrossDatabaseSnapshotExpiredRequireNewVersion" in result.stderr
    assert duck_rows(project[3], "select name from marts.joined") == [("O'Brien",)]
    result = invoke(project, config, native_environment, "cleanup")
    assert result.returncode == 0, result.stderr
    assert "Cleaned 1 retained stages" in result.stdout
    result = invoke(project, config, native_environment, "run", *flags)
    assert result.returncode != 0
    assert "CrossDatabaseSnapshotExpiredRequireNewVersion" in result.stderr
    config["models"]["joined"]["inputs"]["customers"]["stage"]["version"] = "v2"
    result = invoke(project, config, native_environment, "run", *flags)
    assert result.returncode == 0, result.stderr
    assert "leaked" not in result.stderr
    assert duck_rows(project[3], "select name from marts.joined") == [("v2",)]


def test_retained_payload_corruption_rolls_back_output_and_cleanup_allows_cache_rebuild(project, native_environment):
    import duckdb
    config = retain(project)
    flags = ["--allow-movement", "--allow-retention"]
    result = invoke(project, config, native_environment, "run", *flags)
    assert result.returncode == 0, result.stderr
    with duckdb.connect(str(project[0] / "cache.duckdb")) as connection:
        manifest = json.loads(connection.execute("select manifest_json from dxt_stage.catalog").fetchone()[0])
        connection.execute(f'update dxt_stage."{manifest["dataset"]}" set name=\'corrupt\'')
    result = invoke(project, config, native_environment, "run", *flags)
    assert result.returncode != 0
    assert "CrossDatabaseStageChecksumMismatch" in result.stderr
    assert "leaked" not in result.stderr
    assert duck_rows(project[3], "select name from marts.joined") == [("O'Brien",)]
    result = invoke(project, config, native_environment, "cleanup", "--older-than-seconds", "0")
    assert result.returncode == 0, result.stderr
    result = invoke(project, config, native_environment, "run", *flags)
    assert result.returncode == 0, result.stderr
    assert duck_rows(project[3], "select name from marts.joined") == [("O'Brien",)]


def test_retention_policy_rejects_before_creating_cache(project, native_environment):
    config = retain(project)
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode != 0
    assert "retained stages require" in result.stderr
    assert not (project[0] / "cache.duckdb").exists()


def test_retained_typed_data_preserves_json_uuid_decimal_and_binary(project, native_environment):
    config = retain(project)
    input_config = config["models"]["joined"]["inputs"]["customers"]
    input_config["columns"] = ["id", "amount", "enabled", "missing", "day", "payload", "uid", "document"]
    config["models"] = {"typed": {"destination": "warehouse", "inputs": {"typed": input_config}, "sql": "select * from {{ input('typed') }}"}}
    for _ in range(2):
        result = invoke(project, config, native_environment, "run", "--allow-movement", "--allow-retention")
        assert result.returncode == 0, result.stderr
        assert "leaked" not in result.stderr
        assert duck_rows(project[3], "select amount,hex(payload),uid::text,document::json->>'a' from marts.typed") == [
            (Decimal("1234567890123456.7890"), "00FF275C", "12345678-1234-5678-1234-567812345678", "1")]


def test_snapshot_same_version_rejects_changed_source_definition(project, native_environment):
    config = retain(project, "snapshot", "fixed-v1")
    flags = ["--allow-movement", "--allow-retention"]
    assert invoke(project, config, native_environment, "run", *flags).returncode == 0
    config["models"]["joined"]["inputs"]["customers"]["filter"] = "not enabled"
    result = invoke(project, config, native_environment, "run", *flags)
    assert result.returncode != 0
    assert "CrossDatabaseSnapshotDefinitionChangedRequireNewVersion" in result.stderr
    assert duck_rows(project[3], "select name from marts.joined") == [("O'Brien",)]


def test_retained_nanosecond_timestamp_and_nul_text_are_exact(project, native_environment):
    import duckdb
    config = retain(project)
    config["connections"]["source"]["allowed_destinations"] = ["cache"]
    source_input = {"connection": "source", "relation": "main.precise", "columns": ["stamp", "txt"],
                    "stage": {"mode": "cached", "connection": "cache", "ttl_seconds": 3600}}
    with duckdb.connect(str(project[4])) as connection:
        connection.execute("create table precise as select '2024-01-01 01:02:03.123456789'::timestamp_ns stamp, 'a'||chr(0)||'b' txt")
    config["models"] = {"precise": {"destination": "warehouse", "inputs": {"precise": source_input},
                                  "sql": "select * from {{ input('precise') }}"}}
    for _ in range(2):
        result = invoke(project, config, native_environment, "run", "--allow-movement", "--allow-retention")
        assert result.returncode == 0, result.stderr
        assert "leaked" not in result.stderr
        assert duck_rows(project[3], "select stamp::text,txt,typeof(stamp) from marts.precise") == [
            ("2024-01-01 01:02:03.123456789", "a\0b", "TIMESTAMP_NS")]


def test_nanosecond_transfer_to_postgres_rejects_rounding(project, native_environment):
    import duckdb
    config = project[1]
    with duckdb.connect(str(project[4])) as connection:
        connection.execute("create table precise as select '2024-01-01 01:02:03.123456789'::timestamp_ns stamp")
    config["models"] = {"precise": {"destination": "crm", "inputs": {"precise": {"connection": "source",
                                  "relation": "main.precise", "columns": ["stamp"]}},
                                  "sql": "select * from {{ input('precise') }}"}}
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode != 0
    assert "CrossDatabaseTimestampPrecisionExceeded" in result.stderr
    assert "leaked" not in result.stderr


def test_cached_stage_tightened_ttl_refreshes_old_payload(project, native_environment, postgres):
    import duckdb
    config = retain(project)
    flags = ["--allow-movement", "--allow-retention"]
    assert invoke(project, config, native_environment, "run", *flags).returncode == 0
    with postgres.cursor() as cursor:
        cursor.execute(f'update "{project[2]}".customers set name=\'new\' where id=1')
    with duckdb.connect(str(project[0] / "cache.duckdb")) as connection:
        key, encoded = connection.execute("select key,manifest_json from dxt_stage.catalog").fetchone()
        manifest = json.loads(encoded)
        manifest["created_epoch"] -= 10
        connection.execute("update dxt_stage.catalog set created_epoch=?,manifest_json=? where key=?",
                           [manifest["created_epoch"], json.dumps(manifest), key])
    config["models"]["joined"]["inputs"]["customers"]["stage"]["ttl_seconds"] = 1
    result = invoke(project, config, native_environment, "run", *flags)
    assert result.returncode == 0, result.stderr
    assert duck_rows(project[3], "select name from marts.joined") == [("new",)]
    assert state(project)[1]["models"][0]["stage_artifacts"][0]["cache_hit"] is False


def test_catalog_observations_feed_fresh_costs_and_preserve_recovery_identity(project, native_environment):
    config = project[1]
    source = config["models"]["joined"]["inputs"]["customers"]
    source.pop("estimated_rows")
    source.pop("estimated_bytes")
    flags = ["--allow-movement"]
    assert invoke(project, config, native_environment, "plan", *flags).returncode == 0
    first_plan = json.loads((project[0] / "target" / "dxt_plan.json").read_text())
    assert first_plan["models"][0]["confidence"] == "unknown"
    result = invoke(project, config, native_environment, "run", *flags)
    assert result.returncode == 0, result.stderr
    assert "leaked" not in result.stderr
    path, recorded = state(project)
    catalog_text = (project[0] / ".dxt" / "cross-catalog.json").read_text()
    catalog = json.loads(catalog_text)
    assert str(project[0]) not in catalog_text
    assert len(catalog["relation_stats"]) == 1
    stat = catalog["relation_stats"][0]
    assert stat["rows"] == 1 and stat["bytes"] == 8
    assert stat["source_adapter"] == "postgres" and stat["source_version"]
    assert [column["name"] for column in stat["columns"]] == ["id", "name"]
    assert catalog["runs"][0]["tasks"][0]["rows_moved"] == 1
    assert catalog["runs"][0]["tasks"][0]["estimated_rows"] == 0
    assert catalog["lineage_edges"][0]["logical_id"] == "source.cross.crm.customers"
    assert invoke(project, config, native_environment, "plan", *flags).returncode == 0
    observed_plan = json.loads((project[0] / "target" / "dxt_plan.json").read_text())
    assert observed_plan["definition_hash"] == first_plan["definition_hash"]
    assert observed_plan["plan_hash"] != first_plan["plan_hash"]
    assert observed_plan["models"][0]["confidence"] == "observed_previous_run"
    assert observed_plan["models"][0]["estimated_moved_bytes"] == 8
    result = invoke(project, config, native_environment, "run", *flags, "--max-bytes", "7")
    assert result.returncode != 0
    assert "estimated movement exceeds the byte budget" in result.stderr
    assert duck_rows(project[3], "select quantity from marts.joined") == [(10,)]
    recorded["models"][0]["status"] = "running"
    path.write_text(json.dumps(recorded))
    result = invoke(project, config, native_environment, "recover", *flags, "--run-id", recorded["run_id"])
    assert result.returncode == 0, result.stderr
    assert json.loads(path.read_text())["models"][0]["status"] == "success"
    source["filter"] = "not enabled"
    assert invoke(project, config, native_environment, "plan", *flags).returncode == 0
    changed = json.loads((project[0] / "target" / "dxt_plan.json").read_text())
    assert changed["models"][0]["confidence"] == "unknown"


def test_catalog_stale_or_changed_credentials_do_not_authorize_estimates(project, native_environment):
    config = project[1]
    source = config["models"]["joined"]["inputs"]["customers"]
    source.pop("estimated_rows")
    source.pop("estimated_bytes")
    flags = ["--allow-movement"]
    assert invoke(project, config, native_environment, "run", *flags).returncode == 0
    catalog_path = project[0] / ".dxt" / "cross-catalog.json"
    catalog = json.loads(catalog_path.read_text())
    catalog["relation_stats"][0]["observed_epoch"] -= 100
    catalog_path.write_text(json.dumps(catalog))
    config["catalog"] = {"max_age_seconds": 1}
    assert invoke(project, config, native_environment, "plan", *flags).returncode == 0
    assert json.loads((project[0] / "target" / "dxt_plan.json").read_text())["models"][0]["confidence"] == "unknown"
    config.pop("catalog")
    profiles_path = project[0] / "profiles.yml"
    profiles = json.loads(profiles_path.read_text())
    profiles["cross"]["outputs"]["crm"]["password"] = "private-credential-fixture"
    profiles_path.write_text(json.dumps(profiles))
    result = invoke(project, config, native_environment, "plan", *flags)
    assert result.returncode == 0, result.stderr
    rendered = (project[0] / "target" / "dxt_plan.json").read_text()
    assert "private-credential-fixture" not in rendered
    assert "private-credential-fixture" not in result.stderr
    assert json.loads(rendered)["models"][0]["confidence"] == "unknown"


def test_native_capability_probes_are_versioned_readonly_and_clean(project, native_environment, postgres):
    config = project[1]
    config["connections"]["source"]["role"] = "source"
    config["connections"]["crm"]["role"] = "source"
    result = invoke(project, config, native_environment, "debug", "--probe-cancellation")
    assert result.returncode == 0, result.stderr
    assert "leaked" not in result.stderr
    text = (project[0] / "target" / "dxt_capabilities.json").read_text()
    assert str(project[0]) not in text
    results = {item["connection"]: item for item in json.loads(text)["connections"]}
    assert all(item["status"] == "success" and item["version"] and item["read_only_transaction"] and item["cancellation"] for item in results.values())
    assert results["crm"]["transactional_ddl"] is None
    assert results["source"]["typed_temporary_table"] is None
    assert results["warehouse"]["transactional_ddl"] is True
    assert results["warehouse"]["binary_roundtrip"] is True
    assert duck_rows(project[3], "select table_name from information_schema.tables where table_name like '__dxt_probe_%'") == []
    assert duck_rows(project[4], "select count(*) from typed") == [(1,)]
    with postgres.cursor() as cursor:
        cursor.execute(f'select count(*) from "{project[2]}".customers')
        assert cursor.fetchone()[0] == 2


def test_capability_failure_is_sanitized_and_independent_connections_continue(project, native_environment):
    config = project[1]
    path = project[0] / "profiles.yml"
    profiles = json.loads(path.read_text())
    private_host = str(project[0] / "unavailable-private-socket")
    profiles["cross"]["outputs"]["crm"]["host"] = private_host
    path.write_text(json.dumps(profiles))
    result = invoke(project, config, native_environment, "debug")
    assert result.returncode != 0
    text = (project[0] / "target" / "dxt_capabilities.json").read_text()
    assert private_host not in text and private_host not in result.stderr
    results = {item["connection"]: item for item in json.loads(text)["connections"]}
    assert results["crm"]["status"] == "error"
    assert results["source"]["status"] == "success"
    assert results["local"]["status"] == "success"


def test_namespaced_catalog_export_contains_observed_metadata(project, native_environment):
    assert invoke(project, project[1], native_environment, "run", "--allow-movement").returncode == 0
    result = invoke(project, project[1], native_environment, "catalog")
    assert result.returncode == 0, result.stderr
    text = (project[0] / "target" / "dxt_catalog.json").read_text()
    assert str(project[0]) not in text
    catalog = json.loads(text)
    assert catalog["generation"] == 1
    assert catalog["relation_stats"][0]["rows"] == 1
    assert catalog["connections"][0]["capabilities"]["transactional_ddl"] is True


def test_cost_alternatives_log_known_movement_and_unknown_join_output(project, native_environment):
    result = invoke(project, project[1], native_environment, "plan", "--allow-movement", "--allow-raw-extract")
    assert result.returncode == 0, result.stderr
    model = json.loads((project[0] / "target" / "dxt_plan.json").read_text())["models"][0]
    alternatives = {item["execution_connection"]: item for item in model["alternatives"]}
    assert alternatives["warehouse"]["selected"] is True
    assert alternatives["warehouse"]["estimated_moved_bytes"] == 16
    assert alternatives["warehouse"]["estimated_rows"] == 1
    assert alternatives["local"]["permitted"] is True
    assert alternatives["local"]["estimated_moved_bytes"] is None
    assert "unknown output cardinality" in alternatives["local"]["reason"]
    assert alternatives["crm"]["permitted"] is False
    assert model["largest_movement_contributor"] == {"input": "customers", "rows": 1, "bytes": 16}


def test_alternative_policy_denials_include_concrete_budget_remedies(project, native_environment):
    config = project[1]
    config["connections"]["local"]["trust_domain"] = "other"
    config["models"]["joined"]["inputs"]["customers"]["sensitivity"] = "restricted"
    config["models"]["joined"]["budget"] = {"max_bytes": 8}
    result = invoke(project, config, native_environment, "plan", "--allow-movement", "--allow-sensitive", "--allow-raw-extract")
    assert result.returncode == 0, result.stderr
    model = json.loads((project[0] / "target" / "dxt_plan.json").read_text())["models"][0]
    assert model["permitted"] is False
    assert model["largest_movement_contributor"]["bytes"] == 16
    assert model["suggested_changes"]
    local = next(item for item in model["alternatives"] if item["execution_connection"] == "local")
    assert local["permitted"] is False
    assert not (project[0] / ".dxt").exists()


def literal_model(destination="warehouse", value=1):
    return {"destination": destination, "inputs": {"one": {"connection": destination, "query": f"select {value}::bigint as id"}},
            "sql": "select * from {{ input('one') }}"}


def test_cross_task_dag_orders_ancestors_and_selected_dependency_closure(project, native_environment):
    config = project[1]
    child = {"destination": "warehouse", "depends_on": ["parent"],
             "inputs": {"parent": {"connection": "warehouse", "relation": "marts.parent"}},
             "sql": "select id+1 as id from {{ input('parent') }}"}
    config["models"] = {"child": child, "independent": literal_model(value=9), "parent": literal_model()}
    result = invoke(project, config, native_environment, "run", "--select", "child", "--max-concurrent-tasks", "2")
    assert result.returncode == 0, result.stderr
    assert "leaked" not in result.stderr
    assert duck_rows(project[3], "select * from marts.child") == [(2,)]
    assert duck_rows(project[3], "select table_name from information_schema.tables where table_schema='marts' order by table_name") == [("child",), ("parent",)]
    assert len(state(project)[1]["models"]) == 2
    assert all(record["status"] == "success" and record["target_lock"] == "released" for record in state(project)[1]["models"])


@pytest.mark.parametrize("fault", ["missing", "cycle", "capacity", "memory"])
def test_invalid_task_graph_and_capacities_fail_before_database_mutations(project, native_environment, fault):
    config = project[1]
    config["models"] = {"one": literal_model(), "two": literal_model(value=2)}
    if fault == "missing": config["models"]["one"]["depends_on"] = ["missing"]
    if fault == "cycle":
        config["models"]["one"]["depends_on"] = ["two"]
        config["models"]["two"]["depends_on"] = ["one"]
    if fault == "capacity": config["connections"]["warehouse"]["limits"] = {"max_queries": 0}
    if fault == "memory": config["scheduler"] = {"max_memory_bytes": 1}
    result = invoke(project, config, native_environment)
    assert result.returncode != 0
    assert not (project[0] / ".dxt").exists()
    assert duck_rows(project[3], "select table_name from information_schema.tables where table_schema='marts'") == []


def test_failed_cross_task_skips_descendants_and_continues_independent_tasks(project, native_environment):
    config = project[1]
    config["models"] = {
        "child": {"destination": "warehouse", "depends_on": ["broken"],
                  "inputs": {"parent": {"connection": "warehouse", "relation": "marts.broken"}}, "sql": "select * from {{ input('parent') }}"},
        "broken": {"destination": "warehouse", "inputs": {"bad": {"connection": "crm", "query": "select nonexistent_column"}}, "sql": "select * from {{ input('bad') }}"},
        "independent": literal_model(value=17)}
    result = invoke(project, config, native_environment, "run", "--allow-movement", "--max-concurrent-tasks", "3")
    assert result.returncode != 0
    assert "leaked" not in result.stderr
    records = {record["model"]: record for record in state(project)[1]["models"]}
    assert [records[name]["status"] for name in ("broken", "child", "independent")] == ["error", "skipped", "success"]
    assert records["broken"]["attempt_count"] == 1
    assert duck_rows(project[3], "select * from marts.independent") == [(17,)]


@pytest.mark.parametrize("stream_limit", [1, 2])
def test_native_task_concurrency_obeys_source_stream_pool_and_aliases(project, native_environment, postgres, stream_limit):
    config = project[1]
    limits = {"max_queries": 4, "max_streaming_readers": stream_limit, "max_loaders": 1}
    config["connections"]["crm"]["limits"] = limits
    config["connections"]["crm_reader"] = {"profile": "cross", "target": "crm", "limits": limits}
    config["models"] = {
        "duck_job": {"destination": "warehouse", "inputs": {"wait": {"connection": "crm", "query": "select 1::bigint id from pg_sleep(2)"}}, "sql": "select * from {{ input('wait') }}"},
        "pg_job": {"destination": "crm", "inputs": {"wait": {"connection": "crm_reader", "query": "select 2::bigint id from pg_sleep(2)"}}, "sql": "select * from {{ input('wait') }}"}}
    (project[0] / "dxt_connections.yml").write_text(json.dumps(config))
    with postgres.cursor() as cursor:
        cursor.execute("select clock_timestamp()")
        started = cursor.fetchone()[0]
    args = [str(DXT), "cross-database", "run", "--project-dir", str(project[0]), "--profiles-dir", str(project[0]), "--allow-movement", "--max-concurrent-tasks", "2"]
    process = subprocess.Popen(args, cwd=ROOT, env=native_environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    maximum = 0
    try:
        for _ in range(350):
            with postgres.cursor() as cursor:
                cursor.execute("select pg_stat_clear_snapshot()")
                cursor.execute("select count(*) from pg_stat_activity where state='active' and query like 'fetch forward%%__dxt_extract%%' and backend_start>=%s", [started])
                maximum = max(maximum, cursor.fetchone()[0])
            if process.poll() is not None: break
            time.sleep(0.02)
        output, errors = process.communicate(timeout=10)
        assert process.returncode == 0, errors
        assert "leaked" not in errors
        assert maximum == stream_limit
    finally:
        if process.poll() is None: process.terminate(); process.communicate(timeout=5)
    assert duck_rows(project[3], "select * from marts.duck_job") == [(1,)]
    with postgres.cursor() as cursor:
        cursor.execute(f'select * from "{project[2]}".pg_job')
        assert cursor.fetchall() == [(2,)]


@pytest.mark.parametrize("sqlstate", ["40001", "40P01", "55P03"])
def test_known_aborted_source_query_retries_with_adaptive_backpressure(project, native_environment, postgres, sqlstate):
    import psycopg2
    config = project[1]
    config["connections"]["crm"]["limits"] = {"max_queries": 4, "max_streaming_readers": 4}
    with postgres.cursor() as cursor:
        cursor.execute(f'''create function "{project[2]}".retry_read() returns bigint language plpgsql as $$
            begin
                if not pg_try_advisory_lock(72833861) then
                    raise exception 'private source diagnostic' using errcode='{sqlstate}';
                end if;
                perform pg_advisory_unlock(72833861);
                return 41;
            end $$''')
    config["models"] = {"retried": {"destination": "warehouse", "inputs": {"one": {"connection": "crm", "query": f'select "{project[2]}".retry_read() as id'}}, "sql": "select * from {{ input('one') }}"}}
    (project[0] / "dxt_connections.yml").write_text(json.dumps(config))
    blocker = psycopg2.connect(postgres.dsn)
    blocker.autocommit = True
    with blocker.cursor() as cursor: cursor.execute("select pg_advisory_lock(72833861)")
    args = [str(DXT), "cross-database", "run", "--project-dir", str(project[0]), "--profiles-dir", str(project[0]), "--allow-movement", "--max-retries", "8", "--retry-delay-ms", "100"]
    process = subprocess.Popen(args, cwd=ROOT, env=native_environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        for _ in range(200):
            files = list((project[0] / ".dxt" / "cross-runs").glob("*/tasks/retried.json"))
            if files and json.loads(files[0].read_text())["status"] == "retrying": break
            if process.poll() is not None: pytest.fail(process.communicate()[1])
            time.sleep(0.01)
        else: pytest.fail("Source did not publish its known-abort retry state")
        with blocker.cursor() as cursor: cursor.execute("select pg_advisory_unlock(72833861)")
        output, errors = process.communicate(timeout=15)
        assert process.returncode == 0, errors
        assert "private source diagnostic" not in errors and "leaked" not in errors
    finally:
        blocker.close()
        if process.poll() is None: process.terminate(); process.communicate(timeout=5)
    record = state(project)[1]["models"][0]
    assert record["status"] == "success" and record["attempt_count"] >= 2
    assert record["throttled_connection"] == "crm"
    assert record["attempts"][0]["status"] == "error"
    assert duck_rows(project[3], "select * from marts.retried") == [(41,)]
    stage_files = list((project[0] / ".dxt" / "cross-runs").glob("*/stages/retried.json"))
    assert stage_files and json.loads(stage_files[0].read_text())["stages"][0]["readiness"] == "ready"


def test_shared_query_accounts_managed_movement_and_client_result_separately(project, native_environment, query_driver):
    request = {"options": {"connection": "warehouse", "budget": {"max_rows": 1},
                           "policy": {"profiles_dir": str(project[0]), "allow_movement": True}},
               "sql": 'select id from "logical"."customer"',
               "bindings": [{"logical_id": "semantic.customer", "relation_name": '"logical"."customer"',
                             "source_relation": f"{project[2]}.customers", "connection": "crm",
                             "source_query": f'select id from "{project[2]}".customers where enabled'}]}
    result = invoke_query(query_driver, project, request, native_environment)
    assert result.returncode == 0, result.stderr
    assert "leaked" not in result.stderr
    artifact = json.loads(result.stdout)
    assert artifact["result"] == [{"id": 1}]
    execution = artifact["execution"]
    assert execution["rows_moved"] == 1 and execution["output_rows"] == 1
    assert execution["bytes_moved"] == 1 and execution["result_bytes"] == 1
    assert execution["attempt_count"] == 1
    assert str(project[0]) not in json.dumps(execution)


@pytest.mark.parametrize("partial_read,max_rows,succeeds", [(False, 100000, True), (True, 100000, True), (True, 32, False)])
def test_shared_query_retries_confirmed_source_abort_and_records_actual_attempts(project, native_environment, query_driver, postgres, partial_read, max_rows, succeeds):
    import psycopg2
    with postgres.cursor() as cursor:
        cursor.execute(f'''create function "{project[2]}".retry_query(value bigint) returns bigint language plpgsql as $$
            begin
                if value in (17, 42) and not pg_try_advisory_lock(72833862) then
                    perform pg_sleep(0.3);
                    raise exception 'private query diagnostic' using errcode='40001';
                end if;
                if value in (17, 42) then perform pg_advisory_unlock(72833862); end if;
                return value;
            end $$''')
    source_query = (f'select "{project[2]}".retry_query(id) as id from generate_series(1,17) as rows(id)' if partial_read
                    else f'select "{project[2]}".retry_query(42) as id')
    request = {"options": {"connection": "warehouse", "budget": {"max_rows": max_rows}, "policy": {"profiles_dir": str(project[0]), "allow_movement": True, "max_retries": 8}},
               "sql": 'select id from "logical"."customer"',
               "bindings": [{"logical_id": "semantic.customer", "relation_name": '"logical"."customer"',
                             "source_relation": f"{project[2]}.customers", "connection": "crm",
                             "source_query": source_query}]}
    (project[0] / "dxt_connections.yml").write_text(json.dumps(project[1]))
    request_path = project[0] / "query_request.json"
    request_path.write_text(json.dumps(request))
    blocker = psycopg2.connect(postgres.dsn)
    blocker.autocommit = True
    with blocker.cursor() as cursor: cursor.execute("select pg_advisory_lock(72833862)")
    with postgres.cursor() as cursor:
        cursor.execute("select clock_timestamp()")
        started = cursor.fetchone()[0]
    process = subprocess.Popen([str(query_driver), "query", str(project[0]), str(request_path)], cwd=ROOT, env=native_environment,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        for _ in range(200):
            with postgres.cursor() as cursor:
                cursor.execute("select pg_stat_clear_snapshot()")
                cursor.execute("select count(*) from pg_stat_activity where state='active' and wait_event='PgSleep' and query like 'fetch forward%%__dxt_extract%%' and backend_start >= %s", [started])
                if cursor.fetchone()[0]: break
            if process.poll() is not None: pytest.fail(process.communicate()[1])
            time.sleep(0.01)
        else: pytest.fail("Query did not enter its controlled source read")
        with blocker.cursor() as cursor: cursor.execute("select pg_advisory_unlock(72833862)")
        output, errors = process.communicate(timeout=15)
        assert (process.returncode == 0) is succeeds, errors
        assert "private query diagnostic" not in errors and "leaked" not in errors
    finally:
        blocker.close()
        if process.poll() is None: process.terminate(); process.communicate(timeout=5)
    catalog = json.loads((project[0] / ".dxt" / "cross-catalog.json").read_text())
    summary = catalog["runs"][-1]
    record = json.loads((project[0] / ".dxt" / "cross-runs" / summary["run_id"] / "tasks" / "metric_query.json").read_text())
    assert record["attempt_count"] >= 2
    assert record["attempts"][0]["error_name"] == "PostgresSerializationFailure"
    assert record["attempts"][0]["rows_moved"] == (16 if partial_read else 0)
    if succeeds:
        artifact = json.loads(output)
        assert artifact["result"] == ([{"id": value} for value in range(1, 18)] if partial_read else [{"id": 42}])
        assert artifact["execution"]["rows_moved"] == (33 if partial_read else 1)
        assert artifact["execution"]["output_rows"] == (17 if partial_read else 1)
        assert artifact["execution"]["attempts"] == record["attempts"]
    else:
        assert "CrossDatabaseRowBudgetExceeded" in errors
        assert record["status"] == "error" and record["cleanup"] == "complete"
        assert record["attempt_count"] == 2
        assert record["rows_moved"] == 33 and record["output_rows"] == 0
        assert record["attempts"][1]["error_name"] == "CrossDatabaseRowBudgetExceeded"

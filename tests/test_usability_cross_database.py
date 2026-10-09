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
def test_process_owned_target_lock_rejects_overlap_and_recovers_after_termination(project, native_environment, destination):
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
                    cursor.execute("select count(*) from pg_stat_activity where state='active' and query like 'fetch forward%__dxt_extract%'")
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

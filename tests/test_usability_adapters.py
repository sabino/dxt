"""Actual native-library conformance; Python only drives developer fixtures."""
from __future__ import annotations

import ctypes.util
import importlib.util
import json
import os
import subprocess
from decimal import Decimal
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out" / "bin" / "dxt"
CERTIFY = os.environ.get("DXT_NATIVE_ADAPTER_CERTIFY") == "1"


@pytest.fixture(scope="module")
def driver(tmp_path_factory):
    output = tmp_path_factory.mktemp("native-driver") / "adapter-driver"
    compiled = subprocess.run(
        ["zig", "build-exe", "-lc", "--dep", "adapter",
         "-Mroot=tests/native_adapter_driver.zig",
         "-Ivendor/libyaml/include", "-cflags", "-std=gnu99",
         '-DYAML_VERSION_STRING="0.2.5"', "-DYAML_VERSION_MAJOR=0",
         "-DYAML_VERSION_MINOR=2", "-DYAML_VERSION_PATCH=5", "--",
         "vendor/libyaml/src/api.c", "vendor/libyaml/src/reader.c",
         "vendor/libyaml/src/scanner.c", "vendor/libyaml/src/parser.c",
         "-Madapter=src/project/adapter.zig",
         f"-femit-bin={output}"],
        cwd=ROOT, text=True, capture_output=True,
    )
    assert compiled.returncode == 0, compiled.stderr
    built = subprocess.run(["zig", "build"], cwd=ROOT, text=True, capture_output=True)
    assert built.returncode == 0, built.stderr
    return output


@pytest.fixture(scope="module")
def duckdb_environment():
    library = os.environ.get("DXT_DUCKDB_LIBRARY") or ctypes.util.find_library("duckdb")
    if not library:
        if CERTIFY:
            pytest.fail("Native certification requires DXT_DUCKDB_LIBRARY")
        pytest.skip("Native DuckDB fixture requires libduckdb")
    return dict(os.environ, DXT_DUCKDB_LIBRARY=library, DXT_DUCKDB_BACKEND="native")


@pytest.fixture(scope="module")
def postgres_fixture(tmp_path_factory):
    if not __import__("postgres_fixture").available():
        if CERTIFY:
            pytest.fail("Native certification requires pinned pgserver developer fixture")
        pytest.skip("Native PostgreSQL fixture requires pgserver")
    import postgres_fixture as pgserver
    with pgserver.get_server(tmp_path_factory.mktemp("native-postgres") / "data") as server:
        environment = dict(os.environ, DXT_TEST_POSTGRES_CONNINFO=server.get_uri())
        yield server, environment


def invoke(driver, adapter, mode, database, environment, sql=None):
    arguments = [str(driver), adapter, mode, str(database)]
    if sql is not None:
        arguments.append(sql)
    return subprocess.run(arguments, cwd=ROOT, env=environment,
                          capture_output=True, text=True, timeout=15)


def decoded(result):
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout, parse_float=Decimal)


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_actual_native_types_nulls_quoted_names_and_exact_numeric_values(
    driver, tmp_path, request, adapter
):
    environment = (request.getfixturevalue("duckdb_environment") if adapter == "duckdb"
                   else request.getfixturevalue("postgres_fixture")[1])
    result = invoke(driver, adapter, "query", tmp_path / "typed.duckdb", environment,
                    "select 9223372036854775807::bigint as id, true as enabled, "
                    "null::text as missing, 'O''Brien' as \"quoted\"\"name\", "
                    "1234567890123456.7890::decimal(20,4) as amount, "
                    "date '2024-02-29' as day")
    assert decoded(result) == [{"id": 9223372036854775807, "enabled": True,
                               "missing": None, 'quoted"name': "O'Brien",
                               "amount": Decimal("1234567890123456.7890"), "day": "2024-02-29"}]


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_actual_native_transactions_introspection_and_error_recovery(
    driver, tmp_path, request, adapter
):
    environment = (request.getfixturevalue("duckdb_environment") if adapter == "duckdb"
                   else request.getfixturevalue("postgres_fixture")[1])
    capabilities = decoded(invoke(driver, adapter, "conformance", tmp_path / "transaction.duckdb", environment))
    assert capabilities["transactions"] is True
    assert capabilities["transactional_ddl"] is True
    assert capabilities["schemas"] is True
    assert capabilities["cancellation"] is True
    assert capabilities["concurrent_connections"] is True
    assert capabilities["merge"] is True
    assert capabilities["savepoints"] is (adapter == "postgres")
    assert capabilities["catalogs"] is (adapter == "duckdb")
    assert capabilities["replace_table"] is (adapter == "duckdb")


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_actual_native_dml_returning_rows(driver, tmp_path, request, adapter):
    environment = (request.getfixturevalue("duckdb_environment") if adapter == "duckdb"
                   else request.getfixturevalue("postgres_fixture")[1])
    database = tmp_path / "returning.duckdb"
    sql = "create temporary table returning_rows(id integer); insert into returning_rows values (17), (18) returning id"
    assert decoded(invoke(driver, adapter, "query", database, environment, sql)) == [{"id": 17}, {"id": 18}]


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_actual_native_cancellation_and_reusable_connection(driver, tmp_path, request, adapter):
    environment = (request.getfixturevalue("duckdb_environment") if adapter == "duckdb"
                   else request.getfixturevalue("postgres_fixture")[1])
    assert decoded(invoke(driver, adapter, "cancel", tmp_path / "cancel.duckdb", environment)) == {
        "cancelled": True, "connection_recovered": True,
    }


def test_shared_duckdb_database_supports_simultaneous_writers(driver, tmp_path, duckdb_environment):
    assert decoded(invoke(driver, "duckdb", "pool", tmp_path / "shared.duckdb", duckdb_environment)) == {
        "shared_pool": True, "concurrent_writers": True,
    }


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_actual_qualified_catalog_introspection_and_relation_kinds(driver, tmp_path, request, adapter):
    environment = (request.getfixturevalue("duckdb_environment") if adapter == "duckdb"
                   else request.getfixturevalue("postgres_fixture")[1])
    assert decoded(invoke(driver, adapter, "qualified-introspection", tmp_path / "introspection.duckdb", environment)) == {
        "qualified_identity": True, "column_types": True, "relation_kinds": True,
    }


def test_native_readonly_pool_promotes_only_after_readers_disconnect(driver, tmp_path, duckdb_environment):
    database = tmp_path / "promotion.duckdb"
    assert decoded(invoke(driver, "duckdb", "query", database, duckdb_environment, "select 1")) == [{"1": 1}]
    assert decoded(invoke(driver, "duckdb", "promote", database, duckdb_environment)) == {
        "readers_preserved": True, "promoted_after_disconnect": True,
    }


def test_native_binding_session_retains_temp_views_and_memory_diagnostics(driver, tmp_path, duckdb_environment):
    assert decoded(invoke(driver, "duckdb", "binder", ":memory:", duckdb_environment)) == {
        "temporary_binding": True, "diagnostics_in_memory": True,
    }


def test_native_binding_cannot_escape_shared_writer_readonly_transaction(driver, tmp_path, duckdb_environment):
    database = tmp_path / "binding.duckdb"
    assert decoded(invoke(driver, "duckdb", "binder-write", database, duckdb_environment)) == {
        "persistent_writes_rejected": True, "transaction_escape_rejected": True,
    }
    assert decoded(invoke(driver, "duckdb", "query", database, duckdb_environment,
                          "select count(*) as n from guarded_binding")) == [{"n": 0}]


def test_native_transaction_script_preserves_selected_result_through_rollback(
    driver, tmp_path, duckdb_environment
):
    database = tmp_path / "rollback.duckdb"
    sql = "begin; create table fixture as select 17 as id; select count(*) as failures from fixture where id <> 17; rollback"
    assert decoded(invoke(driver, "duckdb", "query", database, duckdb_environment, sql)) == [{"failures": 0}]
    assert decoded(invoke(driver, "duckdb", "query", database, duckdb_environment,
                          "select count(*) as n from information_schema.tables where table_name='fixture'")) == [{"n": 0}]


@pytest.mark.parametrize("sql", ["insert into guard values (1)", "select nextval('native_sequence')",
                                  "explain analyze insert into guard values (1)"])
def test_pooled_native_readonly_queries_cannot_write(driver, tmp_path, duckdb_environment, sql):
    database = tmp_path / "readonly.duckdb"
    result = invoke(driver, "duckdb", "readonly", database, duckdb_environment, sql)
    assert result.returncode == 1
    assert result.stderr in {"error: DuckDbExecutionFailed\n", "error: NativeDuckDbReadOnlyConnection\n"}
    assert decoded(invoke(driver, "duckdb", "query", database, duckdb_environment,
                          "select count(*) as n from guard")) == [{"n": 0}]


def test_native_readonly_zero_rows_preserve_empty_result(driver, tmp_path, duckdb_environment):
    assert decoded(invoke(driver, "duckdb", "readonly", tmp_path / "readonly.duckdb", duckdb_environment,
                          "select id from guard where false")) == []


def test_postgres_profile_environment_credentials_feed_actual_native_query(
    driver, tmp_path, postgres_fixture
):
    server, environment = postgres_fixture
    info = server.get_postmaster_info()
    secret = "synthetic-profile-secret-a'b\\c"
    environment = dict(environment, DXT_TEST_PG_HOST=str(info.socket_dir),
                       DXT_TEST_PG_PORT=str(info.port), DXT_TEST_PG_USER="postgres", DXT_TEST_PG_SECRET=secret)
    (tmp_path / "profiles.yml").write_text("""native_demo:
  target: native
  outputs:
    native:
      type: postgres
      schema: public
      host: "{{ env_var('DXT_TEST_PG_HOST') }}"
      port: "{{ env_var('DXT_TEST_PG_PORT') }}"
      dbname: postgres
      user: "{{ env_var('DXT_TEST_PG_USER') }}"
      password: "{{ env_var('DXT_TEST_PG_SECRET') }}"
""")
    result = invoke(driver, "postgres", "profile", tmp_path, environment,
                    "select current_user as role, current_database() as database")
    assert decoded(result) == [{"role": "postgres", "database": "postgres"}]
    assert secret not in result.stdout + result.stderr
    assert not list(tmp_path.glob("*.json"))


def test_postgres_failure_diagnostics_never_echo_connection_credentials(driver, tmp_path, postgres_fixture):
    _, environment = postgres_fixture
    secret = "synthetic-connection-secret"
    environment = dict(environment, DXT_TEST_POSTGRES_CONNINFO=f"host=127.0.0.1 port=1 password={secret} connect_timeout=1")
    result = invoke(driver, "postgres", "query", tmp_path, environment, "select 1")
    assert result.returncode == 1
    assert result.stderr == "error: PostgresConnectionFailed\n"
    assert secret not in result.stdout + result.stderr


def test_postgres_server_notices_do_not_escape_native_result_channel(driver, tmp_path, postgres_fixture):
    environment = postgres_fixture[1]
    secret = "synthetic-notice-secret"
    result = invoke(driver, "postgres", "query", tmp_path, environment,
                    f"do $$ begin raise notice '{secret}'; end $$; select 1 as id")
    assert decoded(result) == [{"id": 1}]
    assert result.stderr == ""


def test_explicit_missing_native_library_fails_closed(driver, tmp_path):
    environment = dict(os.environ, DXT_DUCKDB_LIBRARY=str(tmp_path / "unavailable-library"), DXT_DUCKDB_BACKEND="native")
    result = invoke(driver, "duckdb", "query", tmp_path / "missing.duckdb", environment, "select 1")
    assert result.returncode == 1
    assert result.stderr == "error: NativeDuckDbLibraryNotFound\n"
    assert not (tmp_path / "missing.duckdb").exists()


def test_explicit_missing_postgres_library_fails_closed(driver, tmp_path):
    environment = dict(os.environ, DXT_POSTGRES_LIBRARY=str(tmp_path / "unavailable-library"),
                       DXT_TEST_POSTGRES_CONNINFO="dbname=postgres")
    result = invoke(driver, "postgres", "query", tmp_path, environment, "select 1")
    assert result.returncode == 1
    assert result.stderr == "error: NativePostgresLibraryNotFound\n"


def test_cli_fallback_remains_available_and_normalizes_empty_rows(driver, tmp_path):
    environment = dict(os.environ, DXT_DUCKDB_BACKEND="cli")
    environment.pop("DXT_DUCKDB_LIBRARY", None)
    assert decoded(invoke(driver, "duckdb", "query", tmp_path / "fallback.duckdb", environment,
                          "select 1 as id where false")) == []
    assert decoded(invoke(driver, "duckdb", "query", tmp_path / "fallback.duckdb", environment,
                          "select 17 as id, null::text as absent")) == [{"id": 17, "absent": None}]


def test_native_cli_build_runs_without_external_duckdb_executable(driver, tmp_path, duckdb_environment):
    project = tmp_path / "project"
    (project / "models").mkdir(parents=True)
    (project / "seeds").mkdir()
    (project / "dbt_project.yml").write_text("name: native_demo\nversion: '1.0'\n")
    (project / "seeds" / "raw.csv").write_text("id\n17\n")
    (project / "models" / "result.sql").write_text("{{ config(materialized='table') }} select * from {{ ref('raw') }}")
    (project / "models" / "schema.yml").write_text("""version: 2
models:
  - name: result
    columns:
      - name: id
        data_tests: [not_null]
unit_tests:
  - name: native_fixture
    model: result
    given:
      - input: ref('raw')
        rows:
          - {id: 17}
    expect:
      rows:
        - {id: 17}
""")
    empty_path = tmp_path / "empty-bin"
    empty_path.mkdir()
    environment = dict(duckdb_environment, PATH=str(empty_path))
    target = tmp_path / "target"
    result = subprocess.run([str(DXT), "build", "--project-dir", str(project), "--target-path", str(target)],
                            cwd=ROOT, env=environment, text=True, capture_output=True, timeout=15)
    assert result.returncode == 0, result.stderr
    rows = json.loads((target / "run_results.json").read_text())["results"]
    assert sorted(row["status"] for row in rows) == ["pass", "pass", "success", "success"]
    assert decoded(invoke(driver, "duckdb", "query", target / "dxt.duckdb", environment,
                          "select * from result")) == [{"id": 17}]
    for artifact in target.glob("*.json"):
        assert duckdb_environment["DXT_DUCKDB_LIBRARY"] not in artifact.read_text()


def test_native_incremental_and_snapshot_workflows_without_external_cli(driver, tmp_path, duckdb_environment):
    project = tmp_path / "native-workflow"
    (project / "models").mkdir(parents=True)
    (project / "snapshots").mkdir()
    database = project / "warehouse.duckdb"
    (project / "dbt_project.yml").write_text("name: native_demo\nversion: '1.0'\nprofile: native_demo\n")
    (project / "profiles.yml").write_text(
        "native_demo:\n  target: native\n  outputs:\n    native:\n"
        f"      type: duckdb\n      schema: main\n      path: {database}\n"
    )
    (project / "models" / "events.sql").write_text(
        "{{ config(materialized='incremental', unique_key='id') }} select * from raw_events\n"
        "{% if is_incremental() %}where updated > (select max(updated) from main.events){% endif %}\n"
    )
    (project / "snapshots" / "history.sql").write_text(
        "{% snapshot history %}\n"
        "{{ config(strategy='timestamp', unique_key='id', updated_at='ts', target_schema='archive') }}\n"
        "select * from {{ ref('events') }}\n{% endsnapshot %}\n"
    )
    empty_path = tmp_path / "empty-bin"
    empty_path.mkdir()
    environment = dict(duckdb_environment, PATH=str(empty_path))
    assert decoded(invoke(driver, "duckdb", "query", database, environment,
                          "create table raw_events(id integer, label varchar, ts timestamp, updated integer); "
                          "insert into raw_events values (1,'old','2020-01-01',1); select count(*) as n from raw_events")) == [{"n": 1}]

    def command(name):
        result = subprocess.run([str(DXT), name, "--project-dir", str(project)], cwd=ROOT,
                                env=environment, capture_output=True, text=True, timeout=15)
        assert result.returncode == 0, result.stderr

    command("run")
    command("snapshot")
    assert decoded(invoke(driver, "duckdb", "query", database, environment,
                          "update raw_events set label='new', ts='2020-02-01', updated=2; select count(*) as n from raw_events")) == [{"n": 1}]
    command("run")
    command("snapshot")
    command("run")
    command("snapshot")
    assert decoded(invoke(driver, "duckdb", "query", database, environment,
                          "select label from main.events")) == [{"label": "new"}]
    assert decoded(invoke(driver, "duckdb", "query", database, environment,
                          "select label, dbt_valid_to is null as current from archive.history order by dbt_valid_from")) == [
        {"label": "old", "current": False}, {"label": "new", "current": True},
    ]


@pytest.mark.parametrize("state,expected", [
    ("40001", "PostgresSerializationFailure"),
    ("40P01", "PostgresDeadlockDetected"),
    ("55P03", "PostgresLockNotAvailable"),
    ("57014", "AdapterQueryCancelled"),
    ("08006", "PostgresExecutionFailed"),
])
def test_actual_postgres_protocol_classifies_known_retry_states(driver, tmp_path, postgres_fixture, state, expected):
    sql = f"do $$ begin raise exception 'synthetic state fixture' using errcode = '{state}'; end $$"
    result = invoke(driver, "postgres", "query", tmp_path, postgres_fixture[1], sql)
    assert result.returncode != 0
    assert expected in result.stderr
    assert "synthetic state fixture" not in result.stdout + result.stderr

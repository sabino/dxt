"""Native model lifecycle compared with pinned Core on actual DuckDB/Postgres."""
from __future__ import annotations

import ctypes.util
import importlib.metadata
import importlib.util
import json
import os
import shutil
import subprocess
from pathlib import Path
from urllib.parse import unquote, urlparse

import pytest
from test_cli import build_dxt, artifact_validator

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out/bin/dxt"


@pytest.fixture(scope="module")
def postgres_server(tmp_path_factory):
    if not __import__("postgres_fixture").available():
        if os.environ.get("DXT_NATIVE_ADAPTER_CERTIFY") == "1":
            pytest.fail("Native materialization certification requires pgserver")
        pytest.skip("PostgreSQL fixture unavailable")
    import postgres_fixture as pgserver
    with pgserver.get_server(tmp_path_factory.mktemp("materialization-postgres") / "data") as server:
        yield server


def project_at(path, adapter, server=None):
    (path / "models").mkdir(parents=True)
    (path / "dbt_project.yml").write_text("name: materialization_contract\nversion: '1.0'\nconfig-version: 2\nprofile: materialization_contract\n")
    if adapter == "duckdb":
        config = f"      type: duckdb\n      path: {path / 'warehouse.duckdb'}\n      schema: main\n"
    else:
        info = server.get_postmaster_info()
        user = unquote(urlparse(server.get_uri()).username or "postgres")
        config = f"      type: postgres\n      host: {json.dumps(str(info.socket_dir))}\n      port: {info.port}\n      dbname: postgres\n      user: {user}\n      password: ''\n      schema: {path.name}\n"
    (path / "profiles.yml").write_text(f"materialization_contract:\n  target: dev\n  outputs:\n    dev:\n{config}      threads: 1\n")
    return path


def invoke(project, engine="dxt", *arguments):
    env = dict(os.environ, DXT_DUCKDB_BACKEND="native", DBT_SEND_ANONYMOUS_USAGE_STATS="false")
    return subprocess.run([str(DXT) if engine == "dxt" else "dbt", "run", "--project-dir", str(project), "--profiles-dir", str(project), *arguments], env=env, capture_output=True, text=True)


def query(project, adapter, sql, server=None):
    if adapter == "duckdb":
        import duckdb
        with duckdb.connect(str(project / "warehouse.duckdb")) as connection:
            return connection.execute(sql).fetchall()
    import psycopg2
    with psycopg2.connect(server.get_uri()) as connection:
        with connection.cursor() as cursor:
            cursor.execute(f'set search_path to "{project.name}",public')
            cursor.execute(sql)
            return cursor.fetchall() if cursor.description else []


def model(project, body, materialized="table", config=""):
    (project / "models/history.sql").write_text(f"{{{{ config(materialized='{materialized}'{config}) }}}}\n{body}\n")


def successful(result):
    assert result.returncode == 0, result.stdout + result.stderr


def oracle_available(adapter):
    if shutil.which("dbt") is None:
        pytest.skip("Optional pinned dbt oracle unavailable")
    assert importlib.metadata.version("dbt-core") == "1.10.5"
    assert importlib.metadata.version("dbt-duckdb" if adapter == "duckdb" else "dbt-postgres") == ("1.9.6" if adapter == "duckdb" else "1.9.1")


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_core_table_view_first_repeat_switch_and_atomic_error(tmp_path, request, adapter):
    oracle_available(adapter)
    server = request.getfixturevalue("postgres_server") if adapter == "postgres" else None
    projects = [project_at(tmp_path / name, adapter, server) for name in ("native_models", "core_models")]
    for project, engine in zip(projects, ("dxt", "dbt")):
        model(project, "select 1 id, 'first'::text as status_text")
        successful(invoke(project, engine))
        assert query(project, adapter, "select * from history", server) == [(1, "first")]
        model(project, "select id+1 id, 'repeat'::text as status_text from {{ this }}")
        successful(invoke(project, engine))
        assert query(project, adapter, "select * from history", server) == [(2, "repeat")]
        for materialized in ("view", "table"):
            model(project, "select missing_column from nonexistent_source", materialized)
            failed = invoke(project, engine)
            assert failed.returncode != 0
            assert query(project, adapter, "select * from history", server) == [(2, "repeat")]
        model(project, "select 3 id, 'view'::text as status_text", "view")
        successful(invoke(project, engine))
        assert query(project, adapter, "select * from history", server) == [(3, "view")]
        model(project, "select 4 id, 'table'::text as status_text")
        successful(invoke(project, engine))
        successful(invoke(project, engine))
        assert query(project, adapter, "select * from history", server) == [(4, "table")]
        if adapter == "postgres":
            assert query(project, adapter, "select relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname=current_schema() and (relname like '%__dbt_tmp' or relname like '%__dbt_backup')", server) == []
    artifact_validator.assert_artifact(projects[0] / "target/run_results.json")


def test_core_postgres_unlogged_indexes_replacement_and_unique_failure(tmp_path, postgres_server):
    oracle_available("postgres")
    for name, engine in (("native_indexes", "dxt"), ("core_indexes", "dbt")):
        project = project_at(tmp_path / name, "postgres", postgres_server)
        config = ", unlogged=true, sql_header='set local statement_timeout=3000;', indexes=[{'columns':['id'], 'unique':true}, {'columns':['status_text'], 'type':'hash'}]"
        model(project, "select 1 id,'a'::text as status_text", config=config)
        for _ in range(2):
            successful(invoke(project, engine))
            assert query(project, "postgres", "select relpersistence from pg_class where oid='history'::regclass", postgres_server) == [("u",)]
            assert query(project, "postgres", "select a.amname,i.indisunique from pg_index i join pg_class c on c.oid=i.indexrelid join pg_am a on a.oid=c.relam where i.indrelid='history'::regclass order by 1", postgres_server) == [("btree", True), ("hash", False)]
        model(project, "select 1 id,'bad'::text as status_text union all select 1,'duplicate'", config=config)
        assert invoke(project, engine).returncode != 0
        assert query(project, "postgres", "select * from history", postgres_server) == [(1, "a")]


def test_core_postgres_materialized_view_refresh_config_policy_and_full_refresh(tmp_path, postgres_server):
    oracle_available("postgres")
    for name, engine in (("native_mv", "dxt"), ("core_mv", "dbt")):
        project = project_at(tmp_path / name, "postgres", postgres_server)
        query(project, "postgres", f'create schema "{name}"; create table "{name}".input(id integer); insert into "{name}".input values (1)', postgres_server)
        config = ", indexes=[{'columns':['id'], 'unique':true}]"
        model(project, f'select id from "{name}".input', "materialized_view", config)
        successful(invoke(project, engine))
        query(project, "postgres", "insert into input values (2)", postgres_server)
        successful(invoke(project, engine))
        assert query(project, "postgres", "select * from history order by id", postgres_server) == [(1,), (2,)]
        # SQL changes alone refresh the existing definition, matching Core.
        model(project, f'select id+100 id from "{name}".input', "materialized_view", config)
        successful(invoke(project, engine))
        assert query(project, "postgres", "select * from history order by id", postgres_server) == [(1,), (2,)]
        query(project, "postgres", "insert into input values (3)", postgres_server)
        for policy in ("continue", "fail", "apply"):
            model(project, f'select id from "{name}".input', "materialized_view", f", indexes=[], on_configuration_change='{policy}'")
            result = invoke(project, engine)
            if policy == "fail": assert result.returncode != 0
            else: successful(result)
            # Applying only index changes does not refresh in Core 1.10.5.
            assert query(project, "postgres", "select * from history order by id", postgres_server) == [(1,), (2,)]
        successful(invoke(project, engine))
        assert query(project, "postgres", "select * from history order by id", postgres_server) == [(1,), (2,), (3,)]
        model(project, f'select id+100 id from "{name}".input', "materialized_view")
        successful(invoke(project, engine, "--full-refresh"))
        assert query(project, "postgres", "select * from history order by id", postgres_server) == [(101,), (102,), (103,)]
        model(project, f'select missing from "{name}".input', "materialized_view")
        assert invoke(project, engine, "--full-refresh").returncode != 0
        assert query(project, "postgres", "select * from history order by id", postgres_server) == [(101,), (102,), (103,)]
        model(project, "select 5 id", "view")
        successful(invoke(project, engine))
        model(project, "select 6 id", "materialized_view")
        successful(invoke(project, engine))
        assert query(project, "postgres", "select * from history", postgres_server) == [(6,)]


def test_core_postgres_materialized_view_add_index(tmp_path, postgres_server):
    oracle_available("postgres")
    for name, engine in (("native_mv_add", "dxt"), ("core_mv_add", "dbt")):
        project = project_at(tmp_path / name, "postgres", postgres_server)
        model(project, "select 1 id", "materialized_view")
        successful(invoke(project, engine))
        model(project, "select 1 id", "materialized_view", ", indexes=[{'columns':['id'], 'unique':true}], on_configuration_change='apply'")
        successful(invoke(project, engine))
        assert query(project, "postgres", "select indisunique from pg_index where indrelid='history'::regclass", postgres_server) == [(True,)]
        successful(invoke(project, engine))
        assert query(project, "postgres", "select count(*) from pg_index where indrelid='history'::regclass", postgres_server) == [(1,)]
        model(project, "select 1 id", "materialized_view", ", indexes=[{'columns':['id'], 'unique':false, 'type':'hash'}], on_configuration_change='apply'")
        explicit_method = invoke(project, engine)
        if engine == "dbt":
            # Pinned postgres 1.9.1 stores explicit methods as str, then its
            # as_node_config property accesses method.value. Core exposes the
            # resulting AttributeError as Undefined through its Jinja host.
            assert explicit_method.returncode != 0 and "Undefined is not of type 'object'" in explicit_method.stdout
        else:
            successful(explicit_method)
            assert query(project, "postgres", "select a.amname,i.indisunique from pg_index i join pg_class c on c.oid=i.indexrelid join pg_am a on a.oid=c.relam where i.indrelid='history'::regclass", postgres_server) == [("hash", False)]


def test_core_postgres_cross_database_target_is_rejected_without_writes(tmp_path, postgres_server):
    oracle_available("postgres")
    for name, engine in (("native_cross_db", "dxt"), ("core_cross_db", "dbt")):
        project = project_at(tmp_path / name, "postgres", postgres_server)
        model(project, "select 1 id", config=", database='other_database'")
        assert invoke(project, engine).returncode != 0
        assert query(project, "postgres", f"select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='{name}' and c.relname='history'", postgres_server) == [(0,)]

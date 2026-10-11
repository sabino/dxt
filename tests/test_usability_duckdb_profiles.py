"""Actual native connection initialization against pinned dbt-duckdb profiles."""
from __future__ import annotations

import json
import os
import subprocess
import threading

import duckdb
import pytest
import yaml

from test_usability_materializations import (
    DXT, artifact_validator, build_dxt, invoke, oracle_available, project_at,
    query, successful,
)


def profile(project, **options):
    path = project / "profiles.yml"
    value = yaml.safe_load(path.read_text())
    value["materialization_contract"]["outputs"]["dev"].update(options)
    path.write_text(yaml.safe_dump(value, sort_keys=False))


def projects(tmp_path):
    oracle_available("duckdb")
    return [project_at(tmp_path / name, "duckdb") for name in ("native_profile", "core_profile")]


@pytest.mark.parametrize("read_only", [False, True])
def test_attach_alias_options_settings_and_boot_configuration(tmp_path, read_only):
    attached = tmp_path / "attached.duckdb"
    with duckdb.connect(str(attached)) as connection:
        connection.execute("create table inputs as select 7 as id")
    for project, engine in zip(projects(tmp_path), ("dxt", "dbt")):
        profile(project, threads=4, config_options={"default_order": "DESC"},
                settings={"TimeZone": "Europe/Amsterdam", "threads": 2},
                attach=[{"path": str(attached) + "?ignored=yes", "alias": "upstream",
                         "options": {"type": "duckdb", "read_only": read_only}}])
        for index in range(4):
            (project / f"models/observed_{index}.sql").write_text(
                "{{ config(materialized='table') }} select id,"
                "current_setting('TimeZone') as zone, current_setting('threads') as workers,"
                "current_setting('default_order') as ordering from upstream.main.inputs")
        successful(invoke(project, engine))
        for index in range(4):
            assert query(project, "duckdb", f"select * from observed_{index}") == [(7, "Europe/Amsterdam", 2, "DESC")]
        artifact_validator.assert_artifact(project / "target/manifest.json")
        artifact_validator.assert_artifact(project / "target/run_results.json")


def test_attach_read_only_rejects_hook_write_and_preserves_database(tmp_path):
    attached = tmp_path / "protected.duckdb"
    with duckdb.connect(str(attached)) as connection:
        connection.execute("create table inputs as select 7 as id")
    for project, engine in zip(projects(tmp_path), ("dxt", "dbt")):
        profile(project, attach=[{"path": str(attached), "alias": "upstream", "read_only": True}])
        (project / "models/attempt.sql").write_text(
            "{{ config(materialized='table',pre_hook='insert into upstream.main.inputs values(8)') }} select 1 as id")
        result = invoke(project, engine)
        assert result.returncode != 0, result.stdout + result.stderr
        with duckdb.connect(str(attached)) as connection:
            assert connection.execute("select * from inputs").fetchall() == [(7,)]
        assert query(project, "duckdb", "select table_name from information_schema.tables where table_name='attempt'") == []


def test_local_secret_metadata_private_target_and_cache_invalidation(tmp_path):
    for project, engine in zip(projects(tmp_path), ("dxt", "dbt")):
        secret = "synthetic-native-profile-token"
        profile(project, secrets=[{"type": "http", "name": "local_only", "bearer_token": secret,
                                   "scope": "https://example.invalid", "persistent": False}])
        (project / "models/metadata.sql").write_text(
            "{{ config(materialized='table') }} select name,type,provider,persistent,scope,"
            "{{ 'false' if target.secrets is defined else 'true' }} as private_target,"
            "'{{ target.absent_profile_key | default(\"missing\") }}' as missing "
            "from duckdb_secrets()")
        successful(invoke(project, engine))
        assert query(project, "duckdb", "select * from metadata") == [
            ("local_only", "http", "config", False, ["https://example.invalid"], True, "missing")]
        if engine == "dxt":
            cache = project / "target/dxt_parse_cache.json"
            before = json.loads(cache.read_text())["fingerprint"]
            for artifact in (project / "target").glob("*.json"):
                assert secret not in artifact.read_text()
            profile(project, secrets=[{"type": "http", "name": "local_only", "bearer_token": secret + "-changed",
                                       "scope": "https://example.invalid", "persistent": False}])
            successful(invoke(project, engine))
            assert json.loads(cache.read_text())["fingerprint"] != before
            for artifact in (project / "target").glob("*.json"):
                assert secret not in artifact.read_text()


@pytest.mark.parametrize("keep_open", [True, False])
def test_global_secret_initialization_matches_connection_lifetime(tmp_path, keep_open):
    observed = []
    for project, engine in zip(projects(tmp_path), ("dxt", "dbt")):
        profile(project, keep_open=keep_open, secrets=[{"type": "http", "name": "local_only", "bearer_token": "synthetic-token",
                                   "scope": "https://example.invalid/initial"}])
        (project / "models/change.sql").write_text(
            "{{ config(materialized='table',pre_hook=\"create or replace secret local_only "
            "(type http,bearer_token 'synthetic-token',scope 'https://example.invalid/changed')\") }} select 1 as id")
        (project / "models/observe.sql").write_text(
            "{{ config(materialized='table') }} select scope from duckdb_secrets(),{{ ref('change') }}")
        successful(invoke(project, engine))
        observed.append(query(project, "duckdb", "select * from observe"))
    assert observed[0] == observed[1]
    if keep_open:
        assert observed[0] == [(["https://example.invalid/changed"],)]


@pytest.mark.parametrize("materialized", ["table", "external", "table_function"])
def test_disabled_transactions_commit_sql_before_failed_inner_hook(tmp_path, materialized):
    pair = projects(tmp_path)
    for project, engine in zip(pair, ("dxt", "dbt")):
        profile(project, disable_transactions=True)
        location = f",location='{project / 'history.parquet'}'" if materialized == "external" else ""
        call = "()" if materialized == "table_function" else ""
        (project / "models/history.sql").write_text(
            "{{ config(materialized='" + materialized + "'" + location +
            ",pre_hook='create table if not exists events(id integer)',"
            "post_hook='insert into events select id from {{ this }}" + call + "') }} select 1 as id")
        successful(invoke(project, engine))
        assert query(project, "duckdb", "select * from history" + call) == [(1,)]
    original = (pair[0] / "history.parquet").read_bytes() if materialized == "external" else None
    for project, engine in zip(pair, ("dxt", "dbt")):
        location = f",location='{project / 'history.parquet'}'" if materialized == "external" else ""
        (project / "models/history.sql").write_text(
            "{{ config(materialized='" + materialized + "'" + location +
            ",pre_hook='insert into events values(99)',post_hook='select * from missing_inner_hook') }} select 2 as id" +
            (",'new schema' as payload" if materialized == "external" else ""))
        result = invoke(project, engine)
        assert result.returncode != 0, result.stdout + result.stderr
        assert query(project, "duckdb", "select * from events order by id") == [(1,), (99,)]
        if materialized != "external":
            assert query(project, "duckdb", "select * from history" + call) == [(2,)]
    if materialized == "external":
        # The committed new view schema requires the published new file, even
        # when its inner post-hook fails. Both engines retain autocommit output.
        assert (pair[0] / "history.parquet").read_bytes() != original
        for project in pair:
            assert query(project, "duckdb", "select * from history") == [(2, "new schema")]


def test_missing_target_chained_attribute_remains_a_compile_error(tmp_path):
    for project, engine in zip(projects(tmp_path), ("dxt", "dbt")):
        (project / "models/attempt.sql").write_text("select '{{ target.absent_profile_key.child }}' as value")
        result = invoke(project, engine)
        assert result.returncode != 0, result.stdout + result.stderr


def test_native_profile_connections_work_without_cli_on_path(tmp_path):
    project = project_at(tmp_path / "native_empty_path", "duckdb")
    profile(project, settings={"TimeZone": "Europe/Amsterdam"},
            secrets=[{"type": "http", "name": "native_only", "bearer_token": "synthetic-token"}])
    (project / "models/metadata.sql").write_text(
        "{{ config(materialized='table') }} select name,current_setting('TimeZone') as zone from duckdb_secrets()")
    result = subprocess.run([str(DXT), "run", "--project-dir", str(project), "--profiles-dir", str(project)],
                            env=dict(os.environ, PATH="", DXT_DUCKDB_BACKEND="native"), capture_output=True, text=True)
    successful(result)
    assert query(project, "duckdb", "select * from metadata") == [("native_only", "Europe/Amsterdam")]


def test_native_profile_retries_real_typed_query_errors_like_core(tmp_path):
    for project, engine in zip(projects(tmp_path), ("dxt", "dbt")):
        profile(project, disable_transactions=True,
                retries={"connect_attempts": 2, "query_attempts": 2,
                         "retryable_exceptions": ["InvalidInputException"]})
        (project / "models/retried.sql").write_text(
            "{{ config(materialized='table',pre_hook=[\"create sequence retry_counter\","
            "\"select case when nextval('retry_counter')=1 then error('synthetic transient') else 1 end\"]) }} "
            "select currval('retry_counter') as attempts")
        successful(invoke(project, engine))
        assert query(project, "duckdb", "select * from retried") == [(2,)]


def test_native_profile_connect_retries_a_real_writer_lock_like_core(tmp_path):
    for project, engine in zip(projects(tmp_path), ("dxt", "dbt")):
        profile(project, retries={"connect_attempts": 3})
        (project / "models/observed.sql").write_text(
            "{{ config(materialized='table') }} select * from existing")
        connection = duckdb.connect(str(project / "warehouse.duckdb"))
        connection.execute("create table existing as select 7 as id")
        # A separate native process must wait until this writer releases the
        # actual file lock. Query retries are left disabled in this profile.
        release = threading.Timer(1.5, connection.close)
        release.start()
        try:
            successful(invoke(project, engine))
        finally:
            release.join()
            connection.close()
        assert query(project, "duckdb", "select * from observed") == [(7,)]


def test_memory_database_keeps_profile_state_when_keep_open_is_false(tmp_path):
    observed = []
    for project, engine in zip(projects(tmp_path), ("dxt", "dbt")):
        profile(project, path=":memory:", keep_open=False,
                settings={"TimeZone": "Europe/Amsterdam"},
                secrets=[{"type": "http", "name": "local_only", "bearer_token": "synthetic-token",
                          "scope": "https://example.invalid/initial"}])
        (project / "models/change.sql").write_text(
            "{{ config(materialized='table',pre_hook=\"create or replace secret local_only "
            "(type http,bearer_token 'synthetic-token',scope 'https://example.invalid/changed')\") }} select 1 as id")
        (project / "models/observe.sql").write_text(
            "{{ config(materialized='table',post_hook=\"copy (select * from {{ this }}) to '" +
            str(project / "observed.csv") + "' (header,delimiter ',')\") }} "
            "select scope[1] as scope,current_setting('TimeZone') as zone from duckdb_secrets(),{{ ref('change') }}")
        successful(invoke(project, engine))
        observed.append((project / "observed.csv").read_text())
        assert not (project / "warehouse.duckdb").exists()
    assert observed == ["scope,zone\nhttps://example.invalid/changed,Europe/Amsterdam\n"] * 2


@pytest.mark.parametrize("options", [
    {"settings": {"no_such_native_setting": 1}},
    {"config_options": {"no_such_native_option": True}},
    {"attach": [{"path": ":memory:", "read_only": True, "options": {"read_only": True}}]},
    {"extensions": [{"name": "missing_profile_extension", "repo": "/nonexistent/local/repository"}]},
    {"extensions": ["/nonexistent/local_profile.duckdb_extension"]},
    {"secrets": [{"type": "http", "name": "invalid_local", "unknown_option": "synthetic-secret-value"}]},
])
def test_invalid_native_options_fail_visibly_like_core(tmp_path, options):
    for project, engine in zip(projects(tmp_path), ("dxt", "dbt")):
        profile(project, **options)
        (project / "models/attempt.sql").write_text("select 1 as id")
        result = invoke(project, engine)
        assert result.returncode != 0, result.stdout + result.stderr
        if engine == "dxt":
            assert "synthetic-secret-value" not in result.stdout + result.stderr


@pytest.mark.parametrize("options", [
    {"plugins": [{"module": "dbt.adapters.duckdb.plugins.excel"}]},
    {"filesystems": [{"fs": "file"}]},
    {"module_paths": ["/nonexistent/python/modules"]},
    {"remote": {"host": "example.invalid", "port": 1, "user": "synthetic"}},
])
def test_unavailable_python_profiles_fail_before_opening_warehouse(tmp_path, options):
    project = project_at(tmp_path / "unsupported_profile", "duckdb")
    profile(project, **options)
    (project / "models/attempt.sql").write_text("select 1 as id")
    result = invoke(project)
    assert result.returncode != 0, result.stdout + result.stderr
    assert not (project / "warehouse.duckdb").exists()
    assert "UnsupportedDuckDb" in result.stdout + result.stderr

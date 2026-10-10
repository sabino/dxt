from __future__ import annotations

import json
import shutil
import subprocess
from importlib.metadata import version
from pathlib import Path

import pytest

from test_cli import ROOT, DXT, build_dxt, dbt_protobuf_json_compat


@pytest.fixture
def incremental_oracle(monkeypatch):
    from dbt.cli.main import dbtRunner
    import dbt_common.events.base_types as event_types
    from google.protobuf import json_format

    assert version("dbt-core") == "1.10.5"
    assert version("dbt-duckdb") == "1.9.6"
    assert shutil.which("duckdb"), "DuckDB CLI is required for incremental execution"
    monkeypatch.setenv("DBT_SEND_ANONYMOUS_USAGE_STATS", "false")
    wrapper = dbt_protobuf_json_compat(json_format.MessageToJson)
    monkeypatch.setattr(json_format, "MessageToJson", wrapper)
    monkeypatch.setattr(event_types, "MessageToJson", wrapper)
    return dbtRunner()


def warehouse(path: Path, sql: str):
    result = subprocess.run(
        ["duckdb", str(path), "-json", "-batch", "-bail", "-c", sql],
        text=True,
        capture_output=True,
        cwd=ROOT,
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout) if result.stdout.strip() else []


class Pair:
    def __init__(self, root: Path, oracle):
        self.oracle = oracle
        self.projects = [root / "dxt", root / "core"]
        self.databases = []
        for project in self.projects:
            (project / "models").mkdir(parents=True)
            database = project / "warehouse.duckdb"
            self.databases.append(database)
            (project / "dbt_project.yml").write_text(
                'name: incremental_fixture\nversion: "1.0"\nprofile: incremental_fixture\n'
                'model-paths: ["models"]\ntarget-path: target\n'
            )
            (project / "profiles.yml").write_text(
                "incremental_fixture:\n  target: dev\n  outputs:\n    dev:\n"
                "      type: duckdb\n      schema: main\n      threads: 1\n      keep_open: true\n"
                f"      path: {database}\n"
            )
            warehouse(database, "create schema raw; create table raw.events(id integer, tenant varchar, value varchar, updated integer); insert into raw.events values (1, 'a', '10', 1), (2, 'b', '20', 2)")

    def write_sql(self, sql: str):
        for project in self.projects:
            (project / "models/events.sql").write_text(sql)

    def mutate(self, sql: str):
        for database in self.databases:
            warehouse(database, sql)

    def run(self, command="run", full_refresh=False, success=True, core_success=None):
        dxt_project, core_project = self.projects
        extra = ["--full-refresh"] if full_refresh else []
        actual = subprocess.run(
            [DXT, command, "--project-dir", str(dxt_project), "--profiles-dir", str(dxt_project), *extra],
            text=True, capture_output=True, cwd=ROOT,
        )
        expected = self.oracle.invoke([
            command, "--project-dir", str(core_project), "--profiles-dir", str(core_project),
            "--target-path", str(core_project / "target"), "--no-partial-parse", "--quiet", *extra,
        ])
        from dbt.adapters.factory import reset_adapters
        from dbt.adapters.duckdb.connections import DuckDBConnectionManager
        reset_adapters()
        if DuckDBConnectionManager._ENV is not None:
            DuckDBConnectionManager._ENV.close()
            DuckDBConnectionManager._ENV = None
        if core_success is None:
            core_success = success
        assert expected.success is core_success, expected.exception
        assert (actual.returncode == 0) is success, actual.stderr
        if command != "compile":
            actual_rows = json.loads((dxt_project / "target/run_results.json").read_text())["results"]
            expected_rows = json.loads((core_project / "target/run_results.json").read_text())["results"]
            if success == core_success:
                assert [(row["unique_id"], row["status"]) for row in actual_rows] == [(row["unique_id"], row["status"]) for row in expected_rows]
            else:
                assert [(row["unique_id"], row["status"]) for row in actual_rows] == [("model.incremental_fixture.events", "success")]
                assert [(row["unique_id"], row["status"]) for row in expected_rows] == [("model.incremental_fixture.events", "error")]
                assert "another transaction has altered this table" in expected_rows[0]["message"]
        if success:
            actual_node = json.loads((dxt_project / "target/manifest.json").read_text())["nodes"]["model.incremental_fixture.events"]
            expected_node = json.loads((core_project / "target/manifest.json").read_text())["nodes"]["model.incremental_fixture.events"]
            assert actual_node["compiled_code"].strip() == expected_node["compiled_code"].strip()
            keys = ["materialized", "unique_key", "incremental_strategy", "on_schema_change", "full_refresh", "incremental_predicates"]
            assert {key: actual_node["config"].get(key) for key in keys} == {key: expected_node["config"].get(key) for key in keys}
        self.assert_clean_stage()
        return actual

    def equal(self, sql="select * from main.events order by id, value"):
        actual, expected = [warehouse(database, sql) for database in self.databases]
        assert actual == expected
        actual_columns, expected_columns = [warehouse(database, "select column_name, data_type from information_schema.columns where table_schema='main' and table_name='events' order by ordinal_position") for database in self.databases]
        assert actual_columns == expected_columns
        return actual

    def assert_clean_stage(self):
        assert warehouse(self.databases[0], "select table_name from information_schema.tables where table_name like '__dxt_incremental_%'") == []


@pytest.mark.parametrize("strategy,key", [(None, None), (None, "'id'"), ("append", "'id'"), ("delete+insert", "'id'"), ("delete+insert", "['id', 'tenant']")])
def test_incremental_first_repeated_mutation_and_full_refresh(tmp_path, incremental_oracle, strategy, key):
    pair = Pair(tmp_path, incremental_oracle)
    kwargs = ["materialized='incremental'"]
    if strategy:
        kwargs.append(f"incremental_strategy='{strategy}'")
    if key:
        kwargs.append(f"unique_key={key}")
    pair.write_sql("{{ config(" + ", ".join(kwargs) + ") }}\nselect * from raw.events\n{% if is_incremental() %}where updated > (select coalesce(max(updated), 0) from main.events){% endif %}\n")
    pair.run()
    assert len(pair.equal()) == 2
    pair.run(command="compile")
    pair.run(command="compile", full_refresh=True)
    assert len(pair.equal()) == 2
    pair.run()
    assert len(pair.equal()) == 2
    pair.mutate("update raw.events set value='11', updated=3 where id=1; delete from raw.events where id=2; insert into raw.events values (3,'c','30',4)")
    pair.run(command="build")
    rows = pair.equal()
    assert len(rows) == (4 if key is None or strategy == "append" else 3)
    pair.run(full_refresh=True)
    rows = pair.equal()
    assert [(row["id"], row["value"]) for row in rows] == [(1, "11"), (3, "30")]


@pytest.mark.parametrize("policy", ["ignore", "fail", "append_new_columns", "sync_all_columns"])
@pytest.mark.parametrize("drop_old", [False, True])
def test_incremental_schema_addition_and_removal(tmp_path, incremental_oracle, policy, drop_old):
    pair = Pair(tmp_path, incremental_oracle)
    config = f"{{{{ config(materialized='incremental', unique_key='id', on_schema_change='{policy}') }}}}\n"
    pair.write_sql(config + "select id, value from raw.events")
    pair.run()
    pair.mutate("insert into raw.events values (3,'c','30',3)")
    projection = "id, 7 as added" if drop_old else "id, value, 7 as added"
    pair.write_sql(config + f"select {projection} from raw.events where id=3")
    success = policy != "fail" and not (policy == "ignore" and drop_old)
    pair.run(success=success)
    rows = pair.equal("select * from main.events order by id")
    assert len(rows) == (3 if success else 2)
    if success and policy in ("append_new_columns", "sync_all_columns"):
        assert [row["added"] for row in rows] == [None, None, 7]


@pytest.mark.parametrize("policy", ["ignore", "fail", "append_new_columns"])
def test_incremental_schema_type_changes(tmp_path, incremental_oracle, policy):
    pair = Pair(tmp_path, incremental_oracle)
    config = f"{{{{ config(materialized='incremental', unique_key='id', on_schema_change='{policy}') }}}}\n"
    pair.write_sql(config + "select id, value from raw.events")
    pair.run()
    pair.mutate("insert into raw.events values (3,'c','30',3)")
    pair.write_sql(config + "select id::bigint as id, value::integer as value from raw.events where id=3")
    pair.run(success=policy != "fail")
    rows = pair.equal("select * from main.events order by id")
    assert len(rows) == (2 if policy == "fail" else 3)


@pytest.mark.parametrize("override", [True, False])
def test_incremental_model_refresh_override_and_flag_effect(tmp_path, incremental_oracle, override):
    pair = Pair(tmp_path, incremental_oracle)
    pair.write_sql("{{ config(materialized='incremental', unique_key='id', full_refresh=" + str(override).lower() + ") }}\nselect * from raw.events")
    pair.run()
    pair.mutate("delete from raw.events where id=2; update raw.events set value='changed' where id=1")
    pair.run(full_refresh=not override)
    rows = pair.equal()
    assert len(rows) == (1 if override else 2)


def test_incremental_failed_insert_rolls_back_delete_schema_change_and_staging(tmp_path, incremental_oracle):
    pair = Pair(tmp_path, incremental_oracle)
    config = "{{ config(materialized='incremental', unique_key='id', on_schema_change='append_new_columns') }}\n"
    pair.write_sql(config + "select id, value::integer as value from raw.events")
    pair.run()
    pair.write_sql(config + "select 1 as id, 'bad integer' as value, 7 as added")
    pair.run(success=False)
    assert pair.equal("select * from main.events order by id") == [{"id": 1, "value": 10}, {"id": 2, "value": 20}]
    pair.write_sql(config + "select 1 as id, 11 as value")
    pair.run()
    assert pair.equal("select * from main.events order by id")[0]["value"] == 11


def test_incremental_failed_full_refresh_preserves_existing_table(tmp_path, incremental_oracle):
    pair = Pair(tmp_path, incremental_oracle)
    pair.write_sql("{{ config(materialized='incremental', unique_key='id') }}\nselect id, value::integer as value from raw.events")
    pair.run()
    pair.write_sql("{{ config(materialized='incremental', unique_key='id') }}\nselect 1 as id, 'bad integer'::integer as value")
    pair.run(full_refresh=True, success=False)
    assert pair.equal("select * from main.events order by id") == [{"id": 1, "value": 10}, {"id": 2, "value": 20}]


def test_incremental_view_replacement_uses_initial_context(tmp_path, incremental_oracle):
    pair = Pair(tmp_path, incremental_oracle)
    pair.mutate("create view main.events as select id, value from raw.events")
    pair.write_sql("{{ config(materialized='incremental', unique_key='id') }}\nselect id, value from raw.events{% if is_incremental() %} where false{% endif %}")
    pair.run()
    assert len(pair.equal("select * from main.events order by id")) == 2
    assert warehouse(pair.databases[0], "select table_type from information_schema.tables where table_schema='main' and table_name='events'") == [{"table_type": "BASE TABLE"}]


@pytest.mark.parametrize("location", ["project", "yaml"])
def test_incremental_config_locations_and_inline_precedence(tmp_path, incremental_oracle, location):
    pair = Pair(tmp_path, incremental_oracle)
    for project in pair.projects:
        if location == "project":
            with (project / "dbt_project.yml").open("a") as handle:
                handle.write("models:\n  incremental_fixture:\n    +materialized: incremental\n    +unique_key:\n      - id\n      - tenant\n    +on_schema_change: append_new_columns\n    +incremental_strategy: append\n")
        else:
            (project / "models/schema.yml").write_text("version: 2\nmodels:\n  - name: events\n    config:\n      materialized: incremental\n      unique_key:\n        - id\n        - tenant\n      on_schema_change: append_new_columns\n      incremental_strategy: append\n")
    pair.write_sql("{{ config(incremental_strategy='delete+insert') }}\nselect * from raw.events")
    pair.run()
    pair.mutate("update raw.events set value='changed' where id=1")
    pair.run()
    rows = pair.equal()
    assert len(rows) == 2
    assert rows[0]["value"] == "changed"


def test_incremental_composite_key_nulls_and_delete_predicate(tmp_path, incremental_oracle):
    pair = Pair(tmp_path, incremental_oracle)
    pair.write_sql("{{ config(materialized='incremental', unique_key=['id', 'tenant'], incremental_predicates=['DBT_INCREMENTAL_TARGET.updated > 1']) }}\nselect * from raw.events")
    pair.run()
    pair.mutate("update raw.events set value='changed', updated=3 where id=1; insert into raw.events values (4,null,'40',4)")
    pair.run()
    pair.run()
    rows = pair.equal("select * from main.events order by id, value, updated")
    assert len(rows) == 5
    assert len([row for row in rows if row["id"] == 4]) == 2


def test_incremental_sync_type_changes_are_atomic_and_avoid_core_transaction_bug(tmp_path, incremental_oracle):
    pair = Pair(tmp_path, incremental_oracle)
    config = "{{ config(materialized='incremental', unique_key='id', on_schema_change='sync_all_columns') }}\n"
    pair.write_sql(config + "select id, value from raw.events")
    pair.run()
    pair.mutate("insert into raw.events values (3,'c','30',3)")
    pair.write_sql(config + "select id::bigint as id, value::integer as value from raw.events where id=3")
    # Core 1.10.5/dbt-duckdb 1.9.6's copy/update/drop implementation fails
    # COMMIT. Native ALTER TYPE supports the intended policy atomically.
    pair.run(success=True, core_success=False)
    assert warehouse(pair.databases[0], "select * from main.events order by id") == [
        {"id": 1, "value": 10}, {"id": 2, "value": 20}, {"id": 3, "value": 30}
    ]
    assert warehouse(pair.databases[1], "select * from main.events order by id") == [
        {"id": 1, "value": "10"}, {"id": 2, "value": "20"}
    ]
    assert warehouse(pair.databases[0], "select column_name,data_type from information_schema.columns where table_schema='main' and table_name='events' order by ordinal_position") == [
        {"column_name": "id", "data_type": "BIGINT"}, {"column_name": "value", "data_type": "INTEGER"}
    ]
    # Store a nonnumeric value, then verify an invalid type conversion rolls back.
    pair.write_sql(config + "select id::bigint as id, 'cannot cast' as value from raw.events where id=3")
    actual = subprocess.run([DXT, "run", "--project-dir", str(pair.projects[0]), "--profiles-dir", str(pair.projects[0])], text=True, capture_output=True, cwd=ROOT)
    assert actual.returncode == 0, actual.stderr
    pair.write_sql(config + "select id::bigint as id, value::integer as value from raw.events")
    actual = subprocess.run([DXT, "run", "--project-dir", str(pair.projects[0]), "--profiles-dir", str(pair.projects[0])], text=True, capture_output=True, cwd=ROOT)
    assert actual.returncode == 1
    assert warehouse(pair.databases[0], "select value from main.events where id=3") == [{"value": "cannot cast"}]
    assert warehouse(pair.databases[0], "select data_type from information_schema.columns where table_schema='main' and table_name='events' and column_name='value'") == [{"data_type": "VARCHAR"}]
    pair.assert_clean_stage()
    # Full refresh reconciles both engines to the same schema and relation contents.
    pair.run(full_refresh=True)
    assert len(pair.equal("select * from main.events order by id")) == 3


def test_incremental_nullable_config_uses_defaults_and_refresh_flag(tmp_path, incremental_oracle):
    pair = Pair(tmp_path, incremental_oracle)
    pair.write_sql("{{ config(materialized='incremental', unique_key=None, incremental_strategy=None, on_schema_change=None, full_refresh=None, incremental_predicates=None) }}\nselect * from raw.events")
    pair.run()
    pair.run()
    assert len(pair.equal()) == 4
    pair.run(full_refresh=True)
    assert len(pair.equal()) == 2

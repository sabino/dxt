"""Actual PostgreSQL incremental strategy and atomicity oracle comparisons."""
from __future__ import annotations
import hashlib
import json

import pytest
from test_usability_materializations import (
    artifact_validator, build_dxt, invoke, model, oracle_available,
    postgres_server, project_at, query, successful,
)


class Pair:
    def __init__(self, tmp_path, server):
        oracle_available("postgres")
        self.server = server
        suffix = hashlib.md5(str(tmp_path).encode()).hexdigest()[:8]
        self.projects = [project_at(tmp_path / f"{prefix}_inc_{suffix}", "postgres", server) for prefix in ("native", "core")]
        for project in self.projects:
            self.query(project, f'create schema "{project.name}"; create table "{project.name}".raw_events(id integer,tenant integer,payload text,updated integer); insert into "{project.name}".raw_events values(1,1,\'a\',1),(2,1,\'b\',2),(null,1,\'null-key\',2)')

    def query(self, project, sql):
        return query(project, "postgres", sql, self.server)

    def mutate(self, sql):
        for project in self.projects: self.query(project, sql)

    def write(self, config="", body=None):
        for project in self.projects:
            select = body or f'select * from "{project.name}".raw_events {{% if is_incremental() %}}where updated>(select coalesce(max(updated),0) from {{{{ this }}}}){{% endif %}}'
            model(project, select.replace("$SCHEMA", f'"{project.name}"'), "incremental", config)

    def run(self, *args, success=True):
        results = [invoke(project, engine, *args) for project, engine in zip(self.projects, ("dxt", "dbt"))]
        for result in results:
            if success: successful(result)
            else: assert result.returncode != 0, result.stdout + result.stderr
        for project in self.projects: artifact_validator.assert_artifact(project / "target/run_results.json")

    def rows(self):
        actual = [self.query(project, "select * from history order by id nulls last,tenant,payload,updated") for project in self.projects]
        assert actual[0] == actual[1]
        return actual[0]

    def columns(self):
        values = [self.query(project, "select a.attname,format_type(a.atttypid,a.atttypmod) from pg_attribute a where a.attrelid='history'::regclass and a.attnum>0 and not a.attisdropped order by a.attnum") for project in self.projects]
        assert values[0] == values[1]
        return values[0]


@pytest.mark.parametrize("strategy,key", [("default", None),("default", "'id'"),("append", "'id'"),("delete+insert", "['id','tenant']"),("merge", "['id','tenant']")])
def test_postgres_incremental_first_repeat_mutation_null_keys_and_full_refresh(tmp_path, postgres_server, strategy, key):
    pair = Pair(tmp_path, postgres_server)
    pair.write(f", incremental_strategy='{strategy}'" + (f", unique_key={key}" if key else ""))
    pair.run()
    before = pair.rows()
    pair.run()
    assert pair.rows() == before
    pair.mutate("update raw_events set payload='changed',updated=3 where id=1; update raw_events set payload='new-null',updated=5 where id is null; delete from raw_events where id=2; insert into raw_events values(3,1,'new',4)")
    pair.run()
    assert any(row[2] == "changed" for row in pair.rows())
    pair.run("--full-refresh")
    assert len(pair.rows()) == 3
    node = json.loads((pair.projects[0] / "target/manifest.json").read_text())["nodes"]["model.materialization_contract.history"]
    assert node["config"]["incremental_strategy"] == strategy


@pytest.mark.parametrize("policy", ["ignore", "append_new_columns", "sync_all_columns", "fail"])
def test_postgres_incremental_schema_changes_and_atomic_failures(tmp_path, postgres_server, policy):
    pair = Pair(tmp_path, postgres_server)
    config = f", unique_key='id', on_schema_change='{policy}'"
    pair.write(config)
    pair.run()
    before = pair.rows()
    columns = pair.columns()
    pair.mutate("alter table raw_events add column extra bigint; update raw_events set extra=10,updated=3")
    pair.run(success=policy != "fail")
    if policy == "fail":
        assert pair.rows() == before and pair.columns() == columns
    else:
        pair.rows()
        assert ("extra", "bigint") in pair.columns() if policy != "ignore" else ("extra", "bigint") not in pair.columns()
    # Failed casts happen while staging, before any target data/schema changes.
    before = pair.rows()
    columns = pair.columns()
    pair.write(config, "select id,tenant,'bad integer'::integer payload,updated from $SCHEMA.raw_events")
    pair.run(success=False)
    assert pair.rows() == before and pair.columns() == columns
    pair.run("--full-refresh", success=False)
    assert pair.rows() == before and pair.columns() == columns


@pytest.mark.parametrize("update_config", ["merge_update_columns=['payload','updated']", "merge_exclude_columns=['tenant']"])
def test_postgres_merge_column_controls_and_predicates(tmp_path, postgres_server, update_config):
    pair = Pair(tmp_path, postgres_server)
    pair.write(f", unique_key='id', incremental_strategy='merge', {update_config}, incremental_predicates=['DBT_INTERNAL_DEST.id > 0']")
    pair.run()
    pair.mutate("update raw_events set payload='changed',tenant=2,updated=3 where id=1")
    pair.run()
    rows = pair.rows()
    assert next(row for row in rows if row[0] == 1) == (1,1,"changed",3)


def test_postgres_incremental_type_sync_matches_core_column_order(tmp_path, postgres_server):
    pair = Pair(tmp_path, postgres_server)
    pair.write(", unique_key='id', on_schema_change='sync_all_columns'")
    pair.run()
    pair.mutate("alter table raw_events alter column id type bigint; alter table raw_events drop column tenant; update raw_events set updated=3")
    pair.run()
    assert pair.columns() == [("payload", "text"),("updated", "integer"),("id", "bigint")]
    actual = [pair.query(project, "select id,payload,updated from history order by id nulls last,payload") for project in pair.projects]
    assert actual[0] == actual[1]


def test_postgres_incremental_failed_delete_insert_restores_rows_and_columns(tmp_path, postgres_server):
    pair = Pair(tmp_path, postgres_server)
    pair.write(", unique_key='id', on_schema_change='append_new_columns', indexes=[{'columns':['id'],'unique':true}]")
    pair.run()
    before = pair.rows()
    columns = pair.columns()
    pair.mutate("alter table raw_events add column extra integer; insert into raw_events values(1,1,'duplicate',3,7),(1,1,'duplicate2',3,8)")
    pair.run(success=False)
    assert pair.rows() == before and pair.columns() == columns
    for project in pair.projects:
        assert pair.query(project, "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname=current_schema() and c.relname like '__dxt_incremental_%'") == [(0,)]


def test_postgres_incremental_character_widening_precedes_schema_policy(tmp_path, postgres_server):
    pair = Pair(tmp_path, postgres_server)
    pair.mutate("alter table raw_events alter column payload type varchar(12)")
    pair.write(", unique_key='id', on_schema_change='ignore'")
    pair.run()
    pair.mutate("alter table raw_events alter column payload type varchar(30); update raw_events set payload='longer than twelve chars',updated=3 where id=1")
    pair.run()
    pair.rows()
    assert pair.columns() == [("id", "integer"),("tenant", "integer"),("updated", "integer"),("payload", "character varying(30)")]

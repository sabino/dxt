"""Native PostgreSQL SCD2 relation contents against the pinned dbt oracle."""
from __future__ import annotations
import datetime
import hashlib
import json
import os
import subprocess

import pytest
from test_usability_materializations import (
    DXT, artifact_validator, build_dxt, oracle_available,
    postgres_server, project_at, query, successful,
)


class Pair:
    def __init__(self, path, server, strategy="timestamp", deletes="ignore", extra="", updated_at="ts"):
        oracle_available("postgres")
        self.server = server
        self.strategy = strategy
        suffix = hashlib.md5(str(path).encode()).hexdigest()[:8]
        self.projects = [project_at(path / f"{prefix}_scd_{suffix}", "postgres", server) for prefix in ("native", "core")]
        for project in self.projects:
            (project / "snapshots").mkdir()
            self.query(project, f'create schema "{project.name}"; create table "{project.name}".input(id integer,name varchar(12),ts timestamp); insert into "{project.name}".input values(1,\'Alice\',\'2020-01-01\'),(2,null,\'2020-01-02\')')
            settings = f"strategy='{strategy}',unique_key='id',target_schema='{project.name}_archive',hard_deletes='{deletes}'"
            if updated_at: settings += f",updated_at='{updated_at}'"
            if strategy == "check": settings += ",check_cols='all'"
            settings += extra
            (project / "snapshots/history.sql").write_text("{% snapshot history %}\n{{ config(" + settings + ") }}\nselect * from \"" + project.name + "\".input -- trailing comment\n{% endsnapshot %}\n")

    def query(self, project, sql):
        return query(project, "postgres", sql, self.server)

    def mutate(self, sql):
        for project in self.projects: self.query(project, sql)

    def invoke(self, project, engine, command="snapshot", *args):
        return subprocess.run([str(DXT) if engine == "dxt" else "dbt", command, "--project-dir", str(project), "--profiles-dir", str(project), *args], env=dict(os.environ, DBT_SEND_ANONYMOUS_USAGE_STATS="false"), capture_output=True, text=True)

    def run(self, success=True):
        results = [self.invoke(project, engine) for project, engine in zip(self.projects, ("dxt", "dbt"))]
        for result in results:
            if success: successful(result)
            else: assert result.returncode != 0, result.stdout + result.stderr
        for project in self.projects:
            artifact = project / "target/run_results.json"
            artifact_validator.assert_artifact(artifact)
            rows = json.loads(artifact.read_text())["results"]
            assert [(row["unique_id"], row["status"]) for row in rows] == [("snapshot.materialization_contract.history", "success" if success else "error")]

    def rows(self, project):
        relation = f'"{project.name}_archive".history'
        columns = self.query(project, f"select attname from pg_attribute where attrelid='{relation}'::regclass and attnum>0 and not attisdropped order by attnum")
        values = self.query(project, f"select * from {relation} order by id,dbt_valid_from,dbt_scd_id")
        return [dict(zip([name[0] for name in columns], row)) for row in values]

    def compare(self):
        actual = [self.rows(project) for project in self.projects]
        assert normalized(actual[0]) == normalized(actual[1])
        for project in self.projects:
            relation = f'"{project.name}_archive".history'
            # PostgreSQL's own text cast defines the exact timestamp hash input.
            clause = " where dbt_is_deleted='False'" if actual[0] and "dbt_is_deleted" in actual[0][0] else ""
            assert self.query(project, f"select count(*) from {relation}{clause}" + (" and" if clause else " where") + " dbt_scd_id<>md5(coalesce(id::varchar,'') || '|' || coalesce(dbt_updated_at::varchar,''))") == [(0,)]
            if clause:
                assert self.query(project, f"select count(*) from {relation} t where t.dbt_is_deleted='True' and not exists(select 1 from {relation} p where p.id is not distinct from t.id and p.dbt_valid_to=t.dbt_updated_at and t.dbt_scd_id=md5(coalesce(p.dbt_scd_id::varchar,'') || '|' || t.dbt_updated_at::varchar))") == [(0,)]
        return actual[0]


def normalized(rows):
    fields = ("dbt_updated_at", "dbt_valid_from", "dbt_valid_to")
    clocks = sorted({row[field] for row in rows for field in fields if isinstance(row.get(field), datetime.datetime) and 2025 <= row[field].year < 9000})
    clock_map = {clock: f"CLOCK_{i}" for i, clock in enumerate(clocks)}
    result = []
    for row in rows:
        copy = dict(row)
        if any(copy.get(field) in clock_map for field in fields):
            if copy.get("dbt_updated_at") in clock_map: copy["dbt_scd_id"] = "CLOCK_HASH"
            for field in fields:
                if copy.get(field) in clock_map: copy[field] = clock_map[copy[field]]
        result.append(copy)
    return result


@pytest.mark.parametrize("strategy", ["timestamp", "check"])
@pytest.mark.parametrize("deletes", ["ignore", "invalidate", "new_record"])
def test_postgres_snapshot_first_repeat_updates_delete_return(tmp_path, postgres_server, strategy, deletes):
    pair = Pair(tmp_path, postgres_server, strategy, deletes)
    pair.run()
    initial = pair.compare()
    pair.run()
    assert pair.compare() == initial
    pair.mutate("update input set name='Changed',ts='2020-02-01' where id=1")
    pair.run()
    updated = pair.compare()
    assert len(updated) == 3
    pair.run()
    assert pair.compare() == updated
    pair.mutate("delete from input where id=1")
    pair.run()
    deleted = pair.compare()
    assert len(deleted) == 3 + (deletes == "new_record")
    pair.run()
    assert pair.compare() == deleted
    pair.mutate("insert into input values(1,'Returned','2020-03-01')")
    pair.run()
    returned = pair.compare()
    assert sum(row["id"] == 1 and row["dbt_valid_to"] is None for row in returned) == 1


def test_postgres_check_default_clock_addition_and_character_widening(tmp_path, postgres_server):
    pair = Pair(tmp_path, postgres_server, "check", "invalidate", updated_at=None)
    pair.run()
    initial = pair.compare()
    pair.run()
    assert pair.compare() == initial
    pair.mutate("alter table input alter column name type varchar(40); alter table input add column extra numeric(12,2); update input set name='Longer than twelve characters',extra=12.25 where id=1")
    pair.run()
    assert len(pair.compare()) == 4  # check_cols=all notices the new column on both rows
    pair.run()
    pair.compare()
    pair.mutate("delete from input where id=1")
    pair.run()
    pair.compare()


def test_postgres_snapshot_failure_restores_rows_schema_and_public_errors(tmp_path, postgres_server, monkeypatch):
    pair = Pair(tmp_path, postgres_server, "check")
    pair.run()
    before = pair.compare()
    pair.mutate("alter table input add column extra integer; update input set name='Changed',ts='2020-02-01'")
    for project in pair.projects:
        path = project / "snapshots/history.sql"
        path.write_text(path.read_text().replace("check_cols='all'", "check_cols='all',dbt_valid_to_current=\"cast('PRIVATE_BAD_SENTINEL' as timestamp)\""))
    monkeypatch.setenv("DBT_ENV_SECRET_SNAPSHOT_SENTINEL", "PRIVATE_BAD_SENTINEL")
    pair.run(success=False)
    assert pair.compare() == before
    native = pair.invoke(pair.projects[0], "dxt")
    assert "PRIVATE_BAD_SENTINEL" not in native.stdout + native.stderr
    for project in pair.projects:
        assert pair.query(project, f"select count(*) from information_schema.columns where table_schema='{project.name}_archive' and table_name='history' and column_name='extra'") == [(0,)]


def test_postgres_snapshot_unlogged_indexes_and_model_consumer(tmp_path, postgres_server):
    pair = Pair(tmp_path, postgres_server, extra=",unlogged=true,indexes=[{'columns':['dbt_scd_id'],'unique':true}]")
    pair.run()
    pair.compare()
    for project, engine in zip(pair.projects, ("dxt", "dbt")):
        relation = f'"{project.name}_archive".history'
        assert pair.query(project, f"select relpersistence from pg_class where oid='{relation}'::regclass") == [("u",)]
        assert pair.query(project, f"select indisunique from pg_index where indrelid='{relation}'::regclass") == [(True,)]
        (project / "models/current.sql").write_text("select id,name from {{ ref('history') }} where dbt_valid_to is null")
        successful(pair.invoke(project, engine, "run", "--select", "current"))
        assert pair.query(project, "select * from current order by id") == [(1,"Alice"),(2,None)]


@pytest.mark.parametrize("truthy_nulls", [False, True])
def test_postgres_yaml_snapshot_custom_metadata_sentinel_and_nullable_composite_key(tmp_path, postgres_server, truthy_nulls):
    pair = Pair(tmp_path, postgres_server)
    for project, engine in zip(pair.projects, ("dxt", "dbt")):
        (project / "snapshots/history.sql").unlink()
        (project / "models/base.sql").write_text(f'select * from "{project.name}".input')
        config = project / "dbt_project.yml"
        config.write_text(config.read_text()+"snapshots:\n  +strategy: timestamp\n  +unique_key: [id, name]\n  +updated_at: ts\n" + ("flags:\n  enable_truthy_nulls_equals_macro: true\n" if truthy_nulls else ""))
        (project / "snapshots/definitions.yml").write_text(f"""version: 2
snapshots:
  - name: history
    relation: ref('base')
    config:
      target_schema: {project.name}_archive
      alias: history_alias
      dbt_valid_to_current: "timestamp '9999-12-31'"
      snapshot_meta_column_names:
        dbt_scd_id: scd
        dbt_updated_at: updated
        dbt_valid_from: valid_from
        dbt_valid_to: valid_to
""")
        successful(pair.invoke(project, engine, "run", "--select", "base"))
    pair.run()
    before = [pair.query(project, f'select * from "{project.name}_archive".history_alias order by id,valid_from') for project in pair.projects]
    assert before[0] == before[1]
    assert all(row[-1] == datetime.datetime(9999,12,31) for row in before[0])
    pair.run()
    repeated = [pair.query(project, f'select * from "{project.name}_archive".history_alias order by id,valid_from') for project in pair.projects]
    assert repeated[0] == repeated[1]
    assert len(repeated[0]) == (2 if truthy_nulls else 3)
    if truthy_nulls: assert repeated == before
    pair.mutate("update input set ts='2020-02-01' where id=2")
    pair.run()
    after = [pair.query(project, f'select * from "{project.name}_archive".history_alias order by id,valid_from') for project in pair.projects]
    assert after[0] == after[1] and len(after[0]) == (3 if truthy_nulls else 4)
    for project in pair.projects:
        artifact_validator.assert_artifact(project / "target/manifest.json")
        node = json.loads((project / "target/manifest.json").read_text())["nodes"]["snapshot.materialization_contract.history"]
        assert node["depends_on"]["nodes"] == ["model.materialization_contract.base"]


def test_postgres_snapshot_rejects_foreign_catalog_without_relation_changes(tmp_path, postgres_server):
    pair = Pair(tmp_path, postgres_server, extra=",target_database='foreign_catalog'")
    results = [pair.invoke(project, engine) for project, engine in zip(pair.projects, ("dxt", "dbt"))]
    assert all(result.returncode != 0 for result in results)
    # Core rejects cross-database schemas before submitting a resource and emits
    # no RunResults. Native reports the rejected resource in its valid artifact.
    assert not (pair.projects[1] / "target/run_results.json").exists()
    native_artifact = pair.projects[0] / "target/run_results.json"
    artifact_validator.assert_artifact(native_artifact)
    assert [row["status"] for row in json.loads(native_artifact.read_text())["results"]] == ["error"]
    for project in pair.projects:
        assert pair.query(project, f"select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='{project.name}_archive' and c.relname='history'") == [(0,)]


@pytest.mark.parametrize("kind", ["view", "materialized view"])
def test_postgres_snapshot_rejects_existing_non_snapshot_relation_atomically(tmp_path, postgres_server, kind):
    pair = Pair(tmp_path, postgres_server)
    for project in pair.projects:
        pair.query(project, f'create schema "{project.name}_archive"; create {kind} "{project.name}_archive".history as select \'preserved\'::text as marker')
    pair.run(success=False)
    for project in pair.projects:
        relation = f'"{project.name}_archive".history'
        assert pair.query(project, f"select marker from {relation}") == [("preserved",)]
        assert pair.query(project, f"select relkind from pg_class where oid='{relation}'::regclass") == [("v" if kind == "view" else "m",)]
        assert pair.query(project, f"select attname from pg_attribute where attrelid='{relation}'::regclass and attnum>0 and not attisdropped order by attnum") == [("marker",)]

"""Clone actual PostgreSQL relations against Core's native view materialization."""
from __future__ import annotations

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
    def __init__(self, path, server):
        oracle_available("postgres")
        self.server = server
        suffix = hashlib.md5(str(path).encode()).hexdigest()[:8]
        self.projects = [project_at(path / f"{prefix}_clone_{suffix}", "postgres", server) for prefix in ("native", "core")]
        for project in self.projects:
            profile = project / "profiles.yml"
            text = profile.read_text()
            config = text.split("    dev:\n", 1)[1].replace(f"schema: {project.name}", f"schema: {project.name}_prod")
            profile.write_text(text + "    prod:\n" + config)
            (project / "models/customers.sql").write_text("{{ config(materialized='table') }} select 7 as id")

    def invoke(self, project, engine, command="clone", *arguments):
        return subprocess.run([str(DXT) if engine == "dxt" else "dbt", command, "--project-dir", str(project), "--profiles-dir", str(project), *arguments], env=dict(os.environ, DBT_SEND_ANONYMOUS_USAGE_STATS="false"), capture_output=True, text=True)

    def build(self):
        for project, engine in zip(self.projects, ("dxt", "dbt")):
            successful(self.invoke(project, engine, "build", "--target", "prod", "--target-path", str(project / "state")))

    def clone(self, *arguments, success=True):
        outputs = []
        for project, engine in zip(self.projects, ("dxt", "dbt")):
            result = self.invoke(project, engine, "clone", "--state", str(project / "state"), *arguments)
            if success:
                successful(result)
            else:
                assert result.returncode != 0, result.stdout + result.stderr
            artifact_validator.assert_artifact(project / "target/run_results.json")
            artifact_validator.assert_artifact(project / "target/manifest.json")
            outputs.append(result)
        return outputs

    def query(self, project, sql):
        return query(project, "postgres", sql, self.server)

    def results(self):
        observations = []
        for project in self.projects:
            rows = json.loads((project / "target/run_results.json").read_text())["results"]
            data = {row["unique_id"]: {field: row[field] for field in ("status", "compiled", "compiled_code", "message", "failures", "relation_name", "adapter_response")} for row in rows}
            observations.append(json.loads(json.dumps(data).replace(project.name, "schema")))
        assert observations[0] == observations[1]
        return observations[0]


@pytest.mark.parametrize("existing_kind", ["table", "view", "materialized view"])
def test_postgres_clone_actual_response_existing_kinds_and_full_refresh(tmp_path, postgres_server, existing_kind):
    pair = Pair(tmp_path, postgres_server)
    pair.build()
    pair.clone()
    first = pair.results()
    assert first["model.materialization_contract.customers"]["adapter_response"] == {"_message": "CREATE VIEW", "code": "CREATE VIEW", "rows_affected": -1}
    for project in pair.projects:
        assert pair.query(project, "select * from customers") == [(7,)]
        pair.query(project, f"drop view customers; create {existing_kind} customers as select 99 as id")
    pair.clone()
    assert pair.results()["model.materialization_contract.customers"]["message"] == "No-op"
    for project in pair.projects:
        assert pair.query(project, "select * from customers") == [(99,)]
    pair.clone("--full-refresh")
    pair.results()
    for project in pair.projects:
        pair.query(project, f'insert into "{project.name}_prod".customers values(8)')
        assert pair.query(project, "select * from customers order by id") == [(7,), (8,)]
        assert pair.query(project, "select table_type from information_schema.tables where table_schema=current_schema() and table_name='customers'") == [("VIEW",)]
        assert pair.query(project, "select relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname=current_schema() and (relname like '%__dbt_tmp' or relname like '%__dbt_backup')") == []


def test_postgres_clone_seed_snapshot_and_new_resources_are_state_driven(tmp_path, postgres_server):
    pair = Pair(tmp_path, postgres_server)
    for project in pair.projects:
        (project / "seeds").mkdir()
        (project / "seeds/raw.csv").write_text("id\n2\n")
        (project / "snapshots").mkdir()
        (project / "snapshots/history.sql").write_text("{% snapshot history %} {{ config(strategy='timestamp',unique_key='id',updated_at='ts') }} select 3 as id,timestamp '2020-01-01' as ts {% endsnapshot %}")
    pair.build()
    for project in pair.projects:
        (project / "models/new.sql").write_text("select 99 as id")
    pair.clone()
    rows = pair.results()
    assert rows["model.materialization_contract.new"]["message"] == "No-op"
    for project in pair.projects:
        assert pair.query(project, "select * from raw") == [(2,)]
        assert pair.query(project, "select id,dbt_valid_to from history") == [(3, None)]
        assert pair.query(project, "select table_name from information_schema.tables where table_schema=current_schema() and table_name='new'") == []


def test_postgres_clone_failure_preserves_target_and_independent_results(tmp_path, postgres_server):
    pair = Pair(tmp_path, postgres_server)
    for project in pair.projects:
        (project / "models/independent.sql").write_text("select 9 as id")
    pair.build()
    for project in pair.projects:
        pair.query(project, f'create schema "{project.name}"; create table customers as select 99 as id; drop table "{project.name}_prod".customers')
    pair.clone("--full-refresh", success=False)
    # Public errors deliberately exclude database messages; compare observed
    # warehouse atomicity and per-resource status instead of private text.
    for project in pair.projects:
        rows = json.loads((project / "target/run_results.json").read_text())["results"]
        assert {row["unique_id"]: row["status"] for row in rows} == {"model.materialization_contract.customers": "error", "model.materialization_contract.independent": "success"}
        assert pair.query(project, "select * from customers") == [(99,)]
        assert pair.query(project, "select * from independent") == [(9,)]
        manifest = json.loads((project / "target/manifest.json").read_text())
        assert manifest["nodes"]["model.materialization_contract.customers"].get("compiled", False) is False


def test_postgres_clone_hooks_execute_once_and_failed_inner_hook_is_atomic(tmp_path, postgres_server):
    pair = Pair(tmp_path, postgres_server)
    pair.build()
    for project in pair.projects:
        (project / "models/customers.sql").write_text("""{{ config(materialized='table',
pre_hook=[{'sql': "create table if not exists {{ target.schema }}.events(label varchar)", 'transaction': false}, "insert into {{ target.schema }}.events values('inner-pre')"],
post_hook=["insert into {{ target.schema }}.events select 'inner-post:' || cast(id as varchar) from {{ this }}", {'sql': "insert into {{ target.schema }}.events values('outside-post')", 'transaction': false}]) }}
select 999 as id
""")
    pair.clone()
    pair.results()
    for project in pair.projects:
        assert pair.query(project, "select * from customers") == [(7,)]
        assert pair.query(project, "select label from events order by label") == [("inner-post:7",), ("inner-pre",), ("outside-post",)]
    pair.clone()
    pair.results()
    for project in pair.projects:
        assert pair.query(project, "select count(*) from events") == [(3,)]
        pair.query(project, "drop view customers; create table customers as select 99 as id")
        assert pair.query(project, "select * from customers") == [(99,)]
        path = project / "models/customers.sql"
        path.write_text(path.read_text().replace("insert into {{ target.schema }}.events select 'inner-post:' || cast(id as varchar) from {{ this }}", "select * from missing_hook_relation"))
    pair.clone("--full-refresh", success=False)
    # Core's deferred-schema cache miss opens a transaction before the outside
    # hook's raw COMMIT, but leaves its logical transaction flag set. Its SQL
    # log contains no subsequent BEGIN, so this failure commits the swap and
    # inner-pre separately. Native deliberately restores both atomically.
    assert pair.query(pair.projects[0], "select * from customers") == [(99,)]
    assert pair.query(pair.projects[0], "select count(*) from events") == [(3,)]
    assert pair.query(pair.projects[1], "select * from customers") == [(7,)]
    assert pair.query(pair.projects[1], "select count(*) from events") == [(4,)]
    assert pair.query(pair.projects[1], "select * from customers__dbt_backup") == [(99,)]


def test_postgres_clone_uses_current_catalog_when_prior_metadata_names_another_database(tmp_path, postgres_server):
    pair = Pair(tmp_path, postgres_server)
    pair.build()
    for project, engine in zip(pair.projects, ("dxt", "dbt")):
        manifest = project / "state/manifest.json"
        value = json.loads(manifest.read_text())
        value["nodes"]["model.materialization_contract.customers"]["database"] = "foreign_catalog"
        manifest.write_text(json.dumps(value))
        result = pair.invoke(project, engine, "clone", "--state", str(project / "state"))
        successful(result)
        assert pair.query(project, "select * from customers") == [(7,)]
    pair.results()


def test_postgres_clone_missing_state_resource_still_prepares_selected_schema(tmp_path, postgres_server):
    pair = Pair(tmp_path, postgres_server)
    pair.build()
    for project in pair.projects:
        (project / "models/new.sql").write_text("select 99 as id")
    pair.clone("--select", "new")
    assert pair.results()["model.materialization_contract.new"]["message"] == "No-op"
    for project in pair.projects:
        assert pair.query(project, f"select schema_name from information_schema.schemata where schema_name='{project.name}'") == [(project.name,)]


def test_postgres_clone_uses_physical_relation_name_from_state(tmp_path, postgres_server):
    pair = Pair(tmp_path, postgres_server)
    for project in pair.projects:
        (project / "models/independent.sql").write_text("select 9 as id")
    pair.build()
    for project in pair.projects:
        path = project / "state/manifest.json"
        manifest = json.loads(path.read_text())
        manifest["nodes"]["model.materialization_contract.customers"]["relation_name"] = manifest["nodes"]["model.materialization_contract.independent"]["relation_name"]
        path.write_text(json.dumps(manifest))
    pair.clone("--select", "customers")
    pair.results()
    for project in pair.projects:
        assert pair.query(project, "select * from customers") == [(9,)]

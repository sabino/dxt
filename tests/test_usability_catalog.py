"""Actual warehouse catalog metadata compared with pinned Core."""
import json
import subprocess

import duckdb

from test_usability_commands import core_runner
from test_usability_artifacts import ROOT, DXT, contracts, native_binary


def test_duckdb_table_view_source_and_column_comments_match_core(tmp_path, core_runner):
    project = tmp_path / "project"
    (project / "models").mkdir(parents=True)
    (project / "dbt_project.yml").write_text("name: catalog_metadata\nversion: '1.0'\nprofile: catalog_metadata\n")
    (project / "profiles.yml").write_text(f"catalog_metadata:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n      path: {project / 'warehouse.duckdb'}\n      schema: analytics\n      threads: 1\n      keep_open: false\n")
    (project / "models/customers.sql").write_text("select * from {{ source('raw', 'input') }}")
    (project / "models/view_customers.sql").write_text("select * from {{ ref('customers') }}")
    (project / "models/schema.yml").write_text("version: 2\nsources:\n  - name: raw\n    tables:\n      - name: input\n")
    with duckdb.connect(str(project / "warehouse.duckdb")) as database:
        database.execute("create schema analytics; create schema raw; create table raw.input(id bigint, name varchar); create table analytics.customers as select * from raw.input; create view analytics.view_customers as select * from analytics.customers")
        for relation in ["raw.input", "analytics.customers", "analytics.view_customers"]:
            kind = "view" if relation.endswith("view_customers") else "table"
            database.execute(f"comment on {kind} {relation} is 'Directory of customers'; comment on column {relation}.id is 'Customer identifier'; comment on column {relation}.name is 'Display name'")
    observed = {}
    for engine in ["native", "core"]:
        target = project / engine
        arguments = ["docs", "generate", "--project-dir", str(project), "--profiles-dir", str(project), "--target-path", str(target)]
        if engine == "native":
            result = subprocess.run([DXT, *arguments], cwd=ROOT, capture_output=True, text=True)
            assert result.returncode == 0, result.stderr
        else:
            result = core_runner.invoke(["--quiet", *arguments, "--no-partial-parse"])
            assert result.success, result.exception
        contracts.assert_artifact(target / "catalog.json")
        catalog = json.loads((target / "catalog.json").read_text())
        observed[engine] = {kind: catalog[kind] for kind in ["nodes", "sources", "errors"]}
    assert observed["native"] == observed["core"]
    assert observed["native"]["nodes"]["model.catalog_metadata.customers"]["metadata"]["comment"] == "Directory of customers"
    assert observed["native"]["sources"]["source.catalog_metadata.raw.input"]["columns"]["id"]["comment"] == "Customer identifier"

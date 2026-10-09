"""Native dialect parsers/binders and artifact/cache correctness across the CLI."""
from __future__ import annotations
import ctypes.util
import importlib.util
import json
import os
import shutil
import subprocess
from pathlib import Path
import pytest
import jsonschema
from test_cli import build_dxt

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out/bin/dxt"
DUCKDB = shutil.which("duckdb")

@pytest.fixture
def native_environment():
    library = os.environ.get("DXT_DUCKDB_LIBRARY") or ctypes.util.find_library("duckdb")
    if not library:
        if os.environ.get("DXT_NATIVE_ADAPTER_CERTIFY") == "1": pytest.fail("Native SQL analysis certification requires libduckdb")
        pytest.skip("Native SQL analysis requires libduckdb")
    return dict(os.environ, DXT_DUCKDB_LIBRARY=library, DXT_DUCKDB_BACKEND="native", DBT_SEND_ANONYMOUS_USAGE_STATS="false")

def duck_query(project, statement):
    result = subprocess.run([DUCKDB, str(project / "warehouse.duckdb"), "-json", "-c", statement], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout or "[]")

def project_at(path):
    (path / "models").mkdir(parents=True)
    (path / "macros").mkdir()
    (path / "dbt_project.yml").write_text("name: analysis_contract\nversion: '1.0'\nconfig-version: 2\nprofile: analysis_contract\n")
    (path / "profiles.yml").write_text(f"analysis_contract:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n      path: {path / 'warehouse.duckdb'}\n      schema: main\n      threads: 1\n")
    (path / "models/schema.yml").write_text("version: 2\nsources:\n  - name: raw\n    schema: main\n    tables:\n      - name: orders\n")
    duck_query(path, "create table orders(id integer not null, amount decimal(10,2), region varchar); insert into orders values (1,12.25,'east'),(2,5.50,'west')")
    return path

def invoke(project, environment, command="analyze", *arguments):
    return subprocess.run([str(DXT), command, "--project-dir", str(project), "--profiles-dir", str(project), *arguments], env=environment, capture_output=True, text=True)

def report(project, environment, *arguments, command="analyze"):
    result = invoke(project, environment, command, *arguments)
    assert result.returncode == 0, result.stdout + result.stderr
    document = json.loads((project / "target/dxt_sql_analysis.json").read_text())
    assert document["schema_version"] == "dxt-sql-analysis-v1"
    jsonschema.validate(document, json.loads((ROOT / "schemas/dxt/sql-analysis-v1.json").read_text()))
    for key, node in document["nodes"].items():
        assert key == node["unique_id"] and node["status"] == "success"
        assert all(c["data_type"] != "UNKNOWN" for c in node["columns"])
    return document

def test_native_unmaterialized_cte_join_aggregate_types_lineage_and_explain(tmp_path, native_environment):
    project = project_at(tmp_path)
    (project / "models/staging.sql").write_text("select id, cast(amount as decimal(12,2)) amount, upper(region) region from {{ source('raw','orders') }}")
    (project / "models/totals.sql").write_text("with selected as (select * from {{ ref('staging') }}) select s.region,sum(s.amount) as total,max(o.id) as last_id from selected s join {{ source('raw','orders') }} o on s.id=o.id group by s.region")
    before = duck_query(project, "select table_name from information_schema.tables where table_schema='main' order by table_name")
    analyzed = report(project, native_environment, "--select", "totals", command="explain")
    node = analyzed["nodes"]["model.analysis_contract.totals"]
    assert [c["name"] for c in node["columns"]] == ["region", "total", "last_id"]
    assert [c["data_type"] for c in node["columns"]] == ["VARCHAR", "DECIMAL(38,2)", "INTEGER"]
    assert [{o["column"] for o in c["origins"]} for c in node["columns"]] == [{"region"}, {"amount"}, {"id"}]
    assert all(o["resource_id"] == "source.analysis_contract.raw.orders" for c in node["columns"] for o in c["origins"])
    assert {op["kind"] for op in node["operators"]} >= {"CTE", "Scan", "Join", "Project", "Aggregate"}
    assert node["plan"]
    assert duck_query(project, "select table_name from information_schema.tables where table_schema='main' order by table_name") == before
    assert "__dxt_bind" not in json.dumps(node["inputs"])

@pytest.mark.parametrize("body,code", [
    ("select missing_column\nfrom {{ source('raw','orders') }}", "UNRESOLVED_COLUMN"),
    ("select id from {{ source('raw','orders') }} a join {{ source('raw','orders') }} b on a.id=b.id", "AMBIGUOUS_COLUMN"),
    ("select id from", "SQL_SYNTAX"),
    ("select 1; select 2", "SQL_READ_ONLY"),
])
def test_invalid_sql_has_locations_and_leaves_database_untouched(tmp_path, native_environment, body, code):
    project = project_at(tmp_path)
    (project / "models/broken.sql").write_text(body)
    result = invoke(project, native_environment)
    assert result.returncode == 1
    artifact = json.loads((project / "target/dxt_sql_analysis.json").read_text())
    jsonschema.validate(artifact, json.loads((ROOT / "schemas/dxt/sql-analysis-v1.json").read_text()))
    node = artifact["nodes"]["model.analysis_contract.broken"]
    diagnostic = node["diagnostics"][0]
    assert diagnostic["code"] == code
    assert diagnostic["line"] >= 1 and diagnostic["column"] >= 1
    assert diagnostic["coordinate_space"] == "compiled_sql"
    assert "models/broken.sql:" in result.stderr
    assert duck_query(project, "select count(*) n from orders") == [{"n": 2}]
    assert duck_query(project, "select count(*) n from information_schema.tables where table_name='broken'") == [{"n": 0}]

def test_sql_cache_reuses_ast_binding_and_invalidates_source_macro_config_package_environment(tmp_path, native_environment):
    project = project_at(tmp_path)
    (project / "macros/project_id.sql").write_text("{% macro project_id() %}{{ return('id') }}{% endmacro %}")
    (project / "models/staging.sql").write_text("{{ config(meta={'revision':var('revision',1)}) }} select {{ project_id() }} as id from {{ source('raw','orders') }} where id > {{ env_var('DXT_ANALYSIS_MIN','0') }}")
    (project / "models/final.sql").write_text("select * from {{ ref('staging') }}")
    cold = report(project, native_environment)
    warm = report(project, native_environment)
    assert cold["stats"]["parsed_nodes"] == cold["stats"]["bound_nodes"] == 2
    assert warm["stats"]["parsed_nodes"] == warm["stats"]["bound_nodes"] == 0
    assert warm["stats"]["cache_hits"] == 2
    query_before = warm["nodes"]["model.analysis_contract.final"]["fingerprint"]
    for mutate in (
        lambda: duck_query(project, "alter table orders add column added varchar"),
        lambda: (project / "macros/project_id.sql").write_text("{% macro project_id() %}{{ return('id') }}{# body changed #}{% endmacro %}"),
    ):
        mutate()
        changed = report(project, native_environment)
        assert changed["stats"]["invalidated_nodes"] == 2
        assert changed["nodes"]["model.analysis_contract.final"]["fingerprint"] != query_before
        query_before = changed["nodes"]["model.analysis_contract.final"]["fingerprint"]
    changed = report(project, dict(native_environment, DXT_ANALYSIS_MIN="1"))
    assert changed["stats"]["invalidated_nodes"] == 2
    changed = report(project, native_environment, "--vars", "{revision: 2}")
    assert changed["stats"]["invalidated_nodes"] == 2
    package = project / "dbt_packages/helpers"
    (package / "macros").mkdir(parents=True)
    (package / "dbt_project.yml").write_text("name: helpers\nversion: '1.0'\nconfig-version: 2\n")
    helper = package / "macros/value.sql"
    helper.write_text("{% macro value() %}{{ return(1) }}{% endmacro %}")
    (project / "models/staging.sql").write_text("select id + {{ helpers.value() }} as id from {{ source('raw','orders') }}")
    report(project, native_environment)
    helper.write_text("{% macro value() %}{{ return(2) }}{% endmacro %}")
    assert report(project, native_environment)["stats"]["invalidated_nodes"] == 2

def test_installed_analysis_runs_without_cli_or_python_and_reports_native_types(tmp_path, native_environment):
    project = project_at(tmp_path / "project")
    (project / "models/output.sql").write_text("select id from {{ source('raw','orders') }}")
    installed = tmp_path / "installed/dxt"
    installed.parent.mkdir()
    shutil.copy2(DXT, installed)
    environment = dict(native_environment, PATH="")
    result = subprocess.run([str(installed), "explain", "--project-dir", str(project), "--profiles-dir", str(project)], env=environment, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["nodes"]["model.analysis_contract.output"]["columns"][0]["data_type"] == "INTEGER"

@pytest.mark.parametrize("body,origins", [
    ("select id as result from main.orders union all select cast(amount as integer) from main.orders", [{"id", "amount"}]),
    ("select id, sum(amount) over(partition by region order by id) as running from main.orders", [{"id"}, {"id", "amount", "region"}]),
    ("select case when amount > 0 then id else 0 end as result from main.orders order by result", [{"id", "amount"}]),
    ("select id,(select max(i.amount) from main.orders i where i.id=o.id) as maximum from main.orders o", [{"id"}, {"amount"}]),
    ("select * from main.orders a join main.orders b using(id)", [{"id"}, {"amount"}, {"region"}, {"amount"}, {"region"}]),
    ("select x.i from (values (1),(2)) x(i)", [set()]),
    ("select r.range from range(5) r", [set()]),
    ("select r.range from range(/* closing ) with nested /* ( */ comment */5) r", [set()]),
    ("select u.tag from main.orders o, unnest([o.region]) u(tag)", [{"region"}]),
    ("select p.properties.region from (select {'region':region} as properties from main.orders) p", [{"region"}]),
    ("select * exclude(region) replace(amount*2 as amount) rename(id as other) from main.orders", [{"id"}, {"amount"}]),
    ("with recursive t(n) as (select id from main.orders union all select n+1 from t where n<3) select * from t", [{"id"}]),
])
def test_native_sql_constructs_resolve_lineage(tmp_path, native_environment, body, origins):
    project = project_at(tmp_path)
    (project / "models/output.sql").write_text(body)
    node = report(project, native_environment)["nodes"]["model.analysis_contract.output"]
    assert [{o["column"] for o in c["origins"]} for c in node["columns"]] == origins

def test_declared_performance_budget_and_execution_equivalence(tmp_path, native_environment):
    project = project_at(tmp_path)
    (project / "models/base.sql").write_text("select id, amount*2 as doubled from {{ source('raw','orders') }}")
    (project / "models/final.sql").write_text("select id,sum(doubled) total from {{ ref('base') }} group by id order by id")
    cold = report(project, native_environment)
    warm = report(project, native_environment)
    assert cold["stats"]["elapsed_ms"] < 5000
    assert warm["stats"]["elapsed_ms"] < 2000
    assert warm["stats"]["bound_nodes"] == warm["stats"]["parsed_nodes"] == 0
    result = invoke(project, native_environment, "build", "--select", "base", "final")
    assert result.returncode == 0, result.stderr
    assert duck_query(project, 'select * from "final" order by id') == duck_query(project, 'select id,sum(amount*2) total from orders group by id order by id')
    assert [c["name"] for c in cold["nodes"]["model.analysis_contract.final"]["columns"]] == ["id", "total"]

def test_analysis_macros_cannot_escape_readonly_transaction_or_publish_secrets(tmp_path, native_environment):
    project = project_at(tmp_path)
    (project / "models/broken.sql").write_text("{% if execute %}{% set ignored=run_query('commit; delete from orders') %}{% endif %} select id from {{ source('raw','orders') }}")
    result = invoke(project, native_environment)
    assert result.returncode == 1
    assert duck_query(project, "select count(*) n from orders") == [{"n": 2}]
    (project / "models/broken.sql").write_text("select synthetic_secret from {{ source('raw','orders') }}")
    environment = dict(native_environment, DBT_ENV_SECRET_SENTINEL="synthetic_secret")
    result = invoke(project, environment)
    assert result.returncode == 1
    assert "synthetic_secret" not in result.stderr
    assert "synthetic_secret" not in (project / "target/dxt_sql_analysis.json").read_text()
    assert "synthetic_secret" not in (project / "target/.dxt_sql_analysis_cache.json").read_text()

def test_postgres_native_grammar_binding_lineage_errors_and_readonly_recovery(tmp_path):
    if importlib.util.find_spec("pgserver") is None:
        if os.environ.get("DXT_NATIVE_ADAPTER_CERTIFY") == "1": pytest.fail("Native SQL analysis certification requires pgserver")
        pytest.skip("Native PostgreSQL fixture unavailable")
    import pgserver
    import psycopg2
    with pgserver.get_server(tmp_path / "server") as server:
        info = server.get_uri()
        with psycopg2.connect(info) as connection:
            with connection.cursor() as cursor:
                cursor.execute("create table public.orders(id integer not null, amount numeric(10,2)); insert into public.orders values(1,12.25),(2,5.50)")
        project = tmp_path / "project"
        (project / "models").mkdir(parents=True)
        (project / "dbt_project.yml").write_text("name: analysis_contract\nversion: '1.0'\nconfig-version: 2\nprofile: analysis_contract\n")
        from urllib.parse import urlparse, unquote
        parsed = urlparse(info)
        postmaster = server.get_postmaster_info()
        (project / "profiles.yml").write_text(f"analysis_contract:\n  target: dev\n  outputs:\n    dev:\n      type: postgres\n      host: {json.dumps(str(postmaster.socket_dir))}\n      port: {postmaster.port}\n      dbname: postgres\n      user: {unquote(parsed.username or 'postgres')}\n      password: ''\n      schema: public\n      threads: 1\n")
        (project / "models/base.sql").write_text("select id,amount from public.orders")
        (project / "models/final.sql").write_text("with input as (select * from {{ ref('base') }}) select id::bigint as id, amount*2 as amount from input")
        environment = dict(os.environ)
        analyzed = report(project, environment, "--select", "final", command="explain")
        final = analyzed["nodes"]["model.analysis_contract.final"]
        assert [c["data_type"] for c in final["columns"]] == ["bigint", "numeric"]
        assert [{o["column"] for o in c["origins"]} for c in final["columns"]] == [{"id"}, {"amount"}]
        assert final["plan"]
        for body, expected in (
            ("select amount from public.orders", ["numeric(10,2)"]),
            ("select * from public.orders a join public.orders b using(id)", ["integer", "numeric(10,2)", "numeric(10,2)"]),
            ("with recursive t(n) as (select id from public.orders union all select n+1 from t where n<3) select * from t", ["integer"]),
            ("select g from generate_series(1,5) g", ["integer"]),
            ("select g from public.orders o, lateral generate_series(1,o.id) g", ["integer"]),
            ("select x.i from (values(1),(2)) x(i)", ["integer"]),
            ("select sum(amount) over(partition by id) running from public.orders", ["numeric"]),
        ):
            (project / "models/construct.sql").write_text(body)
            document = report(project, environment, "--select", "construct")
            assert [column["data_type"] for column in document["nodes"]["model.analysis_contract.construct"]["columns"]] == expected
        with psycopg2.connect(info) as connection:
            with connection.cursor() as cursor:
                cursor.execute("alter table public.orders alter column amount type numeric(12,3)")
        (project / "models/construct.sql").write_text("select amount from public.orders")
        changed = report(project, environment, "--select", "construct")
        assert changed["nodes"]["model.analysis_contract.construct"]["columns"][0]["data_type"] == "numeric(12,3)"
        (project / "models/a_broken.sql").write_text("select missing_column from public.orders")
        failure = invoke(project, environment)
        assert failure.returncode == 1
        artifact = json.loads((project / "target/dxt_sql_analysis.json").read_text())
        assert artifact["nodes"]["model.analysis_contract.a_broken"]["diagnostics"][0]["code"] == "UNRESOLVED_COLUMN"
        assert artifact["nodes"]["model.analysis_contract.final"]["status"] == "success"
        with psycopg2.connect(info) as connection:
            with connection.cursor() as cursor:
                cursor.execute("select count(*) from public.orders")
                assert cursor.fetchone() == (2,)



def test_file_schema_cache_invalidation_and_failed_dependency_propagation(tmp_path, native_environment):
    project = project_at(tmp_path)
    input_file = project / "input.csv"
    input_file.write_text("id,amount\n1,2\n")
    (project / "models/base.sql").write_text(f"select * from read_csv('{input_file}')")
    (project / "models/final.sql").write_text("select amount from {{ ref('base') }}")
    cold = report(project, native_environment)
    assert cold["nodes"]["model.analysis_contract.final"]["columns"][0]["data_type"] == "BIGINT"
    assert cold["nodes"]["model.analysis_contract.final"]["columns"][0]["origins"][0]["resource_id"].startswith("external.duckdb.read_csv.")
    assert report(project, native_environment)["stats"]["cache_hits"] == 2
    input_file.write_text("id,amount\n1,hello\n")
    changed = report(project, native_environment)
    assert changed["stats"]["invalidated_nodes"] == 2
    assert changed["stats"]["parsed_nodes"] == 0  # Native AST survives a schema-only edit.
    assert changed["nodes"]["model.analysis_contract.final"]["columns"][0]["data_type"] == "VARCHAR"
    duck_query(project, "create table base(amount integer)")
    (project / "models/base.sql").write_text("select nonexistent from main.orders")
    failed = invoke(project, native_environment, "analyze", "--select", "final")
    assert failed.returncode == 1
    artifact = json.loads((project / "target/dxt_sql_analysis.json").read_text())
    assert artifact["nodes"]["model.analysis_contract.final"]["diagnostics"][0]["code"] == "DEPENDENCY_FAILED"
    assert duck_query(project, "select count(*) n from base") == [{"n": 0}]


def test_pinned_core_compiled_sql_and_executed_results_match_analysis(tmp_path, native_environment):
    from importlib.metadata import version, PackageNotFoundError
    try:
        pins = (version("dbt-core"), version("dbt-duckdb"))
    except PackageNotFoundError:
        pytest.skip("Optional pinned Core SQL analysis oracle requires dbt")
    assert pins == ("1.10.5", "1.9.6"), f"Oracle requires the declared pins, received {pins}"
    project = project_at(tmp_path)
    (project / "models/base.sql").write_text("select id,amount*2 as doubled from {{ source('raw','orders') }}")
    (project / "models/final.sql").write_text("select id,sum(doubled) total from {{ ref('base') }} group by id order by id")
    analysis = report(project, native_environment)
    oracle = subprocess.run([shutil.which("dbt"), "build", "--project-dir", str(project), "--profiles-dir", str(project), "--select", "base", "final"], env=native_environment, capture_output=True, text=True)
    assert oracle.returncode == 0, oracle.stdout + oracle.stderr
    manifest = json.loads((project / "target/manifest.json").read_text())
    import re
    for name in ("base", "final"):
        node_id = f"model.analysis_contract.{name}"
        normalize = lambda code: re.sub(r"\s+", " ", code).strip().rstrip(";")
        assert normalize(analysis["nodes"][node_id]["compiled_sql"]) == normalize(manifest["nodes"][node_id]["compiled_code"])
    core_rows = duck_query(project, 'select * from "final" order by id')
    assert invoke(project, native_environment, "run", "--select", "base", "final").returncode == 0
    assert duck_query(project, 'select * from "final" order by id') == core_rows


def test_tests_and_snapshot_metadata_share_native_analysis_dag(tmp_path, native_environment):
    project = project_at(tmp_path)
    (project / "snapshots").mkdir()
    (project / "tests").mkdir()
    duck_query(project, "alter table orders add column ts timestamp; update orders set ts='2024-01-01'")
    (project / "snapshots/history.sql").write_text("{% snapshot history %}{{ config(strategy='timestamp',unique_key='id',updated_at='ts',target_schema='archive',hard_deletes='new_record',snapshot_meta_column_names={'dbt_valid_to':'closed_at'}) }}select * from {{ source('raw','orders') }}{% endsnapshot %}")
    (project / "models/base.sql").write_text("select id,amount from {{ source('raw','orders') }}")
    (project / "models/final.sql").write_text("select id,dbt_scd_id,dbt_updated_at,closed_at,dbt_is_deleted from {{ ref('history') }}")
    schema = project / "models/schema.yml"
    schema.write_text(schema.read_text()+"models:\n  - name: base\n    columns:\n      - name: id\n        data_tests: [not_null]\n")
    (project / "tests/positive_amount.sql").write_text("select id from {{ ref('base') }} where amount<0")
    analyzed = report(project, native_environment)
    final = analyzed["nodes"]["model.analysis_contract.final"]
    assert [column["data_type"] for column in final["columns"]] == ["INTEGER","VARCHAR","TIMESTAMP","TIMESTAMP","VARCHAR"]
    assert final["columns"][1]["origins"] == [{"resource_id":"snapshot.analysis_contract.history","column":"dbt_scd_id"}]
    tests = [node for node in analyzed["nodes"].values() if node["resource_type"] == "test"]
    assert len(tests) == 2 and all(node["status"] == "success" for node in tests)
    assert all(node["columns"][0]["origins"][0]["resource_id"] == "source.analysis_contract.raw.orders" for node in tests)
    selected = report(project, native_environment, "--resource-type", "test")
    assert len(selected["nodes"]) == 2 and all(node["resource_type"] == "test" for node in selected["nodes"].values())
    assert duck_query(project, "select count(*) n from information_schema.tables where table_schema='archive'") == [{"n":0}]


def test_native_search_path_wins_over_duplicate_relation_names(tmp_path, native_environment):
    project = project_at(tmp_path)
    duck_query(project, "create schema a; create schema b; create table a.orders(other varchar); create table b.orders(other varchar)")
    (project / "models/output.sql").write_text("select id from orders")
    node = report(project, native_environment)["nodes"]["model.analysis_contract.output"]
    assert node["inputs"][0]["resource_id"] == "source.analysis_contract.raw.orders"


def test_analysis_global_options_json_output_and_invalid_list_outputs(tmp_path, native_environment):
    project = project_at(tmp_path)
    (project / "models/output.sql").write_text("select id from {{ source('raw','orders') }}")
    result = subprocess.run([str(DXT), "--quiet", "--profile", "analysis_contract", "--target", "dev", "analyze", "--project-dir", str(project), "--profiles-dir", str(project), "--output", "json", "--select", "output"], env=native_environment, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    assert list(json.loads(result.stdout)["nodes"]) == ["model.analysis_contract.output"]
    invalid = invoke(project, native_environment, "analyze", "--output", "selector")
    assert invalid.returncode == 2 and "supports --output text or json" in invalid.stderr

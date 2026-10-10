"""Executed test materialization helpers against pinned Core on both adapters."""
import json

import pytest

from test_cli import build_dxt  # noqa: F401
from test_usability_adapters import duckdb_environment  # noqa: F401
from test_usability_artifacts import contracts
from test_usability_cli_options import environment, pinned_core  # noqa: F401
from test_usability_configuration import configuration_postgres  # noqa: F401
from test_usability_sql_operations import command, project, warehouse_rows

LIMIT = """{% macro get_limit_subquery_sql(sql, limit) %}
{{ return('select * from (' ~ sql ~ ') helper_probe where id >= 2 order by id limit 2') }}
{% endmacro %}
"""
GET_TEST = """{% macro get_test_sql(main_sql, fail_calc, warn_if, error_if, limit) %}
{{ return(dbt.default__get_test_sql(main_sql, fail_calc, warn_if, error_if, limit)) }}
{% endmacro %}
"""
STATEMENT = """{% macro statement(name=None, fetch_result=False, auto_begin=True, language='sql') %}
{% if execute %}
{% if name is none or name == 'main' %}
{% set trace_relation = adapter.quote(target.schema) ~ '.statement_trace' %}
{% do adapter.execute('create table if not exists ' ~ trace_relation ~ '(name text)', auto_begin=True) %}
{% do adapter.execute('insert into ' ~ trace_relation ~ " values('" ~ (name | string) ~ "')", auto_begin=False) %}
{% do adapter.commit() %}
{% endif %}
{% set response, table = adapter.execute(caller(), auto_begin=auto_begin, fetch=fetch_result) %}
{% if name is not none %}{{ store_result(name,response=response,agate_table=table) }}{% endif %}
{% endif %}
{% endmacro %}
"""


def fixture(base, engine, adapter, request, *, store, limit=1, should_store=None, statement=False, generic=False, override_limit=True):
    root, schema = project(base, engine, adapter, request)
    for name in ['a.sql', 'b.sql', 'e.sql']:
        (root / 'models' / name).unlink()
    (root / 'models/input.sql').write_text("{{ config(materialized='table') }}select 1 as id union all select 2 union all select 3")
    macro = (LIMIT if override_limit else '') + GET_TEST
    if should_store is not None:
        macro += "{% macro should_store_failures() %}{{ return(" + str(should_store).lower() + ") }}{% endmacro %}\n"
    if statement:
        macro += STATEMENT
    (root / 'macros/helpers.sql').write_text(macro)
    config = {'alias': 'audit', 'store_failures': store, 'limit': limit}
    if generic:
        (root / 'macros/bad_rows.sql').write_text('{% test bad_rows(model) %}select * from {{ model }}{% endtest %}')
        (root / 'models/schema.yml').write_text('version: 2\nmodels:\n  - name: input\n    data_tests:\n      - bad_rows:\n          config: ' + json.dumps(config) + '\n')
    else:
        options = ','.join(name + '=' + ('none' if value is None else str(value).lower() if isinstance(value, bool) else repr(value)) for name, value in config.items())
        (root / 'tests/check.sql').write_text('{{ config(' + options + ') }}\nselect * from {{ ref("input") }}')
    return root, schema


def captured(root, schema, adapter, request):
    manifest = json.loads((root / 'target/manifest.json').read_text())
    artifact = json.loads((root / 'target/run_results.json').read_text())
    row, = artifact['results']
    node = manifest['nodes'][row['unique_id']]
    exists = warehouse_rows(root, adapter, request, f"select table_name from information_schema.tables where table_schema='{node['schema']}' and table_name='{node['alias']}'")
    rows = warehouse_rows(root, adapter, request, f'select id from "{node["schema"]}"."{node["alias"]}" order by id') if exists else None
    for file in ['manifest.json', 'run_results.json']:
        contracts.assert_artifact(root / 'target' / file)
    assert node['compiled'] is row['compiled'] is True
    resource_path = node['original_file_path'] if node['path'].split('/')[-1] == node['original_file_path'].split('/')[-1] else node['original_file_path'] + '/' + node['path']
    assert (root / 'target/compiled/preview' / resource_path).read_text() == node['compiled_code'] == row['compiled_code']
    assert 'helper_probe' not in node['compiled_code']
    normalize = lambda value: value.replace(schema, 'target_schema') if isinstance(value, str) else value
    fields = {field: normalize(node[field]) for field in ['unique_id', 'schema', 'alias', 'database', 'relation_name', 'compiled_code', 'config', 'depends_on']}
    result = {field: normalize(row[field]) for field in ['unique_id', 'status', 'failures', 'relation_name', 'compiled_code', 'adapter_response']}
    return fields, result, rows


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('generic', [False, True])
@pytest.mark.parametrize('limit', [1, -1, None])
def test_core_limit_override_controls_audit_and_failures_without_changing_compiled_body(tmp_path, request, duckdb_environment, adapter, generic, limit):
    observed = {}
    for engine in ['dxt', 'core']:
        root, schema = fixture(tmp_path, engine, adapter, request, store=True, limit=limit, generic=generic)
        env = environment(duckdb_environment)
        command(engine, root, env, 'run')
        result = command(engine, root, env, 'test', ok=False)
        assert result.returncode == 1, result.stdout + result.stderr
        observed[engine] = captured(root, schema, adapter, request)
        assert observed[engine][1]['status'] == 'fail' and observed[engine][1]['failures'] == 2
        assert observed[engine][2] == [(2,), (3,)]
        deps = observed[engine][0]['depends_on']['macros']
        assert deps[-3:] == ['macro.preview.get_limit_subquery_sql', 'macro.dbt.should_store_failures', 'macro.dbt.statement']
        assert 'macro.preview.get_test_sql' not in deps
    assert observed['dxt'] == observed['core']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('generic', [False, True])
@pytest.mark.parametrize('limit', [0, 1, None])
def test_core_stock_limit_controls_stored_rows_and_failure_count(tmp_path, request, duckdb_environment, adapter, generic, limit):
    observed = {}
    for engine in ['dxt', 'core']:
        root, schema = fixture(tmp_path, engine, adapter, request, store=True, limit=limit, generic=generic, override_limit=False)
        env = environment(duckdb_environment)
        command(engine, root, env, 'run')
        result = command(engine, root, env, 'test', ok=False)
        count = 3 if limit is None else limit
        assert result.returncode == (1 if count else 0), result.stdout + result.stderr
        observed[engine] = captured(root, schema, adapter, request)
        assert observed[engine][1]['failures'] == count
        assert len(observed[engine][2]) == count
        assert observed[engine][0]['config']['limit'] == limit
        assert observed[engine][0]['depends_on']['macros'][-3:] == ['macro.dbt.get_limit_subquery_sql', 'macro.dbt.should_store_failures', 'macro.dbt.statement']
    assert observed['dxt'] == observed['core']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('cli', [False, True])
def test_core_should_store_false_keeps_configured_identity_and_omits_actual_audit(tmp_path, request, duckdb_environment, adapter, cli):
    observed = {}
    for engine in ['dxt', 'core']:
        root, schema = fixture(tmp_path, engine, adapter, request, store=None if cli else True, should_store=False)
        env = environment(duckdb_environment)
        command(engine, root, env, 'run')
        result = command(engine, root, env, 'test', ['--store-failures'] if cli else [], ok=False)
        assert result.returncode == 1, result.stdout + result.stderr
        observed[engine] = captured(root, schema, adapter, request)
        assert observed[engine][1]['failures'] == 2 and observed[engine][2] is None
        assert observed[engine][0]['relation_name'] is not None and observed[engine][1]['relation_name'] == observed[engine][0]['relation_name']
    assert observed['dxt'] == observed['core']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('policy', ['ephemeral', 'missing_schema', 'precreated'])
def test_core_should_store_true_preserves_config_based_preparation_and_identity(tmp_path, request, duckdb_environment, adapter, policy):
    observed = {}
    for engine in ['dxt', 'core']:
        root, schema = fixture(tmp_path, engine, adapter, request, store=False if policy == 'ephemeral' else None, should_store=True)
        env = environment(duckdb_environment)
        command(engine, root, env, 'run')
        if policy == 'precreated':
            manifest = json.loads((root / 'target/manifest.json').read_text())
            node, = [node for node in manifest['nodes'].values() if node['resource_type'] == 'test']
            if adapter == 'duckdb':
                import duckdb
                with duckdb.connect(str(root / 'warehouse.duckdb')) as connection:
                    connection.execute(f'create schema "{node["schema"]}"')
            else:
                import psycopg2
                with psycopg2.connect(request.getfixturevalue('configuration_postgres').get_uri()) as connection:
                    with connection.cursor() as cursor:
                        cursor.execute(f'create schema "{node["schema"]}"')
        result = command(engine, root, env, 'test', ok=False)
        assert result.returncode == 1, result.stdout + result.stderr
        observed[engine] = captured(root, schema, adapter, request)
        fields, row, rows = observed[engine]
        assert fields['relation_name'] is row['relation_name'] is None
        assert row['status'] == ('fail' if policy == 'precreated' else 'error')
        assert row['failures'] == (2 if policy == 'precreated' else None)
        assert rows == ([(2,), (3,)] if policy == 'precreated' else None)
        assert ('macro.dbt.statement' in fields['depends_on']['macros']) == (policy != 'ephemeral')
    assert observed['dxt'] == observed['core']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('store', [False, True])
def test_core_statement_override_executes_caller_and_retains_direct_dependencies(tmp_path, request, duckdb_environment, adapter, store):
    observed = {}
    for engine in ['dxt', 'core']:
        root, schema = fixture(tmp_path, engine, adapter, request, store=store)
        env = environment(duckdb_environment)
        command(engine, root, env, 'run')
        helpers = root / 'macros/helpers.sql'
        helpers.write_text(helpers.read_text() + STATEMENT)
        result = command(engine, root, env, 'test', ok=False)
        assert result.returncode == 1, result.stdout + result.stderr
        data = captured(root, schema, adapter, request)
        trace = warehouse_rows(root, adapter, request, f'select name from "{schema}"."statement_trace" order by name')
        assert trace == ([('None',), ('main',)] if store else [('main',)])
        assert data[0]['depends_on']['macros'][-1] == 'macro.preview.statement'
        assert data[1]['failures'] == 2
        observed[engine] = (data, trace)
    assert observed['dxt'] == observed['core']

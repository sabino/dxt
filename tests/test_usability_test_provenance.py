"""Test resource metadata and retained audit lifecycle against pinned Core."""
import json

import pytest
import yaml

from test_cli import build_dxt, write_generic_test_config_project  # noqa: F401
from test_usability_adapters import duckdb_environment  # noqa: F401
from test_usability_cli_options import environment, invoke, pinned_core  # noqa: F401
from test_usability_configuration import configuration_postgres  # noqa: F401
from test_usability_sql_operations import command
from test_usability_test_helpers import captured, fixture


def storage_policy(root, generic, kind):
    if generic:
        path = root / 'models/schema.yml'
        document = yaml.safe_load(path.read_text())
        document['models'][0]['data_tests'][0]['bad_rows']['config']['store_failures_as'] = kind
        path.write_text(json.dumps(document))
    else:
        path = root / 'tests/check.sql'
        body = path.read_text()
        if body.startswith('{{ config(store_failures_as='):
            body = body.split('\n', 1)[1]
        path.write_text("{{ config(store_failures_as=" + repr(kind) + ") }}\n" + body)


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('generic', [False, True])
def test_core_repeated_audit_replaces_rows_and_switches_relation_kind(tmp_path, request, duckdb_environment, adapter, generic):
    observations = {}
    for engine in ['dxt', 'core']:
        root, schema = fixture(tmp_path, engine, adapter, request, store=True, generic=generic, override_limit=False)
        env = environment(duckdb_environment)
        command(engine, root, env, 'run')
        first = command(engine, root, env, 'test', ok=False)
        assert first.returncode == 1, first.stdout + first.stderr
        phases = [captured(root, schema, adapter, request)]
        assert phases[-1][1]['status'] == 'fail' and phases[-1][1]['failures'] == 1
        assert phases[-1][2] == [(1,)]

        (root / 'models/input.sql').write_text("{{ config(materialized='table') }}select 1 as id where false")
        command(engine, root, env, 'run')
        for kind in ['table', 'view', 'table']:
            storage_policy(root, generic, kind)
            command(engine, root, env, 'test')
            phase = captured(root, schema, adapter, request)
            assert phase[1]['status'] == 'pass' and phase[1]['failures'] == 0
            assert phase[2] == []
            assert phase[0]['config']['store_failures_as'] == kind
            phases.append(phase)
        observations[engine] = phases
    assert observations['dxt'] == observations['core']


def test_native_profileless_duckdb_replaces_audit_with_empty_relation(tmp_path, duckdb_environment):
    import duckdb
    project = tmp_path / 'project'
    target = tmp_path / 'target'
    write_generic_test_config_project(project, severity='error', error_if='> 0', store_failures=True)
    env = environment(duckdb_environment)
    env['HOME'] = str(tmp_path / 'empty-home')
    args = ['--quiet', '--no-use-colors', '--project-dir', project, '--target-path', target]
    invoke('dxt', ['run', *args, '--select', 'customers'], project, env)
    first = invoke('dxt', ['test', *args, '--select', 'not_null_customers_customer_id'], project, env, ok=False)
    assert first.returncode == 1, first.stdout + first.stderr
    first_rows = json.loads((target / 'run_results.json').read_text())['results']
    row, = first_rows
    assert row['status'] == 'fail' and row['failures'] == 1
    write_generic_test_config_project(project, severity='error', error_if='> 0', where="status = 'missing'", store_failures=True)
    invoke('dxt', ['build', *args, '--select', 'customers+'], project, env)
    rows = json.loads((target / 'run_results.json').read_text())['results']
    assert {row['unique_id']: row['status'] for row in rows} == {
        'model.generic_test_config_tests.customers': 'success',
        'test.generic_test_config_tests.not_null_customers_customer_id.5c9bf9911d': 'pass',
    }
    test_row, = [row for row in rows if row['unique_id'].startswith('test.')]
    assert test_row['failures'] == 0
    assert test_row['relation_name'] == '"main_dbt_test__audit"."not_null_customers_customer_id"'
    with duckdb.connect(str(target / 'dxt.duckdb')) as connection:
        assert connection.execute('select count(*) from "main_dbt_test__audit"."not_null_customers_customer_id"').fetchone() == (0,)


INHERITED = ['columns', 'docs', 'contract', 'metrics', 'meta', 'group']


def read_test_node(root, target=None):
    from test_usability_artifacts import contracts
    target = target or root / 'target'
    contracts.assert_artifact(target / 'manifest.json')
    manifest = json.loads((target / 'manifest.json').read_text())
    node, = [node for node in manifest['nodes'].values() if node['resource_type'] == 'test']
    return node


def metadata_policy(root, generic, *, attached_group=False):
    config = {'meta': {'owner': 'analytics', 'levels': [1, True, None]},
              'docs': {'show': False, 'node_color': '#123456'}, 'group': 'finance',
              'contract': {'enforced': True, 'alias_types': False}}
    path = root / 'models/schema.yml'
    document = yaml.safe_load(path.read_text()) if path.exists() else {'version': 2}
    document['groups'] = [{'name': 'finance', 'owner': {'name': 'Test owner'}}]
    if generic:
        model = document['models'][0]
        model['columns'] = [{'name': 'id', 'description': 'Model column, not test columns'}]
        if attached_group:
            model['config'] = {'group': 'finance'}
        model['data_tests'][0]['bad_rows']['config'].update(config)
    else:
        document['data_tests'] = [{'name': 'check', 'config': config}]
    path.write_text(json.dumps(document))
    return config


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('generic', [False, True])
def test_core_inherited_test_metadata_and_parse_cache_creation_time(tmp_path, request, duckdb_environment, adapter, generic):
    import time
    observations = {}
    for engine in ['dxt', 'core']:
        root, _ = fixture(tmp_path, engine, adapter, request, store=True, generic=generic, override_limit=False)
        config = metadata_policy(root, generic)
        env = environment(duckdb_environment)
        before = time.time()
        command(engine, root, env, 'parse')
        first = read_test_node(root)
        assert before <= first['created_at'] <= time.time()
        assert first['build_path'] is None
        assert first['columns'] == {} and first['metrics'] == []
        assert first['contract'] == {**config['contract'], 'checksum': None}
        assert first['docs'] == config['docs'] and first['meta'] == config['meta']
        assert first['group'] == (None if generic else 'finance')
        if generic:
            assert first['file_key_name'] == 'models.input'
        else:
            assert 'file_key_name' not in first
        command(engine, root, env, 'parse')
        cached = read_test_node(root)
        assert cached['created_at'] == first['created_at']
        if generic:
            metadata_policy(root, generic, attached_group=True)
            command(engine, root, env, 'parse')
            updated = read_test_node(root)
            assert updated['created_at'] > first['created_at']
            assert updated['group'] == 'finance'
        else:
            updated = cached
        observations[engine] = ({field: first[field] for field in INHERITED},
                                {field: updated[field] for field in INHERITED})
    assert observations['dxt'] == observations['core']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('generic', [False, True])
@pytest.mark.parametrize('warehouse_error', [False, True])
def test_core_test_write_publishes_real_path_after_success_or_warehouse_error(tmp_path, request, duckdb_environment, adapter, generic, warehouse_error):
    from pathlib import Path
    from test_usability_artifacts import contracts
    from test_usability_sql_operations import events
    observations = {}
    for engine in ['dxt', 'core']:
        root, _ = fixture(tmp_path, engine, adapter, request, store=True, generic=generic, override_limit=False)
        metadata_policy(root, generic)
        env = environment(duckdb_environment)
        command(engine, root, env, 'run')
        query = 'select missing_runtime_column as failures, false as should_warn, false as should_error' if warehouse_error else 'select 0 as failures, false as should_warn, false as should_error'
        (root / 'macros/test_materialization.sql').write_text('''{% materialization test, default %}
{% set before = model.copy() %}
{% set filename = write(sql) %}
{% set after = model.copy() %}
{{ log('PROVENANCE:' ~ tojson({'before': before, 'after': after, 'written': filename}), info=True) }}
{% call statement('main', fetch_result=True) %}''' + query + '''{% endcall %}
{% endmaterialization %}
''')
        target = root / ('output' if warehouse_error else 'target')
        flags = ['--target-path', target] if warehouse_error else []
        result = command(engine, root, env, 'test', flags, quiet=False, ok=not warehouse_error)
        assert result.returncode == (1 if warehouse_error else 0), result.stdout + result.stderr
        node = read_test_node(root, target)
        contracts.assert_artifact(target / 'run_results.json')
        row, = json.loads((target / 'run_results.json').read_text())['results']
        assert row['status'] == ('error' if warehouse_error else 'pass')
        assert row['failures'] == (None if warehouse_error else 0)
        assert node['compiled'] is row['compiled'] is True
        assert node['compiled_code'] == row['compiled_code']
        assert node['build_path'] is not None
        written = Path(node['build_path'])
        if not written.is_absolute():
            written = root / written
        # Core's stock statement('main') performs the final write of executed SQL.
        assert written.read_text() == query
        logical = 'models/schema.yml/bad_rows_input_.sql' if generic else 'tests/check.sql'
        assert str(written) == str(target / 'run/preview' / logical)
        message, = [event['data']['msg'][len('PROVENANCE:'):] for event in events(result, 'JinjaLogInfo')
                    if event['data']['msg'].startswith('PROVENANCE:')]
        runtime = json.loads(message)
        assert runtime['written'] == ''
        for phase in ['before', 'after']:
            context = runtime[phase]
            assert context['created_at'] == node['created_at']
            assert 'build_path' not in context
            expected_context = {field: node[field] for field in INHERITED if node[field] is not None}
            expected_context['contract'] = {key: value for key, value in node['contract'].items() if value is not None}
            expected_context['docs'] = {key: value for key, value in node['docs'].items() if value is not None}
            assert {field: context[field] for field in expected_context} == expected_context
            assert context['compiled'] is True and context['compiled_code'] == node['compiled_code']
            assert context.get('file_key_name') == node.get('file_key_name')
        observations[engine] = ({field: node[field] for field in INHERITED},
                                node['build_path'].replace(str(root), '<project>'),
                                node['depends_on']['macros'], row['status'], row['failures'], runtime['written'])
    assert observations['dxt'] == observations['core']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('generic', [False, True])
def test_core_compile_test_write_records_path_without_executing_test(tmp_path, request, duckdb_environment, adapter, generic):
    from pathlib import Path
    from test_usability_artifacts import contracts
    observations = {}
    for engine in ['dxt', 'core']:
        root, schema = fixture(tmp_path, engine, adapter, request, store=True, generic=generic, override_limit=False)
        env = environment(duckdb_environment)
        if generic:
            path = root / 'macros/bad_rows.sql'
            path.write_text("{% test bad_rows(model) %}{% if execute %}{% do write('actual compile payload') %}{% endif %}select * from {{ model }}{% endtest %}")
        else:
            path = root / 'tests/check.sql'
            path.write_text("{% if execute %}{% do write('actual compile payload') %}{% endif %}" + path.read_text())
        command(engine, root, env, 'compile', ['--no-populate-cache'])
        node = read_test_node(root)
        artifact = json.loads((root / 'target/run_results.json').read_text())
        contracts.assert_artifact(root / 'target/run_results.json')
        row, = [row for row in artifact['results'] if row['unique_id'] == node['unique_id']]
        assert row['status'] == 'success' and row['failures'] is None
        assert node['build_path'] is not None
        written = Path(node['build_path'])
        if not written.is_absolute():
            written = root / written
        assert written.read_text() == 'actual compile payload'
        assert node['compiled_code'] == row['compiled_code']
        observations[engine] = (node['build_path'], node['depends_on']['macros'], row['compiled_code'].replace(schema, 'target_schema'))
    # Default target paths in the artifact are logical, relative project paths.
    assert observations['dxt'] == observations['core']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_generic_file_key_names_follow_model_seed_snapshot_and_source_origins(tmp_path, request, duckdb_environment, adapter):
    observations = {}
    for engine in ['dxt', 'core']:
        root, schema = fixture(tmp_path, engine, adapter, request, store=False, generic=True, override_limit=False)
        (root / 'seeds/items.csv').write_text('id\n1\n')
        (root / 'snapshots').mkdir()
        (root / 'snapshots/state.sql').write_text("{% snapshot state %}{{ config(strategy='timestamp', unique_key='id', updated_at='updated_at', target_schema='" + schema + "') }}select 1 as id, current_timestamp as updated_at{% endsnapshot %}")
        path = root / 'models/schema.yml'
        document = yaml.safe_load(path.read_text())
        document['seeds'] = [{'name': 'items', 'data_tests': ['bad_rows']}]
        document['snapshots'] = [{'name': 'state', 'data_tests': ['bad_rows']}]
        document['sources'] = [{'name': 'external', 'schema': schema, 'tables': [{'name': 'source_items', 'data_tests': ['bad_rows']}]}]
        path.write_text(json.dumps(document))
        command(engine, root, environment(duckdb_environment), 'parse')
        from test_usability_artifacts import contracts
        contracts.assert_artifact(root / 'target/manifest.json')
        manifest = json.loads((root / 'target/manifest.json').read_text())
        nodes = [node for node in manifest['nodes'].values() if node['resource_type'] == 'test']
        assert len(nodes) == 4
        actual = {node['file_key_name'] for node in nodes}
        assert actual == {'models.input', 'seeds.items', 'snapshots.state', 'sources.external'}
        observations[engine] = {node['unique_id']: node['file_key_name'] for node in nodes}
    assert observations['dxt'] == observations['core']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('generic', [False, True])
def test_core_test_context_preserves_arbitrary_nested_nulls_and_config_extras(tmp_path, request, duckdb_environment, adapter, generic):
    from test_usability_sql_operations import events
    observations = {}
    for engine in ['dxt', 'core']:
        root, _ = fixture(tmp_path, engine, adapter, request, store=False, generic=generic, override_limit=False)
        metadata_policy(root, generic)
        path = root / 'models/schema.yml'
        document = yaml.safe_load(path.read_text())
        config = document['models'][0]['data_tests'][0]['bad_rows']['config'] if generic else document['data_tests'][0]['config']
        config.update({'meta': {'nullable': None, 'nested': {'nullable': None}, 'items': [None, {'nullable': None}]},
                       'docs': {'show': True, 'node_color': None},
                       'contract': {'enforced': False, 'alias_types': True, 'checksum': None},
                       'custom_null': None})
        if generic:
            document['models'][0]['data_tests'][0]['bad_rows']['payload'] = {'nullable': None}
            (root / 'macros/bad_rows.sql').write_text('{% test bad_rows(model, payload=None) %}{{ config(custom_null=None) }}select * from {{ model }}{% endtest %}')
        path.write_text(json.dumps(document))
        env = environment(duckdb_environment)
        command(engine, root, env, 'run')
        (root / 'macros/test_materialization.sql').write_text('''{% materialization test, default %}
{{ log('NULL_CONTEXT:' ~ tojson(model.copy()), info=True) }}
{% call statement('main', fetch_result=True) %}select 0 as failures, false as should_warn, false as should_error{% endcall %}
{% endmaterialization %}
''')
        result = command(engine, root, env, 'test', quiet=False)
        message, = [event['data']['msg'][len('NULL_CONTEXT:'):] for event in events(result, 'JinjaLogInfo')
                    if event['data']['msg'].startswith('NULL_CONTEXT:')]
        context = json.loads(message)
        assert context['meta'] == context['config']['meta'] == config['meta']
        assert context['config']['custom_null'] is None
        assert context['config']['docs']['node_color'] is None
        assert context['config']['contract']['checksum'] is None
        assert 'node_color' not in context['docs'] and 'checksum' not in context['contract']
        assert 'database' not in context['config'] and 'build_path' not in context
        if generic:
            assert context['test_metadata']['kwargs']['payload'] == {'nullable': None}
            assert 'namespace' not in context['test_metadata']
        observations[engine] = {field: context[field] for field in ['meta', 'docs', 'contract', 'config']}
    assert observations['dxt'] == observations['core']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('setting', [False, None])
@pytest.mark.parametrize('generic', [False, True])
def test_core_falsy_test_docs_and_contract_retain_inherited_defaults(tmp_path, request, duckdb_environment, adapter, setting, generic):
    observations = {}
    for engine in ['dxt', 'core']:
        root, _ = fixture(tmp_path, engine, adapter, request, store=False, generic=generic, override_limit=False)
        path = root / 'models/schema.yml'
        document = yaml.safe_load(path.read_text()) if path.exists() else {'version': 2}
        if generic:
            document['models'][0]['data_tests'][0]['bad_rows']['config'].update({'docs': setting, 'contract': setting})
        else:
            document['data_tests'] = [{'name': 'check', 'config': {'docs': setting, 'contract': setting}}]
        path.write_text(json.dumps(document))
        result = command(engine, root, environment(duckdb_environment), 'parse', ok=False)
        if generic and setting is False:
            assert result.returncode == 2, result.stdout + result.stderr
            assert not (root / 'target/manifest.json').exists()
            observations[engine] = result.returncode
            continue
        assert result.returncode == 0, result.stdout + result.stderr
        node = read_test_node(root)
        assert node['docs'] == {'show': True, 'node_color': None}
        assert node['contract'] == {'enforced': False, 'alias_types': True, 'checksum': None}
        if generic:
            assert 'docs' not in node['config'] and 'contract' not in node['config']
        else:
            assert node['config']['docs'] == node['config']['contract'] == setting
        observations[engine] = {field: node[field] for field in ['docs', 'contract', 'config']}
    assert observations['dxt'] == observations['core']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('contract', [{'enforced': 'yes'}, {'custom': True}])
def test_core_invalid_test_contract_types_and_unknown_fields_fail_before_artifacts(tmp_path, request, duckdb_environment, adapter, contract):
    for engine in ['dxt', 'core']:
        root, _ = fixture(tmp_path, engine, adapter, request, store=False, generic=True, override_limit=False)
        path = root / 'models/schema.yml'
        document = yaml.safe_load(path.read_text())
        document['models'][0]['data_tests'][0]['bad_rows']['config']['contract'] = contract
        path.write_text(json.dumps(document))
        result = command(engine, root, environment(duckdb_environment), 'parse', ok=False)
        assert result.returncode == 2, result.stdout + result.stderr
        assert not (root / 'target/manifest.json').exists()

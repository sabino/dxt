"""Authored test materialization and runtime model edges against pinned Core."""
import json

import pytest

from test_usability_sql_operations import command, events
from test_usability_test_helpers import (
    build_dxt,  # noqa: F401
    captured,
    configuration_postgres,  # noqa: F401
    duckdb_environment,  # noqa: F401
    environment,
    fixture,
    pinned_core,  # noqa: F401
)


REORDERED_MAIN = """{% materialization test, default %}
{% call statement('main', fetch_result=True) %}
select true as SHOULD_ERROR, 1 as FaIlUrEs, true as SHOULD_WARN
{% endcall %}
{% endmaterialization %}
"""
METADATA_PREFIX = 'test-helper-model-metadata:'


def manifest_test_node(root):
    manifest = json.loads((root / 'target/manifest.json').read_text())
    node, = [node for node in manifest['nodes'].values() if node['resource_type'] == 'test']
    return node


def resource_path(node):
    original, path = node['original_file_path'], node['path']
    return original if original.split('/')[-1] == path.split('/')[-1] else original + '/' + path


def normalize_schema(value, schema):
    if isinstance(value, str):
        return value.replace(schema, 'target_schema')
    if isinstance(value, list):
        return [normalize_schema(item, schema) for item in value]
    if isinstance(value, dict):
        return {key: normalize_schema(item, schema) for key, item in value.items()}
    return value


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('generic', [False, True])
def test_core_test_materialization_accepts_implicit_return_and_named_reordered_results(tmp_path, request, duckdb_environment, adapter, generic):
    observed = {}
    for engine in ['dxt', 'core']:
        root, schema = fixture(tmp_path, engine, adapter, request, store=False, generic=generic, override_limit=False)
        env = environment(duckdb_environment)
        command(engine, root, env, 'run')
        (root / 'macros/test_materialization.sql').write_text(REORDERED_MAIN)
        result = command(engine, root, env, 'test', ok=False)
        assert result.returncode == 1, result.stdout + result.stderr
        data = captured(root, schema, adapter, request)
        fields, row, audit_rows = data
        assert row['status'] == 'fail' and row['failures'] == 1
        assert fields['relation_name'] is row['relation_name'] is None
        assert audit_rows is None
        assert row['adapter_response'] == ({'_message': 'OK'} if adapter == 'duckdb' else {'_message': 'SELECT 1', 'code': 'SELECT', 'rows_affected': 1})
        node = manifest_test_node(root)
        runtime_sql = (root / 'target/run/preview' / resource_path(node)).read_text()
        assert '1 as FaIlUrEs' in runtime_sql and 'true as SHOULD_ERROR' in runtime_sql
        assert fields['depends_on']['macros'][-1] == 'macro.dbt.statement'
        assert 'macro.preview.materialization_test_default' not in fields['depends_on']['macros']
        observed[engine] = (data, runtime_sql)
    assert observed['dxt'] == observed['core']


def add_metadata(root, schema, generic):
    description = 'An authored resource inspected by its runtime helper.'
    tags = ['metadata', 'runtime']
    source = {'name': 'raw', 'schema': schema, 'tables': [{'name': 'input'}]}
    if generic:
        config = {'alias': 'audit', 'store_failures': True, 'limit': 1, 'tags': tags}
        declaration = {'bad_rows': {'description': description, 'source_table': "{{ source('raw', 'input') }}", 'config': config}}
        properties = {'version': 2, 'sources': [source], 'models': [{'name': 'input', 'data_tests': [declaration]}]}
        (root / 'macros/bad_rows.sql').write_text('{% test bad_rows(model, source_table) %}select * from {{ model }} union all select * from {{ source_table }}{% endtest %}')
        (root / 'models/schema.yml').write_text(json.dumps(properties))
    else:
        properties = {'version': 2, 'sources': [source], 'data_tests': [{'name': 'check', 'description': description, 'config': {'tags': tags}}]}
        (root / 'models/schema.yml').write_text(json.dumps(properties))
        sql = root / 'tests/check.sql'
        sql.write_text(sql.read_text() + " union all select * from {{ source('raw', 'input') }}")


def metadata_expectation(node, generic):
    fields = ['path', 'raw_code', 'tags', 'sources', 'description', 'fqn', 'compiled_code', 'compiled']
    if generic:
        fields += ['attached_node', 'test_metadata']
    expected = {field: node[field] for field in fields}
    # Runtime ModelContext.model uses to_dict(omit_none=True).
    expected['refs'] = [{key: value for key, value in ref.items() if value is not None} for ref in node['refs']]
    expected['compiled_sql'] = node['compiled_code']
    def omit_none(value):
        if isinstance(value, dict):
            return {key: omit_none(item) for key, item in value.items() if item is not None}
        if isinstance(value, list):
            return [omit_none(item) for item in value]
        return value
    return omit_none(expected)


def metadata_macro(expected):
    fields = ', '.join(repr(name) + ': model.' + name for name in expected)
    return """{% macro should_store_failures() %}
{% set expected = fromjson(""" + repr(json.dumps(expected)) + """) %}
{% set actual = {""" + fields + """} %}
{% if actual != expected %}
{{ exceptions.raise_compiler_error('Runtime resource metadata mismatch: ' ~ tojson(actual)) }}
{% endif %}
{{ log('""" + METADATA_PREFIX + """' ~ tojson(actual), info=True) }}
{{ return(false) }}
{% endmacro %}
"""


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('generic', [False, True])
def test_core_runtime_test_helper_observes_complete_authored_and_compiled_model(tmp_path, request, duckdb_environment, adapter, generic):
    observed = {}
    for engine in ['dxt', 'core']:
        root, schema = fixture(tmp_path, engine, adapter, request, store=True, generic=generic, override_limit=False)
        add_metadata(root, schema, generic)
        env = environment(duckdb_environment)
        command(engine, root, env, 'run')
        command(engine, root, env, 'compile', ['--select', 'resource_type:test'])
        expected = metadata_expectation(manifest_test_node(root), generic)
        assert expected['compiled'] is True and expected['compiled_code']
        assert expected['tags'] == ['metadata', 'runtime']
        assert expected['refs'] and expected['sources'] == [['raw', 'input']]
        helpers = root / 'macros/helpers.sql'
        helpers.write_text(helpers.read_text() + metadata_macro(expected))
        result = command(engine, root, env, 'test', ok=False, quiet=False)
        assert result.returncode == 1, result.stdout + result.stderr
        data = captured(root, schema, adapter, request)
        fields, row, audit_rows = data
        assert row['status'] == 'fail' and row['failures'] == 1
        assert audit_rows is None
        assert fields['relation_name'] is not None and row['relation_name'] == fields['relation_name']
        messages = [event['data']['msg'][len(METADATA_PREFIX):] for event in events(result, 'JinjaLogInfo') if event['data']['msg'].startswith(METADATA_PREFIX)]
        message, = messages
        assert json.loads(message) == metadata_expectation(manifest_test_node(root), generic) == expected
        assert 'macro.preview.should_store_failures' in fields['depends_on']['macros']
        observed[engine] = (data, normalize_schema(json.loads(message), schema))
    assert observed['dxt'] == observed['core']

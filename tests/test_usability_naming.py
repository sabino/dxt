"""Pinned Core name-generation policy, identity and cache evidence."""
import json
import subprocess

import pytest

from test_cli import DXT, ROOT, build_dxt
from test_usability_artifacts import contracts
from test_usability_configuration import (
    ConfigurationPair, configuration_oracle, configuration_postgres, configure_adapter,
)

ROOT_NAMES = """
{% macro generate_database_name(custom_database_name, node) %}
{% if execute %}{{ exceptions.raise_compiler_error('naming must parse') }}{% endif %}
{{ return('  ' ~ (custom_database_name if custom_database_name is not none else target.database) ~ '  ') }}
{% endmacro %}
{% macro generate_schema_name(custom_schema_name, node) %}
{{ return('  ' ~ target.schema ~ '_' ~ node.resource_type ~ '_' ~ ('none' if custom_schema_name is none else custom_schema_name | trim) ~ '  ') }}
{% endmacro %}
{% macro generate_alias_name(custom_alias_name, node) %}
{{ return('  ' ~ node.name ~ '_named' ~ ('_v' ~ node.version if node.version else '') ~ '  ') }}
{% endmacro %}
"""


def project(tmp_path, oracle, request, adapter='duckdb'):
    pair = ConfigurationPair(tmp_path, oracle)
    configure_adapter(pair, request, adapter)
    pair.write('macros/names.sql', ROOT_NAMES)
    pair.write('models/marts/base.sql', "{{ config(materialized='table', schema=' custom ', alias='ignored') }}select 1 as id")
    pair.write('models/marts/consumer.sql', "select * from {{ ref('base') }}")
    pair.write('models/marts/disabled.sql', "{{ config(enabled=false) }}select 2 as id")
    pair.write('models/schema.yml', """version: 2
models:
  - name: base
    columns:
      - name: id
        data_tests:
          - not_null: {config: {store_failures: true}}
""")
    pair.write('seeds/data.csv', 'id\n1\n')
    pair.write('tests/assert.sql', "{{ config(store_failures=true, alias='ignored', schema=' audit ') }}select 1 where false")
    pair.write('analyses/report.sql', 'select * from {{ ref("base") }}')
    pair.write('snapshots/legacy.sql', "{% snapshot legacy %}{{ config(target_schema='legacy_target', unique_key='id', strategy='check', check_cols='all') }}select 1 as id{% endsnapshot %}")
    return pair


def assert_identity(actual, expected):
    assert set(actual['nodes']) == set(expected['nodes'])
    for name, node in expected['nodes'].items():
        for field in ['database', 'schema', 'alias', 'relation_name', 'config', 'unrendered_config', 'depends_on']:
            assert actual['nodes'][name].get(field) == node.get(field), (name, field)
        if node.get('compiled'):
            assert actual['nodes'][name]['compiled_code'] == node['compiled_code'], name
    assert set(actual['disabled']) == set(expected['disabled'])
    for name, nodes in expected['disabled'].items():
        for field in ['database', 'schema', 'alias', 'relation_name', 'config']:
            assert actual['disabled'][name][0].get(field) == nodes[0].get(field), (name, field)


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('command', ['parse', 'compile'])
def test_core_root_policy_all_resource_and_disabled_identities(tmp_path, configuration_oracle, request, adapter, command):
    pair = project(tmp_path, configuration_oracle, request, adapter)
    actual, expected = pair.invoke(command)
    assert_identity(actual, expected)
    for path in pair.projects:
        contracts.assert_artifact(path / 'target/manifest.json')


@pytest.mark.parametrize('own_schema', [False, True])
def test_core_imported_package_generators_and_root_macro_variable_scope(tmp_path, configuration_oracle, own_schema):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.append_project("vars: {policy: root, dep: {policy: dependency}}\n")
    pair.write('macros/root.sql', """
{% macro generate_schema_name(custom_schema_name, node) %}{{ return(target.schema ~ '_' ~ var('policy')) }}{% endmacro %}
{% macro generate_alias_name(custom_alias_name, node) %}{{ return(node.name ~ '_' ~ var('policy')) }}{% endmacro %}
""")
    pair.write('dbt_packages/dep/dbt_project.yml', "name: dep\nversion: '1.0'\nvars: {policy: local}\n")
    pair.write('dbt_packages/dep/models/dependency.sql', 'select 1 as id')
    pair.write('models/marts/root.sql', "select * from {{ ref('dep', 'dependency') }}")
    if own_schema:
        pair.write('dbt_packages/dep/macros/names.sql', "{% macro generate_schema_name(custom_schema_name, node) %}{{ return(target.schema ~ '_' ~ var('policy')) }}{% endmacro %}")
    actual, expected = pair.invoke()
    assert_identity(actual, expected)
    assert actual['nodes']['model.dep.dependency']['schema'] == ('main_dependency' if own_schema else 'main_root')
    assert actual['nodes']['model.dep.dependency']['alias'] == 'dependency_root'


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_adapter_dispatch_naming_and_env_cli_vars(tmp_path, configuration_oracle, monkeypatch, request, adapter):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    monkeypatch.setenv('DXT_NAME_SUFFIX', 'env')
    pair.append_project("vars: {policy: project}\n")
    pair.write('macros/dispatch.sql', "{% macro " + adapter + "__generate_schema_name(custom_schema_name, node) %}{{ return(target.schema ~ '_' ~ var('policy') ~ '_' ~ env_var('DXT_NAME_SUFFIX')) }}{% endmacro %}")
    pair.write('models/marts/value.sql', "select '{{ this.schema }}' as schema_name")
    actual, expected = pair.invoke(flags=['--vars', '{policy: cli}'])
    assert_identity(actual, expected)
    assert actual['nodes']['model.configuration_fixture.value']['schema'] == 'main_cli_env'


def test_core_unrelated_package_generator_does_not_replace_root_default(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('dbt_packages/other/dbt_project.yml', "name: other\nversion: '1.0'\n")
    pair.write('dbt_packages/other/macros/names.sql', "{% macro generate_schema_name(custom_schema_name, node) %}{{ return('unrelated') }}{% endmacro %}")
    pair.write('models/marts/value.sql', "{{ config(schema='custom') }}select '{{ this.schema }}' as schema_name")
    actual, expected = pair.invoke()
    assert_identity(actual, expected)
    assert actual['nodes']['model.configuration_fixture.value']['schema'] == 'main_custom'


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_version_alias_and_yaml_snapshot_policy(tmp_path, configuration_oracle, request, adapter):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('macros/names.sql', ROOT_NAMES)
    pair.write('models/orders_v1.sql', 'select 1 as id')
    pair.write('models/orders_v2.sql', 'select 2 as id')
    pair.write('models/schema.yml', """version: 2
models:
  - name: orders
    latest_version: 2
    versions: [{v: 1}, {v: 2}]
""")
    pair.write('models/marts/consumer.sql', "select * from {{ ref('orders') }} union all select * from {{ ref('orders', version=1) }}")
    pair.write('snapshots/definitions.yml', """version: 2
snapshots:
  - name: history
    relation: ref('orders')
    config: {schema: archive, strategy: check, unique_key: id, check_cols: all}
""")
    actual, expected = pair.invoke()
    assert_identity(actual, expected)
    assert actual['nodes']['model.configuration_fixture.orders.v1']['alias'] == 'orders_named_v1'
    assert actual['nodes']['snapshot.configuration_fixture.history']['schema'] == 'main_snapshot_archive'


def test_core_database_none_and_whitespace_only_alias_are_preserved(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('macros/names.sql', """
{% macro generate_database_name(custom_database_name, node) %}{{ return(none) }}{% endmacro %}
{% macro generate_alias_name(custom_alias_name, node) %}{{ return('   ') }}{% endmacro %}
""")
    pair.write('models/marts/value.sql', 'select 1 as id')
    actual, expected = pair.invoke('parse')
    assert_identity(actual, expected)
    assert actual['nodes']['model.configuration_fixture.value']['database'] is None
    assert actual['nodes']['model.configuration_fixture.value']['alias'] == ''


@pytest.mark.parametrize('result', ['7', 'false'])
def test_core_invalid_naming_types_fail_without_warehouse_writes(tmp_path, configuration_oracle, result):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('macros/names.sql', "{% macro generate_alias_name(custom_alias_name, node) %}{{ return(" + result + ") }}{% endmacro %}")
    pair.write('models/marts/value.sql', 'select 1 as id')
    actual, reference = pair.invoke('parse', success=False)
    assert actual.returncode != 0
    assert 'naming macro' in actual.stderr
    assert not (pair.projects[0] / 'warehouse.duckdb').exists()


def test_named_identity_warm_cache_and_macro_edits_recompute_every_consumer(tmp_path, configuration_oracle, request):
    pair = project(tmp_path, configuration_oracle, request)
    first, _ = pair.invoke()
    result = subprocess.run([DXT, 'compile', '--project-dir', str(pair.projects[0]), '--profiles-dir', str(pair.projects[0])], cwd=ROOT, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    cached = json.loads((pair.projects[0] / 'target/manifest.json').read_text())
    assert_identity(cached, first)
    assert json.loads((pair.projects[0] / 'target/dxt_parse_cache.json').read_text())['graph']['nodes'][0]['resolved_identity'] is not None
    pair.write('macros/names.sql', ROOT_NAMES.replace('_named', '_changed'))
    changed, expected = pair.invoke()
    assert_identity(changed, expected)
    assert changed['nodes']['model.configuration_fixture.base']['alias'] == 'base_changed'
    assert 'base_changed' in changed['nodes']['model.configuration_fixture.consumer']['compiled_code']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_saved_query_export_generators_preserve_explicit_schema_and_alias(tmp_path, configuration_oracle, request, adapter):
    import yaml
    from test_usability_semantics import SEMANTIC_YAML

    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('models/orders.sql', "select 1 as id, 1 as customer_id, 10 as amount, date '2024-01-01' as ordered_at, 'paid' as status")
    pair.write('models/customers.sql', "select 1 as id, 'US' as country")
    pair.write('models/metricflow_time_spine.sql', "select date '2024-01-01' as date_day")
    semantic = yaml.safe_load(SEMANTIC_YAML)
    del semantic['saved_queries'][0]['query_params']['order_by']
    semantic['saved_queries'][0]['exports'] = [
        {'name': 'generated', 'config': {'export_as': 'table'}},
        {'name': 'explicit', 'config': {'export_as': 'view', 'schema': 'ignored', 'schema_name': 'reporting', 'alias': 'kept', 'database': 'ignored_database'}},
        {'name': 'empty', 'config': {'export_as': 'table', 'schema_name': '', 'alias': ''}},
    ]
    pair.write('models/semantic.yml', yaml.safe_dump(semantic))
    pair.write('macros/names.sql', """
{% macro generate_database_name(custom_database_name, node) %}{{ return(target.database) }}{% endmacro %}
{% macro generate_schema_name(custom_schema_name, node) %}{{ return(target.schema ~ '_' ~ node.name ~ ('_node' if node.resource_type is defined else '_export')) }}{% endmacro %}
{% macro generate_alias_name(custom_alias_name, node) %}{{ return(node.name ~ '_named') }}{% endmacro %}
""")
    actual, expected = pair.invoke('parse')
    assert_identity(actual, expected)
    for section in ['saved_queries', 'semantic_models']:
        assert set(actual[section]) == set(expected[section])
        for key in actual[section]:
            # Resource creation timestamps vary between independent invocations.
            native = {k: v for k, v in actual[section][key].items() if k != 'created_at'}
            core = {k: v for k, v in expected[section][key].items() if k != 'created_at'}
            assert native == core, key
    exports = actual['saved_queries']['saved_query.configuration_fixture.daily_revenue']['exports']
    assert exports[0]['config']['schema_name'] == 'main_generated_export'
    assert exports[1]['config']['schema_name'] == 'reporting'
    assert exports[1]['config']['alias'] == 'kept'
    assert exports[1]['config']['database'] == actual['nodes']['model.configuration_fixture.orders']['database']
    assert exports[2]['config']['alias'] == 'empty_named'
    for path in pair.projects:
        contracts.assert_artifact(path / 'target/manifest.json')


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_name_component_order_and_typed_node_config(tmp_path, configuration_oracle, request, adapter):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('models/marts/value.sql', "{{ config(schema='custom', alias='authored', meta={'suffix': 'metadata'}) }}select '{{ this.identifier }}' as identifier")
    pair.write('macros/names.sql', """
{% macro generate_database_name(custom_database_name, node) %}
  {% if node.schema != target.schema %}{{ exceptions.raise_compiler_error('database must run first') }}{% endif %}
  {{ return(target.database) }}
{% endmacro %}
{% macro generate_schema_name(custom_schema_name, node) %}
  {% if node.database != target.database %}{{ exceptions.raise_compiler_error('schema requires database result') }}{% endif %}
  {{ return(target.schema ~ '_' ~ custom_schema_name) }}
{% endmacro %}
{% macro generate_alias_name(custom_alias_name, node) %}
  {{ return(node.schema ~ '_' ~ node.config.meta.suffix ~ '_' ~ custom_alias_name) }}
{% endmacro %}
""")
    actual, expected = pair.invoke()
    assert_identity(actual, expected)
    assert actual['nodes']['model.configuration_fixture.value']['alias'] == 'main_custom_metadata_authored'


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_root_where_helper_override_is_rendered_and_recorded(tmp_path, configuration_oracle, request, adapter):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('models/marts/value.sql', '{{ config(materialized="table") }}select 1 as id union all select null as id')
    pair.write('models/schema.yml', "version: 2\nmodels:\n  - name: value\n    columns:\n      - name: id\n        data_tests: [not_null]\n")
    pair.write('macros/where.sql', "{% macro get_where_subquery(relation) %}{{ return('(select * from ' ~ relation ~ ' where id is not null) dbt_subquery') }}{% endmacro %}")
    actual, expected = pair.invoke('compile')
    assert_identity(actual, expected)
    test = next(node for node in actual['nodes'].values() if node['resource_type'] == 'test')
    assert 'macro.configuration_fixture.get_where_subquery' in test['depends_on']['macros']
    assert 'where id is not null' in test['compiled_code']
    pair.invoke('build')
    for path in pair.projects:
        assert all(row['status'] in ['success', 'pass'] for row in json.loads((path / 'target/run_results.json').read_text())['results'])


def test_core_unicode_name_trimming_and_generic_yaml_fqn_metadata(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('models/marts/value.sql', "{{ config(meta={'suffix': 'model'}) }}select '{{ this.identifier }}' as id")
    pair.write('models/marts/schema.yml', """version: 2
models:
  - name: value
    columns:
      - name: id
        data_tests:
          - not_null: {config: {meta: {suffix: audit}}}
""")
    pair.write('tests/checks/assert.sql', "{{ config(meta={'suffix': 'singular'}) }}select 1 where false")
    pair.write('macros/names.sql', "{% macro generate_alias_name(custom_alias_name, node) %}{{ return('\u2003\u00a0' ~ node.fqn | join('_') ~ '_' ~ node.meta.get('suffix', 'default') ~ '\u00a0\u2003') }}{% endmacro %}")
    actual, expected = pair.invoke('parse')
    assert_identity(actual, expected)
    assert actual['nodes']['model.configuration_fixture.value']['alias'] == 'configuration_fixture_marts_value_model'
    test = next(node for node in actual['nodes'].values() if node['resource_type'] == 'test' and node['name'].startswith('not_null'))
    assert test['alias'] == 'configuration_fixture_marts_not_null_value_id_audit'


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_generic_model_argument_retains_empty_input_relation_policy(tmp_path, configuration_oracle, request, adapter):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('models/marts/value.sql', '{{ config(materialized="table") }}select cast(null as integer) as id')
    pair.write('models/schema.yml', "version: 2\nmodels:\n  - name: value\n    columns:\n      - name: id\n        data_tests: [not_null]\n")
    pair.invoke('build', flags=['--empty'])
    rows = [json.loads((path / 'target/run_results.json').read_text())['results'] for path in pair.projects]
    assert [row['status'] for row in rows[0]] == [row['status'] for row in rows[1]] == ['success', 'pass']
    assert rows[0][1]['failures'] == rows[1][1]['failures'] == 0
    assert rows[0][1]['compiled_code'] == rows[1][1]['compiled_code']

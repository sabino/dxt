"""Enforced schema/DDL contracts and Core artifact checksums on native adapters."""
import pytest
import json
import subprocess

from test_cli import build_dxt
from test_cli import DXT, ROOT
from test_usability_configuration import configuration_oracle, configuration_postgres
from test_usability_resource_hooks import setup_pair, rows


def patch(pair, kind='table', constraints=True):
    pair.write('models/properties.yml', """version: 2
models:
  - name: rendered
    config: {contract: {enforced: true}}
    columns:
      - {name: label, data_type: string}
      - name: id
        data_type: integer
""" + ("        constraints: [{type: not_null}, {type: check, expression: 'id > 0'}]\n    constraints:\n      - {type: primary_key, columns: [id]}\n      - {type: unique, columns: [label]}\n" if constraints else ''))


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('kind', ['table', 'view'])
def test_contracts_validate_schema_and_table_ddl_matches_core(tmp_path, configuration_oracle, request, adapter, kind):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    patch(pair, kind, constraints=kind == 'table')
    pair.write('models/marts/rendered.sql', "{{ config(materialized='" + kind + "') }}select 1 as id, 'one' as label")
    for _ in range(2):
        actual, expected = pair.invoke('run')
        actual_node = actual['nodes']['model.configuration_fixture.rendered']
        expected_node = expected['nodes']['model.configuration_fixture.rendered']
        assert actual_node['contract'] == expected_node['contract']
        assert actual_node['constraints'] == expected_node['constraints']
        assert actual_node['columns'] == expected_node['columns']
        assert rows(pair, request, adapter, 'select id, label from {schema}.rendered') == [[(1, 'one')], [(1, 'one')]]
        if kind == 'table':
            assert rows(pair, request, adapter, "select column_name from information_schema.columns where table_schema='{schema}' and table_name='rendered' order by ordinal_position") == [[('label',), ('id',)], [('label',), ('id',)]]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('query', ["select 1 as changed_name, 'one' as label", "select 'wrong-type' as id, 'one' as label", "select 1 as id"])
def test_contract_schema_failure_preserves_existing_table(tmp_path, configuration_oracle, request, adapter, query):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    patch(pair)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table') }}select 1 as id, 'one' as label")
    pair.invoke('run')
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table') }}" + query)
    pair.invoke('run', success=False)
    for project in pair.projects:
        assert [row['status'] for row in json.loads((project / 'target/run_results.json').read_text())['results']] == ['error']
    assert rows(pair, request, adapter, 'select id, label from {schema}.rendered') == [[(1, 'one')], [(1, 'one')]]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('query', ["select cast(null as integer) as id, 'two' as label", "select -1 as id, 'two' as label", "select 2 as id, 'two' as label union all select 2, 'three'"])
def test_constraint_data_failure_is_atomic(tmp_path, configuration_oracle, request, adapter, query):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    patch(pair)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table') }}select 1 as id, 'one' as label")
    pair.invoke('run')
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table') }}" + query)
    pair.invoke('run', success=False)
    assert rows(pair, request, adapter, 'select id, label from {schema}.rendered') == [[(1, 'one')], [(1, 'one')]]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_incremental_contracts_enforce_first_repeated_and_full_refresh(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    patch(pair)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='incremental', unique_key='id', on_schema_change='fail') }}select {% if is_incremental() %}2{% else %}1{% endif %} as id, '{% if is_incremental() %}two{% else %}one{% endif %}' as label")
    pair.invoke('run')
    pair.invoke('run')
    assert rows(pair, request, adapter, 'select id, label from {schema}.rendered order by id') == [[(1, 'one'), (2, 'two')]] * 2
    pair.invoke('run', ['--full-refresh'])
    assert rows(pair, request, adapter, 'select id, label from {schema}.rendered order by id') == [[(1, 'one')]] * 2


@pytest.mark.parametrize('policy', ['ignore', 'sync_all_columns'])
def test_incremental_contract_rejects_incompatible_schema_policies(tmp_path, configuration_oracle, policy):
    from test_usability_configuration import ConfigurationPair
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    patch(pair)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='incremental', on_schema_change='" + policy + "') }}select 1 as id, 'one' as label")
    pair.invoke('run', success=False)


def test_postgres_foreign_key_constraints_create_dependency_and_enforce_rows(tmp_path, configuration_oracle, request):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'postgres')
    pair.write('models/marts/parent.sql', "{{ config(materialized='table', contract={'enforced': True}) }}select 1 as id")
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table', contract={'enforced': True}) }}select 1 as id")
    pair.write('models/properties.yml', """version: 2
models:
  - name: parent
    columns:
      - {name: id, data_type: integer, constraints: [{type: primary_key}]}
  - name: rendered
    columns:
      - name: id
        data_type: integer
        constraints: [{type: foreign_key, to: "ref('parent')", to_columns: [id]}]
""")
    actual, expected = pair.invoke('run')
    actual_node = actual['nodes']['model.configuration_fixture.rendered']
    expected_node = expected['nodes']['model.configuration_fixture.rendered']
    assert actual_node['depends_on']['nodes'] == expected_node['depends_on']['nodes'] == ['model.configuration_fixture.parent']
    assert actual_node['contract'] == expected_node['contract']
    actual_constraints = actual_node['columns']['id']['constraints']
    expected_constraints = expected_node['columns']['id']['constraints']
    assert actual_constraints[0]['to'] == actual['nodes']['model.configuration_fixture.parent']['relation_name']
    assert expected_constraints[0]['to'] == expected['nodes']['model.configuration_fixture.parent']['relation_name']
    actual_constraints[0]['to'] = expected_constraints[0]['to']
    assert actual_node['columns'] == expected_node['columns']
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table', contract={'enforced': True}) }}select 2 as id")
    pair.invoke('run', ['--select', 'rendered'], success=False)
    assert rows(pair, request, 'postgres', 'select id from {schema}.rendered') == [[(1,)], [(1,)]]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_quoted_columns_alias_types_and_custom_constraints(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table') }}select cast('one' as varchar) as \"DisplayName\", 1 as id")
    pair.write('models/properties.yml', """version: 2
models:
  - name: rendered
    config: {contract: {enforced: true, alias_types: false}}
    columns:
      - {name: id, data_type: integer, constraints: [{type: custom, expression: 'check (id < 10)'}]}
      - {name: DisplayName, data_type: varchar, quote: true}
""")
    actual, expected = pair.invoke('run')
    for field in ['contract', 'columns', 'constraints']:
        assert actual['nodes']['model.configuration_fixture.rendered'][field] == expected['nodes']['model.configuration_fixture.rendered'][field]
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table') }}select cast('two' as varchar) as \"DisplayName\", 11 as id")
    pair.invoke('run', success=False)
    assert rows(pair, request, adapter, 'select id, "DisplayName" from {schema}.rendered') == [[(1, 'one')]] * 2


@pytest.mark.parametrize('properties', [
    'config: {contract: {enforced: true}}\n    columns: []',
    'config: {contract: {enforced: true}}\n    columns: [{name: id, data_type: integer, constraints: [{type: invented}]}]',
    'config: {contract: {enforced: true}}\n    columns: [{name: id, data_type: integer, constraints: [{type: primary_key}]}, {name: label, data_type: string, constraints: [{type: primary_key}]}]',
    'config: {contract: {enforced: true}}\n    columns: [{name: id, data_type: integer, constraints: [{type: primary_key}]}]\n    constraints: [{type: primary_key, columns: [id]}]',
    'config: {contract: {enforced: true}}\n    columns: [{name: id, data_type: integer, constraints: [{type: foreign_key, to: not_a_ref, to_columns: [id]}]}]',
])
def test_contract_parse_prerequisites_match_core(tmp_path, configuration_oracle, properties):
    from test_usability_configuration import ConfigurationPair
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table') }}select 1 as id, 'one' as label")
    pair.write('models/properties.yml', 'version: 2\nmodels:\n  - name: rendered\n    ' + properties + '\n')
    pair.invoke('parse', success=False)


@pytest.mark.parametrize('silenced', [False, True])
def test_view_constraint_warning_respects_warn_error_and_authored_suppression(tmp_path, configuration_oracle, silenced):
    from test_usability_configuration import ConfigurationPair
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='view') }}select 1 as id")
    pair.write('models/properties.yml', "version: 2\nmodels:\n  - name: rendered\n    config: {contract: {enforced: true}}\n    columns:\n      - name: id\n        data_type: integer\n        constraints: [{type: not_null, warn_unsupported: " + ('false' if silenced else 'true') + "}]\n")
    pair.invoke('run', ['--warn-error'], success=silenced)


def test_postgres_named_unique_constraint_repeat_failure_is_atomic(tmp_path, configuration_oracle, request):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'postgres')
    patch(pair)
    for project in pair.projects:
        path = project / 'models/properties.yml'
        path.write_text(path.read_text().replace('columns: [label]}', 'columns: [label], name: unique_label}'))
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table') }}select 1 as id, 'one' as label")
    pair.invoke('run')
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table') }}select 2 as id, 'two' as label")
    pair.invoke('run', success=False)
    assert rows(pair, request, 'postgres', 'select id, label from {schema}.rendered') == [[(1, 'one')]] * 2


def test_duckdb_quoted_insert_projection_corrects_pinned_adapter_bug(tmp_path, configuration_oracle):
    """Core1.10.5/DuckDB1.9.6 omit authored quoting in their INSERT projection.

    This is an intentional native correctness extension, with the upstream
    failure independently checked instead of treating it as positive parity.
    """
    from test_usability_configuration import ConfigurationPair
    import duckdb
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table') }}select 1 as \"Display Name\"")
    pair.write('models/properties.yml', "version: 2\nmodels:\n  - name: rendered\n    config: {contract: {enforced: true}}\n    columns: [{name: Display Name, data_type: integer, quote: true}]\n")
    actual, expected = pair.projects
    reference = pair.oracle.invoke(['run', '--project-dir', str(expected), '--profiles-dir', str(expected), '--no-partial-parse', '--quiet'])
    assert reference.success is False
    assert 'syntax error' in reference.result.results[0].message.lower()
    from dbt.adapters.factory import reset_adapters
    from dbt.adapters.duckdb.connections import DuckDBConnectionManager
    reset_adapters()
    if DuckDBConnectionManager._ENV is not None:
        DuckDBConnectionManager._ENV.close()
        DuckDBConnectionManager._ENV = None
    for _ in range(2):
        result = subprocess.run([DXT, 'run', '--project-dir', str(actual), '--profiles-dir', str(actual)], text=True, capture_output=True, cwd=ROOT)
        assert result.returncode == 0, result.stdout + result.stderr
        with duckdb.connect(str(actual / 'warehouse.duckdb')) as connection:
            assert connection.execute('select "Display Name" from main.rendered').fetchall() == [(1,)]


def test_unpatched_inline_contract_parses_then_fails_materialization(tmp_path, configuration_oracle):
    from test_usability_configuration import ConfigurationPair
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table', contract={'enforced': True}) }}select 1 as id")
    actual, expected = pair.invoke('parse')
    assert actual['nodes']['model.configuration_fixture.rendered']['contract'] == expected['nodes']['model.configuration_fixture.rendered']['contract'] == {'enforced': True, 'alias_types': True, 'checksum': None}
    pair.invoke('run', success=False)
    for project in pair.projects:
        assert [row['status'] for row in json.loads((project / 'target/run_results.json').read_text())['results']] == ['error']

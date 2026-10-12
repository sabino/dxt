"""Authored incremental strategies against pinned Core on both native adapters."""
import json
import re

import pytest

from test_cli import build_dxt
from test_usability_configuration import configuration_oracle, configuration_postgres
from test_usability_resource_hooks import setup_pair, rows
from validate_dbt_artifacts import assert_artifact


CUSTOM_MACRO = """{% macro get_incremental_custom_append_sql(arg_dict) %}
  {% if arg_dict.keys() | sort != ['dest_columns', 'incremental_predicates', 'target_relation', 'temp_relation', 'unique_key'] %}
    {{ exceptions.raise_compiler_error('unexpected strategy argument keys') }}
  {% endif %}
  {% if arg_dict['unique_key'] != ['id', 'label'] or arg_dict['incremental_predicates'] != ['DBT_INTERNAL_DEST.id > 0'] %}
    {{ exceptions.raise_compiler_error('strategy lost typed configuration') }}
  {% endif %}
  {% if arg_dict['target_relation'].identifier != 'rendered' or not arg_dict['temp_relation'].identifier.startswith('rendered__dbt_tmp') %}
    {{ exceptions.raise_compiler_error('strategy lost typed Relation arguments') }}
  {% endif %}
  {% if arg_dict['dest_columns'] | map(attribute='name') | list != ['id', 'label'] %}
    {{ exceptions.raise_compiler_error('strategy lost typed Column arguments') }}
  {% endif %}
  {{ return(get_incremental_append_sql(arg_dict)) }}
{% endmacro %}
"""


def model(pair, strategy, value):
    pair.write('models/marts/rendered.sql', "{{ config(materialized='incremental', incremental_strategy='" + strategy + "', unique_key=['id', 'label'], incremental_predicates=['DBT_INTERNAL_DEST.id > 0']) }}select cast(" + str(value) + " as integer) as id, cast('row' as varchar) as label")


def assert_results(pair, status):
    for project in pair.projects:
        assert_artifact(project / 'target/manifest.json')
        assert_artifact(project / 'target/run_results.json')
        results = json.loads((project / 'target/run_results.json').read_text())['results']
        assert [(row['unique_id'], row['status']) for row in results] == [('model.configuration_fixture.rendered', status)]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('strategy', ['custom_append', 'custom+append'])
def test_authored_incremental_strategy_first_repeated_and_full_refresh(tmp_path, configuration_oracle, request, adapter, strategy):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('macros/custom_strategy.sql', CUSTOM_MACRO)
    for value, flags, expected in [(1, (), [(1, 'row')]), (2, (), [(1, 'row'), (2, 'row')]), (3, ('--full-refresh',), [(3, 'row')])]:
        model(pair, strategy, value)
        manifests = pair.invoke('run', flags=flags)
        assert_results(pair, 'success')
        assert rows(pair, request, adapter, 'select * from {schema}.rendered order by id') == [expected, expected]
        nodes = [manifest['nodes']['model.configuration_fixture.rendered'] for manifest in manifests]
        for field in ['compiled_code', 'depends_on']:
            assert nodes[0][field] == nodes[1][field]
        assert nodes[0]['config']['incremental_strategy'] == nodes[1]['config']['incremental_strategy'] == strategy
        run_files = [project / 'target/run/configuration_fixture/models/marts/rendered.sql' for project in pair.projects]
        # Compare statement bodies; Core's call block adds outer blank lines.
        # PostgreSQL's stock make_temp_relation suffix contains its invocation clock.
        payloads = [re.sub(r'rendered__dbt_tmp[0-9]+', 'rendered__dbt_tmp<TIMESTAMP>', path.read_text().strip().replace(node['schema'], '<schema>')) for path, node in zip(run_files, nodes)]
        assert payloads[0] == payloads[1]


@pytest.mark.parametrize('adapter,strategy', [('duckdb', 'merge'), ('duckdb', 'insert_overwrite'), ('duckdb', 'missing_strategy')])
def test_unsupported_builtin_or_missing_custom_strategy_fails_only_when_needed(tmp_path, configuration_oracle, request, adapter, strategy):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    # Core creates/replaces a table without consulting a strategy macro.
    model(pair, strategy, 1)
    pair.invoke('compile')
    pair.invoke('run')
    model(pair, strategy, 2)
    pair.invoke('compile')
    pair.invoke('run', success=False)
    assert_results(pair, 'error')
    assert rows(pair, request, adapter, 'select * from {schema}.rendered') == [[(1, 'row')]] * 2
    pair.invoke('run', flags=('--full-refresh',))
    assert_results(pair, 'success')
    assert rows(pair, request, adapter, 'select * from {schema}.rendered') == [[(2, 'row')]] * 2


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_authored_incremental_strategy_sql_failure_rolls_back(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('macros/custom_strategy.sql', "{% macro get_incremental_custom_append_sql(arg_dict) %}{{ return('insert into ' ~ arg_dict.target_relation ~ ' select missing_strategy_function()') }}{% endmacro %}")
    model(pair, 'custom_append', 1)
    pair.invoke('run')
    model(pair, 'custom_append', 2)
    pair.invoke('run', success=False)
    assert_results(pair, 'error')
    assert rows(pair, request, adapter, 'select * from {schema}.rendered') == [[(1, 'row')]] * 2


@pytest.mark.parametrize('strategy', ['insert_overwrite', 'missing_strategy'])
def test_postgres_invalid_strategy_rejects_creation_and_full_refresh(tmp_path, configuration_oracle, request, strategy):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'postgres')
    model(pair, strategy, 1)
    pair.invoke('compile')
    pair.invoke('run', success=False)
    assert_results(pair, 'error')
    assert rows(pair, request, 'postgres', "select count(*) from information_schema.tables where table_schema='{schema}' and table_name='rendered'") == [[(0,)]] * 2
    model(pair, 'default', 1)
    pair.invoke('run')
    model(pair, strategy, 2)
    pair.invoke('run', success=False)
    assert_results(pair, 'error')
    assert rows(pair, request, 'postgres', 'select * from {schema}.rendered') == [[(1, 'row')]] * 2
    pair.invoke('run', flags=('--full-refresh',), success=False)
    assert_results(pair, 'error')
    assert rows(pair, request, 'postgres', 'select * from {schema}.rendered') == [[(1, 'row')]] * 2


@pytest.mark.parametrize('adapter,strategy', [('duckdb', 'merge'), ('postgres', 'insert_overwrite')])
def test_authored_macro_cannot_enable_unsupported_builtin_strategy(tmp_path, configuration_oracle, request, adapter, strategy):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('macros/shadow_builtin.sql', "{% macro get_incremental_" + strategy + "_sql(arg_dict) %}{{ return(get_incremental_append_sql(arg_dict)) }}{% endmacro %}")
    model(pair, 'default', 1)
    pair.invoke('run')
    model(pair, strategy, 2)
    pair.invoke('run', success=False)
    assert_results(pair, 'error')
    assert rows(pair, request, adapter, 'select * from {schema}.rendered') == [[(1, 'row')]] * 2

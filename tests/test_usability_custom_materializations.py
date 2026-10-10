"""Authored materializations execute native SQL and preserve Core main results."""
import json

import pytest

from test_cli import build_dxt
from test_usability_configuration import configuration_oracle, configuration_postgres
from test_usability_resource_hooks import setup_pair, rows


def materialization(name='native_custom', adapter='default', value=1, finish=None, extra='', languages="['sql']"):
    finish = finish if finish is not None else "{{ return({'relations': [target]}) }}"
    adapter_clause = 'default' if adapter == 'default' else "adapter='" + adapter + "'"
    return "{% materialization " + name + ", " + adapter_clause + ", supported_languages=" + languages + " %}\n" + """
{% set target = this.incorporate(type='table') %}
{% set old = adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
{% if old is not none %}{% do adapter.drop_relation(old) %}{% endif %}
{{ run_hooks(pre_hooks, inside_transaction=False) }}
{{ run_hooks(pre_hooks, inside_transaction=True) }}
{% call statement('main') %}create table {{ target }} as select """ + str(value) + """ as id{% endcall %}
{{ run_hooks(post_hooks, inside_transaction=True) }}
""" + extra + "\n{% do adapter.commit() %}\n{{ run_hooks(post_hooks, inside_transaction=False) }}\n" + finish + "\n{% endmaterialization %}"


def response_rows(pair):
    return [[{key: row[key] for key in ('status', 'message', 'adapter_response')} for row in json.loads((project / 'target/run_results.json').read_text())['results']] for project in pair.projects]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_custom_materialization_executes_first_repeated_and_full_refresh_with_main_response(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='native_custom') }}select 900 as ignored_model_sql")
    pair.write('macros/materialization.sql', materialization())
    for flags in [[], [], ['--full-refresh']]:
        pair.invoke('run', flags)
        actual, expected = response_rows(pair)
        assert actual == expected
        assert actual[0]['message'] == ('OK' if adapter == 'duckdb' else 'SELECT 1')
        assert rows(pair, request, adapter, 'select id from {schema}.rendered') == [[(1,)], [(1,)]]
        actual_sql, expected_sql = [(project / 'target/run/configuration_fixture/models/marts/rendered.sql').read_text() for project in pair.projects]
        if adapter == 'postgres':
            import yaml
            schemas = [yaml.safe_load((project / 'profiles.yml').read_text())['configuration_fixture']['outputs']['dev']['schema'] for project in pair.projects]
            actual_sql = actual_sql.replace(schemas[0], schemas[1])
        assert actual_sql == expected_sql


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_custom_materialization_calls_its_authored_hooks_once_and_keeps_main_response(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('macros/materialization.sql', materialization())
    pair.write('models/marts/rendered.sql', """{{ config(materialized='native_custom',
        pre_hook="create table if not exists {{ target.schema }}.events (label varchar)",
        post_hook=["insert into {{ target.schema }}.events values ('post')", "select 77"]
    ) }}select 900 as ignored_model_sql""")
    pair.invoke('run')
    assert rows(pair, request, adapter, 'select label from {schema}.events') == [[('post',)], [('post',)]]
    actual, expected = response_rows(pair)
    assert actual == expected
    assert actual[0]['message'] == ('OK' if adapter == 'duckdb' else 'SELECT 1')


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_adapter_specific_materialization_wins_over_root_default(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='native_custom') }}select 900")
    pair.write('macros/default.sql', materialization(value=1))
    pair.write('macros/specific.sql', materialization(adapter=adapter, value=2))
    pair.invoke('run')
    assert rows(pair, request, adapter, 'select id from {schema}.rendered') == [[(2,)], [(2,)]]
    assert response_rows(pair)[0] == response_rows(pair)[1]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_project_override_of_builtin_materialization_is_executed(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table') }}select 900")
    pair.write('macros/custom_table.sql', materialization(name='table', adapter=adapter, value=8))
    pair.invoke('run')
    assert rows(pair, request, adapter, 'select id from {schema}.rendered') == [[(8,)], [(8,)]]
    assert response_rows(pair)[0] == response_rows(pair)[1]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('finish', ["{{ return('wrong') }}", "{{ return({}) }}", "{{ return({'relations': this}) }}", "{{ return({'relations': ['not a Relation']}) }}"])
def test_invalid_return_values_fail_with_durable_error_rows(tmp_path, configuration_oracle, request, adapter, finish):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='native_custom') }}select 900")
    pair.write('macros/materialization.sql', materialization(finish=finish))
    pair.invoke('run', success=False)
    actual, expected = response_rows(pair)
    assert actual[0]['status'] == expected[0]['status'] == 'error'
    assert actual[0]['adapter_response'] == expected[0]['adapter_response'] == {}
    # The macro explicitly committed before returning: return validation must
    # not silently undo its committed SQL, matching Core's lifecycle.
    assert rows(pair, request, adapter, 'select id from {schema}.rendered') == [[(1,)], [(1,)]]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_noop_main_preserves_authored_response_metadata(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='native_custom') }}select 900")
    pair.write('macros/materialization.sql', materialization(extra="{% call noop_statement('main', message='AUTHORED 7', code='AUTHORED', rows_affected=7) %}select 'metadata only'{% endcall %}"))
    pair.invoke('run')
    actual, expected = response_rows(pair)
    assert actual == expected
    assert actual[0]['message'] == 'AUTHORED 7'
    assert actual[0]['adapter_response'] == {'_message': 'AUTHORED 7', 'code': 'AUTHORED', 'rows_affected': 7}


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_materialization_must_call_main(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='native_custom') }}select 900")
    pair.write('macros/materialization.sql', "{% materialization native_custom, default %}{{ return({'relations': []}) }}{% endmaterialization %}")
    pair.invoke('run', success=False)
    actual, expected = response_rows(pair)
    assert actual[0]['status'] == expected[0]['status'] == 'error'
    assert 'main is not being called' in actual[0]['message']
    assert 'main is not being called' in expected[0]['message']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('flag', [None, True, False])
def test_imported_builtin_override_obeys_core_behavior_flag(tmp_path, configuration_oracle, request, adapter, flag):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    if flag is not None:
        pair.append_project('flags: {require_explicit_package_overrides_for_builtin_materializations: ' + str(flag).lower() + '}\n')
    pair.write('dbt_packages/dependency/dbt_project.yml', "name: dependency\nversion: '1.0'\n")
    pair.write('dbt_packages/dependency/macros/materialization.sql', materialization(name='table', adapter=adapter, value=8))
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table') }}select 900 as id")
    pair.invoke('run')
    expected = 8 if flag is False else 900
    assert rows(pair, request, adapter, 'select id from {schema}.rendered') == [[(expected,)], [(expected,)]]
    if flag is False:
        assert response_rows(pair)[0] == response_rows(pair)[1]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_language_mismatch_is_durable_and_independent_models_continue(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='native_custom') }}select 900")
    pair.write('models/marts/independent.sql', "{{ config(materialized='table') }}select 6 as id")
    pair.write('macros/materialization.sql', materialization(languages="['python']"))
    pair.invoke('run', success=False)
    for project in pair.projects:
        result = {row['unique_id']: row for row in json.loads((project / 'target/run_results.json').read_text())['results']}
        assert result['model.configuration_fixture.rendered']['status'] == 'error'
        assert result['model.configuration_fixture.independent']['status'] == 'success'
        assert 'language' in result['model.configuration_fixture.rendered']['message']
    assert rows(pair, request, adapter, 'select id from {schema}.independent') == [[(6,)], [(6,)]]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_uncommitted_custom_sql_rolls_back_when_materialization_finishes(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='native_custom') }}select 900")
    pair.write('macros/materialization.sql', materialization().replace('{% do adapter.commit() %}', ''))
    pair.invoke('run')
    assert response_rows(pair)[0] == response_rows(pair)[1]
    assert rows(pair, request, adapter, "select count(*) from information_schema.tables where table_schema='{schema}' and table_name='rendered'") == [[(0,)], [(0,)]]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_custom_sql_failure_preserves_server_error_and_rolls_back_body(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='native_custom') }}select 900")
    pair.write('macros/materialization.sql', materialization(extra="{% do run_query('select * from missing_custom_relation') %}"))
    pair.invoke('run', success=False)
    actual, expected = response_rows(pair)
    assert actual[0]['status'] == expected[0]['status'] == 'error'
    assert 'missing_custom_relation' in actual[0]['message']
    assert 'missing_custom_relation' in expected[0]['message']
    assert rows(pair, request, adapter, "select count(*) from information_schema.tables where table_schema='{schema}' and table_name='rendered'") == [[(0,)], [(0,)]]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_plain_stored_main_response_has_message_without_adapter_dataclass_fields(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='native_custom') }}select 900")
    pair.write('macros/materialization.sql', materialization(extra="{% do store_result('main', response='authored plain response') %}"))
    pair.invoke('run')
    actual, expected = response_rows(pair)
    assert actual == expected == [{'status': 'success', 'message': 'authored plain response', 'adapter_response': {}}]

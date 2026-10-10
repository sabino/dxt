"""Main statement metadata is durable across hooks and native cleanup."""
import json

import pytest

from test_cli import build_dxt
from test_usability_configuration import configuration_oracle, configuration_postgres
from test_usability_resource_hooks import setup_pair, rows


def results(pair):
    return [[{key: row[key] for key in ('status', 'message', 'adapter_response')} for row in json.loads((project / 'target/run_results.json').read_text())['results']] for project in pair.projects]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('kind', ['table', 'view', 'incremental', 'delete_insert'])
def test_stock_model_main_response_survives_hooks_first_repeat_and_full_refresh(tmp_path, configuration_oracle, request, adapter, kind):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    config = "materialized='incremental', incremental_strategy='delete+insert', unique_key='id'" if kind == 'delete_insert' else "materialized='" + kind + "'"
    pair.write('models/marts/rendered.sql', '{{ config(' + config + ", post_hook='select 999') }}select 1 as id, 2 as value union all select 2, 4")
    for flags in [[], [], ['--full-refresh']]:
        pair.invoke('run', flags)
        assert results(pair)[0] == results(pair)[1]
        actual, expected = rows(pair, request, adapter, 'select id,value from {schema}.rendered order by id,value')
        assert actual == expected


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_seed_response_counts_all_rows_and_preserves_full_refresh_code(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.append_project("seeds:\n  configuration_fixture:\n    +post-hook: select 999\n")
    pair.write('seeds/loaded.csv', 'id,label\n1,first\n2,second\n')
    for flags in [[], [], ['--full-refresh']]:
        pair.invoke('seed', flags)
        actual, expected = results(pair)
        assert actual == expected
        assert actual[0]['adapter_response']['rows_affected'] == 2
        assert actual[0]['message'] == ('CREATE 2' if flags else 'INSERT 2')


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_snapshot_main_response_first_unchanged_and_updated(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    for stamp in ['2024-01-01', '2024-01-01', '2024-01-02']:
        pair.write('snapshots/history.sql', "{% snapshot history %}{{ config(target_schema=target.schema, unique_key='id', strategy='timestamp', updated_at='updated_at', post_hook='select 999') }}select 1 as id, timestamp '" + stamp + " 00:00:00' as updated_at{% endsnapshot %}")
        pair.invoke('snapshot')
        assert results(pair)[0] == results(pair)[1]
        assert rows(pair, request, adapter, 'select count(*) from {schema}.history')[0] == rows(pair, request, adapter, 'select count(*) from {schema}.history')[1]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('strategy', ['timestamp', 'check'])
def test_snapshot_new_record_main_response_counts_tombstones_and_changes(tmp_path, configuration_oracle, request, adapter, strategy):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    settings = "check_cols=['label']," if strategy == 'check' else ''
    initial = "select 1 as id, 'first' as label, timestamp '2024-01-01' as updated_at union all select 2, 'second', timestamp '2024-01-01'"
    deleted = "select 1 as id, 'first' as label, timestamp '2024-01-01' as updated_at"
    returned = "select 1 as id, 'changed' as label, timestamp '2024-01-02' as updated_at union all select 2, 'returned', timestamp '2024-01-02'"
    for query in [initial, deleted, deleted, returned, returned]:
        pair.write('snapshots/history.sql', "{% snapshot history %}{{ config(target_schema=target.schema, unique_key='id', strategy='" + strategy + "', " + settings + "updated_at='updated_at', hard_deletes='new_record', post_hook='select 999') }}" + query + "{% endsnapshot %}")
        pair.invoke('snapshot')
        assert results(pair)[0] == results(pair)[1]
        actual, expected = rows(pair, request, adapter, "select id,label,dbt_is_deleted,dbt_valid_to is null from {schema}.history order by id,label,dbt_is_deleted,dbt_valid_to is null")
        assert actual == expected


def test_postgres_materialized_view_main_command_first_refresh_and_full_refresh(tmp_path, configuration_oracle, request):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'postgres')
    pair.write('models/marts/rendered.sql', "{{ config(materialized='materialized_view', post_hook='select 999') }}select 1 as id")
    for flags in [[], [], ['--full-refresh']]:
        pair.invoke('run', flags)
        assert results(pair)[0] == results(pair)[1]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_stock_failure_preserves_actual_server_diagnostic_and_prior_data(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table') }}select 1 as id")
    pair.invoke('run')
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table', post_hook='select * from missing_metadata_relation') }}select 2 as id")
    pair.invoke('run', success=False)
    for output in results(pair):
        assert output[0]['status'] == 'error'
        assert 'missing_metadata_relation' in output[0]['message']
        assert output[0]['adapter_response'] == {}
    assert rows(pair, request, adapter, 'select id from {schema}.rendered') == [[(1,)], [(1,)]]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_contract_main_response_keeps_insert_or_adapter_tag(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/properties.yml', "version: 2\nmodels:\n  - name: rendered\n    config: {contract: {enforced: true}}\n    columns:\n      - {name: id, data_type: integer, constraints: [{type: not_null}]}\n")
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table', post_hook='select 999') }}select 1::integer as id union all select 2")
    pair.invoke('run')
    assert results(pair)[0] == results(pair)[1]


def test_postgres_materialized_view_index_commands_are_main_metadata(tmp_path, configuration_oracle, request):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'postgres')
    for indexes in ["[{ 'columns': ['id'] }]", "[{ 'columns': ['value'] }]", "[]"]:
        pair.write('models/marts/rendered.sql', "{{ config(materialized='materialized_view', indexes=" + indexes + ", post_hook='select 999') }}select 1 as id, 2 as value")
        pair.invoke('run')
        assert results(pair)[0] == results(pair)[1]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('count,expected', [("'-1'", '-1'), ('2.5', 2.5), ('true', True), ('123456789012345678901234567890', 123456789012345678901234567890)])
def test_authored_response_retains_core_row_count_value_types(tmp_path, configuration_oracle, request, adapter, count, expected):
    from test_usability_custom_materializations import materialization
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='native_custom') }}select 900")
    pair.write('macros/materialization.sql', materialization(extra="{% call noop_statement('main', message='typed response', code='AUTHORED', rows_affected=" + count + ") %}select 'metadata only'{% endcall %}"))
    pair.invoke('run')
    actual, reference = results(pair)
    assert actual == reference
    assert actual[0]['adapter_response']['rows_affected'] == expected
    assert type(actual[0]['adapter_response']['rows_affected']) is type(expected)


def test_postgres_materialized_view_continue_retains_skip_response_and_data(tmp_path, configuration_oracle, request):
    import yaml
    pair = setup_pair(tmp_path, configuration_oracle, request, 'postgres')
    pair.write('models/marts/rendered.sql', "{{ config(materialized='materialized_view', indexes=[{'columns':['id']}]) }}select 1 as id, 2 as value")
    pair.invoke('run')
    pair.write('models/marts/rendered.sql', "{{ config(materialized='materialized_view', indexes=[{'columns':['value']}], on_configuration_change='continue', post_hook='select 999') }}select 3 as id, 4 as value")
    pair.invoke('run')
    actual, reference = results(pair)
    schemas = [yaml.safe_load((project / 'profiles.yml').read_text())['configuration_fixture']['outputs']['dev']['schema'] for project in pair.projects]
    assert json.dumps(actual).replace(schemas[0], schemas[1]) == json.dumps(reference)
    assert actual[0]['adapter_response']['rows_affected'] == '-1'
    assert actual[0]['adapter_response']['code'] == 'skip'
    assert rows(pair, request, 'postgres', 'select id,value from {schema}.rendered') == [[(1,2)], [(1,2)]]
    pair.invoke('run', ['--warn-error'], success=False)
    assert [row[0]['status'] for row in results(pair)] == ['error', 'error']
    assert rows(pair, request, 'postgres', 'select id,value from {schema}.rendered') == [[(1,2)], [(1,2)]]


def test_postgres_materialized_view_continue_skips_inner_hooks_and_retains_outer_hooks(tmp_path, configuration_oracle, request):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'postgres')
    pair.write('models/marts/rendered.sql', "{{ config(materialized='materialized_view', indexes=[{'columns':['id']}], pre_hook={'sql':'create table {{ target.schema }}.events (label varchar)', 'transaction':false}) }}select 1 as id, 2 as value")
    pair.invoke('run')
    pair.write('models/marts/rendered.sql', "{{ config(materialized='materialized_view', indexes=[{'columns':['value']}], on_configuration_change='continue', pre_hook=\"insert into {{ target.schema }}.events values ('inner-pre')\", post_hook=[\"insert into {{ target.schema }}.events values ('inner-post')\", {'sql':\"insert into {{ target.schema }}.events values ('outer-post')\", 'transaction':false}]) }}select 3 as id, 4 as value")
    pair.invoke('run')
    assert rows(pair, request, 'postgres', 'select label from {schema}.events') == [[('outer-post',)], [('outer-post',)]]
    assert rows(pair, request, 'postgres', 'select id,value from {schema}.rendered') == [[(1,2)], [(1,2)]]

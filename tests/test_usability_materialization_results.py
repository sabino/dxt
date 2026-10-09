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

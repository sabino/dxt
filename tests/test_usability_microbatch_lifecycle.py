"""Microbatch materialization hooks and custom bodies match actual Core effects."""
import json

import pytest

from test_cli import build_dxt
from test_usability_configuration import configuration_oracle, configuration_postgres
from test_usability_resource_hooks import setup_pair, rows
from test_usability_microbatch import DUCKDB_STRATEGY


WINDOW = ['--select', 'events', '--event-time-start', '2024-01-01', '--event-time-end', '2024-01-04']
INPUT = "{{ config(event_time='occurred_at') }}select * from (values (1,10,timestamp '2024-01-01 12:00:00'),(2,20,timestamp '2024-01-02 12:00:00'),(3,30,timestamp '2024-01-03 12:00:00')) t(id,amount,occurred_at)"
EVENTS = "{{ config(materialized='incremental', incremental_strategy='microbatch',unique_key='id',event_time='occurred_at',begin='2024-01-01',batch_size='day') }}select * from {{ ref('input') }}"


def setup(tmp_path, oracle, request, adapter, *, failing=False, custom=False):
    pair = setup_pair(tmp_path, oracle, request, adapter)
    pair.write('models/input.sql', INPUT)
    pair.write('models/events.sql', EVENTS)
    pair.append_project("flags:\n  require_batched_execution_for_custom_microbatch_strategy: true\nmodels:\n  configuration_fixture:\n    events:\n      +pre-hook:\n        - {sql: 'create table if not exists {{ target.schema }}.batch_audit (phase varchar, batch_id varchar)', transaction: false}\n        - \"insert into {{ target.schema }}.batch_audit values ('pre', '{{ model.batch.id }}')\"\n      +post-hook:\n        - \"insert into {{ target.schema }}.batch_audit values ('post', '{{ model.batch.id }}')\"\n")
    if failing:
        pair.write('models/events.sql', EVENTS.replace("batch_size='day'", "batch_size='day',post_hook=\"{% if model.batch.id == '20240103' %}select * from missing_batch_hook{% endif %}\""))
    if adapter == 'duckdb':
        pair.write('macros/microbatch.sql', DUCKDB_STRATEGY)
    if custom:
        pair.write('macros/custom.sql', "{% materialization incremental, adapter='" + adapter + "' %}{{ run_hooks(pre_hooks, inside_transaction=False) }}{{ run_hooks(pre_hooks, inside_transaction=True) }}{% call statement('main') %}{% if is_incremental() %}insert into {{ this }}{% else %}create table {{ this }} as{% endif %} {{ sql }}{% endcall %}{{ run_hooks(post_hooks, inside_transaction=True) }}{% do adapter.commit() %}{{ run_hooks(post_hooks, inside_transaction=False) }}{{ return({'relations':[this]}) }}{% endmaterialization %}")
    pair.invoke('run', ['--select', 'input'])
    return pair


def result_pair(pair):
    keys = ('status', 'message', 'adapter_response', 'failures', 'batch_results')
    return [{key: row[key] for key in keys} for root in pair.projects for row in json.loads((root / 'target/run_results.json').read_text())['results']]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_microbatch_hooks_execute_only_for_first_and_last_batch_on_repeated_and_full_refresh_runs(tmp_path, configuration_oracle, request, adapter):
    pair = setup(tmp_path, configuration_oracle, request, adapter)
    for extra in [[], [], ['--full-refresh']]:
        pair.invoke('run', WINDOW + extra)
        assert result_pair(pair)[0] == result_pair(pair)[1]
        assert rows(pair, request, adapter, 'select id,amount from {schema}.events order by id')[0] == rows(pair, request, adapter, 'select id,amount from {schema}.events order by id')[1]
        assert rows(pair, request, adapter, 'select phase,batch_id from {schema}.batch_audit order by phase,batch_id')[0] == rows(pair, request, adapter, 'select phase,batch_id from {schema}.batch_audit order by phase,batch_id')[1]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_microbatch_post_hook_error_rolls_back_one_batch_and_records_partial_result(tmp_path, configuration_oracle, request, adapter):
    pair = setup(tmp_path, configuration_oracle, request, adapter, failing=True)
    pair.invoke('run', WINDOW, success=False)
    assert result_pair(pair)[0] == result_pair(pair)[1]
    assert rows(pair, request, adapter, 'select id,amount from {schema}.events order by id')[0] == rows(pair, request, adapter, 'select id,amount from {schema}.events order by id')[1]
    assert rows(pair, request, adapter, 'select phase,batch_id from {schema}.batch_audit order by phase,batch_id')[0] == rows(pair, request, adapter, 'select phase,batch_id from {schema}.batch_audit order by phase,batch_id')[1]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_microbatch_runs_authored_incremental_materialization_for_each_batch(tmp_path, configuration_oracle, request, adapter):
    pair = setup(tmp_path, configuration_oracle, request, adapter, custom=True)
    pair.invoke('run', WINDOW)
    assert result_pair(pair)[0] == result_pair(pair)[1]
    assert rows(pair, request, adapter, 'select phase,batch_id from {schema}.batch_audit order by phase,batch_id')[0] == rows(pair, request, adapter, 'select phase,batch_id from {schema}.batch_audit order by phase,batch_id')[1]

"""Actual stock statements and run-file timing against pinned Core adapters."""
import json
import re

import pytest

from test_cli import build_dxt  # noqa: F401
from test_usability_configuration import configuration_oracle, configuration_postgres  # noqa: F401
from test_usability_resource_hooks import setup_pair, rows
from test_usability_artifacts import contracts


def resource(project, name='rendered', kind='model'):
    contracts.assert_artifact(project / 'target/manifest.json')
    contracts.assert_artifact(project / 'target/run_results.json')
    return json.loads((project / 'target/manifest.json').read_text())['nodes'][f'{kind}.configuration_fixture.{name}']


def runtime_sql(project, node):
    assert node['build_path'] is not None
    return (project / node['build_path']).read_text()


def normalized(project, sql):
    import yaml
    profile = yaml.safe_load((project / 'profiles.yml').read_text())['configuration_fixture']['outputs']['dev']
    sql = sql.replace(profile['schema'], 'main')
    # Temporary names include an invocation clock. Retain microbatch IDs.
    sql = re.sub(r'(__dbt_tmp_\d{8})\d+', r'\1', sql)
    sql = re.sub(r'__dbt_tmp\d+', '__dbt_tmp', sql)
    return re.sub(r'\s+', '', sql).rstrip(';')


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('materialized', ['table', 'view'])
def test_stock_main_file_is_actual_staged_statement_and_survives_failed_replacement(tmp_path, configuration_oracle, request, adapter, materialized):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='" + materialized + "') }}select 1 as id")
    pair.invoke('compile')
    for project in pair.projects:
        node = resource(project)
        assert node['build_path'] is None
        assert not (project / 'target/run').exists()
    for code, success in [('select 1 as id', True), ('select 2 as id', True), ('select missing_column as id', False)]:
        pair.write('models/marts/rendered.sql', "{{ config(materialized='" + materialized + "') }}" + code)
        pair.invoke('run', success=success)
        nodes = [resource(project) for project in pair.projects]
        assert [node['build_path'] for node in nodes] == ['target/run/configuration_fixture/models/marts/rendered.sql'] * 2
        statements = [runtime_sql(project, node) for project, node in zip(pair.projects, nodes)]
        assert normalized(pair.projects[0], statements[0]) == normalized(pair.projects[1], statements[1])
        assert '__dbt_tmp' in statements[0] and code in statements[0]
        assert rows(pair, request, adapter, 'select id from {schema}.rendered') == [[(2 if code != 'select 1 as id' else 1,)], [(2 if code != 'select 1 as id' else 1,)]]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('strategy', ['append', 'delete+insert'])
def test_incremental_files_follow_initial_strategy_full_refresh_and_stage_error_timing(tmp_path, configuration_oracle, request, adapter, strategy):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    config = "{{ config(materialized='incremental',incremental_strategy='" + strategy + "',unique_key='id') }}"
    pair.write('models/marts/rendered.sql', config + 'select 1 as id')
    for flags in [[], [], ['--full-refresh']]:
        pair.invoke('run', flags)
        nodes = [resource(project) for project in pair.projects]
        statements = [runtime_sql(project, node) for project, node in zip(pair.projects, nodes)]
        assert normalized(pair.projects[0], statements[0]) == normalized(pair.projects[1], statements[1])
    for project in pair.projects:
        (project / resource(project)['build_path']).unlink()
    pair.write('models/marts/rendered.sql', config + 'select missing_column as id')
    pair.invoke('run', success=False)
    for project in pair.projects:
        assert resource(project)['build_path'] is None
        assert not (project / 'target/run/configuration_fixture/models/marts/rendered.sql').exists()
    assert rows(pair, request, adapter, 'select id from {schema}.rendered') == [[(1,)], [(1,)]]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_incremental_main_failure_writes_the_authored_strategy_that_is_executed(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='incremental',incremental_strategy='append') }}select 1 as id")
    pair.invoke('run')
    pair.write('macros/append.sql', "{% macro get_incremental_append_sql(arg_dict) %}insert into {{ arg_dict.target_relation }} select missing_column from {{ arg_dict.temp_relation }}{% endmacro %}")
    pair.invoke('run', success=False)
    nodes = [resource(project) for project in pair.projects]
    statements = [runtime_sql(project, node) for project, node in zip(pair.projects, nodes)]
    assert normalized(pair.projects[0], statements[0]) == normalized(pair.projects[1], statements[1])
    assert 'select missing_column' in statements[0]
    assert rows(pair, request, adapter, 'select id from {schema}.rendered') == [[(1,)], [(1,)]]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_relation_name_limit_is_the_real_postgres_protocol(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    code = "select {{ this.relation_max_name_length() }} as maximum" if adapter == 'postgres' else "select {{ 1 if this.relation_max_name_length is undefined else 0 }} as absent"
    pair.write('models/marts/rendered.sql', code)
    actual, expected = [manifest['nodes']['model.configuration_fixture.rendered'] for manifest in pair.invoke('compile')]
    assert actual['compiled_code'] == expected['compiled_code']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_seed_run_file_is_written_after_load_and_retained_after_later_hook_error(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('seeds/data.csv', 'id\n1\n2\n')
    pair.append_project("seeds:\n  configuration_fixture:\n    data:\n      +column_types: {id: integer}\n")
    for flags in [[], [], ['--full-refresh']]:
        pair.invoke('seed', flags)
        nodes = [resource(project, 'data', 'seed') for project in pair.projects]
        assert [node['build_path'] for node in nodes] == ['target/run/configuration_fixture/seeds/data.csv'] * 2
        statements = [runtime_sql(project, node) for project, node in zip(pair.projects, nodes)]
        assert 'insert into' in statements[0].lower()
        # The native statement contains the literals actually loaded. The
        # pinned DuckDB adapter uses COPY, and PostgreSQL uses bound INSERTs.
        # Keep these execution representations visible in the oracle.
        if adapter == 'duckdb':
            assert 'COPY ' in statements[1]
            assert str(pair.projects[1] / 'seeds/data.csv') in statements[1]
        else:
            assert 'insert into' in statements[1].lower()
            assert '%s' in statements[1] and '%s' not in statements[0]
        assert rows(pair, request, adapter, 'select id from {schema}.data order by id') == [[(1,), (2,)]] * 2
    pair.append_project("      +post-hook: 'select * from missing_seed_hook'\n")
    pair.write('seeds/data.csv', 'id\n3\n4\n')
    pair.invoke('seed', success=False)
    for project in pair.projects:
        assert resource(project, 'data', 'seed')['build_path'] == 'target/run/configuration_fixture/seeds/data.csv'
    assert rows(pair, request, adapter, 'select id from {schema}.data order by id') == [[(1,), (2,)]] * 2


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_seed_load_failure_does_not_publish_a_main_file_and_rolls_back_reset(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('seeds/data.csv', 'id\n1\n2\n')
    pair.append_project("seeds:\n  configuration_fixture:\n    data:\n      +column_types: {id: integer}\n")
    pair.invoke('seed')
    for project in pair.projects:
        (project / resource(project, 'data', 'seed')['build_path']).unlink()
    pair.write('seeds/data.csv', 'id\nnot_an_integer\n')
    pair.invoke('seed', success=False)
    for project in pair.projects:
        assert resource(project, 'data', 'seed')['build_path'] is None
        assert not (project / 'target/run/configuration_fixture/seeds/data.csv').exists()
    assert rows(pair, request, adapter, 'select id from {schema}.data order by id') == [[(1,), (2,)]] * 2


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_snapshot_preparation_main_and_cleanup_are_distinct_artifact_boundaries(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    snapshot = "{% snapshot history %}{{ config(target_schema=target.schema,strategy='timestamp',unique_key='id',updated_at='changed_at') }}select 1 as id, timestamp '2024-01-01' as changed_at{% endsnapshot %}"
    pair.write('snapshots/history.sql', snapshot)
    for phase in range(2):
        pair.invoke('snapshot')
        nodes = [resource(project, 'history', 'snapshot') for project in pair.projects]
        assert [node['build_path'] for node in nodes] == ['target/run/configuration_fixture/snapshots/history.sql'] * 2
        statements = [runtime_sql(project, node) for project, node in zip(pair.projects, nodes)]
        assert all('create temporary' not in text.lower() and 'drop table' not in text.lower() for text in statements)
        assert all(('create ' if phase == 0 else 'update ') in text.lower() for text in statements)
        assert rows(pair, request, adapter, 'select id from {schema}.history where dbt_valid_to is null') == [[(1,)]] * 2
    for project in pair.projects:
        (project / resource(project, 'history', 'snapshot')['build_path']).unlink()
    pair.write('snapshots/history.sql', snapshot.replace('select 1 as id', 'select missing_column as id'))
    pair.invoke('snapshot', success=False)
    for project in pair.projects:
        assert resource(project, 'history', 'snapshot')['build_path'] is None
        assert not (project / 'target/run/configuration_fixture/snapshots/history.sql').exists()


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_microbatch_run_and_compiled_files_use_calendar_labels_with_parent_path_unset(tmp_path, configuration_oracle, request, adapter):
    from test_usability_microbatch_lifecycle import setup, WINDOW
    pair = setup(tmp_path, configuration_oracle, request, adapter)
    for flags in [[], [], ['--full-refresh']]:
        pair.invoke('run', WINDOW + flags)
        for project in pair.projects:
            assert resource(project, 'events')['build_path'] is None
            for directory in ['run', 'compiled']:
                files = project / 'target' / directory / 'configuration_fixture/models/events'
                assert sorted(path.name for path in files.glob('*.sql')) == [f'events_2024-01-0{day}.sql' for day in range(1, 4)]
        for day in range(1, 4):
            relative = f'target/run/configuration_fixture/models/events/events_2024-01-0{day}.sql'
            statements = [(project / relative).read_text() for project in pair.projects]
            assert normalized(pair.projects[0], statements[0]) == normalized(pair.projects[1], statements[1])


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_microbatch_failed_stage_keeps_compiled_file_without_inventing_a_main_file(tmp_path, configuration_oracle, request, adapter):
    from test_usability_microbatch_lifecycle import setup, WINDOW, EVENTS, result_pair
    pair = setup(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/events.sql', EVENTS.replace('select * from', "select id,case when id=3 then cast(concat(id,'invalid') as integer) else amount end as amount,occurred_at from"))
    pair.invoke('run', WINDOW, success=False)
    assert result_pair(pair)[0] == result_pair(pair)[1]
    for project in pair.projects:
        assert resource(project, 'events')['build_path'] is None
        for day in range(1, 4):
            relative = f'configuration_fixture/models/events/events_2024-01-0{day}.sql'
            assert (project / 'target/compiled' / relative).is_file()
            assert (project / 'target/run' / relative).is_file() is (day != 3)
    assert rows(pair, request, adapter, 'select id,amount from {schema}.events order by id') == [[(1, 10), (2, 20)]] * 2


def test_materialized_view_main_file_contains_index_creation_refresh_and_index_changes(tmp_path, configuration_oracle, request):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'postgres')
    def assert_same_main():
        statements = [runtime_sql(project, resource(project)) for project in pair.projects]
        # Core's index name hashes include the clock of each invocation.
        canonical = [re.sub(r'"[0-9a-f]{32}"', '"index_name"', normalized(project, sql)) for project, sql in zip(pair.projects, statements)]
        assert canonical[0] == canonical[1]
    pair.write('models/marts/rendered.sql', "{{ config(materialized='materialized_view', indexes=[{'columns':['id'],'unique':true}]) }}select 1 as id")
    pair.invoke('run')
    assert_same_main()
    for project in pair.projects:
        sql = runtime_sql(project, resource(project)).lower()
        assert 'create materialized view' in sql
        assert 'create unique index' in sql
    pair.invoke('run')
    assert_same_main()
    for project in pair.projects:
        sql = runtime_sql(project, resource(project)).lower()
        assert 'refresh materialized view' in sql and 'create index' not in sql
    pair.write('models/marts/rendered.sql', "{{ config(materialized='materialized_view', indexes=[], on_configuration_change='apply') }}select 2 as id")
    pair.invoke('run')
    assert_same_main()
    for project in pair.projects:
        sql = runtime_sql(project, resource(project)).lower()
        assert 'drop index' in sql and 'refresh materialized view' not in sql
    assert rows(pair, request, 'postgres', 'select id from {schema}.rendered') == [[(1,)]] * 2
    pair.write('models/marts/rendered.sql', "{{ config(materialized='materialized_view', indexes=[{'columns':['id']}], on_configuration_change='continue') }}select 2 as id")
    pair.invoke('run')
    for project in pair.projects:
        assert resource(project)['build_path'] is None
    pair.write('models/marts/rendered.sql', "{{ config(materialized='materialized_view') }}select missing_column as id")
    pair.invoke('run', ['--full-refresh'], success=False)
    for project in pair.projects:
        assert 'missing_column' in runtime_sql(project, resource(project))
    assert rows(pair, request, 'postgres', 'select id from {schema}.rendered') == [[(1,)]] * 2


def test_table_function_run_file_survives_a_failed_replacement(tmp_path, configuration_oracle, request):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'duckdb')
    for sql, success in [('select minimum as id', True), ('select missing_column as id', False)]:
        pair.write('models/marts/rendered.sql', "{{ config(materialized='table_function',parameters=['minimum']) }}" + sql)
        pair.invoke('run', success=success)
        statements = [runtime_sql(project, resource(project)) for project in pair.projects]
        assert all('create or replace function' in value.lower() and sql in value for value in statements)
    assert rows(pair, request, 'duckdb', 'select id from {schema}.rendered(3)') == [[(3,)]] * 2


def test_external_main_file_tracks_pre_copy_main_and_last_view_statement(tmp_path, configuration_oracle, request):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'duckdb')
    for project in pair.projects:
        (project / 'models/marts').mkdir(parents=True, exist_ok=True)
        (project / 'models/marts/rendered.sql').write_text("{{ config(materialized='external',location='" + str(project / 'data.parquet') + "') }}select 1 as id")
    pair.invoke('run')
    for project in pair.projects:
        sql = runtime_sql(project, resource(project)).lower()
        assert 'create ' in sql and 'view ' in sql and 'read_parquet' in sql
    assert rows(pair, request, 'duckdb', 'select id from {schema}.rendered') == [[(1,)]] * 2
    for project in pair.projects:
        (project / 'models/marts/rendered.sql').write_text("{{ config(materialized='external',location='" + str(project / 'data.parquet') + "',options={'compression':'INVALID_COMPRESSION'}) }}select 2 as id")
    pair.invoke('run', success=False)
    for project in pair.projects:
        sql = runtime_sql(project, resource(project))
        # COPY is named write_to_file, after an empty main statement for
        # nonempty data. It fails before the later view main can overwrite it.
        assert sql == ''
        result = json.loads((project / 'target/run_results.json').read_text())['results'][0]
        assert result['status'] == 'error' and 'compression' in result['message'].lower()
    assert rows(pair, request, 'duckdb', 'select id from {schema}.rendered') == [[(1,)]] * 2


@pytest.mark.parametrize('definition', [
    'none',
    "{'columns':[]}",
    "{'columns':['id']}",
    "{'columns':['id','amount'],'unique':true,'type':'hash'}",
])
def test_postgres_index_config_native_protocol_matches_core(tmp_path, configuration_oracle, request, definition):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'postgres')
    pair.write('models/marts/rendered.sql', "{% set index = adapter.parse_index(" + definition + ") %}{% if index is none %}select 1 as missing{% else %}select {{ index.columns|length }} as columns, {{ 1 if index.unique else 0 }} as unique_index, '{{ index.type }}' as method, '{{ index }}' as description, {{ index.render(this)|length }} as name_length, {{ 1 if index is mapping else 0 }} as mapping, {{ 1 if index is iterable else 0 }} as iterable, {{ 1 if index.keys is undefined else 0 }} as missing_keys{% endif %}")
    actual, expected = [manifest['nodes']['model.configuration_fixture.rendered'] for manifest in pair.invoke('compile')]
    assert actual['compiled_code'] == expected['compiled_code']


@pytest.mark.parametrize('definition', [
    '{}', "{'columns':('id',)}", "{'columns':[1]}",
    "{'columns':['id'],'unique':1}", "{'columns':['id'],'type':1}",
    "{'columns':['id'],'extra':1}",
])
def test_postgres_index_config_rejects_invalid_typed_shapes(tmp_path, configuration_oracle, request, definition):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'postgres')
    pair.write('models/marts/rendered.sql', "select '{{ adapter.parse_index(" + definition + ") }}' as index")
    pair.invoke('compile', success=False)


@pytest.mark.parametrize('expression', ['index|list', 'index|length', 'index.keys()'])
def test_postgres_index_config_does_not_expose_mapping_or_iteration_protocol(tmp_path, configuration_oracle, request, expression):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'postgres')
    pair.write('models/marts/rendered.sql', "{% set index = adapter.parse_index({'columns':['id']}) %}select '{{ " + expression + " }}' as invalid")
    pair.invoke('compile', success=False)


def test_materialized_view_empty_index_error_keeps_actual_main_file_and_no_relation(tmp_path, configuration_oracle, request):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'postgres')
    pair.write('models/marts/rendered.sql', "{{ config(materialized='materialized_view',indexes=[{'columns':[]}]) }}select 1 as id")
    pair.invoke('run', success=False)
    for project in pair.projects:
        sql = runtime_sql(project, resource(project)).lower()
        assert 'create materialized view' in sql and re.search(r'create\s+index', sql)
    assert rows(pair, request, 'postgres', "select count(*) from information_schema.tables where table_schema='{schema}' and table_name='rendered'") == [[(0,)]] * 2

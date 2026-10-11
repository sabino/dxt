from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from test_usability_commands import core_runner, native_binary, write_project, run_dxt, invoke_core, query, artifact


INPUT = """{{ config(event_time='occurred_at') }}
select * from (values
 (1,10,timestamp '2024-01-01 12:00:00'),
 (2,20,timestamp '2024-01-02 12:00:00'),
 (3,30,timestamp '2024-01-03 12:00:00'),
 (4,40,timestamp '2024-01-04 12:00:00'),
 (5,50,timestamp '2024-01-05 12:00:00')
) t(id,amount,occurred_at)
"""
EVENTS = """{{ config(materialized='incremental', incremental_strategy='microbatch',
 unique_key='id', event_time='occurred_at', begin='2024-01-01', batch_size='day') }}
select * from {{ ref('input') }}
"""
# The pinned dbt-duckdb adapter lacks stock microbatch support. This explicit
# project strategy makes Core's own batch orchestration an executable reference
# for dxt's DuckDB extension; PostgreSQL uses its built-in MERGE strategy.
DUCKDB_STRATEGY = """{% macro get_incremental_microbatch_sql(arg_dict) %}
{% set columns = arg_dict.dest_columns | map(attribute='name') | join(', ') %}
delete from {{ arg_dict.target_relation }} where id in (select id from {{ arg_dict.temp_relation }});
insert into {{ arg_dict.target_relation }} ({{ columns }}) select {{ columns }} from {{ arg_dict.temp_relation }};
{% endmacro %}
"""


def project(path: Path, *, custom_strategy=True, events=EVENTS, inputs=INPUT):
    write_project(path, {'models/input.sql': inputs, 'models/events.sql': events,
                         **({'macros/microbatch.sql': DUCKDB_STRATEGY} if custom_strategy else {})})
    if custom_strategy:
        with (path / 'dbt_project.yml').open('a') as stream:
            stream.write('flags:\n  require_batched_execution_for_custom_microbatch_strategy: true\n')
    return path


def batch_results(path):
    row = next(row for row in artifact(path)['results'] if row['unique_id'].endswith('.events'))
    batches = row['batch_results']
    return row['status'], {key: [[datetime.fromisoformat(start), datetime.fromisoformat(end)]
                                for start, end in intervals] for key, intervals in batches.items()}


def invoke(engine, runner, path, *flags):
    if engine == 'core':
        result = invoke_core(runner, path, 'run', '--select', 'events', *flags)
        return result.success
    return run_dxt(path, 'run', '--select', 'events', *flags).returncode == 0


def test_core_microbatch_duckdb_first_repeat_lookback_and_full_refresh(tmp_path, core_runner):
    today = datetime.now(timezone.utc).date()
    inputs = INPUT
    for day in range(1, 6):
        inputs = inputs.replace(f'2024-01-0{day}', str(today - timedelta(days=5 - day)))
    events = EVENTS.replace('2024-01-01', str(today - timedelta(days=4)))
    projects = {engine: project(tmp_path / engine, inputs=inputs, events=events) for engine in ['core', 'native']}
    for engine, path in projects.items():
        setup = invoke_core(core_runner, path, 'run', '--select', 'input') if engine == 'core' else run_dxt(path, 'run', '--select', 'input')
        assert setup.success if engine == 'core' else setup.returncode == 0
        assert invoke(engine, core_runner, path)
    assert query(projects['native'] / 'warehouse.duckdb', 'select * from dev.events order by id') == query(projects['core'] / 'warehouse.duckdb', 'select * from dev.events order by id')
    assert batch_results(projects['native']) == batch_results(projects['core'])
    for engine, path in projects.items():
        (path / 'models/input.sql').write_text(inputs.replace('(1,10,', '(1,100,').replace('(4,40,', '(4,400,'))
        setup = invoke_core(core_runner, path, 'run', '--select', 'input') if engine == 'core' else run_dxt(path, 'run', '--select', 'input')
        assert setup.success if engine == 'core' else setup.returncode == 0
        assert invoke(engine, core_runner, path)
    expected = [{'id': 1, 'amount': 10}, {'id': 2, 'amount': 20}, {'id': 3, 'amount': 30}, {'id': 4, 'amount': 400}, {'id': 5, 'amount': 50}]
    assert query(projects['native'] / 'warehouse.duckdb', 'select id,amount from dev.events order by id') == expected
    assert query(projects['core'] / 'warehouse.duckdb', 'select id,amount from dev.events order by id') == expected
    assert batch_results(projects['native']) == batch_results(projects['core'])
    for engine, path in projects.items():
        assert invoke(engine, core_runner, path, '--full-refresh')
    expected[0]['amount'] = 100
    assert query(projects['native'] / 'warehouse.duckdb', 'select id,amount from dev.events order by id') == expected
    assert query(projects['core'] / 'warehouse.duckdb', 'select id,amount from dev.events order by id') == expected
    assert batch_results(projects['native']) == batch_results(projects['core'])


@pytest.mark.parametrize('start,end,batch_size,begin', [
    ('2024-01-02 12:30:00', '2024-01-03 12:30:00', 'day', '2024-01-01'),
    ('2024-01-01 12:30:00', '2024-01-01 13:30:00', 'hour', '2024-01-01'),
    ('2024-01-15', '2024-02-15', 'month', '2023-12-31'),
    ('2024-06-01', '2025-06-01', 'year', '2023-12-31'),
    ('1899-01-01', '1899-01-02', 'day', '1899-01-01'),
])
def test_core_microbatch_explicit_calendar_ranges(tmp_path, core_runner, start, end, batch_size, begin):
    projects = {}
    for engine in ['core', 'native']:
        path = project(tmp_path / engine, events=EVENTS.replace("batch_size='day'", f"batch_size='{batch_size}'").replace("begin='2024-01-01'", f"begin='{begin}'"))
        projects[engine] = path
        setup = invoke_core(core_runner, path, 'run', '--select', 'input') if engine == 'core' else run_dxt(path, 'run', '--select', 'input')
        assert setup.success if engine == 'core' else setup.returncode == 0
        assert invoke(engine, core_runner, path, '--event-time-start', start, '--event-time-end', end)
    assert query(projects['native'] / 'warehouse.duckdb', 'select * from dev.events order by id') == query(projects['core'] / 'warehouse.duckdb', 'select * from dev.events order by id')
    assert batch_results(projects['native']) == batch_results(projects['core'])


@pytest.mark.parametrize('bad_id,expected_status', [(1, 'error'), (2, 'partial success')])
def test_core_microbatch_sql_errors_are_durable_and_other_batches_continue(tmp_path, core_runner, bad_id, expected_status):
    events = EVENTS.replace('select * from', f"select id,case when id={bad_id} then cast(concat(id,'invalid') as integer) else amount end as amount,occurred_at from")
    projects = {}
    for engine in ['core', 'native']:
        path = project(tmp_path / engine, events=events)
        projects[engine] = path
        setup = invoke_core(core_runner, path, 'run', '--select', 'input') if engine == 'core' else run_dxt(path, 'run', '--select', 'input')
        assert setup.success if engine == 'core' else setup.returncode == 0
        assert not invoke(engine, core_runner, path, '--event-time-start', '2024-01-01', '--event-time-end', '2024-01-05')
        assert batch_results(path)[0] == expected_status
    assert batch_results(projects['native']) == batch_results(projects['core'])
    if bad_id == 2:
        assert query(projects['native'] / 'warehouse.duckdb', 'select * from dev.events order by id') == query(projects['core'] / 'warehouse.duckdb', 'select * from dev.events order by id')
    for path in projects.values():
        assert query(path / 'warehouse.duckdb', "select table_name from information_schema.tables where table_name like '__dxt_microbatch%' ") == []


def test_core_microbatch_retry_executes_only_failed_batches_and_retains_prior_successes(tmp_path, core_runner):
    projects = {}
    broken = EVENTS.replace('select * from', "select id,case when id=2 then cast(concat(id,'invalid') as integer) else amount end as amount,occurred_at from")
    for engine in ['core', 'native']:
        path = project(tmp_path / engine, events=broken)
        projects[engine] = path
        setup = invoke_core(core_runner, path, 'run', '--select', 'input') if engine == 'core' else run_dxt(path, 'run', '--select', 'input')
        assert setup.success if engine == 'core' else setup.returncode == 0
        assert not invoke(engine, core_runner, path, '--event-time-start', '2024-01-01', '--event-time-end', '2024-01-05')
        assert batch_results(path)[0] == 'partial success'
        (path / 'models/events.sql').write_text(EVENTS)
        # Prior successful batches must remain untouched, even if their source
        # rows change before the retry.
        query(path / 'warehouse.duckdb', 'update dev.input set amount=999 where id=1')
        result = invoke_core(core_runner, path, 'retry') if engine == 'core' else run_dxt(path, 'retry')
        assert result.success if engine == 'core' else result.returncode == 0
        assert query(path / 'warehouse.duckdb', 'select id,amount from dev.events order by id') == [
            {'id': 1, 'amount': 10}, {'id': 2, 'amount': 20}, {'id': 3, 'amount': 30}, {'id': 4, 'amount': 40}]
    assert batch_results(projects['native']) == batch_results(projects['core'])


@pytest.mark.parametrize('field,replacement', [('event_time', 'null'), ('begin', "'bad-date'"), ('batch_size', "'week'"), ('lookback', "'two'")])
def test_core_microbatch_invalid_configuration_fails_without_warehouse(tmp_path, core_runner, field, replacement):
    events = EVENTS.replace("event_time='occurred_at'", f'event_time={replacement}') if field == 'event_time' else EVENTS.replace("begin='2024-01-01'", f'begin={replacement}') if field == 'begin' else EVENTS.replace("batch_size='day'", f'batch_size={replacement}') if field == 'batch_size' else EVENTS.replace("batch_size='day'", f"batch_size='day', lookback={replacement}")
    path = project(tmp_path / 'invalid', events=events)
    assert not invoke_core(core_runner, path, 'parse').success
    result = run_dxt(path, 'parse')
    assert result.returncode == 2
    assert not (path / 'warehouse.duckdb').exists()


def postgres_project(path, server, schema, *, events=EVENTS, inputs=INPUT):
    project(path, custom_strategy=False, events=events, inputs=inputs)
    info = server.get_postmaster_info()
    (path / 'profiles.yml').write_text(f"""commands:
  target: dev
  outputs:
    dev:
      type: postgres
      host: '{info.socket_dir}'
      port: {info.port}
      dbname: postgres
      user: postgres
      password: ''
      schema: {schema}
      threads: 1
""")
    return path


def postgres_rows(server, schema):
    import psycopg2
    with psycopg2.connect(server.get_uri()) as connection, connection.cursor() as cursor:
        cursor.execute(f'select id,amount,occurred_at from {schema}.events order by id')
        return cursor.fetchall()


def test_core_postgres_microbatch_first_repeat_full_refresh_and_explicit_interval(tmp_path, core_runner):
    import postgres_fixture as pgserver
    from importlib.metadata import version
    assert version('dbt-postgres') == '1.9.1'
    today = datetime.now(timezone.utc).date()
    inputs = INPUT
    for day in range(1, 6):
        inputs = inputs.replace(f'2024-01-0{day}', str(today - timedelta(days=5 - day)))
    events = EVENTS.replace('2024-01-01', str(today - timedelta(days=4)))
    with pgserver.get_server(tmp_path / 'postgres-data') as server:
        projects = {engine: postgres_project(tmp_path / engine, server, engine, inputs=inputs, events=events)
                    for engine in ['core', 'native']}
        for engine, path in projects.items():
            assert invoke_core(core_runner, path, 'run', '--select', 'input').success
            assert invoke(engine, core_runner, path)
        assert postgres_rows(server, 'native') == postgres_rows(server, 'core')
        assert batch_results(projects['native']) == batch_results(projects['core'])
        for engine, path in projects.items():
            (path / 'models/input.sql').write_text(inputs.replace('(1,10,', '(1,100,').replace('(4,40,', '(4,400,'))
            assert invoke_core(core_runner, path, 'run', '--select', 'input').success
            assert invoke(engine, core_runner, path)
        assert [(id, amount) for id, amount, _ in postgres_rows(server, 'native')] == [(1,10),(2,20),(3,30),(4,400),(5,50)]
        assert postgres_rows(server, 'native') == postgres_rows(server, 'core')
        assert batch_results(projects['native']) == batch_results(projects['core'])
        for engine, path in projects.items():
            assert invoke(engine, core_runner, path, '--full-refresh')
        assert postgres_rows(server, 'native') == postgres_rows(server, 'core')
        assert postgres_rows(server, 'native')[0][1] == 100
        assert batch_results(projects['native']) == batch_results(projects['core'])
        start, end = str(today - timedelta(days=2)), str(today)
        for engine, path in projects.items():
            assert invoke(engine, core_runner, path, '--event-time-start', start, '--event-time-end', end)
        assert postgres_rows(server, 'native') == postgres_rows(server, 'core')
        assert batch_results(projects['native']) == batch_results(projects['core'])


@pytest.mark.parametrize('bad_id,expected_status', [(1, 'error'), (2, 'partial success')])
def test_core_postgres_microbatch_batch_errors_rollback_and_retry(tmp_path, core_runner, bad_id, expected_status):
    import postgres_fixture as pgserver
    import psycopg2
    broken = EVENTS.replace('select * from', f"select id,case when id={bad_id} then cast(concat(id,'invalid') as integer) else amount end as amount,occurred_at from")
    with pgserver.get_server(tmp_path / 'postgres-data') as server:
        projects = {engine: postgres_project(tmp_path / engine, server, engine, events=broken)
                    for engine in ['core', 'native']}
        for engine, path in projects.items():
            assert invoke_core(core_runner, path, 'run', '--select', 'input').success
            assert not invoke(engine, core_runner, path, '--event-time-start', '2024-01-01', '--event-time-end', '2024-01-05')
            assert batch_results(path)[0] == expected_status
            assert artifact(path)['results'][0]['failures'] == 0
        assert batch_results(projects['native']) == batch_results(projects['core'])
        if bad_id == 2:
            assert postgres_rows(server, 'native') == postgres_rows(server, 'core')
        else:
            with psycopg2.connect(server.get_uri()) as connection, connection.cursor() as cursor:
                cursor.execute("select table_schema from information_schema.tables where table_name='events'")
                assert cursor.fetchall() == []
        for engine, path in projects.items():
            (path / 'models/events.sql').write_text(EVENTS)
            with psycopg2.connect(server.get_uri()) as connection, connection.cursor() as cursor:
                cursor.execute(f'update {engine}.input set amount=999 where id=1')
            result = invoke_core(core_runner, path, 'retry') if engine == 'core' else run_dxt(path, 'retry')
            assert result.success if engine == 'core' else result.returncode == 0, result
        assert postgres_rows(server, 'native') == postgres_rows(server, 'core')
        assert batch_results(projects['native']) == batch_results(projects['core'])
        assert postgres_rows(server, 'native')[0][1] == (999 if bad_id == 1 else 10)


@pytest.mark.parametrize('dialect', ['duckdb', 'postgres'])
def test_core_microbatch_failed_full_refresh_preserves_existing_relation(tmp_path, core_runner, dialect):
    import postgres_fixture as pgserver
    import psycopg2
    from contextlib import nullcontext
    with pgserver.get_server(tmp_path / 'postgres-data') if dialect == 'postgres' else nullcontext(None) as server:
        projects = {engine: (postgres_project(tmp_path / engine, server, engine) if server else project(tmp_path / engine))
                    for engine in ['core', 'native']}
        for engine, path in projects.items():
            assert invoke_core(core_runner, path, 'run', '--select', 'input').success
            assert invoke(engine, core_runner, path, '--event-time-start', '2024-01-01', '--event-time-end', '2024-01-05')
        before = postgres_rows(server, 'core') if server else query(projects['core'] / 'warehouse.duckdb', 'select * from dev.events order by id')
        for engine, path in projects.items():
            (path / 'models/events.sql').write_text(EVENTS.replace('select * from', "select id,cast(concat(id,'invalid') as integer) as amount,occurred_at from"))
            assert not invoke(engine, core_runner, path, '--full-refresh', '--event-time-start', '2024-01-01', '--event-time-end', '2024-01-05')
            actual = postgres_rows(server, engine) if server else query(path / 'warehouse.duckdb', 'select * from dev.events order by id')
            assert actual == before
        assert batch_results(projects['native']) == batch_results(projects['core'])


@pytest.mark.parametrize('unique_key,end,expected_status', [('none','2024-01-02','success'), ('none','2024-01-03','partial success'), ('[]','2024-01-03','partial success')])
def test_core_postgres_microbatch_unique_key_required_when_merging_existing_table(tmp_path, core_runner, unique_key, end, expected_status):
    import postgres_fixture as pgserver
    events = EVENTS.replace("unique_key='id'", f'unique_key={unique_key}')
    with pgserver.get_server(tmp_path / 'postgres-data') as server:
        projects = {engine: postgres_project(tmp_path / engine, server, engine, events=events)
                    for engine in ['core', 'native']}
        for engine, path in projects.items():
            assert invoke_core(core_runner, path, 'run', '--select', 'input').success
            assert invoke(engine, core_runner, path, '--event-time-start', '2024-01-01', '--event-time-end', end) == (expected_status == 'success')
            assert batch_results(path)[0] == expected_status
        assert postgres_rows(server, 'native') == postgres_rows(server, 'core')
        assert batch_results(projects['native']) == batch_results(projects['core'])


@pytest.mark.parametrize('dialect', ['duckdb','postgres'])
def test_core_custom_microbatch_strategy_requires_batched_behavior_opt_in(tmp_path, core_runner, dialect):
    import postgres_fixture as pgserver
    from contextlib import nullcontext
    with pgserver.get_server(tmp_path / 'postgres-data') if dialect == 'postgres' else nullcontext(None) as server:
        projects = {engine: (postgres_project(tmp_path / engine, server, engine) if server else project(tmp_path / engine))
                    for engine in ['core','native']}
        for engine, path in projects.items():
            (path / 'macros').mkdir(exist_ok=True)
            (path / 'macros/microbatch.sql').write_text(DUCKDB_STRATEGY)
            (path / 'dbt_project.yml').write_text((path / 'dbt_project.yml').read_text().replace('require_batched_execution_for_custom_microbatch_strategy: true', 'require_batched_execution_for_custom_microbatch_strategy: false'))
            assert invoke_core(core_runner, path, 'run', '--select', 'input').success
            assert invoke(engine, core_runner, path, '--event-time-start','2024-01-01','--event-time-end','2024-01-03')
            row = artifact(path)['results'][0]
            assert row.get('batch_results') is None
            assert len(postgres_rows(server, engine) if server else query(path / 'warehouse.duckdb', 'select * from dev.events')) == 5
            assert invoke(engine, core_runner, path, '--event-time-start','2024-01-01','--event-time-end','2024-01-03') == (dialect == 'postgres')
        if server:
            assert postgres_rows(server, 'native') == postgres_rows(server, 'core')


@pytest.mark.parametrize('input_kind', ['model','source','ephemeral'])
def test_core_microbatch_source_model_filter_and_sample_intersection(tmp_path, core_runner, input_kind):
    projects = {}
    sample = '{start: "2024-01-02 12:30:00", end: "2024-01-03 12:30:00"}'
    for engine in ['core','native']:
        path = project(tmp_path / engine)
        projects[engine] = path
        assert invoke_core(core_runner, path, 'run', '--select', 'input').success
        if input_kind == 'source':
            (path / 'models/source.yml').write_text("version: 2\nsources:\n  - name: raw\n    schema: dev\n    tables:\n      - name: input\n        config:\n          event_time: occurred_at\n")
            (path / 'models/events.sql').write_text(EVENTS.replace("ref('input')", "source('raw','input')"))
        if input_kind == 'ephemeral':
            (path / 'models/input_ephemeral.sql').write_text("{{ config(materialized='ephemeral', event_time='occurred_at') }} select * from {{ ref('input') }}")
            (path / 'models/events.sql').write_text(EVENTS.replace("ref('input')", "ref('input_ephemeral')"))
        assert invoke(engine, core_runner, path, '--sample', sample)
    assert query(projects['native'] / 'warehouse.duckdb', 'select * from dev.events order by id') == query(projects['core'] / 'warehouse.duckdb', 'select * from dev.events order by id')
    assert batch_results(projects['native']) == batch_results(projects['core'])


def test_core_microbatch_build_partial_failure_skips_dependents_and_runs_independent(tmp_path, core_runner):
    projects = {}
    for engine in ['core','native']:
        path = project(tmp_path / engine, events=EVENTS.replace('select * from', "select id,case when id=2 then cast(concat(id,'invalid') as integer) else amount end as amount,occurred_at from"))
        projects[engine] = path
        (path / 'models/child.sql').write_text("select * from {{ ref('events') }}")
        (path / 'models/independent.sql').write_text('select 1 as value')
        result = invoke_core(core_runner, path, 'build', '--event-time-start','2024-01-01','--event-time-end','2024-01-05') if engine == 'core' else run_dxt(path, 'build', '--event-time-start','2024-01-01','--event-time-end','2024-01-05')
        assert not result.success if engine == 'core' else result.returncode == 1
        statuses = {row['unique_id']:row['status'] for row in artifact(path)['results']}
        assert statuses == {'model.commands.input':'success','model.commands.events':'partial success','model.commands.child':'skipped','model.commands.independent':'success'}
    assert batch_results(projects['native']) == batch_results(projects['core'])


@pytest.mark.parametrize('dialect', ['duckdb','postgres'])
@pytest.mark.parametrize('begin', ['2024-01-01','2024-01-01T00:00:00+02:00'])
def test_core_microbatch_model_datetime_and_typed_strategy_context(tmp_path, core_runner, dialect, begin):
    import postgres_fixture as pgserver
    from contextlib import nullcontext
    metadata = """{% if model.batch %}
select *, '{{ model.batch.id }}' as batch_id,
 '{{ model.batch.event_time_start.strftime('%Y-%m-%d %H:%M:%S %z') }}' as start_time,
 '{{ model.batch.event_time_end.isoformat() }}' as end_time,
 '{{ config.get('__dbt_internal_microbatch_event_time_start').date().isoformat() }}' as config_start,
 '{{ config.get('begin').isoformat() }}' as config_begin,
 {{ config.get('lookback') }} as lookback,
 '{{ model.config.batch_size }}' as batch_size
from {{ ref('input') }}
{% else %}
select *, '' as batch_id, '' as start_time, '' as end_time, '' as config_start, '' as config_begin, 1 as lookback, '' as batch_size from {{ ref('input') }}
{% endif %}
"""
    strategy = """{% macro get_incremental_microbatch_sql(arg_dict) %}
{% if not arg_dict.target_relation.is_table or not arg_dict.temp_relation.is_table %}
  {{ exceptions.raise_compiler_error('strategy relations must be tables') }}
{% endif %}
{% if arg_dict.target_relation.identifier != this.identifier or config.get('unique_key') != 'id' or not model.batch.id %}
  {{ exceptions.raise_compiler_error('strategy node context is missing') }}
{% endif %}
{% if not arg_dict.dest_columns[0].is_integer() %}
  {{ exceptions.raise_compiler_error('strategy columns must support native methods') }}
{% endif %}
{% set columns = arg_dict.dest_columns | map(attribute='quoted') | join(', ') %}
delete from {{ arg_dict.target_relation.render() }} where id in (select id from {{ arg_dict.temp_relation.render() }});
insert into {{ arg_dict.target_relation }} ({{ columns }}) select {{ columns }} from {{ arg_dict.temp_relation }};
{% endmacro %}
"""
    with pgserver.get_server(tmp_path / 'postgres-data') if dialect == 'postgres' else nullcontext(None) as server:
        projects = {engine: (postgres_project(tmp_path / engine, server, engine, events=EVENTS.replace("select * from {{ ref('input') }}", metadata).replace("begin='2024-01-01'", f"begin='{begin}'")) if server else project(tmp_path / engine, events=EVENTS.replace("select * from {{ ref('input') }}", metadata).replace("begin='2024-01-01'", f"begin='{begin}'")))
                    for engine in ['core','native']}
        data = {}
        for engine, path in projects.items():
            (path / 'macros').mkdir(exist_ok=True)
            (path / 'macros/microbatch.sql').write_text(strategy)
            if server:
                with (path / 'dbt_project.yml').open('a') as stream:
                    stream.write('flags:\n  require_batched_execution_for_custom_microbatch_strategy: true\n')
            assert invoke_core(core_runner, path, 'run', '--select', 'input').success
            assert invoke(engine, core_runner, path, '--event-time-start','2024-01-01','--event-time-end','2024-01-04')
            if server:
                import psycopg2
                with psycopg2.connect(server.get_uri()) as connection, connection.cursor() as cursor:
                    cursor.execute(f'select * from {engine}.events order by id')
                    data[engine] = cursor.fetchall()
            else:
                data[engine] = query(path / 'warehouse.duckdb', 'select * from dev.events order by id')
        assert data['native'] == data['core']
        assert batch_results(projects['native']) == batch_results(projects['core'])
        config_keys = ['event_time','begin','batch_size','lookback','concurrent_batches']
        configs = {engine:json.loads((path / 'target/manifest.json').read_text())['nodes']['model.commands.events']['config'] for engine,path in projects.items()}
        assert {key:configs['native'].get(key) for key in config_keys} == {key:configs['core'].get(key) for key in config_keys}


def test_core_microbatch_parallel_models_use_isolated_temporary_stages(tmp_path, core_runner):
    projects = {}
    for engine in ['core','native']:
        path = project(tmp_path / engine)
        projects[engine] = path
        (path / 'models/events_two.sql').write_text(EVENTS)
        assert invoke_core(core_runner, path, 'run', '--select','input').success
        result = invoke_core(core_runner, path, 'run','--select','events events_two','--threads','2','--event-time-start','2024-01-01','--event-time-end','2024-01-05') if engine == 'core' else run_dxt(path,'run','--select','events events_two','--threads','2','--event-time-start','2024-01-01','--event-time-end','2024-01-05')
        assert result.success if engine == 'core' else result.returncode == 0, result
        assert {row['status'] for row in artifact(path)['results']} == {'success'}
        assert query(path / 'warehouse.duckdb','select * from dev.events order by id') == query(path / 'warehouse.duckdb','select * from dev.events_two order by id')
    assert query(projects['native'] / 'warehouse.duckdb','select * from dev.events order by id') == query(projects['core'] / 'warehouse.duckdb','select * from dev.events order by id')
    assert batch_results(projects['native']) == batch_results(projects['core'])


@pytest.mark.parametrize('config', ["merge_update_columns=['amount']", "merge_exclude_columns=['occurred_at']"])
def test_core_postgres_microbatch_preserves_excluded_update_columns(tmp_path, core_runner, config):
    import postgres_fixture as pgserver
    events = EVENTS.replace("batch_size='day'", f"batch_size='day', {config}")
    with pgserver.get_server(tmp_path / 'postgres-data') as server:
        projects = {engine: postgres_project(tmp_path / engine, server, engine, events=events)
                    for engine in ['core','native']}
        for engine, path in projects.items():
            assert invoke_core(core_runner,path,'run','--select','input').success
            assert invoke(engine, core_runner, path,'--event-time-start','2024-01-01','--event-time-end','2024-01-03')
            (path / 'models/input.sql').write_text(INPUT.replace('(1,10,','(1,999,').replace('2024-01-01 12:00:00','2024-01-01 14:00:00'))
            assert invoke_core(core_runner,path,'run','--select','input').success
            assert invoke(engine, core_runner, path,'--event-time-start','2024-01-01','--event-time-end','2024-01-03')
        assert postgres_rows(server,'native') == postgres_rows(server,'core')
        assert postgres_rows(server,'native')[0] == (1,999,datetime(2024,1,1,12))
        assert batch_results(projects['native']) == batch_results(projects['core'])

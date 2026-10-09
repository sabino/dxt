"""Mandatory pinned Core profiling and real main-thread execution contracts."""
from __future__ import annotations
import io
import json
import pstats
import pytest
from test_cli import DXT, build_dxt  # noqa: F401
from test_usability_adapters import duckdb_environment, postgres_fixture, driver  # noqa: F401
from test_usability_cli_options import environment, invoke
from test_usability_cli_execution import project, query, pinned  # noqa: F401


def model_project(tmp_path, engine, adapter, server=None):
    root, db, schema = project(tmp_path, engine, adapter, server)
    (root / 'macros').mkdir()
    (root / 'macros/twice.sql').write_text('{% macro twice(x) %}{{ return(x * 2) }}{% endmacro %}')
    (root / 'models/a.sql').write_text("{{ config(materialized='table') }} select {{ twice(2) }} as id\n")
    (root / 'models/b.sql').write_text("{{ config(materialized='table') }} {{ log('single-main', info=true) }} select * from {{ ref('a') }}\n")
    return root, db, schema


def stats(path, *, native=False):
    report = pstats.Stats(str(path), stream=io.StringIO())
    assert report.total_calls > 0 and report.total_tt > 0 and report.stats
    report.strip_dirs().sort_stats('cumulative').print_stats()
    for key, value in report.stats.items():
        assert len(key) == 3 and len(value) == 5
        cc, nc, tt, ct, callers = value
        assert nc >= cc >= 0 and tt >= 0 and ct >= 0 and isinstance(callers, dict)
        # cProfile's thread-switching/exception records may contain nc=0 or
        # truncated cumulative times. Native completed spans retain both times.
        if native:
            assert nc > 0 and ct >= tt
    return report


@pytest.mark.parametrize('command', ['parse', 'compile', 'run'])
def test_core_record_timing_profile_is_readable_and_contains_measured_native_work(tmp_path, duckdb_environment, command):
    for engine in ['dxt', 'core']:
        root, _, _ = model_project(tmp_path, engine, 'duckdb')
        path = root / 'timing.profile'
        flag = ['-r', path] if command == 'parse' else [f'--record-timing-info={path}']
        invoke(engine, ['-q', *flag, command, '--project-dir', root, '--profiles-dir', root], root, environment(duckdb_environment))
        report = stats(path, native=engine == 'dxt')
        if engine == 'dxt':
            functions = {key[2] for key in report.stats}
            assert {'runCommand', 'loadGraph'} <= functions
            if command != 'parse':
                assert {'compileModelBody', 'renderMacroValue'} <= functions
            if command == 'run':
                assert 'Job.work' in functions
        if command != 'parse':
            args = json.loads((root / 'target/run_results.json').read_text())['args']
            assert args['record_timing_info'] == str(path)


@pytest.mark.parametrize('failure', ['parse', 'execution'])
def test_core_record_timing_profile_is_written_after_runtime_failures(tmp_path, duckdb_environment, failure):
    for engine in ['dxt', 'core']:
        root, _, _ = model_project(tmp_path, engine, 'duckdb')
        path = root / 'failed.profile'
        if failure == 'parse':
            (root / 'models/a.sql').write_text("select * from {{ ref('required_missing') }}")
            command = 'parse'
        else:
            (root / 'models/a.sql').write_text('select missing_column from (select 1 as id) input')
            command = 'run'
        result = invoke(engine, ['-q', command, '--project-dir', root, '--profiles-dir', root, '-r', path], root, environment(duckdb_environment), ok=False)
        assert result.returncode != 0
        stats(path, native=engine == 'dxt')


def events(result):
    output = []
    for line in (result.stdout + result.stderr).splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict) and isinstance(event.get('info'), dict):
            output.append(event)
    return output


def test_core_single_threaded_postgres_compiles_on_main_and_keeps_requested_threads(tmp_path, postgres_fixture):
    server, native = postgres_fixture
    for engine in ['dxt', 'core']:
        root, _, _ = model_project(tmp_path, engine, 'postgres', server)
        for flags, env, expected in [
            (['--single-threaded'], {}, True),
            ([], {'DBT_SINGLE_THREADED': 'true'}, True),
            (['--no-single-threaded'], {'DBT_SINGLE_THREADED': 'true'}, False),
        ]:
            result = invoke(engine, [*flags, '--log-format', 'json', 'compile', '--project-dir', root, '--profiles-dir', root, '--threads', '3'], root, environment(native, **env))
            artifact = json.loads((root / 'target/run_results.json').read_text())
            assert artifact['args'].get('single_threaded', False) is expected
            if not expected:
                assert 'single_threaded' not in artifact['args']
            assert artifact['args']['threads'] == 3
            assert {r['thread_id'] == 'MainThread' for r in artifact['results']} == {expected}
            messages = [e for e in events(result) if e['info']['name'].startswith('JinjaLog') and e.get('data', {}).get('msg') == 'single-main']
            assert messages and {e['info']['thread'] == 'MainThread' for e in messages} == {expected}


def test_core_single_threaded_source_freshness_uses_main_thread(tmp_path, postgres_fixture, driver):
    server, native = postgres_fixture
    for engine in ['dxt', 'core']:
        root, db, schema = model_project(tmp_path, engine, 'postgres', server)
        query(driver, 'postgres', db, native, f'create schema "{schema}"; create table "{schema}".events as select now() as loaded_at')
        (root / 'models/sources.yml').write_text(f"sources:\n  - name: raw\n    schema: {schema}\n    tables:\n      - name: events\n        config:\n          loaded_at_field: loaded_at\n          freshness:\n            warn_after: {{count: 1, period: day}}\n            error_after: {{count: 2, period: day}}\n")
        invoke(engine, ['-q', '--single-threaded', 'source', 'freshness', '--project-dir', root, '--profiles-dir', root], root, environment(native))
        results = json.loads((root / 'target/sources.json').read_text())['results']
        assert len(results) == 1 and results[0]['thread_id'] == 'MainThread' and results[0]['status'] == 'pass'


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_native_single_threaded_runs_directly_despite_core_main_connection_bug(tmp_path, request, adapter):
    server, native = (None, request.getfixturevalue('duckdb_environment')) if adapter == 'duckdb' else request.getfixturevalue('postgres_fixture')
    root, _, _ = model_project(tmp_path, 'dxt', adapter, server)
    profile = root / 'native.profile'
    invoke('dxt', ['-q', '--single-threaded', '-r', profile, 'run', '--project-dir', root, '--profiles-dir', root, '--threads', '3'], root, environment(native))
    results = json.loads((root / 'target/run_results.json').read_text())['results']
    assert len(results) == 2 and {r['thread_id'] for r in results} == {'MainThread'}
    report = stats(profile, native=True)
    job_keys = [key for key in report.stats if key[2] == 'Job.work']
    assert len(job_keys) == 1 and report.stats[job_keys[0]][1] == 2
    assert {caller[2] for caller in report.stats[job_keys[0]][4]} == {'runCommand'}
    # Core 1.10.5 closes the cached main connection before running the direct
    # runner on both pinned adapters. Capture that failure without a skip.
    core, _, _ = model_project(tmp_path, 'core', adapter, server)
    result = invoke('core', ['-q', '--single-threaded', 'run', '--project-dir', core, '--profiles-dir', core], core, environment(native), ok=False)
    assert result.returncode == 2 and 'connection already closed' in (result.stdout + result.stderr).lower()


def test_core_record_timing_info_help_does_not_start_profiling(tmp_path, duckdb_environment):
    for engine in ['dxt', 'core']:
        path = tmp_path / f'{engine}.profile'
        invoke(engine, ['-r', path, '--help'], tmp_path, environment(duckdb_environment))
        assert not path.exists()

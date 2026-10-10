"""DuckDB warning-once events share the invocation's concurrent adapter scope."""
import json

import pytest

from test_cli import build_dxt
from test_usability_adapters import duckdb_environment
from test_usability_cli_options import environment, invoke, project


def warnings(output):
    result = []
    for line in output.splitlines():
        if not line.startswith('{'):
            continue
        event = json.loads(line)
        if event.get('info', {}).get('name') == 'AdapterEventWarning':
            result.append({
                'level': event['info']['level'],
                'message': event['info']['msg'],
                'data': {key: event['data'][key] for key in ('name', 'base_msg', 'args')},
            })
    return sorted(result, key=lambda event: event['data']['base_msg'])


@pytest.mark.parametrize('command,threads,flags', [('run', 1, []), ('run', 4, []), ('compile', 1, []), ('compile', 4, []), ('run', 4, ['--warn-error'])])
def test_adapter_warning_once_shared_by_concurrent_nodes_and_reset_each_invocation(tmp_path, duckdb_environment, command, threads, flags):
    root, _ = project(tmp_path)
    for path in (root / 'models').glob('*.sql'):
        path.unlink()
    for name in ['a', 'b', 'c', 'd']:
        (root / 'models' / (name + '.sql')).write_text("{% if execute %}{% do adapter.warn_once('shared warning') %}{% do adapter.warn_once('shared warning') %}{% do adapter.warn_once('another warning') %}{% endif %}select 1 as id")
    env = environment(duckdb_environment)
    observed = {}
    for engine in ['dxt', 'core']:
        args = ['--log-format', 'json', '--no-partial-parse', command, '--project-dir', root, '--profiles-dir', root, '--threads', threads, *flags]
        repeated = [warnings(invoke(engine, args, root, env).stdout) for _ in range(2)]
        assert repeated[0] == repeated[1]
        assert [entry['data']['base_msg'] for entry in repeated[0]] == ['another warning', 'shared warning']
        observed[engine] = repeated[0]
    assert observed['dxt'] == observed['core']


def test_adapter_warning_respects_quiet_console_and_keeps_file_event(tmp_path, duckdb_environment):
    root, _ = project(tmp_path)
    (root / 'models/a.sql').write_text("{% if execute %}{% do adapter.warn_once('quiet warning') %}{% endif %}select 1 as id")
    env = environment(duckdb_environment)
    for engine in ['dxt', 'core']:
        logs = tmp_path / (engine + '-logs')
        result = invoke(engine, ['--quiet', '--log-format-file', 'json', '--log-path', logs, '--no-partial-parse', 'run', '--project-dir', root, '--profiles-dir', root], root, env)
        assert result.stdout == result.stderr == ''
        output = warnings((logs / 'dbt.log').read_text())
        assert len(output) == 1
        assert output[0]['data']['base_msg'] == 'quiet warning'


@pytest.mark.parametrize('command', ['parse', 'list', 'compile', 'run'])
def test_adapter_warnings_during_parse_share_runtime_scope_and_preserve_core_event(tmp_path, duckdb_environment, command):
    root, _ = project(tmp_path)
    (root / 'models/a.sql').write_text("{% do adapter.warn_once('parse warning') %}select 1 as id")
    (root / 'models/b.sql').write_text("{% do adapter.warn_once('parse warning') %}select * from {{ ref('a') }}")
    env = environment(duckdb_environment)
    observed = {}
    for engine in ['dxt', 'core']:
        result = invoke(engine, ['--log-format', 'json', '--no-partial-parse', command, '--project-dir', root, '--profiles-dir', root], root, env)
        observed[engine] = warnings(result.stdout)
        assert len(observed[engine]) == 1
    assert observed['dxt'] == observed['core']


def test_adapter_warning_precedes_later_parse_error_without_getting_lost(tmp_path, duckdb_environment):
    root, _ = project(tmp_path)
    (root / 'models/a.sql').write_text("{% do adapter.warn_once('before parse error') %}{{ exceptions.raise_compiler_error('later parse error') }}select 1 as id")
    env = environment(duckdb_environment)
    observed = {}
    for engine in ['dxt', 'core']:
        result = invoke(engine, ['--log-format', 'json', '--no-partial-parse', 'parse', '--project-dir', root, '--profiles-dir', root], root, env, ok=False)
        assert result.returncode == 2
        observed[engine] = warnings(result.stdout)
        assert len(observed[engine]) == 1
    assert observed['dxt'] == observed['core']

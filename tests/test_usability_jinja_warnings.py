"""Core authored warnings retain parse/runtime event policy and stdout routing."""
import json

import pytest

from test_cli import build_dxt
from test_usability_adapters import duckdb_environment
from test_usability_cli_options import environment, invoke, project


def warning_events(text):
    events = []
    for line in text.splitlines():
        if line.startswith('{'):
            event = json.loads(line)
            if event.get('info', {}).get('name') == 'JinjaLogWarning':
                events.append((event['info']['level'], event['info']['msg'], event['data']['msg']))
    return events


@pytest.mark.parametrize('command', ['parse', 'list', 'compile', 'run'])
def test_authored_jinja_warning_retains_each_phase_event(tmp_path, duckdb_environment, command):
    root, _ = project(tmp_path)
    (root / 'models/a.sql').write_text("{{ config(materialized='table') }}{% do exceptions.warn('authored warning') %}select 1 as id")
    observed = {}
    for engine in ['dxt', 'core']:
        output = invoke(engine, ['--log-format', 'json', '--no-partial-parse', command, '--project-dir', root, '--profiles-dir', root], root, environment(duckdb_environment))
        observed[engine] = warning_events(output.stdout)
        assert warning_events(output.stderr) == []
    assert observed['dxt'] == observed['core']
    assert len(observed['dxt']) == (1 if command in ['parse', 'list'] else 2)


@pytest.mark.parametrize('flags,count,success', [(['--warn-error'], 0, False), (['--warn-error-options', '{error: [JinjaLogWarning]}'], 0, False), (['--warn-error-options', '{silence: [JinjaLogWarning]}'], 0, True)])
def test_authored_warning_obeys_core_event_promotion_and_silencing(tmp_path, duckdb_environment, flags, count, success):
    root, _ = project(tmp_path)
    (root / 'models/a.sql').write_text("{% do exceptions.warn(msg='policy warning') %}select 1 as id")
    for engine in ['dxt', 'core']:
        output = invoke(engine, ['--log-format', 'json', '--no-partial-parse', 'parse', '--project-dir', root, '--profiles-dir', root, *flags], root, environment(duckdb_environment), ok=success)
        assert output.returncode == (0 if success else 2)
        assert len(warning_events(output.stdout)) == count
        if not success:
            assert 'policy warning' in output.stdout + output.stderr

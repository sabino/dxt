"""Real empty task queues and warning policies against pinned dbt Core 1.10.5."""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from test_cli import DXT, build_dxt  # noqa: F401
from test_usability_adapters import duckdb_environment  # noqa: F401
from test_usability_cli_options import environment, invoke, pinned_core, write_profile  # noqa: F401

COMMANDS = ['run', 'build', 'test', 'snapshot', 'seed', 'compile']


def fixture_project(tmp_path: Path, engine: str, kind: str):
    root = tmp_path / engine / kind
    (root / 'models').mkdir(parents=True)
    (root / 'dbt_project.yml').write_text(
        "name: cli_fixture\nversion: '1.0'\nconfig-version: 2\nprofile: cli_fixture\n"
    )
    database = root / 'warehouse.duckdb'
    write_profile(root, database)
    if kind == 'disabled':
        (root / 'models/a.sql').write_text('{{ config(enabled=false) }} select 1 as id')
    elif kind in ['missing', 'model']:
        (root / 'models/a.sql').write_text("{{ config(materialized='table') }} select 1 as id")
    elif kind == 'empty_sql':
        (root / 'models/a.sql').write_text(' \n\t')
    return root, database


def records(result):
    return [json.loads(line) for text in [result.stdout, result.stderr]
            for line in text.splitlines() if line.startswith('{')]


def warnings(result):
    return [(row['info']['name'], row['info']['code'], row['info']['msg'])
            for row in records(result) if row['info']['level'] == 'warn']


def run(engine, root, env, command, flags=(), *, ok=True):
    return invoke(engine, ['--no-use-colors', '--log-format=json', command, *flags,
                          '--project-dir', root, '--profiles-dir', root], root, env, ok=ok)


def empty_artifacts(root, command):
    manifest = json.loads((root / 'target/manifest.json').read_text())
    artifact = json.loads((root / 'target/run_results.json').read_text())
    assert artifact['results'] == []
    assert artifact['elapsed_time'] == 0.0
    assert artifact['args']['which'] == command
    assert manifest['metadata']['dbt_schema_version'].endswith('/v12.json')
    return manifest


@pytest.mark.parametrize('command', COMMANDS)
def test_core_empty_disabled_missing_and_empty_sql_tasks(tmp_path, duckdb_environment, command):
    env = environment(duckdb_environment)
    for kind in ['empty', 'disabled', 'missing', 'empty_sql']:
        observed = {}
        for engine in ['dxt', 'core']:
            root, database = fixture_project(tmp_path, engine, kind)
            if command != 'compile':
                with (root / 'dbt_project.yml').open('a') as file:
                    file.write('on-run-start: ["select empty_selection_hook_must_not_execute()"]\n'
                               'on-run-end: ["select empty_selection_hook_must_not_execute()"]\n')
            flags = ['--select=absent'] if kind == 'missing' else []
            result = run(engine, root, env, command, flags)
            manifest = empty_artifacts(root, command)
            assert not database.exists(), result.stdout + result.stderr
            if kind == 'disabled':
                assert 'model.cli_fixture.a' in manifest['disabled']
            observed[engine] = warnings(result)
        assert observed['dxt'] == observed['core']
        assert observed['dxt'][-1] == ('NothingToDo', 'Q035',
            'Nothing to do. Try checking your model configs and model specification args')
        expected_count = (4 if command == 'build' else 2) if kind == 'missing' else 1
        assert len(observed['dxt']) == expected_count


@pytest.mark.parametrize('command', ['test', 'seed', 'snapshot'])
def test_core_matching_another_resource_type_is_a_successful_empty_task(tmp_path, duckdb_environment, command):
    observed = {}
    for engine in ['dxt', 'core']:
        root, database = fixture_project(tmp_path, engine, 'model')
        result = run(engine, root, environment(duckdb_environment), command, ['--select=a'])
        empty_artifacts(root, command)
        assert not database.exists()
        observed[engine] = warnings(result)
        assert [name for name, _, _ in observed[engine]] == ['NothingToDo']
    assert observed['dxt'] == observed['core']


@pytest.mark.parametrize('policy,expected_exit,event_names', [
    (['--warn-error'], 2, []),
    (['--warn-error-options', '{error: [NoNodesForSelectionCriteria]}'], 2, []),
    (['--warn-error-options', '{error: [NothingToDo]}'], 2, ['NoNodesForSelectionCriteria']),
    (['--warn-error-options', '{silence: [NoNodesForSelectionCriteria, NothingToDo]}'], 0, []),
    (['--warn-error-options', '{error: all, warn: [NoNodesForSelectionCriteria, NothingToDo]}'], 0,
     ['NoNodesForSelectionCriteria', 'NothingToDo']),
])
def test_core_empty_selection_warning_promotion_and_silencing(tmp_path, duckdb_environment, policy, expected_exit, event_names):
    observed = {}
    for engine in ['dxt', 'core']:
        root, database = fixture_project(tmp_path, engine, 'missing')
        result = run(engine, root, environment(duckdb_environment), 'run', [*policy, '--select=absent'], ok=False)
        assert result.returncode == expected_exit, result.stdout + result.stderr
        assert (root / 'target/manifest.json').exists()
        assert (root / 'target/run_results.json').exists() == (expected_exit == 0)
        assert not database.exists()
        observed[engine] = warnings(result)
        assert [name for name, _, _ in observed[engine]] == event_names
        if expected_exit:
            assert any(row['info']['level'] == 'error' for row in records(result))
    assert observed['dxt'] == observed['core']


@pytest.mark.parametrize('criteria', [['--select', 'a', 'absent'], ['--select', 'a,absent'], ['--select', 'a', '--exclude', 'absent']])
def test_core_unmatched_union_intersection_and_exclusion_criteria(tmp_path, duckdb_environment, criteria):
    observed = {}
    for engine in ['dxt', 'core']:
        root, _ = fixture_project(tmp_path, engine, 'model')
        result = run(engine, root, environment(duckdb_environment), 'compile', criteria)
        observed[engine] = warnings(result)
        expected = 'a,absent' if criteria == ['--select', 'a,absent'] else 'absent'
        assert observed[engine][0][2] == f"The selection criterion '{expected}' does not match any enabled nodes"
        artifact = json.loads((root / 'target/run_results.json').read_text())
        assert len(artifact['results']) == (0 if expected == 'a,absent' else 1)
    assert observed['dxt'] == observed['core']


def test_core_disabled_only_unit_test_selection(tmp_path, duckdb_environment):
    observed = {}
    for engine in ['dxt', 'core']:
        root, database = fixture_project(tmp_path, engine, 'model')
        (root / 'models/unit.yml').write_text(
            'version: 2\nunit_tests:\n  - name: disabled_case\n    model: a\n'
            '    config: {enabled: false}\n    given: []\n    expect:\n      rows: [{id: 1}]\n'
        )
        result = run(engine, root, environment(duckdb_environment), 'test')
        manifest = empty_artifacts(root, 'test')
        assert 'unit_test.cli_fixture.a.disabled_case' in manifest['disabled']
        assert not database.exists()
        observed[engine] = warnings(result)
    assert observed['dxt'] == observed['core']


@pytest.mark.parametrize('command', ['run', 'compile'])
def test_core_empty_write_json_and_quiet_effects(tmp_path, duckdb_environment, command):
    for engine in ['dxt', 'core']:
        root, database = fixture_project(tmp_path, engine, 'missing')
        result = run(engine, root, environment(duckdb_environment), command,
                     ['--quiet', '--no-write-json', '--select=absent'])
        assert result.stdout == result.stderr == ''
        assert not (root / 'target/manifest.json').exists()
        assert not (root / 'target/run_results.json').exists()
        assert not database.exists()


@pytest.mark.parametrize('command', ['run', 'build', 'compile'])
def test_core_ephemeral_selection_is_work_without_materialization(tmp_path, duckdb_environment, command):
    observed = {}
    for engine in ['dxt', 'core']:
        root, database = fixture_project(tmp_path, engine, 'model')
        (root / 'dbt_project.yml').write_text("name: cli_fixture\nversion: '1.0'\nconfig-version: 2\nprofile: cli_fixture\n")
        (root / 'models/a.sql').write_text("{{ config(materialized='ephemeral') }} select 1 as id")
        result = run(engine, root, environment(duckdb_environment), command, ['--select=a'])
        assert warnings(result) == []
        artifact = json.loads((root / 'target/run_results.json').read_text())
        observed[engine] = [(row['unique_id'], row['status']) for row in artifact['results']]
        assert observed[engine] == ([('model.cli_fixture.a', 'success')] if command == 'compile' else [])
        assert artifact['elapsed_time'] > 0
        assert database.exists() == (command != 'compile')
        manifest = json.loads((root / 'target/manifest.json').read_text())
        assert manifest['nodes']['model.cli_fixture.a']['compiled'] is True
        assert (root / 'target/compiled/cli_fixture/models/a.sql').exists()
    assert observed['dxt'] == observed['core']


@pytest.mark.parametrize('command', COMMANDS)
def test_core_postgres_empty_task_does_not_connect(tmp_path, duckdb_environment, command):
    import select
    import socket
    from importlib.metadata import version
    assert version('dbt-postgres') == '1.9.1'
    observed = {}
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        for engine in ['dxt', 'core']:
            root, _ = fixture_project(tmp_path, engine, 'empty')
            (root / 'profiles.yml').write_text(
                'cli_fixture:\n  target: dev\n  outputs:\n    dev:\n'
                '      type: postgres\n      host: 127.0.0.1\n'
                f'      port: {listener.getsockname()[1]}\n'
                '      user: empty_probe\n      password: unused\n'
                '      dbname: empty_probe\n      schema: dev\n      threads: 4\n'
                '      connect_timeout: 1\n'
            )
            result = run(engine, root, environment(duckdb_environment), command)
            empty_artifacts(root, command)
            assert select.select([listener], [], [], 0)[0] == [], 'empty queue opened a PostgreSQL connection'
            observed[engine] = warnings(result)
    assert observed['dxt'] == observed['core']

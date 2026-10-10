"""Actual Core warning policy remains local to each CLI-shaped invocation."""
import subprocess
import sys

import pytest

from test_usability_commands import core_runner


DEPRECATION = 'MissingArgumentsPropertyInGenericTestDeprecation'


def project_at(path, deprecated=False):
    (path / 'models').mkdir(parents=True)
    (path / 'dbt_project.yml').write_text(
        "name: lifecycle\nversion: '1.0'\nprofile: lifecycle\n"
        'flags: {require_generic_test_arguments_property: true}\n'
    )
    (path / 'profiles.yml').write_text(
        'lifecycle:\n  target: dev\n  outputs:\n    dev:\n'
        f'      type: duckdb\n      path: {path / "warehouse.duckdb"}\n'
        '      threads: 1\n      keep_open: false\n'
    )
    (path / 'models/rendered.sql').write_text(
        "{{ config(materialized='view') }}select 1 as id"
    )
    (path / 'models/properties.yml').write_text(
        'version: 2\nmodels:\n  - name: rendered\n'
        '    config: {contract: {enforced: true}}\n    columns:\n'
        '      - name: id\n        data_type: integer\n'
        '        constraints: [{type: not_null, warn_unsupported: false}]\n'
        + ('        data_tests:\n          - accepted_values: {values: [1]}\n' if deprecated else '')
    )
    return path


def arguments(project, command='parse', strict=False):
    return [
        command, '--project-dir', str(project), '--profiles-dir', str(project),
        '--no-partial-parse', '--quiet', *(['--warn-error'] if strict else []),
    ]


@pytest.mark.parametrize('new_runner', [False, True])
def test_deprecations_do_not_leak_between_core_cli_invocations(tmp_path, core_runner, new_runner):
    from dbt.cli.main import dbtRunner
    from dbt.deprecations import active_deprecations, buffered_deprecations

    deprecated = project_at(tmp_path / 'deprecated', deprecated=True)
    clean = project_at(tmp_path / 'clean')
    warning_events = []
    core_runner.callbacks = [warning_events.append]
    for _ in range(2):
        warning_events.clear()
        result = core_runner.invoke(arguments(deprecated))
        assert result.success, result.exception
        assert [event.info.name for event in warning_events].count(DEPRECATION) == 1
        summaries = [event for event in warning_events if event.info.name == 'DeprecationsSummary']
        assert len(summaries) == 1
        assert [(row.event_name, row.occurrences) for row in summaries[0].data.summaries] == [(DEPRECATION, 1)]

    runner = dbtRunner() if new_runner else core_runner
    clean_events = []
    runner.callbacks = [clean_events.append]
    result = runner.invoke(arguments(clean, command='run', strict=True))
    assert result.success, result.exception
    assert not [event for event in clean_events if 'Deprecation' in event.info.name]
    assert all(event.info.invocation_id != warning_events[0].info.invocation_id for event in clean_events)

    # Isolation preserves errors authored in the current invocation.
    result = runner.invoke(arguments(deprecated, strict=True))
    assert result.success is False
    assert DEPRECATION in str(result.exception)
    assert not active_deprecations
    assert not buffered_deprecations


def test_failed_buffered_warning_does_not_poison_a_later_strict_command(tmp_path, core_runner):
    from dbt.deprecations import active_deprecations, buffered_deprecations

    clean = project_at(tmp_path / 'clean')
    result = core_runner.invoke([
        *arguments(clean), '--warn-error-options', '{"include": "all"}',
    ])
    assert result.success is False
    assert 'WEOIncludeExcludeDeprecation' in str(result.exception)
    assert not active_deprecations
    assert not buffered_deprecations
    result = core_runner.invoke(arguments(clean, strict=True))
    assert result.success, result.exception


@pytest.mark.parametrize('deprecated,returncode', [(False, 0), (True, 2)])
def test_fresh_core_cli_preserves_the_same_strict_warning_policy(tmp_path, core_runner, deprecated, returncode):
    project = project_at(tmp_path / 'cli', deprecated=deprecated)
    result = subprocess.run(
        [sys.executable, '-c', 'from dbt.cli.main import cli; cli()', *arguments(project, command='run', strict=True)],
        text=True, capture_output=True,
    )
    assert result.returncode == returncode, result.stdout + result.stderr
    if deprecated:
        assert DEPRECATION in result.stdout + result.stderr
    else:
        assert 'DeprecationsSummary' not in result.stdout + result.stderr

"""Mandatory Core command-context flag and environment precedence contracts."""
import json

import pytest

from test_cli import build_dxt  # noqa: F401
from test_usability_adapters import duckdb_environment  # noqa: F401
from test_usability_cli_options import environment, pinned_core  # noqa: F401
from test_usability_configuration import configuration_postgres  # noqa: F401
from test_usability_sql_operations import command, events, project


COMMANDS = [
    ('parse', [], [False, False, None, True]),
    ('ls', ['-s', 'a'], [False, False, None, True]),
    ('compile', ['-s', 'a'], [True, False, True, False]),
    ('run', ['-s', 'a'], [True, False, True, True]),
    ('build', ['-s', 'a'], [True, True, True, True]),
    ('seed', [], [True, False, None, True]),
    ('test', [], [False, True, None, True]),
    ('snapshot', [], [False, False, True, True]),
    ('docs', ['generate', '--empty-catalog'], [False, False, None, True]),
    ('show', ['--inline', 'select 1 as id', '--introspect'], [True, False, None, True]),
    ('run-operation', ['flag_probe'], [False, False, None, True]),
]
VALUES = '[flags.FULL_REFRESH, flags.STORE_FAILURES, flags.EMPTY, flags.INTROSPECT]'
PROJECTION = "{{ config(meta={'flag_contract': " + VALUES + "}) }}"


@pytest.mark.parametrize('which,flags,expected', COMMANDS)
def test_core_command_flags_have_command_nulls_and_real_environment_values(tmp_path, request, duckdb_environment, which, flags, expected):
    observed = {}
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, 'duckdb', request)
        (root / 'models/a.sql').write_text(PROJECTION + "{{ config(materialized='table') }}select 8 as id")
        (root / 'macros/flag_probe.sql').write_text("{% macro flag_probe() %}{{ log('flag_contract=' ~ tojson(" + VALUES + "), info=true) }}{% endmacro %}")
        result = command(engine, root, environment(duckdb_environment, DBT_FULL_REFRESH='true', DBT_STORE_FAILURES='true', DBT_EMPTY='true', DBT_INTROSPECT='false'), which, flags, quiet=False)
        manifest = json.loads((root / 'target/manifest.json').read_text())
        observed[engine] = manifest['nodes']['model.preview.a']['config']['meta']['flag_contract']
        assert observed[engine] == expected
        if which == 'run-operation':
            messages = [row['data']['msg'] for row in events(result, 'JinjaLogInfo') if row['data']['msg'].startswith('flag_contract=')]
            assert [json.loads(message.removeprefix('flag_contract=')) for message in messages] == [expected]
    assert observed['dxt'] == observed['core']


@pytest.mark.parametrize('flag', ['--full-refresh', '-f'])
def test_core_show_full_refresh_alias_overrides_environment_in_macro_context(tmp_path, request, duckdb_environment, flag):
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, 'duckdb', request)
        result = command(engine, root, environment(duckdb_environment, DBT_FULL_REFRESH='false'), 'show', ['--inline', "select '{{ flags.FULL_REFRESH }}' as refresh", flag, '--output', 'json'])
        shown, = events(result, 'ShowNode')
        assert json.loads(shown['data']['preview']) == [{'refresh': 'True'}]
        artifact = json.loads((root / 'target/run_results.json').read_text())
        assert artifact['args']['full_refresh'] is True


@pytest.mark.parametrize('which', ['snapshot', 'test', 'parse'])
def test_core_command_placements_reject_full_refresh_when_flag_is_absent(tmp_path, request, duckdb_environment, which):
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, 'duckdb', request)
        result = command(engine, root, environment(duckdb_environment), which, ['--full-refresh'], ok=False)
        assert result.returncode == 2
        assert not (root / 'target/manifest.json').exists()


def test_core_regular_incremental_offline_compilation_connects_only_for_authored_helper(tmp_path, request, duckdb_environment):
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, 'postgres', request)
        p = root / 'profiles.yml'
        p.write_text(p.read_text().replace('port: ', 'port: 65530 # '))
        env = environment(duckdb_environment)
        (root / 'models/a.sql').write_text("{{ config(materialized='incremental') }}select 8 as id")
        command(engine, root, env, 'compile', ['-s', 'a', '--no-populate-cache'])
        prior = (root / 'target/run_results.json').read_bytes()
        (root / 'models/a.sql').write_text("{{ config(materialized='incremental') }}select '{{ is_incremental() }}' as state")
        failure = command(engine, root, env, 'compile', ['-s', 'a', '--no-populate-cache'], ok=False)
        assert failure.returncode == 2
        assert (root / 'target/run_results.json').read_bytes() == prior


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_no_introspect_allows_plain_compile_and_rejects_sql_callbacks_and_preview(tmp_path, request, duckdb_environment, adapter):
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, adapter, request)
        env = environment(duckdb_environment)
        flags = ['--no-populate-cache', '--no-introspect']
        command(engine, root, env, 'compile', ['-s', 'a', *flags])
        prior = (root / 'target/run_results.json').read_bytes()
        if adapter == 'duckdb':
            assert not (root / 'warehouse.duckdb').exists()
        (root / 'models/a.sql').write_text("{% if execute %}{% set rows = run_query('select 19 as n') %}select {{ rows.rows[0][0] }} as n{% else %}select 1 as n{% endif %}")
        result = command(engine, root, env, 'compile', ['-s', 'a', *flags], ok=False)
        assert result.returncode == 2
        assert (root / 'target/run_results.json').read_bytes() == prior
        (root / 'models/a.sql').write_text('select 1 as id')
        result = command(engine, root, env, 'show', ['--inline', 'select 1 as id', *flags], ok=False)
        assert result.returncode == 2
        assert (root / 'target/run_results.json').read_bytes() == prior
        if adapter == 'duckdb':
            assert not (root / 'warehouse.duckdb').exists()


def test_core_direct_preview_acquires_its_connection_with_no_introspect(tmp_path, request, duckdb_environment):
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, 'duckdb', request)
        result = command(engine, root, environment(duckdb_environment), 'show', ['--inline-direct', 'select 12 as n', '--no-introspect', '--output', 'json'])
        shown, = events(result, 'ShowNode')
        assert json.loads(shown['data']['preview']) == [{'n': 12}]
        assert not (root / 'target/manifest.json').exists()

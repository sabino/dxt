"""Core's deprecated root profile behavior configuration and conflict policy."""
import json
from datetime import datetime

import pytest

from test_cli import build_dxt  # noqa: F401
from test_usability_adapters import duckdb_environment  # noqa: F401
from test_usability_cli_options import environment, pinned_core  # noqa: F401
from test_usability_configuration import configuration_postgres  # noqa: F401
from test_usability_microbatch import DUCKDB_STRATEGY, EVENTS, INPUT
from test_usability_sql_operations import command, events, project, warehouse_rows

FLAGS = dict.fromkeys(['require_generic_test_arguments_property', 'enable_truthy_nulls_equals_macro', 'validate_macro_args', 'require_batched_execution_for_custom_microbatch_strategy'], True)


def profile_config(root, config):
    path = root / 'profiles.yml'
    path.write_text(path.read_text() + 'config: ' + json.dumps(config) + '\n')


def macro(root):
    (root / 'macros/profile_probe.sql').write_text('{% macro profile_probe(first, second=1) %}{{ return(first) }}{% endmacro %}')


def arguments(root):
    return json.loads((root / 'target/manifest.json').read_text())['macros']['macro.preview.profile_probe']['arguments']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_profile_behavior_flags_drive_generic_arguments_macro_metadata_nulls_and_microbatches(tmp_path, request, duckdb_environment, adapter):
    observed = {}
    for engine in ['dxt', 'core']:
        root, schema = project(tmp_path, engine, adapter, request)
        profile_config(root, FLAGS)
        macro(root)
        (root / 'models/a.sql').write_text("{{ config(materialized='table') }}select 1 as id,{{ equals('null','null') }} as same")
        (root / 'models/schema.yml').write_text('version: 2\nmodels:\n  - name: a\n    data_tests:\n      - not_null:\n          arguments: {column_name: id}\n')
        (root / 'models/input.sql').write_text(INPUT)
        (root / 'models/events.sql').write_text(EVENTS)
        (root / 'macros/microbatch.sql').write_text(DUCKDB_STRATEGY)
        env = environment(duckdb_environment)
        command(engine, root, env, 'parse')
        assert [arg['name'] for arg in arguments(root)] == ['first', 'second']
        command(engine, root, env, 'compile', ['-s', 'a', '--no-populate-cache'])
        manifest = json.loads((root / 'target/manifest.json').read_text())
        sql = manifest['nodes']['model.preview.a']['compiled_code']
        test, = [node for node in manifest['nodes'].values() if node['resource_type'] == 'test']
        assert test['test_metadata']['kwargs']['column_name'] == 'id'
        command(engine, root, env, 'run', ['-s', 'a input'])
        assert warehouse_rows(root, adapter, request, f'select id,same from "{schema}"."a"') == [(1, None)]
        result = command(engine, root, env, 'run', ['-s', 'events', '--event-time-start', '2024-01-01', '--event-time-end', '2024-01-03'], ok=False)
        assert result.returncode == (1 if adapter == 'duckdb' else 0), result.stdout + result.stderr
        artifact = json.loads((root / 'target/run_results.json').read_text())
        row, = artifact['results']
        successful = [[datetime.fromisoformat(start), datetime.fromisoformat(end)] for start,end in row['batch_results']['successful']]
        failed = [[datetime.fromisoformat(start), datetime.fromisoformat(end)] for start,end in row['batch_results']['failed']]
        assert len(successful) == (1 if adapter == 'duckdb' else 2)
        assert len(failed) == (1 if adapter == 'duckdb' else 0)
        assert row['status'] == ('partial success' if adapter == 'duckdb' else 'success')
        rows = warehouse_rows(root, adapter, request, f'select id,amount from "{schema}"."events" order by id')
        assert rows == ([(1,10)] if adapter == 'duckdb' else [(1,10),(2,20)])
        observed[engine] = (arguments(root), sql, test['test_metadata'], successful, failed, rows)
    assert observed['dxt'] == observed['core']


def test_core_empty_project_flags_allow_profile_fallback(tmp_path, request, duckdb_environment):
    observed = {}
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, 'duckdb', request)
        (root / 'dbt_project.yml').write_text((root / 'dbt_project.yml').read_text() + 'flags: {}\n')
        profile_config(root, {'validate_macro_args': True})
        macro(root)
        command(engine, root, environment(duckdb_environment), 'parse')
        observed[engine] = arguments(root)
        assert [arg['name'] for arg in observed[engine]] == ['first','second']
    assert observed['dxt'] == observed['core']


def test_core_null_project_flags_are_invalid_even_with_profile_fallback(tmp_path, request, duckdb_environment):
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, 'duckdb', request)
        (root / 'dbt_project.yml').write_text((root / 'dbt_project.yml').read_text() + 'flags: null\n')
        profile_config(root, {'validate_macro_args': True})
        result = command(engine, root, environment(duckdb_environment), 'parse', ok=False)
        assert result.returncode == 2, result.stdout + result.stderr
        assert not (root / 'target/manifest.json').exists()


def test_core_nonempty_project_and_profile_flags_conflict_before_artifacts(tmp_path, request, duckdb_environment):
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, 'duckdb', request)
        (root / 'dbt_project.yml').write_text((root / 'dbt_project.yml').read_text() + 'flags: {validate_macro_args: false}\n')
        profile_config(root, {'require_generic_test_arguments_property': True})
        result = command(engine, root, environment(duckdb_environment), 'parse', ok=False)
        assert result.returncode == 2 and 'Do not specify both' in result.stdout + result.stderr
        assert not (root / 'target/manifest.json').exists()


def test_core_invalid_profile_behavior_value_discards_complete_override(tmp_path, request, duckdb_environment):
    observed = {}
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, 'duckdb', request)
        profile_config(root, dict(FLAGS, validate_macro_args='true'))
        macro(root)
        (root / 'models/a.sql').write_text("select {{ equals('null','null') }} as same")
        command(engine, root, environment(duckdb_environment), 'compile', ['-s', 'a', '--no-populate-cache'])
        assert arguments(root) == []
        node = json.loads((root / 'target/manifest.json').read_text())['nodes']['model.preview.a']
        assert '(null = null)' in node['compiled_code']
        observed[engine] = node['compiled_code']
    assert observed['dxt'] == observed['core']


@pytest.mark.parametrize('policy', ['default','error','silence'])
def test_core_profile_config_deprecation_has_warning_policy(tmp_path, request, duckdb_environment, policy):
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, 'duckdb', request)
        profile_config(root, {'validate_macro_args': True})
        flags = ['--warn-error'] if policy == 'error' else ['--warn-error-options', '{"silence":["ProjectFlagsMovedDeprecation"]}'] if policy == 'silence' else []
        result = command(engine, root, environment(duckdb_environment), 'parse', flags, ok=False, quiet=False)
        assert result.returncode == (2 if policy == 'error' else 0), result.stdout + result.stderr
        warnings = events(result, 'ProjectFlagsMovedDeprecation')
        assert len(warnings) == (1 if policy == 'default' else 0)
        if warnings:
            assert warnings[0]['info']['code'] == 'D013' and warnings[0]['info']['level'] == 'warn'
        assert (root / 'target/manifest.json').exists() == (policy != 'error')

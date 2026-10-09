"""Core flag normalization plus actual native metadata population controls."""
import json
import pytest
from test_cli import build_dxt  # noqa: F401
from test_usability_adapters import duckdb_environment  # noqa: F401
from test_usability_cli_options import environment, invoke, pinned_core, project  # noqa: F401


def records(result):
    return [json.loads(line) for text in [result.stdout, result.stderr]
            for line in text.splitlines() if line.startswith('{')]


@pytest.mark.parametrize('policy,populate,selected_only', [
    ([], True, False),
    (['--cache-selected-only'], True, True),
    (['--no-populate-cache'], False, False),
])
def test_core_actual_cache_population_and_selected_schema_controls(tmp_path, duckdb_environment, policy, populate, selected_only):
    observed = {}
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path / engine)
        (root / 'models/a.sql').write_text(
            "{{ config(materialized='table') }}\n"
            "{% if execute %}{{ log('CACHE_FLAGS|' ~ flags.CACHE_SELECTED_ONLY ~ '|' ~ flags.LOG_CACHE_EVENTS, info=true) }}{% endif %}\n"
            'select 7 as id\n'
        )
        (root / 'models/b.sql').write_text("{{ config(schema='other') }} select 8 as id\n")
        result = invoke(engine, ['--debug', '--no-use-colors', '--log-format=json',
                                '--log-cache-events', *policy, 'run',
                                '--project-dir', root, '--profiles-dir', root, '-s', 'a'],
                        root, environment(duckdb_environment))
        rows = records(result)
        artifact = json.loads((root / 'target/run_results.json').read_text())
        args = artifact['args']
        observed[engine] = {key: args[key] for key in ['populate_cache', 'cache_selected_only', 'log_cache_events']}
        assert observed[engine] == dict(populate_cache=populate, cache_selected_only=selected_only, log_cache_events=True)
        messages = [row['data']['msg'] for row in rows if row['info']['name'] == 'JinjaLogInfo']
        assert messages == [f'CACHE_FLAGS|{selected_only}|True']
        if engine == 'dxt':
            events = [row for row in rows if row['info']['name'] == 'CacheAction']
            assert events, result.stdout + result.stderr
            queries = max(row['data']['cache']['warm_queries'] for row in events)
            assert (queries > 0) == populate
            first_population = [row for row in events if row['data']['action'] == 'populate']
            if populate:
                # The preparation session opens with one query per requested
                # physical schema, before selected resource DDL can invalidate.
                assert first_population[0]['data']['cache']['warm_queries'] == 1
                first_ddl = next(index for index, row in enumerate(events) if row['data']['action'] == 'invalidate')
                initial_queries = [row for row in events[:first_ddl] if row['data']['action'] == 'populate']
                assert len(initial_queries) == (1 if selected_only else 2)
        else:
            schema_queries = [row for row in rows if row['info']['name'] == 'SQLQuery'
                              and row['data'].get('conn_name', '').startswith('list_')
                              and 'information_schema.tables' in row['data'].get('sql', '')]
            assert len(schema_queries) == (0 if not populate else 1 if selected_only else 2), schema_queries
    assert observed['dxt'] == observed['core']


def test_core_cache_environment_and_explicit_flag_precedence(tmp_path, duckdb_environment):
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path / engine)
        (root / 'macros').mkdir()
        (root / 'macros/flags.sql').write_text(
            "{% macro inspect_cache() %}{{ print('CACHE_FLAGS|' ~ flags.CACHE_SELECTED_ONLY ~ '|' ~ flags.LOG_CACHE_EVENTS ~ '|' ~ (flags.POPULATE_CACHE is defined)) }}{% endmacro %}"
        )
        env = environment(duckdb_environment, DBT_POPULATE_CACHE='false', DBT_CACHE_SELECTED_ONLY='true', DBT_LOG_CACHE_EVENTS='true')
        common = ['run-operation', 'inspect_cache', '--project-dir', root, '--profiles-dir', root]
        first = invoke(engine, ['-q', *common], root, env)
        assert first.stdout.strip() == 'CACHE_FLAGS|True|True|False', first.stdout + first.stderr
        second = invoke(engine, ['-q', '--populate-cache', '--no-cache-selected-only', '--no-log-cache-events', *common], root, env)
        assert second.stdout.strip() == 'CACHE_FLAGS|False|False|False', second.stdout + second.stderr
        duplicate = invoke(engine, ['--populate-cache', *common, '--no-populate-cache'], root, env, ok=False)
        assert duplicate.returncode == 2

"""Mandatory pinned Core SQL-operation/preview oracles on both native adapters."""
import json
from pathlib import Path
from urllib.parse import unquote, urlparse

import pytest

from test_cli import build_dxt  # noqa: F401
from test_usability_adapters import duckdb_environment  # noqa: F401
from test_usability_cli_options import environment, invoke, pinned_core  # noqa: F401
from test_usability_configuration import configuration_postgres  # noqa: F401


def project(base, engine, adapter, request):
    root = base / engine
    for folder in ['models', 'seeds', 'analyses', 'macros', 'tests']:
        (root / folder).mkdir(parents=True)
    (root / 'dbt_project.yml').write_text("name: preview\nversion: '1.0'\nconfig-version: 2\nprofile: preview\n")
    (root / 'models/a.sql').write_text("{{ config(materialized='table') }}select 8 as id")
    (root / 'models/e.sql').write_text("{{ config(materialized='ephemeral') }}select * from (values (1), (2), (3), (4), (5), (6)) as rows(id)")
    (root / 'models/b.sql').write_text("select * from {{ ref('e') }}")
    schema = 'dev'
    if adapter == 'duckdb':
        profile = f"type: duckdb\n      path: '{root / 'warehouse.duckdb'}'\n      schema: {schema}\n      threads: 2\n"
    else:
        from importlib.metadata import version
        assert version('dbt-postgres') == '1.9.1'
        server = request.getfixturevalue('configuration_postgres')
        info = server.get_postmaster_info()
        user = unquote(urlparse(server.get_uri()).username or 'postgres')
        schema = 'preview_' + engine + '_' + ''.join(c for c in base.name if c.isalnum())[-24:]
        profile = f"type: postgres\n      host: {json.dumps(str(info.socket_dir))}\n      port: {info.port}\n      dbname: postgres\n      user: {user}\n      password: ''\n      schema: {schema}\n      threads: 2\n"
    (root / 'profiles.yml').write_text('preview:\n  target: dev\n  outputs:\n    dev:\n      ' + profile)
    return root, schema


def command(engine, root, env, which, flags=(), *, ok=True, json_logs=True, quiet=True):
    args = ['--no-use-colors'] + (['--log-format=json'] if json_logs else []) + (['--quiet'] if quiet else [])
    subcommand = [flags[0]] if which in ['docs', 'source'] else []
    remaining = flags[1:] if subcommand else flags
    return invoke(engine, [*args, which, *subcommand, '--project-dir', root, '--profiles-dir', root, *remaining], root, env, ok=ok)


def events(result, name):
    return [row for text in [result.stdout, result.stderr] for line in text.splitlines()
            if line.startswith('{') and (row := json.loads(line))['info']['name'] == name]


def artifacts(root):
    manifest = json.loads((root / 'target/manifest.json').read_text())
    result = json.loads((root / 'target/run_results.json').read_text())
    return manifest, result


def warehouse_rows(root, adapter, request, sql):
    if adapter == 'duckdb':
        import duckdb
        with duckdb.connect(str(root / 'warehouse.duckdb')) as connection:
            return connection.execute(sql).fetchall()
    import psycopg2
    with psycopg2.connect(request.getfixturevalue('configuration_postgres').get_uri()) as connection:
        with connection.cursor() as cursor:
            cursor.execute(sql)
            return cursor.fetchall()


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('limit', [5, 0, -1])
def test_core_show_inline_ephemeral_sql_limits_artifacts_and_no_materialization(tmp_path, request, duckdb_environment, adapter, limit):
    observed = {}
    for engine in ['dxt', 'core']:
        root, schema = project(tmp_path, engine, adapter, request)
        sql = "select * from {{ ref('e') }} order by id"
        result = command(engine, root, environment(duckdb_environment), 'show', ['--inline', sql, '--output', 'json', '--limit', limit])
        shown, = events(result, 'ShowNode')
        manifest, artifact = artifacts(root)
        row, = artifact['results']
        assert shown['data']['unique_id'] == row['unique_id'] == 'sql_operation.preview.inline_query'
        assert shown['data']['quiet'] is shown['data']['is_inline'] is True
        assert not any(key.startswith('sql_operation.') for key in manifest['nodes'])
        assert manifest['nodes']['model.preview.e']['compiled'] is True
        assert (root / 'target/compiled/preview/models/e.sql').read_text() == manifest['nodes']['model.preview.e']['compiled_code']
        assert row['compiled'] is True and row['status'] == 'success' and row['relation_name'] is None
        assert artifact['args']['inline'] == sql and artifact['args']['limit'] == limit
        assert artifact['args']['output'] == 'json'
        assert warehouse_rows(root, adapter, request, f"select count(*) from information_schema.tables where table_schema='{schema}'") == [(0,)]
        observed[engine] = (json.loads(shown['data']['preview']), row['compiled_code'], row['adapter_response'],
                            (root / 'target/compiled/preview/from remote system.sql/sql/inline_query').read_text())
    assert observed['dxt'] == observed['core']
    assert observed['dxt'][0] == [{'id': i} for i in range(1, (7 if limit < 0 else limit + 1))]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_compile_inline_preserves_authored_padding_and_removes_temporary_node(tmp_path, request, duckdb_environment, adapter):
    observed = {}
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, adapter, request)
        sql = ' \nselect {{ var("answer", 9) }} as id\n '
        result = command(engine, root, environment(duckdb_environment), 'compile', ['--inline', sql, '--output', 'json'])
        event, = events(result, 'CompiledNode')
        manifest, artifact = artifacts(root)
        row, = artifact['results']
        assert not any('inline_query' in key for key in manifest['nodes'])
        assert row['unique_id'] == 'sql_operation.preview.inline_query'
        assert row['adapter_response'] == {} and row['relation_name'] is None
        assert artifact['args']['inject_ephemeral_ctes'] is True and artifact['args']['introspect'] is True
        observed[engine] = (event['data'], row['compiled_code'], (root / 'target/compiled/preview/from remote system.sql/sql/inline_query').read_text())
    assert observed['dxt'] == observed['core']
    assert observed['dxt'][1] == ' \nselect 9 as id\n '


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_show_typed_table_formatting_numbers_nulls_wide_columns_and_unicode(tmp_path, request, duckdb_environment, adapter):
    observed = {}
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, adapter, request)
        (root / 'analyses/x.sql').write_text("select true as active, null::varchar as blank, 1234.50::decimal(8,2) as amount, 12.3455::decimal(8,4) as rounded, '東京abcdefghijklmnopqrstu' as label, 1234 as integer_column, 'extra' as hidden_column")
        result = command(engine, root, environment(duckdb_environment), 'show', ['-s', 'x'])
        event, = events(result, 'ShowNode')
        manifest, artifact = artifacts(root)
        assert artifact['results'][0]['relation_name'] is None
        assert manifest['nodes']['analysis.preview.x']['compiled_code'] == artifact['results'][0]['compiled_code']
        observed[engine] = event['data']['preview']
    assert observed['dxt'] == observed['core']
    assert '1,234.5' in observed['dxt'] and '12.346…' in observed['dxt'] and '東京abcdefghijklmno...' in observed['dxt']
    assert 'hidden_column' not in observed['dxt']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_seed_show_uses_csv_values_ignores_query_limit_and_executes_hooks(tmp_path, request, duckdb_environment, adapter):
    observed = {}
    for engine in ['dxt', 'core']:
        root, schema = project(tmp_path, engine, adapter, request)
        env = environment(duckdb_environment)
        command(engine, root, env, 'run', ['-s', 'a'])
        (root / 'seeds/s.csv').write_text('id,label\n1,Ada\n2,Bob\n')
        with (root / 'dbt_project.yml').open('a') as file:
            file.write("seeds:\n  preview:\n    +column_types: {id: varchar}\n    +post-hook: \"{% do adapter.drop_relation(this.incorporate(type='table')) %}\"\n")
        result = command(engine, root, env, 'show', ['-s', 's', '--limit', '0', '--output', 'json'])
        shown, = events(result, 'ShowNode')
        _, artifact = artifacts(root)
        row, = artifact['results']
        assert row['unique_id'] == 'seed.preview.s' and row['compiled_code'] is None
        assert warehouse_rows(root, adapter, request, f"select count(*) from information_schema.tables where table_schema='{schema}' and table_name='s'") == [(0,)]
        observed[engine] = json.loads(shown['data']['preview'])
    assert observed['dxt'] == observed['core'] == [{'id': '1', 'label': 'Ada'}, {'id': '2', 'label': 'Bob'}]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('limit', [0, 2, -1])
def test_core_direct_show_bypasses_project_sql_parsing_and_artifact_writes(tmp_path, request, duckdb_environment, adapter, limit):
    observed = {}
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, adapter, request)
        (root / 'models/a.sql').write_text('{% unsupported broken project syntax %}')
        result = command(engine, root, environment(duckdb_environment), 'show', ['--inline-direct', 'select * from (values (1), (2), (3)) as rows(id)', '--limit', limit, '--output', 'json'])
        shown, = events(result, 'ShowNode')
        assert shown['data']['unique_id'] == 'direct-query'
        assert not (root / 'target/manifest.json').exists() and not (root / 'target/run_results.json').exists()
        observed[engine] = shown['data']
    assert observed['dxt'] == observed['core']
    assert json.loads(observed['dxt']['preview']) == [{'id': i} for i in range(1, 3 if limit == 2 else 4)]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_show_readiness_and_errors_preserve_previous_run_results(tmp_path, request, duckdb_environment, adapter):
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, adapter, request)
        env = environment(duckdb_environment)
        missing = command(engine, root, env, 'show', ok=False)
        assert missing.returncode == 2 and 'Either --select or --inline' in missing.stdout + missing.stderr
        assert not (root / 'target/run_results.json').exists()
        command(engine, root, env, 'compile', ['--inline', 'select 1 as id'])
        previous = (root / 'target/run_results.json').read_bytes()
        failed = command(engine, root, env, 'show', ['--inline', 'select missing_column'], ok=False)
        assert failed.returncode == 2 and 'missing_column' in failed.stdout + failed.stderr
        assert (root / 'target/run_results.json').read_bytes() == previous
        unresolved = command(engine, root, env, 'compile', ['--inline', "select * from {{ ref('not_found') }}"], ok=False)
        assert unresolved.returncode == 2
        assert (root / 'target/run_results.json').read_bytes() == previous
        assert not any('inline_query' in key for key in json.loads((root / 'target/manifest.json').read_text())['nodes'])


def test_core_introspect_environment_and_ephemeral_injection_controls(tmp_path, request, duckdb_environment):
    observed = {}
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, 'duckdb', request)
        env = environment(duckdb_environment, DBT_INTROSPECT='true')
        (root / 'models/i.sql').write_text("{% if execute and flags.INTROSPECT %}{% set values = run_query('select 11 as n') %}select {{ values.rows[0][0] }} as n{% else %}select 22 as n{% endif %}")
        disabled = command(engine, root, env, 'compile', ['-s', 'i', '--no-introspect', '--output', 'json'])
        compiled, = events(disabled, 'CompiledNode')
        assert compiled['data']['compiled'] == 'select 22 as n'
        _, artifact = artifacts(root)
        assert artifact['args']['introspect'] is False
        enabled = command(engine, root, env, 'compile', ['-s', 'i', '--output', 'json'])
        compiled, = events(enabled, 'CompiledNode')
        assert compiled['data']['compiled'] == 'select 11 as n'
        command(engine, root, env, 'compile', ['-s', 'b', '--no-inject-ephemeral-ctes'])
        manifest, artifact = artifacts(root)
        node = manifest['nodes']['model.preview.b']
        observed[engine] = (node['compiled_code'], node['extra_ctes'], node['extra_ctes_injected'], artifact['args']['inject_ephemeral_ctes'])
    assert observed['dxt'] == observed['core'] == ('select * from __dbt__cte__e', [{'id': 'model.preview.e', 'sql': None}], False, False)


@pytest.mark.parametrize('json_logs', [False, True])
def test_core_quiet_compile_and_show_output_policy(tmp_path, request, duckdb_environment, json_logs):
    observed = {}
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, 'duckdb', request)
        for which in ['compile', 'show']:
            result = command(engine, root, environment(duckdb_environment), which, ['--inline', 'select 2 as id', '--output', 'json'], json_logs=json_logs)
            if json_logs:
                event, = events(result, 'ShowNode' if which == 'show' else 'CompiledNode')
                output = json.loads(event['info']['msg'])
            else:
                output = json.loads(result.stdout)
            observed[(engine, which)] = output
            assert result.stderr == ''
    assert observed[('dxt', 'compile')] == observed[('core', 'compile')] == {'compiled': 'select 2 as id'}
    assert observed[('dxt', 'show')] == observed[('core', 'show')] == {'show': [{'id': 2}]}


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_show_json_dates_numeric_strings_and_duplicate_columns(tmp_path, request, duckdb_environment, adapter):
    observed = {}
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, adapter, request)
        sql = "select date '2024-01-02' as day, timestamp '2024-01-02 03:04:05.12' as moment, timestamptz '2024-01-02 03:04:05.000001+00' as instant, 1.2e10::double precision as number, '12.50' as numeric_text, 1 as id, 2 as id"
        result = command(engine, root, environment(duckdb_environment), 'show', ['--inline', sql, '--output', 'JSON'])
        shown, = events(result, 'ShowNode')
        observed[engine] = json.loads(shown['data']['preview'])
    assert observed['dxt'] == observed['core'] == [{'day': '2024-01-02', 'moment': '2024-01-02T03:04:05.120000', 'instant': '2024-01-02T03:04:05.000001+00:00', 'number': 12000000000.0, 'numeric_text': '12.50', 'id': 1, 'id_2': 2}]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_show_seed_requires_schema_and_preserves_existing_artifact(tmp_path, request, duckdb_environment, adapter):
    for engine in ['dxt', 'core']:
        root, schema = project(tmp_path, engine, adapter, request)
        env = environment(duckdb_environment)
        command(engine, root, env, 'compile', ['--inline', 'select 1 as id'])
        previous = (root / 'target/run_results.json').read_bytes()
        (root / 'seeds/s.csv').write_text('id\n1\n')
        failed = command(engine, root, env, 'show', ['-s', 's'], ok=False)
        assert failed.returncode == 2 and schema in failed.stdout + failed.stderr
        assert (root / 'target/run_results.json').read_bytes() == previous
        assert warehouse_rows(root, adapter, request, f"select count(*) from information_schema.schemata where schema_name='{schema}'") == [(0,)]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_show_no_write_json_still_writes_compiled_sql(tmp_path, request, duckdb_environment, adapter):
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, adapter, request)
        result = command(engine, root, environment(duckdb_environment), 'show', ['--inline', 'select 3 as id', '--output', 'json', '--no-write-json'])
        shown, = events(result, 'ShowNode')
        assert json.loads(shown['data']['preview']) == [{'id': 3}]
        assert not (root / 'target/manifest.json').exists() and not (root / 'target/run_results.json').exists()
        assert (root / 'target/compiled/preview/from remote system.sql/sql/inline_query').read_text() == 'select 3 as id'


def test_core_compile_cache_readiness_and_offline_override(tmp_path, request, duckdb_environment):
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, 'postgres', request)
        p = root / 'profiles.yml'
        p.write_text(p.read_text().replace('port: ', 'port: 65530 # '))
        env = environment(duckdb_environment)
        failed = command(engine, root, env, 'compile', ['-s', 'a'], ok=False)
        assert failed.returncode == 2
        assert not (root / 'target/run_results.json').exists()
        success = command(engine, root, env, 'compile', ['-s', 'a', '--no-populate-cache'])
        compiled, = events(success, 'CompiledNode')
        assert compiled['data']['compiled'] == 'select 8 as id'


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_compile_nested_ephemeral_ctes_preserve_with_comments_and_semicolons(tmp_path, request, duckdb_environment, adapter):
    observed = {}
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, adapter, request)
        (root / 'models/e.sql').write_text("{{ config(materialized='ephemeral') }}select 1 as id;")
        (root / 'models/m.sql').write_text("{{ config(materialized='ephemeral') }}WITH recursive local_cte as (select * from {{ ref('e') }}) select * from local_cte")
        result = command(engine, root, environment(duckdb_environment), 'compile', ['--inline', "-- initial = comment\nWITH current_rows as (select * from {{ ref('m') }}) select * from current_rows", '--output', 'json'])
        compiled, = events(result, 'CompiledNode')
        manifest, artifact = artifacts(root)
        observed[engine] = (compiled['data']['compiled'], artifact['results'][0]['compiled_code'],
                            [(manifest['nodes'][f'model.preview.{name}']['compiled_code'], manifest['nodes'][f'model.preview.{name}']['extra_ctes'], (root / f'target/compiled/preview/models/{name}.sql').read_text()) for name in ['e', 'm']])
    assert observed['dxt'] == observed['core']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_custom_preview_macro_and_inline_project_config(tmp_path, request, duckdb_environment, adapter):
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, adapter, request)
        with (root / 'dbt_project.yml').open('a') as file:
            file.write("models:\n  preview:\n    +enabled: false\n    sql:\n      +sql_header: '-- authored header'\n")
        (root / 'macros/show.sql').write_text("{% macro get_show_sql(compiled_code, sql_header, limit) %}{% if sql_header != '-- authored header' %}{{ exceptions.raise_compiler_error('inline project configuration missing') }}{% endif %}{{ sql_header }}\nselect * from ({{ compiled_code }}) as preview_rows where id >= 2{% endmacro %}")
        result = command(engine, root, environment(duckdb_environment), 'show', ['--inline', 'select * from (values (1), (2), (3)) as rows(id)', '--limit', '0', '--output', 'json'])
        shown, = events(result, 'ShowNode')
        assert json.loads(shown['data']['preview']) == [{'id': 2}, {'id': 3}]
        manifest, artifact = artifacts(root)
        assert artifact['results'][0]['compiled_code'].startswith('-- authored header\n')
        assert not any('inline_query' in key for key in manifest['nodes'])


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('which', ['compile', 'docs'])
def test_core_compile_failures_preserve_previous_success_artifacts(tmp_path, request, duckdb_environment, adapter, which):
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, adapter, request)
        env = environment(duckdb_environment)
        command(engine, root, env, 'docs', ['generate', '--empty-catalog'])
        prior_results = (root / 'target/run_results.json').read_bytes()
        prior_catalog = (root / 'target/catalog.json').read_bytes()
        prior_manifest = (root / 'target/manifest.json').read_bytes()
        sql = "{% if execute %}{{ exceptions.raise_compiler_error('authored compile failure') }}{% endif %}select 8 as id"
        (root / 'models/a.sql').write_text(sql)
        flags = ['-s', 'a'] if which == 'compile' else ['generate', '-s', 'a', '--empty-catalog']
        failed = command(engine, root, env, which, flags, ok=False)
        assert failed.returncode == 2 and 'authored compile failure' in failed.stdout + failed.stderr
        assert (root / 'target/run_results.json').read_bytes() == prior_results
        assert (root / 'target/catalog.json').read_bytes() == prior_catalog
        current_manifest = (root / 'target/manifest.json').read_bytes()
        if which == 'docs':
            assert current_manifest == prior_manifest
        else:
            assert json.loads(current_manifest)['nodes']['model.preview.a']['raw_code'] == sql


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_parse_compilation_errors_use_exit_two(tmp_path, request, duckdb_environment, adapter):
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, adapter, request)
        (root / 'models/a.sql').write_text("{{ exceptions.raise_compiler_error('authored parse failure') }}select 1")
        failed = command(engine, root, environment(duckdb_environment), 'parse', ok=False)
        assert failed.returncode == 2 and 'authored parse failure' in failed.stdout + failed.stderr
        assert not (root / 'target/manifest.json').exists() and not (root / 'target/run_results.json').exists()


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_parse_missing_var_is_deferred_to_execution(tmp_path, request, duckdb_environment, adapter):
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, adapter, request)
        (root / 'models/a.sql').write_text("select '{{ var('required_missing_var') }}' as missing")
        command(engine, root, environment(duckdb_environment), 'parse')
        manifest = json.loads((root / 'target/manifest.json').read_text())
        assert manifest['nodes']['model.preview.a']['refs'] == []
        failed = command(engine, root, environment(duckdb_environment), 'compile', ['-s', 'a'], ok=False)
        assert failed.returncode == 2 and 'required_missing_var' in failed.stdout + failed.stderr
        assert not (root / 'target/run_results.json').exists()


def test_core_duckdb_timestamp_zone_dst_transport(tmp_path, request, duckdb_environment):
    observed = {}
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, 'duckdb', request)
        sql = "set timezone='Europe/Amsterdam'; select timestamptz '2024-02-02 03:04:05.000001+00' as instant, '' as empty, 'null' as literal_null union all select timestamptz '2024-08-02 03:04:05.000001+00', '', 'null' union all select null::timestamptz, '', 'null'"
        result = command(engine, root, environment(duckdb_environment), 'show', ['--inline-direct', sql, '--output', 'json'])
        shown, = events(result, 'ShowNode')
        observed[engine] = json.loads(shown['data']['preview'])
    assert observed['dxt'] == observed['core'] == [{'instant': '2024-02-02T04:04:05.000001+01:00', 'empty': '', 'literal_null': 'null'}, {'instant': '2024-08-02T05:04:05.000001+02:00', 'empty': '', 'literal_null': 'null'}, {'instant': None, 'empty': '', 'literal_null': 'null'}]

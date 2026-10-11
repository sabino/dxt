"""Mandatory Core execution flag and persisted-test oracle on local adapters."""
from __future__ import annotations
import json
import hashlib
from importlib.metadata import version
from pathlib import Path
import pytest
from test_cli import ROOT, DXT, build_dxt  # noqa: F401
from test_usability_adapters import duckdb_environment, postgres_fixture, driver, invoke as native_invoke  # noqa: F401
from test_usability_cli_options import environment, invoke, write_profile

@pytest.fixture(autouse=True)
def pinned():
    assert version('dbt-core') == '1.10.5'
    assert version('dbt-duckdb') == '1.9.6'
    assert version('dbt-postgres') == '1.9.1'


def project(tmp_path, engine, adapter, server=None):
    root = tmp_path / engine
    (root / 'models').mkdir(parents=True)
    (root / 'tests').mkdir()
    (root / 'seeds').mkdir()
    (root / 'dbt_project.yml').write_text("name: cli_fixture\nversion: '1.0'\nconfig-version: 2\nprofile: cli_fixture\n")
    schema = f'cli_{engine}_{hashlib.sha256(str(tmp_path).encode()).hexdigest()[:8]}'
    db = root / 'warehouse.duckdb'
    if adapter == 'duckdb':
        write_profile(root, db, schema=schema)
    else:
        info = server.get_postmaster_info()
        (root / 'profiles.yml').write_text(f"cli_fixture:\n  target: dev\n  outputs:\n    dev:\n      type: postgres\n      schema: {schema}\n      host: '{info.socket_dir}'\n      port: {info.port}\n      dbname: postgres\n      user: postgres\n      password: ''\n      threads: 3\n")
    return root, db, schema


def query(driver, adapter, db, env, sql):
    result = native_invoke(driver, adapter, 'query', db, env, sql)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_failure_audit_persistence_sql_thresholds_and_signed_results(tmp_path, request, adapter, driver):
    server, native = (None, request.getfixturevalue('duckdb_environment')) if adapter == 'duckdb' else request.getfixturevalue('postgres_fixture')
    observed = {}
    for engine in ['dxt', 'core']:
        root, db, schema = project(tmp_path, engine, adapter, server)
        cases = {
            'empty_stored': "{{ config(store_failures=true) }} select 1 as bad where false",
            'view_failure': "{{ config(store_failures=false, store_failures_as='view', alias='custom_alias', schema='audits', severity='warn', fail_calc='-count(*)', warn_if='< 0', error_if='> 0') }} select 1 as bad union all select 2",
            'cli_false': "{{ config(store_failures=false) }} select 1 as bad where false",
            'cli_store': 'select 1 as bad where false',
            'complex': "{{ config(fail_calc='sum(n)', error_if='between 2 and 4', warn_if='in (1,5)') }} select 2 as n union all select 1",
        }
        for name, sql in cases.items():
            (root / f'tests/{name}.sql').write_text(sql + '\n')
        result = invoke(engine, ['-q', 'test', '--project-dir', root, '--threads', '3', '--store-failures'], root, environment(native), ok=False)
        assert result.returncode == 1, result.stdout + result.stderr
        rows = json.loads((root / 'target/run_results.json').read_text())['results']
        observed[engine] = {r['unique_id']: (r['status'], r['failures']) for r in rows}
        assert observed[engine]['test.cli_fixture.view_failure'] == ('warn', -2)
        manifest = json.loads((root / 'target/manifest.json').read_text())['nodes']
        node = manifest['test.cli_fixture.view_failure']
        assert node['alias'] == 'custom_alias' and node['schema'] == f'{schema}_audits'
        assert node['config']['store_failures'] is True and node['config']['store_failures_as'] == 'view'
        assert node['unrendered_config']['store_failures'] is False
        assert node['config']['fail_calc'] == '-count(*)'
        assert query(driver, adapter, db, native, f'select count(*) as n from "{schema}_dbt_test__audit".empty_stored') == [{'n': 0}]
        assert query(driver, adapter, db, native, f'select count(*) as n from "{schema}_dbt_test__audit".cli_store') == [{'n': 0}]
        assert query(driver, adapter, db, native, f'select count(*) as n from "{schema}_audits".custom_alias') == [{'n': 2}]
        assert query(driver, adapter, db, native, f"select table_type from information_schema.tables where table_schema='{schema}_audits' and table_name='custom_alias'") == [{'table_type': 'VIEW'}]
        assert query(driver, adapter, db, native, f"select table_name from information_schema.tables where table_schema='{schema}_dbt_test__audit' and table_name='cli_false'") == []
        # Replacing a view with a table, then persisting a passing result, follows
        # actual existing relation kind rather than issuing DROP TABLE on a view.
        (root / 'tests/view_failure.sql').write_text("{{ config(store_failures=true, store_failures_as='table', alias='custom_alias', schema='audits') }} select 1 as bad where false\n")
        invoke(engine, ['-q', 'test', '--project-dir', root, '-s', 'view_failure'], root, environment(native))
        assert query(driver, adapter, db, native, f'select count(*) as n from "{schema}_audits".custom_alias') == [{'n': 0}]
        assert query(driver, adapter, db, native, f"select table_type from information_schema.tables where table_schema='{schema}_audits' and table_name='custom_alias'") == [{'table_type': 'BASE TABLE'}]
    assert observed['dxt'] == observed['core']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_failure_audit_env_overrides_invalid_materialization_and_result(tmp_path, request, adapter, driver):
    server, native = (None, request.getfixturevalue('duckdb_environment')) if adapter == 'duckdb' else request.getfixturevalue('postgres_fixture')
    observed = {}
    for engine in ['dxt', 'core']:
        root, db, schema = project(tmp_path, engine, adapter, server)
        (root / 'tests/env.sql').write_text('select 1 as bad where false\n')
        invoke(engine, ['-q', 'test', '--project-dir', root], root, environment(native, DBT_STORE_FAILURES='true'))
        assert query(driver, adapter, db, native, f'select count(*) as n from "{schema}_dbt_test__audit".env') == [{'n': 0}]
        (root / 'tests/bad_kind.sql').write_text("{{ config(store_failures=false, store_failures_as='invalid') }} select 1\n")
        (root / 'tests/fraction.sql').write_text("{{ config(fail_calc='1.5') }} select 1\n")
        result = invoke(engine, ['-q', 'test', '--project-dir', root, '--threads', '3', '-s', 'bad_kind fraction'], root, environment(native), ok=False)
        assert result.returncode == 1
        observed[engine] = {r['unique_id']: (r['status'], r['failures']) for r in json.loads((root / 'target/run_results.json').read_text())['results']}
        assert set(observed[engine].values()) == {('error', None)}
    assert observed['dxt'] == observed['core']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_empty_sample_inputs_and_explicit_relation_render(tmp_path, request, adapter, driver):
    server, native = (None, request.getfixturevalue('duckdb_environment')) if adapter == 'duckdb' else request.getfixturevalue('postgres_fixture')
    for engine in ['dxt', 'core']:
        root, db, schema = project(tmp_path, engine, adapter, server)
        sql = "select 1 as id, cast('2024-01-01' as timestamp) as occurred_at union all select 2, cast('2024-01-02' as timestamp) union all select 3, cast('2024-01-03' as timestamp)"
        (root / 'models/a.sql').write_text("{{ config(materialized='table', event_time='occurred_at') }} " + sql + '\n')
        for name, relation in [('limited', "ref('a')"), ('explicit', "ref('a').render()"), ('source_limited', "source('external', 'events')")]:
            (root / f'models/{name}.sql').write_text("{{ config(materialized='table') }} select * from {{ " + relation + ' }}\n')
        (root / 'models/sources.yml').write_text(f"sources:\n  - name: external\n    schema: {schema}\n    tables:\n      - name: events\n        identifier: external_events\n        config:\n          event_time: occurred_at\n")
        query(driver, adapter, db, native, f'create schema if not exists "{schema}"; create table "{schema}".external_events as ({sql})')
        common = ['-q', 'run', '--project-dir', root, '-s', 'limited explicit source_limited']
        invoke(engine, ['-q', 'run', '--project-dir', root, '-s', 'a'], root, environment(native))
        invoke(engine, [*common, '--empty'], root, environment(native))
        assert query(driver, adapter, db, native, f'select count(*) as n from "{schema}".limited') == [{'n': 0}]
        assert query(driver, adapter, db, native, f'select count(*) as n from "{schema}".source_limited') == [{'n': 0}]
        assert query(driver, adapter, db, native, f'select count(*) as n from "{schema}".explicit') == [{'n': 3}]
        compiled = (root / 'target/compiled/cli_fixture/models/limited.sql').read_text()
        assert 'where false limit 0' in compiled
        assert ('_dbt_limit_subq_a' in compiled) is (adapter == 'postgres')
        invoke(engine, [*common, '--no-empty'], root, environment(native, DBT_EMPTY='true'))
        assert query(driver, adapter, db, native, f'select count(*) as n from "{schema}".limited') == [{'n': 3}]
        sample = "{start: '2024-01-02T00:00:00+05:00', end: '2024-01-04T00:00:00+05:00'}"
        invoke(engine, [*common, '--sample', sample], root, environment(native))
        for name in ['limited', 'source_limited']:
            assert query(driver, adapter, db, native, f'select id from "{schema}".{name} order by id') == [{'id': 2}, {'id': 3}]
        assert query(driver, adapter, db, native, f'select count(*) as n from "{schema}".explicit') == [{'n': 3}]
        artifact = json.loads((root / 'target/run_results.json').read_text())
        assert artifact['args']['sample'] == {'start': '2024-01-02T00:00:00+00:00', 'end': '2024-01-04T00:00:00+00:00'}
        invoke(engine, [*common, '--sample', sample, '--empty'], root, environment(native))
        assert query(driver, adapter, db, native, f'select count(*) as n from "{schema}".limited') == [{'n': 0}]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_seed_portable_csv_reload_and_full_refresh_preserve_existing_types(tmp_path, request, adapter, driver):
    server, native = (None, request.getfixturevalue('duckdb_environment')) if adapter == 'duckdb' else request.getfixturevalue('postgres_fixture')
    for engine in ['dxt', 'core']:
        root, db, schema = project(tmp_path, engine, adapter, server)
        seed = root / 'seeds/people.csv'
        seed.write_text('id,label\r\n2,"Alice, Smith"\r\n3,"Bob ""quoted"""\r\n')
        (root / 'seeds/properties.yml').write_text("seeds:\n  - name: people\n    config:\n      quote_columns: true\n      column_types: {id: bigint, label: text}\n    columns:\n      - name: id\n        data_tests:\n          - not_null:\n              config: {store_failures_as: view, schema: audits, alias: empty_not_null}\n")
        invoke(engine, ['-q', 'seed', '--project-dir', root], root, environment(native))
        assert query(driver, adapter, db, native, f'select * from "{schema}".people order by id') == [{'id': 2, 'label': 'Alice, Smith'}, {'id': 3, 'label': 'Bob "quoted"'}]
        # Normal seed reload keeps the old relation and its authored native type.
        (root / 'seeds/properties.yml').write_text((root / 'seeds/properties.yml').read_text().replace('id: bigint', 'id: text'))
        seed.write_text('id,label\n4,new\n')
        invoke(engine, ['-q', 'seed', '--project-dir', root], root, environment(native))
        assert query(driver, adapter, db, native, f'select * from "{schema}".people') == [{'id': 4, 'label': 'new'}]
        invoke(engine, ['-q', 'seed', '--project-dir', root, '--full-refresh'], root, environment(native))
        assert query(driver, adapter, db, native, f'select * from "{schema}".people') == [{'id': '4', 'label': 'new'}]
        invoke(engine, ['-q', 'test', '--project-dir', root, '-s', 'people'], root, environment(native))
        assert query(driver, adapter, db, native, f'select * from "{schema}_audits".empty_not_null') == []
        manifest = json.loads((root / 'target/manifest.json').read_text())['nodes']
        test = next(n for n in manifest.values() if n['resource_type'] == 'test')
        assert test['alias'] == 'empty_not_null' and test['schema'] == f'{schema}_audits'
        assert test['config']['store_failures'] is True and test['config']['store_failures_as'] == 'view'
        query(driver, adapter, db, native, f'drop table "{schema}".people cascade; create view "{schema}".people as select 4 as id, cast(\'new\' as text) as label')
        result = invoke(engine, ['-q', 'seed', '--project-dir', root, '--full-refresh'], root, environment(native), ok=False)
        assert result.returncode == 1
        assert query(driver, adapter, db, native, f"select table_type from information_schema.tables where table_schema='{schema}' and table_name='people'") == [{'table_type': 'VIEW'}]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_seed_show_primary_table_survives_quiet_json_and_no_print(tmp_path, request, adapter):
    server, native = (None, request.getfixturevalue('duckdb_environment')) if adapter == 'duckdb' else request.getfixturevalue('postgres_fixture')
    expected = {'| id | name  |', '| -- | ----- |', '|  2 | Alice |', '|  3 | Bob   |'}
    for engine in ['dxt', 'core']:
        root, _, _ = project(tmp_path, engine, adapter, server)
        (root / 'seeds/people.csv').write_text('id,name\n2,Alice\n3,Bob\n')
        for flags in [['-q'], ['-q', '--log-format', 'json'], ['-q', '--no-print'], ['--log-level', 'none']]:
            result = invoke(engine, [*flags, 'seed', '--project-dir', root, '--show'], root, environment(native))
            table = {line.strip() for line in result.stdout.splitlines() if line.startswith('|')}
            assert table == expected, (engine, flags, result.stdout, result.stderr)
        # BuildTask accepts show but inherits RunTask's end messages, which
        # do not call SeedTask.show_tables.
        result = invoke(engine, ['-q', 'build', '--project-dir', root, '--show', '-s', 'people'], root, environment(native))
        assert not any(line.startswith('|') for line in result.stdout.splitlines()), (engine, result.stdout)

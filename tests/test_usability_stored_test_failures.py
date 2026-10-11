"""Persisted singular test audit relations compared with pinned Core."""
from __future__ import annotations

import json

import pytest
from test_usability_global_hooks import invoke, normalize
from test_usability_materializations import (
    artifact_validator, build_dxt, oracle_available, postgres_server, project_at, query,
)


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_singular_audit_table_is_retained_after_passing_test(tmp_path, request, adapter):
    oracle_available(adapter)
    server = request.getfixturevalue('postgres_server') if adapter == 'postgres' else None
    observed = []
    for name, engine in [('core_audit', 'dbt'), ('native_audit', 'dxt')]:
        project = project_at(tmp_path / name, adapter, server)
        (project / 'models/a.sql').write_text("{{ config(materialized='table') }}select 1 as id")
        (project / 'tests').mkdir()
        audit = project / 'tests/audit_a.sql'
        audit.write_text("{{ config(store_failures=true) }}select * from {{ ref('a') }} where id > 0")
        schema = f'{project.name if adapter == "postgres" else "main"}_dbt_test__audit'
        records = []
        for command, condition, expected in [('build', '> 0', 1), ('test', '< 0', 0)]:
            audit.write_text("{{ config(store_failures=true) }}select * from {{ ref('a') }} where id " + condition)
            result = invoke(project, engine, command, '--select', 'a+')
            assert result.returncode == expected, result.stdout + result.stderr
            artifact_validator.assert_artifact(project / 'target/manifest.json')
            artifact_validator.assert_artifact(project / 'target/run_results.json')
            manifest = json.loads((project / 'target/manifest.json').read_text())
            node = manifest['nodes']['test.materialization_contract.audit_a']
            assert node['schema'] == schema
            assert node['config']['store_failures'] is True
            rows = json.loads((project / 'target/run_results.json').read_text())['results']
            row = next(row for row in rows if row['unique_id'] == node['unique_id'])
            assert row['status'] == ('fail' if expected else 'pass')
            assert row['failures'] == expected
            assert row['relation_name'] is not None
            records.append(normalize({key: row[key] for key in ['unique_id', 'status', 'failures', 'relation_name']}, project))
            assert query(project, adapter, f'select count(*) from "{schema}"."audit_a"', server) == [(expected,)]
            assert query(project, adapter, f"select count(*) from information_schema.tables where table_schema='{schema}' and table_name='audit_a'", server) == [(1,)]
        observed.append(records)
    assert observed[0] == observed[1]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('kind', ['generic', 'singular'])
@pytest.mark.parametrize('stage', ['create', 'aggregate'])
def test_core_audit_sql_error_matches_adapter_rollback_and_continues(tmp_path, request, adapter, kind, stage):
    oracle_available(adapter)
    server = request.getfixturevalue('postgres_server') if adapter == 'postgres' else None
    observed = []
    for name, engine in [('core_audit_error', 'dbt'), ('native_audit_error', 'dxt')]:
        project = project_at(tmp_path / f'{name}_{kind}_{stage}', adapter, server)
        (project / 'models/a.sql').write_text("{{ config(materialized='table') }}select 1 as id")
        (project / 'tests').mkdir()
        (project / 'tests/independent.sql').write_text('select 1 where false')
        if kind == 'generic':
            column = 'missing_column' if stage == 'create' else 'id'
            alias = f'not_null_a_{column}'
            config = {'store_failures': True}
            if stage == 'aggregate':
                config['fail_calc'] = 'missing_failure_count'
            (project / 'models/schema.yml').write_text(
                'version: 2\nmodels: [{name: a, columns: [{name: ' + column + ', data_tests: [{not_null: {config: ' + json.dumps(config) + '}}]}]}]\n'
            )
        else:
            alias = 'audit_a'
            (project / 'tests/audit_a.sql').write_text(
                "{{ config(store_failures=true) }}select missing_column from {{ ref('a') }}"
                if stage == 'create' else
                "{{ config(store_failures=true,fail_calc='missing_failure_count') }}select id from {{ ref('a') }} where id > 0"
            )
        schema = f'{project.name if adapter == "postgres" else "main"}_dbt_test__audit'
        base = project.name if adapter == 'postgres' else 'main'
        query(project, adapter, f'create schema if not exists "{base}"; create table "{base}".a(id integer); insert into "{base}".a values (1); create schema "{schema}"; create view "{schema}"."{alias}" as select 99 as id', server)
        result = invoke(project, engine, 'test')
        assert result.returncode == 1, result.stdout + result.stderr
        artifact_validator.assert_artifact(project / 'target/manifest.json')
        artifact_validator.assert_artifact(project / 'target/run_results.json')
        rows = json.loads((project / 'target/run_results.json').read_text())['results']
        observed.append({row['unique_id']: (row['status'], row['failures']) for row in rows})
        assert {row['status'] for row in rows} == {'error', 'pass'}
        retained = 1 if adapter == 'postgres' or stage == 'aggregate' else 0
        assert query(project, adapter, f"select count(*) from information_schema.tables where table_schema='{schema}' and table_name='{alias}'", server) == [(retained,)], engine
        if retained:
            expected = [(99,)] if stage == 'create' else ([] if kind == 'generic' else [(1,)])
            assert query(project, adapter, f'select * from "{schema}"."{alias}"', server) == expected
    assert observed[0] == observed[1]

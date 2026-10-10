"""Test resource metadata and retained audit lifecycle against pinned Core."""
import json

import pytest
import yaml

from test_cli import build_dxt, write_generic_test_config_project  # noqa: F401
from test_usability_adapters import duckdb_environment  # noqa: F401
from test_usability_cli_options import environment, invoke, pinned_core  # noqa: F401
from test_usability_configuration import configuration_postgres  # noqa: F401
from test_usability_sql_operations import command
from test_usability_test_helpers import captured, fixture


def storage_policy(root, generic, kind):
    if generic:
        path = root / 'models/schema.yml'
        document = yaml.safe_load(path.read_text())
        document['models'][0]['data_tests'][0]['bad_rows']['config']['store_failures_as'] = kind
        path.write_text(json.dumps(document))
    else:
        path = root / 'tests/check.sql'
        body = path.read_text()
        if body.startswith('{{ config(store_failures_as='):
            body = body.split('\n', 1)[1]
        path.write_text("{{ config(store_failures_as=" + repr(kind) + ") }}\n" + body)


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('generic', [False, True])
def test_core_repeated_audit_replaces_rows_and_switches_relation_kind(tmp_path, request, duckdb_environment, adapter, generic):
    observations = {}
    for engine in ['dxt', 'core']:
        root, schema = fixture(tmp_path, engine, adapter, request, store=True, generic=generic, override_limit=False)
        env = environment(duckdb_environment)
        command(engine, root, env, 'run')
        first = command(engine, root, env, 'test', ok=False)
        assert first.returncode == 1, first.stdout + first.stderr
        phases = [captured(root, schema, adapter, request)]
        assert phases[-1][1]['status'] == 'fail' and phases[-1][1]['failures'] == 1
        assert phases[-1][2] == [(1,)]

        (root / 'models/input.sql').write_text("{{ config(materialized='table') }}select 1 as id where false")
        command(engine, root, env, 'run')
        for kind in ['table', 'view', 'table']:
            storage_policy(root, generic, kind)
            command(engine, root, env, 'test')
            phase = captured(root, schema, adapter, request)
            assert phase[1]['status'] == 'pass' and phase[1]['failures'] == 0
            assert phase[2] == []
            assert phase[0]['config']['store_failures_as'] == kind
            phases.append(phase)
        observations[engine] = phases
    assert observations['dxt'] == observations['core']


def test_native_profileless_duckdb_replaces_audit_with_empty_relation(tmp_path, duckdb_environment):
    import duckdb
    project = tmp_path / 'project'
    target = tmp_path / 'target'
    write_generic_test_config_project(project, severity='error', error_if='> 0', store_failures=True)
    env = environment(duckdb_environment)
    env['HOME'] = str(tmp_path / 'empty-home')
    args = ['--quiet', '--no-use-colors', '--project-dir', project, '--target-path', target]
    invoke('dxt', ['run', *args, '--select', 'customers'], project, env)
    first = invoke('dxt', ['test', *args, '--select', 'not_null_customers_customer_id'], project, env, ok=False)
    assert first.returncode == 1, first.stdout + first.stderr
    first_rows = json.loads((target / 'run_results.json').read_text())['results']
    row, = first_rows
    assert row['status'] == 'fail' and row['failures'] == 1
    write_generic_test_config_project(project, severity='error', error_if='> 0', where="status = 'missing'", store_failures=True)
    invoke('dxt', ['build', *args, '--select', 'customers+'], project, env)
    rows = json.loads((target / 'run_results.json').read_text())['results']
    assert {row['unique_id']: row['status'] for row in rows} == {
        'model.generic_test_config_tests.customers': 'success',
        'test.generic_test_config_tests.not_null_customers_customer_id.5c9bf9911d': 'pass',
    }
    test_row, = [row for row in rows if row['unique_id'].startswith('test.')]
    assert test_row['failures'] == 0
    assert test_row['relation_name'] == '"main_dbt_test__audit"."not_null_customers_customer_id"'
    with duckdb.connect(str(target / 'dxt.duckdb')) as connection:
        assert connection.execute('select count(*) from "main_dbt_test__audit"."not_null_customers_customer_id"').fetchone() == (0,)

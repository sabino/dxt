"""Actual Core CTE compilation and execution for ephemeral data-test inputs."""
import json

import pytest

from test_cli import build_dxt
from test_usability_artifacts import contracts
from test_usability_configuration import (
    ConfigurationPair, configuration_oracle, configuration_postgres, configure_adapter,
)


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('statement', ['select', 'with', 'recursive'])
def test_core_ephemeral_generic_and_singular_tests_compile_and_execute(
    tmp_path, configuration_oracle, request, adapter, statement,
):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('models/marts/base.sql', '{{ config(materialized="ephemeral", alias="custom_base") }}select 1 as id')
    pair.write('models/marts/value.sql', '{{ config(materialized="ephemeral", alias="custom_value") }}select * from {{ ref("base") }}')
    pair.write('models/schema.yml', "version: 2\nmodels:\n  - name: value\n    columns:\n      - name: id\n        data_tests: [not_null, unique]\n")
    source = "select * from {{ ref('value') }} where id is null"
    if statement == 'with':
        source = "-- retain comment\nWITH own as (select * from {{ ref('value') }}) select * from own where id is null"
    elif statement == 'recursive':
        source = "/* retain comment */\nWITH RECURSIVE own as (select * from {{ ref('value') }}) select * from own where id is null"
    pair.write('tests/assert_value.sql', source)

    actual, expected = pair.invoke('compile')
    tests = {uid: node for uid, node in expected['nodes'].items() if node['resource_type'] == 'test'}
    assert len(tests) == 3
    for uid, node in tests.items():
        for field in ['compiled_code', 'extra_ctes', 'extra_ctes_injected', 'depends_on']:
            assert actual['nodes'][uid][field] == node[field], (uid, field)
        assert [cte['id'] for cte in node['extra_ctes']] == [
            'model.configuration_fixture.base', 'model.configuration_fixture.value',
        ]
    for path in pair.projects:
        contracts.assert_artifact(path / 'target/manifest.json')

    pair.invoke('build')
    rows = [{row['unique_id']: row for row in json.loads((p / 'target/run_results.json').read_text())['results']} for p in pair.projects]
    assert set(rows[0]) == set(rows[1]) == set(tests)
    for uid in tests:
        for field in ['status', 'failures', 'compiled_code', 'relation_name']:
            assert rows[0][uid][field] == rows[1][uid][field], (uid, field)
        assert rows[0][uid]['status'] == 'pass'
    for path in pair.projects:
        contracts.assert_artifact(path / 'target/run_results.json')


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_ephemeral_test_sql_error_retains_compilation_and_independent_results(
    tmp_path, configuration_oracle, request, adapter,
):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('models/marts/value.sql', '{{ config(materialized="ephemeral", alias="custom_value") }}select 1 as id')
    pair.write('models/schema.yml', "version: 2\nmodels:\n  - name: value\n    columns:\n      - name: id\n        data_tests: [not_null]\n")
    pair.write('tests/assert_value.sql', "select missing_column from {{ ref('value') }}")
    pair.invoke('build', success=False)
    rows = [{row['unique_id']: row for row in json.loads((p / 'target/run_results.json').read_text())['results']} for p in pair.projects]
    assert set(rows[0]) == set(rows[1])
    assert {row['status'] for row in rows[0].values()} == {'error', 'pass'}
    for uid in rows[1]:
        for field in ['status', 'failures', 'compiled_code']:
            assert rows[0][uid][field] == rows[1][uid][field], (uid, field)
        assert '__dbt__cte__custom_value as (' in rows[0][uid]['compiled_code']
    for path in pair.projects:
        contracts.assert_artifact(path / 'target/run_results.json')

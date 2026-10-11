"""Core CSV identifiers and existing-view seed boundaries on both adapters."""
from __future__ import annotations

import json

import pytest
from test_usability_global_hooks import invoke
from test_usability_materializations import (
    artifact_validator, build_dxt, oracle_available, postgres_server, project_at, query,
)


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('scenario', ['typed_unquoted', 'invalid_unquoted', 'view', 'view_full_refresh'])
def test_core_seed_unquoted_names_types_and_existing_view_policy(tmp_path, request, adapter, scenario):
    oracle_available(adapter)
    server = request.getfixturevalue('postgres_server') if adapter == 'postgres' else None
    projects = [project_at(tmp_path / f'{name}_{scenario}', adapter, server) for name in ['native_seed', 'core_seed']]
    outcomes = []
    # Validate authored SQL with Core first, including negative seed contracts.
    for project, engine in [(projects[1], 'dbt'), (projects[0], 'dxt')]:
        (project / 'models/a.sql').write_text('select 1 as id')
        (project / 'seeds').mkdir()
        header = 'Order ID' if scenario == 'invalid_unquoted' else 'order_id'
        (project / 'seeds/input.csv').write_text(f'{header},amount\n1,10.50\n')
        (project / 'seeds/properties.yml').write_text(
            'version: 2\nseeds:\n  - name: input\n    config:\n      quote_columns: false\n'
            '      column_types: {order_id: integer, amount: "decimal(10,2)"}\n'
        )
        schema = project.name if adapter == 'postgres' else 'main'
        if scenario.startswith('view'):
            query(project, adapter, f'create schema if not exists "{schema}"; create view "{schema}".input as select 99 as order_id', server)
        arguments = ['--select', 'input']
        if scenario == 'view_full_refresh':
            arguments.append('--full-refresh')
        result = invoke(project, engine, 'seed', *arguments)
        expected = 0 if scenario == 'typed_unquoted' else 1
        assert result.returncode == expected, result.stdout + result.stderr
        artifact_validator.assert_artifact(project / 'target/manifest.json')
        artifact_validator.assert_artifact(project / 'target/run_results.json')
        rows = json.loads((project / 'target/run_results.json').read_text())['results']
        outcomes.append([(row['unique_id'], row['status']) for row in rows])
        if scenario.startswith('view'):
            assert query(project, adapter, 'select * from input', server) == [(99,)]
        elif scenario == 'typed_unquoted':
            from decimal import Decimal
            assert query(project, adapter, 'select * from input', server) == [(1, Decimal('10.50'))]
            assert query(project, adapter, "select column_name, data_type from information_schema.columns where table_schema=current_schema() and table_name='input' order by ordinal_position", server) == [
                ('order_id', 'integer' if adapter == 'postgres' else 'INTEGER'),
                ('amount', 'numeric' if adapter == 'postgres' else 'DECIMAL(10,2)'),
            ]
    assert outcomes[0] == outcomes[1]

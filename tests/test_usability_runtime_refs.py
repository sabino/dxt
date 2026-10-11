"""Runtime refs require dependencies captured by parse or an explicit hint."""
import json

import pytest

from test_cli import build_dxt
from test_usability_configuration import configuration_oracle, configuration_postgres
from test_usability_resource_hooks import setup_pair


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('hint', [False, True])
def test_conditional_runtime_ref_requires_dependency_hint(tmp_path, configuration_oracle, request, adapter, hint):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/parent.sql', 'select 1 as id')
    sql = "{% if execute %}select * from {{ ref('parent') }}{% else %}select 1 as id{% endif %}"
    if hint:
        sql = "-- depends_on: {{ ref('parent') }}\n" + sql
    pair.write('models/marts/rendered.sql', sql)
    manifests = pair.invoke('parse')
    for manifest in manifests:
        dependencies = manifest['nodes']['model.configuration_fixture.rendered']['depends_on']['nodes']
        assert dependencies == (['model.configuration_fixture.parent'] if hint else [])
    output = pair.invoke('compile', success=hint)
    if not hint:
        result, reference = output
        assert 'unable to infer all dependencies' in result.stdout + result.stderr
        assert "depends_on: {{ ref('parent') }}" in result.stdout + result.stderr
        assert 'unable to infer all dependencies' in str(reference.exception)
    else:
        assert [row['status'] for row in json.loads((pair.projects[0] / 'target/run_results.json').read_text())['results']] == ['success', 'success']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_run_operation_refs_use_operation_provider_without_model_dependency_requirement(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/parent.sql', 'select 1 as id')
    pair.write('macros/probe.sql', "{% macro probe() %}{% set relation = ref('parent') %}{% if relation.identifier != 'parent' %}{{ exceptions.raise_compiler_error('bad relation') }}{% endif %}{% endmacro %}")
    pair.invoke('run-operation probe')

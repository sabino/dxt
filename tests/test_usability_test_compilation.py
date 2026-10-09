"""Pinned Core data-test compilation boundaries, distinct from execution SQL."""
import pytest

from test_cli import build_dxt
from test_usability_artifacts import contracts
from test_usability_configuration import (
    ConfigurationPair, configuration_oracle, configuration_postgres, configure_adapter,
)


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('limit', [None, -1, 0, 2])
def test_core_configured_test_limit_is_not_added_to_compiled_macro_body(
    tmp_path, configuration_oracle, request, adapter, limit,
):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('models/marts/value.sql', '{{ config(materialized="table") }}select 1 as id')
    pair.write('macros/bounded.sql', "{% test bounded(model) %}select * from {{ model }} where id is null limit 99{% endtest %}")
    serialized = 'null' if limit is None else str(limit)
    pair.write('models/schema.yml', 'version: 2\nmodels:\n  - name: value\n    data_tests:\n      - bounded: {config: {limit: ' + serialized + '}}\n    columns:\n      - name: id\n        data_tests:\n          - not_null: {config: {limit: ' + serialized + '}}\n')
    actual, expected = pair.invoke('compile')
    tests = {uid: node for uid, node in expected['nodes'].items() if node['resource_type'] == 'test'}
    assert len(tests) == 2
    for uid, node in tests.items():
        assert actual['nodes'][uid]['compiled_code'] == node['compiled_code'], uid
        assert actual['nodes'][uid]['config']['limit'] == node['config']['limit'] == limit
        assert actual['nodes'][uid]['depends_on'] == node['depends_on'], uid
        if node['test_metadata']['name'] == 'bounded':
            assert node['compiled_code'].endswith('limit 99')
        else:
            assert 'limit' not in node['compiled_code'].lower()
    for path in pair.projects:
        contracts.assert_artifact(path / 'target/manifest.json')


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_authored_generic_model_argument_preserves_relation_attributes(
    tmp_path, configuration_oracle, request, adapter,
):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('models/marts/value.sql', '{{ config(materialized="table") }}select 1 as id')
    pair.write('macros/identity.sql', "{% test relation_identity(model) %}select '{{ model.identifier }}' as identifier, '{{ model.schema }}' as schema_name from {{ model.render() }} where false{% endtest %}")
    pair.write('models/schema.yml', "version: 2\nmodels:\n  - name: value\n    data_tests: [relation_identity]\nsources:\n  - name: raw\n    schema: landing\n    tables:\n      - name: events\n        identifier: source_events\n        data_tests: [relation_identity]\n")
    actual, expected = pair.invoke('compile')
    tests = {uid: node for uid, node in expected['nodes'].items() if node['resource_type'] == 'test'}
    assert len(tests) == 2
    for uid, node in tests.items():
        assert actual['nodes'][uid]['compiled_code'] == node['compiled_code'], uid
        assert actual['nodes'][uid]['depends_on'] == node['depends_on'], uid
        identifier = 'source_events' if node['attached_node'] is None else 'value'
        assert f"select '{identifier}' as identifier" in node['compiled_code']
    for path in pair.projects:
        contracts.assert_artifact(path / 'target/manifest.json')

"""Generic argument calls retain actual runtime dependency order."""
import json

import pytest

from test_cli import build_dxt
from test_usability_configuration import configuration_oracle, configuration_postgres
from test_usability_resource_hooks import setup_pair


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('command', ['compile', 'test', 'build'])
def test_generic_runtime_argument_macro_is_retained_before_test_execution(tmp_path, configuration_oracle, request, adapter, command):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.append_project('flags:\n  require_generic_test_arguments_property: true\n')
    pair.write('models/marts/rendered.sql', 'select 1 as id')
    pair.write('macros/order.sql', "{% macro z_inner(value) %}{{ return(value) }}{% endmacro %}{% test positive(model, column_name, threshold) %}select * from {{ model }} where {{ column_name }} < {{ threshold }}{% endtest %}")
    pair.write('models/schema.yml', json.dumps({'version': 2, 'models': [{'name': 'rendered', 'columns': [{'name': 'id', 'data_tests': [{'positive': {'arguments': {'threshold': '{{ z_inner(1) if execute else 0 }}'}}}]}]}]}))
    if command == 'test':
        pair.invoke('run')
    actual, expected = pair.invoke(command)
    actual_tests = [node for node in actual['nodes'].values() if node['resource_type'] == 'test']
    expected_tests = [node for node in expected['nodes'].values() if node['resource_type'] == 'test']
    assert len(actual_tests) == len(expected_tests) == 1
    assert actual_tests[0]['depends_on']['macros'] == expected_tests[0]['depends_on']['macros']
    assert 'macro.configuration_fixture.z_inner' in expected_tests[0]['depends_on']['macros']

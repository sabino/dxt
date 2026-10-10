"""Reached singular-test calls follow Core argument order before helper calls."""
import pytest

from test_cli import build_dxt
from test_usability_configuration import configuration_oracle, configuration_postgres
from test_usability_resource_hooks import setup_pair


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('command', ['parse', 'compile', 'test', 'build'])
def test_singular_runtime_calls_retain_direct_evaluation_order(tmp_path, configuration_oracle, request, adapter, command):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', 'select 1 as id')
    pair.write('macros/order.sql', "{% macro z_inner(value) %}{{ return(value) }}{% endmacro %}{% macro a_outer(value) %}{{ return(hidden(value)) }}{% endmacro %}{% macro hidden(value) %}{{ return(value) }}{% endmacro %}")
    pair.write('tests/assert_runtime.sql', "select {{ a_outer(z_inner(1)) if execute else 1 }} as id where false")
    actual, expected = pair.invoke(command)
    actual_dependencies = actual['nodes']['test.configuration_fixture.assert_runtime']['depends_on']['macros']
    expected_dependencies = expected['nodes']['test.configuration_fixture.assert_runtime']['depends_on']['macros']
    assert actual_dependencies == expected_dependencies
    if command == 'parse':
        assert expected_dependencies == []
    else:
        assert expected_dependencies[:2] == ['macro.configuration_fixture.z_inner', 'macro.configuration_fixture.a_outer']
        assert 'macro.configuration_fixture.hidden' not in expected_dependencies

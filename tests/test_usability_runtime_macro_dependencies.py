"""Runtime-only direct macro calls retain Core's evaluation order in artifacts."""
import json
import pytest

from test_cli import build_dxt
from test_usability_configuration import ConfigurationPair, configuration_oracle, configuration_postgres, configure_adapter


MACROS = """{% macro z_inner(value) %}{{ return(value) }}{% endmacro %}
{% macro a_outer(value) %}{{ return(hidden(value)) }}{% endmacro %}
{% macro hidden(value) %}{{ return(value) }}{% endmacro %}
{% macro loop_meta(value) %}{{ value.length }}{% endmacro %}
"""


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('command', ['parse', 'compile', 'run', 'build'])
def test_runtime_macro_calls_append_direct_argument_evaluation_order(tmp_path, configuration_oracle, request, adapter, command):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('macros/order.sql', MACROS)
    pair.write('models/marts/rendered.sql', "{% set values = [1,2] if execute else [] %}select {% for value in values %}{{ a_outer(z_inner(value)) }} + {% endfor %}0 as id")
    actual, expected = pair.invoke(command)
    actual_deps = actual['nodes']['model.configuration_fixture.rendered']['depends_on']['macros']
    expected_deps = expected['nodes']['model.configuration_fixture.rendered']['depends_on']['macros']
    assert actual_deps == expected_deps
    assert expected_deps == ([] if command == 'parse' else ['macro.configuration_fixture.z_inner', 'macro.configuration_fixture.a_outer'])


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_parse_macro_dependencies_preserve_argument_order(tmp_path, configuration_oracle, request, adapter):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('macros/order.sql', MACROS)
    pair.write('models/marts/rendered.sql', 'select {{ a_outer(z_inner(1)) }} as id')
    actual, expected = pair.invoke('parse')
    assert actual['nodes']['model.configuration_fixture.rendered']['depends_on']['macros'] == expected['nodes']['model.configuration_fixture.rendered']['depends_on']['macros'] == ['macro.configuration_fixture.z_inner', 'macro.configuration_fixture.a_outer']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_deferred_loop_filter_keeps_creation_scope_inside_macro(tmp_path, configuration_oracle, request, adapter):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('macros/order.sql', MACROS)
    pair.write('models/marts/rendered.sql', "{% set cutoff=3 %}select '{% for value in [1,2,3] if value<cutoff %}{{ value }}:{{ loop_meta(loop) }};{% endfor %}' as value")
    actual, expected = pair.invoke('compile')
    assert actual['nodes']['model.configuration_fixture.rendered']['compiled_code'] == expected['nodes']['model.configuration_fixture.rendered']['compiled_code']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('command', ['compile', 'run', 'build'])
def test_macro_calls_reached_before_runtime_error_remain_in_manifest(tmp_path, configuration_oracle, request, adapter, command):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('macros/order.sql', MACROS + "{% macro z_bad() %}{{ missing_global.child }}{% endmacro %}")
    pair.write('models/marts/rendered.sql', 'select {{ z_bad() if execute else 1 }} as id')
    pair.invoke(command, success=False)
    actual, expected = [json.loads((project / 'target/manifest.json').read_text()) for project in pair.projects]
    # CompileTask leaves its previously written parse manifest after failure;
    # executable runners publish the reached call in their final manifest.
    assert actual['nodes']['model.configuration_fixture.rendered']['depends_on']['macros'] == expected['nodes']['model.configuration_fixture.rendered']['depends_on']['macros'] == ([] if command == 'compile' else ['macro.configuration_fixture.z_bad'])

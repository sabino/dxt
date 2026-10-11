"""Core oracles for scoped native control flow, callbacks and typed kwargs."""
import json

import pytest

from test_cli import build_dxt
from test_usability_configuration import ConfigurationPair, configuration_oracle


@pytest.mark.parametrize('template', [
    "select '{% for x in [1,2,3,4] if x % 2 == 0 %}{{ loop.index }}:{{ x }}:{{ loop.last }};{% endfor %}' as value",
    "select '{% for x in [] %}{{ x }}{% else %}empty{% endfor %}' as value",
    "select '{% for x in [1,2] %}{{ x }}{% else %}empty{% endfor %}' as value",
    "select '{% for x in [1,2] if x > 5 %}{{ x }}{% else %}filtered-empty{% endfor %}' as value",
    "select '{% for x in range(5) %}{% if x == 2 %}{% break %}{% endif %}{{ x }}{% endfor %}' as value",
    "select '{% for x in range(5) %}{% if x == 2 %}{% continue %}{% endif %}{{ loop.index }}:{{ x }};{% endfor %}' as value",
    "select '{% for x in [1,2] %}{{ x }}[{% for y in [1,2,3] %}{% if y == 2 %}{% break %}{% endif %}{{ y }}{% endfor %}]{% endfor %}' as value",
    "{% set fn = stringify %}select '{{ fn(7) }}' as value",
    "{% set fn = adapter.dispatch('stringify', 'configuration_fixture') %}select '{{ fn(7) }}' as value",
    "select '{{ invoke(stringify, 7) }}' as value",
])
def test_native_scoped_loops_and_callable_bindings_match_core(tmp_path, configuration_oracle, template):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('macros/callbacks.sql', """{% macro stringify(value) %}{{ return('value=' ~ value) }}{% endmacro %}
{% macro default__stringify(value) %}{{ return('dispatched=' ~ value) }}{% endmacro %}
{% macro invoke(callback, value) %}{{ return(callback(value)) }}{% endmacro %}
""")
    pair.write('models/marts/rendered.sql', template)
    actual, expected = pair.invoke('compile')
    assert actual['nodes']['model.configuration_fixture.rendered']['compiled_code'] == expected['nodes']['model.configuration_fixture.rendered']['compiled_code']


def test_custom_generic_kwargs_keep_nested_expression_types_and_relations(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.append_project("flags: {require_generic_test_arguments_property: true}\nvars: {numbers: [1, 2], enabled: true, suffix: 7}\n")
    pair.write('models/marts/rendered.sql', 'select 1 as id')
    pair.write('models/marts/other.sql', 'select 1 as id')
    pair.write('models/properties.yml', """version: 2
models:
  - name: rendered
    data_tests:
      - nested_values:
          arguments:
            payload:
              numbers: "{{ var('numbers') }}"
              nested: {enabled: "{{ var('enabled') }}"}
              relation: "ref('other')"
              mixed: "prefix-{{ var('suffix') }}"
""")
    pair.write('macros/tests.sql', """{% test nested_values(model, payload) %}
{% if payload['numbers'] != [1, 2] or payload.nested.enabled is not boolean or (execute and payload.relation.identifier != 'other') or payload.mixed != 'prefix-7' %}
{{ exceptions.raise_compiler_error('Generic argument types were lost') }}
{% endif %}
select * from {{ model }} where id not in (select id from {{ payload.relation }})
{% endtest %}
""")
    actual, expected = pair.invoke('compile')
    actual_test = next(node for node in actual['nodes'].values() if node['resource_type'] == 'test')
    expected_test = next(node for node in expected['nodes'].values() if node['resource_type'] == 'test')
    assert actual_test['compiled_code'] == expected_test['compiled_code']

"""Model-local macros use dbt's MacroFuzz names and lexical template context."""
import pytest

from test_cli import build_dxt
from test_usability_configuration import configuration_oracle, configuration_postgres
from test_usability_resource_hooks import setup_pair


CASES = [
    "{% macro up(x) %}{{ x|upper }}{% endmacro %}select '{{ dbt_macro__up('abc') }}' as value",
    "{% macro up(x: string, options: dict[str,list[int]]={'ids':[1,2]}) %}{{ x|upper }}:{{ options.ids|length }}{% endmacro %}select '{{ dbt_macro__up('abc') }}' as value",
    "{% set value='before' %}{% macro local() %}{{ value }}{% endmacro %}{% set value='after' %}select '{{ dbt_macro__local() }}' as value",
    "{% macro local() %}{{ value }}{% endmacro %}{% set value='after' %}select '{{ dbt_macro__local() }}' as value",
    "{% macro local(x='a', y=x|upper) %}{{ y }}{% endmacro %}select '{{ dbt_macro__local() }}' as value",
    "{% macro local(x) %}{% if x > 0 %}{{ x }}{{ dbt_macro__local(x-1) }}{% endif %}{% endmacro %}select '{{ dbt_macro__local(3) }}' as value",
    "{% macro local(x='a') %}{{ x }}{% endmacro %}select '{{ dbt_macro__local.name }}:{{ dbt_macro__local.arguments }}:{{ dbt_macro__local.catch_kwargs }}:{{ dbt_macro__local.caller }}' as value",
    "{% macro local(x) %}{{ x }}:{{ varargs|join(',') }}:{{ kwargs.label }}{% endmacro %}select '{{ dbt_macro__local(1,2,3,label='yes') }}' as value",
    "{% macro local() %}[{{ caller('value') }}]{% endmacro %}select '{% call(x) dbt_macro__local() %}{{ x|upper }}{% endcall %}' as value",
    "{% set values=[] %}{% macro local(x) %}{% do values.append(x) %}{{ values|join(',') }}{% endmacro %}select '{{ dbt_macro__local(1) }}|{{ dbt_macro__local(2) }}|{{ values|join(',') }}' as value",
    "{% macro mutate(xs) %}{% do xs.append(1) %}{% endmacro %}{% macro local() %}{% set xs=[] %}{% do dbt_macro__mutate(xs) %}{{ xs|join(',') }}{% endmacro %}select '{{ dbt_macro__local() }}' as value",
    "{% macro first(x=1000) %}{{ x is sameas 1000 }}:{{ dbt_macro__second(x) }}{% endmacro %}{% macro second(x=1000) %}{{ x is sameas 1000 }}{% endmacro %}select '{{ dbt_macro__first() }}' as value",
]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('template', CASES)
def test_inline_macro_uses_fuzzed_name_and_lexical_bindings(tmp_path, configuration_oracle, request, adapter, template):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', template)
    actual, expected = [manifest['nodes']['model.configuration_fixture.rendered'] for manifest in pair.invoke('compile')]
    assert actual['compiled_code'] == expected['compiled_code']
    assert actual['depends_on'] == expected['depends_on']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('template', [
    "{% macro local(x) %}{{ x }}{% endmacro %}select '{{ local('value') }}' as value",
    "{% macro local(x) %}{{ return(x) }}{% endmacro %}select '{{ dbt_macro__local('value') }}' as value",
    "{% macro local(x) %}{{ x }}{% endmacro %}select '{{ dbt_macro__local(1,2) }}' as value",
    "{% macro local(x:) %}{{ x }}{% endmacro %}select '{{ dbt_macro__local('value') }}' as value",
])
def test_inline_macro_retains_core_name_return_and_argument_errors(tmp_path, configuration_oracle, request, adapter, template):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', template)
    pair.invoke('compile', success=False)


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('command', ['parse', 'compile'])
def test_inline_macro_keeps_project_macro_dependencies_direct(tmp_path, configuration_oracle, request, adapter, command):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('macros/helper.sql', "{% macro helper(x) %}{{ x|upper }}{% endmacro %}")
    pair.write('models/marts/rendered.sql', "{% macro local(x) %}{{ helper(x) }}{% endmacro %}select '{{ dbt_macro__local('abc') }}' as value")
    actual, expected = [manifest['nodes']['model.configuration_fixture.rendered'] for manifest in pair.invoke(command)]
    assert actual['depends_on'] == expected['depends_on']
    assert actual['depends_on']['macros'] == ['macro.configuration_fixture.helper']
    if command == 'compile':
        assert actual['compiled_code'] == expected['compiled_code']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_authored_typed_macro_binds_names_without_changing_artifact_metadata(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('macros/helper.sql', "{% macro helper(x: string, options: dict[str,list[int]]={'ids':[1,2]}) %}{{ x|upper }}:{{ options.ids|length }}{% endmacro %}")
    pair.write('models/marts/rendered.sql', "select '{{ helper('abc') }}' as value")
    actual, expected = pair.invoke('compile')
    assert actual['nodes']['model.configuration_fixture.rendered']['compiled_code'] == expected['nodes']['model.configuration_fixture.rendered']['compiled_code']
    assert actual['macros']['macro.configuration_fixture.helper']['arguments'] == expected['macros']['macro.configuration_fixture.helper']['arguments']

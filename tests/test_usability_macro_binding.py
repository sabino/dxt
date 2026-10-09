"""Pinned Core macro argument and lexical call-block integration oracles."""
from __future__ import annotations

import pytest

from test_cli import build_dxt
from test_usability_configuration import (
    ConfigurationPair, configuration_oracle, configuration_postgres, configure_adapter,
)


POSITIVE = [
    ("quoted_expression_boundary", "{% macro probe() %}{{ return('}}' ~ kwargs.label) }}{% endmacro %}", "select '{{ probe(label='bound') }}' as rendered"),
    ("missing_argument_identity", "{% macro probe(value) %}{{ return((value is sameas value)|string ~ ':' ~ (value is sameas missing)|string) }}{% endmacro %}", "select '{{ probe() }}' as rendered"),
    ("caller_mutable_aliases", "{% macro probe() %}{{ caller(1) }}{{ caller(2) }}{% endmacro %}", "{% set xs=[] %}{% set alias=xs %}select '{% call(value) probe() %}{% do xs.append(value) %}{% endcall %}{{ xs|join(',') }}:{{ alias|join(',') }}' as rendered"),
    ("caller_model_capture_globals", "{% macro probe() %}{{ caller() }}{% endmacro %}", "select '{% call probe() %}{% if not execute %}{% do config(meta={'name':missing_global.child.name}) %}{% endif %}ok{% endcall %}' as rendered"),
    ("forwarded_model_capture", "{% macro probe(value) %}{% if not execute %}{% do config(meta={'name':value.name,'hint':value.hint}) %}{% endif %}{{ return((value is undefined)|string) }}{% endmacro %}", "select '{{ probe(missing_global) }}' as rendered"),

    ("missing_required", "{% macro probe(value) %}{{ return((value is undefined)|string ~ ':' ~ (value|default('fallback')) ~ ':' ~ value) }}{% endmacro %}", "select '{{ probe() }}' as rendered"),
    ("forward_missing", "{% macro probe(value) %}{{ return(forward(value)) }}{% endmacro %}{% macro forward(value) %}{{ return('prefix:' ~ value) }}{% endmacro %}", "select '{{ probe() }}' as rendered"),
    ("dependent_defaults", "{% macro probe(a=7,b=a,c=b) %}{{ return(a|string ~ ':' ~ b|string ~ ':' ~ c|string) }}{% endmacro %}", "select '{{ probe(b=8) }}' as rendered"),
    ("collected_extras", "{% macro probe(value) %}{{ return(value|string ~ ':' ~ varargs|join(',') ~ ':' ~ kwargs.label) }}{% endmacro %}", "select '{{ probe(1,2,3,label='ok') }}' as rendered"),
    ("collected_duplicate_parameter", "{% macro probe(value) %}{{ return(value|string ~ ':' ~ kwargs.value|string) }}{% endmacro %}", "select '{{ probe(1,value=2) }}' as rendered"),
    ("dead_branch_extras", "{% macro probe() %}{% if false %}{{ varargs }}{{ kwargs }}{% endif %}{{ return('ok') }}{% endmacro %}", "select '{{ probe(1,label='ignored') }}' as rendered"),
    ("explicit_special_parameters", "{% macro probe(varargs,kwargs) %}{{ return(varargs|string ~ ':' ~ kwargs.label) }}{% endmacro %}", "select '{{ probe(7,{'label':'explicit'}) }}' as rendered"),
    ("caller_missing_defined", "{% macro probe() %}{{ return((caller is undefined)|string) }}{% endmacro %}", "select '{{ probe() }}' as rendered"),
    ("caller_lazy_unused", "{% macro probe() %}{% if false %}{{ caller() }}{% endif %}ok{% endmacro %}", "select '{% call probe() %}{{ exceptions.raise_compiler_error('unused caller executed') }}{% endcall %}' as rendered"),
    ("caller_repeated_arguments", "{% macro probe() %}{{ caller(1) }}|{{ caller(value=2,prefix='other') }}{% endmacro %}", "select '{% call(value,prefix='row') probe() %}{{ prefix }}:{{ value }}{% endcall %}' as rendered"),
    ("caller_lexical_scope", "{% macro probe() %}{% set label='inner' %}{{ caller(1) }}|{{ caller(2) }}{% endmacro %}", "{% set label='outer' %}select '{% call(value) probe() %}{{ label }}:{{ value }}{% endcall %}' as rendered"),
    ("caller_explicit_default", "{% macro probe(caller=None) %}{{ caller('bound') }}{% endmacro %}", "select '{% call(value) probe() %}{{ value }}{% endcall %}' as rendered"),
    ("caller_nested", "{% macro probe(value) %}[{{ caller(value) }}]{% endmacro %}", "select '{% call(a) probe(1) %}{{ a }}{% call(b) probe(2) %}{{ a }}:{{ b }}{% endcall %}{% endcall %}' as rendered"),
    ("caller_body_return", "{% macro probe() %}{{ caller() }}{{ exceptions.raise_compiler_error('return did not exit macro') }}{% endmacro %}", "select '{% call probe() %}{{ return('done') }}{% endcall %}' as rendered"),
    ("capture_callback_parameter_hint", "{% macro probe() %}{{ caller() }}{% endmacro %}", "select '{% call(value) probe() %}{% if not execute %}{% do config(meta={'callback_hint':value.hint}) %}{% endif %}{{ value|default('omitted') }}{% endcall %}' as rendered"),
]


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("name,macros,template", POSITIVE, ids=[case[0] for case in POSITIVE])
def test_native_macro_binding_and_callers_match_core(tmp_path, configuration_oracle, request, adapter, name, macros, template):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write("macros/binding.sql", macros)
    pair.write("models/marts/rendered.sql", template)
    actual, expected = pair.invoke("compile")
    actual_node = actual["nodes"]["model.configuration_fixture.rendered"]
    expected_node = expected["nodes"]["model.configuration_fixture.rendered"]
    assert actual_node["compiled_code"] == expected_node["compiled_code"]
    assert actual_node["depends_on"]["macros"] == expected_node["depends_on"]["macros"]
    assert actual_node["config"]["meta"] == expected_node["config"]["meta"]


NEGATIVE = [
    ("spaced_attribute_does_not_collect", "{% macro probe(mapping) %}{{ mapping . kwargs }}{% endmacro %}", "probe({'kwargs':'value'},extra=2)"),
    ("macro_missing_parameter_hint", "{% macro probe(value) %}{% if not execute %}{% do config(meta={'hint':value.hint}) %}{% endif %}ok{% endmacro %}", "probe()"),
    ("macro_missing_caller_hint", "{% macro probe() %}{% if not execute %}{% do config(meta={'hint':caller.hint}) %}{% endif %}ok{% endmacro %}", "probe()"),
    ("macro_unknown_global_parse", "{% macro probe() %}{% if not execute %}{{ missing_global.child }}{% endif %}ok{% endmacro %}", "probe()"),
    ("macro_unknown_default_parse", "{% macro probe(value=missing_global.child) %}ok{% endmacro %}", "probe()"),
    ("macro_authored_callback_ordinary", "{% macro probe() %}{% call(value) other() %}{% if not execute %}{{ value.child }}{% endif %}ok{% endcall %}{% endmacro %}{% macro other() %}{{ caller() }}{% endmacro %}", "probe()"),

    ("extra_positional", "{% macro probe(value) %}{{ value }}{% endmacro %}", "probe(1,2)"),
    ("extra_keyword", "{% macro probe(value) %}{{ value }}{% endmacro %}", "probe(1,extra=2)"),
    ("duplicate_parameter", "{% macro probe(value) %}{{ value }}{% endmacro %}", "probe(1,value=2)"),
    ("duplicate_expanded_keyword", "{% macro probe() %}{{ kwargs }}{% endmacro %}", "probe(value=1,**{'value':2})"),
    ("literal_does_not_collect", "{% macro probe() %}{{ return('kwargs varargs') }}{% endmacro %}", "probe(1,extra=2)"),
    ("comment_does_not_collect", "{% macro probe() %}{# {{ kwargs }} {{ varargs }} #}ok{% endmacro %}", "probe(extra=2)"),
    ("raw_does_not_collect", "{% macro probe() %}{% raw %}{{ kwargs }}{% endraw %}{% endmacro %}", "probe(extra=2)"),
    ("local_does_not_collect", "{% macro probe() %}{% set kwargs={'label':'local'} %}{{ kwargs.label }}{% endmacro %}", "probe(extra=2)"),
    ("explicit_varargs_no_collection", "{% macro probe(varargs) %}{{ varargs }}{% endmacro %}", "probe(1,2)"),
    ("explicit_kwargs_no_collection", "{% macro probe(kwargs) %}{{ kwargs }}{% endmacro %}", "probe({},extra=2)"),
    ("missing_attribute", "{% macro probe(value) %}{{ value.child }}{% endmacro %}", "probe()"),
    ("missing_arithmetic", "{% macro probe(value) %}{{ value+1 }}{% endmacro %}", "probe()"),
    ("missing_caller", "{% macro probe() %}{{ caller() }}{% endmacro %}", "probe()"),
    ("explicit_caller_requires_default", "{% macro probe(caller) %}{{ caller() }}{% endmacro %}", "probe()"),
]


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("name,macros,expression", NEGATIVE, ids=[case[0] for case in NEGATIVE])
def test_invalid_macro_bindings_fail_like_core(tmp_path, configuration_oracle, request, adapter, name, macros, expression):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write("macros/binding.sql", macros)
    pair.write("models/marts/rendered.sql", "select '{{ " + expression + " }}' as rendered")
    pair.invoke("compile", success=False)

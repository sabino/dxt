"""Actual Core saved builtin methods, dictionary lookup precedence and mutation aliases."""
from __future__ import annotations

import subprocess
from importlib.metadata import version
from pathlib import Path

import pytest

from test_usability_configuration import (
    ConfigurationPair, configuration_oracle, configuration_postgres, configure_adapter,
)

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


def pair_at(tmp_path, configuration_oracle, request, adapter, template):
    assert version("dbt-core") == "1.10.5"
    assert version("dbt-duckdb") == "1.9.6"
    assert version("dbt-postgres") == "1.9.1"
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write("models/marts/rendered.sql", template)
    pair.write("macros/identity.sql", "{% macro identity(value) %}{{ return(value) }}{% endmacro %}")
    return pair


# Each expectation was observed through actual pinned Core model compilation
# on CPython 3.12, independently of the native implementation.
POSITIVE = [
    pytest.param(
        "{% set a={'x':1} %}{% set b={'x':1} %}{% for name in ['items','get','update'] %}{% set method=a[name] %}{% set alias=method %}{{ a==b }}|{{ method==a[name] }}|{{ method is sameas(a[name]) }}|{{ method is sameas(alias) }}|{{ method==b[name] }}|{{ {method:1,a[name]:2,b[name]:3}|length }}|{{ {method:1,a[name]:2}.get(alias) }};{% endfor %}",
        'True|True|False|True|False|2|2;True|True|False|True|False|2|2;True|True|False|True|False|2|2;',
        id='dict_method_identity_hash',
    ),
    pytest.param(
        "{% set a={'x':1} %}{% set get=a.get %}{% set update=a.update %}{% set items=a.items %}{% set view=items() %}{{ get('x') }}|{{ update({'x':2,'y':3}) }}|{{ get('x') }}|{{ get('missing','absent') }}|{{ view|list }}|{{ items()|list }}",
        "1|None|2|absent|[('x', 2), ('y', 3)]|[('x', 2), ('y', 3)]",
        id='dict_alias_calls_mutation',
    ),
    pytest.param(
        "{% set a={'get':'key_get','items':'key_items','update':'key_update'} %}{{ a.get is callable }}|{{ a.items is callable }}|{{ a.update is callable }}|{{ a['get'] }}|{{ a['items'] }}|{{ a['update'] }}|{{ a.get('get') }}|{{ a.items()|length }}",
        'True|True|True|key_get|key_items|key_update|key_get|3',
        id='dict_builtin_attribute_precedence',
    ),
    pytest.param(
        "{% set a={'__dxt_callable':'user_value','__dxt_bound_builtin':true,'__dxt_method_function':'get','__dxt_timezone_builtin':true,'__dxt_receiver':{'x':1}} %}{{ a.__dxt_callable }}|{{ a['__dxt_bound_builtin'] }}|{{ a.get('__dxt_method_function') }}|{{ a|length }}|{{ tojson(a, 'fallback') }}",
        'user_value|True|get|5|{"__dxt_callable": "user_value", "__dxt_bound_builtin": true, "__dxt_method_function": "get", "__dxt_timezone_builtin": true, "__dxt_receiver": {"x": 1}}',
        id='dict_authored_marker_keys',
    ),
    pytest.param(
        "{% set a={'x':1} %}{% set method=a.update %}{% set alias=identity(method) %}{{ alias is sameas(method) }}|{{ alias==a.update }}|{{ alias({'y':2}) }}|{{ a }}|{{ {method:1,alias:2,a.update:3}|length }}",
        "True|True|None|{'x': 1, 'y': 2}|1",
        id='saved_dict_method_macro_alias_mutation',
    ),
    pytest.param(
        "{% set a={'x':1} %}{% set alias=identity(a) %}{% set get=a.get %}{{ alias is sameas(a) }}|{{ alias.get==get }}|{{ alias.update({'x':2}) }}|{{ get('x') }}",
        'True|True|None|2',
        id='saved_dict_receiver_macro_alias_mutation',
    ),
    pytest.param(
        "{% set a=[1,2,1] %}{% set b=[1,2,1] %}{% for name in ['append','index','count','copy'] %}{% set method=a[name] %}{% set alias=identity(method) %}{{ a==b }}|{{ method==a[name] }}|{{ method is sameas(a[name]) }}|{{ method is sameas(alias) }}|{{ method==b[name] }}|{{ {method:1,a[name]:2,b[name]:3}|length }}|{{ {method:1,a[name]:2}.get(alias) }};{% endfor %}",
        'True|True|False|True|False|2|2;True|True|False|True|False|2|2;True|True|False|True|False|2|2;True|True|False|True|False|2|2;',
        id='list_method_identity_hash',
    ),
    pytest.param(
        '{% set a=[1,2,1] %}{% set append=a.append %}{% set index=a.index %}{% set count=a.count %}{% set copy=a.copy %}{% set b=copy() %}{{ append(3) }}|{{ index(1,1) }}|{{ count(1) }}|{{ a }}|{{ b }}|{{ a is sameas(b) }}|{{ a.append==b.append }}',
        'None|2|2|[1, 2, 1, 3]|[1, 2, 1]|False|False',
        id='list_saved_alias_calls_and_copy',
    ),
    pytest.param(
        '{% set a=[1] %}{% set append=a.append %}{% set alias=identity(a) %}{{ alias is sameas(a) }}|{{ alias.append==append }}|{{ alias.append(2) }}|{{ a }}',
        'True|True|None|[1, 2]',
        id='list_saved_receiver_alias',
    ),
    pytest.param(
        '{% set a=fromjson(\'"hello world"\') %}{% set b=fromjson(\'"hello world"\') %}{% for name in [\'upper\',\'split\',\'format\'] %}{% set method=a[name] %}{% set alias=identity(method) %}{{ a==b }}|{{ a is sameas(b) }}|{{ method==a[name] }}|{{ method is sameas(a[name]) }}|{{ method is sameas(alias) }}|{{ method==b[name] }}|{{ {method:1,a[name]:2,b[name]:3}|length }}|{{ {method:1,a[name]:2}.get(alias) }};{% endfor %}',
        'True|False|True|False|True|False|2|2;True|False|True|False|True|False|2|2;True|False|False|False|True|False|3|1;',
        id='string_method_identity_hash',
    ),
    pytest.param(
        "{% set s='hello world' %}{% set upper=s.upper %}{% set split=s.split %}{% set format='{}:{label}'.format %}{{ upper() }}|{{ split(' ',1) }}|{{ format(7,label='value') }}|{{ identity(upper)() }}",
        "HELLO WORLD|['hello', 'world']|7:value|HELLO WORLD",
        id='string_saved_alias_calls',
    ),
    pytest.param(
        "{% set a={'x':1} %}{% for method in [a.items,a.get,a.update,[1].append,'hello'.upper] %}{{ method.__dxt_callable|default('missing') }}|{{ method.__dxt_receiver|default('missing') }}|{{ method.__dxt_method_function|default('missing') }};{% endfor %}",
        'missing|missing|missing;missing|missing|missing;missing|missing|missing;missing|missing|missing;missing|missing|missing;',
        id='builtin_method_private_attributes_opaque',
    ),
    pytest.param(
        '{% set s=fromjson(\'"{x}"\') %}{% set method=s.format_map %}{% set alias=identity(method) %}{{ method==s.format_map }}|{{ method is sameas(s.format_map) }}|{{ method is sameas(alias) }}|{{ {method:1,s.format_map:2,s.format_map:3}|length }}|{{ {method:1}.get(alias) }}|{{ alias({\'x\':7}) }}',
        'False|False|True|3|1|7',
        id='string_format_map_wrapper_identity',
    ),
    pytest.param(
        "{% set a={'x':7} %}{% set get=a['get'] %}{{ get is callable }}|{{ get==a.get }}|{{ get('x') }}|{{ a['items'] is callable }}|{{ a['update']==a.update }}",
        'True|True|7|True|True',
        id='dict_missing_item_falls_back_builtin_method',
    ),
    pytest.param(
        "{% set a={} %}{% set method=a.get %}{% set keys={method:1} %}{{ a.update({'x':7}) }}|{{ keys.get(a.get) }}|{{ a.update({a.get:11}) }}|{{ a.get(method) }}|{{ a.get(a.get) }}|{{ method==a.get }}|{{ keys.get(a.get) }}",
        'None|1|None|11|11|True|1',
        id='dict_method_keys_survive_receiver_mutation',
    ),
    pytest.param(
        '{% set a=[] %}{% set append=a.append %}{% set keys={append:7} %}{{ append(1) }}|{{ keys.get(a.append) }}|{{ a.append(2) }}|{{ keys.get(a.append) }}|{{ append==a.append }}|{{ a }}',
        'None|7|None|7|True|[1, 2]',
        id='list_method_keys_survive_receiver_mutation',
    ),
    pytest.param(
        "{% set a={'x':1} %}{% for method in [a.get,a.items,a.update,[1].append,'hello'.upper,'{x}'.format,'{x}'.format_map] %}{{ method|attr('__dxt_native_bound_method')|default('missing') }}|{{ method|attr('__dxt_bound_method_self')|default('missing') }}|{{ method|attr('__dxt_native_mapping')|default('missing') }};{% endfor %}",
        'missing|missing|missing;missing|missing|missing;missing|missing|missing;missing|missing|missing;missing|missing|missing;missing|missing|missing;missing|missing|missing;',
        id='builtin_methods_attr_private_marker_opaque',
    ),
    pytest.param(
        "{% if not execute %}{% set observed={} | attr('absent') %}{{ config(meta={'attribute_name':observed.name}) }}{% endif %}{% set a={'field':7,'get':'key'} %}{{ a.field }}|{{ a|attr('field') is undefined }}|{{ a|attr('get') is callable }}|{{ (a|attr('get'))('field') }}|{{ a['get'] }}",
        '7|True|True|7|key',
        id='dict_attr_only',
    ),
    pytest.param(
        "{{ config.get is callable }}|{{ config|attr('get') is callable }}|{{ config|attr('items') is undefined }}|{{ config|attr('__dxt_context_object') is undefined }}|{{ flags|attr('get') is undefined }}|{{ model.config|attr('get') is callable }}",
        'True|True|True|True|True|True',
        id='context_markers',
    ),
    pytest.param(
        "{% set a={} %}{% set get=a.get %}{% set before=get|string %}{{ a.update({'x':1}) }}|{{ before==get|string }}|{{ get|string==a.get|string }}",
        'None|True|True',
        id='method_repr_mutation_stable',
    ),
    pytest.param(
        '{% set a=(1,2,1) %}{% set count=a.count %}{{ count(1) }}|{{ count==a.count }}|{{ count is sameas(a.count) }}|{{ {count:1,a.count:2}|length }}',
        '2|True|False|1',
        id='tuple_method_alias',
    ),
    pytest.param(
        '{% set a=set([1]) %}{% set add=a.add %}{% set contains=a.issubset %}{{ add(2) }}|{{ a|sort }}|{{ add==a.add }}|{{ {add:1,a.add:2}|length }}|{{ contains(set([1,2,3])) }}',
        'None|[1, 2]|True|1|True',
        id='set_method_alias',
    ),
    pytest.param(
        "{% set a=modules.datetime.date(2024,1,1) %}{% set method=a|attr('isoformat') %}{{ method() }}|{{ method==a.isoformat }}|{{ method|attr('__dxt_callable') is undefined }}",
        '2024-01-01|True|True',
        id='temporal_attr_method',
    ),
    pytest.param(
        "{% set a={'__dxt_noniterable':true} %}{{ a is mapping }}|{{ a is iterable }}|{{ a.__dxt_noniterable }}|{{ a|attr('__dxt_noniterable') is undefined }}|{{ a|list }}|{{ tojson(a) }}|{{ a|tojson }}",
        'True|True|True|True|[\'__dxt_noniterable\']|{"__dxt_noniterable": true}|{"__dxt_noniterable": true}',
        id='ordinary_boolean_marker_dictionary',
    ),
]


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("template, expected_text", POSITIVE)
def test_saved_builtin_method_objects(tmp_path, configuration_oracle, request, adapter, template, expected_text):
    pair = pair_at(tmp_path, configuration_oracle, request, adapter, template)
    actual, reference = [manifest["nodes"]["model.configuration_fixture.rendered"] for manifest in pair.invoke(flags=["--no-partial-parse"])]
    assert reference["compiled_code"] == expected_text
    assert actual["compiled_code"] == reference["compiled_code"]
    assert actual["config"]["meta"] == reference["config"]["meta"]


NEGATIVE = [
    pytest.param(
        "{% set a={'x':1} %}{{ tojson(a.get,'fallback') }}|{{ tojson({'method':a.items},'fallback') }}|{{ tojson([a.update],'fallback') }}|{{ tojson([1].append,'fallback') }}|{{ tojson('hello'.upper,'fallback') }}",
        'Object of type builtin_function_or_method is not JSON serializable',
        id='saved_builtin_method_json_defaults',
    ),
    pytest.param(
        '{% set index=[1,2].index %}{{ index(3) }}',
        '3 is not in list',
        id='list_index_missing',
    ),
    pytest.param(
        '{% set update={}.update %}{{ update(1) }}',
        "'int' object is not iterable",
        id='saved_dict_update_invalid',
    ),
    pytest.param(
        "{% set a={'x':1} %}{{ a.get|tojson }}",
        'Object of type builtin_function_or_method is not JSON serializable',
        id='saved_builtin_method_json_filter',
    ),
    pytest.param(
        "{% set split='hello'.split %}{{ split('') }}",
        'empty separator',
        id='saved_string_split_invalid_separator',
    ),
    pytest.param(
        '{% set method={}.get %}{{ dict(**method) }}',
        'argument after ** must be a mapping',
        id='kwargs_method',
    ),
    pytest.param(
        '{% set method=modules.datetime.date.fromisoformat %}{{ dict(**method) }}',
        'argument after ** must be a mapping',
        id='kwargs_classmethod',
    ),
]


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("template, expected_error", NEGATIVE)
def test_invalid_saved_builtin_methods(tmp_path, configuration_oracle, request, adapter, template, expected_error):
    pair = pair_at(tmp_path, configuration_oracle, request, adapter, template)
    result, reference = pair.invoke(flags=["--no-partial-parse"], success=False)
    assert expected_error in str(reference.exception)
    assert "Unsupported" not in result.stdout + result.stderr
    assert "InvalidOption" not in result.stdout + result.stderr

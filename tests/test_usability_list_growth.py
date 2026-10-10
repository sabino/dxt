"""Mutable list growth retains Core aliases while scaling to real seed batches."""
import json
from pathlib import Path
import subprocess

import pytest

from test_usability_configuration import (
    ConfigurationPair,
    configuration_oracle,
    configuration_postgres,
    configure_adapter,
)

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope='module', autouse=True)
def native_binary():
    subprocess.run(['zig', 'build'], cwd=ROOT, check=True)


MACROS = (
    '{% macro grow(value) %}{% do value.extend([7,8]) %}{% do value.append(9) %}{{ return(value) }}{% endmacro %}'
    '{% macro collect() %}{{ caller() }}{% endmacro %}'
)


CASES = [
    (
        "{% set x=[] %}{% set alias=x %}{% set box={'child':x} %}{% set nested=(x,) %}"
        '{% do x.append(1) %}{% do alias.extend([2,3]) %}',
        '[x, box.child, nested[0], x is sameas alias]',
        [[1, 2, 3], [1, 2, 3], [1, 2, 3], True],
    ),
    ('{% set x=[1,2] %}{% do x.extend(x) %}', '[x]', [[1, 2, 1, 2]]),
    (
        "{% set x=[] %}{% set alias=x %}{% do x.extend([]) %}{% do x.append('a') %}"
        "{% do x.clear() %}{% do x.append('b') %}{% set popped=x.pop() %}{% do alias.extend([popped,'c']) %}",
        '[x, alias, x is sameas alias]',
        [['b', 'c'], ['b', 'c'], True],
    ),
    (
        "{% set x=[1] %}{% set box={'child':x} %}{% set returned=grow(box.child) %}",
        '[x, box.child, returned, returned is sameas x]',
        [[1, 7, 8, 9], [1, 7, 8, 9], [1, 7, 8, 9], True],
    ),
    (
        '{% set x=[] %}{% set append=x.append %}{% set extend=x.extend %}{% do append(1) %}'
        '{% do extend([2,3]) %}{% set popped=x.pop() %}{% do append(popped) %}',
        '[x, x.append == append, x.append is sameas append]',
        [[1, 2, 3], True, False],
    ),
    (
        "{% set x=[] %}{% set append=x.append %}{% set lookup={append:'direct',(append,):'nested'} %}"
        '{% do append(5) %}{% do x.extend([6,7]) %}',
        '[lookup[x.append], lookup[(x.append,)], x]',
        ['direct', 'nested', [5, 6, 7]],
    ),
    (
        '{% set x=[1] %}{% set copy=x.copy() %}{% do x.extend([2]) %}',
        '[x, copy, x is sameas copy]',
        [[1, 2], [1], False],
    ),
]


def compile_pair(tmp_path, configuration_oracle, request, adapter, source, expected):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('models/marts/mutated.sql', source)
    pair.write('macros/growth.sql', MACROS)
    native_manifest, core_manifest = pair.invoke()
    node_id = 'model.configuration_fixture.mutated'
    assert core_manifest['nodes'][node_id]['compiled_code'] == expected
    assert native_manifest['nodes'][node_id]['compiled_code'] == expected


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('setup, expression, values', CASES)
def test_mutable_list_growth_preserves_aliases_methods_and_copies(tmp_path, configuration_oracle, request, adapter, setup, expression, values):
    compile_pair(tmp_path, configuration_oracle, request, adapter, setup + "select '{{ " + expression + "|tojson }}' as value", "select '" + json.dumps(values) + "' as value")


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_caller_captured_aliases_observe_growth_from_suspended_macro_frame(tmp_path, configuration_oracle, request, adapter):
    source = (
        "{% set x=[] %}{% set alias=x %}{% set box={'child':x} %}select '"
        '{% call collect() %}{% do grow(x) %}{{ [box.child, alias, box.child is sameas x]|tojson }}{% endcall %}'
        "' as value"
    )
    compile_pair(tmp_path, configuration_oracle, request, adapter, source, "select '" + json.dumps([[7, 8, 9], [7, 8, 9], True]) + "' as value")


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_seventy_thousand_bindings_accumulate_through_generic_authored_jinja(tmp_path, configuration_oracle, request, adapter):
    source = (
        '{% set bindings=[] %}{% set alias=bindings %}'
        '{% for row in range(10000) %}{% do bindings.extend([row,1,2,3,4,5,6]) %}{% endfor %}'
        "select '{{ [bindings|length, bindings[:7], bindings[-7:], alias is sameas bindings]|tojson }}' as value"
    )
    values = [70000, [0, 1, 2, 3, 4, 5, 6], [9999, 1, 2, 3, 4, 5, 6], True]
    compile_pair(tmp_path, configuration_oracle, request, adapter, source, "select '" + json.dumps(values) + "' as value")

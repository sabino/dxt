"""One-shot standard filters, argument timing, and Unicode against pinned Core."""
import subprocess
import json

import pytest

from test_usability_commands import core_runner
from test_usability_expression_types import ROOT, DXT, compare, write_project


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


@pytest.mark.parametrize("expression", [
    "[1,2,3,4,5] | batch(2) | list", "[1,2,3,4,5] | batch(2,'x') | list",
    "[1,2,3,4] | batch(2,'x') | list", "[] | batch(2,'x') | list",
    "'é好😀X' | batch(2) | list", "{'a':1,'b':2,'c':3} | batch(2) | list",
    "zip([1,2],[3,4]) | batch(1) | list", "[1,2,3] | batch(0) | list",
    "[1,2,3] | batch(-1,'x') | list", "[1,2,3] | batch(none) | list",
    "[1,2,3] | batch('2') | list", "[1,2,3] | batch(1.5) | list",
    "[1,2,3,4] | batch(2.0) | list", "[1,2] | batch(2.0,'x') | list",
    "[1,2] | batch(true) | list", "[1,2] | batch(false) | list",
    "[1,2] | batch(linecount=2,fill_with=0) | list", "[] | batch(none,'x') | list",
    "[1,2,3,4,5] | slice(2) | list", "[1,2,3,4,5] | slice(2,'x') | list",
    "[1,2,3,4] | slice(2,'x') | list", "[1,2] | slice(4,'x') | list",
    "[] | slice(2,'x') | list", "[1,2] | slice(-2,'x') | list",
    "'é好😀X' | slice(3) | list", "[1,2] | slice(true) | list",
    "{'a':1,'b':2,'c':3} | slice(slices=2,fill_with='-') | list",
    "none | map() | list", "0 | map() | list", "[] | map() | list",
    "[] | map('unknown') | list", "[1,2] | map(attribute=none) | list",
    "[1,2] | map(attribute=none,default=9) | list",
    "[{'a':{'b':1}},{}] | map(attribute='a.b',default={'b':7}) | list",
    "[{'a':{}},{}] | map(attribute='a.b',default={'b':7}) | list",
    "[{'x':none},{}] | map(attribute='x',default=7) | list",
    "[{'x':1},{}] | map(attribute='x',default=none) | select('defined') | list",
    "[['a','b'],['c','d']] | map(attribute='١') | list",
    "[['a','b'],['c','d']] | map(attribute='０') | list",
    "[{'-1':'a'},{'-1':'b'}] | map(attribute='-1') | list",
    "[['a','b']] | map(attribute='-1',default='missing') | list",
    "[[1]] | map(attribute='999999999999999999999') | list",
    "['aaa','abc'] | map('replace','a','z',1) | list",
    "['ab','é好'] | map('replace','','-',2) | list",
    "['A','B'] | map('lower') | join('-')",
    "[] | selectattr() | list", "none | selectattr() | list",
    "[0,1,2,'',none] | select(unused=true) | list",
    "[0,1,2,'',none] | reject | list", "[1,2,3,4] | select('odd') | list",
    "[1,2,3,4] | reject('even') | list", "[{'x':1},{}] | selectattr('x') | list",
    "[['a'],[]] | selectattr(0,'defined') | list",
    "[1,1.0,true,0,false,2] | unique | list",
    "['É','é','A','a'] | unique | list", "['É','é'] | unique(case_sensitive=true) | list",
    "[(1,2),(1.0,2),(2,3)] | unique | list",
    "[{'x':1},{'x':1},{}] | unique(attribute='x') | list",
    "[] | unique(attribute='²')",  # construction does not prepare the getter
    "[1] | map('unknown') is iterable", "[1] | select('unknown') is not sequence",
    "([1] | unique) is not mapping", "([] | batch(2)) is not sequence",
    "([] | map) is iterable and ([] | map) is not sequence",
    "[1,2] | map('lower') | first",
    "['ff','10'] | map('int',base=16) | list",
    "['1.2','bad'] | map('float',default='fallback') | list",
    "['  a  ','é'] | map('trim',chars=none) | list",
    "[none,0,2] | map('default',9,boolean=true) | list",
    "[{'-1':1},{'-1':2}] | sort(attribute='-1') | list",
    "[['a','b'],['c','d']] | sort(attribute='١') | list", "[] | select | first | default('empty')",
    "[3,1,2] | map('int') | sort", "[3,1,2] | select | min",
    "[3,1,2] | select | max", "[1,2,3] | select | sum",
])
def test_filter_iterators_match_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    # Avoid generator repr (its memory address is deliberately not stable).
    if expression == "[] | unique(attribute='²')":
        expression += " is iterable"
    write_project(root, expression)
    compare(root, core_runner)


@pytest.mark.parametrize("expression", [
    "[1] | batch()", "[] | batch(1,unknown=2)", "[] | batch(1,linecount=2)",
    "none | batch(2) | list", "[1] | batch(none,0) | list",
    "[1] | batch('2',0) | list", "[1] | batch(2.0,0) | list",
    "[1] | slice()", "[] | slice(1,unknown=2)", "[] | slice(1,slices=2)",
    "[] | slice(0) | list", "[] | slice(false) | list", "[1] | slice(2.0) | list",
    "[] | slice(2.0) | list", "none | slice(2) | list", "[1] | slice(none) | list",
    "[1] | map() | list", "zip([],[]) | map() | list",
    "[1] | map('unknown') | list", "[1] | map(none) | list",
    "[1] | map('lower',unknown=2) | list", "[1] | map(attribute=0,unknown=2) | list",
    "[{}] | map(attribute='a.b') | list", "[{}] | map(attribute='a.b',default=none) | list",
    "[[1]] | map(attribute='²') | list",
    "[1] | selectattr() | list", "[1] | selectattr(attribute='x') | list",
    "[1] | select('unknown') | list", "[1] | select(none) | list",
    "[1] | select('odd',unknown=2) | list", "[1] | unique(unknown=2)",
    "none | unique | list", "[[1]] | unique | list", "[{}] | unique | list",
    "[(1,[])] | unique | list", "[] | unique(attribute='²') | list",
    "[1] | map('string') | length", "[1] | map('string') | last",
    "[1] | map('list',unknown=2) | list",
    "[1] | map('int',unknown=2) | list", "[1] | map('float',unknown=2) | list",
    "[1] | map('trim',chars=2) | list", "[1] | map('default',unknown=2) | list",
    "[[1]] | map('sum',unknown=2) | list", "[[1]] | map('join',unknown=2) | list",
])
def test_filter_iterator_errors_match_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    write_project(root, expression)
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root), "--select", "value"]
    actual = subprocess.run([DXT, *common], capture_output=True, text=True)
    oracle = core_runner.invoke(["--quiet", *common, "--no-partial-parse"])
    assert actual.returncode != 0, actual.stdout
    assert not oracle.success


@pytest.mark.parametrize("template", [
    "{% set stream = ['A','B','C']|map('lower') %}{% set alias=stream %}{{ [stream|first,alias|first,stream|list,alias|list] }}",
    "{% set stream=[1,2,1,3]|unique %}{{ [stream|first,stream|list,stream|list] }}",
    "{% set stream=[1,2,3,4]|select('odd') %}{{ [stream|first,stream|list,stream|list] }}",
    "{% set source=zip([1,2,3,4],[5,6,7,8]) %}{% set batches=source|batch(2) %}{{ [batches|first,source|list,batches|list] }}",
    "{% set source=zip([1,2,3],[4,5,6]) %}{% set slices=source|slice(2) %}{{ [slices|first,source|list,slices|list] }}",
    "{% set source=zip([1,2,3],[4,5,6]) %}{% set stream=source|map(attribute=0) %}{{ [source|first,stream|list] }}",
    "{% set stream=[fromyaml('.nan'),fromyaml('.nan')]|unique %}{{ stream|list|length }}",
    "{% set x=fromyaml('.nan') %}{{ [x,x]|unique|list|length }}",
    "{% set stream=[1,'bad']|map('int') %}{{ [stream|first,stream|list] }}",
])
def test_filter_aliases_and_pull_order_match_core(tmp_path, core_runner, template):
    root = tmp_path / "project"
    write_project(root, "0")
    (root / "models/value.sql").write_text("select '" + template + "' as value")
    compare(root, core_runner)


@pytest.mark.parametrize("template", [
    "{% macro take_first(stream) %}{% for row in stream %}{{ return(row) }}{% endfor %}{{ return('empty') }}{% endmacro %}{{ take_first([[1],none]|map('list')) }}",
    "{% macro take_first(stream) %}{% for row in stream %}{{ return(row) }}{% endfor %}{{ return('empty') }}{% endmacro %}{{ take_first([1,{}]|unique) }}",
    "{% set stream=[1,2,3]|map('int') %}{{ [2 is in(stream),stream|list] }}",
    "{% set stream=[1,2,3]|map('int') %}{{ [2 in stream,stream|list] }}",
    "{% set source=[1,2,3]|map('int') %}{{ [[2,1,3]|select('in',source)|list,source|list] }}",
    "{{ [1,2]|batch(fromyaml('.nan'),0)|list }}",
    "{% set stream=[1,2,3]|reverse %}{{ [stream is sequence,stream|first,stream|list,stream|list] }}",
])
def test_filter_consumer_timing_matches_core(tmp_path, core_runner, template):
    root = tmp_path / "project"
    write_project(root, "0")
    if template.startswith("{% macro "):
        declaration, template = template.split("{% endmacro %}", 1)
        (root / "macros").mkdir(exist_ok=True)
        (root / "macros/timing.sql").write_text(declaration + "{% endmacro %}")
    (root / "models/value.sql").write_text("select '" + template + "' as value")
    compare(root, core_runner)


def test_filter_missing_paths_use_parse_capture_context(tmp_path, core_runner):
    root = tmp_path / "project"
    write_project(root, "1")
    (root / "models/value.sql").write_text("""
{% if not execute %}
{% set missing = [{}]|map(attribute='a.b')|first %}
{{ config(meta={'captured_name': missing.name, 'same_alias': missing is sameas(missing)}) }}
{% endif %}
select '1' as rendered
""")
    compare(root, core_runner)
    actual = json.loads((root / "native/manifest.json").read_text())["nodes"]["model.expressions.value"]["config"]["meta"]
    expected = json.loads((root / "core/manifest.json").read_text())["nodes"]["model.expressions.value"]["config"]["meta"]
    assert actual == expected == {'captured_name': 'a', 'same_alias': True}

"""Forcing aggregates and getter stages against the pinned actual Core CLI."""
import subprocess

import pytest

from test_usability_commands import core_runner
from test_usability_expression_types import ROOT, DXT, compare, write_project


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


@pytest.mark.parametrize("expression", [
    "[] | min(attribute='²') | default('empty')",
    "[] | max(attribute='²') | default('empty')",
    "zip([],[]) | min(attribute='²') | default('empty')",
    "[] | sum(start=none)", "[] | sum(start=[])", "[] | sum(start=())",
    "[[1],[2,3]] | sum(start=[])", "[(1,),(2,3)] | sum(start=())",
    "[true,false,3] | sum", "[1,2,3] | select('odd') | sum(start=7)",
    "[{'x':1},{'x':2}] | sum(attribute='x',start=7)",
    "[[1,2],[3,4]] | sum(attribute='١')",
    "[{'-1':1},{'-1':2}] | sum(attribute='-1')",
    "[] | join(none)", "[1,true,none] | join(none)",
    "[{'x':'é'},{'x':'好'}] | join('-',attribute='x')",
    "[['a','b'],['c','d']] | join('-',attribute='١')",
    "[{}] | join(attribute='x')", "['A','b','a'] | select | min",
    "['A','b','a'] | select | max", "['A','b','a'] | min(case_sensitive=true)",
    "[(1,2),(1,1)] | max", "[2,fromyaml('.nan'),1] | min",
    "[2,fromyaml('.nan'),1] | max", "[] | sort(attribute='x,y')",
    "zip(['a','b'],['é 好','c/d']) | urlencode",
    "[['a','1'],['b','2']] | map('list') | urlencode",
    "[zip(['a','1'],[])] | select('false') | urlencode",
    "[zip(['a','1']) | map(attribute=0)] | urlencode",
])
def test_aggregate_results_match_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    write_project(root, expression)
    compare(root, core_runner)


@pytest.mark.parametrize("expression", [
    "[] | sum(start='')", "[] | sum(start=fromyaml('!!binary YQ=='))",
    "[1] | sum(start='x')", "[1] | sum(start=none)",
    "[] | sum(attribute='²')", "[] | join(attribute='²')",
    "[] | sort(attribute='²')", "[] | sort(attribute='x,²')",
    "[1] | min(attribute='²')", "[1] | max(attribute='²')",
    "none | min", "none | max", "none | sum", "none | join",
    "[{}] | sum(attribute='x')", "[{'x':1},{}] | min(attribute='x')",
    "[{'x':1},{}] | max(attribute='x')", "[{}] | join(attribute='x.y')",
    "[1,2] | map('list') | sum", "[1,2] | map('list') | urlencode",
    "[zip([1,2,3,4])] | urlencode", "[zip([1])] | urlencode",
    "[] | join(unknown=1)", "[] | sum(unknown=1)",
    "[] | min(unknown=1)", "[] | max(false,case_sensitive=true)",
])
def test_aggregate_errors_match_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    write_project(root, expression)
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root), "--select", "value"]
    actual = subprocess.run([DXT, *common], capture_output=True, text=True)
    oracle = core_runner.invoke(["--quiet", *common, "--no-partial-parse"])
    assert actual.returncode != 0, actual.stdout
    assert not oracle.success


@pytest.mark.parametrize("template", [
    "{% set source=[3,1,2]|map('int') %}{{ [source|min,source|list] }}",
    "{% set source=[3,1,2]|map('int') %}{{ [source|max,source|list] }}",
    "{% set source=[3,1,2]|map('int') %}{{ [source|sum,source|list] }}",
    "{% set source=['a','b']|map('string') %}{{ [source|join('-'),source|list] }}",
    "{% set source=zip(['a','b'],[1,2]) %}{{ [source|urlencode,source|list] }}",
    "{% set pair=zip(['a','é 好'])|map(attribute=0) %}{{ [[pair]|urlencode,pair|list] }}",
])
def test_aggregate_consumes_aliases_once(tmp_path, core_runner, template):
    root = tmp_path / "project"
    write_project(root, "0")
    (root / "models/value.sql").write_text("select '" + template + "' as value")
    compare(root, core_runner)

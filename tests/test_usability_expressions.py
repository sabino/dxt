"""Native Jinja collection expressions through unchanged pinned Core projects."""
import json
import subprocess
from pathlib import Path

import pytest

from test_usability_commands import core_runner
from test_usability_artifacts import contracts

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out/bin/dxt"


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


EXPRESSIONS = [
    "['A','B'] | map('lower') | list",
    "[[1,2],[3,4]] | map(attribute=0) | list",
    "[{'name':'Ada'},{}] | map(attribute='name',default='missing') | list",
    "[{'x':{'n':1}},{'x':{'n':4}}] | selectattr('x.n','gt',2) | map(attribute='x.n') | list",
    "[none,0,1,2] | reject('none') | select | list",
    "[{'n':true},{'n':false},{}] | rejectattr('n') | list",
    "['b','A','a','C'] | sort(reverse=true) | list",
    "[{'age':2,'n':'a'},{'age':1,'n':'b'},{'age':2,'n':'c'}] | sort(attribute='age',reverse=true) | map(attribute='n') | list",
    "['A','a','B','b'] | unique | list",
    "['A','a','B','b'] | unique(case_sensitive=true) | list",
    "[{'n':1},{'n':3}] | sum(attribute='n',start=10)",
    "[{'n':'Ada'},{'n':'Bob'}] | join(', ',attribute='n')",
    "[4,2,3] | min",
    "['b','A','c'] | max",
    "[0,1,2,3,4][1:-1:2]",
    "[0,1,2,3,4][-2:0:-1]",
    "'aé好'[1:][::-1]",
    "zip([1,2],[3,4,5]) | list | map(attribute=0) | list",
    "dict({'x':1},x=2,y=3)",
    "{} is mapping and [1,2] is sequence and 3 is odd",
    "4 is divisibleby(2) and 3 is not equalto(2)",
    "1 / 0 if false else 'chosen'",
    "'chosen' if true else 1 / 0",
    "missing | default(default_value='fallback')",
    "0 | default(boolean=true,default_value=7)",
    "('chosen' if true else 1 / 0) ~ '!'",
    "[1 if false else 2, 3 if true else 1 / 0]",
    "dict(a=1 if true else 1 / 0,b='yes' if true)",
    "{'a': 7 if true else 1 / 0}",
    "false and 1 / 0",
    "true or 1 / 0",
    "'chosen' or missing_function()",
    "none if false else 'selected' if true else 1 / 0",
    "{'a':1,'b':2}.get('missing',9)",
    "{'a':1,'b':2}.keys() | list",
    "{'a':1,'b':2}.values() | list",
    "{'a':1,'b':2}.items() | map(attribute=0) | list",
    "[1,2,1].count(1)",
    "[1,2,1].index(1,1)",
    "[1,2].copy()",
    "' abC '.strip().lower()",
    "'ééhié'.strip('é')",
    "'abcabc'.startswith('bc',1)",
    "'abcabc'.endswith('bc',0,-1)",
    "'éhi好hi'.find('hi',2)",
    "'abcabc'.rfind('bc')",
    "'abc'.count('')",
    "'abc'.find('',4)",
    "'abc'.replace('','-',2)",
    "'aba'.replace('a','z',1)",
    "', '.join(['a','b'])",
    "' a  b c '.split()",
    "' a b c '.split(None,1)",
    "' a b c '.rsplit(maxsplit=1)",
    "'a,,b,'.split(',')",
    "'a,,b,'.rsplit(',',2)",
    "' a b '.split(None,0)",
    "' a b '.rsplit(None,0)",
    "'aé好'[1]",
    "'aé好'[-1]",
    "[1,2][1.2] | default('undefined')",
]


def write_project(root, expression):
    root.mkdir()
    (root / "models").mkdir()
    (root / "dbt_project.yml").write_text("name: expressions\nversion: '1.0'\nprofile: expressions\n")
    (root / "profiles.yml").write_text(f"expressions:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n      path: {root / 'warehouse.duckdb'}\n      schema: main\n")
    (root / "models/value.sql").write_text("select '{{ " + expression + " }}' as rendered")


@pytest.mark.parametrize("expression", EXPRESSIONS)
def test_native_expression_matches_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    write_project(root, expression)
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root), "--select", "value"]
    result = subprocess.run([DXT, *common, "--target-path", "native"], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    oracle = core_runner.invoke(["--quiet", *common, "--target-path", "core", "--no-partial-parse"])
    assert oracle.success, oracle.exception
    actual = json.loads((root / "native/manifest.json").read_text())["nodes"]["model.expressions.value"]["compiled_code"]
    expected = json.loads((root / "core/manifest.json").read_text())["nodes"]["model.expressions.value"]["compiled_code"]
    assert actual == expected
    contracts.assert_artifact(root / "native/manifest.json")
    contracts.assert_artifact(root / "native/run_results.json")


@pytest.mark.parametrize("expression", ["[1,2][::0]", "[1,'a'] | sort", "[1,2] | map() | list", "[1,2].index(9)", "'abc'.index('z')", "{}.get('x', default=1)", "'abc'.split(foo=1)", "'abc'.split(',',sep=',')", "'abc'.split('')"])
def test_invalid_collection_expression_fails_like_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    write_project(root, expression)
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root), "--select", "value"]
    actual = subprocess.run([DXT, *common], text=True, capture_output=True)
    oracle = core_runner.invoke(["--quiet", *common, "--no-partial-parse"])
    assert actual.returncode != 0 and not oracle.success
    assert not (root / "warehouse.duckdb").exists()

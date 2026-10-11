"""Pinned Core lexicographic ordering and aggregation contracts."""
import subprocess

import pytest

from test_usability_commands import core_runner
from test_usability_expression_types import ROOT, DXT, compare, write_project


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


@pytest.mark.parametrize("expression", [
    "[1,2] < [1,3]", "[1,2] <= [1,2]", "[1,2] >= [1,2]", "[1,2] > [1]",
    "[] < [none]", "[none] >= [none]", "() < (none,)", "(1,2) > (1,1)",
    "[1,[2,3]] < [1,[2,4]]", "((1,2),3) < ((1,3),0)",
    "[{'a':1}] <= [{'a':1}]", "[1.0,true] <= [1,1]",
    "[9007199254740993] > [9007199254740992.0]",
    "['é'] > ['e']", "[[1,3],[1],[1,2],[]] | sort",
    "[(2,),(1,3),(1,2),(1,)] | sort(reverse=true)",
    "[[],[0],[0,0],[-1]] | min", "[[],[0],[0,0],[-1]] | max",
    "[{'n':1,'v':'first'},{'n':1,'v':'second'}] | min(attribute='n')",
    "[{'n':1,'v':'first'},{'n':1,'v':'second'}] | max(attribute='n')",
    "[{'a':'B','b':0},{'a':'a','b':2},{'a':'A','b':1}] | sort(attribute='a,b')",
    "[{'a':'B','b':0},{'a':'a','b':2},{'a':'A','b':1}] | sort(attribute='a,b',case_sensitive=true)",
    "[{'a':[1,3]},{'a':[1,2]}] | sort(attribute='a.0,a.1')",
    "[[1,3],[1,2]] | min(attribute=true)",
    "[[1,3],[1,2]] | sort(attribute=true)",
    "[(0,0),(1,none),(1,2)] | min",
    "[none] | sort", "[{},{}] | sort", "[[],[]] | sort", "[] | max | default('empty')",
    "[2,fromyaml('.nan'),1] | sort", "[2,fromyaml('.nan'),1] | sort(reverse=true)",
    "[fromyaml('.nan'),2,1] | min", "[fromyaml('.nan'),2,1] | max",
    "[fromyaml('.nan'),fromyaml('.nan')] | sort",
    "[(fromyaml('.nan'),1),(fromyaml('.nan'),0)] | sort",
    "[(fromyaml('!!binary Yg=='),),(fromyaml('!!binary YQ=='),)] | sort",
])
def test_sequence_ordering_matches_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    write_project(root, expression)
    compare(root, core_runner)


@pytest.mark.parametrize("expression", [
    "[] < ()", "[1] < (1,)", "[[1]] < [(1,)]", "[none] < [1]",
    "[{'a':1}] < [{'a':2}]", "[(0,0),(1,none),(1,2)] | sort",
    "[(1,none),(1,2)] | min", "[(0,0),(1,none),(1,2)] | max",
    "[1,2] | sort(unexpected=true)", "[1,2] | min(unexpected=true)",
    "[1,2] | max(true,false,none)", "[1,2] | sort(false,reverse=true)",
    "[1,2] | unique(unexpected=true) | list",
])
def test_sequence_ordering_errors_match_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    write_project(root, expression)
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root), "--select", "value"]
    actual = subprocess.run([DXT, *common], capture_output=True, text=True)
    oracle = core_runner.invoke(["--quiet", *common, "--no-partial-parse"])
    assert actual.returncode != 0, actual.stdout
    assert not oracle.success

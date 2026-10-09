"""Jinja JSON filter behavior used by unchanged dbt Python scaffolding macros."""
import subprocess

import pytest

from test_usability_commands import core_runner
from test_usability_expression_types import compare, write_project, ROOT, DXT


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


@pytest.mark.parametrize("expression", [
    "{'z':1,'a':2}|tojson",
    "[1,1.0,-0.0,true,none]|tojson",
    "(1,2)|tojson",
    "9007199254740993|tojson",
    "'<é好😀>&\\\''|tojson",
    "'a\\x00\\b\\f\\t\\n\\r'|tojson",
    "{'b':{'é':3},'a':[1,2]}|tojson(indent=2)",
    "[1,2]|tojson(0)",
    "[1,2]|tojson(-2)",
    "{'a':[1,2]}|tojson(indent='\\t')",
    "{}|tojson",
    "[]|tojson(indent=2)",
    "1e309|tojson",
    "{10:'ten',2:'two'}|tojson",
    "{none:'null'}|tojson",
    "{1.5:'float',-1:'negative',2:'two'}|tojson",
    "{9007199254740993:'exact',9007199254740992.0:'float'}|tojson",
    "tojson({none:'null',true:'boolean',2.0:'float'})",
    "[var('nan_text','nan')|float]|tojson",
    "tojson([var('nan_text','nan')|float])",
])
def test_native_tojson_matches_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    write_project(root, expression)
    compare(root, core_runner)


@pytest.mark.parametrize("expression", ["[1]|tojson(indent=2.0)", "missing|tojson", "{'a':1}.keys()|tojson", "[1]|tojson(1,2)", "[1]|tojson(foo=1)", "{1:'number','2':'string'}|tojson", "{none:'null',1:'number'}|tojson", "{true:'boolean',none:'null'}|tojson", "{(1,2):'tuple'}|tojson", "tojson({(1,2):'tuple'})"])
def test_native_tojson_errors_match_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    write_project(root, expression)
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root), "--select", "value"]
    native = subprocess.run([DXT, *common], text=True, capture_output=True)
    oracle = core_runner.invoke(["--quiet", *common, "--no-partial-parse"])
    assert native.returncode != 0
    assert not oracle.success

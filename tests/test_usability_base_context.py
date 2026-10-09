"""Pinned Core comparisons for native BaseContext helper signatures and values."""
import subprocess

import pytest

from test_usability_commands import core_runner
from test_usability_expression_types import ROOT, DXT, compare, write_project


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


@pytest.mark.parametrize("expression", [
    "local_md5('hello world')",
    "local_md5(value='é好😀')",
    "local_md5('')",
    "tojson({'b':2,'a':1}, sort_keys=true)",
    "tojson({'b':2,'a':1}, 'fallback', true)",
    "tojson(value={10:'ten',2:'two'}, sort_keys=true)",
    "fromjson(string='invalid', default={'fallback':true})",
    "fromjson('[9007199254740993123456789,1.0,null,true]')",
    "fromjson('{\"same\":1,\"same\":2}')",
    "set([1,1.0,true,2])|list|sort",
    "set('é好é')|list|sort",
    "set({'b':2,'a':1})|list|sort",
    "set(none, default='fallback')",
    "set([[1]], 'fallback')",
    "set_strict(value=['b','a','b'])|list|sort",
    "zip_strict([1,2], 'é好')|list",
    "zip_strict()|list",
    "diff_of_two_dicts({'READ':['Alice','BOB'],'Write':['ß']}, {'read':['ALICE']})",
])
def test_base_context_values_match_core(tmp_path, core_runner, expression):
    project = tmp_path / "project"
    write_project(project, expression)
    compare(project, core_runner)


@pytest.mark.parametrize("expression", [
    "local_md5(none)", "local_md5()", "local_md5('a', value='b')",
    "tojson({(1,2):'bad'}, 'fallback')", "tojson({'a':1}, unknown=true)",
    "fromjson(none, 'fallback')", "fromjson(value='invalid')", "set_strict(none)", "set_strict([[1]])",
    "set()", "set_strict([1], default='fallback')", "zip_strict(none)",
    "zip_strict([], default=[])"
])
def test_base_context_errors_match_core(tmp_path, core_runner, expression):
    project = tmp_path / "project"
    write_project(project, expression)
    common = ["compile", "--project-dir", str(project), "--profiles-dir", str(project), "--select", "value"]
    actual = subprocess.run([DXT, *common], capture_output=True, text=True)
    expected = core_runner.invoke(["--quiet", *common, "--no-partial-parse"])
    assert actual.returncode != 0
    assert not expected.success


def test_base_context_callable_aliases_and_shared_set_members_match_core(tmp_path, core_runner):
    project = tmp_path / "project"
    write_project(project, "tojson([digest('hello'), decoder('bad', 3), values|list|sort])")
    model = project / "models/value.sql"
    model.write_text("{% set digest=local_md5 %}{% set decoder=fromjson %}{% set values=set_strict([2,1,2]) %}" + model.read_text())
    compare(project, core_runner)

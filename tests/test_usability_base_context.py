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
    "set(missing)|list", "set_strict(missing)|list",
    "zip(missing)|list", "zip_strict(missing)|list",
    "zip(none, default=['fallback'])",
    "set_strict([1,2]) == set_strict([2,1])",
    "set_strict([1]) < set_strict([1,2])",
    "2 in set_strict([1,2])",
    "set_strict([]) is iterable and set_strict([]) is not mapping",
    "set_strict([1,2]).union([2,3])|list|sort",
    "set_strict([1,2]).intersection([2,3])|list|sort",
    "set_strict([1,2]).difference([2,3])|list|sort",
    "set_strict([1,2]).symmetric_difference([2,3])|list|sort",
    "set_strict([1]).issubset([1,2])",
    "set_strict([1,2]).issuperset([1])",
    "set_strict([1]).isdisjoint([2])",
    # Sets have no iteration order; sort after conversion to retain every key/value.
    "dict(set_strict([(1,'one'),(2,'two')]))|dictsort",
    "set_strict([1])[0]|default('undefined')",
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
    , "set_strict([1]).add([2])", "set_strict([1]).remove(2)",
    "set_strict([1]).union(none)", "set_strict([1])[:1]",
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


@pytest.mark.parametrize("statements, expression", [
    ("{% set values=set_strict([1,2]) %}{% set alias=values %}{% do alias.add(3) %}{% do alias.discard(9) %}", "values|list|sort"),
    ("{% set values=set_strict([1,2]) %}{% set alias=values %}{% do alias.update([2,3]) %}{% do alias.difference_update([1]) %}", "values|list|sort"),
    ("{% set values=set_strict([1,2,3]) %}{% do values.intersection_update([2,3,4]) %}{% do values.symmetric_difference_update([3,4]) %}", "values|list|sort"),
    ("{% set values=set_strict([1]) %}{% set copy=values.copy() %}{% do copy.clear() %}", "[values|list, copy|list]"),
    ("{% set values=zip([1,2],[3,4]) %}", "[values|list, values|list]"),
    ("{% set zipper=zip %}{% set values=zipper(none, default=[3]) %}", "values"),
])
def test_base_context_mutable_aliases_and_iterators_match_core(tmp_path, core_runner, statements, expression):
    project = tmp_path / "project"
    write_project(project, expression)
    model = project / "models/value.sql"
    model.write_text(statements + model.read_text())
    compare(project, core_runner)


@pytest.mark.parametrize("expression", [
    "fromyaml('a: [1, yes, null]\\nb: 0x10')",
    "fromyaml('')",
    "fromyaml(value='[bad', default={'fallback':true})",
    "fromyaml('[broken', ['fallback'])",
    "fromyaml('!!python/object:unsafe {}', 'safe')",
    "fromyaml('{1: integer, true: boolean, \"1\": string}').items()|list",
    "fromyaml('{defaults: &v {a: 1, b: 2}, result: {<<: *v, b: 3}}')",
    "fromyaml('!!pairs [{a: 1}, {b: 2}]')",
    "fromyaml('!!omap [{a: 1}, {b: 2}]')",
    "fromyaml('!!set {b: null, a: null}')|list|sort",
    "fromyaml('2020-01-02').isoformat()",
    "fromyaml('2020-01-02T03:04:05.123Z').isoformat()",
    "fromyaml('!!binary SGVsbG8=').decode()",
    "fromyaml('!!binary w6k=').decode('utf8')",
    "fromyaml('!!binary AP8=').hex()",
    "set([fromyaml('.nan'),fromyaml('.nan')])|length",
    "toyaml({'values':[true,none,1,1.0],'str':'yes'})",
    "toyaml({'b':2,'a':1}, sort_keys=true)",
    "toyaml(value={'b':2,'a':1}, default='fallback', sort_keys=true)",
    "toyaml({10:'ten',2:'two'}, sort_keys=true)",
    "toyaml({1:'number','a':'string'}, sort_keys=true)",
    "toyaml((1,2))",
    "toyaml([])", "toyaml({})", "toyaml(none)", "toyaml('')",
    "toyaml(1)", "toyaml(true)", "toyaml(1.25)", "toyaml('plain')",
    "toyaml('yes')", "toyaml('é好😀')", "toyaml('first\\nsecond\\n')",
    "toyaml([1e20,1e-6,1.0,-0.0])",
    "toyaml(fromyaml('[.nan,.inf,-.inf]'))",
    "toyaml(fromyaml('2020-01-02'))",
    "toyaml(fromyaml('2020-01-02T03:04:05.123Z'))",
    "toyaml(fromyaml('!!binary SGVsbG8='))",
    "toyaml(fromyaml('{first: &v [1], second: *v}'))",
    "toyaml(fromyaml('&root [*root]'))",
    "toyaml(local_md5, default='fallback')",
])
def test_yaml_helpers_preserve_core_safe_types_and_output_styles(tmp_path, core_runner, expression):
    project = tmp_path / "project"
    write_project(project, expression)
    compare(project, core_runner)


@pytest.mark.parametrize("expression", [
    "fromyaml()", "fromyaml(string='text')", "toyaml()", "toyaml(1, bad=true)",
    "fromyaml(none,'fallback')", "fromyaml(1,'fallback')", "fromyaml([], 'fallback')",
])
def test_yaml_helper_signature_errors_match_core(tmp_path, core_runner, expression):
    project = tmp_path / "project"
    write_project(project, expression)
    common = ["compile", "--project-dir", str(project), "--profiles-dir", str(project), "--select", "value"]
    actual = subprocess.run([DXT, *common], capture_output=True, text=True)
    expected = core_runner.invoke(["--quiet", *common, "--no-partial-parse"])
    assert actual.returncode != 0
    assert not expected.success

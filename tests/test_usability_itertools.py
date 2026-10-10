"""The restricted dbt itertools provider preserves native lazy stream identity."""
import json
import subprocess
import sys

import pytest

from test_usability_commands import core_runner
from test_usability_expression_types import compare, contracts, write_project, ROOT, DXT


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


EXPRESSIONS = [
    "modules.itertools|list",
    "modules.itertools.count()|string", "modules.itertools.count(1,2)|string",
    "modules.itertools.count(true,false)|string", "modules.itertools.count(1.0)|string",
    "modules.itertools.count(1,1.0)|string", "modules.itertools.count(2**100)|string",
    "modules.itertools.repeat('x')|string", "modules.itertools.repeat('x',3)|string",
    "modules.itertools.repeat('x',-2)|string", "modules.itertools.repeat([1,2],1)|string",
    "modules.itertools.chain({'__dxt_sequence_kind':'itertools_count'})|list",
    "modules.itertools.count().current is undefined",
    "modules.itertools.count()['current'] is undefined",
    "modules.itertools.count()['__dxt_native_sequence'] is undefined",
    "modules.itertools.count()|attr('current') is undefined",
    "modules.itertools.count is callable and modules.itertools.chain is not iterable",
    "modules.itertools.count|string",
    "modules.itertools.tee|string",
    "modules.itertools.islice(modules.itertools.count(),5)|list",
    "modules.itertools.islice(modules.itertools.count(2,3),4)|list",
    "modules.itertools.islice(modules.itertools.count(start=-2,step=3),4)|list",
    "modules.itertools.islice(modules.itertools.count(0.5,0.25),4)|list",
    "modules.itertools.islice(modules.itertools.count(true,false),3)|list",
    "modules.itertools.islice(modules.itertools.count(true),3)|list",
    "modules.itertools.islice(modules.itertools.count(true,true),3)|list",
    "modules.itertools.islice(modules.itertools.count(true,1.0),3)|list",
    "modules.itertools.islice(modules.itertools.count(modules.re.ASCII),3)|list",
    "modules.itertools.islice(modules.itertools.count(modules.re.ASCII,0),3)|list",
    "modules.itertools.islice(modules.itertools.count(9007199254740993,2),3)|list",
    "modules.itertools.islice(modules.itertools.count(2**100,-1),3)|list",
    "modules.itertools.islice(modules.itertools.cycle([1,2]),5)|list",
    "modules.itertools.islice(modules.itertools.cycle('é好'),5)|list",
    "modules.itertools.cycle([])|list",
    "modules.itertools.islice(modules.itertools.repeat('x'),4)|list",
    "modules.itertools.repeat(object='x',times=3)|list",
    "modules.itertools.repeat('x',0)|list",
    "modules.itertools.repeat('x',-3)|list",
    "modules.itertools.islice(modules.itertools.repeat(none),3)|list",
    "modules.itertools.repeat('x',true)|list",
    "modules.itertools.accumulate([1,2,3])|list",
    "modules.itertools.accumulate(iterable=[1,2,3],func=none,initial=10)|list",
    "modules.itertools.accumulate([],initial=10)|list",
    "modules.itertools.accumulate([],initial=none)|list",
    "modules.itertools.accumulate([true,false,2])|list",
    "modules.itertools.accumulate([1,2.5,3])|list",
    "modules.itertools.accumulate(['a','b','c'])|list",
    "modules.itertools.accumulate([[1],[2],[3]])|list",
    "modules.itertools.accumulate([(1,),(2,),(3,)])|list",
    "modules.itertools.accumulate([9007199254740993,1,2])|list",
    "modules.itertools.chain()|list",
    "modules.itertools.chain([1,2],(3,4),'é好')|list",
    "modules.itertools.chain([],[],[1],[])|list",
    "modules.itertools.chain.from_iterable([[1],[2,3]])|list",
    "modules.itertools.chain.from_iterable([])|list",
    "modules.itertools.chain.from_iterable('é好')|list",
    "modules.itertools.compress('abcdef',[1,0,1,0,1,1])|list",
    "modules.itertools.compress(data=[1,2,3],selectors=[false,true])|list",
    "modules.itertools.compress([1],[true,true,true])|list",
    "modules.itertools.compress([1,2],[none,'yes'])|list",
    "modules.itertools.islice([0,1,2,3,4],3)|list",
    "modules.itertools.islice([0,1,2,3,4],none,none,2)|list",
    "modules.itertools.islice([0,1,2,3,4],1,5,2)|list",
    "modules.itertools.islice([0,1,2,3,4],4,2)|list",
    "modules.itertools.islice([0,1],1000000000000,none)|list",
    "modules.itertools.islice([0,1,2],true,none,true)|list",
    "modules.itertools.tee(none,0)",
    "modules.itertools.zip_longest()|list",
    "modules.itertools.zip_longest([1,2],[3],fillvalue='x')|list",
    "modules.itertools.zip_longest([],[],fillvalue='x')|list",
    "modules.itertools.zip_longest([1],[],[2,3],fillvalue=none)|list",
    "modules.itertools.zip_longest('é好',(1,2))|list",
    "modules.itertools.product()|list",
    "modules.itertools.product(repeat=0)|list",
    "modules.itertools.product(none,repeat=0)|list",
    "modules.itertools.product([1,2],'ab')|list",
    "modules.itertools.product([1,2],repeat=2)|list",
    "modules.itertools.product([1,2],[],repeat=2)|list",
    "modules.itertools.product([1],repeat=false)|list",
    "modules.itertools.permutations([1,2,3],2)|list",
    "modules.itertools.permutations(iterable='ab',r=none)|list",
    "modules.itertools.permutations([1,1,2],2)|list",
    "modules.itertools.permutations([],0)|list",
    "modules.itertools.permutations([1],2)|list",
    "modules.itertools.combinations([1,2,3],2)|list",
    "modules.itertools.combinations(iterable=[1,1,2],r=2)|list",
    "modules.itertools.combinations([],0)|list",
    "modules.itertools.combinations([1],2)|list",
    "modules.itertools.combinations_with_replacement([1,2],2)|list",
    "modules.itertools.combinations_with_replacement(iterable='ab',r=3)|list",
    "modules.itertools.combinations_with_replacement([],0)|list",
    "modules.itertools.combinations_with_replacement([],2)|list",
    "modules.itertools.starmap(none,[])|list",
    "modules.itertools.islice(modules.itertools.accumulate([1,2],false),1)|list",
    "modules.itertools.chain(none) is iterable",
    "modules.itertools.starmap(none,[[1]]) is iterable",
    "modules.itertools.accumulate([1,2],false) is iterable",
]

# Pointer values vary by process; compare the observed public representation
# shape while the templates below prove that rendering preserves consumption.
for factory, kind in [
    ("cycle([1])", "cycle"), ("accumulate([1])", "accumulate"),
    ("chain([1])", "chain"), ("compress([1],[true])", "compress"),
    ("islice([1],1)", "islice"), ("starmap(add,[])", "starmap"),
    ("tee([1])[0]", "_tee"), ("zip_longest([1])", "zip_longest"),
    ("product([1])", "product"), ("permutations([1])", "permutations"),
    ("combinations([1],1)", "combinations"),
    ("combinations_with_replacement([1],1)", "combinations_with_replacement"),
]:
    EXPRESSIONS.append(
        f"modules.re.fullmatch('<itertools.{kind} object at 0x[0-9a-f]+>', "
        f"modules.itertools.{factory}|string) is not none"
    )



def project(root, template):
    write_project(root, "0")
    (root / "models/value.sql").write_text(template)
    (root / "macros").mkdir()
    (root / "macros/functions.sql").write_text(
        "{% macro add(a,b) %}{{ return(a+b) }}{% endmacro %}\n"
        "{% macro multiply(a,b) %}{{ return(a*b) }}{% endmacro %}\n"
        "{% macro collect(value) %}{{ return(value|list) }}{% endmacro %}\n"
        "{% macro make_stream() %}{{ return(modules.itertools.starmap(add,[(1,2),(3,4)])) }}{% endmacro %}\n"
    )


@pytest.mark.parametrize("expression", EXPRESSIONS)
def test_native_itertools_expressions_match_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    project(root, "select '{{ " + expression + " }}' as rendered")
    compare(root, core_runner)


TEMPLATES = [
    "{% set i=modules.itertools.count(1,2) %}select '{{ i }}|{{ modules.itertools.islice(i,2)|list }}|{{ i }}|{{ modules.itertools.islice(i,1)|list }}'",
    "{% set i=modules.itertools.count(true,false) %}select '{{ i }}|{{ modules.itertools.islice(i,1)|list }}|{{ i }}'",
    "{% set i=modules.itertools.repeat('x',3) %}select '{{ i }}|{{ modules.itertools.islice(i,2)|list }}|{{ i }}|{{ i|list }}|{{ i }}'",
    "{% set i=modules.itertools.chain([1,2]) %}select '{{ (i|string).startswith('<itertools.chain object at 0x') }}|{{ i|list }}'",
    "select '{% for x in [1,2] %}{{ modules.itertools.repeat(loop,2)|string }};{% endfor %}'",
    "{% set i=modules.itertools.chain([1,2],[3]) %}select '{{ i|list }}|{{ i|list }}'",
    "{% set i=modules.itertools.islice(modules.itertools.count(1),3) %}select '{{ i|list }}|{{ i|list }}'",
    "{% set i=modules.itertools.tee([1,2,3]) %}select '{{ i[0]|list }}|{{ i[1]|list }}|{{ i[0]|list }}'",
    "{% set i=modules.itertools.tee(modules.itertools.count(1)) %}select '{{ modules.itertools.islice(i[0],3)|list }}|{{ modules.itertools.islice(i[1],2)|list }}|{{ modules.itertools.islice(i[0],2)|list }}|{{ modules.itertools.islice(i[1],3)|list }}'",
    "{% set i=modules.itertools.count(0) %}select '{% for x in modules.itertools.islice(i,3) %}{{ x }}|{{ modules.itertools.islice(i,1)|list }};{% endfor %}'",
    "{% set i=modules.itertools.count(0) %}{% set alias=i %}select '{{ modules.itertools.islice(i,2)|list }}|{{ modules.itertools.islice(alias,3)|list }}'",
    "{% set i=modules.itertools.chain([0,1,2,3,4,5]) %}{% set s=modules.itertools.islice(i,4,2) %}select '{{ s|list }}|{{ i|list }}'",
    "{% set i=modules.itertools.chain([0,1,2,3,4,5]) %}{% set s=modules.itertools.islice(i,0,3,100) %}select '{{ s|list }}|{{ i|list }}'",
    "{% set i=modules.itertools.chain([1,2,3]) %}{% set p=modules.itertools.product(i,repeat=0) %}select '{{ p|list }}|{{ i|list }}'",
    "{% set i=modules.itertools.chain([1,2]) %}{% set p=modules.itertools.product(i,repeat=2) %}select '{{ i|list }}|{{ p|list }}'",
    "{% set i=modules.itertools.chain([1,2,3]) %}{% set p=modules.itertools.permutations(i,2) %}select '{{ i|list }}|{{ p|list }}'",
    "{% set i=modules.itertools.chain([1,2,3]) %}{% set p=modules.itertools.combinations(i,2) %}select '{{ i|list }}|{{ p|list }}'",
    "{% set i=modules.itertools.chain([1,2,3]) %}{% set p=modules.itertools.combinations_with_replacement(i,2) %}select '{{ i|list }}|{{ p|list }}'",
    "{% set x=modules.itertools.starmap(add,[(1,2),(3,4)]) %}select '{{ x|list }}|{{ x|list }}'",
    "select '{{ modules.itertools.starmap(multiply,[(2,3),(4,5)])|list }}'",
    "select '{{ modules.itertools.accumulate([1,2,3,4],multiply,initial=2)|list }}'",
    "select '{{ modules.itertools.accumulate([1,2,3],add)|list }}'",
    "{% set x=make_stream() %}select '{{ collect(x) }}|{{ x|list }}'",
    "{% set x=modules.itertools.starmap(modules.datetime.date,[(2024,1,2),(2024,2,3)]) %}select '{{ x|map('string')|list }}'",
    "{% set i=modules.itertools.count(0) %}select '{{ zip(modules.itertools.islice(i,2),modules.itertools.islice(i,2))|list }}'",
    "{% set i=modules.itertools.count(0) %}select '{{ modules.itertools.zip_longest(modules.itertools.islice(i,2),modules.itertools.islice(i,3))|list }}'",
    "{% set i=modules.itertools.count(0) %}{% set x=modules.itertools.compress(i,[true,false,true]) %}select '{{ x|list }}|{{ modules.itertools.islice(i,2)|list }}'",
    "{% set i=modules.itertools.chain([1,2,3]) %}{% set x=modules.itertools.cycle(i) %}select '{{ i|list }}|{{ modules.itertools.islice(x,5)|list }}'",
    "{% set i=modules.itertools.chain([1,2,3]) %}{% set x=modules.itertools.cycle(i) %}select '{{ modules.itertools.islice(x,1)|list }}|{{ i|list }}|{{ modules.itertools.islice(x,4)|list }}'",
    "{% set i=modules.itertools.chain([1,2,3]) %}{% set x=modules.itertools.repeat(i,2)|list %}select '{{ x[0] is sameas x[1] }}|{{ x[0]|list }}|{{ x[1]|list }}'",
]


@pytest.mark.parametrize("template", TEMPLATES)
def test_native_itertools_aliases_callbacks_and_consumption_match_core(tmp_path, core_runner, template):
    root = tmp_path / "project"
    project(root, template)
    compare(root, core_runner)


def test_native_tee_clone_identity_tracks_canonical_python_312(tmp_path, core_runner):
    # CPython 3.11 reuses the input as its first branch; 3.12 clones it.
    # Native evaluation follows the canonical 3.12 contract on every host.
    root = tmp_path / "project"
    project(root, "{% set original=modules.itertools.tee([1,2,3])[0] %}"
            "{% set branches=modules.itertools.tee(original) %}"
            "select '{{ branches[0] is sameas original }}|"
            "{{ branches[0] is sameas branches[1] }}|"
            "{{ branches[0]|list }}|{{ branches[1]|list }}'")
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root), "--select", "value"]
    native = subprocess.run([DXT, *common, "--target-path", "native"], text=True, capture_output=True)
    assert native.returncode == 0, native.stderr
    oracle = core_runner.invoke(["--quiet", *common, "--target-path", "core", "--no-partial-parse"])
    assert oracle.success, oracle.exception
    def compiled(directory):
        return json.loads((root / directory / "manifest.json").read_text())["nodes"]["model.expressions.value"]["compiled_code"]
    consumed = "|False|[1, 2, 3]|[1, 2, 3]'"
    assert compiled("native") == "select 'False" + consumed
    expected_identity = "True" if sys.version_info[:2] < (3, 12) else "False"
    assert compiled("core") == "select '" + expected_identity + consumed
    contracts.assert_artifact(root / "native/manifest.json")
    contracts.assert_artifact(root / "native/run_results.json")


ERRORS = [
    "modules.itertools.count()|attr()", "modules.itertools.count()|attr('x','y')",
    "modules.itertools.count().items()", "modules.itertools.count().keys()",
    "modules.itertools.count().get('current')", "modules.itertools.count().copy()",
    "modules.itertools.count().update({'current':0})", "modules.itertools.count().clear()",
    "modules.itertools.count().pop('current')",
    "modules.itertools.count('x')", "modules.itertools.count(1,'x')", "modules.itertools.count(1,2,3)",
    "modules.itertools.count(foo=1)", "modules.itertools.cycle()", "modules.itertools.cycle(none)",
    "modules.itertools.cycle(iterable=[1])", "modules.itertools.repeat()", "modules.itertools.repeat('x',1.5)",
    "modules.itertools.repeat('x',times=2,object='y')", "modules.itertools.repeat(none,none)", "modules.itertools.accumulate()",
    "modules.itertools.accumulate([1,2],none,3)", "modules.itertools.accumulate(none)",
    "modules.itertools.accumulate([1,'x'])|list", "modules.itertools.accumulate([1,2],false)|list",
    "modules.itertools.chain(none)|list", "modules.itertools.chain(iterable=[1])",
    "modules.itertools.chain.from_iterable(none)", "modules.itertools.chain.from_iterable([[1],none])|list",
    "modules.itertools.chain.from_iterable(iterable=[[1]])", "modules.itertools.compress([1])",
    "modules.itertools.compress(none,[])", "modules.itertools.compress([],none)",
    "modules.itertools.islice([1])", "modules.itertools.islice([1],-1)",
    "modules.itertools.islice([1],0,1,0)", "modules.itertools.islice([1],0,1,-1)",
    "modules.itertools.islice([1],1.0)", "modules.itertools.islice([1],stop=1)",
    "modules.itertools.islice([1],2**100)", "modules.itertools.starmap(none)",
    "modules.itertools.starmap(none,none)", "modules.itertools.starmap(none,[[1]])|list",
    "modules.itertools.starmap(add,[1])|list", "modules.itertools.starmap(add,[(1,)])|list",
    "modules.itertools.starmap(function=add,iterable=[])", "modules.itertools.tee(none)",
    "modules.itertools.tee([1],-1)", "modules.itertools.tee([1],1.5)",
    "modules.itertools.tee([1],n=2)", "modules.itertools.zip_longest(none)",
    "modules.itertools.zip_longest([],foo=1)", "modules.itertools.product(none)",
    "modules.itertools.product([1],repeat=-1)", "modules.itertools.product([1],repeat=1.5)",
    "modules.itertools.product([1],foo=1)", "modules.itertools.permutations(none)",
    "modules.itertools.permutations([1],-1)", "modules.itertools.permutations([1],1.5)",
    "modules.itertools.combinations([1])", "modules.itertools.combinations([1],none)",
    "modules.itertools.combinations([1],-1)", "modules.itertools.combinations_with_replacement([1],-1)",
    "modules.itertools.combinations_with_replacement([1],1.5)",
]


@pytest.mark.parametrize("expression", ERRORS)
def test_native_itertools_genuine_errors_match_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    project(root, "select '{{ " + expression + " }}' as rendered")
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root), "--select", "value"]
    native = subprocess.run([DXT, *common], text=True, capture_output=True)
    oracle = core_runner.invoke(["--quiet", *common, "--no-partial-parse"])
    assert native.returncode != 0
    assert not oracle.success

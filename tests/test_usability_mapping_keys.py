"""Typed dictionary keys through native dxt and actual pinned dbt Core."""
import subprocess
from pathlib import Path

import pytest

from test_usability_commands import core_runner
from test_usability_expression_types import compare
from test_usability_expressions import write_project

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out/bin/dxt"


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


EXPRESSIONS = [
    "{1:'one',2:'two'}",
    "{true:'first',1:'second',1.0:'third'}",
    "{1.0:'first',true:'second',1:'third'} | list",
    "{1:'one'}[true]",
    "{false:'zero'}[0.0]",
    "{9007199254740993:'exact',9007199254740992.0:'float'}",
    "{none:'null',(1,2):'pair'}",
    "{(true,2.0):'pair'}[(1,2)]",
    "{(1,(none,'é')):'nested'}.get((true,(none,'é')))",
    "{1:'one'}.get(2,'fallback')",
    "{none:'null'}[none]",
    "{1:'one'}.keys()",
    "{1:'one',none:'null',(2,3):'pair'}.items()",
    "{1:'one',none:'null'}.values() | list",
    "dict([(1,'first'),(true,'second'),(none,'null')])",
    "dict({1:'one'},label='named')",
    "{1:'one'} == {true:'one'}",
    "{1:'one'} == {'1':'one'}",
    "{(1,2):'pair'}.keys() == {(true,2.0):'other'}.keys()",
    "{1:'one'}.items() == {true:'one'}.items()",
    "1.0 in {true:'one'}",
    "none not in {1:'one'}",
    "[{'key':1},{'key':2}] | map(attribute='key') | list",
    "dict(zip((1,2),('one','two')))",
    "{(-1)**0.5:'complex'}[(-1)**0.5]",
]


@pytest.mark.parametrize("expression", EXPRESSIONS)
def test_typed_mapping_expression_matches_core(tmp_path, core_runner, expression):
    root = tmp_path / "mapping_contract"
    write_project(root, expression)
    compare(root, core_runner)


TEMPLATES = [
    "{% set d={1:'one',none:'null'} %}{{ d }}|{{ d[true] }}|{{ d.get(none) }}",
    "{% set d={1:'one'} %}{% set alias=d %}{% do alias.update({true:'new',2:'two'}) %}{{ d }}",
    "{% set d={1:'one'} %}{% set keys=d.keys() %}{% do d.update({none:'null'}) %}{{ keys|list }}",
    "{% set d={1:'one'} %}{% do d.update([(true,'new'),((2,3),'pair')]) %}{{ d }}",
    "{% set d={1:'one'} %}{{ d.pop(true) }}|{{ d }}",
    "{% set d={1:'one'} %}{{ d.setdefault(true,'other') }}|{{ d.setdefault(none,'null') }}|{{ d }}",
    "{% set d={none:'null',(1,2):'pair'} %}{% for key,value in d.items() %}{{ key }}:{{ value }};{% endfor %}",
    "{% set d={none:'null',(1,2):'pair'} %}{% for key in d %}{{ key }};{% endfor %}",
    "{% set n=var('nan_text')|float %}{% set d={n:'same'} %}{{ d[n] }}|{{ n in d }}|{{ d.get(n) }}",
    "{% set n=var('nan_text')|float %}{% set other=var('nan_text')|float %}{% set d={n:'first',other:'second'} %}{{ d|length }}|{{ d[n] }}|{{ d[other] }}",
    "{% set n=var('nan_text')|float %}{% set d={(n,1):'pair'} %}{{ d[(n,true)] }}|{{ d.get((var('nan_text')|float,1),'different') }}",
    "{% set n=var('nan_text')|float %}{{ n == n }}|{{ n is float }}|{{ n is number }}|{{ n < 1 }}|{{ n != n }}",
    "{% set n=var('nan_text')|float %}{{ n is sameas(n) }}|{{ n is sameas(n|float) }}|{{ n is sameas(var('nan_text')|float) }}|{{ n is sameas(n.real) }}|{{ n.imag }}",
    "{% set n=var('nan_text')|float %}{{ n in [n] }}|{{ [n].count(n) }}|{{ [n].index(n) }}|{{ [n] == [n] }}|{{ {'a':n} == {'a':n} }}",
    "{% set r=api.Relation.create(database='warehouse',schema='main',identifier='key',type='table') %}{% set d={r:'found'} %}{{ d[r] }}|{{ r in d }}|{{ d.get(r) }}",
    "{% set r=api.Relation.create(database='warehouse',schema='main',identifier='key',type='table') %}{% set same=api.Relation.create(database='warehouse',schema='main',identifier='key',type='table') %}{% set d={r:'found'} %}{{ d.get(same,'missing') }}|{{ d|length }}",
    "{% set r=api.Relation.create(database='warehouse',schema='main',identifier='key',type='table') %}{% set other=api.Relation.create(database='warehouse',schema='main',identifier='key',type='view') %}{% set d={r:'found'} %}{{ d.get(other,'different') }}|{{ d.get(r|string,'text') }}",
    "{% set r=api.Relation.create(schema='main',identifier='key') %}{% set d={} %}{% do d.update({r:[]}) %}{{ d[r] }}|{{ d|length }}",
    "{% set r=api.Relation.create(schema='main',identifier='key') %}{% set d={r:'found'} %}{{ d.keys()|list }}|{{ d.items()|list }}",
    "{% set r=api.Relation.create(schema='main',identifier='key') %}{% set other=r.include(schema=false) %}{% set d={r:'found'} %}{{ d.get(other,'different') }}|{{ r == other }}",
    "{% set r=api.Relation.create(schema='main',identifier='key') %}{% set other=r.quote(identifier=false) %}{% set d={r:'found'} %}{{ d.get(other,'different') }}|{{ r == other }}",
]


@pytest.mark.parametrize("template", TEMPLATES)
def test_mapping_bindings_mutations_and_relations_match_core(tmp_path, core_runner, template):
    root = tmp_path / "mapping_contract"
    write_project(root, "0")
    (root / "models/value.sql").write_text("select '" + template + "' as rendered\n")
    compare(root, core_runner, {"nan_text": "nan"})


@pytest.mark.parametrize("expression", [
    "{[]:1}", "{{}:1}", "{([1],):1}", "{1:2}[[]]", "{1:2}.get({})",
    "[] in {1:2}", "dict([(1,2,3)])", "dict([(1,)])", "dict(1)",
    "dict({}, {})", "dict(**{1:2})",
])
def test_unhashable_and_invalid_keys_match_core_failure(tmp_path, core_runner, expression):
    root = tmp_path / "mapping_invalid"
    write_project(root, expression)
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root)]
    actual = subprocess.run([str(DXT), *common], capture_output=True, text=True)
    oracle = core_runner.invoke(["--quiet", *common, "--no-partial-parse"])
    assert actual.returncode != 0, actual.stdout + actual.stderr
    assert "InvalidOption" not in actual.stderr
    assert not oracle.success, oracle.result


def test_native_literal_nan_avoids_core_constant_fold_codegen_defect(tmp_path, core_runner):
    """Document the deliberate correction of Jinja's invalid Python constant."""
    root = tmp_path / "mapping_literal_nan"
    write_project(root, "0")
    (root / "models/value.sql").write_text(
        "{% set n='nan'|float %}{% set d={n:'same'} %}select '{{ d[n] }}' as rendered\n"
    )
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root)]
    actual = subprocess.run([str(DXT), *common], capture_output=True, text=True)
    oracle = core_runner.invoke(["--quiet", *common, "--no-partial-parse"])
    assert actual.returncode == 0, actual.stderr
    assert not oracle.success
    assert "name 'nan' is not defined" in str(oracle.exception)

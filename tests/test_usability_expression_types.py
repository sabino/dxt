"""Exact native Jinja numeric, tuple, iterator and Unicode Core contracts."""
import json
import subprocess
from pathlib import Path

import pytest

from test_usability_artifacts import contracts
from test_usability_commands import core_runner
from test_usability_expressions import write_project

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out/bin/dxt"


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


EXPRESSIONS = [
    "1 is integer and 1.0 is float and true is not integer",
    "[1,1.0,-0.0,true,false,1e-5,1e16]",
    "9007199254740993",
    "9007199254740993 + 1",
    "9007199254740993 - 9007199254740992",
    "9007199254740993 * 9007199254740993",
    "9007199254740993 == 9007199254740992.0",
    "9007199254740993 > 9007199254740992.0",
    "9007199254740993 < 9007199254740994.0",
    "9007199254740993 != 9007199254740992.0",
    "-9007199254740993 < -9007199254740992.0",
    "9007199254740992 == 9007199254740992.0",
    "9007199254740993 is odd",
    "9007199254740993 is divisibleby(3)",
    "2 ** 100",
    "-7 // 3",
    "7 // -3",
    "-7 % 3",
    "7 % -3",
    "1.0 // 0.1",
    "-1.0 % 0.1",
    "-0.0 % 3.0",
    "0 / -1",
    "(10 ** 400) / (10 ** 400)",
    "1 / (2 ** 1074)",
    "3 / (2 ** 1075)",
    "1 / (2 ** 1075)",
    "1 + 2.0",
    "true + 2",
    "+true",
    "-false",
    "[9007199254740993,1] | sum",
    "[9007199254740993,9007199254740992.0] | sort",
    "[9007199254740993,9007199254740992.0] | unique | list",
    "'9007199254740993' | int",
    "'0x10000000000000000' | int(base=0)",
    "'ff' | int(base=16)",
    "'42.9' | int",
    "'bad' | int(default='fallback')",
    "none | int",
    "-1.9 | int",
    "1e20 | int",
    "1 | float",
    "'bad' | float(default='fallback')",
    "1 + 2 is even",
    "-1 is odd",
    "-2 is even",
    "+true is integer",
    "-1 is odd + 1",
    "-0 | default('fallback',true)",
    "2 ** 3 is odd",
    "1 is odd | string",
    "(1 + 2) is odd",
    "()",
    "(1,)",
    "(1,2.0,'x')",
    "(1,2) + (3,)",
    "(1,2) * 2",
    "2 * [1,2]",
    "'é' * 3",
    "(1,2) == [1,2]",
    "(1,2)[-1]",
    "(1,2,3)[::-1]",
    "(1,2)[::1.0] | default('undefined')",
    "(1,2)[1.0:] | default('undefined')",
    "(1,2,1).count(1)",
    "(1,2,1).index(1,1)",
    "zip([1,2],[3,4]) | list",
    "zip((1,2),'é好') | list",
    "{}.items()",
    "{'a':1,'b':2}.items()",
    "{'a':1,'b':2}.items() | list",
    "{'a':1,'b':2}.keys()",
    "{'a':1,'b':2}.values() | list",
    "{'a':1}.items() is not sequence",
    "{'a':1}.items() | length",
    "'a' in {'a':1}.keys()",
    "('a',1) in {'a':1}.items()",
    "1 in {'a':1}.values()",
    "{'a':1}.keys() == {'a':2}.keys()",
    "{'a':1}.values() == {'a':1}.values()",
    "'aé好' | length",
    "'Straße ﬃ' | upper",
    "'İ ΟΣ ΟΣΑ ΟΣ́' | lower",
    "'ÉİΣ' | lower",
    "'Straße ﬃ'.casefold()",
    "['É','é','A'] | unique | list",
    "['é','Å','Ä'] | sort",
    "'\\u00a0\\u2003é\\u3000' | trim",
    "'  é　'.strip()",
    "'  é　'.lstrip()",
    "'  é　'.rstrip()",
    "' a b　c '.split()",
    "' a b　c '.split(None,1)",
    "' a b　c '.rsplit(None,1)",
    "' a b '.split(None,0)",
    "' a b '.rsplit(None,0)",
    "['a\\x00','quote\\\'',' ']",
]


def compare(root, core_runner, variables=None):
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root), "--select", "value"]
    if variables is not None:
        common.extend(["--vars", json.dumps(variables)])
    result = subprocess.run([DXT, *common, "--target-path", "native"], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    oracle = core_runner.invoke(["--quiet", *common, "--target-path", "core", "--no-partial-parse"])
    assert oracle.success, oracle.exception
    actual = json.loads((root / "native/manifest.json").read_text())["nodes"]["model.expressions.value"]["compiled_code"]
    expected = json.loads((root / "core/manifest.json").read_text())["nodes"]["model.expressions.value"]["compiled_code"]
    assert actual == expected
    contracts.assert_artifact(root / "native/manifest.json")
    contracts.assert_artifact(root / "native/run_results.json")


@pytest.mark.parametrize("expression", EXPRESSIONS)
def test_native_typed_expression_matches_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    write_project(root, expression)
    compare(root, core_runner)


TEMPLATES = [
    "{% set v=zip([1,2],[3,4]) %}select '{{ v|list }} {{ v|list }}' as rendered",
    "{% set v=zip([1,2,3],[4,5,6]) %}{% set w=zip(v,[7]) %}select '{{ w|list }} {{ v|list }}' as rendered",
    "{% set v=zip([1,2],[3,4]) %}{% set alias=v %}select '{{ alias|list }} {{ v|list }}' as rendered",
    "{% set d={'a':1} %}{% set v=d.items() %}{% do d.update({'b':2}) %}select '{{ v|list }}' as rendered",
    "{% set d={'a':1} %}{% set v=d.keys() %}{% do d.clear() %}select '{{ v|length }} {{ v|list }}' as rendered",
    "select '{% for x,y in zip((1,2),(3,4)) %}{{ x+y }}{% endfor %}' as rendered",
    "select '{% for x in 'aé好' %}{{ loop.index }}:{{ x }};{% endfor %}' as rendered",
    "select '{{ var('big') }} {{ var('floating') }} {{ var('big') + 1 }} {{ var('big') is integer }}' as rendered",
]


@pytest.mark.parametrize("template", TEMPLATES)
def test_native_typed_bindings_and_iteration_match_core(tmp_path, core_runner, template):
    root = tmp_path / "project"
    write_project(root, "0")
    (root / "models/value.sql").write_text(template)
    compare(root, core_runner, {"big": 9007199254740993, "floating": 1.0})


@pytest.mark.parametrize("expression", ["'x'|indent(4.0)", "range(3.0)|list", "(1,2).index(9)", "10.0 ** 400", "1e309|int", "(10 ** 400)|float", "(10 ** 400) / 1"])
def test_invalid_typed_expression_fails_like_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    write_project(root, expression)
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root), "--select", "value"]
    actual = subprocess.run([DXT, *common], text=True, capture_output=True)
    assert actual.returncode != 0
    assert not (root / "warehouse.duckdb").exists()
    oracle = core_runner.invoke(["--quiet", *common, "--no-partial-parse"])
    assert not oracle.success

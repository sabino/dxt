"""Immutable runtime identities and compiled constant scopes against Core."""
import subprocess

import pytest

from test_usability_commands import core_runner
from test_usability_expression_types import ROOT, compare, write_project


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


RUNTIME = [
    "1000 is sameas 1000", "1.0 is sameas 1.0", "'abc' is sameas 'abc'",
    "'é' is sameas 'é'", "'好' is sameas '好'", "256 is sameas 256",
    "257 is sameas 257", "(-5) is sameas(-5)", "(-6) is sameas(-6)",
    "i is sameas i", "f is sameas f", "s is sameas s", "c is sameas c",
    "i is sameas 1000", "i is sameas(500+500)", "f is sameas 1.0",
    "s is sameas 'abc'", "t is sameas((1000,2))",
    "(i+0) is sameas i", "(f+0) is sameas f", "(c+0) is sameas c",
    "(+i) is sameas i", "(+f) is sameas f", "(+c) is sameas c",
    "i|int is sameas i", "f|float is sameas f",
    "[]|sum(start=i) is sameas i", "[]|sum(start=f) is sameas f",
    "[]|sum(start=c) is sameas c", "[]|sum(start=1000) is sameas 1000",
    "[]|sum(start=1.0) is sameas 1.0",
    "s.lower() is sameas s", "s.lower() is sameas(s.lower())",
    "upper.upper() is sameas upper", "s.strip() is sameas s",
    "s.replace('none','x') is sameas s", "s.replace('a','a') is sameas s",
    "s.replace('a','z',0) is sameas s", "s.upper().lower() is sameas s",
    "''.join([s]) is sameas s", "[s]|join is sameas s",
    "(s+'') is sameas s", "(''+s) is sameas s", "(s*1) is sameas s",
    "s[:] is sameas s", "s[0:3:1] is sameas s", "s|trim is sameas s",
    "s.split('|')[0] is sameas s", "s.split()[0] is sameas s",
    "latin[0] is sameas latin", "latin|first is sameas latin",
    "latin|last is sameas latin", "latin.lower() is sameas latin",
    "latin.upper() is sameas 'É'", "latin.strip() is sameas latin",
    "' é '.strip() is sameas latin", "' 好 '.strip() is sameas larger",
    "larger[0] is sameas larger", "larger[:] is sameas larger",
    "(t+()) is sameas t", "(()+t) is sameas t", "(t*1) is sameas t",
    "(1*t) is sameas t", "t[:] is sameas t", "(t*0) is sameas(())",
    "[] is sameas []", "{} is sameas {}", "() is sameas(())",
    "(1000,2) is sameas((1000,2))",
    "i|string is sameas(i|string)", "f|string is sameas(f|string)",
    "n|string is sameas(n|string)", "truth|string is sameas(truth|string)",
    "truth|string is sameas 'True'", "fallback is sameas fallback",
    "fallback is sameas(bad|float)", "fallback is sameas 0.0",
    "f.real is sameas f", "f.imag is sameas(f.imag)",
    "c.real is sameas(c.real)", "c.imag is sameas(c.imag)",
    "([1]|map('float')|first) is sameas([1]|map('float')|first)",
]


def test_primitive_runtime_identity_matches_core(tmp_path, core_runner):
    root = tmp_path / "project"
    write_project(root, "0")
    prefix = "".join("{% set " + name + "=" + value + " %}" for name, value in [
        ("i", "1000"), ("f", "1.0"), ("s", "'abc'"), ("upper", "'ABC'"),
        ("c", "(-1.0)**0.5"), ("t", "(1000,2)"), ("latin", "'é'"),
        ("larger", "'好'"), ("n", "none"), ("truth", "true"),
        ("bad", "'bad'"), ("fallback", "bad|float"),
    ])
    (root / "models/value.sql").write_text(
        prefix + "select '" + ";".join("{{ " + item + " }}" for item in RUNTIME) + "' as value"
    )
    compare(root, core_runner)


CONSTANTS = ["1000", "1.0", "'abc'", "'a b'", "'é'", "'a'", "'éé'",
             "'_a1'", "'123'", "'a-b'", "'好'", "(1000,2)", "(1000,)", "()",
             "'bad'|float"]


def test_compiled_constants_follow_model_and_macro_scopes(tmp_path, core_runner):
    root = tmp_path / "project"
    write_project(root, "0")
    macro_dir = root / "macros"
    macro_dir.mkdir(exist_ok=True)
    same, other, model = [], [], []
    for index, literal in enumerate(CONSTANTS):
        for name in ["one", "two"]:
            same.append("{% macro " + name + str(index) + "() %}{{ return(" + literal + ") }}{% endmacro %}")
        other.append("{% macro other" + str(index) + "() %}{{ return(" + literal + ") }}{% endmacro %}")
        model.append("{% set value=" + literal + " %}{% set macro=one" + str(index) + "() %}")
        model.append("{{ [value is sameas macro, macro is sameas(one" + str(index) + "()), "
                     "macro is sameas(two" + str(index) + "()), macro is sameas(other" + str(index) + "()), "
                     "value is sameas((" + literal + ")), (" + literal + ") is sameas((" + literal + "))] }};")
    (macro_dir / "same.sql").write_text("\n".join(same))
    (macro_dir / "other.sql").write_text("\n".join(other))
    (root / "models/value.sql").write_text("select '" + "".join(model) + "' as value")
    compare(root, core_runner)


def test_macro_defaults_and_callers_share_body_constants(tmp_path, core_runner):
    root = tmp_path / "project"
    write_project(root, "0")
    macro_dir = root / "macros"
    macro_dir.mkdir(exist_ok=True)
    macros, model = [], []
    for index, literal in enumerate(["1000", "1.0", "'a b'", "500+500"]):
        suffix = str(index)
        macros.append("{% macro check" + suffix + "(x=" + literal + ") %}"
                      "{{ return(x is sameas(" + literal + ")) }}{% endmacro %}")
        macros.append("{% macro value" + suffix + "(x=" + literal + ") %}"
                      "{{ return(x) }}{% endmacro %}")
        model.extend(["{{ check" + suffix + "() }}",
                      "{{ value" + suffix + "() is sameas(value" + suffix + "()) }}"])
    macros.append("{% macro use_caller() %}{{ caller() }}{% endmacro %}")
    model.append("{% call(x=1000) use_caller() %}{{ x is sameas 1000 }}{% endcall %}")
    (macro_dir / "defaults.sql").write_text("\n".join(macros))
    (root / "models/value.sql").write_text("select '" + ";".join(model) + "' as value")
    compare(root, core_runner)


@pytest.mark.parametrize("expression", [
    "{'__dxt_native_numeric':'__dxt_native_numeric','__dxt_float':1.0} is mapping",
    "{'__dxt_native_numeric':'__dxt_native_numeric','__dxt_float':1.0}|tojson",
    "1.0['__dxt_float']|default('missing')",
    "1.0|attr('__dxt_float_identity')|default('missing')",
    "{'__dxt_float':1.0} == {'__dxt_float':1.0}",
    "{1.0:'one',1:'same',2.0:'two'}|tojson",
    "[1.0,2.0,1]|unique|list", "[1.0,-0.0,1e16]|tojson",
])
def test_native_numeric_protocol_is_opaque_and_preserves_values(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    write_project(root, expression)
    compare(root, core_runner)

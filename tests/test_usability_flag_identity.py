"""Regex flag singletons, subclass conversion and opaque identities against Core."""
import subprocess
import json
import sys

import pytest

from test_usability_commands import core_runner
from test_usability_expression_types import ROOT, compare, write_project


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


FLAG_IDENTITIES = [
    "modules.re.I is sameas modules.re.I",
    "modules.re.I is sameas modules.re.IGNORECASE",
    "modules.re.RegexFlag(2) is sameas modules.re.I",
    "modules.re.RegexFlag(2.0) is sameas modules.re.I",
    "modules.re.RegexFlag(3) is sameas modules.re.RegexFlag(3)",
    "modules.re.RegexFlag(0) is sameas modules.re.NOFLAG",
    "modules.re.RegexFlag(512) is sameas modules.re.RegexFlag(512)",
    "modules.re.RegexFlag(-1) is sameas modules.re.RegexFlag(511)",
    "modules.re.RegexFlag(-512) is sameas modules.re.NOFLAG",
    "modules.re.RegexFlag(-513) is sameas modules.re.RegexFlag(511)",
    "modules.re.RegexFlag(true) is sameas modules.re.RegexFlag(1)",
    "modules.re.RegexFlag(9007199254740993) is sameas modules.re.RegexFlag(9007199254740993)",
    "modules.re.I|int is sameas 2", "modules.re.I is sameas 2",
    "modules.re.I is sameas modules.re.M",
    "modules.re.I['__dxt_immutable_identity']|default('missing')",
    "modules.re.I|attr('__dxt_immutable_identity')|default('missing')",
    "{'__dxt_immutable_identity':'__dxt_regex_flag:2'} is sameas modules.re.I",
    "{'__dxt_immutable_identity':modules.re.RegexFlag} is sameas modules.re.I",
    "{'__dxt_immutable_identity':'__dxt_regex_flag:2'} is mapping",
    "{'__dxt_immutable_identity':'__dxt_regex_flag:2'}|tojson",
]


def test_regex_flag_singletons_match_core(tmp_path, core_runner):
    root = tmp_path / "project"
    write_project(root, "0")
    (root / "models/value.sql").write_text(
        "select '" + ";".join("{{ " + item + " }}" for item in FLAG_IDENTITIES) + "' as value"
    )
    compare(root, core_runner)


def test_as_text_retains_string_aliases(tmp_path, core_runner):
    root = tmp_path / "project"
    write_project(root, "0")
    expressions = [
        "a is sameas s", "a is sameas(s|as_text)", "a|string is sameas a",
        "a|string is sameas s", "a==s", "a is string", "a is sequence",
        "a[0] is sameas 'a'", "a[:] is sameas a", "a.strip() is sameas a",
        "a.replace('none','x') is sameas a", "(a+'') is sameas a",
    ]
    (root / "models/value.sql").write_text(
        "{% set s='abc' %}{% set a=s|as_text %}select '"
        + ";".join("{{ " + item + " }}" for item in expressions) + "' as value"
    )
    compare(root, core_runner)


def test_regex_flag_class_and_constructor_cache_match_core(tmp_path, core_runner):
    root = tmp_path / "project"
    write_project(root, "0")
    expressions = [
        "modules.re.RegexFlag.I is sameas modules.re.I",
        "modules.re.RegexFlag.TEMPLATE.value", "modules.re.RegexFlag.DEBUG.value",
        "modules.re.RegexFlag['I'] is sameas modules.re.I",
        "modules.re.RegexFlag[0]|default('missing')", "modules.re.RegexFlag|list",
        "modules.re.RegexFlag|length", "modules.re.RegexFlag is iterable",
        "modules.re.RegexFlag is sequence", "modules.re.RegexFlag is mapping",
        "'I' in modules.re.RegexFlag", "modules.re.I in modules.re.RegexFlag",
        "modules.re.RegexFlag(3.0) is sameas three",
        "modules.re.RegexFlag(512.0) is sameas unknown",
        "modules.re.RegexFlag(-257.0) is sameas negative",
        "modules.re.RegexFlag(255.0) is sameas negative",
        "modules.re.RegexFlag|attr('__dxt_native_regex_enum')|default('missing')",
        "{'__dxt_integer':'1'} is mapping", "{'__dxt_integer':'1'}|tojson",
        "{'__dxt_integer':'1'} == 1",
    ]
    prefix = "{% set three=modules.re.RegexFlag(3) %}{% set unknown=modules.re.RegexFlag(512) %}{% set negative=modules.re.RegexFlag(-257) %}"
    (root / "models/value.sql").write_text(
        prefix + "select '" + ";".join("{{ " + item + " }}" for item in expressions) + "' as value"
    )
    compare(root, core_runner)


@pytest.mark.parametrize("value,prefix", [
    ("7999.0", ""), ("-7999.0", ""), ("3.5", ""),
    ("authored|float", "{% set authored='nan' %}"),
    ("authored|float", "{% set authored='inf' %}"),
    ("-513.0", "{% set normalized=modules.re.RegexFlag(-513) %}"),
])
def test_uncached_or_invalid_regex_flag_floats_fail_in_fresh_core(tmp_path, core_runner, value, prefix):
    root = tmp_path / "project"
    write_project(root, "0")
    (root / "models/value.sql").write_text(prefix + "select '{{ modules.re.RegexFlag(" + value + ") }}' as value")
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root)]
    native = subprocess.run([ROOT / "zig-out/bin/dxt", *common], capture_output=True, text=True)
    assert native.returncode != 0, native.stdout + native.stderr
    assert "InvalidRegularExpressionFlags" in native.stderr, native.stderr
    # The Enum cache belongs to the process, so each cold-cache failure needs
    # a fresh actual Core process rather than the suite's reusable dbtRunner.
    script = "from dbt.cli.main import dbtRunner; import json,sys; r=dbtRunner().invoke(json.loads(sys.argv[1])); assert not r.success, 'Core accepted the invalid flag'; assert 'is not a valid RegexFlag' in str(r.exception), r.exception"
    core = subprocess.run([sys.executable, "-c", script, json.dumps(["--quiet", *common, "--no-partial-parse"])], capture_output=True, text=True)
    assert core.returncode == 0, core.stdout + core.stderr

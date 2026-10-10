"""Regex flag singletons, subclass conversion and opaque identities against Core."""
import subprocess

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

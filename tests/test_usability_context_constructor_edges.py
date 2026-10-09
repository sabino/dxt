"""Pinned Core constructor fallbacks and native runtime codec boundaries."""
import subprocess

import pytest

from test_usability_commands import core_runner
from test_usability_expression_types import ROOT, DXT, compare, write_project


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


@pytest.mark.parametrize("expression", [
    "fromyaml('!!binary SGV!sbG8=')", "fromyaml('!!binary =SGVsbG8=')",
    "fromyaml('!!binary SGVs=bG8=')", "fromyaml('!!binary SGVsbG8===')",
    "fromyaml('!!binary SGVsbG8=xAAA')", "fromyaml('!!binary \"!!!\"')",
    "fromyaml('!!binary AB==').hex()",
    "fromyaml('!!binary S===', 'fallback')",
    "fromyaml('!!binary SGVsbG8', 'fallback')",
    "fromyaml('!!binary \"é\"', 'fallback')",
    "fromyaml('!!binary \"SGVsbG8=é\"', 'fallback')",
    "fromyaml('!!int invalid', 'fallback')",
    "fromyaml('!!float invalid', 'fallback')",
    "fromyaml('!!timestamp invalid', 'fallback')",
    "fromyaml('2020-13-02', 'fallback')",
    "fromyaml('2020-01-40', 'fallback')",
    "fromyaml('!!bool TRUE')",
    "fromyaml('!!bool tRuE')",
])
def test_safe_yaml_constructor_fallbacks_match_core(tmp_path, core_runner, expression):
    project = tmp_path / "project"
    write_project(project, expression)
    compare(project, core_runner)


@pytest.mark.parametrize("value", ["invalid", "y", "1"])
def test_safe_yaml_bool_constructor_key_errors_remain_visible(tmp_path, core_runner, value):
    project = tmp_path / "project"
    write_project(project, "fromyaml('!!bool " + value + "', 'fallback')")
    common = ["compile", "--project-dir", str(project), "--profiles-dir", str(project), "--select", "value"]
    actual = subprocess.run([DXT, *common], capture_output=True, text=True)
    expected = core_runner.invoke(["--quiet", *common, "--no-partial-parse"])
    assert actual.returncode != 0
    assert not expected.success


@pytest.mark.parametrize("digits", [4300, 4301])
@pytest.mark.parametrize("negative", [False, True])
def test_json_default_integer_digit_boundary_matches_core(tmp_path, core_runner, digits, negative):
    project = tmp_path / "project"
    write_project(project, "fromjson(var('payload'), 'fallback') is number")
    payload = ("-" if negative else "") + "1" * digits
    compare(project, core_runner, variables={"payload": payload})

"""Pinned Core legal SafeLoader keys and native SafeDumper scalar identity."""
import subprocess

import pytest

from test_usability_commands import core_runner
from test_usability_expression_types import ROOT, compare, write_project


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


@pytest.mark.parametrize("expression", [
    "fromyaml('{2020-01-02: date}')[fromyaml('2020-01-02')]",
    "fromyaml('{!!binary SGVsbG8=: binary}')[fromyaml('!!binary SGVsbG8=')]",
    "fromyaml('{2020-01-02T03:04:05Z: first, 2020-01-02T04:04:05+01:00: second}')|length",
    "fromyaml('{2020-01-02: day, 2020-01-02T00:00:00: time}')|length",
    "fromyaml('{2020-01-02T00:00:00: naive, 2020-01-02T00:00:00Z: aware}')|length",
    "fromyaml('2020-01-02') in fromyaml('!!set {2020-01-02: null}')",
    "fromyaml('!!binary SGVsbG8=') in set_strict([fromyaml('!!binary SGVsbG8=')])",
    "set_strict([fromyaml('2020-01-02T03:04:05Z'),fromyaml('2020-01-02T04:04:05+01:00')])|length",
    "toyaml(fromyaml('{2020-01-03: later, 2020-01-02: earlier}'), sort_keys=true)",
    "toyaml(fromyaml('{!!binary Yg==: second, !!binary YQ==: first}'), sort_keys=true)",
    "toyaml(fromyaml('{2020-01-02T03:00:00Z: later, 2020-01-02T03:30:00+01:00: earlier}'), sort_keys=true)",
    "toyaml(fromyaml('{2020-01-03: date, a: string}'), sort_keys=true)",
    "toyaml(fromyaml('2020-01-02T03:04:05Z').date())",
    "toyaml({(2,):[1],(1,):[0]}, sort_keys=true)",
    "fromyaml('!!binary Jw==')", "fromyaml('!!binary Ig==')",
    "fromyaml('!!binary JyI=')", "fromyaml('!!binary AP8KCVw=')",
    "[fromyaml('2020-01-02'), fromyaml('2020-01-02T00:00:00')]",
    "[fromyaml('2020-01-02T03:04:05.123Z')]",
    "[fromyaml('2020-01-02T03:04:05+01:00')]",
    "[fromyaml('2020-01-02T03:04:05-01:00')]",
    "fromyaml('2020-01-02T03:04:05Z').date() is not mapping",
    "fromyaml('2020-01-02') is not iterable",
    "zip(fromyaml('2020-01-02'), default=['fallback'])",
])
def test_yaml_scalar_keys_and_representations_match_core(tmp_path, core_runner, expression):
    project = tmp_path / "project"
    write_project(project, expression)
    compare(project, core_runner)


def test_yaml_date_alias_anchors_match_core(tmp_path, core_runner):
    project = tmp_path / "project"
    write_project(project, "toyaml([value,value])")
    model = project / "models/value.sql"
    model.write_text("{% set value=fromyaml('2020-01-02') %}" + model.read_text())
    compare(project, core_runner)

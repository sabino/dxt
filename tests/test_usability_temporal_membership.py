"""Container comparison preserves identity shortcuts and datetime errors."""
import subprocess

import pytest

from test_usability_commands import core_runner
from test_usability_expression_types import ROOT, DXT, compare, write_project


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


def temporal_project(root, kind, expression):
    write_project(root, "0")
    arguments = "2024,1,1" if kind == "datetime" else "1"
    factory = "modules.datetime." + kind
    prefix = "{% set a=" + factory + "(" + arguments + ",tzinfo=modules.datetime.tzinfo()) %}"
    prefix += "{% set b=" + factory + "(" + arguments + ") %}"
    (root / "models/value.sql").write_text(prefix + "select '{{ " + expression + " }}' as value")


@pytest.mark.parametrize("kind", ["datetime", "time"])
@pytest.mark.parametrize("expression", [
    "a in [a]", "[a].count(a)", "[a].index(a)", "(a,) in [(a,)]",
    "[a] in [[a]]", "{'x':a} in [{'x':a}]",
])
def test_exact_temporal_alias_bypasses_offset_callbacks(tmp_path, core_runner, kind, expression):
    root = tmp_path / "project"
    temporal_project(root, kind, expression)
    compare(root, core_runner)


@pytest.mark.parametrize("kind", ["datetime", "time"])
@pytest.mark.parametrize("expression", [
    "a in [b]", "a not in (b,)", "a is in([b])", "[b].count(a)",
    "(b,).index(a)", "(a,) in [(b,)]", "[a] in [[b]]",
    "{'x':a} in [{'x':b}]", "a in {'x':b}.values()",
    "[b]|select('in',[a])|list",
])
def test_temporal_comparison_errors_propagate_from_members(tmp_path, core_runner, kind, expression):
    root = tmp_path / "project"
    temporal_project(root, kind, expression)
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root), "--select", "value"]
    actual = subprocess.run([DXT, *common], capture_output=True, text=True)
    oracle = core_runner.invoke(["--quiet", *common, "--no-partial-parse"])
    assert actual.returncode != 0, actual.stdout
    assert not oracle.success

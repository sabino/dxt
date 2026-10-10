"""CPython 3.12 sum semantics, with explicit historical 3.11 Core results."""
import json
import subprocess
import sys

import pytest

from test_usability_commands import core_runner
from test_usability_expression_types import ROOT, DXT, compare, write_project


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


@pytest.mark.parametrize("expression,canonical,historical", [
    ("[1e16,1.0,-1e16] | sum", "1.0", "0.0"),
    ("[1.0,1e100,1.0,-1e100] | sum", "2.0", "0.0"),
    ("[1e16,1.0,-1e16,1e16,1.0,-1e16] | sum", "2.0", "0.0"),
    ("[1e16,1.0,-1e16] | sum(start=0.0)", "1.0", "0.0"),
    pytest.param("[1e16,1.0,-1e16] | sum(start=1.0)", "2.0", "0.0", id="float_start_compensation"),
    ("[1,1e16,1.0,-1e16] | sum", "1.0", "0.0"),
    ("[1e16,1.0,-1e16,(-1)**0.5] | sum", "(1+1j)", "(6.123233995736766e-17+1j)"),
])
def test_compensated_sum_targets_cpython_312(tmp_path, core_runner, expression, canonical, historical):
    assert_pinned_sum(tmp_path, core_runner, expression, canonical, historical)


def assert_pinned_sum(tmp_path, core_runner, expression, canonical, historical):
    root = tmp_path / "project"
    write_project(root, expression)
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root), "--select", "value"]
    actual = subprocess.run([DXT, *common, "--target-path", "native"], capture_output=True, text=True)
    assert actual.returncode == 0, actual.stderr
    oracle = core_runner.invoke(["--quiet", *common, "--target-path", "core", "--no-partial-parse"])
    assert oracle.success, oracle.exception
    native = json.loads((root / "native/manifest.json").read_text())["nodes"]["model.expressions.value"]["compiled_code"]
    core = json.loads((root / "core/manifest.json").read_text())["nodes"]["model.expressions.value"]["compiled_code"]
    assert native == f"select '{canonical}' as rendered"
    # Core runs in this Python interpreter. dxt's numeric contract remains
    # CPython 3.12 on every platform; pre-3.12 Core uses naive float summation.
    expected_core = canonical if sys.version_info >= (3, 12) else historical
    assert core == f"select '{expected_core}' as rendered", sys.version


@pytest.mark.parametrize("expression,canonical,historical", [
    ("[modules.re.I,1e16,1.0,-1e16] | sum", "4.0", "4.0"),
    ("[1e16,modules.re.I,1.0,-1e16] | sum", "3.0", "4.0"),
    ("[1e16,1.0,-1e16] | sum(start=modules.re.I)", "4.0", "4.0"),
])
def test_regex_subclasses_preserve_sum_lane_transitions(tmp_path, core_runner, expression, canonical, historical):
    assert_pinned_sum(tmp_path, core_runner, expression, canonical, historical)


@pytest.mark.parametrize("expression", [
    "[1e16,1,-1e16] | sum", "[1e16,true,-1e16] | sum",
    "[1e16,1.0,-1e16] | sum(start=true)",
    "[1e16,1.0,-1e16] | sum(start=2**100)",
    "[1e16,1.0,-1e16] | sum(start=(-1)**0.5)",
    "[2**63,1e16,1.0,-1e16] | sum(start=-(2**63))",
    "[2**63-1,1,-(2**63),1e16,1.0,-1e16] | sum",
    "[1e16,1.0,2**63,-(2**63),-1e16] | sum",
    "[1e308,1e308,-1e308] | sum",
    "[fromyaml('.inf'),fromyaml('-.inf')] | sum",
    "[fromyaml('.nan'),1.0] | sum", "[] | sum(start=-0.0)",
    "[-0.0,-0.0] | sum(start=-0.0)", "[-0.0] | sum",
    "[9007199254740993,9007199254740993] | sum",
    "[true,false,2] | sum(start=false)",
])
def test_sum_fast_lane_transitions_match_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    write_project(root, expression)
    compare(root, core_runner)


def test_empty_nan_sum_creates_a_fresh_float(tmp_path, core_runner):
    root = tmp_path / "project"
    write_project(root, "0")
    (root / "models/value.sql").write_text("{% set start=fromyaml('.nan') %}select '{{ ([]|sum(start=start)) is sameas(start) }}' as rendered")
    compare(root, core_runner)

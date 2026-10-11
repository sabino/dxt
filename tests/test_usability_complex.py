"""Native complex scalar results certified against pinned dbt Core."""
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
    "(-1) ** 0.5",
    "(-8) ** (1.0 / 3.0)",
    "(-16.0) ** 0.25",
    "(-1) ** -0.5",
    "((-1)**0.5) is number",
    "((-1)**0.5) is not float and ((-1)**0.5) is not integer",
    "((-1)**0.5).real",
    "((-1)**0.5).imag",
    "((-1)**0.5).conjugate()",
    "-((-1)**0.5)",
    "+((-1)**0.5)",
    "((-1)**0.5) + 3",
    "3 + ((-1)**0.5)",
    "((-1)**0.5) - 3",
    "3 - ((-1)**0.5)",
    "((-1)**0.5) * 3",
    "3 * ((-1)**0.5)",
    "((-1)**0.5) / 3",
    "3 / ((-1)**0.5)",
    "((-1)**0.5) ** 2",
    "((-1)**0.5) ** -2",
    "((-1)**0.5) ** 0.5",
    "2 ** ((-1)**0.5)",
    "((-1)**0.5) ** ((-1)**0.5)",
    "((-1)**0.5) + ((-1)**0.5)",
    "((-1)**0.5) / ((-1)**0.5)",
    "((-1)**0.5) - ((-1)**0.5)",
    "((-1)**0.5) * 0",
    "((-1)**0.5) ** 0",
    "((-1)**0.5) ** 0 == 1",
    "((-1)**0.5) ** 0 == true",
    "((-1)**0.5) ** 0 != 9007199254740993",
    "not (((-1)**0.5) - ((-1)**0.5))",
    "[(-1)**0.5, ((-1)**0.5)**2]",
    "[((-1)**0.5),((-1)**0.5)] | sum",
    "[((-1)**0.5),((-1)**0.5)] | unique | list",
    "((-1)**0.5) | int(default=42)",
    "((-1)**0.5) | float(default=42)",
    "((-1)**0.5) | string",
    "'{}'.format((-1)**0.5)",
]


@pytest.mark.parametrize("expression", EXPRESSIONS)
def test_complex_scalar_matches_core(tmp_path, core_runner, expression):
    root = tmp_path / "complex_contract"
    write_project(root, expression)
    compare(root, core_runner)


INVALID = [
    "((-1)**0.5) // 2",
    "((-1)**0.5) % 2",
    "((-1)**0.5) < 2",
    "[(-1)**0.5,2] | sort",
    "((-1)**0.5) | tojson",
    "tojson((-1)**0.5)",
    "((-1)**0.5) / 0",
    "((-1)**0.5).conjugate(1)",
    "((-1e308)**1.5)",
]


@pytest.mark.parametrize("expression", INVALID)
def test_invalid_complex_operation_matches_core_failure(tmp_path, core_runner, expression):
    root = tmp_path / "complex_invalid"
    write_project(root, expression)
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root), "--no-partial-parse"]
    native = subprocess.run([str(DXT), *common, "--target-path", "native"], cwd=ROOT, capture_output=True, text=True)
    core = core_runner.invoke(["--quiet", *common, "--target-path", "core"])
    assert native.returncode != 0, native.stdout + native.stderr
    assert not core.success, core.result

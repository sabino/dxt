"""Native str.format fields used by unchanged dbt SQL macros."""
import subprocess

import pytest

from test_usability_commands import core_runner
from test_usability_expression_types import compare, write_project, ROOT, DXT


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


@pytest.mark.parametrize("expression", [
    "'{} {}'.format(1,1.0)",
    "'{1} {0}'.format('a','b')",
    "'{name} {count}'.format(name='é',count=9007199254740993)",
    "'{{{0}}}'.format('column')",
    "'{{}}'.format()",
    "'{} {x}'.format('a',x='b')",
    "'{x} {}'.format('a',x='b')",
    "'{x!s}:{x!r}:{x!a}'.format(x='é')",
    "'{0[item]}:{0[name]}'.format({'item':1,'name':'foo'})",
    "'{0[1]}'.format((1,2))",
    "'{0.column}'.format(api.Column('foo','integer'))",
    "'{}'.format(this)",
    "'{schema}.{identifier}'.format(**{'schema':'main','identifier':'input'})",
    "'{0:}'.format(1.0)",
    "'{} {} {}'.format(*[true,none,(1,)])",
])
def test_native_string_format_matches_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    write_project(root, expression)
    compare(root, core_runner)


@pytest.mark.parametrize("expression", ["'{} {0}'.format(1)", "'{'.format(1)", "'}'.format()", "'{missing}'.format()", "'{2}'.format(1)", "'{0!z}'.format(1)"])
def test_native_string_format_errors_match_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    write_project(root, expression)
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root), "--select", "value"]
    native = subprocess.run([DXT, *common], text=True, capture_output=True)
    oracle = core_runner.invoke(["--quiet", *common, "--no-partial-parse"])
    assert native.returncode != 0
    assert not oracle.success

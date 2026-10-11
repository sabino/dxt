"""Plain Undefined from no-else expressions must retain Core Jinja semantics."""
import subprocess

import pytest

from test_usability_commands import core_runner
from test_usability_expression_types import compare, write_project, ROOT, DXT


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


@pytest.mark.parametrize("expression", [
    "'x' if false",
    "('x' if false) is undefined",
    "('x' if false) is not defined",
    "('x' if false)|default('fallback')",
    "('x' if false)|length",
    "('x' if false)|list",
    "('x' if false)|string",
    "('x' if false) or 'fallback'",
    "('x' if false) == ('y' if false)",
])
def test_plain_undefined_matches_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    write_project(root, expression)
    compare(root, core_runner)


@pytest.mark.parametrize("expression", ["('x' if false).foo|default('bad')", "('x' if false)|int", "('x' if false)|float", "('x' if false)|tojson"])
def test_plain_undefined_errors_match_core(tmp_path, core_runner, expression):
    root = tmp_path / "project"
    write_project(root, expression)
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root), "--select", "value"]
    native = subprocess.run([DXT, *common], text=True, capture_output=True)
    oracle = core_runner.invoke(["--quiet", *common, "--no-partial-parse"])
    assert native.returncode != 0
    assert not oracle.success


def test_dispatch_loop_without_conditional_else_matches_core(tmp_path, core_runner):
    root = tmp_path / "project"
    write_project(root, "0")
    (root / "macros").mkdir()
    (root / "macros/group_by.sql").write_text("""{%- macro group_by(n) -%}
    {{ return(adapter.dispatch('group_by', 'expressions')(n)) }}
{% endmacro %}
{%- macro default__group_by(n) -%}
  group by {% for i in range(1, n + 1) -%}
      {{ i }}{{ ',' if not loop.last }}
   {%- endfor -%}
{%- endmacro -%}
""")
    (root / "models/value.sql").write_text("select 1 as a, 2 as b {{ group_by(2) }}")
    compare(root, core_runner)

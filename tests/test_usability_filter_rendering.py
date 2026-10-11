"""Text filters render live objects through the active native compiler frame."""
import subprocess

import pytest

from test_usability_commands import core_runner
from test_usability_expression_types import ROOT, compare, write_project


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


@pytest.mark.parametrize("render", [
    "[loop]|join", "['a','b']|join(loop)", "loop|lower", "loop|upper",
    "loop|trim", "loop|as_text", "loop|replace('LoopContext','row')",
    "[['x',loop]]|urlencode", "[{'x':loop}]|join(attribute='x')",
    "loop|replace(loop,'x')", "'x'|replace('x',loop)",
])
def test_deferred_loop_filter_rendering_matches_core(tmp_path, core_runner, render):
    root = tmp_path / "project"
    write_project(root, "0")
    (root / "models/value.sql").write_text(
        "select '{% for value in [1,2]|map('int') %}{{ " + render + " }};{% endfor %}' as value"
    )
    compare(root, core_runner)


def test_country_mapping_urlencode_matches_core(tmp_path, core_runner):
    root = tmp_path / "project"
    write_project(root, "modules.pytz.country_names | urlencode")
    compare(root, core_runner)

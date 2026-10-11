"""Typed mapping identities survive native compiler and adapter boundaries."""
import json
import subprocess
from pathlib import Path

import pytest

from test_usability_artifacts import contracts
from test_usability_commands import core_runner
from test_usability_expressions import write_project

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out/bin/dxt"


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


TEMPLATES = [
    "{% set keys = typed_keys() %}select '{% for key in keys %}{{ key }}={{ keys[key] }};{% endfor %}'",
    "{% set keys = typed_keys() %}select '{{ keys.keys()|list }}|{{ keys.items()|list }}'",
    "{% set keys = typed_keys() %}{% set copy=keys.copy() %}select '{{ copy[(1,2)] }}|{{ copy[7] }}'",
    "{% set keys = relation_keys() %}select '{{ keys }}|{{ keys[this] }}'",
    "{% set info=this.information_schema('columns') %}select '{{ [info] }}'",
    "{{ config ( {'materialized': 'table', 'tags': ['mapped']}) }}select 'configured'",
]


def project(root, template):
    write_project(root, "0")
    (root / "models/value.sql").write_text(template)
    (root / "macros").mkdir()
    (root / "macros/keys.sql").write_text(
        "{% macro typed_keys() %}{{ return({(1,2):'tuple', 7:'integer'}) }}{% endmacro %}\n"
        "{% macro relation_keys() %}{{ return({this: 'relation'}) }}{% endmacro %}\n"
    )


@pytest.mark.parametrize("template", TEMPLATES)
def test_macro_returned_mapping_keys_and_relation_repr_match_core(tmp_path, core_runner, template):
    root = tmp_path / "project"
    project(root, template)
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root), "--select", "value"]
    native = subprocess.run([DXT, *common, "--target-path", "native"], text=True, capture_output=True)
    oracle = core_runner.invoke(["--quiet", *common, "--target-path", "core", "--no-partial-parse"])
    assert native.returncode == 0, native.stderr
    assert oracle.success, oracle.exception
    actual = json.loads((root / "native/manifest.json").read_text())["nodes"]["model.expressions.value"]
    expected = json.loads((root / "core/manifest.json").read_text())["nodes"]["model.expressions.value"]
    assert actual["compiled_code"] == expected["compiled_code"]
    assert actual["config"] == expected["config"]
    contracts.assert_artifact(root / "native/manifest.json")
    contracts.assert_artifact(root / "native/run_results.json")


def test_nonstring_config_dictionary_keys_fail_like_core(tmp_path, core_runner):
    root = tmp_path / "project"
    project(root, "{{ config({1: 'table'}) }}select 1")
    common = ["compile", "--project-dir", str(root), "--profiles-dir", str(root), "--select", "value"]
    native = subprocess.run([DXT, *common, "--target-path", "native"], text=True, capture_output=True)
    oracle = core_runner.invoke(["--quiet", *common, "--target-path", "core", "--no-partial-parse"])
    assert native.returncode != 0
    assert not oracle.success

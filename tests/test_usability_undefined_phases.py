"""Ordinary and parse-time undefined values through actual pinned dbt Core."""
import json
import subprocess
from pathlib import Path

import pytest

from test_usability_commands import core_runner
from test_usability_expressions import write_project

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out/bin/dxt"


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


def invoke(project, core_runner, phase, suffix=""):
    common = [phase, "--project-dir", str(project), "--profiles-dir", str(project)]
    if phase == "compile":
        common += ["--select", "value"]
    actual_path = project / ("native_" + phase + suffix)
    expected_path = project / ("core_" + phase + suffix)
    actual = subprocess.run([DXT, *common, "--target-path", str(actual_path), "--no-partial-parse"], text=True, capture_output=True)
    expected = core_runner.invoke(["--quiet", *common, "--target-path", str(expected_path), "--no-partial-parse"])
    assert "InvalidOption" not in actual.stderr
    return actual, expected, actual_path, expected_path


def node(target):
    return json.loads((target / "manifest.json").read_text())["nodes"]["model.expressions.value"]


@pytest.mark.parametrize("template", [
    "{{ missing }}|{{ missing|length }}|{{ missing|list }}|{{ missing|join(',') }}",
    "{{ missing is undefined }}|{{ missing is defined }}|{{ missing is callable }}|{{ missing is iterable }}|{{ missing is sequence }}|{{ missing is mapping }}",
    "{{ missing == other }}|{{ missing != other }}|{{ missing == none }}|{{ missing in [missing] }}",
    "{{ 1 in missing }}|{{ 1 not in missing }}|{{ missing|default('fallback') }}",
    "{% if missing %}wrong{% else %}false{% endif %}{% for item in missing %}wrong{% else %}|empty{% endfor %}",
    "{% set original=missing %}{% set alias=original %}{{ original is sameas(alias) }}|{{ original is sameas(missing) }}",
    "{% set original='value' if false %}{{ original is sameas(original) }}|{{ original is undefined }}|{{ original == missing }}",
    "{{ [missing] }}|{{ {'value':missing} }}|{{ ('value' if false)|string }}",
    "{{ missing.__class__ }}|{{ missing.__repr__ }}",
    "{{ missing|map(attribute='value')|list }}|{{ missing|select|list }}|{{ missing|reject|list }}",
    "{{ missing|upper }}|{{ missing|lower }}|{{ missing|trim }}|{{ missing|string }}",
    "{{ missing|default('x', true) }}|{{ 'x' if missing else 'fallback' }}",
    "{{ [missing,other]|unique|list }}|{{ {missing:'first',other:'second'}|length }}",
])
@pytest.mark.parametrize("phase", ["parse", "compile"])
def test_ordinary_missing_values_match_core(tmp_path, core_runner, template, phase):
    project = tmp_path / "project"
    write_project(project, "0")
    (project / "models/value.sql").write_text("select '" + template + "' as rendered\n")
    actual, expected, native, reference = invoke(project, core_runner, phase)
    assert expected.success, expected.exception
    assert actual.returncode == 0, actual.stderr
    if phase == "compile":
        assert node(native)["compiled_code"] == node(reference)["compiled_code"]


CAPTURE_TEMPLATES = [
    "{% set observed=missing.name %}",
    "{% set observed=missing.field.name %}",
    "{% set observed=missing.field.call().name %}",
    "{% set observed=missing['key'].name %}",
    "{% set observed=missing[:2].name %}",
    "{% set observed=missing().name %}",
    "{% set original=missing %}{% set child=original.field %}{% set observed=original.name~'|'~child.name~'|'~(original is sameas(child)) %}",
    "{% set original=missing %}{% set observed=(original['key'] is sameas(original))~'|'~(original[:2] is sameas(original))~'|'~(original() is sameas(original)) %}",
    "{% set original=missing %}{% set called=original() %}{% set observed=original.name~'|'~(called is sameas(original)) %}",
    "{% set observed=missing.unsafe_callable~'|'~missing.alters_data~'|'~missing.hint %}",
    "{% set observed=missing.__class__.name~'|'~missing.__unknown__.name %}",
    "{% set observed=(missing|attr('__class__')).name~'|'~(missing|attr('__unknown__')).name %}",
    "{% set observed=missing == ('value' if false) %}",
    "{% set original=missing %}{% set observed=(original|attr('field')).name~'|'~original.name %}",
    "{% set observed=missing['field'].name~'|'~missing[1].name %}",
    "{% set original=missing %}{% set forwarded=keep(original) %}{% set child=forwarded.field %}{% set observed=original.name~'|'~forwarded.name~'|'~(original is sameas(forwarded)) %}",
    "{% set observed=plain() == ('value' if false) %}",
]


@pytest.mark.parametrize("template", CAPTURE_TEMPLATES)
def test_capture_aliases_names_and_calls_match_core_parse(tmp_path, core_runner, template):
    project = tmp_path / "project"
    write_project(project, "0")
    (project / "macros").mkdir()
    (project / "macros/keep.sql").write_text("{% macro keep(value) %}{{ return(value) }}{% endmacro %}\n{% macro plain() %}{{ return(unresolved_macro_global) }}{% endmacro %}\n")
    (project / "models/value.sql").write_text("{% if not execute %}" + template + "{% do config(meta={'observed': observed|string}) %}{% endif %}\nselect 1\n")
    actual, expected, native, reference = invoke(project, core_runner, "parse")
    assert expected.success, expected.exception
    assert actual.returncode == 0, actual.stderr
    assert node(native)["config"]["meta"] == node(reference)["config"]["meta"]
    # Compilation runs the ordinary environment without evaluating parse-only
    # captured paths. Both artifacts retain the observed parse configuration.
    actual, expected, native, reference = invoke(project, core_runner, "compile")
    assert expected.success, expected.exception
    assert actual.returncode == 0, actual.stderr
    assert node(native)["compiled_code"] == node(reference)["compiled_code"]
    assert node(native)["config"]["meta"] == node(reference)["config"]["meta"]


@pytest.mark.parametrize("expression,parse_success", [
    ("missing.field", True), ("missing.field.call()", True),
    ("missing['key']", True), ("missing[:2]", True), ("missing()", True),
    ("missing|attr('field')", True),
    ("missing.method(1)", True), ("unknown_function()", True),
    ("missing + 1", False), ("1 + missing", False), ("+missing", False),
    ("-missing", False), ("missing < 1", False), ("missing|int", False),
    ("missing|float", False), ("none|list", False),
    ("1 is defined 2", False), ("1 is string 2", False), ("1 is eq(other=1)", False),
    ("exceptions.raise_compiler_error('authored undefined guard')", False),
])
@pytest.mark.parametrize("phase", ["parse", "compile"])
def test_missing_paths_capture_only_in_parse_and_real_errors_remain(tmp_path, core_runner, expression, parse_success, phase):
    project = tmp_path / "project"
    write_project(project, expression)
    actual, expected, _, _ = invoke(project, core_runner, phase)
    success = phase == "parse" and parse_success
    assert expected.success == success, expected.exception
    assert (actual.returncode == 0) == success, actual.stderr

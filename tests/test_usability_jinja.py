"""Native rendering and dbt Core evidence for general expression/macro contexts."""
import json
import os
from pathlib import Path
import subprocess

import pytest
from jinja2 import Environment, StrictUndefined

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out" / "bin" / "dxt"


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    result = subprocess.run(["zig", "build"], cwd=ROOT, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


def project_at(path, sql, macros=""):
    (path / "models").mkdir(parents=True)
    (path / "macros").mkdir()
    (path / "dbt_project.yml").write_text("name: jinja_demo\nversion: '1.0'\nprofile: jinja_demo\n")
    (path / "models" / "rendered.sql").write_text(sql)
    if macros:
        (path / "macros" / "render.sql").write_text(macros)
    (path / "profiles.yml").write_text(f"jinja_demo:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n      path: {path / 'core.duckdb'}\n      schema: main\n      threads: 1\n")


def compile_dxt(path):
    result = subprocess.run([str(DXT), "compile", "--project-dir", str(path), "--profiles-dir", str(path), "--target-path", "target-dxt"], cwd=ROOT, text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    manifest = json.loads((path / "target-dxt" / "manifest.json").read_text())
    return manifest["nodes"]["model.jinja_demo.rendered"]["compiled_code"]


@pytest.mark.parametrize("sql", [
    "{% set x = 'credit_card' %}select '{{ x|upper }}' as payment",
    "{% set xs = [missing] %}select 1 as marker",
    "{% set xs = ['a\\n'] %}select '{{ xs[0]|replace('\\n','!') }}' as marker",
    "{% set xs = [] %}{% for x in xs %}{{ missing_call() }}{% endfor %}select 1 as marker",
    "{% set xs = [1, 2, 3] %}{% for x in xs %}select {{ x*2 }} as n{% if not loop.last %} union all {% endif %}{% endfor %}",
    "select {{ (2+3)*4 }} as n, '{{ {'key': ['a','b']}['key']|join('-') }}' as joined",
    "{% if false and missing_call() %}select 0{% else %}select 1{% endif %}",
    " \n{%- set x = 3 -%}\n select {{- ' ' ~ x -}} as n",
])
def test_general_jinja_matches_reference_environment(tmp_path, sql):
    project = tmp_path / "project"
    project_at(project, sql)
    compiled = compile_dxt(project)
    reference = Environment(undefined=StrictUndefined, extensions=["jinja2.ext.do"]).from_string(sql).render()
    assert compiled == reference


def test_nested_macro_defaults_keywords_typed_returns_core_1105(tmp_path, monkeypatch):
    monkeypatch.setenv("DBT_SEND_ANONYMOUS_USAGE_STATS", "false")
    monkeypatch.setenv("DXT_JINJA_MARKER", "confirmed")
    project = tmp_path / "macros"
    macros = """{% macro numbers(offset=0, values=[1,2,3]) %}{{ return(values) }}ignored after return{% endmacro %}
{% macro render_number(value, multiplier=2) %}{% if multiplier >= 2 %}{{ return(value * multiplier) }}{% else %}{{ return(value) }}{% endif %}{% endmacro %}
{% macro nested(value, multiplier=2) %}{{ return(render_number(multiplier=multiplier, value=value)) }}{% endmacro %}
"""
    sql = """{{ config(materialized='table') }}
{% set values = numbers(values=[2,3,4]) %}
{% for value in values %}
select {{ nested(value, multiplier=3) }} as n, '{{ env_var('DXT_JINJA_MARKER') }}' as marker
{% if not loop.last %}union all{% endif %}
{% endfor %}
"""
    project_at(project, sql, macros)
    compiled = compile_dxt(project)
    version = subprocess.run(["dbt", "--version"], text=True, capture_output=True)
    assert version.returncode == 0 and "1.10.5" in version.stdout
    result = subprocess.run(["dbt", "compile", "--project-dir", str(project), "--profiles-dir", str(project), "--target-path", "target-core"], cwd=ROOT, text=True, capture_output=True, env=os.environ.copy())
    assert result.returncode == 0, result.stdout + result.stderr
    reference = json.loads((project / "target-core" / "manifest.json").read_text())["nodes"]["model.jinja_demo.rendered"]["compiled_code"]
    assert compiled == reference
    assert "ignored after return" not in compiled
    result = subprocess.run(["duckdb", ":memory:", "-json", "-batch", "-bail", "-c", compiled], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == [{"n": 6, "marker": "confirmed"}, {"n": 9, "marker": "confirmed"}, {"n": 12, "marker": "confirmed"}]

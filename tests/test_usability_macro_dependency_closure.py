"""Nested macro calls seed Core's restricted generic-test parse namespace."""
import json
import subprocess
from pathlib import Path

import pytest

from test_usability_configuration import (
    ConfigurationPair, configuration_oracle, configuration_postgres, configure_adapter,
)
from test_usability_unmatched_generic_tests import compare_tests

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


def setup_case(pair, case):
    pair.write("models/marts/input.sql", "select 1 as id")
    pair.write("macros/positive.sql", "{% test positive(model,column_name) %}{{ return(adapter.dispatch('test_positive')(model,column_name)) }}{% endtest %}")
    pair.write("macros/length.sql", "{% macro length() %}{{ exceptions.raise_compiler_error('filter is not a macro') }}{% endmacro %}")
    dependencies = []
    if case.startswith("recency"):
        date = case == "recency_date"
        body = "{% set threshold = 'cast(' ~ dbt.dateadd('day', -1, dbt.current_timestamp()) ~ ' as ' ~ ('date' if " + str(date).lower() + " else dbt.type_timestamp()) ~ ')' %}"
        body += "{% if [] | length() > 0 %}unused{% endif %}{{ config(meta={'threshold':threshold}) }}select * from {{ model }} where {{ column_name }} < 0"
        dependencies = ["macro.dbt.dateadd", "macro.dbt.current_timestamp", "macro.dbt.type_timestamp"]
    else:
        for package in ["alpha", "zeta"]:
            pair.write(f"dbt_packages/{package}/dbt_project.yml", f"name: {package}\nversion: '1.0'\n")
            inner = "{{ return('" + package + "') }}"
            if package == "alpha" and case in {"nested_error", "filter_argument_error"}:
                inner = "{{ exceptions.raise_compiler_error('nested dependency reached') }}"
            pair.write(f"dbt_packages/{package}/macros/inner.sql", "{% macro inner() %}" + inner + "{% endmacro %}")
        if case.startswith("filter_argument"):
            body = "{% set value = '' | default(alpha.inner(), true) %}"
            dependencies = ["macro.alpha.inner"]
        else:
            pair.write("macros/outer.sql", "{% macro outer(left,right) %}{{ return(left ~ ':' ~ right) }}{% endmacro %}")
            body = "{% set value = outer(alpha.inner(), right=zeta.inner()) %}"
            dependencies = ["macro.configuration_fixture.outer", "macro.alpha.inner", "macro.zeta.inner"]
        if case == "hidden_qualified":
            pair.write("dbt_packages/alpha/macros/hidden.sql", "{% macro hidden() %}{{ return('hidden') }}{% endmacro %}")
            body += "{% set unexposed=alpha.hidden %}{% set value=unexposed() %}"
        body += "{{ config(meta={'choice':value}) }}select * from {{ model }} where {{ column_name }} < 0"
    pair.write("macros/implementation.sql", "{% macro default__test_positive(model,column_name) %}" + body + "{% endmacro %}")
    pair.write("models/schema.yml", json.dumps({"version": 2, "models": [{
        "name": "input", "columns": [{"name": "id", "data_tests": ["positive"]}],
    }]}))
    return dependencies


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("command", ["parse", "compile"])
@pytest.mark.parametrize("case", ["recency_date", "recency_timestamp", "nested_kwargs", "filter_argument"])
def test_nested_dependency_closure_matches_core(tmp_path, configuration_oracle, request, adapter, command, case):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    dependencies = setup_case(pair, case)
    manifests = pair.invoke(command)
    compare_tests(pair, manifests)
    for manifest in manifests:
        macro = manifest["macros"]["macro.configuration_fixture.default__test_positive"]
        assert macro["depends_on"]["macros"] == dependencies


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("command", ["parse", "compile"])
@pytest.mark.parametrize("case,message", [
    ("nested_error", "nested dependency reached"),
    ("filter_argument_error", "nested dependency reached"),
    ("hidden_qualified", "hidden"),
])
def test_nested_and_unexposed_dependency_errors_match_core(tmp_path, configuration_oracle, request, adapter, command, case, message):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    setup_case(pair, case)
    result, reference = pair.invoke(command, success=False)
    assert message in str(reference.exception)
    assert message in result.stdout + result.stderr
    assert "Unsupported" not in result.stderr

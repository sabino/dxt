"""Retained dispatch functions use Core's global resolver at parse and compile."""
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


def setup_generic(pair, case):
    pair.write("models/marts/input.sql", "select 1 as id")
    package = "configuration_fixture"
    if case == "namespaced":
        package = "dependency"
        pair.write("dbt_packages/dependency/dbt_project.yml", "name: dependency\nversion: '1.0'\n")
    directory = "macros" if package == "configuration_fixture" else "dbt_packages/dependency/macros"
    body = "{{ config(tags=['selected'],meta={'selected':'" + package + "'}) }}{{ return('" + package + "') }}"
    if case == "selected_error":
        body = "{{ exceptions.raise_compiler_error('dispatched function reached') }}"
    pair.write(directory + "/choice.sql", "{% macro default__choice() %}" + body + "{% endmacro %}")
    factory = "{% set dispatch = adapter.dispatch %}{% set selected = dispatch('choice') %}"
    if case == "returned_helper":
        pair.write("macros/factory.sql", "{% macro dispatcher() %}{{ return(adapter.dispatch) }}{% endmacro %}")
        factory = "{% set dispatch = dispatcher() %}{% set selected = dispatch('choice') %}"
    if case == "returned_function":
        pair.write("macros/factory.sql", "{% macro factory() %}{% set dispatch=adapter.dispatch %}{{ return(dispatch('choice')) }}{% endmacro %}")
        factory = "{% set selected=factory() %}"
    if case == "keyword_defaults":
        factory = "{% set dispatch = adapter.dispatch %}{% set selected = dispatch(macro_namespace=none,macro_name='choice',packages=none) %}"
    if case == "namespaced":
        factory = "{% set dispatch = adapter.dispatch %}{% set selected = dispatch(macro_name='choice',macro_namespace='dependency') %}"
    hidden = ""
    if case == "hidden_qualified":
        hidden = "{% set hidden=configuration_fixture.default__choice %}{{ config(meta={'hidden':hidden()|string}) }}"
    pair.write("macros/positive.sql", "{% test positive(model,column_name) %}" + factory +
               "{% set value=selected() %}" + hidden +
               "{{ config(tags=['caller'],meta={'choice':value}) }}select * from {{ model }} where {{ column_name }} < 0{% endtest %}")
    pair.write("models/schema.yml", json.dumps({"version": 2, "models": [{
        "name": "input", "columns": [{"name": "id", "data_tests": ["positive"]}],
    }]}))


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("command", ["parse", "compile"])
@pytest.mark.parametrize("case", ["saved_helper", "returned_helper", "returned_function", "keyword_defaults", "namespaced"])
def test_saved_dispatch_and_returned_function_match_core(tmp_path, configuration_oracle, request, adapter, command, case):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    setup_generic(pair, case)
    manifests = pair.invoke(command)
    key, = compare_tests(pair, manifests)
    expected = "dependency" if case == "namespaced" else "configuration_fixture"
    assert manifests[0]["nodes"][key]["config"]["meta"]["choice"] == expected
    assert manifests[0]["nodes"][key]["tags"] == ["selected", "caller"]
    if command == "parse":
        # None of these selected implementations is statically discoverable
        # from a retained dispatch helper, and invoking it does not expose an
        # authored qualified call in TestMacroNamespace.
        assert all("default__choice" not in macro for macro in manifests[0]["nodes"][key]["depends_on"]["macros"])


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("command", ["parse", "compile"])
@pytest.mark.parametrize("case, message", [("selected_error", "dispatched function reached"), ("hidden_qualified", "default__choice")])
def test_saved_dispatch_keeps_selected_and_unexposed_lookup_errors(tmp_path, configuration_oracle, request, adapter, command, case, message):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    setup_generic(pair, case)
    result, reference = pair.invoke(command, success=False)
    assert message in str(reference.exception)
    assert message in result.stdout + result.stderr
    assert "Unsupported" not in result.stderr


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_returned_dispatch_function_uses_current_held_query_session(tmp_path, configuration_oracle, request, adapter):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write("macros/factory.sql", "{% macro factory() %}{% set dispatch=adapter.dispatch %}{{ return(dispatch('session_value')) }}{% endmacro %}")
    pair.write("macros/value.sql", """{% macro default__session_value() %}
{% if execute %}
{% do run_query('create temporary table saved_dispatch_session as select 7 as value') %}
{% set row = run_query('select value from saved_dispatch_session') %}
{{ return(row.columns[0][0]) }}
{% else %}{{ return(0) }}{% endif %}
{% endmacro %}""")
    pair.write("models/marts/result.sql", "{% set selected=factory() %}select {{ selected() }} as value")
    manifests = pair.invoke("compile")
    key = "model.configuration_fixture.result"
    for manifest in manifests:
        assert manifest["nodes"][key]["compiled_code"] == "select 7 as value"
    assert manifests[0]["nodes"][key]["depends_on"]["macros"] == manifests[1]["nodes"][key]["depends_on"]["macros"]

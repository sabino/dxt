"""Core parses schema tests independently of matching the YAML target."""
import json
import subprocess
from pathlib import Path

import pytest

from test_usability_artifacts import contracts
from test_usability_configuration import (
    ConfigurationPair, configuration_oracle, configuration_postgres, configure_adapter,
)

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


def compare_tests(pair, manifests):
    native, core = manifests
    identifiers = {key for key in core["nodes"] if key.startswith("test.")}
    assert {key for key in native["nodes"] if key.startswith("test.")} == identifiers
    assert native["disabled"].keys() == core["disabled"].keys()
    for key in identifiers:
        for field in ("name", "fqn", "path", "original_file_path", "raw_code", "compiled_code",
                      "config", "unrendered_config", "tags", "test_metadata", "depends_on", "attached_node", "file_key_name"):
            assert native["nodes"][key].get(field) == core["nodes"][key].get(field), (key, field)
    for project in pair.projects:
        contracts.assert_artifact(project / "target/manifest.json")
        if (project / "target/run_results.json").exists():
            contracts.assert_artifact(project / "target/run_results.json")
    return identifiers


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("kind", ["models", "seeds"])
@pytest.mark.parametrize("command", ["parse", "build"])
def test_missing_yaml_targets_retain_nonexecuting_generic_tests(tmp_path, configuration_oracle, request, adapter, kind, command):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write("models/marts/input.sql", "select 1 as id")
    pair.write("macros/compare.sql", """{% test compare(model, compare_model) %}
{{ config(fail_calc='count(*)') }}select * from {{ model }} where id < 0
{% endtest %}""")
    pair.write("models/schema.yml", json.dumps({"version": 2, kind: [{
        "name": "absent", "data_tests": [{"compare": {"compare_model": "ref('input')"}}],
        "columns": [{"name": "id", "tags": ["yaml_column"], "data_tests": ["not_null"]}],
    }]}))
    manifests = pair.invoke(command)
    keys = compare_tests(pair, manifests)
    assert len(keys) == 2
    for key in keys:
        assert manifests[0]["nodes"][key]["config"]["enabled"] is False
        assert manifests[0]["nodes"][key]["attached_node"] is None
    if command == "build":
        outcomes = [json.loads((project / "target/run_results.json").read_text())["results"] for project in pair.projects]
        assert [{row["unique_id"]: row["status"] for row in result} for result in outcomes] == [
            {"model.configuration_fixture.input": "success"}, {"model.configuration_fixture.input": "success"},
        ]


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("command", ["parse", "build"])
@pytest.mark.parametrize("expose", [False, True])
def test_namespaced_generic_macro_keeps_core_unqualified_seed_dependency(tmp_path, configuration_oracle, request, adapter, command, expose):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write("dbt_packages/dependency/dbt_project.yml", "name: dependency\nversion: '1.0'\n")
    pair.write("dbt_packages/dependency/macros/positive.sql", """{% test positive(model, column_name) %}
{{ config(severity='warn') }}select * from {{ model }} where {{ column_name }} < 0
{% endtest %}""")
    expose_call = "{% if false %}{{ dependency.test_positive(model, column_name) }}{% endif %}" if expose else ""
    pair.write("macros/positive.sql", """{% test positive(model, column_name) %}
{{ config(severity='error') }}select * from {{ model }} where {{ column_name }} < 0
""" + expose_call + "{% endtest %}")
    pair.write("models/marts/input.sql", "select 1 as id")
    pair.write("models/schema.yml", json.dumps({"version": 2, "models": [{
        "name": "input", "columns": [{"name": "id", "data_tests": ["dependency.positive"]}],
    }]}))
    manifests = pair.invoke(command)
    key, = compare_tests(pair, manifests)
    assert manifests[0]["nodes"][key]["depends_on"]["macros"][:2] == [
        "macro.configuration_fixture.test_positive", "macro.dbt.get_where_subquery",
    ]
    assert ("macro.dependency.test_positive" in manifests[0]["nodes"][key]["depends_on"]["macros"]) is (expose or command == "build")
    assert manifests[0]["nodes"][key]["config"]["severity"] == ("warn" if expose else "ERROR")

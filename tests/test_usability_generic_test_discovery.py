"""Discover and execute tests/generic macros as pinned Core does."""
import json

import pytest

from test_cli import build_dxt  # noqa: F401
from test_usability_adapters import duckdb_environment  # noqa: F401
from test_usability_artifacts import contracts
from test_usability_configuration import (
    ConfigurationPair,
    configuration_oracle,  # noqa: F401
    configuration_postgres,  # noqa: F401
    configure_adapter,
)


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("packaged", [False, True])
@pytest.mark.parametrize("test_path", ["tests", "data_tests"])
def test_generic_directory_macros_parse_and_execute_with_root_and_package_paths(
    tmp_path, request, configuration_oracle, duckdb_environment, adapter, packaged, test_path
):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    package = "dependency" if packaged else "configuration_fixture"
    prefix = "dbt_packages/dependency/" if packaged else ""
    project_options = f"test-paths: [{test_path}]\nflags: {{validate_macro_args: true}}\n"
    if packaged:
        pair.write(prefix + "dbt_project.yml", "name: dependency\nversion: '1.0'\n" + project_options)
    else:
        pair.append_project(project_options)
    macro_path = test_path + "/generic/nested/positive.sql"
    pair.write(prefix + macro_path, """{% macro ignored_helper(model) %}{% if true %}ignored{% endif %}{% endmacro %}
{% test positive(model, column_name) %}select * from {{ model }} where {{ column_name }} < 0{% endtest %}
""")
    pair.write("models/marts/input.sql", "select 1 as id")
    pair.write("models/schema.yml", json.dumps({"version": 2, "models": [{
        "name": "input", "columns": [{"name": "id", "data_tests": [
            ("dependency.positive" if packaged else "positive")
        ]}]
    }]}))
    manifests = pair.invoke("build")
    actual, expected = manifests
    assert actual["macros"].keys() == expected["macros"].keys()
    macro_id = f"macro.{package}.test_positive"
    for field in ["name", "package_name", "path", "original_file_path", "macro_sql", "arguments", "depends_on"]:
        assert actual["macros"][macro_id][field] == expected["macros"][macro_id][field]
    assert actual["macros"][macro_id]["original_file_path"] == macro_path
    assert f"macro.{package}.ignored_helper" not in actual["macros"]
    assert actual["nodes"].keys() == expected["nodes"].keys()
    test_id, = [identifier for identifier in expected["nodes"] if identifier.startswith("test.")]
    for field in ["raw_code", "compiled_code", "config", "test_metadata", "depends_on", "original_file_path"]:
        assert actual["nodes"][test_id][field] == expected["nodes"][test_id][field]
    assert macro_id in actual["nodes"][test_id]["depends_on"]["macros"]
    outcomes = []
    for root in pair.projects:
        contracts.assert_artifact(root / "target/manifest.json")
        contracts.assert_artifact(root / "target/run_results.json")
        rows = json.loads((root / "target/run_results.json").read_text())["results"]
        outcomes.append({row["unique_id"]: (row["status"], row["failures"]) for row in rows})
    assert outcomes[0] == outcomes[1]
    assert outcomes[0][test_id] == ("pass", 0)

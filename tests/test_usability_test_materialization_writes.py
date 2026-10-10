"""Test materialization artifacts keep writes attached to their own resource."""
from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path

import pytest

from test_usability_adapters import duckdb_environment  # noqa: F401
from test_usability_artifacts import contracts
from test_usability_configuration import (
    ConfigurationPair,
    configuration_oracle,  # noqa: F401
    configuration_postgres,  # noqa: F401
    configure_adapter,
)

ROOT = Path(__file__).resolve().parents[1]
CHILD_PAYLOAD = "completed ephemeral child write"
OWN_PAYLOAD = "completed test compilation write"
RESULT_SQL = "select 0 as failures, false as should_warn, false as should_error"


@pytest.fixture(scope="module", autouse=True)
def binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


def project_pair(path, oracle, request, adapter, generic, ordering, ending):
    pair = ConfigurationPair(path, oracle)
    configure_adapter(pair, request, adapter)
    if adapter == "postgres":
        suffix = hashlib.sha256(str(path).encode()).hexdigest()[:12]
        for project in pair.projects:
            profile = project / "profiles.yml"
            profile.write_text(profile.read_text().replace("schema: main", f"schema: testwrites_{project.name}_{suffix}"))
    pair.write("models/input.sql", "{{ config(materialized='table') }}select 1 as id")
    pair.write("models/child.sql", "{{ config(materialized='ephemeral') }}{% if execute %}{% do write(" + repr(CHILD_PAYLOAD) + ") %}{% endif %}select 1 as id")
    write = "{% if execute %}{% do write(" + repr(OWN_PAYLOAD) + ") %}{% endif %}"
    # Ref registers the dependency; Core renders/injects the child's SQL during
    # compilation. Its later RuntimeRefResolver only returns the CTE relation.
    body = "select * from " + ("{{ model }}" if generic else "{{ ref('input') }}") + " where id in (select id from {{ ref('child') }})"
    body = (write if ordering == "before_ref" else "") + body + (write if ordering == "after_ref" else "")
    if generic:
        pair.write("macros/bad_rows.sql", "{% test bad_rows(model) %}" + body + "{% endtest %}")
        pair.write("models/schema.yml", "version: 2\nmodels:\n  - name: input\n    data_tests: [bad_rows]\n")
    else:
        pair.write("tests/check.sql", body)
    relative = "models/schema.yml/bad_rows_input_.sql" if generic else "tests/check.sql"
    own_path = "target/run/configuration_fixture/" + relative
    expected_early = json.dumps(own_path) if ordering != "none" else "none"
    materialization = "{% materialization test, default %}" + (
        "{% if model.get('build_path') != " + expected_early + " %}"
        "{{ exceptions.raise_compiler_error('child write changed the test runtime context') }}{% endif %}"
        "{% set child_relation = ref('child') %}"
        "{% if child_relation.identifier != '__dbt__cte__child' %}"
        "{{ exceptions.raise_compiler_error('materialization did not resolve the ephemeral child') }}{% endif %}"
    )
    if ending == "main":
        payload = RESULT_SQL
        materialization += "{% call statement('main', fetch_result=True) %}" + payload + "{% endcall %}"
    elif ending == "noop":
        payload = "-- completed test noop statement"
        materialization += "{% set table = run_query(" + json.dumps(RESULT_SQL) + ") %}{% call noop_statement('main',message='NOOP',code='NOOP',rows_affected=0,res=table) %}" + payload + "{% endcall %}"
    elif ending == "omitted":
        payload = OWN_PAYLOAD if ordering != "none" else None
        materialization += "{% set table = run_query(" + json.dumps(RESULT_SQL) + ") %}{% do store_raw_result('main',message='NO_WRITE',code='NO_WRITE',rows_affected=0,agate_table=table) %}"
    elif ending == "write_error":
        payload = "completed materialization write before failure"
        materialization += "{% do write(" + json.dumps(payload) + ") %}{{ exceptions.raise_compiler_error('materialization failed after the child reference') }}"
    else:
        payload = OWN_PAYLOAD if ordering != "none" else None
        materialization += "{{ exceptions.raise_compiler_error('materialization failed after the child reference') }}"
    pair.write("macros/materialization.sql", materialization + "{% endmaterialization %}")
    return pair, own_path, payload


def capture(project, own_path, payload, ending):
    target = project / "target"
    for artifact in ["manifest.json", "run_results.json"]:
        contracts.assert_artifact(target / artifact)
    manifest = json.loads((target / "manifest.json").read_text())
    result = json.loads((target / "run_results.json").read_text())
    row, = result["results"]
    node = manifest["nodes"][row["unique_id"]]
    assert node["resource_type"] == "test"
    assert node["compiled"] is row["compiled"] is True
    assert node["build_path"] == (own_path if payload is not None else None)
    own_file = project / own_path
    assert own_file.exists() is (payload is not None)
    if payload is not None:
        assert own_file.read_text() == payload
    child_file = project / "target/run/configuration_fixture/models/child.sql"
    assert child_file.read_text() == CHILD_PAYLOAD
    assert node["build_path"] != str(child_file.relative_to(project))
    assert (project / node["compiled_path"]).read_text() == node["compiled_code"] == row["compiled_code"]
    assert "__dbt__cte__child" in row["compiled_code"]
    if ending in ["error", "write_error"]:
        assert row["status"] == "error" and row["failures"] is None
        assert "materialization failed after the child reference" in row["message"]
    else:
        assert row["status"] == "pass" and row["failures"] == 0 and row["message"] is None
    schema = manifest["nodes"]["model.configuration_fixture.input"]["schema"]
    normalize = lambda value: value.replace(schema, "target_schema") if isinstance(value, str) else value
    return (
        {key: node[key] for key in ["unique_id", "build_path", "compiled_path"]},
        {key: normalize(row[key]) for key in ["unique_id", "status", "failures", "relation_name", "compiled_code", "adapter_response"]},
    )


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("generic", [False, True], ids=["singular", "generic"])
@pytest.mark.parametrize("ordering", ["none", "before_ref", "after_ref"])
@pytest.mark.parametrize("ending", ["main", "noop", "omitted", "error", "write_error"])
def test_core_materialization_publishes_own_writes_and_keeps_child_writes_separate(
    tmp_path, request, monkeypatch, configuration_oracle, duckdb_environment, adapter, generic, ordering, ending,
):
    monkeypatch.setenv("DXT_DUCKDB_LIBRARY", duckdb_environment["DXT_DUCKDB_LIBRARY"])
    monkeypatch.setenv("DXT_DUCKDB_BACKEND", "native")
    pair, own_path, payload = project_pair(tmp_path, configuration_oracle, request, adapter, generic, ordering, ending)
    pair.invoke("run", flags=["--select", "input"])
    pair.invoke("test", success=ending not in ["error", "write_error"])
    actual, expected = [capture(project, own_path, payload, ending) for project in pair.projects]
    assert actual == expected

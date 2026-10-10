"""Reported data-test failures follow Core thresholds, not the raw SQL aggregate."""
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
from test_usability_sql_operations import warehouse_rows

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module", autouse=True)
def binary():
    # Reuse the normal project cache rather than the legacy cold-build fixture.
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


def config_for_policy(policy, signed):
    false_condition = "< -10" if signed else "> 10"
    return {
        "alias": "audit",
        "store_failures": True,
        "fail_calc": "-count(*)" if signed else "count(*)",
        "severity": "warn" if policy in ["warn_pass", "warn_error"] else "error",
        "error_if": "!= 0" if policy in ["warn_pass", "fail", "warn_error"] else false_condition,
        "warn_if": false_condition if policy in ["pass", "warn_pass"] else "!= 0",
    }


def configure_project(pair, adapter, request, generic, config):
    configure_adapter(pair, request, adapter)
    if adapter == "postgres":
        # Keep paired engines and independently parameterized fixtures isolated.
        suffix = hashlib.sha256(str(pair.projects[0].parent).encode()).hexdigest()[:12]
        for project in pair.projects:
            path = project / "profiles.yml"
            path.write_text(path.read_text().replace("schema: main", f"schema: reported_{project.name}_{suffix}"))
    pair.write("models/input.sql", "{{ config(materialized='table') }}select 1 as id union all select 2 union all select 3")
    if generic:
        pair.write("macros/bad_rows.sql", "{% test bad_rows(model) %}select * from {{ model }}{% endtest %}")
        pair.write("models/schema.yml", "version: 2\nmodels:\n  - name: input\n    data_tests:\n      - bad_rows:\n          config: " + json.dumps(config) + "\n")
    else:
        options = ", ".join(f"{key}={value!r}" for key, value in config.items())
        pair.write("tests/check.sql", "{{ config(" + options + ") }}\nselect * from {{ ref('input') }}")


def capture(project, adapter, request, command, config):
    target = project / "target"
    for name in ["manifest.json", "run_results.json"]:
        contracts.assert_artifact(target / name)
    manifest = json.loads((target / "manifest.json").read_text())
    artifact = json.loads((target / "run_results.json").read_text())
    tests = [row for row in artifact["results"] if row["unique_id"].startswith("test.")]
    row, = tests
    assert len(artifact["results"]) == (2 if command == "build" else 1)
    if command == "build":
        model, = [row for row in artifact["results"] if row["unique_id"].startswith("model.")]
        assert model["unique_id"] == "model.configuration_fixture.input" and model["status"] == "success"
    node = manifest["nodes"][row["unique_id"]]
    assert node["compiled"] is row["compiled"] is True
    assert {key: node["config"][key] for key in config} == config
    # The executed query still has three rows when its aggregate passes thresholds.
    audit_rows = warehouse_rows(project, adapter, request, f'select id from "{node["schema"]}"."{node["alias"]}" order by id')
    assert audit_rows == [(1,), (2,), (3,)]
    schema = manifest["nodes"]["model.configuration_fixture.input"]["schema"]
    normalize = lambda value: value.replace(schema, "target_schema") if isinstance(value, str) else value
    return {key: normalize(row[key]) for key in ["unique_id", "status", "failures", "message", "relation_name", "compiled_code", "adapter_response"]}


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("generic", [False, True], ids=["singular", "generic"])
@pytest.mark.parametrize("signed", [False, True], ids=["positive", "negative"])
@pytest.mark.parametrize("policy", ["pass", "warn_pass", "warn", "fail", "warn_error"])
def test_core_reports_zero_for_pass_and_aggregate_for_triggered_thresholds(
    tmp_path, request, monkeypatch, configuration_oracle, duckdb_environment, adapter, generic, signed, policy,
):
    monkeypatch.setenv("DXT_DUCKDB_LIBRARY", duckdb_environment["DXT_DUCKDB_LIBRARY"])
    monkeypatch.setenv("DXT_DUCKDB_BACKEND", "native")
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    config = config_for_policy(policy, signed)
    configure_project(pair, adapter, request, generic, config)
    pair.invoke("run")
    status = "pass" if policy in ["pass", "warn_pass"] else "warn" if policy == "warn" else "fail"
    aggregate = -3 if signed else 3
    reported = 0 if status == "pass" else aggregate
    condition = config["error_if"] if policy == "fail" else config["warn_if"]
    message = None if status == "pass" else f"Got {aggregate} results, configured to {'warn' if status == 'warn' else 'fail'} if {condition}"
    for command in ["test", "build"]:
        flags = []
        if policy == "warn_error":
            flags = ["--warn-error"] if command == "test" else ["--warn-error-options", '{"include": ["LogTestResult"]}']
        pair.invoke(command, flags=flags, success=status != "fail")
        actual, expected = [capture(project, adapter, request, command, config) for project in pair.projects]
        assert actual == expected
        assert actual["status"] == status
        assert actual["failures"] == reported
        assert actual["message"] == message

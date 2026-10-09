"""Source-grounded Core 1.10.5 configuration and resource workflow oracles."""
from __future__ import annotations

import json
import subprocess
from importlib.metadata import version
from pathlib import Path

import pytest

from test_cli import ROOT, DXT, build_dxt, dbt_protobuf_json_compat


@pytest.fixture
def configuration_oracle(monkeypatch):
    from dbt.cli.main import dbtRunner
    import dbt_common.events.base_types as event_types
    from google.protobuf import json_format

    assert version("dbt-core") == "1.10.5"
    assert version("dbt-duckdb") == "1.9.6"
    monkeypatch.setenv("DBT_SEND_ANONYMOUS_USAGE_STATS", "false")
    wrapper = dbt_protobuf_json_compat(json_format.MessageToJson)
    monkeypatch.setattr(json_format, "MessageToJson", wrapper)
    monkeypatch.setattr(event_types, "MessageToJson", wrapper)
    return dbtRunner()


class ConfigurationPair:
    def __init__(self, path: Path, oracle):
        self.oracle = oracle
        self.projects = [path / "dxt", path / "core"]
        for project in self.projects:
            (project / "models/marts").mkdir(parents=True)
            (project / "macros").mkdir()
            (project / "dbt_project.yml").write_text("name: configuration_fixture\nversion: '1.0'\nprofile: configuration_fixture\n")
            (project / "profiles.yml").write_text(
                "configuration_fixture:\n  target: dev\n  outputs:\n    dev:\n"
                "      type: duckdb\n      schema: main\n      threads: 1\n"
                f"      path: {project / 'warehouse.duckdb'}\n"
            )

    def write(self, path: str, content: str):
        for project in self.projects:
            (project / path).parent.mkdir(parents=True, exist_ok=True)
            (project / path).write_text(content)

    def append_project(self, text: str):
        for project in self.projects:
            path = project / "dbt_project.yml"
            path.write_text(path.read_text() + text)

    def invoke(self, command="compile", flags=(), success=True):
        actual, expected = self.projects
        result = subprocess.run([DXT, command, "--project-dir", str(actual), "--profiles-dir", str(actual), *flags], text=True, capture_output=True, cwd=ROOT)
        reference = self.oracle.invoke([command, "--project-dir", str(expected), "--profiles-dir", str(expected), "--no-partial-parse", "--quiet", *flags])
        from dbt.adapters.factory import reset_adapters
        from dbt.adapters.duckdb.connections import DuckDBConnectionManager
        reset_adapters()
        if DuckDBConnectionManager._ENV is not None:
            DuckDBConnectionManager._ENV.close()
            DuckDBConnectionManager._ENV = None
        assert reference.success is success, reference.exception
        assert (result.returncode == 0) is success, result.stdout + result.stderr
        if success:
            return [json.loads((project / "target/manifest.json").read_text()) for project in self.projects]
        return result, reference


@pytest.mark.parametrize("cli_vars", [None, "{options: {enabled: false, values: [7, 8], label: 'true'}, materialization: table}"])
def test_nested_typed_vars_dynamic_config_and_cli_precedence(tmp_path, configuration_oracle, cli_vars):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.append_project("vars:\n  options: {enabled: true, values: [1, 2], label: 'false'}\n  materialization: view\n  metadata: {owner: analytics, nested: [true, null, 3]}\n")
    pair.write("models/marts/rendered.sql", """{{ config(materialized=var('materialization'), meta=var('metadata')) }}
select {{ var('options')['values'][0] }} as number, '{{ var('options')['label'] }}' as label
{% if var('options')['enabled'] %}, 1 as enabled{% else %}, 0 as enabled{% endif %}
""")
    manifests = pair.invoke(flags=["--vars", cli_vars] if cli_vars else [])
    actual, expected = [m["nodes"]["model.configuration_fixture.rendered"] for m in manifests]
    assert actual["compiled_code"] == expected["compiled_code"]
    assert actual["config"]["materialized"] == expected["config"]["materialized"]
    assert actual["config"]["meta"] == expected["config"]["meta"]
    assert actual["meta"] == expected["meta"]


def test_hierarchical_project_config_and_inline_tags_precedence(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.append_project("models:\n  +tags: [all]\n  configuration_fixture:\n    +materialized: table\n    +meta: {owner: analytics, nested: {default: true}}\n    marts:\n      +tags: [marts]\n      +docs: {show: false, node_color: '#ff6600'}\n      +meta: {team: marts}\n")
    pair.write("models/marts/rendered.sql", "{{ config(materialized='view', tags=['inline'], meta={'nested': {'override': True}}) }} select 1 as id")
    manifests = pair.invoke()
    actual, expected = [m["nodes"]["model.configuration_fixture.rendered"] for m in manifests]
    for key in ["materialized", "tags", "meta", "docs"]:
        assert actual["config"][key] == expected["config"][key]
    assert actual["docs"] == expected["docs"]
    assert actual["unrendered_config"] == expected["unrendered_config"]


def test_flow_profile_anchors_environment_target_and_typed_threads(tmp_path, configuration_oracle, monkeypatch):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    monkeypatch.setenv("DXT_CONFIG_SCHEMA", "analytics")
    monkeypatch.setenv("DXT_CONFIG_TARGET", "dev")
    monkeypatch.setenv("DXT_CONFIG_THREADS", "2")
    for project in pair.projects:
        (project / "profiles.yml").write_text(
            "base: &base {type: duckdb, schema: \"{{ env_var('DXT_CONFIG_SCHEMA') }}\", threads: \"{{ env_var('DXT_CONFIG_THREADS') | int }}\"}\n"
            "configuration_fixture:\n  target: \"{{ env_var('DXT_CONFIG_TARGET') }}\"\n  outputs:\n"
            f"    dev: {{<<: *base, path: '{project / 'warehouse.duckdb'}'}}\n"
        )
    pair.append_project("models: {configuration_fixture: {+schema: \"{{ target.schema }}\", +tags: [env]}}\n")
    pair.write("models/marts/rendered.sql", "select {{ target.threads }} as threads, '{{ target.schema }}' as target_schema")
    manifests = pair.invoke()
    actual, expected = [m["nodes"]["model.configuration_fixture.rendered"] for m in manifests]
    assert actual["compiled_code"] == expected["compiled_code"]
    assert actual["schema"] == expected["schema"]
    assert actual["config"]["schema"] == expected["config"]["schema"]
    assert actual["unrendered_config"] == expected["unrendered_config"]


def test_project_disabled_resources_and_inline_override(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.append_project("models: {configuration_fixture: {marts: {+enabled: false, +tags: [disabled]}}}\n")
    pair.write("models/marts/disabled.sql", "select 1 as id")
    pair.write("models/marts/rendered.sql", "{{ config(enabled=True) }} select 2 as id")
    manifests = pair.invoke("parse")
    actual, expected = manifests
    assert set(actual["nodes"]) == set(expected["nodes"])
    assert set(actual["disabled"]) == set(expected["disabled"])


def test_root_package_resource_overrides_and_package_vars(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.append_project("vars: {multiplier: 4, dependency: {specific: 3}}\nmodels: {dependency: {+materialized: table, +tags: [root]}}\n")
    pair.write("dbt_packages/dependency/dbt_project.yml", "name: dependency\nversion: '1.0'\nvars: {multiplier: 2, specific: 1}\nmodels: {dependency: {+tags: [package]}}\n")
    pair.write("dbt_packages/dependency/models/base.sql", "{{ config(materialized='view', tags=['inline']) }} select {{ var('multiplier') * var('specific') }} as value")
    pair.write("models/marts/rendered.sql", "select * from {{ ref('dependency', 'base') }}")
    manifests = pair.invoke()
    actual, expected = [m["nodes"]["model.dependency.base"] for m in manifests]
    assert actual["compiled_code"] == expected["compiled_code"]
    assert actual["config"]["materialized"] == expected["config"]["materialized"]
    assert actual["config"]["tags"] == expected["config"]["tags"]


def test_yaml_model_properties_anchors_typed_metadata_columns_and_precedence(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.append_project("models: {configuration_fixture: {+materialized: table, +meta: {owner: project, retained: true}, +tags: [project]}}\n")
    pair.write("models/marts/rendered.sql", "{{ config(materialized='view', meta={'inline': True}, tags=['inline']) }} select 1 as id")
    pair.write("models/properties.yml", """version: 2
model_defaults: &defaults
  description: 'Orders with "quoted" labels'
  config:
    materialized: table
    meta: {owner: yaml, nested: [1, true, null]}
    tags: [yaml]
    docs: {show: false, node_color: '#123456'}
models:
  - <<: *defaults
    name: rendered
    columns:
      - name: id
        description: Identifier
        data_type: integer
        constraints: [{type: not_null}]
        quote: true
        meta: {owner: data, nested: {enabled: true}}
        tags: [identifier]
""")
    manifests = pair.invoke("parse")
    actual, expected = [m["nodes"]["model.configuration_fixture.rendered"] for m in manifests]
    for key in ["description", "docs", "meta", "unrendered_config", "columns"]:
        assert actual[key] == expected[key]
    for key in ["materialized", "tags", "meta", "docs"]:
        assert actual["config"][key] == expected["config"][key]


def test_inline_singular_test_warning_config_reaches_execution(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write("tests/warning.sql", "{{ config(severity='warn', warn_if='> 0', error_if='> 10', limit=3) }} select 1 as failure")
    manifests = pair.invoke("test")
    actual, expected = [m["nodes"]["test.configuration_fixture.warning"] for m in manifests]
    for key in ["severity", "warn_if", "error_if", "limit"]:
        assert actual["config"][key] == expected["config"][key]
    results = [json.loads((p / "target/run_results.json").read_text())["results"][0] for p in pair.projects]
    assert [result["status"] for result in results] == ["warn", "warn"]
    assert [result["failures"] for result in results] == [1, 1]

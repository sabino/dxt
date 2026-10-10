"""Source-grounded Core 1.10.5 configuration and resource workflow oracles."""
from __future__ import annotations

import json
import subprocess
from importlib.metadata import version
from pathlib import Path

import pytest

from cli_helpers import json_lines

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
        result = subprocess.run([DXT, *command.split(), "--project-dir", str(actual), "--profiles-dir", str(actual), *flags], text=True, capture_output=True, cwd=ROOT)
        reference = self.oracle.invoke([*command.split(), "--project-dir", str(expected), "--profiles-dir", str(expected), "--no-partial-parse", "--quiet", *flags])
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


@pytest.fixture(scope="module")
def configuration_postgres(tmp_path_factory):
    import postgres_fixture as pgserver
    with pgserver.get_server(tmp_path_factory.mktemp("configuration-postgres") / "data") as server:
        yield server


def configure_adapter(pair, request, adapter):
    if adapter == 'postgres':
        from urllib.parse import unquote, urlparse
        assert version('dbt-postgres') == '1.9.1'
        server = request.getfixturevalue('configuration_postgres')
        info = server.get_postmaster_info()
        user = unquote(urlparse(server.get_uri()).username or 'postgres')
        pair.write('profiles.yml', "configuration_fixture:\n  target: dev\n  outputs:\n    dev:\n      type: postgres\n      host: " + json.dumps(str(info.socket_dir)) + "\n      port: " + str(info.port) + "\n      dbname: postgres\n      user: " + user + "\n      password: ''\n      schema: main\n      threads: 1\n")


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


def test_cli_vars_resolve_custom_package_install_path(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.append_project("packages-install-path: '{{ var(\"install_dir\") }}'\n")
    pair.write("vendored/util_pkg/dbt_project.yml", "name: util_pkg\nversion: '1.0'\n")
    pair.write("vendored/util_pkg/models/upstream.sql", "select 7 as id")
    pair.write("models/marts/rendered.sql", "select * from {{ ref('util_pkg', 'upstream') }}")
    manifests = pair.invoke(flags=["--vars", "{install_dir: vendored}"])
    actual, expected = [m["nodes"]["model.configuration_fixture.rendered"] for m in manifests]
    assert actual["compiled_code"] == expected["compiled_code"]
    assert actual["depends_on"]["nodes"] == expected["depends_on"]["nodes"]


def test_source_yaml_anchors_typed_inheritance_and_disabled_resources(tmp_path, configuration_oracle, monkeypatch):
    monkeypatch.setenv("DXT_SOURCE_SCHEMA", "landing")
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.append_project("sources: {configuration_fixture: {raw: {+meta: {project: true}, +tags: [project]}}}\n")
    pair.write("models/properties.yml", """version: 2
source_defaults: &defaults
  schema: "{{ env_var('DXT_SOURCE_SCHEMA') }}"
  description: Upstream event data
  loaded_at_field: loaded_at
  freshness: {warn_after: {count: 4, period: hour}}
  meta: {owner: source, nested: [1, true, null]}
  tags: [source]
sources:
  - <<: *defaults
    name: raw
    tables:
      - name: events
        description: Event records
        meta: {team: events}
        tags: [events]
        freshness: {error_after: {count: 8, period: hour}}
        columns:
          - {name: id, data_type: integer, meta: {nested: {enabled: true}}, tags: [key]}
      - {name: hidden, config: {enabled: false}}
""")
    manifests = pair.invoke("parse")
    actual, expected = [m["sources"]["source.configuration_fixture.raw.events"] for m in manifests]
    for key in ["schema", "database", "identifier", "relation_name", "description", "source_description", "freshness", "loaded_at_field", "meta", "tags", "columns", "config"]:
        assert actual[key] == expected[key], key
    assert "source.configuration_fixture.raw.hidden" not in manifests[0]["sources"]
    assert manifests[0]["disabled"]["source.configuration_fixture.raw.hidden"][0]["config"]["enabled"] is False


@pytest.mark.parametrize("package", ["configuration_fixture", "util_pkg"])
def test_table_custom_generic_tests_keep_typed_arguments_and_package_scope(tmp_path, configuration_oracle, package):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.append_project("flags: {require_generic_test_arguments_property: true}\n")
    prefix = "" if package == "configuration_fixture" else "dbt_packages/util_pkg/"
    if prefix:
        pair.write(prefix + "dbt_project.yml", "name: util_pkg\nversion: '1.0'\n")
    pair.write(prefix + "models/rendered.sql", "select 1 as id")
    pair.write(prefix + "macros/custom.sql", "{% test custom_range(model, threshold=1, options=None) %}select * from {{ model }} where {% if options.enabled %}id > {{ threshold }}{% else %}false{% endif %}{% endtest %}")
    pair.write(prefix + "models/properties.yml", """version: 2
models:
  - name: rendered
    data_tests:
      - custom_range:
          arguments: {threshold: 2, options: {enabled: true, label: safe}}
sources:
  - name: raw
    tables:
      - name: events
        data_tests:
          - custom_range:
              arguments: {threshold: 3, options: {enabled: true, label: source}}
""")
    manifests = pair.invoke(flags=["--select", "resource_type:test"])
    actual, expected = [{uid: node for uid, node in m["nodes"].items() if node["resource_type"] == "test"} for m in manifests]
    assert actual.keys() == expected.keys()
    assert len(actual) == 2
    for uid in expected:
        for key in ["test_metadata", "compiled_code", "depends_on", "attached_node"]:
            assert actual[uid][key] == expected[uid][key], (uid, key)


def test_missing_custom_generic_test_macro_is_rejected_instead_of_omitted(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write("models/rendered.sql", "select 1 as id")
    pair.write("models/properties.yml", "models: [{name: rendered, data_tests: [missing_test]}]\n")
    actual, reference = pair.invoke("compile", success=False)
    assert "macro" in actual.stderr.lower()


def test_namespaced_builtin_name_uses_authored_generic_macro(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write("dbt_packages/util_pkg/dbt_project.yml", "name: util_pkg\nversion: '1.0'\n")
    pair.write("dbt_packages/util_pkg/macros/tests.sql", "{% test not_null(model) %}select * from {{ model }} where false{% endtest %}")
    pair.write("models/rendered.sql", "select 1 as id")
    pair.write("models/properties.yml", "models: [{name: rendered, data_tests: [util_pkg.not_null]}]\n")
    manifests = pair.invoke(flags=["--select", "resource_type:test"])
    actual, expected = [next(node for node in m["nodes"].values() if node["resource_type"] == "test") for m in manifests]
    for key in ["test_metadata", "compiled_code", "depends_on", "attached_node"]:
        assert actual[key] == expected[key]


@pytest.mark.parametrize("latest", [1, 2])
def test_model_versions_latest_explicit_refs_defined_in_and_column_inheritance(tmp_path, configuration_oracle, latest):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.append_project("models: {configuration_fixture: {orders: {+materialized: table, +meta: {owner: versioned}}}}\n")
    pair.write("models/orders_v1.sql", "select 1 as id, 'old' as legacy")
    pair.write("models/custom_orders.sql", "select 2 as id, 'new' as label")
    pair.write("models/marts/rendered.sql", "select * from {{ ref('orders') }} union all select * from {{ ref('orders', v=1) }} union all select * from {{ ref('configuration_fixture', 'orders', version=2) }}")
    pair.write("models/properties.yml", f"""version: 2
models:
  - name: orders
    description: Versioned orders
    latest_version: {latest}
    config: {{tags: [orders]}}
    columns:
      - {{name: id, description: Identifier, data_type: integer, data_tests: [not_null]}}
      - {{name: legacy, description: Old label, data_type: varchar}}
    versions:
      - v: 1
      - v: 2
        defined_in: custom_orders
        description: Current orders
        config: {{meta: {{generation: 2}}}}
        columns:
          - {{include: all, exclude: [legacy]}}
          - {{name: label, description: New label, data_type: varchar}}
""")
    manifests = pair.invoke()
    for uid in ["model.configuration_fixture.orders.v1", "model.configuration_fixture.orders.v2", "model.configuration_fixture.rendered"]:
        actual, expected = [m["nodes"][uid] for m in manifests]
        for key in ["name", "alias", "version", "latest_version", "fqn", "description", "columns", "refs", "depends_on", "compiled_code"]:
            assert actual[key] == expected[key], (uid, key)
        for key in ["materialized", "meta", "tags"]:
            assert actual["config"][key] == expected["config"][key], (uid, key)
    actual_tests, expected_tests = [{uid: n for uid, n in m["nodes"].items() if n["resource_type"] == "test"} for m in manifests]
    assert actual_tests.keys() == expected_tests.keys()
    assert len(actual_tests) == 2
    for uid in expected_tests:
        for key in ["name", "test_metadata", "refs", "depends_on", "attached_node"]:
            assert actual_tests[uid][key] == expected_tests[uid][key], (uid, key)
        assert " ".join(actual_tests[uid]["compiled_code"].replace('"id"', 'id').split()) == " ".join(expected_tests[uid]["compiled_code"].split())


def test_latest_model_version_uses_unversioned_file_and_null_alias_default(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write("models/orders_v1.sql", "select 1 as id")
    pair.write("models/orders.sql", "select 2 as id")
    pair.write("models/marts/rendered.sql", "select * from {{ ref('orders') }}")
    pair.write("models/properties.yml", "models: [{name: orders, config: {alias: null}, versions: [{v: 1}, {v: 2}]}]\n")
    manifests = pair.invoke()
    for uid in ["model.configuration_fixture.orders.v2", "model.configuration_fixture.rendered"]:
        actual, expected = [m["nodes"][uid] for m in manifests]
        for key in ["name", "alias", "version", "latest_version", "fqn", "depends_on", "compiled_code"]:
            assert actual[key] == expected[key], (uid, key)



@pytest.mark.parametrize("selection, names", [("version:latest", ["model.configuration_fixture.orders.v2"]), ("version:old", ["model.configuration_fixture.orders.v1"]), ("version:prerelease", ["model.configuration_fixture.orders.v3"]), ("version:none", ["model.configuration_fixture.rendered"]), ("orders.v1", ["model.configuration_fixture.orders.v1"]), ("fqn:configuration_fixture.orders.v2", ["model.configuration_fixture.orders.v2"])])
def test_model_version_selectors_match_core(tmp_path, configuration_oracle, selection, names):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    for v in [1, 2, 3]:
        pair.write(f"models/orders_v{v}.sql", f"select {v} as id")
    pair.write("models/marts/rendered.sql", "select 0 as id")
    pair.write("models/properties.yml", "models: [{name: orders, latest_version: 2, versions: [{v: 1}, {v: 2}, {v: 3}]}]\n")
    actual, expected = pair.projects
    args = ["ls", "--select", selection, "--resource-type", "model", "--output", "json", "--output-keys", "unique_id"]
    result = subprocess.run([DXT, *args, "--project-dir", str(actual), "--profiles-dir", str(actual)], text=True, capture_output=True, cwd=ROOT)
    reference = configuration_oracle.invoke([*args, "--project-dir", str(expected), "--profiles-dir", str(expected), "--no-partial-parse", "--quiet"])
    assert reference.success, reference.exception
    assert result.returncode == 0, result.stderr
    reference_ids = sorted(json.loads(line)["unique_id"] for line in reference.result)
    assert sorted(row["unique_id"] for row in json_lines(result.stdout)) == reference_ids == names


def test_model_version_columns_default_inheritance_and_explicit_replacement(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write("models/orders_v1.sql", "select 1 as id, 'x' as label")
    pair.write("models/orders_v2.sql", "select 2 as id, 'x' as label")
    pair.write("models/properties.yml", """models:
  - name: orders
    columns:
      - {name: id, description: Identifier, data_type: integer, data_tests: [not_null]}
      - {name: label, description: Label, data_type: varchar}
    versions:
      - {v: 1}
      - v: 2
        columns: [{name: id, description: New identifier}]
""")
    manifests = pair.invoke()
    for uid in ["model.configuration_fixture.orders.v1", "model.configuration_fixture.orders.v2"]:
        actual, expected = [m["nodes"][uid] for m in manifests]
        assert actual["columns"] == expected["columns"]
    actual, expected = [{uid: n["test_metadata"] for uid, n in m["nodes"].items() if n["resource_type"] == "test"} for m in manifests]
    assert actual == expected


def test_source_config_partial_thresholds_and_deferred_loaded_at_query(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.append_project("vars: {minimum_id: 0}\n")
    pair.write("models/properties.yml", """sources:
  - name: raw
    schema: main
    config:
      loaded_at_field: loaded_at
      freshness: {warn_after: {count: 1, period: hour}, error_after: {count: 1, period: day}}
    tables:
      - name: events
        config:
          loaded_at_query: "select max(loaded_at) from {{ this }} where id > {{ var('minimum_id') }}"
          freshness: {warn_after: {count: 3, period: hour}}
""")
    manifests = pair.invoke("parse")
    actual, expected = [m["sources"]["source.configuration_fixture.raw.events"] for m in manifests]
    for key in ["loaded_at_field", "loaded_at_query", "freshness", "config"]:
        assert actual[key] == expected[key], key
    import duckdb
    for project in pair.projects:
        with duckdb.connect(str(project / "warehouse.duckdb")) as connection:
            connection.execute("create table events as select 1 as id, current_timestamp - interval '2 hours' as loaded_at")
    pair.invoke("source freshness")
    actual_result, expected_result = [json.loads((p / "target/sources.json").read_text())["results"][0] for p in pair.projects]
    assert actual_result["status"] == expected_result["status"] == "pass"
    assert actual_result["criteria"] == expected_result["criteria"]


def test_source_yaml_freshness_replaces_project_thresholds(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.append_project("sources: {configuration_fixture: {raw: {+freshness: {warn_after: {count: 3, period: hour}}}}}\n")
    pair.write("models/properties.yml", "sources: [{name: raw, tables: [{name: events, loaded_at_field: loaded_at, freshness: {error_after: {count: 2, period: day}}}]}]\n")
    manifests = pair.invoke("parse")
    actual, expected = [m["sources"]["source.configuration_fixture.raw.events"] for m in manifests]
    assert actual["freshness"] == expected["freshness"]


@pytest.mark.parametrize("requirement, flags, success", [(">=1.5.0,<2.0.0", [], True), ("=1.10.5", [], True), (">=1.11.0", [], False), (">=1.11.0", ["--no-version-check"], True), ("bad", ["--no-version-check"], False)])
def test_project_required_core_version_matches_pinned_core(tmp_path, configuration_oracle, requirement, flags, success):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.append_project(f"require-dbt-version: '{requirement}'\n")
    pair.write("models/marts/rendered.sql", "select 1 as id")
    pair.invoke("parse", flags=flags, success=success)


def test_installed_package_required_core_version_is_checked(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write("dbt_packages/util_pkg/dbt_project.yml", "name: util_pkg\nversion: '1.0'\nrequire-dbt-version: '>=1.11.0'\n")
    pair.write("dbt_packages/util_pkg/models/upstream.sql", "select 1 as id")
    pair.invoke("parse", success=False)
    pair.invoke("parse", flags=["--no-version-check"])


@pytest.mark.parametrize("flags", [[], ["--no-print", "--no-version-check", "--threads", "2"]])
def test_jinja_flags_and_core_version_use_effective_command_options(tmp_path, configuration_oracle, flags):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write("models/marts/rendered.sql", "{{ config(meta={'no_print': flags.NO_PRINT, 'version_check': flags.VERSION_CHECK, 'core': dbt_version}) }} select '{{ flags.FULL_REFRESH }}' as full_refresh, '{{ flags.FAIL_FAST }}' as fail_fast")
    manifests = pair.invoke(flags=flags)
    actual, expected = [m["nodes"]["model.configuration_fixture.rendered"] for m in manifests]
    assert actual["compiled_code"] == expected["compiled_code"]
    assert actual["config"]["meta"] == expected["config"]["meta"]


@pytest.mark.parametrize('adapter_type', ['duckdb', 'postgres'])
def test_bundled_core_and_adapter_definitions_match_pinned_manifest(tmp_path, configuration_oracle, adapter_type):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('models/marts/bundled.sql', 'select 1 as id\n')
    if adapter_type == 'postgres':
        pair.write('profiles.yml', 'configuration_fixture:\n  target: dev\n  outputs:\n    dev: {type: postgres, host: localhost, port: 1, dbname: configuration_fixture, schema: main, user: fixture, password: fixture, threads: 1}\n')
    actual, expected = pair.invoke('parse')
    internal = lambda manifest: {key: value for key, value in manifest['macros'].items() if value['package_name'] in {'dbt', 'dbt_' + adapter_type}}
    actual_macros, expected_macros = internal(actual), internal(expected)
    assert actual_macros.keys() == expected_macros.keys()
    for key in expected_macros:
        for field in ['name', 'package_name', 'path', 'original_file_path', 'macro_sql']:
            assert actual_macros[key][field] == expected_macros[key][field], (key, field)
    assert actual['docs']['doc.dbt.__overview__'] == expected['docs']['doc.dbt.__overview__']


@pytest.mark.parametrize('sql', [
    "select cast(1 as {{ dbt.type_int() }}) as id, cast('hello' as {{ dbt.type_string() }}) as label",
    "select cast(1 as {{ dbt.type_numeric() }}) as amount, cast(1 as {{ dbt.type_float() }}) as value, cast(true as {{ dbt.type_boolean() }}) as enabled",
    "select {{ dbt.string_literal('hello') }} as label, {{ dbt.hash(\"'hello'\") }} as digest",
    "select {{ dbt.dateadd('day', 2, \"date '2024-01-01'\") }} as added, {{ dbt.datediff(\"date '2024-01-01'\", \"date '2024-01-03'\", 'day') }} as delta",
    "{{ '\\n\\n' }}{%- set ignored = 1 %}select 1 as id",
    "\n\n{# comment preserves preceding literal whitespace #}{%- set ignored = 1 -%}select 1 as id",
    "select {{ dbt.concat([\"'a'\", \"'b'\"]) }} as joined, {{ dbt.split_part(\"'a,b'\", \"','\", 2) }} as part",
])
def test_upstream_sql_macros_compile_and_execute_unchanged(tmp_path, configuration_oracle, sql):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('models/marts/bundled.sql', '{{ config(materialized="table") }}\n' + sql + '\n')
    actual, expected = pair.invoke('run')
    assert actual['nodes']['model.configuration_fixture.bundled']['compiled_code'] == expected['nodes']['model.configuration_fixture.bundled']['compiled_code']
    import duckdb
    rows = []
    for project in pair.projects:
        with duckdb.connect(str(project / 'warehouse.duckdb'), read_only=True) as connection:
            rows.append(connection.execute('select * from main.bundled').fetchall())
    assert rows[0] == rows[1]


@pytest.mark.parametrize('expression', [
    "r",
    "r.render()",
    "r.include(database=false)",
    "r.quote(identifier=false)",
    "r.incorporate(path={'schema': 'other', 'identifier': 'changed'}, type='view')",
    "r.replace_path(identifier='changed').identifier",
    "r.without_identifier()",
    "r.incorporate(type='view').is_view",
    "r.matches(schema='Main', identifier='Thing')",
    "r.information_schema('columns')",
    "r.information_schema().schema",
])
def test_native_relation_factories_and_nested_methods_match_core(tmp_path, configuration_oracle, expression):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('models/marts/relations.sql', "{% set r = api.Relation.create(database='warehouse', schema='Main', identifier='Thing', type='table') %}\nselect '{{ " + expression + " }}' as value\n")
    actual, expected = pair.invoke('compile')
    assert actual['nodes']['model.configuration_fixture.relations']['compiled_code'] == expected['nodes']['model.configuration_fixture.relations']['compiled_code']


def test_native_this_ref_source_relations_return_through_macros(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('models/marts/parent.sql', '{{ config(materialized="table") }}\nselect 1 as id\n')
    pair.write('models/schema.yml', "version: 2\nsources:\n  - name: raw\n    schema: main\n    tables:\n      - name: parent\n")
    pair.write('macros/relocated.sql', "{% macro relocated(relation) %}{{ return(relation.incorporate(path={'identifier': 'parent'})) }}{% endmacro %}")
    pair.write('models/marts/relations.sql', "{% set dependency = ref('parent') %}{% set incoming = source('raw', 'parent') %}\nselect '{{ this.identifier }}' as model_name, '{{ dependency.type }}' as kind, '{{ incoming.schema }}' as source_schema from {{ relocated(this).include(database=false) }}\n")
    actual, expected = pair.invoke('run')
    assert actual['nodes']['model.configuration_fixture.relations']['compiled_code'] == expected['nodes']['model.configuration_fixture.relations']['compiled_code']
    assert sorted(actual['nodes']['model.configuration_fixture.relations']['depends_on']['nodes']) == sorted(expected['nodes']['model.configuration_fixture.relations']['depends_on']['nodes'])


@pytest.mark.parametrize('expression', ['r.matches()', "r.matches(identifier='thing')"])
def test_native_relation_invalid_and_approximate_matching_fails_like_core(tmp_path, configuration_oracle, expression):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('models/marts/relations.sql', "{% set r = api.Relation.create(schema='Main', identifier='Thing') %}\nselect '{{ " + expression + " }}' as value\n")
    pair.invoke('compile', success=False)


@pytest.mark.parametrize('authored_database', [None, 'analytics'])
def test_postgres_resource_database_identity_matches_core(tmp_path, configuration_oracle, authored_database):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('profiles.yml', 'configuration_fixture:\n  target: dev\n  outputs:\n    dev: {type: postgres, host: localhost, port: 1, dbname: configuration_fixture, schema: main, user: fixture, password: fixture, threads: 1}\n')
    inline = '{{ config(database="' + authored_database + '") }}\n' if authored_database else ''
    pair.write('models/marts/identity.sql', inline + 'select 1 as id\n')
    pair.write('models/schema.yml', 'version: 2\nsources: [{name: raw, schema: landing, tables: [{name: orders}]}]\n')
    actual, expected = pair.invoke('parse')
    for manifest in [actual, expected]:
        assert manifest['nodes']['model.configuration_fixture.identity']['database'] == (authored_database or 'configuration_fixture')
        assert manifest['sources']['source.configuration_fixture.raw.orders']['database'] == 'configuration_fixture'


@pytest.mark.parametrize('expression', [
    "api.Column.create('label', 'string').data_type",
    "api.Column('label', 'varchar', 12).data_type",
    "api.Column('amount', 'numeric', numeric_precision=18, numeric_scale=3).data_type",
    "api.Column('id', 'integer').is_integer()",
    "api.Column('id', 'integer').is_numeric()",
    "api.Column('ratio', 'double').is_float()",
    "api.Column('label', 'varchar', 12).quoted",
    "api.Column('label', 'varchar', 12).string_size()",
    "api.Column('label', 'varchar', 12).can_expand_to(api.Column('label', 'varchar', 24))",
    "api.Column('id', 'integer').literal(7)",
    "api.Relation.add_ephemeral_prefix('orders')",
])
def test_native_adapter_column_values_match_core(tmp_path, configuration_oracle, expression):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('models/marts/context.sql', "select '{{ " + expression + " }}' as value\n")
    actual, expected = pair.invoke('compile')
    assert actual['nodes']['model.configuration_fixture.context']['compiled_code'] == expected['nodes']['model.configuration_fixture.context']['compiled_code']


def test_native_model_and_configuration_context_match_core(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('models/schema.yml', 'version: 2\nmodels:\n  - name: context\n    description: A context fixture\n    config: {materialized: table, meta: {owner: analytics}}\n    columns:\n      - {name: id, data_type: integer, description: Identifier}\n')
    pair.write('models/marts/context.sql', "select '{{ model.name }}' as name, '{{ model.config.materialized }}' as materialization, '{{ model.columns.id.data_type }}' as declared_type, '{{ config.get(\"contract\").enforced }}' as enforced, '{{ config.get(\"missing\", \"fallback\") }}' as fallback, '{{ adapter.type() }}' as adapter\n")
    actual, expected = pair.invoke('run')
    assert actual['nodes']['model.configuration_fixture.context']['compiled_code'] == expected['nodes']['model.configuration_fixture.context']['compiled_code']


def test_native_required_configuration_missing_fails_like_core(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('models/marts/context.sql', 'select {{ config.require("missing") }} as value\n')
    pair.invoke('compile', success=False)


@pytest.mark.parametrize('setup, expression', [
    ("{% set items = [] %}{% do items.append('first') %}{% do items.extend(['second', 'third']) %}", "items | join(',')"),
    ("{% set left = [] %}{% set right = [] %}{% do left.append(1) %}", "right | length"),
    ("{% set items = [1, 2, 3] %}{% set alias = items %}{% set removed = items.pop(-2) %}", "alias | join(',') ~ ':' ~ removed"),
    ("{% set items = [1] %}{% set nested = {'child': items} %}{% do items.append(2) %}", "nested.child | join(',')"),
    ("{% set options = {} %}{% set alias = options %}{% do options.update({'one': 1}, two=2) %}", "alias.one ~ ',' ~ alias.two"),
    ("{% set options = {'one': 1, 'two': 2} %}{% set alias = options %}{% set removed = options.pop('one') %}", "alias.two ~ ':' ~ (alias | length) ~ ':' ~ removed"),
    ("{% set items = [1] %}{% set alias = items %}{% do items.clear() %}", "alias | length"),
    ("{% set options = {'one': 1} %}{% set alias = options %}{% do options.clear() %}", "alias | length"),
    ("{% set options = {} %}", "options.pop('missing', 'fallback')"),
    ("{% set items = [] %}{% for number in [1, 2, 3] %}{% do items.append(number) %}{% endfor %}", "items | join(',')"),
])
def test_native_mutable_macro_containers_match_core(tmp_path, configuration_oracle, setup, expression):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('models/marts/containers.sql', setup + "select '{{ " + expression + " }}' as value")
    actual, expected = pair.invoke('compile')
    assert actual['nodes']['model.configuration_fixture.containers']['compiled_code'] == expected['nodes']['model.configuration_fixture.containers']['compiled_code']


def test_native_macro_argument_mutation_preserves_caller_aliases(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('macros/collect.sql', "{% macro collect(items) %}{% do items.append(7) %}{{ return(items) }}{% endmacro %}")
    pair.write('models/marts/containers.sql', "{% set items = [] %}{% set returned = collect(items) %}select '{{ items | join(',') }}' as items, '{{ returned | join(',') }}' as returned")
    actual, expected = pair.invoke('compile')
    assert actual['nodes']['model.configuration_fixture.containers']['compiled_code'] == expected['nodes']['model.configuration_fixture.containers']['compiled_code']


@pytest.mark.parametrize('setup, expression', [("{% set items = [] %}", "items.pop()"), ("{% set options = {} %}", "options.pop('missing')"), ("{% set items = [1] %}", "items.pop(3)"), ("{% set items = [1] %}", "items.extend(7)")])
def test_native_invalid_container_mutation_fails_like_core(tmp_path, configuration_oracle, setup, expression):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('models/marts/containers.sql', setup + "select '{{ " + expression + " }}' as value")
    pair.invoke('compile', success=False)


@pytest.mark.parametrize('expression', [
    "result | length",
    "result is mapping",
    "result[0][0]",
    "result.rows[0]['id']",
    "result.rows[0].id",
    "result.columns[0].values() | join(',')",
    "result.columns['id'].values() | join(',')",
    "result.column_names | join(',')",
    "result.columns | map(attribute='name') | join(',')",
])
@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_native_query_table_sequences_match_core(tmp_path, configuration_oracle, expression, request, adapter):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('models/marts/query.sql', "{% if execute %}{% set result = run_query('select 1 as id union all select 2 as id order by id') %}select '{{ " + expression + " }}' as value{% else %}select 0 as value{% endif %}")
    actual, expected = pair.invoke('compile')
    assert actual['nodes']['model.configuration_fixture.query']['compiled_code'] == expected['nodes']['model.configuration_fixture.query']['compiled_code']


def test_native_query_rows_iterate_and_unpack_through_macros(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('macros/collect_rows.sql', "{% macro collect_rows(rows) %}{% set results = [] %}{% for row in rows %}{% do results.append(row[0] ~ ':' ~ row['label']) %}{% endfor %}{{ return(results) }}{% endmacro %}")
    pair.write('models/marts/query.sql', "{% if execute %}{% set result = run_query(\"select 1 as id, 'one' as label union all select 2 as id, 'two' as label order by id\") %}select '{{ collect_rows(result) | join(',') }}' as value{% else %}select 0 as value{% endif %}")
    actual, expected = pair.invoke('compile')
    assert actual['nodes']['model.configuration_fixture.query']['compiled_code'] == expected['nodes']['model.configuration_fixture.query']['compiled_code']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_native_adapter_introspection_uses_typed_columns_and_project_dispatch(tmp_path, configuration_oracle, request, adapter):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('models/marts/parent.sql', '{{ config(materialized="table") }}select 1::integer as id, \'hello\'::varchar as label')
    pair.invoke('run')
    pair.write('models/marts/describe.sql', "{% set dependency = ref('parent') %}{% if execute %}{% set existing = adapter.get_relation(database=dependency.database, schema=dependency.schema, identifier=dependency.identifier) %}{% set columns = adapter.get_columns_in_relation(existing) %}select '{{ existing.type }}' as relation_type, '{{ columns | map(attribute='name') | join(',') }}' as names, '{{ columns[0].dtype }}' as dtype, '{{ columns[0].is_integer() }}' as is_integer, '{{ columns[1].data_type }}' as label_type{% else %}select 0{% endif %}")
    actual, expected = pair.invoke('compile')
    assert actual['nodes']['model.configuration_fixture.describe']['compiled_code'] == expected['nodes']['model.configuration_fixture.describe']['compiled_code']
    pair.write('macros/get_columns.sql', "{% macro " + adapter + "__get_columns_in_relation(relation) %}{{ return([api.Column('overridden', 'integer')]) }}{% endmacro %}")
    pair.write('models/marts/describe.sql', "{% set dependency = ref('parent') %}{% if execute %}select '{{ adapter.get_columns_in_relation(dependency)[0].name }}' as value{% else %}select 0{% endif %}")
    actual, expected = pair.invoke('compile')
    assert actual['nodes']['model.configuration_fixture.describe']['compiled_code'] == expected['nodes']['model.configuration_fixture.describe']['compiled_code']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_native_adapter_execute_and_named_statement_results_match_core(tmp_path, configuration_oracle, request, adapter):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('models/marts/query.sql', "{% if execute %}{% set response, table = adapter.execute('select 1 as id', fetch=true) %}{% call statement('named', fetch_result=true, auto_begin=false) %}select 1 as id{% endcall %}{% call statement('named', fetch_result=true, auto_begin=false) %}select 2 as id{% endcall %}select '{{ response }}' as message, '{{ response.code }}' as code, '{{ response.rows_affected }}' as count, '{{ table[0][0] }}' as row, '{{ load_result('named').data[0][0] }}' as latest{% else %}select 0{% endif %}")
    actual, expected = pair.invoke('compile')
    assert actual['nodes']['model.configuration_fixture.query']['compiled_code'] == expected['nodes']['model.configuration_fixture.query']['compiled_code']


@pytest.mark.parametrize('name, success', [('named', False), ('main', True)])
def test_native_statement_result_consumption_matches_core(tmp_path, configuration_oracle, name, success):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('models/marts/query.sql', "{% if execute %}{% call statement('" + name + "', fetch_result=true, auto_begin=false) %}select 1 as id{% endcall %}{% set first = load_result('" + name + "') %}{% set second = load_result('" + name + "') %}select {{ second.data[0][0] }} as id{% else %}select 0{% endif %}")
    if name == 'main':
        # 'main' invokes the upstream runtime writer. Use a non-main named
        # result with explicit store_result to test this provider contract.
        pair.write('models/marts/query.sql', "{% if execute %}{% set table = run_query('select 1 as id') %}{% do store_result('main', response={}, agate_table=table) %}{% set first = load_result('main') %}{% set second = load_result('main') %}select {{ second.data[0][0] }} as id{% else %}select 0{% endif %}")
    pair.invoke('compile', success=success)


@pytest.mark.parametrize('materialized', ['table', 'view', 'materialized_view'])
def test_postgres_docs_catalog_matches_actual_relations_and_comments(tmp_path, configuration_oracle, request, materialized):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, 'postgres')
    pair.write('models/marts/catalog_entry.sql', "{{ config(materialized='" + materialized + "') }}select 1::integer as id, 'hello'::varchar(24) as label")
    pair.invoke('run')
    import psycopg2
    server = request.getfixturevalue('configuration_postgres')
    with psycopg2.connect(server.get_uri()) as connection:
        with connection.cursor() as cursor:
            cursor.execute('comment on ' + ('materialized view' if materialized == 'materialized_view' else materialized) + ' main.catalog_entry is %s', ("Revenue owner's table",))
            cursor.execute('comment on column main.catalog_entry.label is %s', ('Customer label',))
    pair.write('models/sources.yml', "version: 2\nsources:\n  - name: warehouse\n    schema: main\n    tables:\n      - name: same_relation\n        identifier: catalog_entry\n")
    pair.invoke('docs generate')
    actual, expected = [json.loads((project / 'target/catalog.json').read_text()) for project in pair.projects]
    assert actual['errors'] == expected['errors']
    assert actual['nodes'] == expected['nodes']
    assert actual['sources'] == expected['sources']
    entry = actual['nodes']['model.configuration_fixture.catalog_entry']
    assert entry['metadata']['comment'] == "Revenue owner's table"
    assert entry['metadata']['owner']
    assert entry['columns']['label']['comment'] == 'Customer label'


def test_postgres_docs_catalog_uses_project_adapter_dispatch(tmp_path, configuration_oracle, request):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, 'postgres')
    pair.write('models/marts/catalog_entry.sql', "{{ config(materialized='table') }}select 1::integer as id")
    pair.invoke('run')
    pair.write('macros/catalog.sql', """{% macro postgres__get_catalog_relations(information_schema, relations) %}
{% set relations = relations | list %}
{% call statement('catalog', fetch_result=true) %}
select '{{ information_schema.database }}' as table_database,
       '{{ relations[0].schema }}' as table_schema,
       '{{ relations[0].identifier }}' as table_name,
       'BASE TABLE' as table_type, 'Dispatched comment' as table_comment,
       'id' as column_name, 1 as column_index, 'integer' as column_type,
       'Dispatched column' as column_comment, 'Dispatched owner' as table_owner
{% endcall %}{{ return(load_result('catalog').table) }}{% endmacro %}
""")
    pair.invoke('docs generate')
    actual, expected = [json.loads((project / 'target/catalog.json').read_text()) for project in pair.projects]
    assert actual['nodes'] == expected['nodes']
    assert actual['nodes']['model.configuration_fixture.catalog_entry']['metadata']['owner'] == 'Dispatched owner'


def test_postgres_docs_catalog_rejects_other_database(tmp_path, configuration_oracle, request):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, 'postgres')
    pair.write('models/marts/catalog_entry.sql', "{{ config(materialized='table') }}select 1::integer as id")
    pair.invoke('run')
    pair.write('models/sources.yml', "version: 2\nsources:\n  - name: other_database\n    database: unsupported_database\n    schema: main\n    tables:\n      - name: catalog_entry\n")
    pair.invoke('docs generate', success=False)


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_native_query_schema_columns_match_core_adapter_types(tmp_path, configuration_oracle, request, adapter):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('models/marts/query.sql', """{% if execute %}
{% set columns = adapter.get_column_schema_from_query("select 1::smallint as small_number, 1::bigint as big_number, 1::decimal(10,2) as amount, 1::real as approximate, 'hello'::varchar(24) as label, true as enabled, '2024-01-02'::date as day, '2024-01-02 12:30:00'::timestamp as moment") %}
select '{{ columns | map(attribute='name') | join(',') }}' as names,
       '{{ columns | map(attribute='dtype') | join(',') }}' as dtypes,
       '{{ columns | map(attribute='data_type') | join(',') }}' as data_types
{% else %}select 0{% endif %}
""")
    actual, expected = pair.invoke('compile')
    assert actual['nodes']['model.configuration_fixture.query']['compiled_code'] == expected['nodes']['model.configuration_fixture.query']['compiled_code']


def test_native_duckdb_query_schema_flattens_struct_columns_like_core(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('models/marts/query.sql', """{% if execute %}
{% set columns = adapter.get_column_schema_from_query("select {'name': 'one', 'nested': {'number': 2::integer, 'amount': 2::decimal(10,2)}} as payload") %}
select '{{ columns | map(attribute='name') | join(',') }}' as names,
       '{{ columns | map(attribute='dtype') | join(',') }}' as types
{% else %}select 0{% endif %}
""")
    actual, expected = pair.invoke('compile')
    assert actual['nodes']['model.configuration_fixture.query']['compiled_code'] == expected['nodes']['model.configuration_fixture.query']['compiled_code']


def test_native_postgres_expand_target_columns_executes_and_preserves_rows(tmp_path, configuration_oracle, request):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, 'postgres')
    import psycopg2
    from psycopg2 import sql
    server = request.getfixturevalue('configuration_postgres')
    schemas = ['expand_native', 'expand_core']
    for project, schema in zip(pair.projects, schemas):
        profile = project / 'profiles.yml'
        profile.write_text(profile.read_text().replace('schema: main', 'schema: ' + schema))
        with psycopg2.connect(server.get_uri()) as connection:
            with connection.cursor() as cursor:
                cursor.execute(sql.SQL('create schema {}').format(sql.Identifier(schema)))
                cursor.execute(sql.SQL('create table {}.expand_from (label varchar(20)); create table {}.expand_to (label varchar(5)); insert into {}.expand_to values (%s)').format(sql.Identifier(schema), sql.Identifier(schema), sql.Identifier(schema)), ('short',))
    pair.write('macros/expand.sql', """{% macro expand_columns() %}
{% set from_relation = api.Relation.create(database=target.database, schema=target.schema, identifier='expand_from') %}
{% set to_relation = api.Relation.create(database=target.database, schema=target.schema, identifier='expand_to') %}
{% do adapter.expand_target_column_types(from_relation, to_relation) %}
{% do adapter.commit() %}
{% endmacro %}
""")
    pair.invoke('run-operation expand_columns')
    observations = []
    with psycopg2.connect(server.get_uri()) as connection:
        with connection.cursor() as cursor:
            for schema in schemas:
                cursor.execute('select character_maximum_length from information_schema.columns where table_schema=%s and table_name=%s and column_name=%s', (schema, 'expand_to', 'label'))
                length = cursor.fetchone()[0]
                cursor.execute(sql.SQL('select label from {}.expand_to').format(sql.Identifier(schema)))
                observations.append((length, cursor.fetchall()))
    assert observations[0] == observations[1] == (20, [('short',)])


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_native_relation_metadata_mapping_contract_matches_core(tmp_path, configuration_oracle, request, adapter):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('models/marts/relation_metadata.sql', """{% set relation = api.Relation.create(database=target.database, schema=target.schema, identifier='example', type='table', quote_policy={'identifier': false}) %}
select '{{ relation.get('metadata').get('type') }}' as kind,
       '{{ relation.get('metadata', {}).get('type', '').endswith('Relation') }}' as is_relation,
       '{{ relation.get('missing', 'fallback') }}' as missing,
       '{{ relation.get('quote_policy').get('identifier') }}' as quoted,
       '{{ relation.get('include_policy').get('database') }}' as included,
       '{{ relation.information_schema().get('metadata').get('type') }}' as information_schema_type
""")
    actual, expected = pair.invoke('compile')
    assert actual['nodes']['model.configuration_fixture.relation_metadata']['compiled_code'] == expected['nodes']['model.configuration_fixture.relation_metadata']['compiled_code']


@pytest.mark.parametrize('template', [
    "select '{{ tojson({'integer': 9007199254740993, 'float': 1.0, 'label': 'café🙂', 'array': (True, None)}) }}' as value",
    "select '{{ fromjson('{\"values\": [1, 2]}')['values'] | join(',') }}' as value",
    "{% set x,y = (1,2) %}select '{{ x+y }}{% for a,b in zip((1,2),(3,4)) %}{{ a+b }}{% endfor %}' as value",
    "select '{{ render(\"{{ model.name }}:{{ config.get('materialized') }}\") }}' as value",
])
def test_native_hook_context_rendering_and_tuple_binding_match_core(tmp_path, configuration_oracle, template):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('models/marts/rendered.sql', template)
    actual, expected = pair.invoke('compile')
    assert actual['nodes']['model.configuration_fixture.rendered']['compiled_code'] == expected['nodes']['model.configuration_fixture.rendered']['compiled_code']


def test_postgres_catalog_respects_authored_dispatch(tmp_path, configuration_oracle, request):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, 'postgres')
    pair.write('models/marts/catalog_entry.sql', "{{ config(materialized='table') }}select 1::integer as id")
    pair.invoke('run')
    pair.write('macros/catalog.sql', """{% macro postgres__get_catalog_relations(information_schema, relations) %}
{% if relations is mapping or relations is sequence or relations is not iterable %}
{{ exceptions.raise_compiler_error('catalog relations require an iterable set') }}
{% endif %}
{% set relation = (relations | list)[0] %}
{% call statement('catalog_override', fetch_result=true, auto_begin=false) %}
select '{{ information_schema.database }}' as table_database, '{{ relation.schema }}' as table_schema,
 '{{ relation.identifier }}' as table_name, 'BASE TABLE' as table_type,
 'Authored catalog metadata' as table_comment, 'id' as column_name, 1 as column_index,
 'integer' as column_type, 'Authored column metadata' as column_comment, 'Authored owner' as table_owner
{% endcall %}{{ return(load_result('catalog_override').table) }}{% endmacro %}""")
    pair.invoke('docs generate')
    actual, expected = [json.loads((project / 'target/catalog.json').read_text()) for project in pair.projects]
    assert actual['nodes'] == expected['nodes']
    assert actual['nodes']['model.configuration_fixture.catalog_entry']['metadata']['owner'] == 'Authored owner'
    from test_cli import assert_catalog_schema_slice, assert_manifest_schema_slice, assert_run_results_schema_slice
    for project in pair.projects:
        assert_catalog_schema_slice(project / 'target/catalog.json')
        assert_manifest_schema_slice(project / 'target/manifest.json')
        assert_run_results_schema_slice(project / 'target/run_results.json')


@pytest.mark.parametrize('failure', ['direct-subscript', 'authored-error'])
def test_postgres_catalog_errors_preserve_compilation_artifacts(tmp_path, configuration_oracle, request, failure):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, 'postgres')
    pair.write('models/marts/catalog_entry.sql', "{{ config(materialized='table') }}select 1::integer as id")
    pair.invoke('run')
    macro = """{% macro postgres__get_catalog_relations(information_schema, relations) %}
{% call statement('catalog_override', fetch_result=true, auto_begin=false) %}
select '{{ information_schema.database }}' as table_database, '{{ relations[0].schema }}' as table_schema,
 '{{ relations[0].identifier }}' as table_name, 'BASE TABLE' as table_type,
 'Authored catalog metadata' as table_comment, 'id' as column_name, 1 as column_index,
 'integer' as column_type, 'Authored column metadata' as column_comment, 'Authored owner' as table_owner
{% endcall %}{{ return(load_result('catalog_override').table) }}{% endmacro %}"""
    if failure == 'authored-error':
        macro = "{% macro postgres__get_catalog_relations(information_schema, relations) %}{{ exceptions.raise_compiler_error('catalog rejected') }}{% endmacro %}"
    pair.write('macros/catalog.sql', macro)
    result, reference = pair.invoke('docs generate', success=False)
    assert result.returncode == 1, result.stdout + result.stderr
    assert reference.exception is None
    from test_cli import assert_catalog_schema_slice, assert_manifest_schema_slice, assert_run_results_schema_slice
    for project in pair.projects:
        assert_catalog_schema_slice(project / 'target/catalog.json')
        assert_manifest_schema_slice(project / 'target/manifest.json')
        assert_run_results_schema_slice(project / 'target/run_results.json')
        catalog = json.loads((project / 'target/catalog.json').read_text())
        assert catalog['nodes'] == catalog['sources'] == {}
        assert len(catalog['errors']) == 1
        assert isinstance(catalog['errors'][0], str)
        assert (project / 'target/index.html').is_file()
        manifest = json.loads((project / 'target/manifest.json').read_text())
        node = manifest['nodes']['model.configuration_fixture.catalog_entry']
        assert node['compiled'] is True
        assert node['compiled_code'] == 'select 1::integer as id'
        run_results = json.loads((project / 'target/run_results.json').read_text())
        assert [row['status'] for row in run_results['results']] == ['success']
        if failure == 'authored-error':
            assert 'catalog rejected' in catalog['errors'][0]
    if failure == 'authored-error':
        assert 'catalog rejected' in result.stderr


def test_postgres_catalog_rejects_unavailable_source_database(tmp_path, configuration_oracle, request):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, 'postgres')
    pair.write('models/sources.yml', "version: 2\nsources:\n  - name: warehouse\n    database: unavailable_database\n    schema: main\n    tables:\n      - name: missing\n")
    pair.invoke('docs generate', success=False)


def test_core_config_overlay_dict_updates_list_append_and_grant_prefixes(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.append_project("""models:
  configuration_fixture:
    +grants: {select: [project_reader], insert: project_writer}
    +docs: {show: false, node_color: '#110000'}
    +quoting: {schema: false}
    +contract: {enforced: false, alias_types: false}
    +persist_docs: {relation: true, columns: true}
    +packages: [project_dependency]
""")
    pair.write('models/properties.yml', """version: 2
models:
  - name: rendered
    config:
      grants: {+select: [yaml_reader], insert: yaml_writer}
      docs: {show: true}
      quoting: {identifier: false}
      contract: {enforced: false}
      persist_docs: {relation: false}
      packages: [yaml_dependency]
""")
    pair.write('models/marts/rendered.sql', """{{ config(grants={'+select': ['inline_reader'], 'insert': 'inline_writer'}, docs={'node_color': '#ff0000'}, quoting={'database': false}, contract={'alias_types': true}, persist_docs={'columns': false}, packages=['inline_dependency']) }}
{{ config(grants={'+select': ['extra_reader']}) }}
select 1 as id
""")
    actual, expected = pair.invoke('compile')
    actual_config = actual['nodes']['model.configuration_fixture.rendered']['config']
    expected_config = expected['nodes']['model.configuration_fixture.rendered']['config']
    for key in ['grants', 'docs', 'quoting', 'contract', 'persist_docs', 'packages']:
        assert actual_config[key] == expected_config[key], key

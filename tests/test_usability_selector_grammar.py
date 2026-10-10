"""Core's selector grammar preserves literal operators and empty criteria."""
import json
import itertools
import subprocess

import pytest

from cli_helpers import json_lines
from test_cli import DXT, ROOT, build_dxt
from test_usability_configuration import ConfigurationPair, configuration_oracle


def test_source_tag_inheritance_and_selectors_match_complete_core_matrix(tmp_path, configuration_oracle):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    sources = []
    for index, placement in enumerate(itertools.product([False, True], repeat=4)):
        source = {"name": f"raw{index}", "tables": [{"name": "events"}]}
        source_config, source_legacy, table_config, table_legacy = placement
        if source_config:
            source["config"] = {"tags": ["source_config", "common"]}
        if source_legacy:
            source["tags"] = ["source_legacy", "common"]
        if table_config:
            source["tables"][0]["config"] = {"tags": ["table_config", "common"]}
        if table_legacy:
            source["tables"][0]["tags"] = ["table_legacy", "common"]
        sources.append(source)
    pair.write("models/properties.yml", json.dumps({"version": 2, "sources": sources}))
    actual, expected = pair.invoke("parse")
    assert actual["sources"].keys() == expected["sources"].keys()
    for identifier, reference in expected["sources"].items():
        assert actual["sources"][identifier]["tags"] == reference["tags"]
        assert actual["sources"][identifier]["config"] == reference["config"]
        assert actual["sources"][identifier]["unrendered_config"] == reference["unrendered_config"]
    for tag in ["source_config", "source_legacy", "table_config", "table_legacy", "common", "missing"]:
        flags = ["--select", f"tag:{tag}", "--output", "json", "--output-keys", "unique_id", "--quiet"]
        native, core = pair.projects
        result = subprocess.run([DXT, "ls", "--project-dir", str(native), "--profiles-dir", str(native), *flags], cwd=ROOT, text=True, capture_output=True)
        reference = configuration_oracle.invoke(["ls", "--project-dir", str(core), "--profiles-dir", str(core), "--no-partial-parse", *flags])
        assert reference.success, reference.exception
        assert result.returncode == 0, result.stdout + result.stderr
        assert sorted(row["unique_id"] for row in json_lines(result.stdout)) == sorted(json.loads(row)["unique_id"] for row in reference.result)


@pytest.mark.parametrize("selector,success", [
    ("config.schema:audit", True), ("tag:nightly,", True),
    ("config.materialized:", True), ("package:", True),
    ("tag:nightly, config.materialized:view", True),
    ("++customers", True), ("1++customers", True),
    ("customers++", True), ("customers+1+", True),
    ("++customers++", True), ("@", True), ("@@customers", True),
    ("customers@", True), ("@customers+", False),
    ("@customers+1", False), ("@+customers", True),
    ("@1+customers", True), ("@+orders", True),
    ("@0+orders", True), ("999999999999999999999999999999+orders", True),
    ("orders+999999999999999999999999999999", True),
    ("customers,", True), (",customers", True), (",", True),
    ("", True), ("+", True), ("@+", True), (":customers", True),
    ("+missing:customers", False), ("++missing:customers", True),
    ("resource_type:function", False), ("test_type:missing", False),
    ("tag.ignored:nightly", True), ("resource_type.ignored:model", True),
    ("config:ignored", True), ("config.:ignored", True),
    ("😀:customers", True), ("é:customers", False),
])
def test_cli_selector_criteria_match_core(tmp_path, configuration_oracle, selector, success):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write("models/marts/customers.sql", "{{ config(tags=['nightly'], schema='audit') }}select 1 as id")
    pair.write("models/marts/orders.sql", "{{ config(materialized='table') }}select * from {{ ref('customers') }}")
    pair.write("models/marts/reports.sql", "select * from {{ ref('orders') }}")
    actual, expected = pair.projects
    flags = ["--select", selector, "--output", "json", "--output-keys", "unique_id", "--quiet"]
    result = subprocess.run(
        [DXT, "ls", "--project-dir", str(actual), "--profiles-dir", str(actual), *flags],
        cwd=ROOT, text=True, capture_output=True,
    )
    reference = configuration_oracle.invoke([
        "ls", "--project-dir", str(expected), "--profiles-dir", str(expected),
        "--no-partial-parse", *flags,
    ])
    assert reference.success is success, reference.exception
    assert result.returncode == (0 if success else 2), result.stdout + result.stderr
    if success:
        actual_ids = sorted(row["unique_id"] for row in json_lines(result.stdout))
        expected_ids = sorted(json.loads(row)["unique_id"] for row in reference.result)
        assert actual_ids == expected_ids
    from dbt.adapters.factory import reset_adapters
    from dbt.adapters.duckdb.connections import DuckDBConnectionManager
    reset_adapters()
    if DuckDBConnectionManager._ENV is not None:
        DuckDBConnectionManager._ENV.close()
        DuckDBConnectionManager._ENV = None


@pytest.mark.parametrize("selector", [
    "config.schema:audit", "config.materialized:seed", "config.materialized:snapshot",
    "config.materialized:test", "config.enabled:TRUE", "config.tags:nightly",
    "config.on_schema_change:ignore", "config.meta.team:Core", "config.meta.team:core",
    "config.meta.nested:nightly", "config.meta.flags:true", "config.meta.flags:false",
    "config.meta.flags:1", "config.meta.count:1", "config.meta.count:true",
    "config.meta.bool:true", "config.meta.empty:", "config.meta.items:hidden",
    "config.meta.mapping.0:zero", "config.meta.flags.0:1",
    "config.severity:warn", "config.store_failures:TRUE", "config.store_failures_as:table",
    "config.where:id>0", "config.limit:1", "config.docs.show:False",
    "config.contract.enforced:FALSE", "config.meta.team:Source",
    "config.loaded_at_field:loaded_at", "config.event_time:loaded_at",
    "config.freshness.warn_after.period:hour", "config.freshness.warn_after.count:1",
    "config.materialized:table+", "tag.ignored:source_tag",
    "source.ignored:raw.events", "test_name.ignored:not_null",
])
def test_typed_config_selector_values_match_core(tmp_path, configuration_oracle, selector):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write("models/marts/customers.sql", """{{ config(schema='audit', tags=['nightly'], docs={'show':False},
meta={'team':'Core','nested':[['nightly']],'flags':[1.0,0],'count':1,'bool':True,
'empty':'','items':'hidden','mapping':{'0':'zero'}}) }}select 1 as id""")
    pair.write("models/marts/orders.sql", "{{ config(materialized='table') }}select * from {{ ref('customers') }}")
    pair.write("models/marts/reports.sql", "select * from {{ ref('orders') }}")
    pair.write("seeds/input.csv", "id\n1\n")
    pair.write("snapshots/history.sql", "{% snapshot history %}{{ config(target_schema='history', unique_key='id', strategy='check', check_cols=['id']) }}select 1 as id{% endsnapshot %}")
    pair.write("tests/check.sql", "{{ config(severity='WARN', store_failures=True, store_failures_as='table', where='id>0', limit=1) }}select 1 as id where false")
    pair.write("models/properties.yml", """version: 2
models:
  - name: customers
    columns:
      - name: id
        data_tests:
          - not_null:
              config: {severity: WARN, store_failures: true, limit: 1}
sources:
  - name: raw
    config: {meta: {team: Source}, tags: [source_tag], event_time: loaded_at, loaded_at_field: loaded_at, freshness: {warn_after: {count: 1, period: hour}}}
    tables:
      - name: events
""")
    actual, expected = pair.projects
    flags = ["--select", selector, "--output", "json", "--output-keys", "unique_id", "--quiet"]
    result = subprocess.run([DXT, "ls", "--project-dir", str(actual), "--profiles-dir", str(actual), *flags], cwd=ROOT, text=True, capture_output=True)
    reference = configuration_oracle.invoke(["ls", "--project-dir", str(expected), "--profiles-dir", str(expected), "--no-partial-parse", *flags])
    assert reference.success, reference.exception
    assert result.returncode == 0, result.stdout + result.stderr
    assert sorted(row["unique_id"] for row in json_lines(result.stdout)) == sorted(json.loads(row)["unique_id"] for row in reference.result)
    from dbt.adapters.factory import reset_adapters
    from dbt.adapters.duckdb.connections import DuckDBConnectionManager
    reset_adapters()
    if DuckDBConnectionManager._ENV is not None:
        DuckDBConnectionManager._ENV.close()
        DuckDBConnectionManager._ENV = None

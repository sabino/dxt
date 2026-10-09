from __future__ import annotations

import json
import subprocess
from pathlib import Path

import jsonschema
import pytest

from test_usability_commands import (core_runner, write_project, invoke_core)

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / 'zig-out/bin/dxt'

@pytest.fixture(scope='module', autouse=True)
def native_binary():
    subprocess.run(['zig', 'build'], cwd=ROOT, check=True)

def run_dxt(project, command, *args):
    return subprocess.run([DXT, command, *args, '--project-dir', str(project), '--target-path', str(project / 'target')], cwd=ROOT, text=True, capture_output=True)


SEMANTIC_YAML = """version: 2
semantic_models:
  - name: orders
    description: Orders model
    model: ref('orders')
    defaults:
      agg_time_dimension: ordered_at
    entities:
      - name: order
        type: primary
        expr: id
      - name: customer
        type: foreign
        expr: customer_id
    dimensions:
      - name: ordered_at
        type: time
        type_params:
          time_granularity: day
      - name: status
        type: categorical
    measures:
      - name: order_amount
        agg: sum
        expr: amount
        create_metric: true
      - name: order_count
        agg: sum
        expr: 1
      - name: paid_count
        agg: count
        expr: id
    config:
      meta:
        owner: analytics
  - name: customers
    model: ref('customers')
    entities:
      - name: customer
        type: primary
        expr: id
    dimensions:
      - name: country
        type: categorical
  - name: disabled_orders
    model: ref('orders')
    config:
      enabled: false
metrics:
  - name: revenue
    label: Revenue
    type: simple
    type_params:
      measure: order_amount
  - name: orders
    label: Orders
    type: simple
    type_params:
      measure: order_count
  - name: paid_orders
    label: Paid Orders
    type: simple
    type_params:
      measure: paid_count
  - name: average_order
    label: Average Order
    type: ratio
    type_params:
      numerator: revenue
      denominator: orders
  - name: doubled_revenue
    label: Doubled Revenue
    type: derived
    type_params:
      expr: revenue * 2
      metrics:
        - revenue
  - name: rolling_revenue
    label: Rolling Revenue
    type: cumulative
    type_params:
      measure: order_amount
      cumulative_type_params:
        window: 7 days
  - name: paid_conversion
    label: Paid Conversion
    type: conversion
    type_params:
      conversion_type_params:
        base_measure: order_count
        conversion_measure: paid_count
        entity: order
        window: 7 days
  - name: disabled_metric
    label: Disabled
    type: simple
    type_params:
      measure: order_amount
    config:
      enabled: false
saved_queries:
  - name: daily_revenue
    label: Daily Revenue
    description: Revenue grouped by date
    query_params:
      metrics: [revenue]
      group_by: ["TimeDimension('metric_time', 'day')"]
      order_by: ["TimeDimension('metric_time', 'day')"]
      limit: 10
    exports:
      - name: daily_revenue_export
        config:
          export_as: table
          schema: reporting
    config:
      tags: [finance]
      meta:
        priority: 1
"""


def semantic_project(path: Path, yaml_text: str = SEMANTIC_YAML):
    write_project(path, {
        'models/orders.sql': "select 1 as id, 1 as customer_id, 10 as amount, date '2024-01-01' as ordered_at, 'paid' as status",
        'models/customers.sql': "select 1 as id, 'US' as country",
        'models/metricflow_time_spine.sql': "select date '2024-01-01' as date_day",
        'models/semantic.yml': yaml_text,
    })
    return path


def normalize(value):
    if isinstance(value, dict):
        return {key: normalize(item) for key, item in value.items() if key != 'created_at'}
    if isinstance(value, list):
        items = [normalize(item) for item in value]
        if items and all(isinstance(item, dict) and 'name' in item for item in items):
            items.sort(key=lambda item: item['name'])
        return items
    return value


def artifacts(project):
    target = project / 'target'
    return json.loads((target / 'manifest.json').read_text()), json.loads((target / 'semantic_manifest.json').read_text())


def validate_semantics(manifest, semantic):
    from dbt.artifacts.resources.v1.semantic_model import SemanticModel
    from dbt.artifacts.resources.v1.metric import Metric
    from dbt.artifacts.resources.v1.saved_query import SavedQuery
    from dbt_semantic_interfaces.implementations.semantic_manifest import PydanticSemanticManifest
    for key, klass in [('semantic_models', SemanticModel), ('metrics', Metric), ('saved_queries', SavedQuery)]:
        for resource in manifest[key].values():
            klass.validate(resource)
    # DSI 0.9's element config imports Pydantic 2 FieldInfo while its base
    # models deliberately use Pydantic 1. Encode the declared default factory
    # when generating its full schema; keep every schema validation assertion.
    from pydantic.fields import FieldInfo
    from pydantic.v1.json import ENCODERS_BY_TYPE
    ENCODERS_BY_TYPE.setdefault(FieldInfo, lambda value: value.default_factory() if value.default_factory else value.default)
    schema = PydanticSemanticManifest.schema()
    # Pydantic 1 omits JSON null from Optional fields in schema output even
    # though the actual published artifacts and model validators accept it.
    # Restore exactly the nullability declared by each model field.
    visited = set()
    def add_nullable(klass):
        if klass in visited or not hasattr(klass, '__fields__'):
            return
        visited.add(klass)
        target = schema if klass is PydanticSemanticManifest else schema['definitions'][klass.__name__]
        for item in klass.__fields__.values():
            if item.allow_none:
                original = target['properties'][item.alias]
                target['properties'][item.alias] = {'anyOf': [original, {'type': 'null'}]}
            add_nullable(item.type_)
    add_nullable(PydanticSemanticManifest)
    jsonschema.validate(semantic, schema)
    parsed = PydanticSemanticManifest.parse_obj(semantic)
    from dbt_semantic_interfaces.validations.semantic_manifest_validator import SemanticManifestValidator
    assert not SemanticManifestValidator().validate_semantic_manifest(parsed).errors


def test_core_1105_semantic_resources_full_schema_and_artifact_parity(tmp_path, core_runner):
    project = semantic_project(tmp_path / 'semantic')
    core = invoke_core(core_runner, project, 'parse')
    assert core.success, core.exception
    expected_manifest, expected_semantic = artifacts(project)
    validate_semantics(expected_manifest, expected_semantic)
    result = run_dxt(project, 'parse')
    assert result.returncode == 0, result.stderr
    actual_manifest, actual_semantic = artifacts(project)
    validate_semantics(actual_manifest, actual_semantic)
    for key in ['semantic_models', 'metrics', 'saved_queries', 'disabled']:
        assert normalize(actual_manifest[key]) == normalize(expected_manifest[key])
    for key in ['parent_map', 'child_map']:
        ids = set(expected_manifest['semantic_models']) | set(expected_manifest['metrics']) | set(expected_manifest['saved_queries'])
        assert {identifier: actual_manifest[key][identifier] for identifier in ids} == {identifier: expected_manifest[key][identifier] for identifier in ids}
    assert normalize(actual_semantic) == normalize(expected_semantic)


@pytest.mark.parametrize('selector', ['metric:*', 'semantic_model:*', 'saved_query:*', '+metric:revenue', 'semantic_model:orders+', 'resource_type:metric', 'resource_type:saved_query,tag:finance', 'metric:average_order metric:doubled_revenue'])
def test_core_1105_semantic_selectors(tmp_path, core_runner, selector):
    project = semantic_project(tmp_path / 'semantic')
    core = invoke_core(core_runner, project, 'ls', '--select', selector, '--output', 'json', '--output-keys', 'unique_id')
    assert core.success, core.exception
    expected = sorted(json.loads(row)['unique_id'] for row in core.result)
    result = run_dxt(project, 'ls', '--select', selector, '--output', 'json', '--output-keys', 'unique_id')
    assert result.returncode == 0, result.stderr
    actual = sorted(row['unique_id'] for row in json.loads(result.stdout))
    assert actual == expected


@pytest.mark.parametrize('mutation', ['missing_measure', 'missing_model', 'missing_time_spine', 'invalid_grain', 'multiple_primary'])
def test_semantic_errors_fail_before_artifacts_and_warehouse_writes(tmp_path, core_runner, mutation):
    yml = SEMANTIC_YAML
    if mutation == 'missing_measure': yml = yml.replace('measure: order_amount', 'measure: absent_measure')
    if mutation == 'missing_model': yml = yml.replace("model: ref('orders')", "model: ref('absent_model')")
    if mutation == 'invalid_grain': yml = yml.replace('time_granularity: day', 'time_granularity: fortnight')
    if mutation == 'multiple_primary': yml = yml.replace('type: foreign', 'type: primary')
    project = semantic_project(tmp_path / 'semantic', yml)
    if mutation == 'missing_time_spine': (project / 'models/metricflow_time_spine.sql').unlink()
    result = run_dxt(project, 'parse')
    assert result.returncode == 2, result.stdout + result.stderr
    assert not (project / 'warehouse.duckdb').exists()
    assert not (project / 'target/manifest.json').exists()
    core = invoke_core(core_runner, project, 'parse')
    assert not core.success


def test_core_1105_yaml_time_spine_configuration(tmp_path, core_runner):
    spine = """
models:
  - name: metricflow_time_spine
    time_spine:
      standard_granularity_column: date_day
    columns:
      - name: date_day
        granularity: day
"""
    project = semantic_project(tmp_path / 'semantic', SEMANTIC_YAML + spine)
    core = invoke_core(core_runner, project, 'parse')
    assert core.success, core.exception
    expected = artifacts(project)[1]
    result = run_dxt(project, 'parse')
    assert result.returncode == 0, result.stderr
    actual = artifacts(project)[1]
    validate_semantics(artifacts(project)[0], actual)
    assert normalize(actual) == normalize(expected)


def test_core_1105_project_semantic_config_precedence_and_nested_metadata(tmp_path, core_runner):
    project = semantic_project(tmp_path / 'semantic')
    with (project / 'dbt_project.yml').open('a') as out:
        out.write("""semantic-models:
  commands:
    +meta: {project: true, owner: root}
metrics:
  commands:
    +meta: {owner: finance, nested: {enabled: true}}
saved-queries:
  commands:
    +export_as: view
    +schema: exports
""")
    core = invoke_core(core_runner, project, 'parse')
    assert core.success, core.exception
    expected_manifest, expected_semantic = artifacts(project)
    result = run_dxt(project, 'parse')
    assert result.returncode == 0, result.stderr
    actual_manifest, actual_semantic = artifacts(project)
    validate_semantics(actual_manifest, actual_semantic)
    for key in ['semantic_models', 'metrics', 'saved_queries', 'disabled']:
        assert normalize(actual_manifest[key]) == normalize(expected_manifest[key])
    assert normalize(actual_semantic) == normalize(expected_semantic)


def metricflow_sql(project: Path, metrics: list[str], groups: list[str], where: list[str] | None = None,
                   order_by: list[str] | None = None, limit: int | None = None,
                   start_time: str | None = None, end_time: str | None = None):
    from importlib.metadata import version
    from datetime import datetime
    from metricflow_semantics.model.dbt_manifest_parser import parse_manifest_from_dbt_generated_manifest
    from metricflow_semantics.model.semantic_manifest_lookup import SemanticManifestLookup
    from metricflow.engine.metricflow_engine import MetricFlowEngine, MetricFlowQueryRequest
    from metricflow.protocols.sql_client import SqlEngine
    from metricflow.sql.render.duckdb_renderer import DuckDbSqlPlanRenderer
    assert version('metricflow') == '0.208.1'
    class SqlClient:
        sql_engine_type = SqlEngine.DUCKDB
        sql_plan_renderer = DuckDbSqlPlanRenderer()
        def render_bind_parameter_key(self, key):
            return '?'
    manifest = parse_manifest_from_dbt_generated_manifest((project / 'target/semantic_manifest.json').read_text())
    engine = MetricFlowEngine(SemanticManifestLookup(manifest), SqlClient())
    request = MetricFlowQueryRequest.create_with_random_request_id(
        metric_names=metrics, group_by_names=groups, where_constraints=where, order_by_names=order_by,
        limit=limit, time_constraint_start=datetime.fromisoformat(start_time) if start_time else None,
        time_constraint_end=datetime.fromisoformat(end_time) if end_time else None,
    )
    return engine.explain(request).sql_statement.sql


METRIC_EXTENSION = """
  - name: paid_revenue
    label: Paid Revenue
    type: simple
    type_params:
      measure: order_amount
    filter: "{{ Dimension('order__status') }} = 'paid'"
  - name: complete_revenue
    label: Complete Revenue
    type: simple
    type_params:
      measure:
        name: order_amount
        join_to_timespine: true
        fill_nulls_with: 0
  - name: revenue_change
    label: Revenue Change
    type: derived
    type_params:
      expr: current_revenue - previous_revenue
      metrics:
        - name: revenue
          alias: current_revenue
        - name: revenue
          alias: previous_revenue
          offset_window: 1 day
"""


def metric_project(path):
    project = semantic_project(path, SEMANTIC_YAML.replace('saved_queries:\n', METRIC_EXTENSION + 'saved_queries:\n').replace('name: order\n', 'name: order_key\n').replace('entity: order\n', 'entity: order_key\n').replace('order__', 'order_key__'))
    (project / 'models/orders.sql').write_text("""select * from (values
      (1,1,10,'paid',date '2024-01-01'),
      (2,1,20,'cancelled',date '2024-01-01'),
      (3,2,5,'paid',date '2024-01-03'),
      (4,3,NULL,'paid',date '2024-01-08'),
      (5,NULL,0,'cancelled',date '2024-01-09')) t(id,customer_id,amount,status,ordered_at)
    """)
    (project / 'models/customers.sql').write_text("select * from (values(1,'US'),(2,'UK'),(3,NULL)) t(id,country)")
    (project / 'models/metricflow_time_spine.sql').write_text("select cast(generate_series as date) as date_day from generate_series(date '2024-01-01',date '2024-01-10',interval 1 day)")
    return project


@pytest.mark.parametrize('metrics,groups,where', [
    (['revenue'], [], None),
    (['revenue', 'orders'], [], None),
    (['revenue', 'average_order', 'doubled_revenue'], ['customer__country'], None),
    (['revenue'], ['metric_time__day'], None),
    (['revenue'], ['metric_time__month'], None),
    (['revenue'], ['order_key__status'], None),
    (['paid_revenue'], ['customer__country'], None),
    (['revenue'], ['customer__country'], ["{{ Dimension('order_key__status') }} = 'paid'"]),
    (['rolling_revenue'], ['metric_time__day'], None),
    (['complete_revenue'], ['metric_time__day'], None),
    (['revenue_change'], ['metric_time__day'], None),
    (['paid_conversion'], ['metric_time__day'], None),
])
def test_metricflow_02081_query_execution_results(tmp_path, core_runner, metrics, groups, where):
    from test_usability_commands import query
    project = metric_project(tmp_path / 'metric')
    core = invoke_core(core_runner, project, 'parse')
    assert core.success, core.exception
    build = run_dxt(project, 'build')
    assert build.returncode == 0, build.stderr
    oracle_sql = metricflow_sql(project, metrics, groups, where)
    expected = query(project / 'warehouse.duckdb', oracle_sql)
    args = ['--metrics', ','.join(metrics)]
    if groups:
        args += ['--group-by', ','.join(groups)]
    if where:
        args += ['--where', where[0]]
    result = run_dxt(project, 'metric', 'query', *args)
    assert result.returncode == 0, result.stderr
    actual = json.loads(result.stdout)
    key = lambda row: json.dumps(row, sort_keys=True)
    assert sorted(actual, key=key) == sorted(expected, key=key)
    assert json.loads((project / 'target/metric_results.json').read_text()) == actual
    plan = json.loads((project / 'target/metric_plan.json').read_text())
    assert plan['strategy'] == 'single_engine_pushdown'
    assert plan['movement'] == []
    assert plan['metrics'] == metrics
    if 'customer__country' in groups:
        assert all(join['cardinality'] == 'many_to_one' for join in plan['joins'])


def test_metricflow_query_order_limit_timerange_and_saved_export(tmp_path, core_runner):
    from test_usability_commands import query
    project = metric_project(tmp_path / 'metric')
    assert invoke_core(core_runner, project, 'parse').success
    assert run_dxt(project, 'build').returncode == 0
    sql = metricflow_sql(project, ['revenue'], ['metric_time__day'], order_by=['-revenue'], limit=2,
                         start_time='2024-01-01', end_time='2024-01-03')
    expected = query(project / 'warehouse.duckdb', sql)
    result = run_dxt(project, 'metric', 'query', '--metrics', 'revenue', '--group-by', 'metric_time__day',
                     '--order-by=-revenue', '--limit', '2', '--start-time', '2024-01-01', '--end-time', '2024-01-03')
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == expected
    result = run_dxt(project, 'metric', 'query', '--saved-query', 'daily_revenue')
    assert result.returncode == 0, result.stderr
    result = run_dxt(project, 'metric', 'export', '--saved-query', 'daily_revenue')
    assert result.returncode == 0, result.stderr
    assert query(project / 'warehouse.duckdb', 'select * from reporting.daily_revenue_export order by metric_time__day') == json.loads((project / 'target/metric_results.json').read_text())


def test_metric_explain_validates_joins_without_opening_database(tmp_path):
    project = metric_project(tmp_path / 'metric')
    result = run_dxt(project, 'metric', 'explain', '--metrics', 'revenue', '--group-by', 'customer__country')
    assert result.returncode == 0, result.stderr
    plan = json.loads(result.stdout)
    assert plan['joins'][0]['entity'] == 'customer'
    assert not (project / 'warehouse.duckdb').exists()
    yml = (project / 'models/semantic.yml').read_text().replace("name: customers\n    model: ref('customers')\n    entities:\n      - name: customer\n        type: primary", "name: customers\n    model: ref('customers')\n    entities:\n      - name: customer\n        type: foreign\n      - name: customer_record\n        type: primary\n        expr: id")
    (project / 'models/semantic.yml').write_text(yml)
    result = run_dxt(project, 'metric', 'query', '--metrics', 'revenue', '--group-by', 'customer__country')
    assert result.returncode == 2, result.stderr
    assert 'fan out' in result.stderr
    assert not (project / 'warehouse.duckdb').exists()


def test_metric_invalid_dimension_and_grain_fail_before_warehouse(tmp_path):
    project = metric_project(tmp_path / 'metric')
    for group in ['customer__absent', 'metric_time__hour', 'order_key__status__day']:
        result = run_dxt(project, 'metric', 'query', '--metrics', 'revenue', '--group-by', group)
        assert result.returncode == 2, result.stderr
        assert not (project / 'warehouse.duckdb').exists()

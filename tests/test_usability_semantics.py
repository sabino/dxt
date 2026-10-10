from __future__ import annotations

import json
import subprocess
from pathlib import Path

import jsonschema
import pytest

from cli_helpers import json_lines

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
    actual = sorted(row['unique_id'] for row in json_lines(result.stdout))
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
                   start_time: str | None = None, end_time: str | None = None, postgres: bool = False):
    from importlib.metadata import version
    from datetime import datetime
    from metricflow_semantics.model.dbt_manifest_parser import parse_manifest_from_dbt_generated_manifest
    from metricflow_semantics.model.semantic_manifest_lookup import SemanticManifestLookup
    from metricflow.engine.metricflow_engine import MetricFlowEngine, MetricFlowQueryRequest
    from metricflow.protocols.sql_client import SqlEngine
    from metricflow.sql.render.duckdb_renderer import DuckDbSqlPlanRenderer
    from metricflow.sql.render.postgres import PostgresSQLSqlPlanRenderer
    assert version('metricflow') == '0.208.1'
    class SqlClient:
        sql_engine_type = SqlEngine.POSTGRES if postgres else SqlEngine.DUCKDB
        sql_plan_renderer = PostgresSQLSqlPlanRenderer() if postgres else DuckDbSqlPlanRenderer()
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
  - name: rolling_revenue_last
    label: Rolling Revenue Last
    type: cumulative
    type_params:
      measure: order_amount
      cumulative_type_params:
        window: 7 days
        period_agg: last
  - name: rolling_revenue_average
    label: Rolling Revenue Average
    type: cumulative
    type_params:
      measure: order_amount
      cumulative_type_params:
        window: 7 days
        period_agg: average
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
    (['rolling_revenue'], ['metric_time__month'], None),
    (['rolling_revenue_last'], ['metric_time__month'], None),
    (['rolling_revenue_average'], ['metric_time__month'], None),
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


def test_postgres_native_metric_execution_and_atomic_saved_export(tmp_path, core_runner):
    import postgres_fixture as pgserver
    import psycopg2
    with pgserver.get_server(tmp_path / 'postgres-data') as server:
        project = semantic_project(tmp_path / 'metric')
        info = server.get_postmaster_info()
        (project / 'profiles.yml').write_text(f"""commands:
  target: dev
  outputs:
    dev:
      type: postgres
      host: '{info.socket_dir}'
      port: {info.port}
      dbname: postgres
      user: postgres
      password: ''
      schema: dev
      threads: 1
""")
        with psycopg2.connect(server.get_uri()) as connection:
            with connection.cursor() as cursor:
                cursor.execute("create schema dev; create table dev.orders(id integer,customer_id integer,amount integer,ordered_at date,status text)")
                cursor.execute("insert into dev.orders values (1,1,10,'2024-01-01','paid'),(2,1,20,'2024-01-03','paid')")
                cursor.execute("create table dev.customers(id integer,country text); insert into dev.customers values (1,'US')")
                cursor.execute("create table dev.metricflow_time_spine(date_day date); insert into dev.metricflow_time_spine select generate_series(date '2024-01-01',date '2024-01-05',interval '1 day')")
        core = invoke_core(core_runner, project, 'parse')
        assert core.success, core.exception
        result = run_dxt(project, 'metric', 'query', '--metrics', 'revenue,average_order', '--group-by', 'customer__country')
        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout) == [{'customer__country': 'US', 'revenue': 30, 'average_order': 15}]
        for attempt in range(2):
            result = run_dxt(project, 'metric', 'export', '--saved-query', 'daily_revenue')
            assert result.returncode == 0, result.stderr
        with psycopg2.connect(server.get_uri()) as connection:
            with connection.cursor() as cursor:
                cursor.execute(metricflow_sql(project, ['revenue'], ['metric_time__day'], order_by=['metric_time__day'], postgres=True))
                expected = cursor.fetchall()
                cursor.execute('select * from reporting.daily_revenue_export order by metric_time__day')
                assert cursor.fetchall() == expected
        semantic_yaml = project / 'models/semantic.yml'
        original = semantic_yaml.read_text()
        semantic_yaml.write_text(original.replace('export_as: table', 'export_as: view'))
        result = run_dxt(project, 'metric', 'export', '--saved-query', 'daily_revenue')
        assert result.returncode == 0, result.stderr
        semantic_yaml.write_text(original.replace('expr: amount', 'expr: absent_column'))
        result = run_dxt(project, 'metric', 'export', '--saved-query', 'daily_revenue')
        assert result.returncode == 1, result.stderr
        with psycopg2.connect(server.get_uri()) as connection:
            with connection.cursor() as cursor:
                cursor.execute('select * from reporting.daily_revenue_export order by metric_time__day')
                assert cursor.fetchall() == expected
                cursor.execute("select table_type from information_schema.tables where table_schema='reporting' and table_name='daily_revenue_export'")
                assert cursor.fetchone() == ('VIEW',)


@pytest.mark.parametrize('metric,grain,start,end', [
    ('revenue_change', 'day', '2024-01-02', '2024-01-03'),
    ('revenue', 'month', '2024-01-03', '2024-01-08'),
    ('rolling_revenue', 'day', '2024-01-03', '2024-01-08'),
    ('rolling_revenue_last', 'month', '2024-01-03', '2024-01-08'),
])
def test_metricflow_time_ranges_offsets_and_period_alignment(tmp_path, core_runner, metric, grain, start, end):
    from test_usability_commands import query
    project = metric_project(tmp_path / 'metric')
    assert invoke_core(core_runner, project, 'parse').success
    assert run_dxt(project, 'build').returncode == 0
    group = f'metric_time__{grain}'
    sql = metricflow_sql(project, [metric], [group], order_by=[group], start_time=start, end_time=end)
    expected = query(project / 'warehouse.duckdb', sql)
    result = run_dxt(project, 'metric', 'query', '--metrics', metric, '--group-by', group,
                     '--order-by', group, '--start-time', start, '--end-time', end)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == expected


@pytest.mark.parametrize('descending', [True, False])
def test_saved_query_order_builder_honors_boolean(tmp_path, core_runner, descending):
    from test_usability_commands import query
    project = metric_project(tmp_path / 'metric')
    properties = project / 'models/semantic.yml'
    properties.write_text(properties.read_text().replace(
        'order_by: ["TimeDimension(\'metric_time\', \'day\')"]',
        f'order_by: ["Metric(\'revenue\').descending({descending})"]'))
    assert invoke_core(core_runner, project, 'parse').success
    assert run_dxt(project, 'build').returncode == 0
    sql = metricflow_sql(project, ['revenue'], ['metric_time__day'], order_by=['-revenue' if descending else 'revenue'], limit=10)
    expected = query(project / 'warehouse.duckdb', sql)
    result = run_dxt(project, 'metric', 'query', '--saved-query', 'daily_revenue')
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == expected


@pytest.fixture
def cross_metric_project(tmp_path, monkeypatch, core_runner):
    import os
    import ctypes.util
    import postgres_fixture as pgserver
    import psycopg2
    import yaml
    library = os.environ.get('DXT_DUCKDB_LIBRARY') or ctypes.util.find_library('duckdb')
    assert library, 'Metric movement acceptance requires the pinned standalone native DuckDB library'
    monkeypatch.setenv('DXT_DUCKDB_LIBRARY', library)
    monkeypatch.setenv('DXT_DUCKDB_BACKEND', 'native')
    with pgserver.get_server(tmp_path / 'postgres-data') as server:
        project = metric_project(tmp_path / 'metric')
        properties = project / 'models/semantic.yml'
        properties.write_text(properties.read_text().replace("  - name: customers\n    model: ref('customers')\n", """  - name: customers
    model: ref('customers')
    config:
      meta:
        connection: crm
        source: [analytics, customers]
        sensitivity: public
        estimated_rows: 3
        estimated_bytes: 64
"""))
        profiles = yaml.safe_load((project / 'profiles.yml').read_text())
        info = server.get_postmaster_info()
        profiles['commands']['outputs']['crm'] = {
            'type': 'postgres', 'host': str(info.socket_dir), 'port': info.port,
            'dbname': 'postgres', 'user': 'postgres', 'password': 'metric-fixture-secret', 'schema': 'analytics',
        }
        profiles['commands']['outputs']['embedded'] = {'type': 'duckdb', 'path': ':memory:', 'schema': 'main'}
        (project / 'profiles.yml').write_text(json.dumps(profiles))
        with psycopg2.connect(server.get_uri()) as connection:
            with connection.cursor() as cursor:
                cursor.execute('create schema analytics; create table analytics.customers(id bigint,country text,unused_private text)')
                cursor.execute("insert into analytics.customers values(1,'CA','private'),(2,'AU','private'),(3,'NZ','private')")
        configuration = {'connections': {
            'warehouse': {'profile': 'commands', 'target': 'dev', 'role': 'both', 'trust_domain': 'analytics', 'allowed_destinations': ['embedded']},
            'crm': {'profile': 'commands', 'target': 'crm', 'role': 'source', 'trust_domain': 'analytics', 'allowed_destinations': ['warehouse', 'embedded']},
            'embedded': {'profile': 'commands', 'target': 'embedded', 'role': 'both', 'trust_domain': 'analytics'},
        }}
        (project / 'dxt_connections.yml').write_text(json.dumps(configuration))
        assert invoke_core(core_runner, project, 'parse').success
        result = run_dxt(project, 'build')
        assert result.returncode == 0, result.stderr
        yield project, configuration, server


def canonical_rows(rows):
    return sorted(rows, key=lambda row: json.dumps(row, sort_keys=True))


@pytest.mark.parametrize('embedded', [False, True])
def test_metric_cross_database_query_uses_reviewed_native_plan(cross_metric_project, embedded):
    from test_usability_commands import query
    project, configuration, server = cross_metric_project
    flags = ['--connection', 'warehouse', '--allow-movement']
    if embedded:
        flags += ['--execution-connection', 'embedded']
    result = run_dxt(project, 'metric', 'explain', '--metrics', 'revenue', '--group-by', 'customer__country', *flags)
    assert result.returncode == 0, result.stderr
    plan = json.loads(result.stdout)
    physical = plan['cross_database']
    model = physical['models'][0]
    assert model['permitted']
    assert model['execution_connection'] == ('embedded' if embedded else 'warehouse')
    customer = next(item for item in model['inputs'] if item['logical_id'] == 'model.commands.customers')
    assert customer['moved']
    assert customer['raw_extract'] is False
    assert '"id"' in customer['query'] and '"country"' in customer['query']
    assert 'unused_private' not in customer['query']
    assert 'metric-fixture-secret' not in result.stdout
    reviewed_hash = physical['plan_hash']
    result = run_dxt(project, 'metric', 'query', '--metrics', 'revenue', '--group-by', 'customer__country',
                     *flags, '--plan-hash', reviewed_hash)
    assert result.returncode == 0, result.stderr
    assert canonical_rows(json.loads(result.stdout)) == canonical_rows([
        {'customer__country': 'CA', 'revenue': 30}, {'customer__country': 'AU', 'revenue': 5},
        {'customer__country': 'NZ', 'revenue': None}, {'customer__country': None, 'revenue': 0},
    ])
    executed = json.loads((project / 'target/metric_plan.json').read_text())
    assert executed['cross_database']['plan_hash'] == reviewed_hash
    assert query(project / 'warehouse.duckdb', "select table_name from information_schema.tables where table_name like '__dxt_%'") == []
    assert not list((project / '.dxt/cross-runs').glob('*/state.json'))


@pytest.mark.parametrize('flags,diagnostic', [
    (['--connection', 'warehouse'], 'CrossDatabasePolicyDenied'),
    (['--connection', 'warehouse', '--allow-movement', '--max-rows', '1'], 'CrossDatabasePolicyDenied'),
    (['--connection', 'warehouse', '--allow-movement', '--max-rows', '5'], 'CrossDatabaseRowBudgetExceeded'),
    (['--connection', 'missing'], 'MissingCrossDatabaseConnection'),
    (['--allow-movement'], 'MissingMetricConnection'),
    ([], 'MissingMetricConnection'),
])
def test_metric_cross_database_failures_are_bounded_and_leave_no_stages(cross_metric_project, flags, diagnostic):
    from test_usability_commands import query
    project, configuration, server = cross_metric_project
    if diagnostic == 'CrossDatabaseRowBudgetExceeded':
        import psycopg2
        # Keep the declared estimate below the limit, but move six actual source
        # rows. Destination-local result rows do not consume a movement budget.
        with psycopg2.connect(server.get_uri()) as connection:
            with connection.cursor() as cursor:
                cursor.execute("insert into analytics.customers values(4,'CA','private'),(5,'AU','private'),(6,'NZ','private')")
    result = run_dxt(project, 'metric', 'query', '--metrics', 'revenue', '--group-by', 'customer__country', *flags)
    assert result.returncode != 0, result.stderr
    assert diagnostic in result.stderr, result.stderr
    assert 'metric-fixture-secret' not in result.stderr
    assert query(project / 'warehouse.duckdb', "select table_name from information_schema.tables where table_name like '__dxt_%'") == []


def test_metric_cross_database_saved_table_export_and_view_preflight(cross_metric_project):
    from test_usability_commands import query
    project, configuration, server = cross_metric_project
    properties = project / 'models/semantic.yml'
    original = properties.read_text().replace('group_by: ["TimeDimension(\'metric_time\', \'day\')"]', 'group_by: ["Dimension(\'customer__country\')"]').replace('order_by: ["TimeDimension(\'metric_time\', \'day\')"]', 'order_by: ["Dimension(\'customer__country\')"]')
    properties.write_text(original)
    result = run_dxt(project, 'metric', 'export', '--saved-query', 'daily_revenue', '--connection', 'warehouse', '--allow-movement')
    assert result.returncode == 0, result.stderr
    expected = query(project / 'warehouse.duckdb', 'select * from reporting.daily_revenue_export order by customer__country')
    assert {row['customer__country'] for row in expected} == {'CA', 'AU', 'NZ', None}
    properties.write_text(original.replace('export_as: table', 'export_as: view'))
    result = run_dxt(project, 'metric', 'export', '--saved-query', 'daily_revenue', '--connection', 'warehouse', '--allow-movement')
    assert result.returncode != 0, result.stderr
    assert 'CrossDatabaseMetricViewUnavailable' in result.stderr
    assert query(project / 'warehouse.duckdb', 'select * from reporting.daily_revenue_export order by customer__country') == expected
    properties.write_text(original.replace('source: [analytics, customers]', 'source: [analytics, absent_customers]'))
    result = run_dxt(project, 'metric', 'export', '--saved-query', 'daily_revenue', '--connection', 'warehouse', '--allow-movement')
    assert result.returncode != 0, result.stderr
    assert query(project / 'warehouse.duckdb', 'select * from reporting.daily_revenue_export order by customer__country') == expected


def test_metric_named_local_views_recompute_without_movement(cross_metric_project):
    from test_usability_commands import query
    project, configuration, server = cross_metric_project
    properties = project / 'models/semantic.yml'
    source = properties.read_text()
    source = source.replace('        connection: crm\n', '').replace('        source: [analytics, customers]\n', '')
    properties.write_text(source.replace('export_as: table', 'export_as: view'))
    result = run_dxt(project, 'metric', 'export', '--saved-query', 'daily_revenue', '--connection', 'warehouse')
    assert result.returncode == 0, result.stderr
    assert query(project / 'warehouse.duckdb', "select revenue from reporting.daily_revenue_export where metric_time__day=date '2024-01-01'") == [{'revenue': 30}]
    query(project / 'warehouse.duckdb', "update dev.orders set amount=amount+1 where ordered_at=date '2024-01-01'")
    assert query(project / 'warehouse.duckdb', "select revenue from reporting.daily_revenue_export where metric_time__day=date '2024-01-01'") == [{'revenue': 32}]
    assert json.loads((project / 'target/metric_plan.json').read_text())['movement'] == []


def test_metric_cross_database_source_reduction_and_budget_flags(cross_metric_project):
    project, configuration, server = cross_metric_project
    properties = project / 'models/semantic.yml'
    properties.write_text(properties.read_text().replace('        source: [analytics, customers]\n', "        source: [analytics, customers]\n        source_query: \"SELECT id,country FROM analytics.customers WHERE country <> 'NZ'\"\n"))
    flags = ['--connection', 'warehouse', '--allow-movement', '--max-rows', '20', '--max-bytes', '2048',
             '--max-memory-bytes', '33554432', '--max-spill-bytes', '0', '--max-objects', '8', '--max-query-seconds', '10', '--max-cost', '0']
    result = run_dxt(project, 'metric', 'query', '--metrics', 'revenue', '--group-by', 'customer__country', *flags)
    assert result.returncode == 0, result.stderr
    assert {row['customer__country'] for row in json.loads(result.stdout)} == {'CA', 'AU', None}
    plan = json.loads((project / 'target/metric_plan.json').read_text())
    assert "WHERE country <> 'NZ'" in plan['movement'][0]['query']
    assert plan['cross_database']['models'][0]['budget'] == {
        'max_rows': 20, 'max_bytes': 2048, 'max_memory_bytes': 33554432, 'max_spill_bytes': 0,
        'max_objects': 8, 'max_query_seconds': 10, 'max_cost': 0,
    }
    configuration['connections']['crm']['egress_per_gib'] = 1
    (project / 'dxt_connections.yml').write_text(json.dumps(configuration))
    result = run_dxt(project, 'metric', 'query', '--metrics', 'revenue', '--group-by', 'customer__country', *flags)
    assert result.returncode != 0
    assert 'CrossDatabasePolicyDenied' in result.stderr


def test_metric_saved_export_database_is_validated_before_execution(tmp_path):
    project = metric_project(tmp_path / 'metric')
    properties = project / 'models/semantic.yml'
    properties.write_text(properties.read_text().replace('export_as: table', 'export_as: table\n          database: absent_database'))
    result = run_dxt(project, 'metric', 'export', '--saved-query', 'daily_revenue')
    assert result.returncode != 0
    assert 'MetricExportDatabaseMismatch' in result.stderr
    assert not (project / 'warehouse.duckdb').exists()
    assert not (project / 'target/metric_plan.json').exists()


def test_metric_cross_database_duckdb_to_postgres_exact_decimal_export(tmp_path, monkeypatch, core_runner):
    import os
    import ctypes.util
    import postgres_fixture as pgserver
    import psycopg2
    import duckdb
    from decimal import Decimal
    library = os.environ.get('DXT_DUCKDB_LIBRARY') or ctypes.util.find_library('duckdb')
    assert library, 'Metric movement acceptance requires the pinned standalone native DuckDB library'
    monkeypatch.setenv('DXT_DUCKDB_LIBRARY', library)
    monkeypatch.setenv('DXT_DUCKDB_BACKEND', 'native')
    with pgserver.get_server(tmp_path / 'postgres-data') as server:
        project = metric_project(tmp_path / 'metric')
        properties = project / 'models/semantic.yml'
        source = properties.read_text().replace("  - name: customers\n    model: ref('customers')\n", """  - name: customers
    model: ref('customers')
    config:
      meta:
        connection: dims
        source: [main, customers]
        estimated_rows: 1
        estimated_bytes: 16
""")
        source = source.replace('group_by: ["TimeDimension(\'metric_time\', \'day\')"]', 'group_by: ["Dimension(\'customer__country\')"]').replace('order_by: ["TimeDimension(\'metric_time\', \'day\')"]', 'order_by: ["Dimension(\'customer__country\')"]')
        properties.write_text(source)
        dim_database = project / 'dims.duckdb'
        with duckdb.connect(str(dim_database)) as connection:
            connection.execute("create table customers as select 1::bigint id,'US'::varchar country")
        info = server.get_postmaster_info()
        profiles = {'commands': {'target': 'dev', 'outputs': {
            'dev': {'type': 'postgres', 'host': str(info.socket_dir), 'port': info.port,
                    'dbname': 'postgres', 'user': 'postgres', 'password': '', 'schema': 'dev'},
            'dims': {'type': 'duckdb', 'path': str(dim_database), 'schema': 'main'},
        }}}
        (project / 'profiles.yml').write_text(json.dumps(profiles))
        (project / 'dxt_connections.yml').write_text(json.dumps({'connections': {
            'warehouse': {'profile': 'commands', 'target': 'dev', 'role': 'both'},
            'dims': {'profile': 'commands', 'target': 'dims', 'role': 'source', 'allowed_destinations': ['warehouse']},
        }}))
        with psycopg2.connect(server.get_uri()) as connection:
            with connection.cursor() as cursor:
                cursor.execute('create schema dev;create table dev.orders(id bigint,customer_id bigint,amount numeric(20,4),ordered_at date,status text)')
                cursor.execute("insert into dev.orders values(1,1,1234567890123456.7890,'2024-01-01','paid'),(2,1,2.0001,'2024-01-03','paid')")
        assert invoke_core(core_runner, project, 'parse').success
        result = run_dxt(project, 'metric', 'query', '--metrics', 'revenue', '--group-by', 'customer__country', '--connection', 'warehouse', '--allow-movement')
        assert result.returncode == 0, result.stderr
        expected = Decimal('1234567890123458.7891')
        assert json.loads(result.stdout, parse_float=Decimal) == [{'customer__country': 'US', 'revenue': expected}]
        for attempt in range(2):
            result = run_dxt(project, 'metric', 'export', '--saved-query', 'daily_revenue', '--connection', 'warehouse', '--allow-movement')
            assert result.returncode == 0, result.stderr
        with psycopg2.connect(server.get_uri()) as connection:
            with connection.cursor() as cursor:
                cursor.execute('select * from reporting.daily_revenue_export')
                assert cursor.fetchall() == [('US', expected)]
                cursor.execute("select data_type from information_schema.columns where table_schema='reporting' and table_name='daily_revenue_export' and column_name='revenue'")
                assert cursor.fetchone() == ('numeric',)


def edge_metric_project(path):
    project = metric_project(path)
    properties = project / 'models/semantic.yml'
    source = properties.read_text().replace('      - name: paid_count\n', '''      - name: current_balance
        agg: sum
        expr: amount
        non_additive_dimension:
          name: ordered_at
          window_choice: max
          window_groupings: [customer]
      - name: total_balance
        agg: sum
        expr: amount
        non_additive_dimension:
          name: ordered_at
          window_choice: max
      - name: paid_count
''')
    source = source.replace('saved_queries:\n', '''  - name: current_balance
    label: Current Balance
    type: simple
    type_params: {measure: current_balance}
  - name: total_balance
    label: Total Balance
    type: simple
    type_params: {measure: total_balance}
  - name: all_time_revenue
    label: All Time Revenue
    type: cumulative
    type_params: {measure: order_amount}
  - name: month_start_revenue
    label: Month Start Revenue
    type: derived
    type_params:
      expr: prior
      metrics: [{name: revenue, alias: prior, offset_to_grain: month}]
saved_queries:
''')
    properties.write_text(source)
    orders = project / 'models/orders.sql'
    source = orders.read_text().replace("(5,NULL,0,'cancelled',date '2024-01-09'))", "(5,NULL,0,'cancelled',date '2024-01-09'),\n      (6,1,7,'paid',date '2024-01-04'))")
    orders.write_text(source)
    return project


@pytest.mark.parametrize('metric,groups,start,end', [
    ('current_balance', [], None, None),
    ('total_balance', [], None, None),
    ('current_balance', ['customer__country'], None, None),
    ('current_balance', ['order_key__status'], None, None),
    ('current_balance', ['metric_time__day'], None, None),
    ('current_balance', ['metric_time__month'], None, None),
    ('current_balance', ['metric_time__month', 'customer__country'], None, None),
    ('current_balance', [], '2024-01-01', '2024-01-03'),
    ('all_time_revenue', [], None, None),
    ('all_time_revenue', ['customer__country'], None, None),
    ('all_time_revenue', ['metric_time__day'], None, None),
    ('month_start_revenue', ['metric_time__day'], None, None),
    ('month_start_revenue', ['metric_time__day', 'customer__country'], None, None),
    ('month_start_revenue', ['metric_time__day'], '2024-01-08', '2024-01-09'),
])
def test_metricflow_nonadditive_balances_all_time_and_grain_offsets(tmp_path, core_runner, metric, groups, start, end):
    from test_usability_commands import query
    project = edge_metric_project(tmp_path / 'metric')
    assert invoke_core(core_runner, project, 'parse').success
    assert run_dxt(project, 'build').returncode == 0
    sql = metricflow_sql(project, [metric], groups, start_time=start, end_time=end)
    expected = query(project / 'warehouse.duckdb', sql)
    flags = ['--metrics', metric]
    if groups:
        flags += ['--group-by', ','.join(groups)]
    if start:
        flags += ['--start-time', start, '--end-time', end]
    result = run_dxt(project, 'metric', 'query', *flags)
    assert result.returncode == 0, result.stderr
    assert canonical_rows(json.loads(result.stdout)) == canonical_rows(expected)


@pytest.mark.parametrize('aggregation,params', [
    ('min', ''), ('max', ''), ('count', ''), ('count_distinct', ''),
    ('average', ''), ('median', ''), ('sum_boolean', ''),
    ('percentile', 'agg_params: {percentile: 0.25}'),
    ('percentile', 'agg_params: {percentile: 0.25, use_discrete_percentile: true}'),
    ('percentile', 'agg_params: {percentile: 0.25, use_approximate_percentile: true}'),
])
@pytest.mark.parametrize('empty', [False, True])
def test_metricflow_aggregation_nulls_and_empty_inputs(tmp_path, core_runner, aggregation, params, empty):
    from test_usability_commands import query
    project = metric_project(tmp_path / 'metric')
    properties = project / 'models/semantic.yml'
    expr = "status = 'paid'" if aggregation == 'sum_boolean' else 'amount'
    measure = f'      - name: tested_aggregation\n        agg: {aggregation}\n        expr: "{expr}"\n'
    if params:
        measure += f'        {params}\n'
    source = properties.read_text().replace('      - name: paid_count\n', measure + '      - name: paid_count\n')
    source = source.replace('saved_queries:\n', '''  - name: tested_aggregation
    label: Tested Aggregation
    type: simple
    type_params: {measure: tested_aggregation}
saved_queries:
''')
    properties.write_text(source)
    assert invoke_core(core_runner, project, 'parse').success
    assert run_dxt(project, 'build').returncode == 0
    where = ['1 = 0'] if empty else None
    expected = query(project / 'warehouse.duckdb', metricflow_sql(project, ['tested_aggregation'], [], where=where))
    flags = ['--metrics', 'tested_aggregation'] + (['--where', where[0]] if where else [])
    result = run_dxt(project, 'metric', 'query', *flags)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == expected


@pytest.mark.parametrize('metric,grain,bounded', [
    ('revenue', 'day', False), ('rolling_revenue', 'day', False),
    ('rolling_revenue', 'month', False), ('rolling_revenue_last', 'month', False),
    ('rolling_revenue_average', 'month', False), ('revenue_change', 'day', False),
    ('current_balance', 'day', False), ('current_balance', 'month', False),
    ('complete_revenue', 'day', False), ('month_start_revenue', 'day', False),
    ('rolling_revenue', 'month', True),
])
def test_metricflow_own_aggregation_time_dimension_groups(tmp_path, core_runner, metric, grain, bounded):
    from test_usability_commands import query
    project = edge_metric_project(tmp_path / 'metric')
    assert invoke_core(core_runner, project, 'parse').success
    assert run_dxt(project, 'build').returncode == 0
    group = f'order_key__ordered_at__{grain}'
    start, end = ('2024-01-03', '2024-01-08') if bounded else (None, None)
    sql = metricflow_sql(project, [metric], [group], start_time=start, end_time=end)
    expected = query(project / 'warehouse.duckdb', sql)
    flags = ['--metrics', metric, '--group-by', group]
    if bounded:
        flags += ['--start-time', start, '--end-time', end]
    result = run_dxt(project, 'metric', 'query', *flags)
    assert result.returncode == 0, result.stderr
    assert canonical_rows(json.loads(result.stdout)) == canonical_rows(expected)


def test_native_bounded_own_time_offsets_cover_metricflow_assertion_divergence(tmp_path, core_runner):
    from test_usability_commands import query
    project = edge_metric_project(tmp_path / 'metric')
    assert invoke_core(core_runner, project, 'parse').success
    assert run_dxt(project, 'build').returncode == 0
    group = 'order_key__ordered_at__day'
    with pytest.raises(AssertionError, match='No metric time dimensions with standard granularities'):
        metricflow_sql(project, ['revenue_change'], [group], start_time='2024-01-03', end_time='2024-01-08')
    # The pinned planner cannot render this alias with a time bound. Its supported
    # metric_time alias is the same aggregation-time dimension and remains a
    # complete result oracle for the native extension.
    sql = metricflow_sql(project, ['revenue_change'], ['metric_time__day'], start_time='2024-01-03', end_time='2024-01-08')
    expected = query(project / 'warehouse.duckdb', sql)
    expected = [{group: row.pop('metric_time__day'), **row} for row in expected]
    result = run_dxt(project, 'metric', 'query', '--metrics', 'revenue_change', '--group-by', group,
                     '--start-time', '2024-01-03', '--end-time', '2024-01-08')
    assert result.returncode == 0, result.stderr
    assert canonical_rows(json.loads(result.stdout)) == canonical_rows(expected)


@pytest.mark.parametrize('bound', ['not-a-date', '2024-02-30', '2023-02-29', '2024-01-01T25:00:00'])
def test_invalid_metric_timestamp_fails_before_warehouse_or_plan(tmp_path, core_runner, bound):
    from datetime import datetime
    with pytest.raises(ValueError):
        datetime.fromisoformat(bound)
    project = metric_project(tmp_path / 'metric')
    result = run_dxt(project, 'metric', 'explain', '--metrics', 'revenue', '--start-time', bound)
    assert result.returncode == 2, result.stdout + result.stderr
    assert 'InvalidMetricTimestamp' in result.stderr
    assert not (project / 'warehouse.duckdb').exists()
    assert not (project / 'target/metric_plan.json').exists()


@pytest.mark.parametrize('group', ['order_key__day', 'customer__day', 'order_key__ordered_at__hour'])
def test_metric_entity_grains_and_finer_source_time_fail_before_execution(tmp_path, core_runner, group):
    from metricflow_semantics.errors.error_classes import InvalidQueryException
    project = metric_project(tmp_path / 'metric')
    assert invoke_core(core_runner, project, 'parse').success
    with pytest.raises(InvalidQueryException):
        metricflow_sql(project, ['revenue'], [group])
    result = run_dxt(project, 'metric', 'explain', '--metrics', 'revenue', '--group-by', group)
    assert result.returncode == 2, result.stdout + result.stderr
    assert 'metric time grain is invalid or finer than its source dimension' in result.stderr
    assert not (project / 'warehouse.duckdb').exists()
    assert not (project / 'target/metric_plan.json').exists()

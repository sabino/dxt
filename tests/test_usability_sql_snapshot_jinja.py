"""General SQL snapshot Jinja contracts against actual Core on both adapters."""
import json

import pytest

from test_cli import build_dxt  # noqa: F401
from test_usability_adapters import duckdb_environment  # noqa: F401
from test_usability_cli_options import environment, pinned_core  # noqa: F401
from test_usability_configuration import configuration_postgres  # noqa: F401
from test_usability_sql_operations import command, project, warehouse_rows


MACROS = """{% macro history_config(strategy) -%}
  {{ return({'strategy': strategy, 'unique_key': var('history_key'), 'target_schema': target.schema ~ '_archive', 'updated_at': 'ts', 'check_cols': ['name'] if strategy == 'check' else none, 'meta': {'origin': 'macro'}, 'custom_setting': 'retained'}) }}
{%- endmacro %}
{% macro history_query(relation, columns) -%}
select {% for column in columns %}{{ adapter.quote(column) }}{% if not loop.last %}, {% endif %}{% endfor %}
from {{ relation.render() }}
{%- endmacro %}
"""
BODY = """
{% raw %}
-- literal snapshot token: {% endsnapshot %} {{ untouched }}
{% endraw %}
{% set strategy = STRATEGY %}
{{ config(history_config(strategy)) }}
{% set columns = ['id', 'name', 'ts'] %}
{% if var('include_history', true) %}
  {{ history_query(ref(var('history_model')), columns) }}
{% else %}
  select 0 as id, '' as name, cast('2024-01-01' as timestamp) as ts where false
{% endif %}
"""


def create(base, engine, adapter, request):
    root, schema = project(base, engine, adapter, request)
    (root / 'profiles.yml').write_text((root / 'profiles.yml').read_text().replace('threads: 2', 'threads: 1'))
    (root / 'dbt_project.yml').write_text((root / 'dbt_project.yml').read_text() + "vars:\n  history_key: id\n  history_model: current\n")
    (root / 'macros/history.sql').write_text(MACROS)
    (root / 'seeds/input.csv').write_text('id,name,ts\n1,Alice,2024-01-01\n2,,2024-01-02\n')
    (root / 'models/current.sql').write_text("{{ config(materialized='table') }}select id,name,cast(ts as timestamp) as ts from {{ ref('input') }}")
    snapshots = root / 'snapshots/nested'
    snapshots.mkdir(parents=True)
    (snapshots / 'dynamic.sql').write_text(' \n{{ 1 }}\n{% set outside = 1 %}\n{% macro ignored() %}ignored{% endmacro %}\n{# shared snapshot file #}\n' + ''.join('{% snapshot ' + name + ' %}' + BODY.replace('STRATEGY', repr(strategy)) + '{% endsnapshot %}\n' for name, strategy in [('timestamp_history', 'timestamp'), ('check_history', 'check')]) + ' \n')
    return root, schema


def normalized(value, root, schema):
    return json.loads(json.dumps(value).replace(str(root), '<project>').replace(schema, '<target>'))


def projected(root, schema):
    manifest = json.loads((root / 'target/manifest.json').read_text())
    fields = ['unique_id', 'resource_type', 'package_name', 'name', 'path', 'original_file_path', 'fqn', 'raw_code', 'checksum', 'refs', 'sources', 'depends_on', 'config', 'unrendered_config', 'database', 'schema', 'alias', 'relation_name']
    output = {}
    for name in ['timestamp_history', 'check_history']:
        node = manifest['nodes']['snapshot.preview.' + name]
        selected = {key: node[key] for key in fields}
        if node.get('compiled'):
            selected.update({key: node[key] for key in ['compiled', 'compiled_code', 'extra_ctes', 'extra_ctes_injected']})
        output[name] = normalized(selected, root, schema)
    return output


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_sql_snapshot_jinja_dynamic_config_macros_identity_sql_and_history(tmp_path, request, duckdb_environment, adapter):
    observed = {}
    for engine in ['dxt', 'core']:
        root, schema = create(tmp_path, engine, adapter, request)
        env = environment(duckdb_environment)
        command(engine, root, env, 'parse')
        parsed = projected(root, schema)
        command(engine, root, env, 'compile', ['-s', 'resource_type:snapshot'])
        compiled = projected(root, schema)
        command(engine, root, env, 'seed')
        command(engine, root, env, 'run', ['-s', 'current'])
        command(engine, root, env, 'snapshot')
        executed = projected(root, schema)
        histories = []
        for name in ['timestamp_history', 'check_history']:
            rows = warehouse_rows(root, adapter, request, f'select id,name,cast(ts as varchar),dbt_scd_id,cast(dbt_updated_at as varchar),cast(dbt_valid_from as varchar),cast(dbt_valid_to as varchar) from "{schema}_archive"."{name}" order by id,dbt_valid_from')
            assert len(rows) == 2
            histories.append(rows)
        assert warehouse_rows(root, adapter, request, f'update "{schema}"."input" set name=\'Alicia\',ts=\'2024-02-01\' where id=1 returning id') == [(1,)]
        command(engine, root, env, 'run', ['-s', 'current'])
        command(engine, root, env, 'snapshot')
        changed = []
        for name in ['timestamp_history', 'check_history']:
            rows = warehouse_rows(root, adapter, request, f'select id,name,cast(ts as varchar),dbt_scd_id,cast(dbt_updated_at as varchar),cast(dbt_valid_from as varchar),cast(dbt_valid_to as varchar) from "{schema}_archive"."{name}" order by id,dbt_valid_from')
            assert len(rows) == 3 and rows[0][1] == 'Alice' and rows[0][-1] == '2024-02-01 00:00:00' and rows[1][1] == 'Alicia' and rows[1][-1] is None
            changed.append(rows)
        command(engine, root, env, 'snapshot')
        repeated = [warehouse_rows(root, adapter, request, f'select id,name,cast(ts as varchar),dbt_scd_id,cast(dbt_updated_at as varchar),cast(dbt_valid_from as varchar),cast(dbt_valid_to as varchar) from "{schema}_archive"."{name}" order by id,dbt_valid_from') for name in ['timestamp_history', 'check_history']]
        assert repeated == changed
        observed[engine] = (parsed, compiled, executed, histories, changed)
    assert observed['dxt'] == observed['core']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('body', ["{% if true %}select 1", "{{ config(strategy='timestamp', unique_key='id', updated_at='ts', materialized='table') }}select 1 as id", "{{ exceptions.raise_compiler_error('authored snapshot failure') }}select 1"])
def test_core_sql_snapshot_jinja_invalid_bodies_fail_before_artifacts(tmp_path, request, duckdb_environment, adapter, body):
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, adapter, request)
        (root / 'snapshots').mkdir()
        (root / 'snapshots/invalid.sql').write_text('{% snapshot invalid %}' + body + '{% endsnapshot %}')
        result = command(engine, root, environment(duckdb_environment), 'parse', ok=False)
        assert result.returncode == 2
        assert not (root / 'target/manifest.json').exists()


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('outer', ['if true', 'for item in [1]'])
def test_core_snapshot_definitions_must_be_outside_control_flow(tmp_path, request, duckdb_environment, adapter, outer):
    ending = 'endif' if outer.startswith('if') else 'endfor'
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, adapter, request)
        (root / 'snapshots').mkdir()
        body = "{{ config(strategy='timestamp', unique_key='id', updated_at='ts') }}select 1 as id,cast('2024-01-01' as timestamp) as ts"
        (root / 'snapshots/nested.sql').write_text('{% ' + outer + ' %}{% snapshot nested %}' + body + '{% endsnapshot %}{% ' + ending + ' %}')
        result = command(engine, root, environment(duckdb_environment), 'parse', ok=False)
        assert result.returncode == 2
        assert not (root / 'target/manifest.json').exists()

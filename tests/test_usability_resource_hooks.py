"""Native resource hooks against pinned Core transactions and adapters."""
import json
from pathlib import Path
from urllib.parse import unquote, urlparse

import pytest

from test_usability_configuration import ConfigurationPair, configure_adapter, configuration_oracle, configuration_postgres
from test_cli import build_dxt


def setup_pair(tmp_path, oracle, request, adapter):
    pair = ConfigurationPair(tmp_path, oracle)
    configure_adapter(pair, request, adapter)
    if adapter == 'postgres':
        suffix = ''.join(c for c in tmp_path.name if c.isalnum())[-24:]
        for project in pair.projects:
            path = project / 'profiles.yml'
            path.write_text(path.read_text().replace('schema: main', 'schema: hook_' + project.name + '_' + suffix))
    return pair


def rows(pair, request, adapter, sql):
    result = []
    for project in pair.projects:
        if adapter == 'duckdb':
            import duckdb
            with duckdb.connect(str(project / 'warehouse.duckdb')) as connection:
                result.append(connection.execute(sql.format(schema='main')).fetchall())
        else:
            import psycopg2
            import yaml
            server = request.getfixturevalue('configuration_postgres')
            schema = yaml.safe_load((project / 'profiles.yml').read_text())['configuration_fixture']['outputs']['dev']['schema']
            with psycopg2.connect(server.get_uri()) as connection:
                with connection.cursor() as cursor:
                    cursor.execute(sql.format(schema=schema))
                    result.append(cursor.fetchall())
    return result


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_resource_hooks_execute_project_yaml_inline_order_and_node_context(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.append_project("""models:
  configuration_fixture:
    +pre-hook:
      - {sql: "create table if not exists {{ target.schema }}.hook_events (sequence integer, label varchar)", transaction: false}
      - "insert into {{ target.schema }}.hook_events values (1, 'project-pre')"
    +post-hook:
      - "insert into {{ target.schema }}.hook_events select 4, 'project-post:' || cast(id as varchar) from {{ this }}"
      - {sql: "insert into {{ target.schema }}.hook_events values (7, 'outside-post')", transaction: false}
""")
    pair.write('models/properties.yml', """version: 2
models:
  - name: rendered
    config:
      pre_hook: "insert into {{ target.schema }}.hook_events values (2, 'yaml-pre')"
      post_hook: "insert into {{ target.schema }}.hook_events values (5, 'yaml-post')"
""")
    pair.write('models/marts/rendered.sql', """{{ config(materialized='table', pre_hook="insert into {{ target.schema }}.hook_events values (3, 'inline-pre')", post_hook="insert into {{ target.schema }}.hook_events values (6, '{{ model.name }}:inline-post')") }}
select 9 as id
""")
    pair.invoke('run')
    actual, expected = rows(pair, request, adapter, 'select sequence, label from {schema}.hook_events order by sequence')
    assert actual == expected == [(1, 'project-pre'), (2, 'yaml-pre'), (3, 'inline-pre'), (4, 'project-post:9'), (5, 'yaml-post'), (6, 'rendered:inline-post'), (7, 'outside-post')]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_failed_post_hook_rolls_back_replacement_and_inner_hooks(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.append_project("""models:
  configuration_fixture:
    +pre-hook:
      - {sql: "create table if not exists {{ target.schema }}.hook_events (sequence integer)", transaction: false}
      - "insert into {{ target.schema }}.hook_events values (1)"
""")
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table') }}select 1 as id")
    pair.invoke('run')
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table', post_hook='select * from missing_hook_relation') }}select 2 as id")
    pair.invoke('run', success=False)
    assert rows(pair, request, adapter, 'select id from {schema}.rendered') == [[(1,)], [(1,)]]
    assert rows(pair, request, adapter, 'select sequence from {schema}.hook_events') == [[(1,)], [(1,)]]
    for project in pair.projects:
        results = json.loads((project / 'target/run_results.json').read_text())['results']
        assert [row['status'] for row in results] == ['error']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_seed_post_hook_adapter_drop_relation_has_real_effect(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.append_project("""seeds:
  configuration_fixture:
    +post-hook: "{% do adapter.drop_relation(this.incorporate(type='table')) %}"
""")
    pair.write('seeds/dropped.csv', 'id,label\n1,one\n')
    pair.invoke('seed')
    assert rows(pair, request, adapter, "select count(*) from information_schema.tables where table_schema='{schema}' and table_name='dropped'") == [[(0,)], [(0,)]]
    pair.invoke('seed')
    assert rows(pair, request, adapter, "select count(*) from information_schema.tables where table_schema='{schema}' and table_name='dropped'") == [[(0,)], [(0,)]]

"""Actual adapter grants/comments and parse config providers against Core."""
import json

import pytest

from test_cli import build_dxt
from test_usability_configuration import configuration_oracle, configuration_postgres
from test_usability_resource_hooks import setup_pair, rows


def relation_comment(adapter):
    if adapter == 'duckdb':
        return "select comment from (select schema_name, table_name as relation_name, comment from duckdb_tables() union all select schema_name, view_name as relation_name, comment from duckdb_views()) where schema_name='{schema}' and relation_name='rendered'"
    return "select obj_description(c.oid, 'pg_class') from pg_class c join pg_namespace n on c.relnamespace=n.oid where n.nspname='{schema}' and c.relname='rendered'"


def column_comments(adapter):
    if adapter == 'duckdb':
        return "select column_name, comment from duckdb_columns() where schema_name='{schema}' and table_name='rendered' order by column_index"
    return "select a.attname, col_description(c.oid, a.attnum) from pg_class c join pg_namespace n on c.relnamespace=n.oid join pg_attribute a on a.attrelid=c.oid where n.nspname='{schema}' and c.relname='rendered' and a.attnum>0 and not a.attisdropped order by a.attnum"


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('kind', ['table', 'view', 'seed'])
def test_persist_docs_updates_actual_relation_and_existing_columns(tmp_path, configuration_oracle, request, adapter, kind):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    if kind == 'seed':
        pair.write('seeds/rendered.csv', 'id,label\n1,one\n')
    else:
        pair.write('models/marts/rendered.sql', "{{ config(materialized='" + kind + "') }}select 1 as id, 'one' as label")
    section = 'seeds' if kind == 'seed' else 'models'
    pair.write('models/properties.yml', """version: 2
""" + section + """:
  - name: rendered
    description: "Owner's description\nwith a second line"
    config: {persist_docs: {relation: true, columns: true}}
    columns:
      - {name: id, description: "An identifier's description"}
      - {name: label, description: 'Label value'}
      - {name: absent, description: 'Not an actual column'}
""")
    command = 'seed' if kind == 'seed' else 'run'
    for _ in range(2):
        pair.invoke(command)
        assert rows(pair, request, adapter, relation_comment(adapter)) == [[("Owner's description with a second line",)], [("Owner's description with a second line",)]]
        assert rows(pair, request, adapter, column_comments(adapter)) == [[('id', "An identifier's description"), ('label', 'Label value')]] * 2


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_failed_persist_docs_preserves_previous_table_and_comments(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table', persist_docs={'relation': True}) }}select 1 as id")
    pair.write('models/properties.yml', "version: 2\nmodels:\n  - {name: rendered, description: old-description}\n")
    pair.invoke('run')
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table', persist_docs={'relation': True}) }}select 2 as id")
    pair.write('models/properties.yml', "version: 2\nmodels:\n  - {name: rendered, description: '$dbt_comment_literal_block$'}\n")
    pair.invoke('run', success=False)
    assert rows(pair, request, adapter, 'select id from {schema}.rendered') == [[(1,)], [(1,)]]
    assert rows(pair, request, adapter, relation_comment(adapter)) == [[('old-description',)], [('old-description',)]]


def test_postgres_incremental_grants_revoke_previous_roles(tmp_path, configuration_oracle, request):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'postgres')
    import psycopg2
    server = request.getfixturevalue('configuration_postgres')
    prefix = 'grant_' + ''.join(c for c in tmp_path.name if c.isalnum())[-30:]
    roles = [prefix + '_first', prefix + '_second']
    with psycopg2.connect(server.get_uri()) as connection:
        with connection.cursor() as cursor:
            for role in roles:
                cursor.execute('create role "' + role + '"')
    for role in roles:
        pair.write('models/marts/rendered.sql', "{{ config(materialized='incremental', grants={'select': ['" + role + "']}) }}select 1 as id")
        pair.invoke('run')
        query = "select grantee, privilege_type from information_schema.role_table_grants where table_schema='{schema}' and table_name='rendered' and grantee in ('" + "','".join(roles) + "') order by grantee, privilege_type"
        assert rows(pair, request, 'postgres', query) == [[(role, 'SELECT')], [(role, 'SELECT')]]


def test_postgres_failed_grant_rolls_back_replacement(tmp_path, configuration_oracle, request):
    pair = setup_pair(tmp_path, configuration_oracle, request, 'postgres')
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table') }}select 1 as id")
    pair.invoke('run')
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table', grants={'select': ['dxt_missing_role_for_grant_failure']}) }}select 2 as id")
    pair.invoke('run', success=False)
    assert rows(pair, request, 'postgres', 'select id from {schema}.rendered') == [[(1,)], [(1,)]]


def test_grant_diff_uses_unicode_casefold_and_preserves_left_case(tmp_path, configuration_oracle):
    from test_usability_configuration import ConfigurationPair
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('models/marts/rendered.sql', """{% set result = diff_of_two_dicts({'Straße': ['ﬃ', 'Missing'], 'untouched': []}, {'STRASSE': ['FFI']}) %}
select '{{ tojson(result) }}' as result
""")
    actual, expected = pair.invoke('compile')
    assert actual['nodes']['model.configuration_fixture.rendered']['compiled_code'] == expected['nodes']['model.configuration_fixture.rendered']['compiled_code']


def test_parse_config_methods_return_empty_and_runtime_returns_values(tmp_path, configuration_oracle):
    from test_usability_configuration import ConfigurationPair
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('models/marts/rendered.sql', """{{ config(materialized='table', persist_docs={'relation': True, 'columns': True}) }}
{% if not execute and (config.get('materialized', 'fallback') != '' or config.require('missing') != '' or config.persist_relation_docs() or config.persist_column_docs()) %}
{{ exceptions.raise_compiler_error('Parse config provider was not empty') }}
{% endif %}
select '{{ config.get('materialized') }}:{{ config.persist_relation_docs() }}:{{ config.persist_column_docs() }}' as value
""")
    actual, expected = pair.invoke('compile')
    assert actual['nodes']['model.configuration_fixture.rendered']['compiled_code'] == expected['nodes']['model.configuration_fixture.rendered']['compiled_code']

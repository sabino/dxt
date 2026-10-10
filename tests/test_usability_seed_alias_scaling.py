"""Verified CSV backing must not hide evolving mutable receiver aliases."""
import pytest

from test_cli import build_dxt  # noqa: F401
from test_usability_configuration import configuration_oracle, configuration_postgres  # noqa: F401
from test_usability_resource_hooks import setup_pair, rows
from test_usability_seed_bindings import assert_seed_artifacts, canonical
from test_usability_stock_artifacts import resource, runtime_sql
from validate_dbt_artifacts import read_artifact


CASES = [
    (
        'nested_saved_receiver',
        "{% set xs=[] %}{% set nested={'item':(xs,)} %}{% set append=xs.append %}"
        "{% for row in agate_table.rows %}{% do xs.extend(row) %}{% endfor %}"
        "{% do append(99) %}"
        "{% if xs|length != 5 or nested.item[0]|length != 5 or append != xs.append %}"
        "{{ exceptions.raise_compiler_error('nested saved alias') }}{% endif %}",
    ),
    (
        'namespace_after_publication',
        "{% set xs=[] %}{% set box=namespace(item=none) %}{% do xs.append(1) %}"
        "{% set box.item=xs %}{% do xs.append(2) %}"
        "{% if box.item != [1,2] %}{{ exceptions.raise_compiler_error('new namespace alias') }}{% endif %}",
    ),
    (
        'later_lazy_buffer',
        "{% set xs=[] %}{% set stream=[none,xs]|batch(1) %}{% set keep=namespace(loop=none) %}"
        "{% for chunk in stream %}{% set keep.loop=loop %}"
        "{% if loop.first %}{% do xs.append(1) %}{% else %}{% do xs.append(2) %}"
        "{% if chunk[0] != [1,2] %}{{ exceptions.raise_compiler_error('later lazy alias') }}{% endif %}"
        "{% endif %}{% endfor %}{% do xs.append(3) %}"
        "{% if keep.loop.previtem[0] is not none or xs != [1,2,3] %}"
        "{{ exceptions.raise_compiler_error('retained loop alias') }}{% endif %}",
    ),
    (
        'tuple_method_key',
        "{% set xs=[] %}{% set keys={(xs.append,):7} %}{% do xs.append(1) %}"
        "{% set append=keys|first|first %}{% do append(2) %}"
        "{% if keys[(xs.append,)] != 7 or xs != [1,2] %}"
        "{{ exceptions.raise_compiler_error('tuple method alias') }}{% endif %}",
    ),
]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('scenario, body', CASES, ids=[case[0] for case in CASES])
def test_real_seed_table_preserves_mutable_alias_publication(
    tmp_path, configuration_oracle, request, adapter, scenario, body
):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('seeds/input.csv', 'id,label\n1,one\n2,two\n')
    pair.append_project('seeds:\n  configuration_fixture:\n    input:\n      +fast: false\n')
    pair.write(
        'macros/load.sql',
        '{% macro load_csv_rows(model,agate_table) %}' + body
        + "{% if agate_table.rows[0]['id'] != 1 or agate_table.rows[1]['label'] != 'two' %}"
        + "{{ exceptions.raise_compiler_error('CSV backing changed') }}{% endif %}"
        + "{{ return(adapter.dispatch('load_csv_rows','dbt')(model,agate_table)) }}{% endmacro %}",
    )
    pair.invoke('seed')
    assert_seed_artifacts(pair)
    payloads = [runtime_sql(project, resource(project, 'input', 'seed')) for project in pair.projects]
    assert canonical(pair.projects[0], payloads[0]) == canonical(pair.projects[1], payloads[1])
    assert rows(pair, request, adapter, 'select id,label from {schema}.input order by id') == [[(1, 'one'), (2, 'two')]] * 2


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('body', [
    "{% set agate_table.rows = [] %}",
    "{% do agate_table['__dxt_data'].append(1) %}",
    "{% do agate_table.rows.update({'extra':[]}) %}",
])
def test_readonly_seed_provider_rejects_mutation_and_private_backing(
    tmp_path, configuration_oracle, request, adapter, body
):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('seeds/input.csv', 'id,label\n1,one\n2,two\n')
    pair.write('macros/load.sql', '{% macro load_csv_rows(model,agate_table) %}' + body
               + "{{ return(adapter.dispatch('load_csv_rows','dbt')(model,agate_table)) }}{% endmacro %}")
    pair.invoke('seed', success=False)
    for project in pair.projects:
        assert read_artifact(project / 'target/run_results.json')['results'][0]['status'] == 'error'
        assert resource(project, 'input', 'seed')['build_path'] is None

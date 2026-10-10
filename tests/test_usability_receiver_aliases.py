"""Saved builtin receivers survive replacement and public macro value copies."""
import pytest

from test_cli import build_dxt
from test_usability_configuration import configuration_oracle, configuration_postgres
from test_usability_resource_hooks import setup_pair


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('template, expected', [
    ("{% set a={'x':1} %}{% set get=a.get %}{% set before=get|string %}{% do a.update({a.get:11,'x':7}) %}{% set key=a.keys()|list|last %}select '{{ key('x') }}:{{ get==a.get }}:{{ before==get|string }}:{{ get|string==a.get|string }}:{% do a.update({'x':9}) %}{{ key('x') }}' as value", "select '7:True:True:True:9' as value"),
    ("{% set xs=[] %}{% set alias=xs %}{% set append=xs.append %}select '{% call(a) probe() %}{% call(b) probe() %}{% do append(a*10+b) %}{% endcall %}{% endcall %}{{ xs|join(',') }}:{{ alias|join(',') }}:{{ append==xs.append }}' as value", "select '11,12,21,22:11,12,21,22:True' as value"),
    ("{% set a={} %}{% set get=a.get %}{% set keys={(get,):7} %}{% do a.update({'x':1}) %}select '{{ keys[(a.get,)] }}:{{ keys|first|first==a.get }}:{{ get('x') }}' as value", "select '7:True:1' as value"),
])
def test_saved_receivers_keep_identity_calls_and_suspended_aliases(tmp_path, configuration_oracle, request, adapter, template, expected):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('macros/probe.sql', "{% macro probe() %}{{ caller(1) }}{{ caller(2) }}{% endmacro %}")
    pair.write('models/marts/rendered.sql', template)
    actual, reference = [manifest['nodes']['model.configuration_fixture.rendered'] for manifest in pair.invoke('compile')]
    assert reference['compiled_code'] == expected
    assert actual['compiled_code'] == reference['compiled_code']
    assert actual['depends_on'] == reference['depends_on']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_generic_where_provider_copy_preserves_saved_receiver_graph(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', 'select 1 as id')
    pair.write('models/properties.yml', "version: 2\nmodels:\n  - name: rendered\n    data_tests: [bound_bridge]\n")
    pair.write('macros/bridge.sql', """{% macro get_where_subquery(relation) %}{% set xs=[] %}{{ return({'receiver':xs,'method':xs.append,'fresh':xs.append}) }}{% endmacro %}
{% test bound_bridge(model) %}{% do model.method(7) %}select '{{ model.receiver|join(',') }}:{{ (model.method==model.fresh)|string }}' as state where false{% endtest %}""")
    actual, reference = pair.invoke('compile')
    actual_test = next(node for node in actual['nodes'].values() if node['resource_type'] == 'test' and node['name'].startswith('bound_bridge'))
    reference_test = reference['nodes'][actual_test['unique_id']]
    assert reference_test['compiled_code'] == "select '7:True' as state where false"
    assert actual_test['compiled_code'] == reference_test['compiled_code']
    assert actual_test['depends_on'] == reference_test['depends_on']

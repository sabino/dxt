"""Core Relation Mapping supports provider lookup, not dictionary iteration."""
import pytest

from test_cli import build_dxt
from test_usability_configuration import configuration_oracle, configuration_postgres
from test_usability_resource_hooks import setup_pair


POSITIVE = [
    ("traits", "select '{{ this is mapping }}:{{ this is sequence }}:{{ this.get('metadata', {}).get('type', '').endswith('Relation') }}' as value", "select 'True:False:True' as value"),
    ("provider_get", "{% set get=this.get %}select '{{ get(key='metadata').type.endswith('Relation') }}:{{ get('missing', default='fallback') }}:{{ (this|attr('get'))('metadata').type.endswith('Relation') }}' as value", "select 'True:fallback:True' as value"),
    ("public_lookup", "select '{{ this.get('identifier')==this.identifier }}:{{ this['identifier']==this.identifier }}:{{ 'database' in this }}:{{ 'metadata' in this }}:{{ this['metadata'] is undefined }}:{{ this.get('__dxt_relation_mapping','fallback') }}' as value", "select 'True:True:True:False:True:fallback' as value"),
    ("ordinary_reserved_dict", "{% set obj={'__dxt_context_object':True,'__dxt_relation_mapping':['ordinary'],'metadata':{'type':'AuthoredRelation'}} %}select '{{ obj is mapping }}:{{ obj is sequence }}:{{ obj is iterable }}:{{ obj.get('metadata').type }}:{{ obj|tojson }}' as value", "select 'True:True:True:AuthoredRelation:{\"__dxt_context_object\": true, \"__dxt_relation_mapping\": [\"ordinary\"], \"metadata\": {\"type\": \"AuthoredRelation\"}}' as value"),
    ("nonconsuming_views", "{% set keys=this.keys() %}{% set values=this.values() %}{% set items=this.items() %}select '{{ keys is iterable }}:{{ keys is sequence }}:{{ (keys|string).startswith('KeysView(<') }}:{{ (values|string).startswith('ValuesView(<') }}:{{ (items|string).startswith('ItemsView(<') }}' as value", "select 'True:False:True:True:True' as value"),
    ("mapping_macro", "select '{{ is_relation(this) }}:{{ is_relation({'metadata':{'type':'AuthoredRelation'}}) }}' as value", "select 'True:True' as value"),
]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('name, template, expected', POSITIVE)
def test_relation_mapping_preserves_provider_and_plain_dictionary_contract(tmp_path, configuration_oracle, request, adapter, name, template, expected):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('macros/identity.sql', "{% macro is_relation(obj) %}{{ return(obj is mapping and obj.get('metadata', {}).get('type', '').endswith('Relation')) }}{% endmacro %}")
    pair.write('models/marts/rendered.sql', template)
    actual, reference = [manifest['nodes']['model.configuration_fixture.rendered'] for manifest in pair.invoke('compile')]
    assert reference['compiled_code'] == expected
    assert actual['compiled_code'] == reference['compiled_code']
    assert actual['depends_on'] == reference['depends_on']


NEGATIVE = [
    ('iterable_test', "select '{{ this is iterable }}' as value"),
    ('length', "select '{{ this|length }}' as value"),
    ('list', "select '{{ this|list }}' as value"),
    ('loop', "{% for key in this %}{{ key }}{% endfor %}select 1"),
    ('dict', "select '{{ dict(this) }}' as value"),
    ('kwargs', "select '{{ dict(**this) }}' as value"),
    ('keys', "select '{{ this.keys()|list }}' as value"),
    ('values', "select '{{ this.values()|list }}' as value"),
    ('items', "select '{{ this.items()|list }}' as value"),
    ('view_bool', "{% if this.keys() %}select 1{% else %}select 0{% endif %}"),
    ('json_filter', "select '{{ this|tojson }}' as value"),
    ('json_function', "select '{{ tojson(this) }}' as value"),
    ('config', "{{ config(meta={'relation':this}) }}select 1"),
    ('update', "{% do this.update({'extra':1}) %}select 1"),
    ('clear', "{% do this.clear() %}select 1"),
    ('pop', "{% do this.pop('identifier') %}select 1"),
    ('update_from_relation', "{% set obj={} %}{% do obj.update(this) %}select 1"),
    ('extend_from_relation', "{% set obj=[] %}{% do obj.extend(this) %}select 1"),
]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('name, template', NEGATIVE)
def test_relation_mapping_rejects_iteration_mutation_and_dictionary_serialization(tmp_path, configuration_oracle, request, adapter, name, template):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', template)
    pair.invoke('compile', success=False)

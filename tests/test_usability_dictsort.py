"""Standard dictsort through native dxt and actual pinned Core on both adapters."""
import json
import pytest

from test_cli import build_dxt
from test_usability_configuration import configuration_oracle, configuration_postgres
from test_usability_resource_hooks import setup_pair


POSITIVE = [
    "{}|dictsort",
    "{none:'one'}|dictsort",
    "{'b':2,'a':1}|dictsort",
    "{'a':1,'B':2,'A':3,'b':4}|dictsort",
    "{'a':1,'B':2,'A':3,'b':4}|dictsort(true)",
    "{'a':1,'B':2,'A':3,'b':4}|dictsort(reverse=true)",
    "{'a':1,'B':2,'A':3,'b':4}|dictsort(true,'key',true)",
    "{'a':'b','b':'A','c':'a'}|dictsort(by='value')",
    "{'a':'b','b':'A','c':'a'}|dictsort(case_sensitive=true,by='value',reverse=true)",
    "{'a':false,'b':2.5,'c':-1,'d':true}|dictsort(by='value')",
    "{2.5:'float',-1:'integer',true:'bool',0:'zero'}|dictsort",
    "{9007199254740993:'second',9007199254740992:'first'}|dictsort",
    "{(2,'a'):'second',(1,'b'):'first',(1,'a'):'zero'}|dictsort",
    "{'a':[2,1],'b':[1,2],'c':[1,1]}|dictsort(by='value')",
    "{'a':(2,1),'b':(1,2),'c':(1,1)}|dictsort(by='value',reverse=true)",
    "{'É':1,'é':2,'A':3,'a':4}|dictsort",
    "{'É':1,'é':2,'A':3,'a':4}|dictsort(reverse=true)",
    "{'ΟΣ':1,'ος':2,'Οσ':3,'İ':4,'i\\u0307':5}|dictsort",
    "{'ﬃ':1,'ffi':2,'ß':3,'SS':4}|dictsort",
    "{'items':3,'__dxt_context_object':'ordinary','__dxt_noniterable':true}|dictsort",
    "{'a':[],'b':{'nested':1}}|dictsort",
    "{'b':2,'a':1}|dictsort(case_sensitive=none,reverse=none)",
    "{'b':2,'a':1}|dictsort(case_sensitive='yes',reverse=1.0)",
    "{'b':2,'a':1}|dictsort(case_sensitive=[],reverse={})",
    "{'b':2,'a':1}|dictsort(case_sensitive={},reverse='yes')",
    "{'b':2,'a':1}|dictsort(**{'by':'key','case_sensitive':true,'reverse':false})",
    "[{'b':2,'a':1},{'d':4,'c':3}]|map('dictsort')|list",
    "modules.pytz.country_names|dictsort|first",
    "{fromyaml('2020-01-02'):'second',fromyaml('2020-01-01'):'first'}|dictsort",
    "{fromyaml('!!binary Qg=='):'second',fromyaml('!!binary QQ=='):'first'}|dictsort",
]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('expression', POSITIVE)
def test_dictsort_preserves_standard_arguments_and_typed_items(tmp_path, configuration_oracle, request, adapter, expression):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', "select '{{ " + expression + " }}' as value")
    actual, reference = [manifest['nodes']['model.configuration_fixture.rendered'] for manifest in pair.invoke('compile')]
    assert actual['compiled_code'] == reference['compiled_code']
    assert actual['depends_on'] == reference['depends_on']


NEGATIVE = [
    "{}|dictsort(by='other')",
    "{}|dictsort(by=none)",
    "{}|dictsort(by=false)",
    "{}|dictsort(by=1)",
    "{}|dictsort(false,'key',false,'extra')",
    "{}|dictsort(case_sensitive=false,unknown=true)",
    "{}|dictsort(false,case_sensitive=true)",
    "{}|dictsort(false,'key',by='value')",
    "{'a':1,2:3}|dictsort",
    "{(1,'a'):1,(1,2):2}|dictsort",
    "{'a':none,'b':1}|dictsort(by='value')",
    "{'a':[],'b':()}|dictsort(by='value')",
    "none|dictsort",
    "[]|dictsort",
    "1|dictsort",
    "'abc'|dictsort",
    "this|dictsort",
    "modules.datetime.date(2020,1,1)|dictsort",
    "modules.re.compile('a')|dictsort",
]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('expression', NEGATIVE)
def test_dictsort_rejects_invalid_signatures_ordering_and_closed_objects(tmp_path, configuration_oracle, request, adapter, expression):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', "select '{{ " + expression + " }}' as value")
    pair.invoke('compile', success=False)


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('template', [
    "{% set member=[7] %}{% set data={'b':member,'a':member} %}{% set result=data|dictsort %}select '{{ result is sequence }}:{{ result[0] is sequence }}:{{ result[0]!=['a',member] }}:{{ result[0][1] is sameas member }}:{% do member.append(8) %}{{ result }}:{{ data|length }}' as value",
    "{% set data={'b':2,'a':1} %}{% set result=data|dictsort %}{% do data.update({'c':3,'a':9}) %}select '{{ result }}:{{ data|dictsort }}' as value",
    "select '{% for key,value in {'b':2,'a':1}|dictsort %}{{ loop.index }}:{{ key }}={{ value }};{% endfor %}' as value",
    "{% set data={'a':2,'b':var('nan')|float,'c':1,'d':3} %}select '{{ data|dictsort(by='value') }}:{{ data|dictsort(by='value',reverse=true) }}' as value",
    "{% set values=zip([1,2],[3,4]) %}select '{% for item in values %}{{ {}|dictsort(case_sensitive=loop) }}{% break %}{% endfor %}:{{ values|list }}' as value",
    "{% set values=zip([1,2],[3,4]) %}select '{% for item in values %}{{ {}|dictsort(reverse=loop) }}{% break %}{% endfor %}:{{ values|list }}' as value",
])
def test_dictsort_item_identity_snapshots_unpacking_and_unordered_floats(tmp_path, configuration_oracle, request, adapter, template):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.append_project("vars: {nan: nan}\n")
    pair.write('models/marts/rendered.sql', template)
    actual, reference = [manifest['nodes']['model.configuration_fixture.rendered'] for manifest in pair.invoke('compile')]
    assert actual['compiled_code'] == reference['compiled_code']
    assert actual['depends_on'] == reference['depends_on']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_dictsort_handles_genuine_finite_decimal_and_mixed_numeric_keys(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', "{% if execute %}{% set table=run_query('select cast(1.25 as decimal(10,2)) as amount') %}{% set number=table.rows[0][0] %}select '{{ {number:'decimal',true:'bool',2.0:'float'}|dictsort }}:{{ {'decimal':number,'bool':true,'float':2.0}|dictsort(by='value') }}' as value{% else %}select 0{% endif %}")
    actual, reference = [manifest['nodes']['model.configuration_fixture.rendered'] for manifest in pair.invoke('compile')]
    assert actual['compiled_code'] == reference['compiled_code']
    assert actual['depends_on'] == reference['depends_on']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_dictsort_propagates_genuine_decimal_nan_comparison_error(tmp_path, configuration_oracle, request, adapter):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', "{% if execute %}{% set table=run_query(\"select cast('NaN' as double precision) as value\") %}select '{{ {'nan':table.rows[0][0],'finite':1}|dictsort(by='value') }}' as value{% else %}select 0{% endif %}")
    pair.invoke('compile', success=False)


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('size', [64, 65, 127, 128, 257])
@pytest.mark.parametrize('reverse', [False, True])
def test_dictsort_large_scattered_nan_order_matches_core(tmp_path, configuration_oracle, request, adapter, size, reverse):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    values = {str(index): 'nan' if index % 13 in (1, 6) else (index * 37) % size for index in range(size)}
    pair.append_project('vars: ' + json.dumps({'sorting_values': values}) + '\n')
    pair.write('models/marts/rendered.sql', "{% set data={} %}{% for key,value in var('sorting_values').items() %}{% do data.update({key:value|float}) %}{% endfor %}select '{{ data|dictsort(by='value',reverse=" + ('true' if reverse else 'false') + ")|map(attribute=0)|list }}' as value")
    actual, reference = [manifest['nodes']['model.configuration_fixture.rendered'] for manifest in pair.invoke('compile')]
    assert actual['compiled_code'] == reference['compiled_code']
    assert actual['depends_on'] == reference['depends_on']

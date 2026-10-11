"""Standard sort ordering through native dxt and pinned Core on both adapters."""
import json

import pytest

from test_cli import build_dxt  # noqa: F401
from test_usability_configuration import configuration_oracle, configuration_postgres  # noqa: F401
from test_usability_resource_hooks import setup_pair
from validate_dbt_artifacts import assert_artifact, read_artifact


def assert_compiled(pair):
    manifests = pair.invoke('compile')
    results = []
    for project in pair.projects:
        for filename in ['manifest.json', 'run_results.json']:
            assert_artifact(project / 'target' / filename)
        artifact = read_artifact(project / 'target/run_results.json')
        results.append({row['unique_id']: {key: row.get(key) for key in
                        ['status', 'failures', 'compiled', 'compiled_code']}
                        for row in artifact['results']})
    assert results[0] == results[1]
    actual, reference = [manifest['nodes']['model.configuration_fixture.rendered'] for manifest in manifests]
    assert actual['compiled'] is reference['compiled'] is True
    assert actual['raw_code'] == reference['raw_code']
    assert actual['compiled_code'] == reference['compiled_code']
    assert actual['depends_on'] == reference['depends_on']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('reverse', [False, True])
def test_sort_short_unordered_float_run_matches_core(tmp_path, configuration_oracle, request, adapter, reverse):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.append_project('vars: {nan: nan}\n')
    pair.write('models/marts/rendered.sql', "select '{{ [2,var('nan')|float,1,3]|sort(reverse="
               + ('true' if reverse else 'false') + ") }}' as value")
    assert_compiled(pair)


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('size', [64, 65, 127, 128, 257])
@pytest.mark.parametrize('reverse', [False, True])
def test_sort_large_scattered_nan_preserves_original_payload_order(tmp_path, configuration_oracle, request, adapter, size, reverse):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    values = [[str(index), 'nan' if index % 13 in (1, 6) else (index * 37) % size] for index in range(size)]
    pair.append_project('vars: ' + json.dumps({'sorting_values': values}) + '\n')
    pair.write('models/marts/rendered.sql', "{% set data=[] %}{% for key,value in var('sorting_values') %}"
               "{% do data.append((key,value|float)) %}{% endfor %}select '{{ data|sort(attribute=1,reverse="
               + ('true' if reverse else 'false') + ")|map(attribute=0)|list }}' as value")
    assert_compiled(pair)


REPRESENTATIVE = [
    pytest.param("select '{{ []|sort }}' as value", id='empty'),
    pytest.param("select '{{ [2.5,-1,true,false,3,1.0]|sort }}' as value", id='mixed-finite-numbers'),
    pytest.param("select '{{ [2.5,-1,true,false,3,1.0]|sort(reverse=true) }}' as value", id='reverse-finite-ties'),
    pytest.param("select '{{ ['É','é','A','a','ΟΣ','ος','Οσ','İ','i\\u0307']|sort }}' as value", id='unicode-lower-stable-ties'),
    pytest.param("select '{{ ['é','É','a','A']|sort(case_sensitive=true,reverse=true) }}' as value", id='unicode-case-sensitive-reverse'),
    pytest.param("select '{{ [('first',2),('second',1),('third',2)]|sort(attribute=1,reverse=true) }}' as value", id='index-attribute-reverse-ties'),
    pytest.param("select '{{ [{'name':'second','key':{'rank':2}},{'name':'first','key':{'rank':1}}]|sort(attribute='key.rank')|map(attribute='name')|list }}' as value", id='nested-attribute'),
    pytest.param("select '{{ [{'name':'first','rank':2,'label':'b'},{'name':'second','rank':1,'label':'Z'},{'name':'third','rank':1,'label':'a'},{'name':'fourth','rank':1,'label':'A'}]|sort(attribute='rank,label')|map(attribute='name')|list }}' as value", id='multiattribute-stable-ties'),
    pytest.param("{% set member=[7] %}{% set first=(2,member) %}{% set second=(1,member) %}"
                 "{% set values=[first,second] %}{% set result=values|sort(attribute=0) %}"
                 "select '{{ result }}:{{ result[0] is sameas second }}:{{ result[1] is sameas first }}:"
                 "{{ result[0][1] is sameas member }}:{% do member.append(8) %}{{ result }}:{{ values }}' as value",
                 id='typed-payload-identity'),
    pytest.param("{% set values=[3,1,2] %}{% set result=values|sort %}{% do values.append(0) %}"
                 "select '{{ result }}:{{ values }}:{{ result is sameas values }}' as value", id='input-snapshot'),
]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('template', REPRESENTATIVE)
def test_sort_retains_finite_unicode_attribute_and_payload_contracts(tmp_path, configuration_oracle, request, adapter, template):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', template)
    assert_compiled(pair)


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('template', [
    pytest.param("select '{{ [1,'two']|sort }}' as value", id='incomparable-int-string'),
    pytest.param("{% if execute %}{% set table=run_query(\"select cast('NaN' as double precision) as value\") %}"
                 "select '{{ [table.rows[0][0],1]|sort }}' as value{% else %}select 0{% endif %}", id='genuine-decimal-nan'),
])
def test_sort_retains_genuine_comparison_errors(tmp_path, configuration_oracle, request, adapter, template):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', template)
    pair.invoke('compile', success=False)

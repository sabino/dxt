"""Real seed COPY and native parameter execution against pinned Core adapters."""
import json
import re
from decimal import Decimal

import pytest
from test_cli import build_dxt  # noqa: F401
from test_usability_configuration import configuration_oracle, configuration_postgres  # noqa: F401
from test_usability_resource_hooks import setup_pair, rows
from test_usability_stock_artifacts import resource, runtime_sql
from validate_dbt_artifacts import assert_artifact, read_artifact


def canonical(project, sql):
    import yaml
    profile=yaml.safe_load((project/'profiles.yml').read_text())['configuration_fixture']['outputs']['dev']
    return re.sub(r'\s+','',sql.replace(str(project),'PROJECT').replace(profile['schema'],'SCHEMA')).rstrip(';')


def assert_seed_artifacts(pair):
    manifests=[]
    outcomes=[]
    for project in pair.projects:
        for name in ('manifest.json','run_results.json'):
            assert_artifact(project/'target'/name)
        node=resource(project,'input','seed')
        manifests.append({key:node.get(key,'ABSENT') for key in ('raw_code','compiled','compiled_code','compiled_path','build_path','checksum')})
        result=read_artifact(project/'target/run_results.json')['results'][0]
        outcomes.append({key:result.get(key,'ABSENT') for key in ('unique_id','status','message','adapter_response','compiled','compiled_code','relation_name')})
    assert manifests[0]==manifests[1]
    assert outcomes[0]==outcomes[1]


@pytest.mark.parametrize('mode',['duckdb_fast','duckdb_slow','postgres'])
@pytest.mark.parametrize('scenario',['typed','quoted','delimiter','nulls'])
def test_actual_seed_copy_or_bindings_main_matches_core_first_repeat_refresh(tmp_path, configuration_oracle, request, mode, scenario):
    adapter='duckdb' if mode.startswith('duckdb') else 'postgres'
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    delimiter='|' if scenario=='delimiter' else ','
    header='Order ID' if scenario=='quoted' else 'id'
    csv=f'{header}{delimiter}label{delimiter}amount\n1{delimiter}"A, B"{delimiter}10.50\n2{delimiter}"O\'Brien"{delimiter}20.25\n'
    if scenario=='nulls': csv=f'{header}{delimiter}label{delimiter}amount\n1{delimiter}{delimiter}10.50\n2{delimiter}two{delimiter}\n'
    pair.write('seeds/input.csv',csv)
    pair.append_project('seeds:\n  configuration_fixture:\n    input:\n      +fast: '+('false' if mode=='duckdb_slow' else 'true')+'\n      +delimiter: '+json.dumps(delimiter)+'\n      +column_types: '+json.dumps({header:'integer','amount':'decimal(10,2)'})+'\n')
    for flags in [[],[],['--full-refresh']]:
        pair.invoke('seed',flags)
        assert_seed_artifacts(pair)
        payloads=[runtime_sql(project,resource(project,'input','seed')) for project in pair.projects]
        assert canonical(pair.projects[0],payloads[0])==canonical(pair.projects[1],payloads[1])
        if mode=='duckdb_fast': assert 'COPY ' in payloads[0] and str(pair.projects[0]/'seeds/input.csv') in payloads[0]
        else: assert ('?' if adapter=='duckdb' else '%s') in payloads[0] and "O'Brien" not in payloads[0]
        expected=[(1,None,Decimal('10.50')),(2,'two',None)] if scenario=='nulls' else [(1,'A, B',Decimal('10.50')),(2,"O'Brien",Decimal('20.25'))]
        assert rows(pair,request,adapter,'select "'+header+'",label,amount from {schema}.input order by "'+header+'"')==[expected]*2


@pytest.mark.parametrize('mode',['duckdb_fast','duckdb_slow','postgres'])
def test_seed_load_error_retains_previous_rows_without_publishing_main(tmp_path,configuration_oracle,request,mode):
    adapter='duckdb' if mode.startswith('duckdb') else 'postgres'
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    pair.append_project('seeds:\n  configuration_fixture:\n    input:\n      +fast: '+('false' if mode=='duckdb_slow' else 'true')+'\n      +column_types: {id: integer}\n')
    pair.write('seeds/input.csv','id\n1\n')
    pair.invoke('seed')
    for project in pair.projects: (project/resource(project,'input','seed')['build_path']).unlink()
    pair.write('seeds/input.csv','id\ninvalid_integer\n')
    pair.invoke('seed',success=False)
    for project in pair.projects:
        assert_artifact(project/'target/manifest.json')
        assert_artifact(project/'target/run_results.json')
    for project in pair.projects:
        assert resource(project,'input','seed')['build_path'] is None
        assert not (project/'target/run/configuration_fixture/seeds/input.csv').exists()
    assert rows(pair,request,adapter,'select id from {schema}.input')==[[(1,)]]*2


@pytest.mark.parametrize('adapter',['duckdb','postgres'])
@pytest.mark.parametrize('case',['text','null','numeric','date','timestamp','cursor'])
def test_adapter_add_query_real_bindings_and_cursor_consumption(tmp_path,configuration_oracle,request,adapter,case):
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    marker='?' if adapter=='duckdb' else '%s'
    expressions={'text':"\"O'Brien λ\"",'null':'none','numeric':'9007199254740993','date':'modules.datetime.date(2024,2,29)','timestamp':'modules.datetime.datetime(2024,2,29,12,34,56,123456)','cursor':'7'}
    sql='select '+marker+' as result'
    if case=='cursor': sql='select '+marker+' as result union all select 8 union all select 9 order by result'
    expression=expressions[case]
    body="{% if execute %}{% set queried = adapter.add_query("+json.dumps(sql)+", auto_begin=false, bindings=["+expression+"]) %}{% set cursor=queried[1] %}"
    if case=='cursor': body+="{% set first=cursor.fetchone() %}{% set next=cursor.fetchmany(1) %}{% set last=cursor.fetchall() %}select {{ first[0] }} as first,{{ next[0][0] }} as next,{{ last[0][0] }} as last,{{ 1 if cursor.fetchone() is none else 0 }} as exhausted"
    else: body+="{% set value=cursor.fetchall()[0][0] %}select '{{ (value|string)|replace(\"'\",\"''\") }}' as result"
    body+='{% else %}select 1{% endif %}'
    pair.write('models/marts/rendered.sql',body)
    actual,expected=[manifest['nodes']['model.configuration_fixture.rendered'] for manifest in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('mode',['duckdb_slow','postgres'])
def test_seed_helpers_honor_real_batch_override_and_preserve_first_template(tmp_path,configuration_oracle,request,mode):
    adapter='duckdb' if mode.startswith('duckdb') else 'postgres'
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    pair.write('macros/batch.sql','{% macro get_batch_size() %}{{ return(2) }}{% endmacro %}')
    pair.append_project('seeds:\n  configuration_fixture:\n    input:\n      +fast: false\n')
    pair.write('seeds/input.csv','id,label\n1,one\n2,two\n3,three\n4,four\n5,five\n')
    pair.invoke('seed')
    assert_seed_artifacts(pair)
    payloads=[runtime_sql(project,resource(project,'input','seed')) for project in pair.projects]
    assert canonical(pair.projects[0],payloads[0])==canonical(pair.projects[1],payloads[1])
    assert all(sql.count('?' if adapter=='duckdb' else '%s')==4 for sql in payloads)
    assert rows(pair,request,adapter,'select id,label from {schema}.input order by id')==[[(1,'one'),(2,'two'),(3,'three'),(4,'four'),(5,'five')]]*2


@pytest.mark.parametrize('mode',['duckdb_fast','duckdb_slow','postgres'])
@pytest.mark.parametrize('timestamp_mode',['space','iso','fraction_space','mixed'])
def test_nullable_temporal_seed_data_and_exact_type_inference(tmp_path,configuration_oracle,request,mode,timestamp_mode):
    import datetime
    adapter='duckdb' if mode.startswith('duckdb') else 'postgres'
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    pair.append_project('seeds:\n  configuration_fixture:\n    input:\n      +fast: '+('false' if mode=='duckdb_slow' else 'true')+'\n')
    stamp={'space':'2024-02-29 12:34:56','iso':'2024-02-29T12:34:56.123456','fraction_space':'2024-02-29 12:34:56.123456','mixed':'2024-02-29 12:34:56'}[timestamp_mode]
    second='2024-02-29T12:34:56' if timestamp_mode=='mixed' else ''
    pair.write('seeds/input.csv',f'id,flag,day,stamp,amount\n1,true,2024-02-29,{stamp},10.50\n2,false,,{second},\n')
    pair.invoke('seed')
    assert_seed_artifacts(pair)
    payloads=[runtime_sql(project,resource(project,'input','seed')) for project in pair.projects]
    assert canonical(pair.projects[0],payloads[0])==canonical(pair.projects[1],payloads[1])
    first=stamp if timestamp_mode in ['fraction_space','mixed'] else datetime.datetime(2024,2,29,12,34,56,123456 if timestamp_mode=='iso' else 0)
    expected=[(1,True,datetime.date(2024,2,29),first,10.5),(2,False,None,second or None,None)]
    assert rows(pair,request,adapter,'select * from {schema}.input order by id')==[expected]*2


def test_postgres_seed_default_batch_exceeds_extended_protocol_limit_safely(tmp_path,configuration_oracle,request):
    pair=setup_pair(tmp_path,configuration_oracle,request,'postgres')
    pair.write('seeds/input.csv','a,b,c,d,e,f,g\n'+''.join(','.join([str(i)]*7)+'\n' for i in range(10000)))
    pair.invoke('seed')
    assert_seed_artifacts(pair)
    payloads=[runtime_sql(project,resource(project,'input','seed')) for project in pair.projects]
    assert canonical(pair.projects[0],payloads[0])==canonical(pair.projects[1],payloads[1])
    assert all(sql.count('%s')==70000 for sql in payloads)
    assert rows(pair,request,'postgres','select count(*),sum(a),sum(g) from {schema}.input')==[[(10000,49995000,49995000)]]*2


@pytest.mark.parametrize('adapter',['duckdb','postgres'])
@pytest.mark.parametrize('scenario',['missing','extra','invalid_value'])
def test_query_bindings_fail_with_real_core_arity_or_type_errors(tmp_path,configuration_oracle,request,adapter,scenario):
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    marker='?' if adapter=='duckdb' else '%s'
    bindings={'missing':'[]','extra':'[1,2]','invalid_value':'[flags]'}[scenario]
    pair.write('models/marts/rendered.sql',"{% if execute %}{% do adapter.add_query('select "+marker+"',bindings="+bindings+") %}{% endif %}select 1")
    pair.invoke('compile',success=False)


@pytest.mark.parametrize('sql,bindings',[('select %s; select %s','[1,2]'),("select '%s'",'[42]'),("select %s as value, '100%%' as label",'[7]')])
def test_postgres_native_client_adaptation_handles_psycopg2_template_boundaries(tmp_path,configuration_oracle,request,sql,bindings):
    pair=setup_pair(tmp_path,configuration_oracle,request,'postgres')
    pair.write('models/marts/rendered.sql',"{% if execute %}{% set r=adapter.add_query("+json.dumps(sql)+",bindings="+bindings+",auto_begin=false) %}{% set row=r[1].fetchone() %}select '{{ row[0] }}' as value{% else %}select 1{% endif %}")
    actual,expected=[manifest['nodes']['model.configuration_fixture.rendered'] for manifest in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']


@pytest.mark.parametrize('adapter',['duckdb','postgres'])
def test_seed_load_context_uses_real_project_path_rows_and_overrides(tmp_path,configuration_oracle,request,adapter):
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    pair.write('seeds/input.csv','code,amount\n001,10.25\n')
    pair.append_project('seeds:\n  configuration_fixture:\n    input:\n      +column_types: {code: text}\n')
    pair.write('macros/load.sql',"""{% macro load_csv_rows(model,agate_table) %}
{% if agate_table.original_abspath != model.root_path ~ '/' ~ model.original_file_path %}{{ exceptions.raise_compiler_error('seed path') }}{% endif %}
{% if agate_table.column_names != ('code','amount') or agate_table.rows[0]['code'] != '001' or agate_table.rows.values()[0]['code'] != '001' or agate_table.rows.keys() is not none %}{{ exceptions.raise_compiler_error('seed data') }}{% endif %}
{{ return(adapter.dispatch('load_csv_rows','dbt')(model,agate_table)) }}
{% endmacro %}""")
    pair.invoke('seed')
    assert rows(pair,request,adapter,'select code,amount from {schema}.input')==[[('001',10.25)]]*2



@pytest.mark.parametrize('adapter',['duckdb','postgres'])
def test_seed_decimal_binding_preserves_more_than_float_precision(tmp_path,configuration_oracle,request,adapter):
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    pair.append_project('seeds:\n  configuration_fixture:\n    input:\n      +fast: false\n')
    pair.write('seeds/input.csv','amount\n0.123456789012345678901\n')
    pair.write('macros/create.sql',"""{% macro create_csv_table(model,agate_table) %}
{% set sql %}create table {{ this }} (amount decimal(38,21)){% endset %}
{% do adapter.add_query(sql) %}
{{ return(sql) }}
{% endmacro %}""")
    pair.invoke('seed')
    assert rows(pair,request,adapter,'select amount from {schema}.input')==[[(Decimal('0.123456789012345678901'),)]]*2
    payloads=[runtime_sql(project,resource(project,'input','seed')) for project in pair.projects]
    assert canonical(pair.projects[0],payloads[0])==canonical(pair.projects[1],payloads[1])


@pytest.mark.parametrize('adapter',['duckdb','postgres'])
def test_query_cursor_follows_adapter_connection_alias_policy(tmp_path,configuration_oracle,request,adapter):
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    pair.write('models/marts/rendered.sql',"""{% if execute %}
{% set first=adapter.add_query('select 1 as value',auto_begin=false)[1] %}
{% set second=adapter.add_query('select 2 as value',auto_begin=false)[1] %}
select {{ first.fetchone()[0] }} as first, {{ 1 if second.fetchone() is none else 0 }} as second_empty
{% else %}select 1{% endif %}""")
    actual,expected=[manifest['nodes']['model.configuration_fixture.rendered'] for manifest in pair.invoke('compile')]
    assert actual['compiled_code']==expected['compiled_code']
    assert ('select 2 as first, 1 as second_empty' if adapter=='duckdb' else 'select 1 as first, 0 as second_empty') in actual['compiled_code']


@pytest.mark.parametrize('adapter',['duckdb','postgres'])
@pytest.mark.parametrize('arguments',["'select 1',sql='select 2'","sql='select 1',unknown=true"])
def test_add_query_rejects_duplicate_or_unknown_arguments(tmp_path,configuration_oracle,request,adapter,arguments):
    pair=setup_pair(tmp_path,configuration_oracle,request,adapter)
    pair.write('models/marts/rendered.sql',"{% if execute %}{% do adapter.add_query("+arguments+") %}{% endif %}select 1")
    pair.invoke('compile',success=False)

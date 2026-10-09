"""Native unit fixtures agree with pinned Core and never replace target data."""
from __future__ import annotations

import ctypes.util
import json
import os
import shutil
import subprocess
from importlib.metadata import version
from pathlib import Path

import pytest
from test_usability_adapters import postgres_fixture

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / 'zig-out' / 'bin' / 'dxt'

@pytest.fixture(scope='module', autouse=True)
def binary():
    result=subprocess.run(['zig','build'],cwd=ROOT,capture_output=True,text=True)
    assert result.returncode==0,result.stderr

@pytest.fixture(autouse=True)
def native(monkeypatch):
    library=os.environ.get('DXT_DUCKDB_LIBRARY') or ctypes.util.find_library('duckdb')
    if not library:
        if os.environ.get('DXT_NATIVE_ADAPTER_CERTIFY')=='1': pytest.fail('Certification requires libduckdb')
        pytest.skip('Native unit fixture requires libduckdb')
    monkeypatch.setenv('DXT_DUCKDB_LIBRARY',library)
    monkeypatch.setenv('DXT_DUCKDB_BACKEND','native')
    monkeypatch.setenv('DBT_SEND_ANONYMOUS_USAGE_STATS','false')


def project_at(project,adapter,request,properties,models=None):
    (project/'models').mkdir(parents=True)
    (project/'tests'/'fixtures').mkdir(parents=True)
    (project/'dbt_project.yml').write_text("name: unit_demo\nversion: '1.0'\nprofile: unit_demo\n")
    schema='main' if adapter=='duckdb' else 'unit_'+project.name.replace('-','_')
    if adapter=='duckdb':
        profile=f"type: duckdb\n      path: '{project/'warehouse.duckdb'}'\n      schema: main"
    else:
        server=request.getfixturevalue('postgres_fixture')[0]
        info=server.get_postmaster_info()
        profile=f"type: postgres\n      host: '{info.socket_dir}'\n      port: {info.port}\n      user: postgres\n      dbname: postgres\n      schema: {schema}"
    (project/'profiles.yml').write_text(f"unit_demo:\n  target: dev\n  outputs:\n    dev:\n      {profile}\n      threads: 2\n")
    models=models or {'base':"{{ config(materialized='table') }}select cast(100 as integer) as id, cast('real' as varchar(24)) as note",'final':"select * from {{ ref('base') }}"}
    for name,sql in models.items(): (project/'models'/f'{name}.sql').write_text(sql)
    (project/'models'/'schema.yml').write_text(properties)
    return schema


def invoke(project,command,*args, executable=DXT):
    return subprocess.run([str(executable),command,'--project-dir',str(project),'--profiles-dir',str(project),'--target-path',str(project/('target' if executable==DXT else 'core-target')),'--no-use-colors',*args],cwd=ROOT,capture_output=True,text=True,timeout=45)


def rows(project,core=False):
    return json.loads((project/('core-target' if core else 'target')/'run_results.json').read_text())['results']


def query(project,adapter,schema,sql,request):
    if adapter=='duckdb':
        result=subprocess.run(['duckdb',str(project/'warehouse.duckdb'),'-json','-c',sql],capture_output=True,text=True)
        assert result.returncode==0,result.stderr
        return json.loads(result.stdout or '[]')
    import psycopg2
    server=request.getfixturevalue('postgres_fixture')[0]
    with psycopg2.connect(server.get_uri()) as connection:
        with connection.cursor() as cursor:
            cursor.execute(sql)
            return str(cursor.fetchone()[0])


def materialize_inputs(project, adapter, schema, request, *, versions=False):
    if adapter=='duckdb':
        result=invoke(project,'run','--select','base')
        assert result.returncode==0,result.stdout+result.stderr
        return
    # Real PostgreSQL fixture metadata. The unit executor must consume the
    # native session and these actual types while leaving target data intact.
    import psycopg2
    server=request.getfixturevalue('postgres_fixture')[0]
    with psycopg2.connect(server.get_uri()) as connection:
        with connection.cursor() as cursor:
            cursor.execute(f'create schema if not exists "{schema}"')
            names=['base_v1','base_v2'] if versions else ['base']
            for name in names:
                cursor.execute(f"create table \"{schema}\".\"{name}\" as select cast(100 as integer) as id, cast('real' as varchar(24)) as note")



CONTRACT='''version: 2
unit_tests:
  - name: file_csv
    model: final
    given: [{input: "ref('base')", format: csv, fixture: inputs}]
    expect: {rows: [{id: 2, note: null}]}
  - name: inline_csv
    model: final
    given:
      - input: ref('base')
        format: csv
        rows: |
          id,note
          3,"hello, unit"
    expect: {rows: [{id: 3, note: 'hello, unit'}]}
  - name: file_sql
    model: final
    given: [{input: "ref('base')", format: sql, fixture: sql_input}]
    expect: {rows: [{id: 4}]}
  - name: inline_sql
    model: final
    given:
      - input: ref('base')
        format: sql
        rows: |
          select 5 as id, 'inline' as note
    expect:
      format: sql
      rows: |
        select 'inline' as note, 5 as id
  - name: sparse
    model: final
    given: [{input: "ref('base')", rows: [{id: 2}, {note: only}]}]
    expect: {rows: [{id: 2}, {id: null}]}
  - name: empty
    model: final
    given: [{input: "ref('base')", rows: []}]
    expect: {rows: []}
  - name: case_insensitive
    model: final
    given: [{input: "ref('base')", rows: [{ID: 6, NOTE: upper}]}]
    expect: {rows: [{ID: 6}]}
'''

@pytest.mark.parametrize('adapter',['duckdb','postgres'])
def test_csv_sql_sparse_empty_and_partial_assertions_on_actual_adapter(tmp_path,request,adapter):
    project=tmp_path/'fixtures'
    schema=project_at(project,adapter,request,CONTRACT)
    (project/'tests'/'fixtures'/'inputs.csv').write_text('id,note\n2,\n')
    (project/'tests'/'fixtures'/'sql_input.sql').write_text("select 4 as id, 'sql' as note")
    materialize_inputs(project,adapter,schema,request)
    result=invoke(project,'test','--select','test_type:unit')
    assert result.returncode==0,result.stdout+result.stderr
    assert len(rows(project))==7
    assert all(r['status']=='pass' and r['failures']==0 for r in rows(project))
    manifest=json.loads((project/'target'/'manifest.json').read_text())
    definitions=manifest['unit_tests']
    csv=definitions['unit_test.unit_demo.final.file_csv']['given'][0]
    assert csv['format']=='csv' and csv['fixture']=='inputs' and csv['rows']==[{'id':'2','note':None}]
    assert definitions['unit_test.unit_demo.final.file_sql']['given'][0]['rows']=="select 4 as id, 'sql' as note"
    assert not any('sql_input' in n for n in manifest['nodes'])
    sql=f'select id from "{schema}"."base"'
    assert query(project,adapter,schema,sql,request)==([{'id':100}] if adapter=='duckdb' else '100')
    assert '__dxt_unit_input_0' not in (project/'target'/'catalog.json').read_text() if (project/'target'/'catalog.json').exists() else True

@pytest.mark.parametrize('adapter',['duckdb','postgres'])
def test_typed_macro_var_env_and_incremental_this_overrides(tmp_path,request,adapter):
    project=tmp_path/'overrides'
    properties='''version: 2
unit_tests:
  - name: typed
    model: final
    overrides:
      macros: {marker: 7, is_incremental: true}
      vars: {scale: 11}
      env_vars: {UNIT_VALUE: overridden}
    given:
      - {input: "ref('base')", rows: [{id: 2, note: fixture}]}
      - {input: this, rows: [{id: 4}]}
    expect: {rows: [{id: 6, marker: 7, scale: 11, value: overridden}]}
'''
    models={'base':"{{ config(materialized='table') }}select 100 as id, 'real' as note",'final':"{{ config(materialized='incremental') }}select id{% if is_incremental() %}+(select max(id) from {{ this }}){% endif %} as id, {{ marker() }} as marker, {{ var('scale',1) }} as scale, '{{ env_var('UNIT_VALUE','original') }}' as value from {{ ref('base') }}"}
    schema=project_at(project,adapter,request,properties,models)
    (project/'macros').mkdir()
    (project/'macros'/'marker.sql').write_text('{% macro marker() %}{{ return(0) }}{% endmacro %}')
    materialize_inputs(project,adapter,schema,request)
    result=invoke(project,'test','--select','test_type:unit')
    assert result.returncode==0,result.stdout+result.stderr
    assert rows(project)[0]['status']=='pass'
    definition=json.loads((project/'target'/'manifest.json').read_text())['unit_tests']['unit_test.unit_demo.final.typed']
    assert definition['overrides']['macros']['marker']==7 and definition['overrides']['vars']['scale']==11

@pytest.mark.parametrize('adapter',['duckdb','postgres'])
def test_unit_versions_and_versioned_input_refs(tmp_path,request,adapter):
    project=tmp_path/'versions'
    props='''version: 2
models:
  - name: base
    versions: [{v: 1}, {v: 2}]
  - name: final
    versions: [{v: 1}, {v: 2}]
unit_tests:
  - name: every_version
    model: final
    given: [{input: "ref('base', v=1)", rows: [{id: 8}]}]
    expect: {rows: [{id: 8}]}
  - name: included
    model: final
    versions: {include: [2]}
    given: [{input: "ref('base', version=1)", rows: [{id: 9}]}]
    expect: {rows: [{id: 9}]}
'''
    models={'base_v1':'select 1 as id','base_v2':'select 2 as id','final_v1':"select * from {{ ref('base',v=1) }}",'final_v2':"select * from {{ ref('base',v=1) }}"}
    schema=project_at(project,adapter,request,props,models)
    materialize_inputs(project,adapter,schema,request,versions=True)
    result=invoke(project,'test','--select','test_type:unit')
    assert result.returncode==0,result.stdout+result.stderr
    assert {r['unique_id']:r['status'] for r in rows(project)}=={'unit_test.unit_demo.final.every_version_v1':'pass','unit_test.unit_demo.final.every_version_v2':'pass','unit_test.unit_demo.final.included_v2':'pass'}

@pytest.mark.parametrize('kind',['missing','duplicate','unknown_input','unknown_expected','multistatement'])
def test_invalid_fixtures_fail_durably_and_preserve_real_target(tmp_path,request,kind):
    project=tmp_path/'invalid'
    given="{input: \"ref('base')\", rows: [{id: 2}]}"
    expect='{rows: [{id: 2}]}'
    if kind in ['missing','duplicate']:given="{input: \"ref('base')\", format: csv, fixture: inputs}"
    if kind=='unknown_input':given="{input: \"ref('base')\", rows: [{absent: 2}]}"
    if kind=='unknown_expected':expect='{rows: [{absent: 2}]}'
    if kind=='multistatement':given="{input: \"ref('base')\", format: sql, rows: 'select 2 as id; drop table base;'}"
    props=f'version: 2\nunit_tests:\n  - name: invalid\n    model: final\n    given: [{given}]\n    expect: {expect}\n'
    # Materialize the real input before authoring an invalid definition.
    project_at(project,'duckdb',request,'version: 2\n')
    assert invoke(project,'run','--select','base').returncode==0
    (project/'models'/'schema.yml').write_text(props)
    if kind=='duplicate':
        (project/'tests'/'fixtures'/'inputs.csv').write_text('id\n2\n')
        (project/'tests'/'fixtures'/'inputs.sql').write_text('select 2 as id')
    result=invoke(project,'test','--select','test_type:unit')
    assert result.returncode==(2 if kind in ['missing','duplicate'] else 1),result.stdout+result.stderr
    if kind not in ['missing','duplicate']:assert rows(project)[0]['status']=='error' and rows(project)[0]['compiled_code'] is None
    assert query(project,'duckdb','main','select id from base',request)==[{'id':100}]


def test_pinned_core_fixture_and_override_contract(tmp_path,request):
    if not shutil.which('dbt') or version('dbt-core')!='1.10.5' or version('dbt-duckdb')!='1.9.6':
        if os.environ.get('DXT_NATIVE_ADAPTER_CERTIFY')=='1':pytest.fail('Certification requires pinned Core and DuckDB adapter')
        pytest.skip('Pinned Core fixture requires dbt-core 1.10.5 and dbt-duckdb 1.9.6')
    project=tmp_path/'oracle'
    project_at(project,'duckdb',request,CONTRACT)
    (project/'tests'/'fixtures'/'inputs.csv').write_text('id,note\n2,\n')
    (project/'tests'/'fixtures'/'sql_input.sql').write_text("select 4 as id, 'sql' as note")
    core=shutil.which('dbt')
    assert invoke(project,'run','--select','base',executable=core).returncode==0
    expected=invoke(project,'test','--select','test_type:unit',executable=core)
    assert expected.returncode==0,expected.stdout+expected.stderr
    actual=invoke(project,'test','--select','test_type:unit')
    assert actual.returncode==0,actual.stdout+actual.stderr
    assert {r['unique_id']:(r['status'],r['failures']) for r in rows(project)}=={r['unique_id']:(r['status'],r['failures']) for r in rows(project,True)}
    actual_defs=json.loads((project/'target'/'manifest.json').read_text())['unit_tests']
    expected_defs=json.loads((project/'core-target'/'manifest.json').read_text())['unit_tests']
    for identifier,definition in actual_defs.items():
        for field in ['given','expect','overrides','versions','version','depends_on']:
            assert definition[field]==expected_defs[identifier][field],(identifier,field)


@pytest.mark.parametrize('case',['typed_overrides','versions'])
def test_pinned_core_typed_overrides_and_model_version_definitions(tmp_path,request,case):
    if not shutil.which('dbt') or version('dbt-core')!='1.10.5' or version('dbt-duckdb')!='1.9.6':
        if os.environ.get('DXT_NATIVE_ADAPTER_CERTIFY')=='1': pytest.fail('Certification requires pinned Core and DuckDB adapter')
        pytest.skip('Pinned Core unit fixture unavailable')
    project=tmp_path/case
    if case=='typed_overrides':
        props="""version: 2
unit_tests:
  - name: typed
    model: final
    overrides:
      macros: {marker: 7, 'unit_demo.marker': 8}
      vars: {scale: 11}
      env_vars: {UNIT_VALUE: overridden}
    given: [{input: "ref('base')", rows: [{id: 2}]}]
    expect: {rows: [{id: 2, marker: 7, qualified: 8, scale: 11, value: overridden}]}
"""
        models={'base':"select 100 as id",'final':"select id, {{ marker() }} as marker, {{ unit_demo.marker() }} as qualified, {{ var('scale',1) }} as scale, '{{ env_var('UNIT_VALUE','original') }}' as value from {{ ref('base') }}"}
    else:
        props="""version: 2
models:
  - name: final
    versions: [{v: 1}, {v: 2}]
unit_tests:
  - name: included
    model: final
    versions: {include: [2]}
    given: [{input: "ref('base')", rows: [{id: 2}]}]
    expect: {rows: [{id: 2}]}
  - name: excluded
    model: final
    versions: {exclude: [2]}
    given: [{input: "ref('base')", rows: [{id: 2}]}]
    expect: {rows: [{id: 2}]}
"""
        models={'base':'select 100 as id','final_v1':"select * from {{ ref('base') }}",'final_v2':"select * from {{ ref('base') }}"}
    project_at(project,'duckdb',request,props,models)
    if case=='typed_overrides':
        (project/'macros').mkdir()
        (project/'macros'/'marker.sql').write_text('{% macro marker() %}{{ return(0) }}{% endmacro %}')
    core=shutil.which('dbt')
    parents=invoke(project,'run','--select','base',executable=core)
    assert parents.returncode==0,parents.stdout+parents.stderr
    expected=invoke(project,'test','--select','test_type:unit',executable=core)
    assert expected.returncode==0,expected.stdout+expected.stderr
    actual=invoke(project,'test','--select','test_type:unit')
    assert actual.returncode==0,actual.stdout+actual.stderr
    assert {r['unique_id']:(r['status'],r['failures']) for r in rows(project)}=={r['unique_id']:(r['status'],r['failures']) for r in rows(project,True)}
    a=json.loads((project/'target'/'manifest.json').read_text())['unit_tests']
    b=json.loads((project/'core-target'/'manifest.json').read_text())['unit_tests']
    for identifier,definition in a.items():
        for field in ['given','expect','overrides','versions','version','depends_on']:
            assert definition[field]==b[identifier][field],(identifier,field)


@pytest.mark.parametrize('adapter',['duckdb','postgres'])
def test_runtime_macro_queries_read_temporary_fixtures_and_collect_typed_logs(tmp_path,request,adapter):
    project=tmp_path/'runtime_query'
    props="""version: 2
unit_tests:
  - name: query_fixture
    model: final
    given: [{input: "ref('base')", rows: [{id: 9}]}]
    expect: {rows: [{id: 9, observed: 9}]}
"""
    sql="{% if execute %}{% set data=run_query('select max(id) from ' ~ ref('base')) %}{% do log('unit fixture observed',info=true) %}{% set observed=data.rows[0][0] %}{% else %}{% set observed=0 %}{% endif %}select id, {{ observed }} as observed from {{ ref('base') }}"
    schema=project_at(project,adapter,request,props,{'base':'select 100 as id','final':sql})
    materialize_inputs(project,adapter,schema,request)
    result=invoke(project,'test','--select','test_type:unit','--log-format','json')
    assert result.returncode==0,result.stdout+result.stderr
    assert rows(project)[0]['status']=='pass'
    events=[json.loads(line) for line in (result.stdout+result.stderr).splitlines() if line.startswith('{')]
    assert any(e['info']['name']=='JinjaLogInfo' and e['data']['msg']=='unit fixture observed' for e in events)
    assert query(project,adapter,schema,f'select id from "{schema}".base',request)==([{'id':100}] if adapter=='duckdb' else '100')


def test_csv_unit_failure_blocks_model_and_descendants_in_mixed_build(tmp_path,request):
    project=tmp_path/'mixed'
    props="""version: 2
unit_tests:
  - name: wrong_csv
    model: final
    given: [{input: "ref('base')", format: csv, rows: 'id\n2\n'}]
    expect: {rows: [{id: 7}]}
"""
    project_at(project,'duckdb',request,props,{'base':'select 100 as id','final':"select * from {{ ref('base') }}",'child':"select * from {{ ref('final') }}",'independent':'select 42 as id'})
    result=invoke(project,'build','--threads','2')
    assert result.returncode==1,result.stdout+result.stderr
    statuses={r['unique_id']:r['status'] for r in rows(project)}
    assert statuses=={'model.unit_demo.base':'success','unit_test.unit_demo.final.wrong_csv':'fail','model.unit_demo.final':'skipped','model.unit_demo.child':'skipped','model.unit_demo.independent':'success'}
    assert '1 test(s) failed' in result.stdout


def test_duckdb_struct_and_array_dict_fixtures_match_pinned_core(tmp_path,request):
    project=tmp_path/'nested'
    props="""version: 2
unit_tests:
  - name: typed_nested
    model: final
    given: [{input: "ref('base')", rows: [{id: 2, tags: [3, 4], payload: {score: 7}}]}]
    expect: {rows: [{id: 2, tags: [3, 4], payload: {score: 7}}]}
"""
    models={'base':'select 100 as id, [100] as tags, struct_pack(score := 100) as payload','final':"select * from {{ ref('base') }}"}
    project_at(project,'duckdb',request,props,models)
    if not shutil.which('dbt') or version('dbt-core')!='1.10.5' or version('dbt-duckdb')!='1.9.6':
        if os.environ.get('DXT_NATIVE_ADAPTER_CERTIFY')=='1': pytest.fail('Certification requires pinned Core and DuckDB adapter')
        pytest.skip('Pinned Core nested fixture unavailable')
    core=shutil.which('dbt')
    assert invoke(project,'run','--select','base',executable=core).returncode==0
    expected=invoke(project,'test','--select','test_type:unit',executable=core)
    assert expected.returncode==0,expected.stdout+expected.stderr
    actual=invoke(project,'test','--select','test_type:unit')
    assert actual.returncode==0,actual.stdout+actual.stderr
    assert rows(project)[0]['status']==rows(project,True)[0]['status']=='pass'
    a=json.loads((project/'target'/'manifest.json').read_text())['unit_tests']
    b=json.loads((project/'core-target'/'manifest.json').read_text())['unit_tests']
    assert a['unit_test.unit_demo.final.typed_nested']['given']==b['unit_test.unit_demo.final.typed_nested']['given']


def test_pinned_core_unit_mismatch_is_one_failure_with_actual_expected_diagnostics(tmp_path,request):
    project=tmp_path/'mismatch'
    props="""version: 2
unit_tests:
  - name: mismatch
    model: final
    given: [{input: "ref('base')", rows: [{id: 2}, {id: 3}]}]
    expect: {rows: [{id: 7}, {id: 8}]}
"""
    project_at(project,'duckdb',request,props)
    if not shutil.which('dbt') or version('dbt-core')!='1.10.5' or version('dbt-duckdb')!='1.9.6':
        if os.environ.get('DXT_NATIVE_ADAPTER_CERTIFY')=='1': pytest.fail('Certification requires pinned Core and DuckDB adapter')
        pytest.skip('Pinned Core mismatch fixture unavailable')
    core=shutil.which('dbt')
    assert invoke(project,'run','--select','base',executable=core).returncode==0
    expected=invoke(project,'test','--select','test_type:unit',executable=core)
    assert expected.returncode==1,expected.stdout+expected.stderr
    actual=invoke(project,'test','--select','test_type:unit')
    assert actual.returncode==1,actual.stdout+actual.stderr
    a=rows(project)[0]; b=rows(project,True)[0]
    assert (a['status'],a['failures'])==(b['status'],b['failures'])==('fail',1)
    assert 'actual differs from expected' in a['message'] and 'actual' in b['message'] and 'expected' in b['message']
    assert '"id":2' in a['message'] and '"id":7' in a['message']


def test_sql_fixture_is_sampled_once_for_compilation_execution_and_diagnostics(tmp_path,request):
    project=tmp_path/'sample_once'
    props="""version: 2
unit_tests:
  - name: sample_once
    model: final
    given: [{input: "ref('base')", format: sql, rows: 'select random() as id'}]
    expect: {rows: [{same_sample: true}]}
"""
    sql="{% if execute %}{% set data=run_query('select id from ' ~ ref('base')) %}{% set observed=data.rows[0][0] %}{% else %}{% set observed=0 %}{% endif %}select id={{ observed }} as same_sample from {{ ref('base') }}"
    project_at(project,'duckdb',request,props,{'base':'select 0.0 as id','final':sql})
    result=invoke(project,'test','--select','test_type:unit')
    assert result.returncode==0,result.stdout+result.stderr
    assert rows(project)[0]['status']=='pass'

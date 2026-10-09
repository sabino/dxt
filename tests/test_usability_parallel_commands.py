"""Native parallel compilation and source freshness workloads."""
from __future__ import annotations
import ctypes.util
import datetime as dt
import json
import os
import subprocess
from pathlib import Path
import pytest
from test_usability_scheduler import write_project
from test_usability_adapters import postgres_fixture
ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / 'zig-out' / 'bin' / 'dxt'

@pytest.fixture(scope='module', autouse=True)
def binary():
    result = subprocess.run(['zig','build'],cwd=ROOT,capture_output=True,text=True)
    assert result.returncode == 0,result.stderr

@pytest.fixture(autouse=True)
def native(monkeypatch):
    library=os.environ.get('DXT_DUCKDB_LIBRARY') or ctypes.util.find_library('duckdb')
    if not library:
        if os.environ.get('DXT_NATIVE_ADAPTER_CERTIFY')=='1':pytest.fail('Certification requires libduckdb')
        pytest.skip('Native fixture requires libduckdb')
    monkeypatch.setenv('DXT_DUCKDB_LIBRARY',library)
    monkeypatch.setenv('DXT_DUCKDB_BACKEND','native')
    monkeypatch.setenv('DBT_SEND_ANONYMOUS_USAGE_STATS','false')

def invoke(project,*args,env=None):
    result=subprocess.run([str(DXT),*args,'--project-dir',str(project)],cwd=ROOT,capture_output=True,text=True,env=env,timeout=30)
    path=project/'target'/'run_results.json'
    return result,json.loads(path.read_text()) if path.exists() else None

def interval(row):
    value=next(t for t in row['timing'] if t['name']=='compile')
    return [dt.datetime.fromisoformat(value[k].replace('Z','+00:00')) for k in ['started_at','completed_at']]

@pytest.mark.parametrize('command',[['compile'],['docs','generate']])
def test_dynamic_compile_queries_overlap_and_preserve_artifacts(tmp_path,command):
    project=tmp_path/'compile'
    heavy="{% if execute %}{% set result = run_query('select sum(sqrt(i * 1.0)) from range(9000000) t(i)') %}{% endif %} select 17 as id"
    write_project(project,{'one':heavy,'two':heavy})
    result,artifact=invoke(project,*command,'--threads','2','--log-format','json')
    assert result.returncode==0,result.stderr
    rows=artifact['results']
    assert len(rows)==2
    assert len({r['thread_id'] for r in rows})==2
    a,b=map(interval,rows)
    assert max(a[0],b[0])<min(a[1],b[1]),(a,b)
    assert all(r['compiled'] and r['compiled_code'].strip().endswith('select 17 as id') for r in rows)
    assert all(r['execution_time']>0 for r in rows)
    assert (project/'target'/'compiled'/'scheduler_demo'/'models'/'one.sql').exists()
    events=[json.loads(line) for line in result.stderr.splitlines()]
    assert events[-1]['data']['status']=='success'
    if command[0]=='docs':assert (project/'target'/'catalog.json').exists()


def test_offline_compile_with_threads_does_not_open_database(tmp_path):
    project=tmp_path/'offline'
    write_project(project,{'one':'select 1 as id','two':'select 2 as id'})
    environment=dict(os.environ,DXT_DUCKDB_BACKEND='cli',PATH='/nonexistent')
    environment.pop('DXT_DUCKDB_LIBRARY',None)
    result,artifact=invoke(project,'compile','--threads','2',env=environment)
    assert result.returncode==0,result.stderr
    assert len(artifact['results'])==2
    assert not (project/'target'/'dxt.duckdb').exists()


def test_compile_failure_records_error_and_continues_independent_model(tmp_path):
    project=tmp_path/'failure'
    write_project(project,{'bad':'{% if execute %}{{ missing_compile_macro() }}{% endif %} select 1 as id','independent':'select 17 as id'})
    result,artifact=invoke(project,'compile','--threads','2')
    assert result.returncode==1,result.stderr
    statuses={r['unique_id']:r['status'] for r in artifact['results']}
    assert statuses=={'model.scheduler_demo.bad':'error','model.scheduler_demo.independent':'success'}
    bad=next(r for r in artifact['results'] if r['status']=='error')
    assert bad['compiled'] is False and bad['compiled_code'] is None
    assert any(t['name']=='compile' for t in bad['timing'])

@pytest.mark.parametrize('memory_path',[None,':memory:'])
def test_profile_memory_shares_seed_model_test_state_and_isolates_unit_fixtures(tmp_path,memory_path):
    from test_usability_scheduler import unit_project
    project=tmp_path/'memory'
    unit_project(project,17)
    profile="scheduler_demo:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n      schema: main\n      threads: 4\n"
    if memory_path:profile+="      path: ':memory:'\n"
    (project/'profiles.yml').write_text(profile)
    result,artifact=invoke(project,'build')
    assert result.returncode==0,result.stderr
    assert {r['status'] for r in artifact['results']}=={'success','pass'}
    assert any(r['unique_id'].startswith('unit_test.') for r in artifact['results'])
    assert all('"memory".' in r['relation_name'] for r in artifact['results'] if r['unique_id'].startswith('model.'))
    assert not list(project.rglob('*.duckdb'))
    assert not (project/':memory:').exists()
    environment=dict(os.environ,DXT_DUCKDB_BACKEND='cli')
    result,_=invoke(project,'run',env=environment)
    assert result.returncode==2
    assert 'native DuckDB library' in result.stderr
    assert not (project/':memory:').exists()


def test_freshness_queries_overlap_and_keep_independent_runtime_error_rows(tmp_path):
    project=tmp_path/'freshness'
    write_project(project,{'unused':'select 1 as id'})
    database=project/'warehouse.duckdb'
    (project/'profiles.yml').write_text(f"scheduler_demo:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n      schema: main\n      path: {database}\n")
    heavy="select current_timestamp - (sum(sqrt(i * 1.0))::bigint % 2) * interval '1 minute' from range(9000000) t(i)"
    (project/'models'/'sources.yml').write_text(f"""version: 2
sources:
  - name: raw
    freshness:
      warn_after: {{count: 1, period: hour}}
      error_after: {{count: 1, period: day}}
    tables:
      - name: one
        loaded_at_query: "{heavy}"
      - name: two
        loaded_at_query: "{heavy}"
      - name: z_missing
        loaded_at_query: 'select loaded_at from missing_freshness_table'
""")
    result,_=invoke(project,'source','freshness','--threads','2','--log-format','json')
    assert result.returncode==1,result.stderr
    artifact=json.loads((project/'target'/'sources.json').read_text())
    rows={r['unique_id'].split('.')[-1].removeprefix('z_'):r for r in artifact['results']}
    assert rows['one']['status']==rows['two']['status']=='pass'
    assert rows['missing']['status']=='runtime error'
    assert set(rows['missing'])=={'unique_id','status','error'}
    assert rows['one']['thread_id']!=rows['two']['thread_id']
    def window(row):
        t=row['timing'][0]
        return [dt.datetime.fromisoformat(t[k].replace('Z','+00:00')) for k in ['started_at','completed_at']]
    a,b=window(rows['one']),window(rows['two'])
    assert max(a[0],b[0])<min(a[1],b[1]),(a,b)
    assert rows['one']['execution_time']>0
    events=[json.loads(line) for line in result.stderr.splitlines()]
    assert len([event for event in events if event['info']['name']=='NodeFinished'])==3
    assert 'missing_freshness_table' not in rows['missing']['error']


def test_freshness_rejects_mutating_queries_in_native_read_only_transaction(tmp_path):
    project=tmp_path/'read_only'
    write_project(project,{'unused':'select 1 as id'})
    database=project/'protected.duckdb'
    (project/'profiles.yml').write_text(f"scheduler_demo:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n      path: {database}\n")
    initialized=subprocess.run(['duckdb',str(database),'-c','create sequence protected_sequence start 1'],capture_output=True,text=True)
    assert initialized.returncode==0,initialized.stderr
    (project/'models'/'sources.yml').write_text("""version: 2
sources:
  - name: raw
    freshness:
      warn_after: {count: 1, period: hour}
      error_after: {count: 1, period: day}
    tables:
      - name: guarded
        loaded_at_query: "select current_timestamp - nextval('protected_sequence') * interval '1 minute'"
""")
    result,_=invoke(project,'source','freshness','--threads','2')
    assert result.returncode==1,result.stderr
    artifact=json.loads((project/'target'/'sources.json').read_text())
    assert artifact['results'][0]['status']=='runtime error'
    query=subprocess.run(['duckdb',str(database),'-json','-c',"select nextval('protected_sequence') as value"],capture_output=True,text=True)
    assert query.returncode==0,query.stderr
    assert json.loads(query.stdout)==[{'value':1}]


def test_postgres_compile_queries_overlap_with_private_lazy_native_connections(tmp_path,postgres_fixture):
    server,_=postgres_fixture
    info=server.get_postmaster_info()
    project=tmp_path/'postgres'
    sql="{% if execute %}{% set result=run_query('select pg_sleep(0.15)') %}{% endif %}select 17 as id"
    write_project(project,{'one':sql,'two':sql})
    (project/'profiles.yml').write_text("scheduler_demo:\n  target: dev\n  outputs:\n    dev:\n      type: postgres\n      dbname: postgres\n      user: postgres\n      schema: main\n      host: \"{{ env_var('DXT_TEST_PG_SOCKET') }}\"\n      port: \"{{ env_var('DXT_TEST_PG_PORT') | int }}\"\n")
    environment=dict(os.environ,DXT_TEST_PG_SOCKET=str(info.socket_dir),DXT_TEST_PG_PORT=str(info.port))
    result,artifact=invoke(project,'compile','--threads','2',env=environment)
    assert result.returncode==0,result.stderr
    a,b=map(interval,artifact['results'])
    assert max(a[0],b[0])<min(a[1],b[1]),(a,b)
    assert len({r['thread_id'] for r in artifact['results']})==2
    assert all(r['compiled'] for r in artifact['results'])
    artifacts=(project/'target'/'manifest.json').read_text()+(project/'target'/'run_results.json').read_text()
    assert str(info.socket_dir) not in artifacts


@pytest.mark.parametrize('command',['compile','build'])
@pytest.mark.parametrize('log_format',['text','json'])
def test_worker_macro_logs_survive_owned_result_transfer(tmp_path,command,log_format):
    project=tmp_path/'logging'
    sql="{% if execute %}{% do log('native worker message', info=true) %}{% endif %}select 17 as id"
    write_project(project,{'one':sql,'two':sql})
    result,artifact=invoke(project,command,'--threads','2','--log-format',log_format)
    assert result.returncode==0,result.stderr
    if log_format=='json':
        events=[json.loads(line) for line in result.stderr.splitlines()]
        messages=[event for event in events if event['info']['name']=='JinjaLogInfo']
        assert len(messages)==2
        assert {event['data']['unique_id'] for event in messages}=={'model.scheduler_demo.one','model.scheduler_demo.two'}
        assert all(event['data']['msg']=='native worker message' and event['info']['invocation_id'] for event in messages)
    else:assert result.stderr.count('native worker message')==2
    assert 'native worker message' not in json.dumps(artifact)


def test_failed_build_counts_executed_tests_and_excludes_blocked_models(tmp_path):
    from test_usability_scheduler import chain_models
    project=tmp_path/'summary'
    properties="""version: 2
models:
  - name: z_base
    columns:
      - name: id
        data_tests: [not_null]
  - name: a_final
    columns:
      - name: id
        data_tests: [not_null]
"""
    write_project(project,chain_models('select null::integer as id'),properties=properties)
    result,artifact=invoke(project,'build','--threads','2')
    assert result.returncode==1,result.stderr
    assert 'Built 2 model(s) and 1 test(s)' in result.stdout
    assert '1 test(s) failed with 1 failure row(s)' in result.stdout
    assert len([row for row in artifact['results'] if row['status']=='skipped'])==2


def test_unknown_materialization_is_rejected_before_native_database_mutation(tmp_path):
    project=tmp_path/'preflight'
    write_project(project,{'a_good':"{{ config(materialized='table') }} select 1 as id",'z_bad':"{{ config(materialized='unregistered_materialization') }} select 2 as id"})
    result,artifact=invoke(project,'build','--threads','2')
    assert result.returncode==2,result.stderr
    assert 'unsupported build model materialization' in result.stderr
    assert artifact is None
    assert not (project/'target'/'dxt.duckdb').exists()


def test_compile_fail_fast_cancels_lazy_native_query_and_records_pending_skips(tmp_path):
    project=tmp_path/'compile_cancel'
    slow="{% if execute %}{% set result=run_query('select sum(a.i * b.i * 1.0) from range(50000) a(i) cross join range(50000) b(i)') %}{% endif %}select 17 as id"
    error="{% if execute %}{% set result=run_query('select sum(sqrt(i * 1.0)) from range(9000000) t(i)') %}{{ missing_compile_macro() }}{% endif %}select 1 as id"
    write_project(project,{'a_slow':slow,'b_error':error,'c_pending':'select 2 as id'})
    result,artifact=invoke(project,'compile','--threads','2','--fail-fast')
    assert result.returncode==1,result.stderr
    rows={row['unique_id'].split('.')[-1]:row for row in artifact['results']}
    assert {name:row['status'] for name,row in rows.items()}=={'a_slow':'error','b_error':'error','c_pending':'skipped'}
    assert rows['a_slow']['execution_time']>0
    assert 'AdapterQueryCancelled' in rows['a_slow']['message']
    assert interval(rows['a_slow'])[1]>=interval(rows['a_slow'])[0]
    assert rows['c_pending']['compiled'] is False and rows['c_pending']['compiled_code'] is None


def test_qualified_unit_fixtures_use_isolated_memory_and_preserve_real_target_context(tmp_path):
    from test_usability_scheduler import unit_project
    project=tmp_path/'qualified_units'
    unit_project(project,17)
    database=project/'warehouse.duckdb'
    (project/'profiles.yml').write_text(f"scheduler_demo:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n      schema: main\n      path: {database}\n")
    model=project/'models'/'target_model.sql'
    model.write_text("{% if target.database != 'warehouse' %}{{ missing_target_context() }}{% endif %}"+model.read_text())
    result,artifact=invoke(project,'build','--threads','2')
    assert result.returncode==0,result.stderr
    assert next(row for row in artifact['results'] if row['unique_id'].startswith('unit_test.'))['status']=='pass'
    query=subprocess.run(['duckdb',str(database),'-json','-c','select * from target_model'],capture_output=True,text=True)
    assert query.returncode==0,query.stderr
    assert json.loads(query.stdout)==[{'id':100}]


def write_freshness_sources(project,queries):
    text="""version: 2
sources:
  - name: raw
    config:
      freshness:
        warn_after: {count: 1, period: hour}
        error_after: {count: 1, period: day}
    tables:
"""
    for name,query in queries.items():
        text+=f"      - name: {name}\n        config:\n          loaded_at_query: {json.dumps(query)}\n"
    (project/'models'/'sources.yml').write_text(text)


def test_duckdb_freshness_fail_fast_cancels_live_query_and_omits_unfinished_sources(tmp_path):
    project=tmp_path/'freshness_cancel'
    write_project(project,{'unused':'select 1 as id'})
    slow="select current_timestamp - (sum(a.i * b.i * 1.0)::hugeint % 2)::bigint * interval '1 minute' from range(50000) a(i) cross join range(50000) b(i)"
    error="select current_timestamp - interval '10 year' + (sum(sqrt(i * 1.0))::bigint % 2) * interval '1 minute' from range(9000000) t(i)"
    write_freshness_sources(project,{'a_slow':slow,'b_error':error,'c_pending':'select current_timestamp'})
    result,_=invoke(project,'source','freshness','--threads','2','--fail-fast','--log-format','json')
    assert result.returncode==1,result.stderr
    artifact=json.loads((project/'target'/'sources.json').read_text())
    assert [(row['unique_id'].split('.')[-1],row['status']) for row in artifact['results']]==[('b_error','error')]
    events=[json.loads(line) for line in result.stderr.splitlines()]
    finished={event['data']['unique_id'].split('.')[-1]:event['data'] for event in events if event['info']['name']=='NodeFinished'}
    assert finished['a_slow']['status']=='runtime error'
    assert finished['a_slow']['execution_time']>0
    assert finished['c_pending']['status']=='skipped'


def test_freshness_runtime_error_continues_under_fail_fast_like_core(tmp_path):
    project=tmp_path/'runtime_error_continue'
    write_project(project,{'unused':'select 1 as id'})
    write_freshness_sources(project,{'a_error':'select loaded_at from missing_table','b_pass':'select current_timestamp'})
    result,_=invoke(project,'source','freshness','--threads','1','--fail-fast')
    assert result.returncode==1,result.stderr
    artifact=json.loads((project/'target'/'sources.json').read_text())
    assert {row['unique_id'].split('.')[-1]:row['status'] for row in artifact['results']}=={'a_error':'runtime error','b_pass':'pass'}


def postgres_profile(project,server):
    info=server.get_postmaster_info()
    (project/'profiles.yml').write_text("scheduler_demo:\n  target: dev\n  outputs:\n    dev:\n      type: postgres\n      dbname: postgres\n      user: postgres\n      schema: main\n      host: \"{{ env_var('DXT_TEST_PG_SOCKET') }}\"\n      port: \"{{ env_var('DXT_TEST_PG_PORT') | int }}\"\n")
    return dict(os.environ,DXT_TEST_PG_SOCKET=str(info.socket_dir),DXT_TEST_PG_PORT=str(info.port))


def test_postgres_freshness_queries_overlap_in_read_only_native_connections(tmp_path,postgres_fixture):
    server,_=postgres_fixture
    project=tmp_path/'pg_freshness'
    write_project(project,{'unused':'select 1 as id'})
    environment=postgres_profile(project,server)
    write_freshness_sources(project,{'one':'select current_timestamp from pg_sleep(0.2)','two':'select current_timestamp from pg_sleep(0.2)'})
    result,_=invoke(project,'source','freshness','--threads','2',env=environment)
    assert result.returncode==0,result.stderr
    artifact=json.loads((project/'target'/'sources.json').read_text())
    rows=artifact['results']
    assert len(rows)==2 and all(row['status']=='pass' for row in rows)
    assert rows[0]['thread_id']!=rows[1]['thread_id']
    windows=[[dt.datetime.fromisoformat(row['timing'][0][key].replace('Z','+00:00')) for key in ['started_at','completed_at']] for row in rows]
    assert max(window[0] for window in windows)<min(window[1] for window in windows)
    assert all(row['execution_time']>0.2 for row in rows)


def test_postgres_freshness_fail_fast_cancels_live_native_connection(tmp_path,postgres_fixture):
    server,_=postgres_fixture
    project=tmp_path/'pg_cancel'
    write_project(project,{'unused':'select 1 as id'})
    environment=postgres_profile(project,server)
    write_freshness_sources(project,{'a_slow':'select current_timestamp from pg_sleep(30)','b_error':"select current_timestamp - interval '10 years' from pg_sleep(0.15)",'c_pending':'select current_timestamp'})
    result,_=invoke(project,'source','freshness','--threads','2','--fail-fast','--log-format','json',env=environment)
    assert result.returncode==1,result.stderr
    artifact=json.loads((project/'target'/'sources.json').read_text())
    assert [(row['unique_id'].split('.')[-1],row['status']) for row in artifact['results']]==[('b_error','error')]
    events=[json.loads(line) for line in result.stderr.splitlines()]
    assert any(event['info']['name']=='NodeFinished' and event['data']['unique_id'].endswith('.a_slow') and event['data']['status']=='runtime error' for event in events)

"""Actual native worker messages retain Core console and durable file policy."""
from __future__ import annotations

import ctypes.util
import json
import os
import subprocess
from importlib.metadata import version
from pathlib import Path

import pytest
from test_usability_scheduler import write_project

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / 'zig-out' / 'bin' / 'dxt'


@pytest.fixture(scope='module',autouse=True)
def binary():
    result=subprocess.run(['zig','build'],cwd=ROOT,capture_output=True,text=True)
    assert result.returncode==0,result.stderr


@pytest.fixture(autouse=True)
def native(monkeypatch):
    library=os.environ.get('DXT_DUCKDB_LIBRARY') or ctypes.util.find_library('duckdb')
    if not library:
        if os.environ.get('DXT_NATIVE_ADAPTER_CERTIFY')=='1':pytest.fail('Certification requires libduckdb')
        pytest.skip('Native worker fixture requires libduckdb')
    monkeypatch.setenv('DXT_DUCKDB_LIBRARY',library)
    monkeypatch.setenv('DXT_DUCKDB_BACKEND','native')
    monkeypatch.setenv('DBT_SEND_ANONYMOUS_USAGE_STATS','false')


def invoke(project,command,*args):
    return subprocess.run([str(DXT),command,'--project-dir',str(project),'--threads','2','--no-use-colors',*args],cwd=ROOT,capture_output=True,text=True,timeout=20)


@pytest.mark.parametrize('command',['compile','build'])
@pytest.mark.parametrize('quiet',[False,True])
def test_typed_macro_levels_survive_workers_and_preserve_print_identity(tmp_path,command,quiet):
    project=tmp_path/'messages'
    sql="{% if execute %}{% do log('hidden debug marker') %}{% do log('visible info marker',info=true) %}{% do print('authored print marker') %}{% endif %}select 17 as id"
    write_project(project,{'one':sql,'two':sql})
    result=invoke(project,command,'--log-format-file','json',*(['--quiet'] if quiet else []))
    assert result.returncode==0,result.stderr
    console=result.stdout+result.stderr
    assert 'hidden debug marker' not in console
    assert console.count('visible info marker')==(0 if quiet else 2)
    assert console.count('authored print marker')==2
    events=[json.loads(line) for line in (project/'logs'/'dbt.log').read_text().splitlines()]
    messages=[event for event in events if event['info']['name'] in ['JinjaLogDebug','JinjaLogInfo','PrintEvent']]
    assert len(messages)==6
    assert {event['info']['name'] for event in messages}=={'JinjaLogDebug','JinjaLogInfo','PrintEvent'}
    assert {event['info']['level'] for event in messages}=={'debug','info'}
    assert all(event['info']['thread'].startswith('Thread-') and event['info']['invocation_id'] for event in messages)
    artifact=(project/'target'/'run_results.json').read_text()
    assert 'marker' not in artifact


def test_debug_console_and_disabled_print_apply_to_native_worker_messages(tmp_path):
    project=tmp_path/'debug'
    write_project(project,{'one':"{% if execute %}{% do log('debug marker') %}{% do print('disabled print marker') %}{% endif %}select 17 as id"})
    result=invoke(project,'compile','--debug','--no-print','--log-format','json','--log-format-file','json')
    assert result.returncode==0,result.stderr
    events=[json.loads(line) for line in result.stderr.splitlines()]
    messages=[event for event in events if event['info']['name']=='JinjaLogDebug']
    assert len(messages)==1 and messages[0]['info']['level']=='debug'
    assert messages[0]['data']['msg']=='debug marker'
    assert not any(event['info']['name']=='PrintEvent' for event in events)
    assert 'disabled print marker' not in (project/'logs'/'dbt.log').read_text()


@pytest.mark.parametrize('command',['compile','build'])
def test_macro_messages_before_compiler_error_remain_in_durable_logs(tmp_path,command):
    project=tmp_path/'failure'
    write_project(project,{'bad':"{% if execute %}{% do log('before error marker') %}{{ missing_compile_macro() }}{% endif %}select 17 as id"})
    result=invoke(project,command,'--quiet','--log-format-file','json')
    assert result.returncode==1,result.stderr
    assert 'before error marker' not in result.stdout+result.stderr
    events=[json.loads(line) for line in (project/'logs'/'dbt.log').read_text().splitlines()]
    assert any(event['info']['name']=='JinjaLogDebug' and event['info']['level']=='debug' and event['data']['msg']=='before error marker' for event in events)


def test_native_typed_worker_messages_match_pinned_core_quiet_print_and_file_levels(tmp_path):
    assert version('dbt-core')=='1.10.5'
    assert version('dbt-duckdb')=='1.9.6'
    project=tmp_path/'oracle'
    sql="{% if execute %}{% do log('oracle debug marker') %}{% do log('oracle info marker',info=true) %}{% do print('oracle print marker') %}{% endif %}select 17 as id"
    write_project(project,{'one':sql,'two':sql})
    (project/'profiles.yml').write_text("scheduler_demo:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n      path: ':memory:'\n      schema: main\n")
    observed={}
    for name,executable in [('dxt',str(DXT)),('core','dbt')]:
        logs=tmp_path/name
        result=subprocess.run([executable,'compile','--project-dir',str(project),'--profiles-dir',str(project),'--target-path',str(tmp_path/f'{name}-target'),'--threads','2','--quiet','--no-use-colors','--log-format-file','json','--log-path',str(logs)],cwd=ROOT,capture_output=True,text=True,timeout=30)
        assert result.returncode==0,result.stdout+result.stderr
        console=result.stdout+result.stderr
        assert console.count('oracle print marker')==2
        assert 'oracle debug marker' not in console and 'oracle info marker' not in console
        events=[json.loads(line) for line in (logs/'dbt.log').read_text().splitlines()]
        observed[name]=sorted((event['info']['name'],event['info']['level'],event['data']['msg']) for event in events if event['info']['name'] in ['JinjaLogDebug','JinjaLogInfo','PrintEvent'])
    assert observed['dxt']==observed['core']

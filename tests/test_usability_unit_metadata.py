"""Unit config and normalized checksums are readable by pinned dbt Core state."""
from __future__ import annotations
import json
import os
import shutil
from importlib.metadata import version

import pytest
from test_usability_unit_fixtures import binary, native, project_at, invoke, CONTRACT


@pytest.fixture(autouse=True)
def core():
    if not shutil.which('dbt') or version('dbt-core')!='1.10.5' or version('dbt-duckdb')!='1.9.6':
        if os.environ.get('DXT_NATIVE_ADAPTER_CERTIFY')=='1': pytest.fail('Certification requires pinned dbt Core')
        pytest.skip('Pinned dbt Core unavailable')


def definitions(project, core=False):
    return json.loads((project/('core-target' if core else 'target')/'manifest.json').read_text())['unit_tests']


def parsed_by_both(project):
    for executable in [shutil.which('dbt'),None]:
        result=invoke(project,'parse',**({'executable':executable} if executable else {}))
        assert result.returncode==0,result.stdout+result.stderr


def test_core_checksum_all_fixture_formats_and_state_handoff(tmp_path,request):
    project=tmp_path/'checksum'
    project_at(project,'duckdb',request,CONTRACT)
    (project/'tests'/'fixtures'/'inputs.csv').write_text('id,note\n2,\n')
    (project/'tests'/'fixtures'/'sql_input.sql').write_text("select 4 as id, 'sql' as note")
    parsed_by_both(project)
    actual,expected=definitions(project),definitions(project,True)
    assert actual.keys()==expected.keys()
    for identifier in actual:
        for field in ['checksum','fqn','schema','config','given','expect']:
            assert actual[identifier][field]==expected[identifier][field],(identifier,field,actual[identifier][field],expected[identifier][field])
    # Core consumes dxt's state, establishing the reverse interchange direction.
    result=invoke(project,'ls','--select','state:modified','--resource-type','unit_test','--state',str(project/'target'),'--output','json',executable=shutil.which('dbt'))
    assert result.returncode==0,result.stdout+result.stderr
    assert not any(line.startswith('{') for line in result.stdout.splitlines()),result.stdout
    before=actual['unit_test.unit_demo.final.file_csv']['checksum']
    (project/'tests'/'fixtures'/'inputs.csv').write_text('id,note\n9,\n')
    parsed_by_both(project)
    assert definitions(project)['unit_test.unit_demo.final.file_csv']['checksum']!=before
    assert definitions(project)['unit_test.unit_demo.final.file_csv']['checksum']==definitions(project,True)['unit_test.unit_demo.final.file_csv']['checksum']


def test_core_unit_config_hierarchy_typed_rendering_and_nested_fqn(tmp_path,request):
    project=tmp_path/'hierarchy'
    props='''version: 2
unit_tests:
  - name: check
    model: final
    config:
      tags: [property]
      enabled: "{{ var('enable_unit') }}"
      meta: {owner: property, nested: {limit: 3}}
    given: [{input: "ref('base')", rows: [{id: 2}]}]
    expect: {rows: [{id: 2}]}
'''
    project_at(project,'duckdb',request,props)
    (project/'models'/'sub').mkdir()
    (project/'models'/'schema.yml').rename(project/'models'/'sub'/'schema.yml')
    (project/'dbt_project.yml').write_text('''name: unit_demo
version: '1.0'
profile: unit_demo
vars: {enable_unit: true, owner: project}
models:
  unit_demo:
    final: {+schema: custom}
unit_tests:
  +tags: [global]
  +meta: {owner: "{{ env_var('UNIT_OWNER', 'project') }}", global: true}
  unit_demo:
    sub:
      +tags: [folder]
      final:
        +tags: [model]
        check: {+tags: [test], +meta: {test: true}}
''')
    parsed_by_both(project)
    identifier='unit_test.unit_demo.final.check'
    actual,expected=definitions(project)[identifier],definitions(project,True)[identifier]
    for field in ['config','fqn','schema','checksum']:
        assert actual[field]==expected[field],(field,actual[field],expected[field])
    assert actual['fqn']==['unit_demo','sub','final','check']
    assert actual['schema']=='main_custom'
    assert actual['config']['tags']==['global','folder','model','test','property']
    assert actual['config']['meta']=={'owner':'property','global':True,'test':True,'nested':{'limit':3}}
    for executable in [shutil.which('dbt'),None]:
        selected=invoke(project,'ls','--select','fqn:unit_demo.sub.final.check','--resource-type','unit_test','--output','json',**({'executable':executable} if executable else {}))
        assert selected.returncode==0,selected.stdout+selected.stderr
        assert [json.loads(line)['unique_id'] for line in selected.stdout.splitlines() if line.startswith('{')]==[identifier]


def test_core_checksum_nested_numbers_unicode_and_versions(tmp_path,request):
    project=tmp_path/'typed_checksum'
    props=r'''version: 2
models:
  - name: final
    latest_version: 2
    versions: [{v: 1, defined_in: final_v1}, {v: 2, defined_in: final_v2}]
unit_tests:
  - name: typed
    model: final
    versions: {include: [1, 2]}
    overrides:
      macros: {marker: {list: [1, 1.0, -0.0, 0.00001, 10000000000000000.0, true, null], unicode: "café\x00\u00a0\u2028"}}
      vars: {huge: 18446744073709551615}
    given:
      - input: ref('base')
        rows: [{id: 2, note: "quote' and \"double\"", value: {array: [1.0, 0.0001, false, null]}}]
    expect: {rows: [{id: 2}]}
'''
    project_at(project,'duckdb',request,props,{'base':'select 100 as id','final_v1':"select * from {{ ref('base') }}",'final_v2':"select * from {{ ref('base') }}"})
    parsed_by_both(project)
    actual,expected=definitions(project),definitions(project,True)
    assert len(actual)==len(expected)==2
    for identifier in actual:
        for field in ['checksum','fqn','version','versions']:
            assert actual[identifier][field]==expected[identifier][field],(identifier,field,actual[identifier][field],expected[identifier][field])
    assert len({definition['checksum'] for definition in actual.values()})==1


def test_core_disabled_unit_config_keeps_definition_and_skips_execution(tmp_path,request):
    project=tmp_path/'disabled'
    props='''version: 2
unit_tests:
  - name: disabled
    model: final
    given: [{input: "ref('base')", rows: [{id: 2}]}]
    expect: {rows: [{id: 2}]}
'''
    project_at(project,'duckdb',request,props)
    with (project/'dbt_project.yml').open('a') as file:
        file.write("unit_tests:\n  unit_demo:\n    final:\n      disabled: {+enabled: false, +tags: ['off']}\n")
    parsed_by_both(project)
    assert definitions(project)==definitions(project,True)=={}
    identifier='unit_test.unit_demo.final.disabled'
    actual=json.loads((project/'target'/'manifest.json').read_text())['disabled'][identifier][0]
    expected=json.loads((project/'core-target'/'manifest.json').read_text())['disabled'][identifier][0]
    for field in ['config','fqn','checksum','schema','depends_on','given','expect']:
        assert actual[field]==expected[field],(field,actual[field],expected[field])
    result=invoke(project,'ls','--select','test_type:unit','--output','json')
    assert result.returncode==0,result.stdout+result.stderr
    assert not any(line.startswith('{') for line in result.stdout.splitlines())
    assert not (project/'warehouse.duckdb').exists()

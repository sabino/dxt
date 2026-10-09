"""Group ownership and model reference access against unchanged pinned Core."""
import json
import subprocess
from pathlib import Path

import pytest

from test_usability_commands import core_runner
from test_usability_artifacts import contracts
from cli_helpers import json_lines

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / 'zig-out/bin/dxt'


@pytest.fixture(scope='module', autouse=True)
def binary():
    subprocess.run(['zig', 'build'], cwd=ROOT, check=True)


def project_at(project, properties, models=None, config=''):
    (project / 'models/nested').mkdir(parents=True)
    (project / 'dbt_project.yml').write_text("name: ownership\nversion: '1.0'\nprofile: ownership\nvars: {team: finance}\n" + config)
    (project / 'profiles.yml').write_text(f"ownership:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n      path: {project / 'warehouse.duckdb'}\n      schema: main\n")
    (project / 'models/nested/groups.yml').write_text(properties)
    for name, sql in (models or {'base': 'select 1 as id', 'consumer': "select * from {{ ref('base') }}"}).items():
        (project / 'models' / f'{name}.sql').write_text(sql)


def parse_pair(project, core_runner):
    common = ['parse', '--project-dir', str(project), '--profiles-dir', str(project)]
    actual = subprocess.run([DXT, *common, '--target-path', 'native'], capture_output=True, text=True)
    expected = core_runner.invoke(['--quiet', *common, '--target-path', 'core', '--no-partial-parse'])
    return actual, expected


GROUPS = """version: 2
groups:
  - name: finance
    owner: {name: Finance, email: [finance@example.test], slack: '#finance'}
    description: Financial reporting
    config: {meta: {domain: accounting}}
  - name: empty
    owner: {email: empty@example.test}
models:
  - name: base
    config: {group: finance, access: private}
    columns: [{name: id, data_tests: [not_null]}]
  - name: consumer
    config: {group: finance, access: public}
"""


def test_group_definitions_access_and_membership_match_full_core_artifact(tmp_path, core_runner):
    project = tmp_path / 'project'
    project_at(project, GROUPS)
    actual, expected = parse_pair(project, core_runner)
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    native = json.loads((project / 'native/manifest.json').read_text())
    core = json.loads((project / 'core/manifest.json').read_text())
    assert native['groups'] == core['groups']
    assert {k: sorted(v) for k, v in native['group_map'].items()} == {k: sorted(v) for k, v in core['group_map'].items()}
    for key in ['model.ownership.base', 'model.ownership.consumer']:
        assert native['nodes'][key]['access'] == core['nodes'][key]['access']
        assert native['nodes'][key]['config']['group'] == core['nodes'][key]['config']['group']
    contracts.assert_artifact(project / 'native/manifest.json')


@pytest.mark.parametrize('selector', ['group:finance', 'group:fin*', 'group:empty', 'access:private', 'access:public', 'access:protected', 'access:pub*'])
def test_group_and_access_selectors_match_core(tmp_path, core_runner, selector):
    project = tmp_path / 'project'
    project_at(project, GROUPS)
    common = ['ls', '--project-dir', str(project), '--profiles-dir', str(project), '--select', selector, '--output', 'json', '--output-keys', 'unique_id']
    actual = subprocess.run([DXT, *common], capture_output=True, text=True)
    oracle = core_runner.invoke(['--quiet', *common, '--no-partial-parse'])
    assert actual.returncode == 0, actual.stderr
    assert oracle.success, oracle.exception
    # Core runner returns selected nodes without relying on its terminal logs.
    assert sorted(r['unique_id'] for r in json_lines(actual.stdout)) == sorted(json.loads(line)['unique_id'] for line in oracle.result)


@pytest.mark.parametrize('properties,models,error', [
    ('groups: [{name: finance, owner: {}}]', None, 'InvalidGroupOwner'),
    ('groups: [{name: finance, owner: {name: [invalid]}}]', None, 'InvalidGroupOwner'),
    ('groups: [{name: finance, owner: {email: 12}}]', None, 'InvalidGroupOwner'),
    ('groups: [{name: finance, owner: {name: A}}, {name: finance, owner: {name: B}}]', None, 'DuplicateGroupDefinition'),
    ('models: [{name: base, config: {group: missing}}]', None, 'UnknownResourceGroup'),
    ('models: [{name: base, config: {access: secret}}]', None, 'InvalidModelAccess'),
    ('models: [{name: base, config: {access: public, materialized: ephemeral}}]', None, 'PublicEphemeralModel'),
    ('groups: [{name: finance, owner: {name: A}}]\nmodels: [{name: base, config: {access: private, group: finance}}]', None, 'PrivateModelReference'),
    ('groups: [{name: finance, owner: {name: A}}, {name: marketing, owner: {name: B}}]\nmodels: [{name: base, config: {access: private, group: finance}}, {name: consumer, config: {group: marketing}}]', None, 'PrivateModelReference'),
])
def test_invalid_ownership_is_rejected_before_warehouse_access_like_core(tmp_path, core_runner, properties, models, error):
    project = tmp_path / 'project'
    project_at(project, 'version: 2\n' + properties + '\n', models)
    actual, oracle = parse_pair(project, core_runner)
    assert actual.returncode != 0
    assert error in actual.stderr
    assert not oracle.success
    assert not (project / 'warehouse.duckdb').exists()


@pytest.mark.parametrize('visibility,restricted,allowed', [('protected', False, True), ('protected', True, False), ('public', True, True), ('private', False, True), ('private', True, False)])
def test_package_restrict_access_matches_core(tmp_path, core_runner, visibility, restricted, allowed):
    project = tmp_path / 'project'
    project_at(project, 'version: 2\ngroups: [{name: finance, owner: {name: Finance}}]\n', {'consumer': "{{ config(group='finance') }}select * from {{ ref('dependency', 'base') }}"})
    package = project / 'dbt_packages/dependency'
    (package / 'models').mkdir(parents=True)
    (package / 'dbt_project.yml').write_text(f"name: dependency\nversion: '1.0'\nrestrict-access: {'true' if restricted else 'false'}\n")
    (package / 'models/base.sql').write_text(f"{{{{ config(access='{visibility}', group='finance') }}}}select 1 as id")
    (project / 'packages.yml').write_text('packages: [{local: dbt_packages/dependency}]\n')
    actual, oracle = parse_pair(project, core_runner)
    assert (actual.returncode == 0) == allowed, actual.stderr
    assert oracle.success == allowed, oracle.exception

"""Compare complete native resource configs with pinned Core, including defaults."""
import json
import subprocess
from pathlib import Path

import pytest

from test_usability_commands import core_runner
from test_usability_artifacts import contracts

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / 'zig-out/bin/dxt'


@pytest.fixture(scope='module', autouse=True)
def binary():
    subprocess.run(['zig', 'build'], cwd=ROOT, check=True)


@pytest.mark.parametrize('configured', [False, True])
def test_complete_configs_for_every_resource_and_disabled_nodes(tmp_path, core_runner, configured):
    project = tmp_path / 'project'
    for directory in ['models', 'seeds', 'snapshots', 'tests']:
        (project / directory).mkdir(parents=True)
    settings = """models:
  +docs: {show: false}
  +contract: {alias_types: false}
  +pre-hook: ['select 1', {sql: 'select 2', transaction: false}]
  +post-hook: '{"sql": "select 3", "transaction": false}'
  config_contract:
    +meta: {owner: analytics, nested: [true, null, 3]}
    +extension: {typed: [false, 2.5]}
seeds:
  +delimiter: '|'
  +quote_columns: true
  +column_types: {id: bigint}
  +meta: {kind: input}
snapshots:
  +docs: {node_color: '#123abc'}
""" if configured else ''
    (project / 'dbt_project.yml').write_text("name: config_contract\nversion: '1.0'\nprofile: config_contract\n" + settings)
    (project / 'profiles.yml').write_text(f"config_contract:\n  target: dev\n  outputs:\n    dev: {{type: duckdb, schema: main, path: '{project / 'warehouse.duckdb'}'}}\n")
    (project / 'models/base.sql').write_text('select 1 as id, current_timestamp as updated_at')
    (project / 'models/off.sql').write_text("{{ config(enabled=false) }}select 1 as id")
    (project / 'models/schema.yml').write_text('version: 2\nmodels:\n  - name: base\n    columns: [{name: id, data_tests: [not_null]}]\n')
    (project / 'seeds/input.csv').write_text('id\n1\n')
    (project / 'snapshots/history.sql').write_text("{% snapshot history %}{{ config(strategy='timestamp', unique_key='id', updated_at='updated_at', target_schema='history') }}select * from {{ ref('base') }}{% endsnapshot %}")
    (project / 'tests/check.sql').write_text("{{ config(store_failures=true) }}select * from {{ ref('base') }} where id is null")
    common = ['parse', '--project-dir', str(project), '--profiles-dir', str(project)]
    actual = subprocess.run([DXT, *common, '--target-path', 'native'], capture_output=True, text=True)
    expected = core_runner.invoke(['--quiet', *common, '--target-path', 'core', '--no-partial-parse'])
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    native = json.loads((project / 'native/manifest.json').read_text())
    core = json.loads((project / 'core/manifest.json').read_text())
    assert {key: node['config'] for key, node in native['nodes'].items()} == {key: node['config'] for key, node in core['nodes'].items()}
    assert {key: [node['config'] for node in nodes] for key, nodes in native['disabled'].items()} == {key: [node['config'] for node in nodes] for key, nodes in core['disabled'].items()}
    contracts.assert_artifact(project / 'native/manifest.json')
    assert not (project / 'warehouse.duckdb').exists()

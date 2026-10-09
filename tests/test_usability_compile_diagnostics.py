"""Authored compiler exceptions remain useful across native render cleanup."""
import json
from pathlib import Path
import subprocess

import pytest
from test_usability_commands import core_runner
from test_usability_artifacts import contracts

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / 'zig-out/bin/dxt'


@pytest.fixture(scope='module', autouse=True)
def binary():
    subprocess.run(['zig', 'build'], cwd=ROOT, check=True)


@pytest.mark.parametrize('command', ['parse', 'compile'])
def test_compiler_exception_retains_authored_message_and_resource_path(tmp_path, core_runner, command):
    project = tmp_path / 'project'
    (project / 'models').mkdir(parents=True)
    (project / 'dbt_project.yml').write_text("name: diagnostics\nversion: '1.0'\nprofile: diagnostics\n")
    (project / 'profiles.yml').write_text(f"diagnostics:\n  target: dev\n  outputs:\n    dev: {{type: duckdb, schema: main, path: '{project / 'warehouse.duckdb'}'}}\n")
    message = 'Expected a Relation; received an invalid argument: café'
    failing = "{{ exceptions.raise_compiler_error('" + message + "') }}"
    if command == 'compile':
        failing = '{% if execute %}' + failing + '{% endif %}'
    (project / 'models/orders.sql').write_text(failing + 'select 1 as id')
    common = [command, '--project-dir', str(project), '--profiles-dir', str(project)]
    native = subprocess.run([DXT, *common, '--target-path', 'native'], capture_output=True, text=True)
    core = core_runner.invoke(['--quiet', *common, '--target-path', 'core', '--no-partial-parse'])
    assert native.returncode != 0
    assert not core.success
    assert message in native.stderr
    assert 'orders' in native.stderr
    assert 'models/orders.sql' in native.stderr
    assert message in str(core.exception)
    if command == 'compile':
        results = json.loads((project / 'native/run_results.json').read_text())['results']
        assert [(row['unique_id'], row['status']) for row in results] == [('model.diagnostics.orders', 'error')]
        assert message in results[0]['message']
        contracts.assert_artifact(project / 'native/run_results.json')

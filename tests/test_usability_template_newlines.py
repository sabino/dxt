"""Jinja source newlines normalize while artifact source bytes stay authored."""
import hashlib
import json
from pathlib import Path
import subprocess

import pytest

from test_usability_commands import core_runner, write_project


ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / 'zig-out/bin/dxt'


@pytest.fixture(scope='module', autouse=True)
def native_binary():
    subprocess.run(['zig', 'build'], cwd=ROOT, check=True)


@pytest.mark.parametrize('newline', ['\n', '\r\n', '\r', '\r\n\r'])
def test_physical_model_and_macro_newlines_match_core_without_rewriting_artifacts(tmp_path, core_runner, newline):
    project = tmp_path / 'project'
    write_project(project, {})
    macro = (
        "{% macro newline_default(value='d" + newline + "e') %}{{ return(value) }}{% endmacro %}"
        + newline
        + "{% macro newline_data() %}{% set response %}a" + newline + "b{% endset %}{{ return(response) }}{% endmacro %}"
        + newline
        + "{% macro newline_render() -%}-- from" + newline + "-- macro{%- endmacro %}"
    ).encode()
    model = (
        "{{ config(meta={'physical': 'm" + newline + "n', 'escaped': '\\r'}) }}"
        "{{ newline_render() }}" + newline
        + "select '{{ [newline_data(), newline_default(), 'c" + newline + "f', '\\r', var('runtime')]|tojson }}' as value"
        + newline + "{% raw %}-- raw" + newline + "-- block{% endraw %}"
        + newline + "{% for item in [1,2] %}-- row {{ item }}" + newline + "{% endfor %}-- final"
    ).encode()
    macro_path = project / 'macros/newlines.sql'
    model_path = project / 'models/newlines.sql'
    macro_path.parent.mkdir()
    model_path.parent.mkdir()
    macro_path.write_bytes(macro)
    model_path.write_bytes(model)
    common = ['--project-dir', str(project), '--profiles-dir', str(project), '--no-partial-parse', '--vars', '{"runtime":"r\\rs"}']
    reference = core_runner.invoke(['compile', *common, '--target-path', 'core-target', '--quiet'])
    assert reference.success, reference.exception
    expected = json.loads((project / 'core-target/manifest.json').read_text())
    result = subprocess.run([DXT, 'compile', *common, '--target-path', 'native-target'], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    actual = json.loads((project / 'native-target/manifest.json').read_text())
    actual_node = actual['nodes']['model.commands.newlines']
    expected_node = expected['nodes']['model.commands.newlines']
    assert actual_node['raw_code'] == expected_node['raw_code'] == model.decode()
    checksum = {'name': 'sha256', 'checksum': hashlib.sha256(model).hexdigest()}
    assert actual_node['checksum'] == expected_node['checksum'] == checksum
    assert actual['macros']['macro.commands.newline_data']['macro_sql'] == expected['macros']['macro.commands.newline_data']['macro_sql']
    assert '\r' in actual['macros']['macro.commands.newline_data']['macro_sql'] or newline == '\n'
    assert macro_path.read_bytes() == macro
    assert model_path.read_bytes() == model
    assert actual_node['config']['meta'] == expected_node['config']['meta']
    assert expected_node['config']['meta'] == {'physical': ('m' + newline + 'n').replace('\r\n', '\n').replace('\r', '\n'), 'escaped': '\r'}
    assert actual_node['compiled_code'] == expected_node['compiled_code']
    assert '\r' not in actual_node['compiled_code']
    assert '\\r' in actual_node['compiled_code']


def test_render_keeps_decoded_carriage_returns_until_a_second_template_lex(tmp_path, core_runner):
    project = tmp_path / 'project'
    write_project(project, {
        'models/rendered.sql': "select '{{ ['a\\rb', render('a\\rb'), render('a\\r\\nb')]|tojson }}' as value",
    })
    common = ['--project-dir', str(project), '--profiles-dir', str(project), '--no-partial-parse']
    reference = core_runner.invoke(['compile', *common, '--target-path', 'core-target', '--quiet'])
    assert reference.success, reference.exception
    result = subprocess.run([DXT, 'compile', *common, '--target-path', 'native-target'], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    manifests = [json.loads((project / target / 'manifest.json').read_text()) for target in ['native-target', 'core-target']]
    codes = [manifest['nodes']['model.commands.rendered']['compiled_code'] for manifest in manifests]
    assert codes[0] == codes[1] == 'select \'["a\\rb", "a\\nb", "a\\nb"]\' as value'

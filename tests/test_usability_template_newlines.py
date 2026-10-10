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


def test_plain_render_keeps_carriage_returns_and_template_render_lexes_them(tmp_path, core_runner):
    project = tmp_path / 'project'
    write_project(project, {
        'models/rendered.sql': "select '{{ ['a\\rb', render('a\\rb'), render('a\\r\\nb'), render('a\\rb{# comment #}'), render('a\\r\\nb}}')]|tojson }}' as value",
    })
    common = ['--project-dir', str(project), '--profiles-dir', str(project), '--no-partial-parse']
    reference = core_runner.invoke(['compile', *common, '--target-path', 'core-target', '--quiet'])
    assert reference.success, reference.exception
    result = subprocess.run([DXT, 'compile', *common, '--target-path', 'native-target'], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    manifests = [json.loads((project / target / 'manifest.json').read_text()) for target in ['native-target', 'core-target']]
    codes = [manifest['nodes']['model.commands.rendered']['compiled_code'] for manifest in manifests]
    assert codes[0] == codes[1] == 'select \'["a\\rb", "a\\rb", "a\\r\\nb", "a\\nb", "a\\nb}}"]\' as value'


@pytest.mark.parametrize('newline', ['\n', '\r\n', '\r'])
def test_plain_model_sql_bypasses_jinja_normalization(tmp_path, core_runner, newline):
    project = tmp_path / 'project'
    authored = 'select 1 as value' + newline + '-- plain'
    write_project(project, {'models/plain.sql': authored})
    common = ['--project-dir', str(project), '--profiles-dir', str(project), '--no-partial-parse']
    reference = core_runner.invoke(['compile', *common, '--target-path', 'core-target', '--quiet'])
    assert reference.success, reference.exception
    result = subprocess.run([DXT, 'compile', *common, '--target-path', 'native-target'], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    manifests = [json.loads((project / target / 'manifest.json').read_text()) for target in ['native-target', 'core-target']]
    for manifest in manifests:
        node = manifest['nodes']['model.commands.plain']
        assert node['compiled_code'] == node['raw_code'] == authored
        assert node['checksum']['checksum'] == hashlib.sha256(authored.encode()).hexdigest()


@pytest.mark.parametrize('newline', ['\n', '\r\n', '\r'])
def test_plain_docs_bypass_lexer_and_rendered_docs_preserve_returned_data(tmp_path, core_runner, newline):
    project = tmp_path / 'project'
    authored = (
        '{% docs plain %}a' + newline + 'b{% enddocs %}' + newline
        + '{% docs templated %}{# force lexer #}c' + newline + 'd{% enddocs %}' + newline
        + "{% docs returned %}{{ 'e\\rf' }}{% enddocs %}"
    ).encode()
    write_project(project, {
        'models/newlines.sql': 'select 1 as value',
        'models/schema.yml': "version: 2\nmodels:\n  - name: newlines\n    description: \"{{ doc('plain') }}|{{ doc('templated') }}|{{ doc('returned') }}\"\n",
    })
    docs_path = project / 'models/newlines.md'
    docs_path.write_bytes(authored)
    common = ['--project-dir', str(project), '--profiles-dir', str(project), '--no-partial-parse']
    reference = core_runner.invoke(['compile', *common, '--target-path', 'core-target', '--quiet'])
    assert reference.success, reference.exception
    expected = json.loads((project / 'core-target/manifest.json').read_text())
    contents = {'plain': 'a' + newline + 'b', 'templated': 'c\nd', 'returned': 'e\rf'}
    for name, text in contents.items():
        assert expected['docs']['doc.commands.' + name]['block_contents'] == text
    expected_node = expected['nodes']['model.commands.newlines']
    assert expected_node['description'] == '|'.join(contents.values())
    assert expected_node['compiled_code'] == 'select 1 as value'
    result = subprocess.run([DXT, 'compile', *common, '--target-path', 'native-target'], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    actual = json.loads((project / 'native-target/manifest.json').read_text())
    for name, text in contents.items():
        assert actual['docs']['doc.commands.' + name]['block_contents'] == text
    actual_node = actual['nodes']['model.commands.newlines']
    assert actual_node['description'] == expected_node['description']
    assert actual_node['compiled_code'] == expected_node['compiled_code']
    assert docs_path.read_bytes() == authored


@pytest.mark.parametrize('newline', ['\n', '\r\n', '\r'])
def test_render_drops_one_final_source_newline_and_keeps_returned_newlines(tmp_path, core_runner, newline):
    project = tmp_path / 'project'
    inputs = [
        'a' + newline,
        'a{# force lexer #}' + newline,
        'a{# force lexer #}' + newline + newline,
        "{{ '\\r' }}" + newline,
        'a{# force lexer #}' + newline + '\u2028',
    ]
    expression = '[' + ', '.join('render(' + json.dumps(text, ensure_ascii=False) + ')' for text in inputs) + ']'
    authored = "select '{{ " + expression + "|tojson }}' as value"
    write_project(project, {'models/rendered.sql': authored})
    common = ['--project-dir', str(project), '--profiles-dir', str(project), '--no-partial-parse']
    reference = core_runner.invoke(['compile', *common, '--target-path', 'core-target', '--quiet'])
    assert reference.success, reference.exception
    expected = json.loads((project / 'core-target/manifest.json').read_text())['nodes']['model.commands.rendered']
    code = "select '" + json.dumps(['a' + newline, 'a', 'a\n', '\r', 'a\n\u2028']) + "' as value"
    assert expected['compiled_code'] == code
    result = subprocess.run([DXT, 'compile', *common, '--target-path', 'native-target'], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    actual = json.loads((project / 'native-target/manifest.json').read_text())['nodes']['model.commands.rendered']
    assert actual['compiled_code'] == code
    assert actual['raw_code'] == expected['raw_code'] == authored
    assert actual['checksum'] == expected['checksum'] == {'name': 'sha256', 'checksum': hashlib.sha256(authored.encode()).hexdigest()}

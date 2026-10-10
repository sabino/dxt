"""Actual write paths survive native render/execution and failure publication."""
import json
import subprocess

import pytest

from test_cli import DXT, ROOT, build_dxt
from test_usability_configuration import configuration_oracle, configuration_postgres
from test_usability_resource_hooks import setup_pair


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('command', ['compile', 'run', 'build'])
@pytest.mark.parametrize('failure', [False, True])
def test_model_write_publishes_actual_path_even_after_execution_error(tmp_path, configuration_oracle, request, adapter, command, failure):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    payload = 'select 42 as actual_written_payload'
    finish = "{{ exceptions.raise_compiler_error('after actual write') }}" if failure else ''
    if command == 'compile':
        pair.write('models/marts/rendered.sql', "{% if execute %}{{ write('" + payload + "') }}" + finish + '{% endif %}select 1 as id')
    else:
        pair.write('models/marts/rendered.sql', "{{ config(materialized='native_custom') }}select 1 as id")
        pair.write('macros/materialization.sql', "{% materialization native_custom, default %}{{ write('" + payload + "') }}" + finish + "{% call noop_statement('main', message='written', code='WRITE', rows_affected=0) %}-- metadata only{% endcall %}{{ return({'relations': []}) }}{% endmaterialization %}")
    pair.invoke(command, success=not failure)
    manifests = [json.loads((project / 'target/manifest.json').read_text()) for project in pair.projects]
    actual, expected = [manifest['nodes']['model.configuration_fixture.rendered']['build_path'] for manifest in manifests]
    assert actual == expected == (None if command == 'compile' and failure else 'target/run/configuration_fixture/models/marts/rendered.sql')
    assert manifests[0]['nodes']['model.configuration_fixture.rendered']['compiled_path'] == manifests[1]['nodes']['model.configuration_fixture.rendered']['compiled_path']
    for project in pair.projects:
        assert (project / 'target/run/configuration_fixture/models/marts/rendered.sql').read_text() == (payload if command == 'compile' or failure else '-- metadata only')


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('prefix_mode', ['default', 'relative', 'absolute'])
def test_model_materialization_reads_fresh_compiled_file_with_configured_prefix(tmp_path, configuration_oracle, request, adapter, prefix_mode):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', "{{ config(materialized='file_probe') }}{% if execute %}{{ write('compile body wrote before materialization') }}{% endif %}select 42 as id")
    observed = []
    for engine, project in zip(['dxt', 'core'], pair.projects):
        target = project / ('target' if prefix_mode == 'default' else prefix_mode + '-output')
        prefix = 'target' if prefix_mode == 'default' else 'relative-output' if prefix_mode == 'relative' else str(target)
        expected = prefix + '/compiled/configuration_fixture/models/marts/rendered.sql'
        expected_build = prefix + '/run/configuration_fixture/models/marts/rendered.sql'
        physical = project / expected if prefix_mode != 'absolute' else target / 'compiled/configuration_fixture/models/marts/rendered.sql'
        query = "select content from read_text('" + str(physical) + "')" if adapter == 'duckdb' else "select pg_read_file('" + str(physical) + "') as content"
        (project / 'macros/materialization.sql').write_text("""{% materialization file_probe, default %}
{% if model.compiled_path != """ + json.dumps(expected) + """ %}{{ exceptions.raise_compiler_error('configured compiled path was lost') }}{% endif %}
{% if model.build_path != """ + json.dumps(expected_build) + """ %}{{ exceptions.raise_compiler_error('earlier compilation write was not visible in model context') }}{% endif %}
{% set contents = run_query(""" + json.dumps(query) + """) %}
{% if contents.columns[0].values()[0] != model.compiled_code %}{{ exceptions.raise_compiler_error('compiled file did not exist before materialization') }}{% endif %}
{% call noop_statement('main', message='OK') %}-- observed actual compiled file{% endcall %}
{{ return({'relations': []}) }}{% endmaterialization %}""")
        flags = [] if prefix_mode == 'default' else ['--target-path', prefix]
        arguments = ['run', '--project-dir', str(project), '--profiles-dir', str(project), '--no-partial-parse', *flags]
        if engine == 'dxt':
            result = subprocess.run([DXT, *arguments], cwd=ROOT, text=True, capture_output=True)
            assert result.returncode == 0, result.stdout + result.stderr
        else:
            result = configuration_oracle.invoke([*arguments, '--quiet'])
            assert result.success, result.exception
            from dbt.adapters.factory import reset_adapters
            from dbt.adapters.duckdb.connections import DuckDBConnectionManager
            reset_adapters()
            if DuckDBConnectionManager._ENV is not None:
                DuckDBConnectionManager._ENV.close()
                DuckDBConnectionManager._ENV = None
        node = json.loads((target / 'manifest.json').read_text())['nodes']['model.configuration_fixture.rendered']
        assert node['compiled_path'] == expected
        assert physical.read_text() == node['compiled_code']
        observed.append((node['compiled_path'].replace(str(project), '<project>'), node['compiled_code']))
    assert observed[0] == observed[1]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('command', ['run', 'build'])
def test_failed_model_compilation_preserves_completed_write_without_compiled_fields(tmp_path, configuration_oracle, request, adapter, command):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', "{% if execute %}{{ write('actual completed compile write') }}{{ exceptions.raise_compiler_error('compilation failed after write') }}{% endif %}select 1 as id")
    pair.invoke(command, success=False)
    for project in pair.projects:
        node = json.loads((project / 'target/manifest.json').read_text())['nodes']['model.configuration_fixture.rendered']
        assert node['build_path'] == 'target/run/configuration_fixture/models/marts/rendered.sql'
        assert node['compiled_path'] is None
        assert node.get('compiled_code') is None
        assert (project / node['build_path']).read_text() == 'actual completed compile write'


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('command', ['compile', 'run', 'build'])
@pytest.mark.parametrize('outer_write', [False, True])
def test_ephemeral_compilation_write_belongs_to_its_own_resource(tmp_path, configuration_oracle, request, adapter, command, outer_write):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/input.sql', "{{ config(materialized='ephemeral') }}{% if execute %}{{ write('actual ephemeral compilation write') }}{% endif %}select 1 as id")
    write = "{% if execute %}{{ write('actual outer compilation write') }}{% endif %}" if outer_write else ''
    pair.write('models/marts/rendered.sql', "{{ config(materialized='write_probe') }}" + write + "select * from {{ ref('input') }}")
    own_path = 'target/run/configuration_fixture/models/marts/rendered.sql'
    expected_early = json.dumps(own_path) if outer_write else 'none'
    pair.write('macros/materialization.sql', "{% materialization write_probe, default %}"
               "{% if model.get('build_path') != " + expected_early + " %}{{ exceptions.raise_compiler_error('ephemeral write replaced outer resource provenance') }}{% endif %}"
               "{% call noop_statement('main', message='OK') %}-- actual later materialization statement{% endcall %}"
               "{{ return({'relations': []}) }}{% endmaterialization %}")
    manifests = pair.invoke(command)
    for manifest, project in zip(manifests, pair.projects):
        node = manifest['nodes']['model.configuration_fixture.rendered']
        assert node['build_path'] == (own_path if outer_write or command != 'compile' else None)
        if outer_write:
            # Materializations write their later main statement here;
            # compile itself retains the completed earlier template write.
            path = project / 'target/run/configuration_fixture/models/marts/rendered.sql'
            if command == 'compile':
                assert path.read_text() == 'actual outer compilation write'
        path = project / 'target/run/configuration_fixture/models/marts/input.sql'
        assert path.read_text() == 'actual ephemeral compilation write'

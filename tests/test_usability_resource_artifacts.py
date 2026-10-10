"""Actual write paths survive native render/execution and failure publication."""
import json

import pytest

from test_cli import build_dxt
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
    for project in pair.projects:
        assert (project / 'target/run/configuration_fixture/models/marts/rendered.sql').read_text() == (payload if command == 'compile' or failure else '-- metadata only')

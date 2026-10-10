"""Resource result errors retain Core's phase, console stream and file event."""
import json

import pytest

from test_cli import build_dxt  # noqa: F401
from test_usability_adapters import duckdb_environment  # noqa: F401
from test_usability_artifacts import contracts
from test_usability_cli_options import environment, pinned_core  # noqa: F401
from test_usability_configuration import configuration_postgres  # noqa: F401
from test_usability_sql_operations import command, events
from test_usability_test_helpers import fixture


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('scenario', ['singular_compilation', 'generic_compilation', 'model_compilation', 'generic_warehouse', 'model_warehouse'])
@pytest.mark.parametrize('json_logs', [False, True])
@pytest.mark.parametrize('quiet', [False, True])
def test_core_resource_errors_preserve_phase_and_actual_message_in_console_and_file(tmp_path, request, duckdb_environment,
                                                                                  adapter, scenario, json_logs, quiet):
    observed = {}
    marker = 'authored diagnostic café' if scenario.endswith('_compilation') else 'missing_runtime_column'
    phase = 'Compilation Error' if scenario.endswith('_compilation') else 'Database Error' if adapter == 'postgres' else 'Runtime Error'
    for engine in ['dxt', 'core']:
        root, _ = fixture(tmp_path, engine, adapter, request, store=True, generic=scenario.startswith('generic_'), override_limit=False)
        env = environment(duckdb_environment)
        command(engine, root, env, 'run')
        if scenario == 'singular_compilation':
            path = root / 'tests/check.sql'
            path.write_text("{% if execute %}{{ exceptions.raise_compiler_error('" + marker + "') }}{% endif %}" + path.read_text())
        elif scenario == 'generic_compilation':
            (root / 'macros/bad_rows.sql').write_text("{% test bad_rows(model) %}{% if execute %}{{ exceptions.raise_compiler_error('" + marker + "') }}{% endif %}select * from {{ model }}{% endtest %}")
        elif scenario == 'model_compilation':
            (root / 'models/input.sql').write_text("{{ config(materialized='table') }}{% if execute %}{{ exceptions.raise_compiler_error('" + marker + "') }}{% endif %}select 1 as id")
        elif scenario == 'generic_warehouse':
            (root / 'macros/test_materialization.sql').write_text("{% materialization test, default %}{% call statement('main', fetch_result=True) %}select missing_runtime_column as failures, false as should_warn, false as should_error{% endcall %}{% endmaterialization %}")
        else:
            (root / 'models/input.sql').write_text("{{ config(materialized='table') }}select missing_runtime_column as id")
        which = 'run' if scenario.startswith('model_') else 'test'
        result = command(engine, root, env, which, ['--log-format-file=json'], quiet=quiet, json_logs=json_logs, ok=False)
        assert result.returncode == 1, result.stdout + result.stderr
        for artifact in ['manifest.json', 'run_results.json']:
            contracts.assert_artifact(root / 'target' / artifact)
        artifact = json.loads((root / 'target/run_results.json').read_text())
        row, = artifact['results']
        assert row['status'] == 'error' and row['failures'] is None
        assert row['message'].startswith(phase), row['message']
        assert marker in row['message']
        log = [json.loads(line) for line in (root / 'logs/dbt.log').read_text().splitlines() if line.startswith('{')]
        # The earlier successful run cannot contribute a RunResultError event.
        recorded, = [event for event in log if event['info']['name'] == 'RunResultError']
        assert recorded['info']['code'] == 'Z024'
        assert recorded['info']['level'] == 'error' and recorded['info']['thread'] == 'MainThread'
        assert recorded['info']['invocation_id'] == artifact['metadata']['invocation_id']
        assert recorded['data']['msg'] == row['message']
        assert recorded['info']['msg'] == '  ' + row['message']
        assert recorded['data']['node_info']['unique_id'] == row['unique_id']
        if json_logs:
            displayed, = events(result, 'RunResultError')
            assert displayed == recorded
            assert marker in displayed['data']['msg']
            assert json.loads(next(line for line in result.stdout.splitlines() if line.startswith('{') and json.loads(line)['info']['name'] == 'RunResultError')) == recorded
        else:
            assert recorded['info']['msg'] in result.stdout
            assert marker in result.stdout
        observed[engine] = (row['unique_id'], row['status'], row['failures'], phase,
                            recorded['info']['name'], recorded['info']['code'], recorded['info']['level'])
    assert observed['dxt'] == observed['core']


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('warehouse', [False, True])
@pytest.mark.parametrize('json_logs', [False, True])
@pytest.mark.parametrize('quiet', [False, True])
def test_core_operation_error_event_preserves_exception_and_null_result_message(tmp_path, request, duckdb_environment,
                                                                              adapter, warehouse, json_logs, quiet):
    from test_usability_sql_operations import project
    observed = {}
    marker = 'missing_runtime_column' if warehouse else 'operation authored diagnostic café'
    phase = ('Database Error' if adapter == 'postgres' else 'Runtime Error') if warehouse else 'Compilation Error'
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path, engine, adapter, request)
        body = "{% do run_query('select missing_runtime_column') %}" if warehouse else "{{ exceptions.raise_compiler_error('" + marker + "') }}"
        (root / 'macros/broken.sql').write_text('{% macro broken() %}' + body + '{% endmacro %}')
        result = command(engine, root, environment(duckdb_environment), 'run-operation',
                         ['broken', '--log-format-file=json'], ok=False, json_logs=json_logs, quiet=quiet)
        assert result.returncode == 1, result.stdout + result.stderr
        for artifact in ['manifest.json', 'run_results.json']:
            contracts.assert_artifact(root / 'target' / artifact)
        artifact = json.loads((root / 'target/run_results.json').read_text())
        row, = artifact['results']
        fields = {key: row[key] for key in ['unique_id', 'status', 'message', 'failures', 'compiled', 'compiled_code', 'relation_name', 'adapter_response']}
        assert fields == {'unique_id': 'macro.preview.broken', 'status': 'error', 'message': None, 'failures': 1,
                          'compiled': False, 'compiled_code': None, 'relation_name': None, 'adapter_response': {}}
        log = [json.loads(line) for line in (root / 'logs/dbt.log').read_text().splitlines() if line.startswith('{')]
        recorded, = [event for event in log if event['info']['name'] == 'RunningOperationCaughtError']
        assert recorded['info']['code'] == 'Q001'
        assert recorded['info']['level'] == 'error' and recorded['info']['thread'] == 'MainThread'
        assert recorded['info']['invocation_id'] == artifact['metadata']['invocation_id']
        assert recorded['data']['exc'].startswith(phase), recorded['data']['exc']
        assert marker in recorded['data']['exc']
        if not warehouse:
            assert 'broken' in recorded['data']['exc'] and 'macros/broken.sql' in recorded['data']['exc']
        assert recorded['info']['msg'] == 'Encountered an error while running operation: ' + recorded['data']['exc']
        if json_logs:
            displayed, = events(result, 'RunningOperationCaughtError')
            assert displayed == recorded
            assert json.loads(next(line for line in result.stdout.splitlines() if line.startswith('{') and json.loads(line)['info']['name'] == 'RunningOperationCaughtError')) == recorded
        else:
            assert recorded['info']['msg'] in result.stdout
        observed[engine] = (fields, phase, recorded['info']['name'], recorded['info']['code'])
    assert observed['dxt'] == observed['core']

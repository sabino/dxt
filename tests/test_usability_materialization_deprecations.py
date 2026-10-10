"""Imported builtin override warnings follow actual Core invocation policy."""
import json
import subprocess

import pytest

from test_cli import DXT, ROOT, build_dxt
from test_usability_configuration import configuration_oracle, configuration_postgres
from test_usability_custom_materializations import materialization
from test_usability_resource_hooks import setup_pair, rows

EVENT = 'PackageMaterializationOverrideDeprecation'


def invoke(pair, flags=(), success=True):
    # CLI processes own separate registries; dbtRunner shares the module global
    # across calls and needs the same fresh-invocation reset explicitly.
    from dbt.deprecations import reset_deprecations
    reset_deprecations()
    events = []
    pair.oracle.callbacks = [lambda message: events.append(message)]
    actual, expected = pair.projects
    result = subprocess.run([DXT, 'run', '--project-dir', str(actual), '--profiles-dir', str(actual), '--log-format', 'json', '--threads', '2', *flags], text=True, capture_output=True, cwd=ROOT)
    # Core's deprecation check/update can race; serialize its exact-count baseline.
    reference = pair.oracle.invoke(['run', '--project-dir', str(expected), '--profiles-dir', str(expected), '--log-format', 'json', '--threads', '1', '--no-partial-parse', '--quiet', *flags])
    from dbt.adapters.factory import reset_adapters
    from dbt.adapters.duckdb.connections import DuckDBConnectionManager
    reset_adapters()
    if DuckDBConnectionManager._ENV is not None:
        DuckDBConnectionManager._ENV.close()
        DuckDBConnectionManager._ENV = None
    assert reference.success is success, reference.exception
    assert (result.returncode == 0) is success, result.stdout + result.stderr
    native = []
    for line in result.stdout.splitlines():
        if line.startswith('{'):
            event = json.loads(line)
            if event.get('info', {}).get('name') == EVENT:
                native.append(event)
    return native, [event for event in events if event.info.name == EVENT]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('policy', ['once', 'all', 'environment', 'override_environment', 'silence', 'silence_category', 'error', 'error_category'])
def test_imported_builtin_override_deprecation_policy(tmp_path, configuration_oracle, request, monkeypatch, adapter, policy):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.append_project('flags: {require_explicit_package_overrides_for_builtin_materializations: false}\n')
    pair.write('dbt_packages/dependency/dbt_project.yml', "name: dependency\nversion: '1.0'\n")
    pair.write('dbt_packages/dependency/macros/materialization.sql', materialization(name='table', adapter=adapter, value=8))
    pair.write('models/marts/rendered.sql', "{{ config(materialized='table') }}select 900 as id")
    pair.write('models/marts/second.sql', "{{ config(materialized='table') }}select 900 as id")
    flags = []
    if policy == 'all':
        flags = ['--show-all-deprecations']
    if policy in ['environment', 'override_environment']:
        monkeypatch.setenv('DBT_SHOW_ALL_DEPRECATIONS', 'true')
        if policy == 'override_environment':
            flags = ['--no-show-all-deprecations']
    if policy.startswith('silence') or policy.startswith('error'):
        flags = ['--warn-error-options', json.dumps({policy.split('_')[0]: ['Deprecations' if policy.endswith('category') else EVENT]})]
    success = not policy.startswith('error')
    actual, expected = invoke(pair, flags, success)
    for project in pair.projects:
        assert json.loads((project / 'target/run_results.json').read_text())['args']['show_all_deprecations'] is (policy == 'all')
    if success:
        # Core explicitly sets envvar=None for this global switch.
        count = 0 if policy.startswith('silence') else 2 if policy == 'all' else 1
        assert len(actual) == len(expected) == count
        for event in actual:
            assert event['data'] == {'package_name': 'dependency', 'materialization_name': 'table'}
            assert event['info']['code'] == 'D016'
            assert "Installed package 'dependency' is overriding" in event['info']['msg']
        assert rows(pair, request, adapter, 'select id from {schema}.rendered') == [[(8,)], [(8,)]]
    else:
        for project in pair.projects:
            result = json.loads((project / 'target/run_results.json').read_text())['results']
            assert len(result) == 2
            assert all(row['status'] == 'error' and "Installed package 'dependency' is overriding" in ' '.join(row['message'].split()) for row in result)


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('case', ['explicit_required', 'root_override', 'custom_name'])
def test_materialization_without_legacy_import_override_emits_no_deprecation(tmp_path, configuration_oracle, request, adapter, case):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    name = 'native_custom' if case == 'custom_name' else 'table'
    if case != 'explicit_required':
        pair.append_project('flags: {require_explicit_package_overrides_for_builtin_materializations: false}\n')
    if case == 'root_override':
        path = 'macros/materialization.sql'
    else:
        pair.write('dbt_packages/dependency/dbt_project.yml', "name: dependency\nversion: '1.0'\n")
        path = 'dbt_packages/dependency/macros/materialization.sql'
    pair.write(path, materialization(name=name, adapter=adapter, value=8))
    pair.write('models/marts/rendered.sql', "{{ config(materialized='" + name + "') }}select 900 as id")
    actual, expected = invoke(pair)
    assert actual == expected == []

"""Project hook graph and real transaction lifecycle against pinned Core."""
from __future__ import annotations
import json
import hashlib
import os
import subprocess

import pytest
from test_usability_materializations import (
    DXT, artifact_validator, build_dxt, oracle_available, postgres_server,
    project_at, query,
)


def invoke(project, engine, command, *arguments):
    return subprocess.run(
        [str(DXT) if engine == 'dxt' else 'dbt', '--no-use-colors', command,
         '--project-dir', str(project), '--profiles-dir', str(project), *arguments],
        env=dict(os.environ, DBT_SEND_ANONYMOUS_USAGE_STATS='false', DXT_DUCKDB_BACKEND='native'),
        text=True, capture_output=True,
    )


def fixtures(tmp_path, request, adapter, start, end, skip=False):
    oracle_available(adapter)
    server = request.getfixturevalue('postgres_server') if adapter == 'postgres' else None
    suffix = hashlib.sha256(str(tmp_path).encode()).hexdigest()[:8]
    projects = [project_at(tmp_path / f'{name}_{suffix}', adapter, server) for name in ['native_hooks', 'core_hooks']]
    for project in projects:
        with (project / 'dbt_project.yml').open('a') as file:
            file.write('on-run-start: ' + json.dumps(start) + '\non-run-end: ' + json.dumps(end) + '\n')
            if skip:
                file.write('flags: {skip_nodes_if_on_run_start_fails: true}\n')
        (project / 'models/a.sql').write_text("{{ config(materialized='table') }}select 1 as id")
        (project / 'models/schema.yml').write_text('version: 2\nmodels: [{name: a, columns: [{name: id, data_tests: [not_null]}]}]\n')
        (project / 'seeds').mkdir()
        (project / 'seeds/input.csv').write_text('id\n1\n')
        (project / 'snapshots').mkdir()
        (project / 'snapshots/history.sql').write_text("{% snapshot history %}{{ config(strategy='check',check_cols='all',unique_key='id',target_schema=target.schema) }}select 1 as id{% endsnapshot %}")
    return projects, server


def normalize(value, project):
    if isinstance(value, dict):
        return {key: normalize(item, project) for key, item in value.items()}
    if isinstance(value, list):
        return [normalize(item, project) for item in value]
    if isinstance(value, str):
        return value.replace(project.name, '$schema')
    return value


def hook_contract(project):
    manifest = json.loads((project / 'target/manifest.json').read_text())
    fields = ['resource_type', 'name', 'package_name', 'path', 'original_file_path', 'unique_id',
              'fqn', 'alias', 'checksum', 'config', 'tags', 'raw_code', 'language', 'refs',
              'sources', 'depends_on', 'index', 'relation_name']
    return normalize({key: {field: node[field] for field in fields}
                      for key, node in manifest['nodes'].items() if node['resource_type'] == 'operation'}, project)


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('command', ['parse', 'compile', 'run', 'build', 'seed', 'test', 'snapshot'])
def test_core_project_hook_graph_compilation_and_execution(tmp_path, request, adapter, command):
    start = [
        'create table if not exists {{ target.schema }}.hook_events(stage varchar, n integer)',
        "insert into {{ target.schema }}.hook_events values ('start', 0)",
    ]
    end = ["insert into {{ target.schema }}.hook_events values ('end', {{ results|length }})"]
    projects, server = fixtures(tmp_path, request, adapter, start, end)
    observed, records = [], []
    for project, engine in zip(projects, ['dxt', 'dbt']):
        if command == 'test':
            # Tests have a prerequisite relation, while the hook table remains
            # absent until this command's start hooks execute.
            schema = project.name if adapter == 'postgres' else 'main'
            query(project, adapter, f'create schema if not exists "{schema}"; create table "{schema}".a(id integer); insert into "{schema}".a values (1)', server)
        result = invoke(project, engine, command)
        assert result.returncode == 0, result.stdout + result.stderr
        artifact_validator.assert_artifact(project / 'target/manifest.json')
        observed.append(hook_contract(project))
        if command == 'parse':
            continue
        artifact_validator.assert_artifact(project / 'target/run_results.json')
        rows = json.loads((project / 'target/run_results.json').read_text())['results']
        fields = ['unique_id', 'status', 'message', 'failures', 'compiled', 'compiled_code', 'relation_name', 'adapter_response']
        hook_rows = [{field: row[field] for field in fields} for row in rows if row['unique_id'].startswith('operation.')]
        records.append(normalize(hook_rows, project))
        if command == 'compile':
            assert all(row['message'] is None for row in hook_rows)
        else:
            assert all(row['thread_id'] == 'main' for row in rows if row['unique_id'].startswith('operation.'))
            assert [tuple(row) for row in query(project, adapter, 'select * from hook_events order by stage', server)] == [('end', len(rows) - 3), ('start', 0)]
    assert observed[0] == observed[1]
    if records:
        assert records[0] == records[1]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('kind', ['ephemeral', 'persisted_tests'])
def test_core_end_hook_successful_schema_and_result_node_context(tmp_path, request, adapter, kind):
    start = ['create table {{ target.schema }}.hook_events(stage varchar,n integer)']
    end = [
        "insert into {{ target.schema }}.hook_events values ('results', {{ results|length }})",
        "insert into {{ target.schema }}.hook_events values ('schemas', {{ schemas|length }})",
        "insert into {{ target.schema }}.hook_events values ('database_schemas', {{ database_schemas|length }})",
        "{% for r in results %}insert into {{ target.schema }}.hook_events values ('{{ r.node.resource_type }}_{{ r.status }}', 0);{% endfor %}",
    ]
    # The last hook traverses the canonical node objects rather than depending
    # on nondeterministic set order from Core's schema list.
    projects, server = fixtures(tmp_path, request, adapter, start, end)
    observed = []
    for project, engine in zip(projects, ['dxt', 'dbt']):
        if kind == 'ephemeral':
            (project / 'models/a.sql').write_text("{{ config(materialized='ephemeral') }}select 1 as id")
            if adapter == 'postgres':
                query(project, adapter, f'create schema "{project.name}"', server)
            command = 'run'
        else:
            (project / 'models/schema.yml').write_text(
                'version: 2\nmodels: [{name: a, columns: [{name: id, data_tests: [{not_null: {config: {store_failures: true}}}]}]}]\n'
            )
            command = 'build'
        result = invoke(project, engine, command, '--select', 'a')
        assert result.returncode == 0, result.stdout + result.stderr
        artifact_validator.assert_artifact(project / 'target/manifest.json')
        artifact_validator.assert_artifact(project / 'target/run_results.json')
        observed.append(query(project, adapter, 'select * from hook_events order by stage,n', server))
    assert observed[0] == observed[1]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_dependency_hook_package_order_and_stage_index(tmp_path, request, adapter):
    start = ["insert into {{ target.schema }}.hook_events values ('root_start', {{ model.index }})"]
    end = ["insert into {{ target.schema }}.hook_events values ('root_end', {{ model.index }})"]
    projects, server = fixtures(tmp_path, request, adapter, start, end)
    observed, contracts = [], []
    for project, engine in zip(projects, ['dxt', 'dbt']):
        schema = project.name if adapter == 'postgres' else 'main'
        query(project, adapter, f'create schema if not exists "{schema}"; create table "{schema}".hook_events(stage varchar,n integer)', server)
        packages = []
        for name in ['z_hooks', 'a_hooks']:
            path = project / name
            path.mkdir()
            (path / 'dbt_project.yml').write_text(
                f'name: {name}\nversion: "1.0"\nconfig-version: 2\n'
                'on-run-start: ' + json.dumps([f"insert into {{{{ target.schema }}}}.hook_events values ('{name}_start', {{{{ model.index }}}})"]) + '\n'
                'on-run-end: ' + json.dumps([f"insert into {{{{ target.schema }}}}.hook_events values ('{name}_end', {{{{ model.index }}}})"]) + '\n'
            )
            packages.append({'local': str(path)})
        (project / 'packages.yml').write_text(json.dumps({'packages': packages}))
        deps = invoke(project, engine, 'deps')
        assert deps.returncode == 0, deps.stdout + deps.stderr
        result = invoke(project, engine, 'run', '--select', 'a')
        assert result.returncode == 0, result.stdout + result.stderr
        observed.append(query(project, adapter, 'select * from hook_events order by stage', server))
        contracts.append(hook_contract(project))
    assert observed[0] == observed[1]
    assert contracts[0] == contracts[1]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('stage', ['start', 'end'])
def test_core_hook_compilation_error_exit_and_completed_artifact_policy(tmp_path, request, adapter, stage):
    hook = "{{ exceptions.raise_compiler_error('hook_compile_failed') if execute else 'select 1' }}"
    projects, server = fixtures(tmp_path, request, adapter, [hook] if stage == 'start' else [], [hook] if stage == 'end' else [])
    observations = []
    for project, engine in zip(projects, ['dxt', 'dbt']):
        result = invoke(project, engine, 'run', '--select', 'a')
        assert result.returncode == 2, result.stdout + result.stderr
        assert 'hook_compile_failed' in result.stdout + result.stderr
        artifact_validator.assert_artifact(project / 'target/manifest.json')
        path = project / 'target/run_results.json'
        assert path.exists() == (stage == 'end')
        if path.exists():
            artifact_validator.assert_artifact(path)
            observations.append([(row['unique_id'], row['status']) for row in json.loads(path.read_text())['results']])
    if observations:
        assert observations[0] == observations[1]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_core_project_json_dictionary_hook_runs_outside_resource_transaction(tmp_path, request, adapter):
    start = ["{{ tojson({'sql': 'create table ' ~ target.schema ~ '.hook_events(stage varchar,n integer)', 'transaction': true}) }}"]
    end = ["""{{ tojson({'sql': 'insert into ' ~ target.schema ~ ".hook_events values ('end',1)", 'transaction': false}) }}"""]
    projects, server = fixtures(tmp_path, request, adapter, start, end)
    observed = []
    for project, engine in zip(projects, ['dxt', 'dbt']):
        result = invoke(project, engine, 'run', '--select', 'a')
        assert result.returncode == 0, result.stdout + result.stderr
        artifact_validator.assert_artifact(project / 'target/run_results.json')
        observed.append(query(project, adapter, 'select * from hook_events', server))
    assert observed[0] == observed[1] == [('end', 1)]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('failure_stage,skip', [('start', False), ('start', True), ('end', False)])
def test_core_failed_hook_remaining_hook_skip_and_project_policy(tmp_path, request, adapter, failure_stage, skip):
    start = ['create table {{ target.schema }}.hook_events(stage varchar,n integer)']
    end = ["insert into {{ target.schema }}.hook_events values ('end', {{ results|length }})"]
    if failure_stage == 'start':
        start += ['select * from global_hook_missing_relation', "insert into {{ target.schema }}.hook_events values ('must_skip',0)"]
    else:
        end += ['select * from global_hook_missing_relation', "insert into {{ target.schema }}.hook_events values ('must_skip',0)"]
    projects, server = fixtures(tmp_path, request, adapter, start, end, skip)
    observed = []
    for project, engine in zip(projects, ['dxt', 'dbt']):
        result = invoke(project, engine, 'run')
        assert result.returncode == 1, result.stdout + result.stderr
        artifact_validator.assert_artifact(project / 'target/manifest.json')
        artifact_validator.assert_artifact(project / 'target/run_results.json')
        rows = json.loads((project / 'target/run_results.json').read_text())['results']
        observed.append(normalize([{key: row[key] for key in ['unique_id', 'status', 'failures', 'compiled', 'compiled_code', 'relation_name']} for row in rows], project))
        assert query(project, adapter, 'select * from hook_events', server) == [('end', 0 if skip else 2 if failure_stage == 'start' else 1)]
        manifest = json.loads((project / 'target/manifest.json').read_text())
        assert [node['index'] for node in manifest['nodes'].values() if node['resource_type'] == 'operation' and 'on-run-start' in node['tags']] == list(range(1, len(start)+1))
    assert observed[0] == observed[1]

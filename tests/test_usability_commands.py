from __future__ import annotations

import inspect
import os
import ctypes.util
import json
import shutil
import subprocess
from importlib.metadata import version
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / 'zig-out' / 'bin' / 'dxt'
DUCKDB = shutil.which('duckdb')


@pytest.fixture(scope='module', autouse=True)
def native_binary():
    assert DUCKDB is not None, 'DuckDB CLI is required for command acceptance tests'
    subprocess.run(['zig', 'build'], cwd=ROOT, check=True)


@pytest.fixture
def core_runner(monkeypatch):
    from dbt.cli.main import dbtRunner
    import dbt.adapters.duckdb  # noqa: F401
    import dbt_common.events.base_types as events
    import google.protobuf.json_format as protobuf
    assert version('dbt-core') == '1.10.5'
    assert version('dbt-duckdb') == '1.9.6'
    monkeypatch.setenv('DBT_SEND_ANONYMOUS_USAGE_STATS', 'false')
    original = protobuf.MessageToJson
    names = ('always_print_fields_with_no_presence', 'including_default_value_fields')
    supported = next(name for name in names if name in inspect.signature(original).parameters)

    def compatible(message, *args, **kwargs):
        for name in names:
            if name != supported and name in kwargs:
                kwargs.setdefault(supported, kwargs.pop(name))
        return original(message, *args, **kwargs)

    monkeypatch.setattr(protobuf, 'MessageToJson', compatible)
    monkeypatch.setattr(events, 'MessageToJson', compatible)
    return dbtRunner()


def write_project(path: Path, files: dict[str, str], database: Path | None = None):
    path.mkdir()
    (path / 'dbt_project.yml').write_text(
        "name: commands\nversion: '1.0'\nprofile: commands\nmodel-paths: ['models']\n"
        "seed-paths: ['seeds']\ntest-paths: ['tests']\nmacro-paths: ['macros']\n"
        'models:\n  commands:\n    +materialized: table\n'
    )
    database = database or path / 'warehouse.duckdb'
    (path / 'profiles.yml').write_text(
        'commands:\n  target: dev\n  outputs:\n'
        f'    dev:\n      type: duckdb\n      path: {database}\n      schema: dev\n      threads: 1\n      keep_open: false\n'
        f'    prod:\n      type: duckdb\n      path: {database}\n      schema: prod\n      threads: 1\n      keep_open: false\n'
    )
    for name, text in files.items():
        target = path / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
    return database


def run_dxt(project: Path, command: str, *args: str, target: Path | None = None, cwd: Path | None = None):
    return subprocess.run(
        [DXT, command, *args, '--project-dir', str(project), *([] if command == 'debug' else ['--target-path', str(target or project / 'target')])],
        cwd=cwd or ROOT, text=True, capture_output=True,
    )


def query(database: Path, sql: str):
    result = subprocess.run([DUCKDB, str(database), '-json', '-batch', '-bail', '-c', sql], text=True, capture_output=True, check=True)
    return json.loads(result.stdout or '[]')


def artifact(project: Path, target: Path | None = None):
    return json.loads(((target or project / 'target') / 'run_results.json').read_text())


def rows(project: Path, target: Path | None = None):
    return {row['unique_id']: row for row in artifact(project, target)['results']}


def test_init_scaffolds_a_buildable_duckdb_project(tmp_path):
    result = subprocess.run([DXT, 'init', 'starter', '--project-dir', str(tmp_path)], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    project = tmp_path / 'starter'
    build = run_dxt(project, 'build', cwd=project)
    assert build.returncode == 0, build.stderr
    data = artifact(project)
    assert data['args']['which'] == 'build'
    assert data['metadata']['invocation_id'] is not None
    assert data['metadata']['invocation_started_at'][:4] != '1970'
    assert data['elapsed_time'] > 0
    assert len(data['results']) == 4
    assert all(row['status'] in {'success', 'pass'} for row in data['results'])
    assert query(project / 'starter.duckdb', 'select * from main.customers order by id') == [{'id': 1, 'name': 'Ada'}, {'id': 2, 'name': 'Grace'}]


@pytest.mark.parametrize('name', ['../escape', 'invalid-name', '1project'])
def test_init_rejects_invalid_names_without_scaffolding(tmp_path, name):
    result = subprocess.run([DXT, 'init', name, '--project-dir', str(tmp_path)], text=True, capture_output=True)
    assert result.returncode == 2
    assert [path.name for path in tmp_path.iterdir()] == ['logs']
    assert [path.name for path in (tmp_path / 'logs').iterdir()] == ['dbt.log']
    diagnostic = 'project name must contain only letters, digits, and underscores and start with a letter or underscore'
    assert diagnostic in result.stderr
    assert diagnostic in (tmp_path / 'logs' / 'dbt.log').read_text()


def test_init_preserves_existing_project_and_profile(tmp_path):
    project = tmp_path / 'starter'
    project.mkdir()
    (project / 'keep.txt').write_text('keep')
    result = subprocess.run([DXT, 'init', 'starter', '--project-dir', str(tmp_path)], text=True, capture_output=True)
    assert result.returncode == 2
    assert (project / 'keep.txt').read_text() == 'keep'
    profiles = tmp_path / 'profiles'
    profiles.mkdir()
    (profiles / 'profiles.yml').write_text('keep: profile\n')
    result = subprocess.run([DXT, 'init', 'second', '--project-dir', str(tmp_path), '--profiles-dir', str(profiles)], text=True, capture_output=True)
    assert result.returncode == 2
    assert not (tmp_path / 'second').exists()
    assert (profiles / 'profiles.yml').read_text() == 'keep: profile\n'


def test_init_skip_profile_setup_writes_no_profile(tmp_path):
    result = subprocess.run([DXT, 'init', 'starter', '--project-dir', str(tmp_path), '--skip-profile-setup'], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    assert (tmp_path / 'starter' / 'dbt_project.yml').is_file()
    assert not (tmp_path / 'starter' / 'profiles.yml').exists()


def test_debug_checks_connection_without_parsing_model_sql(tmp_path):
    project = tmp_path / 'project'
    database = write_project(project, {'models/broken.sql': '{{ malformed syntax'})
    result = run_dxt(project, 'debug')
    assert result.returncode == 0, result.stderr
    assert 'Connection test: OK' in result.stdout
    assert database.is_file()
    assert not (project / 'target' / 'manifest.json').exists()


def test_debug_reports_real_connection_failure_without_secrets(tmp_path):
    project = tmp_path / 'project'
    write_project(project, {}, tmp_path / 'does-not-exist' / 'secret-password.duckdb')
    result = run_dxt(project, 'debug')
    assert result.returncode == 1
    assert 'Connection test: OK' not in result.stdout
    assert 'secret-password' not in result.stderr


def test_run_operation_returns_sql_without_executing_it(tmp_path):
    project = tmp_path / 'project'
    database = write_project(project, {'macros/noop.sql': "{% macro noop() %}{{ return('create table never_created(id int)') }}{% endmacro %}"})
    result = run_dxt(project, 'run-operation', 'noop')
    assert result.returncode == 0, result.stderr
    row = rows(project)['macro.commands.noop']
    assert (row['status'], row['failures'], row['compiled'], row['compiled_code']) == ('success', 0, False, None)
    assert artifact(project)['args']['which'] == 'run-operation'
    assert not database.exists() or query(database, "select table_name from information_schema.tables where table_name='never_created'") == []


def test_run_operation_executes_run_query_with_typed_kwargs_and_results(tmp_path):
    project = tmp_path / 'project'
    database = write_project(project, {'macros/create_rows.sql': """{% macro create_rows(table='created', n=3, enabled=true) %}
{% if enabled %}
{% do run_query('create table ' ~ adapter.quote(table) ~ ' as select ' ~ n ~ ' as n') %}
{% set result = run_query('select n from ' ~ adapter.quote(table)) %}
{% do log(result.columns[0].values()[0], info=true) %}
{% endif %}
{% endmacro %}"""})
    result = run_dxt(project, 'run-operation', 'create_rows', '--args', '{table: chosen, n: 7, enabled: true}')
    assert result.returncode == 0, result.stderr
    assert '7\n' in result.stdout
    assert query(database, 'select * from chosen') == [{'n': 7}]


def test_run_operation_records_sanitized_sql_error(tmp_path):
    project = tmp_path / 'project'
    write_project(project, {'macros/broken.sql': "{% macro broken() %}{% do run_query('select * from secret_password_missing') %}{% endmacro %}"})
    result = run_dxt(project, 'run-operation', 'broken')
    assert result.returncode == 1
    assert 'secret_password' not in result.stderr
    row = rows(project)['macro.commands.broken']
    assert (row['status'], row['failures'], row['compiled'], row['message']) == ('error', 1, False, None)


@pytest.mark.parametrize('args', ['[]', 'bad', '{"n":'])
def test_run_operation_rejects_non_mapping_args(tmp_path, args):
    project = tmp_path / 'project'
    database = write_project(project, {'macros/noop.sql': '{% macro noop() %}{% endmacro %}'})
    result = run_dxt(project, 'run-operation', 'noop', '--args', args)
    assert result.returncode == 2
    assert not database.exists()


def test_retry_replays_run_only_failed_and_skipped_nodes(tmp_path):
    project = tmp_path / 'project'
    database = write_project(project, {
        'models/broken.sql': 'select * from missing_relation',
        'models/child.sql': "select * from {{ ref('broken') }}",
        'models/independent.sql': 'select 9 as id',
    })
    first = run_dxt(project, 'run', '--select', 'broken+', 'independent', '--target', 'prod', '--vars', '{revision: 1}')
    assert first.returncode == 1, first.stderr
    before = rows(project)
    assert {key: row['status'] for key, row in before.items()} == {'model.commands.broken': 'error', 'model.commands.child': 'skipped', 'model.commands.independent': 'success'}
    query(database, 'insert into prod.independent values (99)')
    (project / 'models/broken.sql').write_text('select 7 as id')
    second = run_dxt(project, 'retry')
    assert second.returncode == 0, second.stderr
    after = artifact(project)
    assert after['args']['which'] == 'run'
    assert after['args']['select'] == ['broken+', 'independent']
    assert after['args']['target'] == 'prod'
    assert set(row['unique_id'] for row in after['results']) == {'model.commands.broken', 'model.commands.child'}
    assert all(row['status'] == 'success' for row in after['results'])
    assert query(database, 'select id from prod.independent order by id') == [{'id': 9}, {'id': 99}]
    third = run_dxt(project, 'retry')
    assert third.returncode == 0, third.stderr
    assert artifact(project)['results'] == []
    assert artifact(project)['args']['which'] == 'run'


def test_retry_replays_failed_test_without_building_parent(tmp_path):
    project = tmp_path / 'project'
    database = write_project(project, {'models/parent.sql': 'select 1 as id', 'tests/bad.sql': 'select 1 where true'})
    assert run_dxt(project, 'run').returncode == 0
    first = run_dxt(project, 'test')
    assert first.returncode == 1, first.stderr
    query(database, 'insert into dev.parent values (99)')
    (project / 'tests/bad.sql').write_text('select 1 where false')
    second = run_dxt(project, 'retry')
    assert second.returncode == 0, second.stderr
    assert artifact(project)['args']['which'] == 'test'
    assert list(rows(project)) == ['test.commands.bad']
    assert rows(project)['test.commands.bad']['status'] == 'pass'
    assert query(database, 'select id from dev.parent order by id') == [{'id': 1}, {'id': 99}]


def test_retry_requires_real_prior_results(tmp_path):
    project = tmp_path / 'project'
    write_project(project, {})
    result = run_dxt(project, 'retry')
    assert result.returncode == 2
    assert not (project / 'target').exists()


def test_clone_uses_prior_relations_and_preserves_existing_until_full_refresh(tmp_path):
    project = tmp_path / 'project'
    database = write_project(project, {'models/customers.sql': 'select 7 as id', 'seeds/raw.csv': 'id\n2\n'})
    state = tmp_path / 'state'
    assert run_dxt(project, 'build', '--target', 'prod', target=state).returncode == 0
    result = run_dxt(project, 'clone', '--state', str(state))
    assert result.returncode == 0, result.stderr
    assert set(rows(project)) == {'model.commands.customers', 'seed.commands.raw'}
    assert query(database, 'select * from dev.customers') == [{'id': 7}]
    assert query(database, "select table_type from information_schema.tables where table_schema='dev' and table_name='customers'") == [{'table_type': 'VIEW'}]
    query(database, 'drop view dev.customers; create table dev.customers as select 99 as id')
    assert run_dxt(project, 'clone', '--state', str(state)).returncode == 0
    assert query(database, 'select * from dev.customers') == [{'id': 99}]
    result = run_dxt(project, 'clone', '--state', str(state), '--full-refresh')
    assert result.returncode == 0, result.stderr
    assert query(database, 'select * from dev.customers') == [{'id': 7}]
    query(database, 'insert into prod.customers values (8)')
    assert query(database, 'select * from dev.customers order by id') == [{'id': 7}, {'id': 8}]


def test_clone_requires_state_before_database_side_effect(tmp_path):
    project = tmp_path / 'project'
    database = write_project(project, {'models/customers.sql': 'select 7 as id'})
    result = run_dxt(project, 'clone')
    assert result.returncode == 2
    assert not database.exists()


def invoke_core(runner, project: Path, command: str, *args: str, target: Path | None = None):
    common = [command, '--project-dir', str(project), '--profiles-dir', str(project)]
    if command != 'debug':
        common += ['--target-path', str(target or project / 'target')]
    return runner.invoke([*common, *args])


def validate_schema(project: Path, target: Path | None = None):
    from dbt.artifacts.schemas.run import RunResultsArtifact
    RunResultsArtifact.validate(artifact(project, target))


def test_core_1105_debug_checks_connection_without_parsing_models(tmp_path, core_runner):
    for engine in ('dxt', 'core'):
        project = tmp_path / engine
        database = write_project(project, {'models/broken.sql': '{{ malformed syntax'})
        result = run_dxt(project, 'debug') if engine == 'dxt' else invoke_core(core_runner, project, 'debug')
        assert (result.returncode == 0) if engine == 'dxt' else result.success
        assert database.is_file()
        assert not (project / 'target' / 'manifest.json').exists()


@pytest.mark.parametrize('failing', [False, True])
def test_core_1105_run_operation_typed_effects_and_error_artifacts(tmp_path, core_runner, failing):
    macro = """{% macro operation(n=3, enabled=true) %}
{% if enabled %}
{% do run_query('create table created as select ' ~ n ~ ' as n') %}
{% set result = run_query('select n from created') %}
{% do log(result.columns[0].values()[0], info=true) %}
{% endif %}
""" + ("{% do run_query('select * from secret_password_missing') %}" if failing else "{{ return('create table never_created as select 8') }}") + "{% endmacro %}"
    observed = {}
    for engine in ('dxt', 'core'):
        project = tmp_path / engine
        database = write_project(project, {'macros/operation.sql': macro})
        args = ('operation', '--args', '{n: 7, enabled: true}')
        result = run_dxt(project, 'run-operation', *args) if engine == 'dxt' else invoke_core(core_runner, project, 'run-operation', *args)
        assert (result.returncode == (1 if failing else 0)) if engine == 'dxt' else result.success is not failing
        assert query(database, 'select * from created') == [{'n': 7}]
        assert query(database, "select table_name from information_schema.tables where table_name='never_created'") == []
        validate_schema(project)
        row = rows(project)['macro.commands.operation']
        observed[engine] = {key: row[key] for key in ('status', 'failures', 'message', 'compiled', 'compiled_code', 'relation_name')}
        assert artifact(project)['args']['which'] == 'run-operation'
    assert observed['dxt'] == observed['core']


def test_core_1105_retry_preserves_original_run_semantics_and_subsets(tmp_path, core_runner):
    observed = {}
    files = {'models/broken.sql': 'select * from missing_relation', 'models/child.sql': "select * from {{ ref('broken') }}", 'models/independent.sql': 'select 9 as id'}
    for engine in ('dxt', 'core'):
        project = tmp_path / engine
        database = write_project(project, files)
        args = ('--select', 'broken+', 'independent', '--target', 'prod', '--vars', '{revision: 1}')
        first = run_dxt(project, 'run', *args) if engine == 'dxt' else invoke_core(core_runner, project, 'run', *args)
        assert (first.returncode == 1) if engine == 'dxt' else first.success is False
        before = {key: row['status'] for key, row in rows(project).items()}
        query(database, 'insert into prod.independent values (99)')
        (project / 'models/broken.sql').write_text('select 7 as id')
        second = run_dxt(project, 'retry') if engine == 'dxt' else invoke_core(core_runner, project, 'retry')
        assert (second.returncode == 0) if engine == 'dxt' else second.success
        validate_schema(project)
        after = {key: row['status'] for key, row in rows(project).items()}
        assert artifact(project)['args']['which'] == 'run'
        assert artifact(project)['args']['target'] == 'prod'
        assert query(database, 'select id from prod.independent order by id') == [{'id': 9}, {'id': 99}]
        observed[engine] = before, after
    assert observed['dxt'] == observed['core']


def test_core_1105_clone_view_copy_existing_relation_and_full_refresh(tmp_path, core_runner):
    observed = {}
    for engine in ('dxt', 'core'):
        project = tmp_path / engine
        database = write_project(project, {'models/customers.sql': 'select 7 as id', 'seeds/raw.csv': 'id\n2\n'})
        state = tmp_path / f'{engine}-state'
        first = run_dxt(project, 'build', '--target', 'prod', target=state) if engine == 'dxt' else invoke_core(core_runner, project, 'build', '--target', 'prod', target=state)
        assert (first.returncode == 0) if engine == 'dxt' else first.success
        args = ('--state', str(state))
        clone = run_dxt(project, 'clone', *args) if engine == 'dxt' else invoke_core(core_runner, project, 'clone', *args)
        assert (clone.returncode == 0) if engine == 'dxt' else clone.success
        validate_schema(project)
        assert query(database, 'select * from dev.customers') == [{'id': 7}]
        assert query(database, 'select * from dev.raw') == [{'id': 2}]
        query(database, 'drop view dev.customers; create table dev.customers as select 99 as id')
        clone = run_dxt(project, 'clone', *args) if engine == 'dxt' else invoke_core(core_runner, project, 'clone', *args)
        assert (clone.returncode == 0) if engine == 'dxt' else clone.success
        assert query(database, 'select * from dev.customers') == [{'id': 99}]
        clone = run_dxt(project, 'clone', *args, '--full-refresh') if engine == 'dxt' else invoke_core(core_runner, project, 'clone', *args, '--full-refresh')
        assert (clone.returncode == 0) if engine == 'dxt' else clone.success
        query(database, 'insert into prod.customers values (8)')
        observed[engine] = {
            'results': {key: {field: row[field] for field in ('status', 'compiled', 'compiled_code', 'message', 'failures', 'relation_name', 'adapter_response')} for key, row in rows(project).items()},
            'data': query(database, 'select * from dev.customers order by id'),
            'type': query(database, "select table_type from information_schema.tables where table_schema='dev' and table_name='customers'"),
        }
    assert observed['dxt'] == observed['core']


@pytest.fixture
def native_library(monkeypatch):
    library = os.environ.get('DXT_DUCKDB_LIBRARY') or ctypes.util.find_library('duckdb')
    assert library is not None, 'Statement transaction certification requires libduckdb or DXT_DUCKDB_LIBRARY'
    monkeypatch.setenv('DXT_DUCKDB_LIBRARY', library)
    monkeypatch.setenv('DXT_DUCKDB_BACKEND', 'native')


@pytest.mark.parametrize('commit', [False, True])
def test_core_1105_statement_transactions_and_loaded_results(tmp_path, core_runner, native_library, commit):
    macro = """{% macro statement_rows() %}
{% call statement('create_rows') %}create table created as select 7 as id{% endcall %}
{% call statement('read_rows', fetch_result=true) %}select id from created{% endcall %}
{% set result = load_result('read_rows') %}
{% do log(result.data[0][0], info=true) %}
""" + ('{% do adapter.commit() %}' if commit else '') + '{% endmacro %}'
    observed = {}
    for engine in ('dxt', 'core'):
        project = tmp_path / engine
        database = write_project(project, {'macros/statement.sql': macro})
        result = run_dxt(project, 'run-operation', 'statement_rows') if engine == 'dxt' else invoke_core(core_runner, project, 'run-operation', 'statement_rows')
        assert (result.returncode == 0) if engine == 'dxt' else result.success
        if engine == 'dxt':
            assert '7\n' in result.stdout
        observed[engine] = query(database, "select table_name from information_schema.tables where table_name='created'")
        assert rows(project)['macro.commands.statement_rows']['status'] == 'success'
    assert observed['dxt'] == observed['core'] == ([{'table_name': 'created'}] if commit else [])


def test_core_1105_statement_auto_begin_false_and_empty_select_metadata(tmp_path, core_runner, native_library):
    macro = """{% macro statement_rows() %}
{% call statement('create_rows', auto_begin=false) %}create table created as select 7 as id{% endcall %}
{% set result = run_query('select id from created where false') %}
{% do log(result.column_names[0], info=true) %}
{% do log(result.rows | length, info=true) %}
{% endmacro %}"""
    for engine in ('dxt', 'core'):
        project = tmp_path / engine
        database = write_project(project, {'macros/statement.sql': macro})
        result = run_dxt(project, 'run-operation', 'statement_rows', '--no-use-colors') if engine == 'dxt' else invoke_core(core_runner, project, 'run-operation', 'statement_rows', '--no-use-colors')
        assert (result.returncode == 0) if engine == 'dxt' else result.success
        if engine == 'dxt':
            assert 'id\n0\n' in result.stdout
        assert query(database, 'select * from created') == [{'id': 7}]


def test_run_operation_block_yaml_args_are_typed_and_durable(tmp_path):
    project = tmp_path / 'project'
    database = write_project(project, {'macros/typed.sql': """{% macro typed(n, flags, names) %}
{% if flags.enabled %}{% do run_query('create table created as select ' ~ n ~ ' as n') %}{% endif %}
{% do log(names[0], info=true) %}
{% endmacro %}"""})
    arguments = 'n: 7\nflags:\n  enabled: true\nnames: [Ada, Grace]\n'
    result = run_dxt(project, 'run-operation', 'typed', '--args', arguments)
    assert result.returncode == 0, result.stderr
    assert 'Ada\n' in result.stdout
    assert artifact(project)['args']['args'] == {'n': 7, 'flags': {'enabled': True}, 'names': ['Ada', 'Grace']}
    assert query(database, 'select * from created') == [{'n': 7}]


def test_retry_operation_preserves_typed_macro_args(tmp_path):
    project = tmp_path / 'project'
    database = write_project(project, {'macros/op.sql': "{% macro op(n=3) %}{% do run_query('select * from missing_relation') %}{% endmacro %}"})
    first = run_dxt(project, 'run-operation', 'op', '--args', '{n: 7}')
    assert first.returncode == 1
    (project / 'macros/op.sql').write_text("{% macro op(n=3) %}{% do run_query('create table created as select ' ~ n ~ ' as n') %}{% endmacro %}")
    second = run_dxt(project, 'retry')
    assert second.returncode == 0, second.stderr
    assert artifact(project)['args']['which'] == 'run-operation'
    assert artifact(project)['args']['args'] == {'n': 7}
    assert query(database, 'select * from created') == [{'n': 7}]


def test_clone_error_retains_success_rows_and_current_manifest(tmp_path):
    project = tmp_path / 'project'
    database = write_project(project, {'models/bad.sql': 'select 7 as id', 'models/good.sql': 'select 8 as id'})
    state = tmp_path / 'state'
    assert run_dxt(project, 'run', '--target', 'prod', target=state).returncode == 0
    query(database, 'drop table prod.bad')
    result = run_dxt(project, 'clone', '--state', str(state))
    assert result.returncode == 1
    assert {key: row['status'] for key, row in rows(project).items()} == {'model.commands.bad': 'error', 'model.commands.good': 'success'}
    assert (project / 'target' / 'manifest.json').is_file()
    assert query(database, 'select * from dev.good') == [{'id': 8}]


@pytest.mark.parametrize('command,args', [('init', ['starter', '--target', 'dev']), ('debug', ['--state', 'previous']), ('run-operation', ['op', '--state', 'previous'])])
def test_new_commands_reject_flags_without_defined_effects(tmp_path, command, args):
    project = tmp_path / 'project'
    write_project(project, {})
    result = subprocess.run([DXT, command, *args, '--project-dir', str(project)], text=True, capture_output=True)
    assert result.returncode == 2
    assert not (project / 'warehouse.duckdb').exists()


def test_core_1105_retry_build_queue_excludes_new_indirect_tests(tmp_path, core_runner):
    observed = {}
    for engine in ('dxt', 'core'):
        project = tmp_path / engine
        database = write_project(project, {'models/broken.sql': 'select * from missing_relation', 'models/child.sql': "select * from {{ ref('broken') }}", 'models/parent.sql': 'select 1 as id'})
        first = run_dxt(project, 'build') if engine == 'dxt' else invoke_core(core_runner, project, 'build')
        assert (first.returncode == 1) if engine == 'dxt' else first.success is False
        query(database, 'insert into dev.parent values (99)')
        (project / 'models/broken.sql').write_text('select null::integer as id')
        (project / 'models/schema.yml').write_text('version: 2\nmodels:\n  - name: broken\n    columns:\n      - name: id\n        data_tests: [not_null]\n')
        second = run_dxt(project, 'retry') if engine == 'dxt' else invoke_core(core_runner, project, 'retry')
        assert (second.returncode == 0) if engine == 'dxt' else second.success
        observed[engine] = {key: row['status'] for key, row in rows(project).items()}
        assert artifact(project)['args']['which'] == 'build'
        assert query(database, 'select id from dev.parent order by id') == [{'id': 1}, {'id': 99}]
    assert observed['dxt'] == observed['core'] == {'model.commands.broken': 'success', 'model.commands.child': 'success'}

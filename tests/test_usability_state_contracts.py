"""Actual pinned Core/native CLI evidence for breaking state contracts.

Expected reasons and selection are independently asserted; Core manifests are
never rewritten to manufacture a comparison. Pure comparison branches also
have native regressions in state_contract.zig.
"""
import importlib.metadata
import json
import os
from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / 'zig-out/bin/dxt'
METHODS = ('modified.contract', 'modified', 'unmodified')


@pytest.fixture(scope='module', autouse=True)
def native_binary():
    assert importlib.metadata.version('dbt-core') == '1.10.5'
    subprocess.run(['zig', 'build'], cwd=ROOT, check=True)
    assert DXT.is_file()


def invoke(root, command, *args, core=False, target=None, policy=()):
    binary = 'dbt' if core else str(DXT)
    subcommand = [command]
    if command == 'docs':
        subcommand.append(args[0])
        args = args[1:]
    command_args = [binary, '--log-format', 'json', *policy, *subcommand,
                    '--project-dir', str(root), '--profiles-dir', str(root),
                    '--target-path', str(target or root / ('core-current' if core else 'native-current')),
                    *map(str, args)]
    env = dict(os.environ, DBT_SEND_ANONYMOUS_USAGE_STATS='false')
    return subprocess.run(command_args, cwd=ROOT, env=env, text=True, capture_output=True)


def records(result):
    found = []
    for line in (result.stdout + '\n' + result.stderr).splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            found.append(value)
            # Core JSON logging wraps list output in PrintEvent.data.msg.
            message = value.get("data", {}).get("msg")
            if isinstance(message, str) and message.startswith("{"):
                item = json.loads(message)
                if isinstance(item, dict):
                    found.append(item)
    return found


def breaking_events(result):
    return [value for value in records(result) if value.get('info', {}).get('name') == 'UnversionedBreakingChange']


def selected(result):
    return {value['unique_id'] for value in records(result) if 'unique_id' in value}


def definition(versioned=False, materialized='table', enforced=True):
    model = {'name': 'a', 'config': {'materialized': materialized, 'contract': {'enforced': enforced}},
             'columns': [{'name': 'id', 'data_type': 'integer'}, {'name': 'label', 'data_type': 'varchar'}]}
    if versioned:
        model.update(latest_version=1, versions=[{'v': 1}])
    return {'version': 2, 'models': [model]}


def write_schema(root, value):
    (root / 'models/schema.yml').write_text(json.dumps(value))


def project(tmp_path, versioned=False, adapter='duckdb', schema=None):
    root = tmp_path / 'project'
    (root / 'models').mkdir(parents=True)
    (root / 'dbt_project.yml').write_text('name: state_contracts\nversion: 1.0.0\nconfig-version: 2\nprofile: state_contracts\n')
    if adapter == 'duckdb':
        output = {'type': 'duckdb', 'path': str(root / 'warehouse.duckdb'), 'schema': 'analytics'}
    else:
        # parse/list use the actual adapter capability map without connecting.
        output = {'type': 'postgres', 'host': '127.0.0.1', 'port': 1, 'user': 'state_fixture',
                  'pass': 'state_fixture', 'dbname': 'state_fixture', 'schema': 'analytics', 'threads': 1}
    (root / 'profiles.yml').write_text(json.dumps({'state_contracts': {'target': 'dev', 'outputs': {'dev': output}}}))
    (root / 'models' / ('a_v1.sql' if versioned else 'a.sql')).write_text("select 1 as id, cast('one' as varchar) as label")
    (root / 'models/other.sql').write_text('select 2 as id')
    write_schema(root, schema or definition(versioned))
    return root


def baseline(root, tmp_path, origin='core'):
    state = tmp_path / 'state'
    result = invoke(root, 'parse', core=origin == 'core', target=state)
    assert result.returncode == 0, result.stdout + result.stderr
    return state, (state / 'manifest.json').read_bytes()


def compare(root, state, versioned, expected_reason, methods=METHODS, policy=(), selector_args=None):
    expected_id = 'model.state_contracts.a' + ('.v1' if versioned else '')
    for method in methods:
        args = selector_args or ('--select', 'state:' + method)
        results = [invoke(root, 'ls', '--state', state, '--output', 'json', '--indirect-selection', 'empty',
                          *args, core=core, policy=policy) for core in (False, True)]
        for result in results:
            assert result.returncode == (2 if versioned or policy == ('--warn-error',) else 0), result.stdout + result.stderr
            assert expected_reason in result.stdout + result.stderr
            if versioned:
                assert 'Breaking change to contract Error in ' in result.stdout + result.stderr
            if versioned or policy == ('--warn-error',):
                assert not selected(result)
            else:
                events = breaking_events(result)
                assert events, result.stdout + result.stderr
                assert all(event['info']['code'] == 'I071' for event in events)
                assert all(event['data']['model_name'] == 'a' for event in events)
        assert selected(results[0]) == selected(results[1])
        if not versioned and not policy:
            # Different task graph passes may repeat an upstream event. The
            # reason/data contract is independent of event repetition counts.
            fields = ('contract_enforced_disabled', 'columns_removed', 'column_type_changes',
                      'enforced_column_constraint_removed', 'enforced_model_constraint_removed', 'breaking_changes')
            actual, expected = breaking_events(results[0])[0]['data'], breaking_events(results[1])[0]['data']
            assert {key: actual[key] for key in fields} == {key: expected.get(key, [] if key != 'contract_enforced_disabled' else False) for key in fields}
        if not versioned and not policy and selector_args is None:
            present = expected_id in selected(results[0])
            assert present is (method != 'unmodified' and 'deleted' not in expected_reason and 'disabled' not in expected_reason)


@pytest.mark.parametrize('versioned', [False, True])
@pytest.mark.parametrize('change,reason', [
    ('enforcement', 'Contract enforcement was removed'),
    ('column', 'Columns were removed'),
    ('type', 'Columns with data_type changes'),
    ('deleted', 'was deleted or renamed'),
    ('disabled', 'was disabled'),
    ('renamed', 'was deleted or renamed'),
])
def test_breaking_contract_changes_core_native(tmp_path, versioned, change, reason):
    root = project(tmp_path, versioned)
    state, original = baseline(root, tmp_path)
    schema = definition(versioned)
    model = schema['models'][0]
    if change == 'enforcement':
        model['config']['contract']['enforced'] = False
    elif change == 'column':
        model['columns'].pop()
    elif change == 'type':
        model['columns'][0]['data_type'] = 'bigint'
    elif change == 'disabled':
        model['config']['enabled'] = False
    else:
        source = root / 'models' / ('a_v1.sql' if versioned else 'a.sql')
        source.unlink()
        schema['models'].clear()
        if change == 'renamed':
            (root / 'models/replacement.sql').write_text('select 1 as id')
    write_schema(root, schema)
    compare(root, state, versioned, reason)
    assert (state / 'manifest.json').read_bytes() == original


@pytest.mark.parametrize('versioned', [False, True])
@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('change,reason', [
    ('column_constraint', 'Enforced column level constraints were removed'),
    ('model_constraint', 'Enforced model level constraints were removed'),
    ('materialization', 'Materialization changed with enforced constraints'),
])
def test_constraint_and_materialization_changes_core_native(tmp_path, versioned, adapter, change, reason):
    schema = definition(versioned)
    model = schema['models'][0]
    model['columns'][0]['constraints'] = [{'type': 'not_null', 'name': 'id_required'}, {'type': 'check', 'expression': 'id > 0'}]
    model['constraints'] = [{'type': 'primary_key', 'columns': ['id']}, {'type': 'unique', 'columns': ['label'], 'name': 'label_unique'}]
    root = project(tmp_path, versioned, adapter, schema)
    state, original = baseline(root, tmp_path)
    if change == 'column_constraint':
        model['columns'][0]['constraints'].clear()
    elif change == 'model_constraint':
        model['constraints'].clear()
    else:
        model['config']['materialized'] = 'view'
        for constraint in model['columns'][0]['constraints'] + model['constraints']:
            constraint['warn_unsupported'] = False
    write_schema(root, schema)
    compare(root, state, versioned, reason, methods=('modified.contract',))
    assert (state / 'manifest.json').read_bytes() == original


@pytest.mark.parametrize('origin', ['core', 'native'])
@pytest.mark.parametrize('change', ['add_column', 'add_constraint', 'enable', 'unenforced', 'reorder', 'materialization_without_constraints', 'deprecation_past', 'new_contracted', 'disabled_unenforced_current'])
def test_nonbreaking_contract_changes_core_native(tmp_path, origin, change):
    schema = definition(enforced=change not in {'enable', 'unenforced'})
    model = schema['models'][0]
    if change == 'reorder':
        model['columns'][0]['constraints'] = [{'type': 'not_null'}, {'type': 'check', 'expression': 'id > 0'}]
    if change == 'deprecation_past':
        model['deprecation_date'] = '2000-01-01T00:00:00Z'
    root = project(tmp_path, schema=schema)
    state, original = baseline(root, tmp_path, origin)
    if change == 'add_column':
        model['columns'].append({'name': 'extra', 'data_type': 'integer'})
    elif change == 'add_constraint':
        model['columns'][0]['constraints'] = [{'type': 'not_null'}]
    elif change == 'enable':
        model['config']['contract']['enforced'] = True
    elif change == 'unenforced':
        model['columns'].pop()
    elif change == 'reorder':
        model['columns'].reverse()
        model['columns'][1]['constraints'].reverse()
    elif change == 'materialization_without_constraints':
        model['config']['materialized'] = 'view'
    elif change == 'deprecation_past':
        (root / 'models/a.sql').unlink()
        schema['models'].clear()
    elif change == 'new_contracted':
        added = definition()['models'][0]
        added['name'] = 'new_model'
        schema['models'].append(added)
        (root / 'models/new_model.sql').write_text("select 1 as id, cast('one' as varchar) as label")
    elif change == 'disabled_unenforced_current':
        model['config']['enabled'] = False
        model['config']['contract']['enforced'] = False
    write_schema(root, schema)
    for method in METHODS:
        actual = invoke(root, 'ls', '--state', state, '--select', 'state:' + method, '--output', 'json', '--indirect-selection', 'empty')
        expected = invoke(root, 'ls', '--state', state, '--select', 'state:' + method, '--output', 'json', '--indirect-selection', 'empty', core=True)
        assert actual.returncode == expected.returncode == 0, actual.stderr + expected.stdout + expected.stderr
        assert not breaking_events(actual) and not breaking_events(expected)
        assert selected(actual) == selected(expected)
    assert (state / 'manifest.json').read_bytes() == original


@pytest.mark.parametrize('policy', [('--warn-error',), ('--warn-error-options', '{error: [UnversionedBreakingChange]}'),
                                    ('--warn-error-options', '{silence: [UnversionedBreakingChange]}'),
                                    ('--warn-error-options', '{error: all, warn: [UnversionedBreakingChange]}')])
def test_breaking_warning_policy_core_native(tmp_path, policy):
    root = project(tmp_path)
    state, _ = baseline(root, tmp_path)
    schema = definition()
    schema['models'][0]['columns'].pop()
    write_schema(root, schema)
    results = [invoke(root, 'ls', '--state', state, '--select', 'state:modified.contract', '--output', 'json',
                      core=core, policy=policy) for core in (False, True)]
    promoted = policy == ('--warn-error',) or policy[-1].startswith('{error: [')
    expected_code = 2 if promoted else 0
    assert results[0].returncode == results[1].returncode == expected_code, [r.stdout + r.stderr for r in results]
    assert selected(results[0]) == selected(results[1])
    if 'silence:' in policy[-1]:
        assert all('Columns were removed' not in r.stdout + r.stderr for r in results)
    else:
        assert all('Columns were removed' in r.stdout + r.stderr for r in results)


@pytest.mark.parametrize('selector_args', [('--select', '+state:modified.contract'),
                                           ('--exclude', 'state:modified.contract'),
                                           ('--selector', 'contract_changes'),
                                           ('--selector', 'exclude_contract_changes')])
def test_breaking_state_selector_boundaries_core_native(tmp_path, selector_args):
    root = project(tmp_path, versioned=True)
    state, _ = baseline(root, tmp_path)
    (root / 'selectors.yml').write_text('''selectors:
  - name: contract_changes
    definition:
      intersection:
        - method: state
          value: modified.contract
        - method: fqn
          value: a.v1
  - name: exclude_contract_changes
    definition:
      union:
        - '*'
        - exclude:
            - method: state
              value: modified.contract
''')
    schema = definition(True)
    schema['models'][0]['columns'].pop()
    write_schema(root, schema)
    compare(root, state, True, 'Columns were removed', methods=('modified.contract',), selector_args=selector_args)
    for method in ('new', 'old', 'modified.body', 'modified.configs', 'modified.relation', 'modified.macros', 'modified.persisted_descriptions'):
        results = [invoke(root, 'ls', '--state', state, '--select', 'state:' + method, '--output', 'json',
                          '--indirect-selection', 'empty', core=core) for core in (False, True)]
        assert results[0].returncode == results[1].returncode == 0
        assert selected(results[0]) == selected(results[1])
        assert all('Columns were removed' not in r.stdout + r.stderr for r in results)


def nested_contract_selector(root, method):
    # The exclusion belongs to one intersection branch, so native lowering
    # must keep it as a negated leaf inside the outer union.
    (root / 'selectors.yml').write_text(f'''selectors:
  - name: nested_contract
    definition:
      union:
        - intersection:
            - method: fqn
              value: '*'
            - exclude:
                - method: state
                  value: {method}
        - method: fqn
          value: other
''')


@pytest.mark.parametrize('versioned', [False, True])
@pytest.mark.parametrize('method', METHODS)
def test_nested_contract_exclusion_core_native(tmp_path, versioned, method):
    root = project(tmp_path, versioned)
    state, original = baseline(root, tmp_path)
    nested_contract_selector(root, method)
    schema = definition(versioned)
    schema['models'][0]['columns'].pop()
    write_schema(root, schema)
    results = [invoke(root, 'ls', '--state', state, '--selector', 'nested_contract',
                      '--output', 'json', '--indirect-selection', 'empty', core=core)
               for core in (True, False)]
    for result in results:
        assert result.returncode == (2 if versioned else 0), result.stdout + result.stderr
        assert 'Columns were removed' in result.stdout + result.stderr
        if versioned:
            assert 'Breaking change to contract Error in ' in result.stdout + result.stderr
            assert not selected(result)
        else:
            events = breaking_events(result)
            assert events and all(event['info']['code'] == 'I071' for event in events)
            assert all(event['data']['model_name'] == 'a' and event['data']['columns_removed'] == ['label']
                       for event in events)
            expected = {'model.state_contracts.other'}
            if method == 'unmodified':
                expected.add('model.state_contracts.a')
            assert selected(result) == expected
    assert (state / 'manifest.json').read_bytes() == original


@pytest.mark.parametrize('command', ['compile', 'run', 'build', 'docs'])
@pytest.mark.parametrize('promoted', [False, True])
def test_nested_contract_failure_preserves_artifacts_and_warehouse(tmp_path, command, promoted):
    import duckdb
    root = project(tmp_path, versioned=not promoted)
    state, original = baseline(root, tmp_path)
    nested_contract_selector(root, 'modified.contract')
    with duckdb.connect(str(root / 'warehouse.duckdb')) as connection:
        connection.execute('create schema analytics')
        connection.execute('create table analytics.sentinel as select 42 as id')
        connection.execute('create table analytics.other as select 11 as id')
    schema = definition(not promoted)
    schema['models'][0]['columns'].pop()
    (root / 'models' / ('a.sql' if promoted else 'a_v1.sql')).write_text('select 2 as id')
    # This independent union branch is selected even though the changed model
    # is excluded. Premature execution would delete the sentinel and replace
    # its existing relation, making both warehouse assertions meaningful.
    schema['models'].append({'name': 'other', 'config': {
        'materialized': 'table', 'pre-hook': 'delete from analytics.sentinel'}})
    write_schema(root, schema)
    args = ('generate',) if command == 'docs' else ()
    for core in (True, False):
        target = tmp_path / ('core-target' if core else 'native-target')
        target.mkdir()
        previous = {name: ('previous ' + name).encode()
                    for name in ('manifest.json', 'run_results.json', 'catalog.json')}
        for name, data in previous.items():
            (target / name).write_bytes(data)
        result = invoke(root, command, *args, '--state', state, '--selector', 'nested_contract',
                        core=core, target=target, policy=('--warn-error',) if promoted else ())
        assert result.returncode == 2, result.stdout + result.stderr
        assert 'Columns were removed' in result.stdout + result.stderr
        if not core:
            assert {name: (target / name).read_bytes() for name in previous} == previous
        assert (state / 'manifest.json').read_bytes() == original
        with duckdb.connect(str(root / 'warehouse.duckdb')) as connection:
            assert connection.execute('select * from analytics.sentinel').fetchall() == [(42,)]
            assert connection.execute('select * from analytics.other').fetchall() == [(11,)]
            assert connection.execute("select table_name from information_schema.tables "
                                      "where table_schema='analytics' order by table_name").fetchall() == [('other',), ('sentinel',)]


@pytest.fixture(scope='module')
def contract_postgres(tmp_path_factory):
    import postgres_fixture
    with postgres_fixture.get_server(tmp_path_factory.mktemp('state-contract-postgres') / 'data') as server:
        yield server


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('command', ['ls', 'compile', 'run', 'build', 'show', 'docs'])
@pytest.mark.parametrize('promoted', [False, True])
def test_contract_failure_preserves_artifacts_and_warehouse(tmp_path, command, promoted, adapter, request):
    import duckdb
    root = project(tmp_path, versioned=not promoted, adapter=adapter)
    if adapter == 'duckdb':
        def connect():
            return duckdb.connect(str(root / 'warehouse.duckdb'))
    else:
        import psycopg2
        from urllib.parse import unquote, urlparse
        server = request.getfixturevalue('contract_postgres')
        info = server.get_postmaster_info()
        user = unquote(urlparse(server.get_uri()).username or 'postgres')
        output = {'type': 'postgres', 'host': str(info.socket_dir), 'port': info.port,
                  'user': user, 'password': '', 'dbname': 'postgres', 'schema': 'analytics', 'threads': 1}
        (root / 'profiles.yml').write_text(json.dumps({'state_contracts': {'target': 'dev', 'outputs': {'dev': output}}}))
        def connect():
            return psycopg2.connect(server.get_uri())
    def query(sql):
        with connect() as connection:
            if adapter == 'duckdb':
                return connection.execute(sql).fetchall()
            with connection.cursor() as cursor:
                cursor.execute(sql)
                return cursor.fetchall() if cursor.description else []
    if adapter == 'postgres':
        query('drop schema if exists analytics cascade')
    query('create schema analytics')
    query('create table analytics.sentinel as select 42 as id')
    state, original = baseline(root, tmp_path)
    target = tmp_path / 'native-target'
    target.mkdir()
    previous = {name: ('previous ' + name).encode() for name in ('manifest.json', 'run_results.json', 'catalog.json')}
    for name, data in previous.items():
        (target / name).write_bytes(data)
    schema = definition(not promoted)
    schema['models'][0]['columns'].pop()
    # Any prematurely executed hook makes independent warehouse evidence fail.
    schema['models'][0]['config']['pre-hook'] = 'delete from analytics.sentinel'
    (root / 'models' / ('a.sql' if promoted else 'a_v1.sql')).write_text('select 2 as id')
    write_schema(root, schema)
    args = ('generate',) if command == 'docs' else ()
    result = invoke(root, command, *args, '--state', state, '--select', 'state:modified.contract',
                    target=target, policy=('--warn-error',) if promoted else ())
    assert result.returncode == 2, result.stdout + result.stderr
    assert 'Columns were removed' in result.stdout + result.stderr
    assert {name: (target / name).read_bytes() for name in previous} == previous
    assert (state / 'manifest.json').read_bytes() == original
    assert query('select * from analytics.sentinel') == [(42,)]
    assert query("select table_name from information_schema.tables where table_schema='analytics'") == [('sentinel',)]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('level', ['model', 'column'])
def test_removed_foreign_key_core_native(tmp_path, adapter, level):
    schema = definition()
    constraint = {'type': 'foreign_key', 'name': 'parent_fk', 'to': "ref('other')", 'to_columns': ['id']}
    location = schema['models'][0] if level == 'model' else schema['models'][0]['columns'][0]
    if level == 'model':
        constraint['columns'] = ['id']
    location['constraints'] = [constraint]
    root = project(tmp_path, adapter=adapter, schema=schema)
    state, _ = baseline(root, tmp_path)
    location['constraints'].clear()
    write_schema(root, schema)
    compare(root, state, False, 'Enforced ' + level + ' level constraints were removed', methods=('modified.contract',))


def assert_authored_manifest(root):
    manifest = json.loads((root / 'native-current/manifest.json').read_text())
    assert set(manifest['nodes']) == {'model.state_contracts.a', 'model.state_contracts.other'}
    for mapping in ('parent_map', 'child_map'):
        assert not any(key.startswith('sql_operation.') for key in manifest[mapping])
        assert not any(node.startswith('sql_operation.') for nodes in manifest[mapping].values() for node in nodes)


@pytest.mark.parametrize('command,query', [
    ('show', 'select missing_column'),
    ('show', "select * from {{ ref('not_found') }}"),
    ('compile', "select * from {{ ref('not_found') }}"),
    ('compile', "{{ exceptions.raise_compiler_error('inline failure') }}"),
])
def test_inline_failure_publishes_only_authored_manifest_core_native(tmp_path, command, query):
    root = project(tmp_path)
    for core in (False, True):
        result = invoke(root, command, '--inline', query, core=core)
        assert result.returncode == 2, result.stdout + result.stderr
        target = root / ('core-current' if core else 'native-current')
        manifest = json.loads((target / 'manifest.json').read_text())
        assert set(manifest['nodes']) == {'model.state_contracts.a', 'model.state_contracts.other'}
        for mapping in ('parent_map', 'child_map'):
            assert not any(key.startswith('sql_operation.') for key in manifest[mapping])
            assert not any(node.startswith('sql_operation.') for nodes in manifest[mapping].values() for node in nodes)
        assert not (target / 'run_results.json').exists()


def test_show_missing_selection_preserves_authored_publication(tmp_path):
    root = project(tmp_path)
    result = invoke(root, 'show')
    assert result.returncode == 2, result.stdout + result.stderr
    assert_authored_manifest(root)
    assert not (root / 'native-current/run_results.json').exists()


@pytest.mark.parametrize('command', ['show', 'compile'])
@pytest.mark.parametrize('contract_selector', [False, True])
def test_inline_empty_selection_keeps_operation_out_of_authored_manifest(tmp_path, command, contract_selector):
    root = project(tmp_path)
    if contract_selector:
        state, _ = baseline(root, tmp_path)
        schema = definition(enforced=False)
        write_schema(root, schema)
        args = ('--state', state, '--select', 'state:modified.contract')
    else:
        args = ('--select', 'tag:missing')
    # Native inline selection can legitimately be empty. The temporary node
    # must stay out of artifacts even when final success cleanup is not reached.
    result = invoke(root, command, '--inline', 'select 7 as id', *args)
    assert result.returncode == 0, result.stdout + result.stderr
    assert_authored_manifest(root)
    assert json.loads((root / 'native-current/run_results.json').read_text())['results'] == []


@pytest.mark.parametrize('command,inline', [('show', False), ('show', True), ('compile', True)])
def test_invalid_named_selector_preserves_authored_sql_operation_publication(tmp_path, command, inline):
    root = project(tmp_path)
    args = ('--inline', 'select 7 as id') if inline else ()
    result = invoke(root, command, *args, '--selector', 'missing_selector')
    assert result.returncode == 2, result.stdout + result.stderr
    assert_authored_manifest(root)
    assert not (root / 'native-current/run_results.json').exists()

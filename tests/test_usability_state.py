"""Black-box evidence for manifest comparison, freshness state, and deferral."""
import json
import shutil
import subprocess
from pathlib import Path

import pytest

from cli_helpers import json_lines
from test_cli import DXT, ROOT, build_dxt, write_sources_state  # noqa: F401


def project(tmp_path: Path) -> Path:
    root = tmp_path / 'project'
    (root / 'models').mkdir(parents=True)
    (root / 'dbt_project.yml').write_text('name: usability_state\nversion: 1.0.0\nconfig-version: 2\nprofile: default\n')
    (root / 'profiles.yml').write_text(f'default:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n      path: {root / "warehouse.duckdb"}\n      schema: dev\n    prod:\n      type: duckdb\n      path: {root / "warehouse.duckdb"}\n      schema: prod\n')
    (root / 'models' / 'a.sql').write_text('select 1 as id\n')
    (root / 'models' / 'b.sql').write_text("select * from {{ ref('a') }}\n")
    return root


def invoke(root: Path, command: str, *args: str):
    return subprocess.run([str(DXT), command, '--project-dir', str(root), *map(str, args)], cwd=ROOT, text=True, capture_output=True)


def ids(root: Path, *args: str) -> set[str]:
    result = invoke(root, 'ls', '--output', 'json', '--indirect-selection', 'empty', *args)
    assert result.returncode == 0, result.stderr
    return {item['unique_id'] for item in json_lines(result.stdout)}


def core_ids(root: Path, target: Path, *args: str) -> set[str]:
    result = subprocess.run(['dbt', '--quiet', 'ls', '--project-dir', str(root), '--profiles-dir', str(root), '--target-path', str(target), '--output', 'json', *map(str, args)], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    return {json.loads(line)['unique_id'] for line in result.stdout.splitlines() if line.startswith('{')}


def selected_ids(root: Path, *args: str) -> set[str]:
    result = invoke(root, 'ls', '--output', 'json', *args)
    assert result.returncode == 0, result.stderr
    return {item['unique_id'] for item in json_lines(result.stdout)}


def test_state_comparison_body_configuration_relation_and_membership(tmp_path):
    root = project(tmp_path)
    state = tmp_path / 'state'
    assert invoke(root, 'parse', '--target-path', state).returncode == 0
    (root / 'models' / 'a.sql').write_text('select 2 as id\n')
    (root / 'models' / 'c.sql').write_text('select 3 as id\n')
    common = ['--state', state, '--resource-type', 'model']
    assert ids(root, *common, '--select', 'state:new') == {'model.usability_state.c'}
    assert ids(root, *common, '--select', 'state:old') == {'model.usability_state.a', 'model.usability_state.b'}
    assert ids(root, *common, '--select', 'state:modified') == {'model.usability_state.a', 'model.usability_state.c'}
    assert ids(root, *common, '--select', 'state:modified.body') == {'model.usability_state.a', 'model.usability_state.c'}
    assert ids(root, *common, '--select', 'state:unmodified') == {'model.usability_state.b'}
    assert ids(root, *common, '--select', 'state:modified.configs') == {'model.usability_state.c'}
    assert ids(root, *common, '--select', 'state:modified.relation') == {'model.usability_state.c'}
    (root / 'models' / 'b.sql').write_text("{{ config(alias='renamed') }}\nselect * from {{ ref('a') }}\n")
    assert ids(root, *common, '--select', 'state:modified.relation') == {'model.usability_state.b', 'model.usability_state.c'}
    # Alias is part of relation comparison and SQL body, but excluded from configs.
    assert ids(root, *common, '--select', 'state:modified.configs') == {'model.usability_state.c'}


def test_state_macro_changes_follow_transitive_dependencies(tmp_path):
    root = project(tmp_path)
    (root / 'macros').mkdir()
    (root / 'macros' / 'helpers.sql').write_text('{% macro inner() %}1{% endmacro %}\n{% macro outer() %}{{ inner() }}{% endmacro %}\n')
    (root / 'models' / 'a.sql').write_text('select {{ outer() }} as id\n')
    state = tmp_path / 'state'
    assert invoke(root, 'parse', '--target-path', state).returncode == 0
    (root / 'macros' / 'helpers.sql').write_text('{% macro inner() %}2{% endmacro %}\n{% macro outer() %}{{ inner() }}{% endmacro %}\n')
    assert ids(root, '--state', state, '--select', 'state:modified.macros') == {'model.usability_state.a'}
    assert ids(root, '--state', state, '--select', 'state:modified.body') == set()
    assert ids(root, '--state', state, '--select', 'state:modified') == {'model.usability_state.a'}


def test_fresher_compares_current_and_previous_artifacts(tmp_path):
    root = project(tmp_path)
    (root / 'models' / 'sources.yml').write_text('version: 2\nsources:\n  - name: raw\n    tables:\n      - name: orders\n      - name: customers\n      - name: failed\n')
    state = tmp_path / 'state'; state.mkdir()
    current = tmp_path / 'current'; current.mkdir()
    def freshness(path, rows):
        (path / 'sources.json').write_text(json.dumps({'metadata': {'dbt_schema_version': 'https://schemas.getdbt.com/dbt/sources/v3.json'}, 'results': rows}))
    def row(name, timestamp, status='pass'):
        result = {'unique_id': f'source.usability_state.raw.{name}', 'status': status}
        if timestamp is not None: result['max_loaded_at'] = timestamp
        return result
    freshness(state, [row('orders', '2026-01-01T00:00:00Z'), row('customers', '2026-01-01T00:00:00Z')])
    freshness(current, [row('orders', '2026-01-01T01:00:00+00:00'), row('customers', '2025-12-31T21:00:00-03:00'), row('failed', None, 'runtime error')])
    assert ids(root, '--state', state, '--target-path', current, '--select', 'source_status:fresher') == {'source.usability_state.raw.orders'}
    (current / 'sources.json').unlink()
    error = invoke(root, 'ls', '--state', state, '--target-path', current, '--select', 'source_status:fresher')
    assert error.returncode == 2 and 'current target sources.json' in error.stderr


def test_state_missing_and_malformed_artifacts_fail(tmp_path):
    root = project(tmp_path)
    assert invoke(root, 'ls', '--select', 'state:modified').returncode == 2
    state = tmp_path / 'missing'; state.mkdir()
    result = invoke(root, 'ls', '--state', state, '--select', 'state:old')
    assert result.returncode == 2 and 'manifest.json' in result.stderr
    (state / 'manifest.json').write_text('{}')
    result = invoke(root, 'ls', '--state', state, '--select', 'state:modified')
    assert result.returncode == 2 and 'malformed' in result.stderr


@pytest.mark.skipif(shutil.which('duckdb') is None, reason='DuckDB CLI required')
def test_defer_favor_state_separate_artifact_and_selected_identity(tmp_path):
    root = project(tmp_path)
    state = tmp_path / 'state'
    result = invoke(root, 'run', '--target', 'prod', '--target-path', state)
    assert result.returncode == 0, result.stderr
    target = tmp_path / 'compiled'
    def compile_sql(*args):
        result = invoke(root, 'compile', '--target-path', target, '--defer', '--state', state, *args)
        assert result.returncode == 0, result.stderr
        return (target / 'compiled' / 'usability_state' / 'models' / 'b.sql').read_text()
    assert '"prod"."a"' in compile_sql('--select', 'b')
    subprocess.run(['duckdb', str(root / 'warehouse.duckdb'), '-c', 'create schema dev; create table dev.a as select 9 as id;'], check=True, capture_output=True)
    assert '"dev"."a"' in compile_sql('--select', 'b')
    assert '"prod"."a"' in compile_sql('--select', 'b', '--favor-state')
    assert '"dev"."a"' in compile_sql('--select', 'a', 'b', '--favor-state')
    separate = tmp_path / 'defer'; separate.mkdir()
    artifact = json.loads((state / 'manifest.json').read_text())
    artifact['nodes']['model.usability_state.a']['relation_name'] = '"archive"."a"'
    (separate / 'manifest.json').write_text(json.dumps(artifact))
    assert '"archive"."a"' in compile_sql('--select', 'b', '--favor-state', '--defer-state', separate)
    result = invoke(root, 'compile', '--defer', '--select', 'b')
    assert result.returncode == 2 and '--state or --defer-state' in result.stderr


def test_nested_yaml_selector_operations_default_and_references(tmp_path):
    root = project(tmp_path)
    (root / 'models' / 'c.sql').write_text('select 3 as id\n')
    (root / 'selectors.yml').write_text('''selectors:
  - name: baseline
    definition:
      union:
        - a
        - b
  - name: composed
    default: true
    definition:
      union:
        - intersection:
            - method: selector
              value: baseline
            - union:
                - a
                - c
        - intersection:
            - b
            - union:
                - a
                - b
                - exclude:
                    - a
''')
    assert ids(root) == {'model.usability_state.a', 'model.usability_state.b'}
    assert ids(root, '--selector', 'baseline') == {'model.usability_state.a', 'model.usability_state.b'}
    assert ids(root, '--select', 'c') == {'model.usability_state.c'}


@pytest.mark.skipif(shutil.which('dbt') is None, reason='pinned Core oracle required')
def test_state_core_oracle(tmp_path):
    root = project(tmp_path)
    state = tmp_path / 'core-state'
    result = subprocess.run(['dbt', '--quiet', 'parse', '--project-dir', str(root), '--profiles-dir', str(root), '--target-path', str(state)], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    (root / 'models' / 'a.sql').write_text('select 2 as id\n')
    (root / 'models' / 'c.sql').write_text('select 3 as id\n')
    for method in ['new', 'old', 'modified', 'unmodified', 'modified.body', 'modified.configs', 'modified.relation', 'modified.macros', 'modified.contract', 'modified.persisted_descriptions']:
        result = subprocess.run(['dbt', '--quiet', 'ls', '--project-dir', str(root), '--profiles-dir', str(root), '--target-path', str(tmp_path / 'core-current'), '--state', str(state), '--select', f'state:{method}', '--output', 'json', '--indirect-selection', 'empty'], text=True, capture_output=True)
        assert result.returncode == 0, result.stdout + result.stderr
        expected = {json.loads(line)['unique_id'] for line in result.stdout.splitlines() if line.startswith('{')}
        assert ids(root, '--state', state, '--select', f'state:{method}') == expected, method


@pytest.mark.skipif(shutil.which('dbt') is None, reason='pinned Core oracle required')
def test_indirect_modes_and_yaml_leaf_scope_core_oracle(tmp_path):
    root = project(tmp_path)
    (root / 'models' / 'c.sql').write_text('select 3 as id\n')
    (root / 'tests').mkdir()
    (root / 'tests' / 'cross.sql').write_text("select a.id from {{ ref('a') }} a join {{ ref('c') }} c using(id) where false\n")
    (root / 'tests' / 'upstream.sql').write_text("select b.id from {{ ref('b') }} b join {{ ref('a') }} a using(id) where false\n")
    (root / 'models' / 'schema.yml').write_text('''version: 2
models:
  - name: a
    columns:
      - name: id
        data_tests:
          - not_null
sources:
  - name: raw
    schema: raw
    tables:
      - name: orders
''')
    (root / 'tests' / 'external.sql').write_text("select a.id from {{ ref('a') }} a join {{ source('raw', 'orders') }} o using(id) where false\n")
    (root / 'selectors.yml').write_text('''selectors:
  - name: eager_intersection
    definition:
      intersection:
        - method: fqn
          value: a
          indirect_selection: eager
        - method: fqn
          value: c
          indirect_selection: eager
  - name: mixed
    definition:
      union:
        - method: fqn
          value: a
          indirect_selection: empty
        - method: fqn
          value: c
          indirect_selection: cautious
  - name: mixed_eager
    definition:
      union:
        - method: fqn
          value: a
          indirect_selection: empty
        - method: fqn
          value: c
          indirect_selection: eager
  - name: neighborhood
    definition:
      method: fqn
      value: a
      children: true
      children_depth: 1
      indirect_selection: buildable
  - name: scoped_exclusion
    definition:
      union:
        - intersection:
            - method: fqn
              value: a
              indirect_selection: eager
            - method: fqn
              value: c
              indirect_selection: eager
        - b
        - exclude:
            - upstream
''')
    current = tmp_path / 'core-current'
    for mode in ['eager', 'cautious', 'buildable', 'empty']:
        for expression in ['a', 'b', 'a c', 'a,c', '+b']:
            args = ('--select', expression, '--indirect-selection', mode)
            assert selected_ids(root, *args) == core_ids(root, current, *args), (mode, expression)
    for name in ['eager_intersection', 'mixed', 'mixed_eager', 'neighborhood', 'scoped_exclusion']:
        args = ('--selector', name, '--indirect-selection', 'empty')
        assert selected_ids(root, *args) == core_ids(root, current, *args), name


@pytest.mark.skipif(shutil.which('dbt') is None, reason='pinned Core oracle required')
def test_persisted_descriptions_and_unit_fixture_state_core_oracle(tmp_path):
    root = project(tmp_path)
    schema = root / 'models' / 'schema.yml'
    schema.write_text('''version: 2
models:
  - name: a
    description: Before
    config:
      persist_docs:
        relation: true
        columns: true
    columns:
      - name: id
        description: Before
unit_tests:
  - name: b_fixture
    model: b
    given:
      - input: ref('a')
        rows:
          - {id: 1}
    expect:
      rows:
        - {id: 1}
''')
    state = tmp_path / 'state'
    result = subprocess.run(['dbt', '--quiet', 'parse', '--project-dir', str(root), '--profiles-dir', str(root), '--target-path', str(state)], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    for method in ['modified', 'modified.persisted_descriptions']:
        args = ('--state', state, '--select', f'state:{method}', '--indirect-selection', 'empty')
        assert selected_ids(root, *args) == core_ids(root, tmp_path / 'core-current', *args)

    schema.write_text(schema.read_text().replace('Before', 'After').replace('{id: 1}', '{id: 2}'))
    for method in ['modified', 'modified.persisted_descriptions']:
        args = ('--state', state, '--select', f'state:{method}', '--indirect-selection', 'empty')
        assert selected_ids(root, *args) == core_ids(root, tmp_path / 'core-current', *args)


@pytest.mark.skipif(shutil.which('dbt') is None, reason='pinned Core oracle required')
def test_source_and_exposure_state_core_oracle(tmp_path):
    root = project(tmp_path)
    schema = root / 'models' / 'sources.yml'
    schema.write_text('''version: 2
sources:
  - name: raw
    tables:
      - name: orders
exposures:
  - name: dashboard
    type: dashboard
    owner:
      name: Analytics
      email: analytics@example.com
    depends_on:
      - ref('a')
''')
    state = tmp_path / 'core-state'
    result = subprocess.run(['dbt', '--quiet', 'parse', '--project-dir', str(root), '--profiles-dir', str(root), '--target-path', str(state)], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    for method in ['modified', 'unmodified', 'modified.configs', 'modified.relation']:
        args = ('--state', state, '--select', f'state:{method}', '--indirect-selection', 'empty')
        assert selected_ids(root, *args) == core_ids(root, tmp_path / 'core-current', *args), method
    schema.write_text(schema.read_text().replace('  - name: raw', '  - name: raw\n    schema: changed').replace('name: Analytics', 'name: Changed'))
    args = ('--state', state, '--select', 'state:modified', '--indirect-selection', 'empty')
    assert selected_ids(root, *args) == core_ids(root, tmp_path / 'core-current', *args)


@pytest.mark.skipif(shutil.which('dbt') is None, reason='pinned Core oracle required')
def test_fresher_core_oracle_with_sources_v3_artifacts(tmp_path):
    root = project(tmp_path)
    (root / 'models' / 'sources.yml').write_text('version: 2\nsources:\n  - name: raw\n    tables:\n      - name: orders\n      - name: new_orders\n')
    state = tmp_path / 'state'
    current = tmp_path / 'current'
    write_sources_state(state, {'source.usability_state.raw.orders': 'pass'})
    write_sources_state(current, {'source.usability_state.raw.orders': 'pass', 'source.usability_state.raw.new_orders': 'warn'})
    args = ('--state', state, '--target-path', current, '--select', 'source_status:fresher', '--indirect-selection', 'empty')
    assert selected_ids(root, *args) == core_ids(root, current, '--state', state, '--select', 'source_status:fresher', '--indirect-selection', 'empty')
    artifact = json.loads((current / 'sources.json').read_text())
    artifact['results'][0]['max_loaded_at'] = '2026-06-17T13:00:00Z'
    (current / 'sources.json').write_text(json.dumps(artifact))
    assert selected_ids(root, *args) == core_ids(root, current, '--state', state, '--select', 'source_status:fresher', '--indirect-selection', 'empty')


@pytest.mark.skipif(shutil.which('dbt') is None or shutil.which('duckdb') is None, reason='Core and DuckDB required')
def test_defer_core_oracle_with_real_relations(tmp_path):
    root = project(tmp_path)
    warehouse = root / 'warehouse.duckdb'
    profiles = root / 'profiles.yml'
    profiles.write_text(profiles.read_text().replace(f'path: {root / "warehouse.duckdb"}', f'path: {warehouse}'))
    state = tmp_path / 'core-state'
    def core(command, target, *args):
        result = subprocess.run(['dbt', '--quiet', command, '--project-dir', str(root), '--profiles-dir', str(root), '--target-path', str(target), *map(str, args)], text=True, capture_output=True)
        assert result.returncode == 0, result.stdout + result.stderr
    core('run', state, '--target', 'prod')
    def compiled(target):
        return (target / 'compiled' / 'usability_state' / 'models' / 'b.sql').read_text()
    def compare(expected, *args):
        native = tmp_path / 'native'
        oracle = tmp_path / 'oracle'
        common = ('--defer', '--state', state, *args)
        result = invoke(root, 'compile', '--target-path', native, *common)
        assert result.returncode == 0, result.stderr
        core('compile', oracle, *common)
        assert expected in compiled(native)
        assert expected in compiled(oracle)
    compare('"prod"."a"', '--select', 'b')
    core('run', tmp_path / 'dev', '--target', 'dev')
    compare('"dev"."a"', '--select', 'b')
    compare('"prod"."a"', '--select', 'b', '--favor-state')
    compare('"dev"."a"', '--select', 'a', 'b', '--favor-state')


@pytest.mark.skipif(shutil.which('dbt') is None, reason='pinned Core oracle required')
def test_generic_test_configuration_state_core_oracle(tmp_path):
    root = project(tmp_path)
    schema = root / 'models' / 'schema.yml'
    schema.write_text('''version: 2
models:
  - name: a
    columns:
      - name: id
        data_tests:
          - not_null:
              config:
                severity: ERROR
''')
    state = tmp_path / 'core-state'
    result = subprocess.run(['dbt', '--quiet', 'parse', '--project-dir', str(root), '--profiles-dir', str(root), '--target-path', str(state)], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    for changed in [False, True]:
        if changed: schema.write_text(schema.read_text().replace('severity: ERROR', 'severity: WARN'))
        for method in ['modified', 'modified.configs', 'modified.body', 'unmodified']:
            args = ('--state', state, '--select', f'state:{method}', '--indirect-selection', 'empty')
            assert selected_ids(root, *args) == core_ids(root, tmp_path / 'core-current', *args), (changed, method)


@pytest.mark.skipif(shutil.which('dbt') is None, reason='pinned Core oracle required')
@pytest.mark.parametrize('field,value', [
    ('latest_version', 2), ('access', 'public'),
    ('deprecation_date', '2099-01-01T00:00:00Z'),
])
def test_model_reference_metadata_state_core_oracle(tmp_path, field, value):
    root = project(tmp_path)
    (root / 'models' / 'a_v1.sql').write_text('select 1 as id')
    (root / 'models' / 'a_v2.sql').write_text('select 2 as id')
    (root / 'models' / 'a.sql').unlink()
    definition = {'name': 'a', 'latest_version': 1, 'access': 'protected',
                  'versions': [{'v': 1}, {'v': 2}]}
    if field == 'deprecation_date':
        definition['deprecation_date'] = '2098-01-01'
    schema = root / 'models' / 'schema.yml'
    schema.write_text(json.dumps({'version': 2, 'models': [definition]}))
    state = tmp_path / 'core-state'
    result = subprocess.run(['dbt', '--quiet', 'parse', '--project-dir', str(root),
                             '--profiles-dir', str(root), '--target-path', str(state)],
                            text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    if field == 'deprecation_date':
        definition['versions'][0][field] = value
    else:
        definition[field] = value
    schema.write_text(json.dumps({'version': 2, 'models': [definition]}))
    for method in ['modified', 'unmodified', 'modified.body', 'modified.configs', 'modified.relation']:
        args = ('--state', state, '--select', f'state:{method}', '--indirect-selection', 'empty')
        expected = core_ids(root, tmp_path / 'core-current', *args)
        assert selected_ids(root, *args) == expected, (field, method)
        if method == 'modified':
            affected = {'model.usability_state.a.v1'} if field == 'deprecation_date' else {'model.usability_state.a.v1', 'model.usability_state.a.v2'}
            assert affected <= expected


def semantic_state_definition():
    return {
        'version': 2,
        'groups': [{'name': name, 'owner': {'name': 'Analytics'}} for name in ['first', 'second']],
        'semantic_models': [{
            'name': 'events', 'model': "ref('a')", 'description': 'Before',
            'defaults': {'agg_time_dimension': 'event_time'},
            'entities': [{'name': 'event', 'type': 'primary', 'expr': 'id'},
                         {'name': 'customer', 'type': 'foreign', 'expr': 'id'}],
            'dimensions': [{'name': 'event_time', 'type': 'time',
                            'type_params': {'time_granularity': 'day'}}],
            'measures': [{'name': 'amount', 'agg': 'sum', 'expr': 'id'}],
            'config': {'group': 'first', 'meta': {'rendered': "{{ var('state_value', 'before') }}"}},
        }],
        'metrics': [{'name': 'revenue', 'label': 'Revenue', 'description': 'Before',
                     'type': 'simple', 'type_params': {'measure': 'amount'},
                     'config': {'group': 'first', 'meta': {'owner': 'before'}}}],
        'saved_queries': [{
            'name': 'daily', 'label': 'Daily', 'description': 'Before',
            'query_params': {'metrics': ['revenue'],
                             'group_by': ["TimeDimension('metric_time', 'day')"], 'limit': 10},
            'exports': [{'name': 'first', 'config': {'export_as': 'table', 'schema': 'reporting'}},
                        {'name': 'second', 'config': {'export_as': 'table', 'schema': 'reporting'}}],
            'config': {'group': 'first', 'tags': ['a', 'b'],
                       'meta': {'rendered': "{{ var('state_value', 'before') }}"}},
        }],
    }


@pytest.mark.skipif(shutil.which('dbt') is None, reason='pinned Core oracle required')
@pytest.mark.parametrize('kind,change', [
    ('semantic_models', 'description'), ('semantic_models', 'entity_order'),
    ('semantic_models', 'measure'), ('semantic_models', 'group'),
    ('semantic_models', 'rendered_config'),
    ('metrics', 'description'), ('metrics', 'label'), ('metrics', 'group'),
    ('metrics', 'meta'), ('metrics', 'filter'), ('metrics', 'type_params'),
    ('saved_queries', 'description'), ('saved_queries', 'group'),
    ('saved_queries', 'rendered_config'), ('saved_queries', 'tags_order'),
    ('saved_queries', 'where'), ('saved_queries', 'limit'),
    ('saved_queries', 'export_order'), ('saved_queries', 'export_schema'),
])
def test_semantic_resource_state_core_oracle(tmp_path, kind, change):
    root = project(tmp_path)
    (root / 'models' / 'a.sql').write_text("select 1 as id, date '2024-01-01' as event_time")
    (root / 'models' / 'metricflow_time_spine.sql').write_text("select date '2024-01-01' as date_day")
    definition = semantic_state_definition()
    schema = root / 'models' / 'schema.yml'
    schema.write_text(json.dumps(definition))
    state = tmp_path / 'core-state'
    result = subprocess.run(['dbt', '--quiet', 'parse', '--project-dir', str(root),
                             '--profiles-dir', str(root), '--target-path', str(state)],
                            text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    resource = definition[kind][0]
    extra = ()
    if change in ['description', 'label']:
        resource[change] = 'After'
    elif change == 'entity_order':
        resource['entities'].reverse()
    elif change == 'measure':
        resource['measures'][0]['expr'] = 'id * 2'
    elif change == 'group':
        resource['config']['group'] = 'second'
    elif change == 'rendered_config':
        extra = ('--vars', '{state_value: after}')
    elif change == 'meta':
        resource['config']['meta']['owner'] = 'after'
    elif change == 'filter':
        resource['filter'] = "{{ Dimension('event__event_time') }} > '2020-01-01'"
    elif change == 'type_params':
        resource['type_params']['measure'] = {'name': 'amount', 'filter': 'id > 0'}
    elif change == 'tags_order':
        resource['config']['tags'].reverse()
    elif change == 'where':
        resource['query_params']['where'] = "{{ TimeDimension('metric_time', 'day') }} > '2020-01-01'"
    elif change == 'limit':
        resource['query_params']['limit'] = 20
    elif change == 'export_order':
        resource['exports'].reverse()
    elif change == 'export_schema':
        resource['exports'][0]['config']['schema'] = 'after'
    schema.write_text(json.dumps(definition))
    for method in ['modified', 'modified.configs', 'unmodified']:
        args = ('--state', state, '--select', f'state:{method}', '--indirect-selection', 'empty', *extra)
        assert selected_ids(root, *args) == core_ids(root, tmp_path / 'core-current', *args), (kind, change, method)


@pytest.mark.skipif(shutil.which('dbt') is None, reason='pinned Core oracle required')
def test_new_semantic_resource_state_capabilities_core_oracle(tmp_path):
    root = project(tmp_path)
    state = tmp_path / 'core-state'
    result = subprocess.run(['dbt', '--quiet', 'parse', '--project-dir', str(root),
                             '--profiles-dir', str(root), '--target-path', str(state)],
                            text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    (root / 'models' / 'a.sql').write_text("select 1 as id, date '2024-01-01' as event_time")
    (root / 'models' / 'metricflow_time_spine.sql').write_text("select date '2024-01-01' as date_day")
    (root / 'models' / 'schema.yml').write_text(json.dumps(semantic_state_definition()))
    for method in ['new', 'old', 'modified', 'unmodified', 'modified.body', 'modified.configs',
                   'modified.relation', 'modified.macros', 'modified.contract', 'modified.persisted_descriptions']:
        args = ('--state', state, '--select', f'state:{method}', '--indirect-selection', 'empty')
        assert selected_ids(root, *args) == core_ids(root, tmp_path / 'core-current', *args), method


@pytest.mark.skipif(shutil.which('dbt') is None, reason='pinned Core oracle required')
@pytest.mark.parametrize('authored,tz,expected', [
    ('2099-01-02', 'UTC', '2099-01-02T00:00:00+00:00'),
    ('2099-01-02', 'America/New_York', '2099-01-02T00:00:00-05:00'),
    ('2099-01-02T03:04:05', 'America/New_York', '2099-01-02T03:04:05-05:00'),
    ('2099-01-02T03:04:05Z', 'America/New_York', '2099-01-02T03:04:05+00:00'),
    ('2099-01-02T03:04:05.123456+05:30', 'UTC', '2099-01-02T03:04:05.123456+05:30'),
    ('20990102T0304+0530', 'UTC', '2099-01-02T03:04:00+05:30'),
    (None, 'UTC', None),
])
def test_model_deprecation_metadata_context_and_warm_cache_core_oracle(tmp_path, monkeypatch, authored, tz, expected):
    monkeypatch.setenv('TZ', tz)
    root = project(tmp_path)
    schema = root / 'models' / 'schema.yml'
    schema.write_text(json.dumps({'version': 2, 'models': [{'name': 'a', 'deprecation_date': authored}]}))
    native = tmp_path / 'native'
    core = tmp_path / 'core'
    def parse_pair():
        result = invoke(root, 'parse', '--target-path', native)
        assert result.returncode == 0, result.stdout + result.stderr
        reference = subprocess.run(['dbt', '--quiet', 'parse', '--project-dir', str(root),
                                    '--profiles-dir', str(root), '--target-path', str(core)],
                                   text=True, capture_output=True)
        assert reference.returncode == 0, reference.stdout + reference.stderr
        actual = json.loads((native / 'manifest.json').read_text())['nodes']['model.usability_state.a']
        upstream = json.loads((core / 'manifest.json').read_text())['nodes']['model.usability_state.a']
        assert actual['deprecation_date'] == upstream['deprecation_date']
        return actual['deprecation_date']
    assert parse_pair() == expected
    assert parse_pair() == expected  # unchanged warm native and Core parse caches
    schema.write_text(json.dumps({'version': 2, 'models': [{'name': 'a', 'deprecation_date': '2099-12-31T00:00:00Z'}]}))
    assert parse_pair() == '2099-12-31T00:00:00+00:00'  # property-only cache invalidation
    (root / 'models' / 'a.sql').write_text("select '{{ model.deprecation_date }}' as date")
    result = invoke(root, 'compile', '--target-path', native, '--select', 'a')
    assert result.returncode == 0, result.stdout + result.stderr
    reference = subprocess.run(['dbt', '--quiet', 'compile', '--project-dir', str(root),
                                '--profiles-dir', str(root), '--target-path', str(core), '--select', 'a'],
                               text=True, capture_output=True)
    assert reference.returncode == 0, reference.stdout + reference.stderr
    actual = json.loads((native / 'manifest.json').read_text())['nodes']['model.usability_state.a']['compiled_code']
    upstream = json.loads((core / 'manifest.json').read_text())['nodes']['model.usability_state.a']['compiled_code']
    assert actual == upstream == "select '2099-12-31T00:00:00+00:00' as date"
    # Core's macro model context serializes the datetime to a string.
    (root / 'models' / 'a.sql').write_text("select '{{ model.deprecation_date.isoformat() }}' as date")
    result = invoke(root, 'compile', '--target-path', native, '--select', 'a')
    reference = subprocess.run(['dbt', '--quiet', 'compile', '--project-dir', str(root),
                                '--profiles-dir', str(root), '--target-path', str(core), '--select', 'a'],
                               text=True, capture_output=True)
    assert result.returncode == reference.returncode == 2



@pytest.mark.skipif(shutil.which('dbt') is None, reason='pinned Core oracle required')
@pytest.mark.parametrize('authored', ['bad', '2099-02-29', '2099-01-01T25:00:00', '2099-01-02T03:04:05+05:30:45.123456', 1])
def test_invalid_model_deprecation_metadata_core_oracle(tmp_path, authored):
    root = project(tmp_path)
    (root / 'models' / 'schema.yml').write_text(json.dumps({'version': 2, 'models': [{'name': 'a', 'deprecation_date': authored}]}))
    result = invoke(root, 'parse')
    reference = subprocess.run(['dbt', '--quiet', 'parse', '--project-dir', str(root), '--profiles-dir', str(root)],
                               text=True, capture_output=True)
    assert result.returncode == reference.returncode == 2


@pytest.mark.skipif(shutil.which('dbt') is None, reason='pinned Core oracle required')
def test_equivalent_aware_model_deprecation_state_core_oracle(tmp_path):
    root = project(tmp_path)
    schema = root / 'models' / 'schema.yml'
    schema.write_text(json.dumps({'version': 2, 'models': [{'name': 'a', 'deprecation_date': '2099-01-02T03:04:05.123456+05:30'}]}))
    state = tmp_path / 'core-state'
    result = subprocess.run(['dbt', '--quiet', 'parse', '--project-dir', str(root),
                             '--profiles-dir', str(root), '--target-path', str(state)], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    for authored, changed in [('2099-01-01T21:34:05.123456Z', False), ('2099-01-01T21:34:05.123457Z', True)]:
        schema.write_text(json.dumps({'version': 2, 'models': [{'name': 'a', 'deprecation_date': authored}]}))
        args = ('--state', state, '--select', 'state:modified', '--indirect-selection', 'empty')
        expected = core_ids(root, tmp_path / 'core-current', *args)
        assert ('model.usability_state.a' in expected) is changed
        assert selected_ids(root, *args) == expected

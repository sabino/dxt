"""Complete schema-test configs and disabled boundaries against pinned Core."""
import json
import subprocess
from pathlib import Path

import pytest

from cli_helpers import json_lines
from test_usability_commands import core_runner
from test_usability_artifacts import contracts

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / 'zig-out/bin/dxt'
FIELDS = ('config', 'unrendered_config', 'tags', 'meta', 'group', 'description',
          'fqn', 'raw_code', 'refs', 'sources', 'depends_on', 'name', 'alias',
          'path', 'schema', 'database', 'test_metadata', 'column_name', 'attached_node')


@pytest.fixture(scope='module', autouse=True)
def binary():
    subprocess.run(['zig', 'build'], cwd=ROOT, check=True)


def project_at(project, properties, config=''):
    (project / 'models/nested').mkdir(parents=True)
    (project / 'dbt_project.yml').write_text("name: config_tests\nversion: '1.0'\nprofile: config_tests\nvars: {disabled: false, threshold: 0}\n" + config)
    (project / 'profiles.yml').write_text(f"config_tests:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n      path: {project / 'warehouse.duckdb'}\n      schema: main\n      threads: 2\n")
    (project / 'models/base.sql').write_text("{{ config(materialized='table') }}select 1 as id")
    (project / 'models/nested/schema.yml').write_text(properties)


def native(project, command='parse', *extra):
    return subprocess.run([DXT, command, '--project-dir', str(project), '--profiles-dir', str(project),
                           '--target-path', 'native', *extra], capture_output=True, text=True)


def pair(project, runner):
    actual = native(project)
    expected = runner.invoke(['--quiet', 'parse', '--project-dir', str(project), '--profiles-dir', str(project),
                              '--target-path', 'core', '--no-partial-parse'])
    return actual, expected


def compare(project):
    actual = json.loads((project / 'native/manifest.json').read_text())
    expected = json.loads((project / 'core/manifest.json').read_text())
    contracts.assert_artifact(project / 'native/manifest.json')
    for section in ('nodes', 'disabled'):
        left = {key: value if section == 'nodes' else value[0] for key, value in actual[section].items()}
        right = {key: value if section == 'nodes' else value[0] for key, value in expected[section].items()}
        left = {key: node for key, node in left.items() if node['resource_type'] == 'test'}
        right = {key: node for key, node in right.items() if node['resource_type'] == 'test'}
        assert set(left) == set(right)
        for key, node in left.items():
            for field in FIELDS:
                assert node.get(field) == right[key].get(field), (key, field, node.get(field), right[key].get(field))
    assert actual['parent_map'] == expected['parent_map']
    assert actual['child_map'] == expected['child_map']
    assert {key: sorted(value) for key, value in actual['group_map'].items()} == {
        key: sorted(value) for key, value in expected['group_map'].items()}
    return actual, expected


CONFIG = '''data_tests:
  +tags: [global, same]
  +meta: {owner: project, nested: {a: 1}}
  config_tests:
    nested:
      +severity: warn
      +tags: nested
'''
PROPERTIES = '''version: 2
groups: [{name: finance, owner: {name: Finance}}]
models:
  - name: base
    config: {tags: [model], group: finance}
    columns:
      - name: id
        tags: [column, same]
        data_tests:
          - not_null:
              name: custom_check
              description: describe me
              config:
                tags: [local, same]
                meta: {owner: authored, nested: {b: 2}}
                custom: {deep: [1, false]}
                group: finance
          - unique: {config: {enabled: "{{ var('disabled') }}", tags: disabled}}
sources:
  - name: raw
    schema: main
    tables:
      - name: base
        columns:
          - name: id
            tags: [source_column]
            data_tests:
              - not_null: {name: disabled_source, config: {enabled: false, meta: {source: true}}}
'''


def test_complete_configs_names_columns_and_disabled_artifacts_match_core(tmp_path, core_runner):
    project = tmp_path / 'project'
    project_at(project, PROPERTIES, CONFIG)
    actual, expected = pair(project, core_runner)
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    first, _ = compare(project)
    assert native(project).returncode == 0
    second = json.loads((project / 'native/manifest.json').read_text())
    assert {key: value for key, value in first.items() if key != 'metadata'} == {
        key: value for key, value in second.items() if key != 'metadata'}


@pytest.mark.parametrize('selector', ['tag:column', 'tag:local', 'config.tags:global', 'config.severity:warn',
                                     'config.custom.deep:1', 'config.custom.deep:true', 'config.severity:WARN', 'test_name:not_null', 'test_type:schema', 'fqn:config_tests.nested.custom_check',
                                     'custom_check+', 'unique_base_id'])
def test_config_tags_fqn_and_disabled_selectors_match_core(tmp_path, core_runner, selector):
    project = tmp_path / 'project'
    project_at(project, PROPERTIES, CONFIG)
    common = ['ls', '--project-dir', str(project), '--profiles-dir', str(project), '--resource-type', 'test',
              '--select', selector, '--output', 'json', '--output-keys', 'unique_id', 'config']
    actual = subprocess.run([DXT, *common, '--target-path', 'native'], capture_output=True, text=True)
    expected = core_runner.invoke(['--quiet', *common, '--target-path', 'core'])
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    left = {node['unique_id']: node['config'] for node in json_lines(actual.stdout)}
    right = {node['unique_id']: node['config'] for node in map(json.loads, expected.result)}
    # Listing retains the complete typed config, including configuration tags
    # separately from top-level column tags.
    assert left == right


def test_parse_time_macro_config_precedence_and_runtime_config_get(tmp_path, core_runner):
    project = tmp_path / 'project'
    project_at(project, '''version: 2
models:
  - name: base
    columns:
      - name: id
        tags: [column]
        data_tests:
          - check:
              threshold: 0
              config: {tags: [local], meta: {owner: authored}, severity: warn, extension: {value: 2}}
''', CONFIG)
    (project / 'macros').mkdir()
    (project / 'macros/check.sql').write_text("""{% test check(model, column_name, threshold=0) %}
{{ config(tags=['macro'], meta={'macro': true}, severity='error') }}
select * from {{ model }} where {{ column_name }} < {{ threshold }}
{% if execute %}and {{ config.get('extension')['value'] }} = 2{% endif %}
{% endtest %}""")
    actual, expected = pair(project, core_runner)
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    compare(project)
    result = native(project, 'build')
    assert result.returncode == 0, result.stderr
    results = json.loads((project / 'native/run_results.json').read_text())['results']
    assert len(results) == 2 and all(row['status'] == 'success' or row['status'] == 'pass' for row in results)
    expected_build = core_runner.invoke(['--quiet', 'build', '--project-dir', str(project), '--profiles-dir', str(project), '--target-path', 'core', '--no-partial-parse'])
    assert expected_build.success, expected_build.exception
    expected_results = json.loads((project / 'core/run_results.json').read_text())['results']
    assert {row['unique_id']: row['status'] for row in results} == {row['unique_id']: row['status'] for row in expected_results}


@pytest.mark.parametrize('parent', ['model', 'source'])
def test_disabled_parent_keeps_parsed_generic_nodes_but_never_selects_or_executes(tmp_path, core_runner, parent):
    project = tmp_path / 'project'
    properties = '''version: 2
models:
  - name: base
    config: {enabled: false}
    columns: [{name: id, data_tests: [not_null]}]
''' if parent == 'model' else '''version: 2
sources:
  - name: raw
    config: {enabled: false}
    tables: [{name: absent, columns: [{name: id, data_tests: [not_null]}]}]
'''
    project_at(project, properties)
    actual, expected = pair(project, core_runner)
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    manifest, _ = compare(project)
    tests = [node for node in manifest['nodes'].values() if node['resource_type'] == 'test']
    assert len(tests) == 1 and not tests[0]['config']['enabled']
    result = native(project, 'test', '--log-cache-events')
    assert result.returncode == 0, result.stderr
    assert not (project / 'warehouse.duckdb').exists()
    assert not json.loads((project / 'native/run_results.json').read_text())['results']
    assert 'populate' not in result.stderr


def test_explicitly_disabled_relationship_can_reference_missing_target_without_database_access(tmp_path, core_runner):
    project = tmp_path / 'project'
    project_at(project, '''version: 2
models:
  - name: base
    columns:
      - name: id
        data_tests:
          - relationships: {to: "ref('absent')", field: id, config: {enabled: false}}
''')
    actual, expected = pair(project, core_runner)
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    compare(project)
    result = native(project, 'test')
    assert result.returncode == 0, result.stderr
    assert not (project / 'warehouse.duckdb').exists()
    assert not json.loads((project / 'native/run_results.json').read_text())['results']


@pytest.mark.parametrize('definition', [
    "not_null: {config: {enabled: nope}}", "not_null: {config: {tags: [1]}}",
    "not_null: {config: {meta: [owner]}}", "not_null: {config: {severity: invalid}}",
    "not_null: {severity: warn, config: {severity: error}}", "not_null: {model: forbidden}",
    "not_null: {config: {limit: wrong}}", "not_null: {config: {group: 3}}",
])
def test_invalid_test_configs_fail_native_and_core_before_database_access(tmp_path, core_runner, definition):
    project = tmp_path / 'project'
    project_at(project, 'version: 2\nmodels:\n  - name: base\n    columns:\n      - name: id\n        data_tests:\n          - ' + definition + '\n')
    actual, expected = pair(project, core_runner)
    assert actual.returncode != 0
    assert not expected.success
    assert not (project / 'warehouse.duckdb').exists()
    assert not (project / 'native/manifest.json').exists()


def test_dependency_project_builder_and_root_override_config_precedence(tmp_path, core_runner):
    project = tmp_path / 'project'
    project_at(project, 'version: 2\n', '''data_tests:
  +tags: [root_global]
  dependency:
    nested:
      external_check:
        +tags: [root_final]
        +meta: {owner: root, root: true}
        +severity: error
''')
    dependency = project / 'dbt_packages/dependency'
    (dependency / 'models/nested').mkdir(parents=True)
    (dependency / 'dbt_project.yml').write_text("name: dependency\nversion: '1.0'\ndata_tests:\n  +tags: [package]\n  +meta: {owner: package, package: true}\n  dependency:\n    nested:\n      +severity: warn\n")
    (dependency / 'models/external.sql').write_text('select 1 as id')
    (dependency / 'models/nested/schema.yml').write_text('''version: 2
models:
  - name: external
    columns:
      - name: id
        data_tests:
          - not_null:
              name: external_check
              config: {tags: [builder], meta: {owner: builder, builder: true}, extension: {types: [true, 3]}}
''')
    # Core discovers installed package projects; dependency declarations also
    # make this fixture represent a real local-package project.
    (project / 'packages.yml').write_text('packages: [{local: dbt_packages/dependency}]\n')
    actual, expected = pair(project, core_runner)
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    compare(project)


@pytest.mark.parametrize('limit', [None, -1, 0, 2])
def test_nullable_and_signed_limits_parse_exactly_like_core(tmp_path, core_runner, limit):
    project = tmp_path / 'project'
    project_at(project, 'version: 2\nmodels:\n  - name: base\n    columns:\n      - name: id\n        data_tests:\n          - not_null: {config: {limit: ' + ('null' if limit is None else str(limit)) + '}}\n')
    actual, expected = pair(project, core_runner)
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    compare(project)


@pytest.mark.parametrize('disabled', [True, False])
def test_duplicate_test_definitions_preserve_disabled_variants_and_reject_enabled_duplicates(tmp_path, core_runner, disabled):
    project = tmp_path / 'project'
    value = str(not disabled).lower()
    project_at(project, 'version: 2\nmodels:\n  - name: base\n    columns:\n      - name: id\n        data_tests:\n          - not_null: {config: {enabled: ' + value + ', tags: first}}\n          - not_null: {config: {enabled: ' + value + ', tags: second}}\n')
    actual, expected = pair(project, core_runner)
    if not disabled:
        assert actual.returncode != 0
        assert not expected.success
    else:
        assert actual.returncode == 0, actual.stderr
        assert expected.success, expected.exception
        a = json.loads((project / 'native/manifest.json').read_text())
        b = json.loads((project / 'core/manifest.json').read_text())
        assert set(a['disabled']) == set(b['disabled'])
        for key, variants in a['disabled'].items():
            assert len(variants) == len(b['disabled'][key]) == 2
            assert [{field: node.get(field) for field in FIELDS} for node in variants] == [
                {field: node.get(field) for field in FIELDS} for node in b['disabled'][key]]


def test_source_test_group_config_and_membership_match_core(tmp_path, core_runner):
    project = tmp_path / 'project'
    project_at(project, '''version: 2
groups: [{name: finance, owner: {name: Finance}}]
sources:
  - name: raw
    schema: main
    tables:
      - name: base
        columns:
          - name: id
            data_tests:
              - not_null: {name: source_check, config: {group: finance, tags: [source], meta: {owner: source}}}
''')
    actual, expected = pair(project, core_runner)
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    compare(project)
    common = ['ls', '--project-dir', str(project), '--profiles-dir', str(project), '--resource-type', 'test',
              '--select', 'group:finance', '--indirect-selection', 'empty', '--output', 'json', '--output-keys', 'unique_id']
    actual = subprocess.run([DXT, *common, '--target-path', 'native'], capture_output=True, text=True)
    expected = core_runner.invoke(['--quiet', *common, '--target-path', 'core'])
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    assert sorted(row['unique_id'] for row in json_lines(actual.stdout)) == sorted(json.loads(line)['unique_id'] for line in expected.result)


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_only_disabled_generic_tasks_never_connect_for_either_initial_adapter(tmp_path, core_runner, adapter):
    project = tmp_path / 'project'
    project_at(project, '''version: 2
models:
  - name: base
    columns: [{name: id, data_tests: [{not_null: {config: {enabled: false}}}]}]
''')
    if adapter == 'postgres':
        (project / 'profiles.yml').write_text('config_tests:\n  target: dev\n  outputs:\n    dev:\n      type: postgres\n      host: 127.0.0.1\n      port: 1\n      user: synthetic\n      password: synthetic\n      dbname: synthetic\n      schema: main\n      threads: 2\n      connect_timeout: 1\n')
    common = ['test', '--project-dir', str(project), '--profiles-dir', str(project)]
    actual = native(project, 'test', '--log-cache-events')
    expected = core_runner.invoke(['--quiet', *common, '--target-path', 'core', '--no-partial-parse'])
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    assert not (project / 'warehouse.duckdb').exists()
    assert not json.loads((project / 'native/run_results.json').read_text())['results']
    assert not json.loads((project / 'core/run_results.json').read_text())['results']
    assert 'populate' not in actual.stderr


@pytest.mark.parametrize('promoted', [False, True])
def test_missing_generic_reference_matches_core_warning_policy_and_never_executes(tmp_path, core_runner, promoted):
    project = tmp_path / 'project'
    project_at(project, '''version: 2
models:
  - name: base
    columns:
      - name: id
        data_tests:
          - relationships: {to: "ref('missing')", field: id}
''')
    extra = ['--warn-error'] if promoted else []
    actual = native(project, 'parse', *extra)
    expected = core_runner.invoke(['--quiet', *extra, 'parse', '--project-dir', str(project), '--profiles-dir', str(project), '--target-path', 'core', '--no-partial-parse'])
    if promoted:
        assert actual.returncode != 0
        assert not expected.success
    else:
        assert actual.returncode == 0, actual.stderr
        assert expected.success, expected.exception
        compare(project)
        assert 'NodeNotFoundOrDisabled' in actual.stderr
        executed = native(project, 'test')
        assert executed.returncode == 0, executed.stderr
        assert not json.loads((project / 'native/run_results.json').read_text())['results']
    assert not (project / 'warehouse.duckdb').exists()


def test_typed_nested_kwargs_and_parse_config_proxy_match_core(tmp_path, core_runner):
    project = tmp_path / 'project'
    project_at(project, '''version: 2
models:
  - name: base
    data_tests:
      - check:
          payload:
            nested: ["{{ var('threshold') }}", {flag: "{{ var('enabled_flag', true) }}"}]
            relation: "ref('other')"
            source: "{{ source('raw', 'base') }}"
            text: "value={{ var('threshold') }}"
          config: {mandatory: 7, extension: {value: 2}, tags: [authored]}
sources:
  - name: raw
    schema: main
    tables: [{name: base}]
''')
    (project / 'models/other.sql').write_text("{{ config(materialized='table') }}select 2 as id")
    (project / 'macros').mkdir()
    (project / 'macros/check.sql').write_text('''{% test check(model, payload) %}
{% if not execute %}
  {% if config.get('extension', {'value': 99}) != '' or config.require('mandatory') != ''
        or config.persist_relation_docs() or config.persist_column_docs() %}
    {{ exceptions.raise_compiler_error('invalid parse config proxy') }}
  {% endif %}
{% else %}
  {% if config.require('mandatory') != 7 or config.get('extension')['value'] != 2
        or payload['relation'].identifier != 'other' or payload['source'].identifier != 'base' %}
    {{ exceptions.raise_compiler_error('invalid runtime typed values') }}
  {% endif %}
{% endif %}
{{ config(meta={'typed_flag': payload['nested'][1]['flag']}) }}
{% if payload['text'] != 'value=0' or payload['nested'][0] != 0 %}
  {{ exceptions.raise_compiler_error('invalid nested generic arguments') }}
{% endif %}
select * from {{ model }} where id < {{ payload['nested'][0] }}
{% endtest %}''')
    actual, expected = pair(project, core_runner)
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    compare(project)
    actual_build = native(project, 'build')
    expected_build = core_runner.invoke(['--quiet', 'build', '--project-dir', str(project),
                                         '--profiles-dir', str(project), '--target-path', 'core', '--no-partial-parse'])
    assert actual_build.returncode == 0, actual_build.stderr
    assert expected_build.success, expected_build.exception
    actual_rows = json.loads((project / 'native/run_results.json').read_text())['results']
    expected_rows = json.loads((project / 'core/run_results.json').read_text())['results']
    assert {row['unique_id']: row['status'] for row in actual_rows} == {
        row['unique_id']: row['status'] for row in expected_rows}


@pytest.mark.parametrize('id_value', ['1', 'null'])
def test_generic_failure_audit_schema_and_empty_table_persistence_match_core(tmp_path, core_runner, id_value):
    project = tmp_path / 'project'
    project_at(project, '''version: 2
models:
  - name: base
    columns: [{name: id, data_tests: [{not_null: {config: {store_failures: true}}}]}]
''')
    (project / 'models/base.sql').write_text("{{ config(materialized='table') }}select " + id_value + " as id")
    actual = native(project, 'build')
    expected = core_runner.invoke(['--quiet', 'build', '--project-dir', str(project), '--profiles-dir', str(project),
                                   '--target-path', 'core', '--no-partial-parse'])
    assert actual.returncode == (0 if id_value == '1' else 1), actual.stderr
    assert expected.success == (id_value == '1'), expected.exception
    actual_rows = json.loads((project / 'native/run_results.json').read_text())['results']
    expected_rows = json.loads((project / 'core/run_results.json').read_text())['results']
    actual_test = next(row for row in actual_rows if row['unique_id'].startswith('test.'))
    expected_test = next(row for row in expected_rows if row['unique_id'].startswith('test.'))
    assert actual_test['status'] == expected_test['status']
    assert actual_test['relation_name'] == expected_test['relation_name']
    assert 'main_dbt_test__audit' in actual_test['relation_name']
    # The passing test keeps a real, empty audit relation in Core and dxt.
    import duckdb
    with duckdb.connect(str(project / 'warehouse.duckdb')) as database:
        count = database.execute('select count(*) from ' + actual_test['relation_name']).fetchone()[0]
    assert count == (0 if id_value == '1' else 1)

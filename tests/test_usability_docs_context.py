"""Native documentation rendering against pinned Core, including cache reuse."""
import json
import subprocess
from pathlib import Path

import pytest

from test_usability_commands import core_runner
from test_usability_artifacts import contracts

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / 'zig-out/bin/dxt'


@pytest.fixture(scope='module', autouse=True)
def binary():
    subprocess.run(['zig', 'build'], cwd=ROOT, check=True)


def create(project, description='Prefix {{ doc("shared") | upper }} / {{ var("who") }} / {{ target.schema }}{{ doc("only_pkg") if false else "" }} / {{ doc("shared") }}'):
    (project / 'models').mkdir(parents=True)
    (project / 'dbt_project.yml').write_text("name: docs_context\nversion: '1.0'\nprofile: docs_context\nvars: {who: Native}\n")
    (project / 'profiles.yml').write_text(f"docs_context:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n      path: {project / 'warehouse.duckdb'}\n      schema: main\n")
    (project / 'models/base.sql').write_text('select 1 as id')
    (project / 'models/docs.md').write_text('{% docs shared %}Root documentation{% enddocs %}')
    (project / 'models/schema.yml').write_text('version: 2\nmodels:\n  - name: base\n    description: ' + json.dumps(description) + '\n    columns:\n      - name: id\n        description: "{{ doc(\'pkg\', \'shared\') }}"\n        data_tests:\n          - not_null:\n              description: "{{ doc(\'only_pkg\') }}"\n')
    package = project / 'dbt_packages/pkg'
    (package / 'models').mkdir(parents=True)
    (package / 'dbt_project.yml').write_text("name: pkg\nversion: '1.0'\n")
    (package / 'models/docs.md').write_text('{% docs shared %}Package documentation{% enddocs %}\n{% docs only_pkg %}Fallback documentation{% enddocs %}')
    (package / 'models/package_model.sql').write_text('select 2 as id')
    (package / 'models/schema.yml').write_text('version: 2\nmodels:\n  - name: package_model\n    description: "{{ doc(\'shared\') }} {{ doc(\'pkg\', \'shared\') }}"\n')


def native(project, *extra):
    return subprocess.run([DXT, 'parse', '--project-dir', str(project), '--profiles-dir', str(project),
                           '--target-path', 'native', *extra], capture_output=True, text=True)


def oracle(project, runner):
    return runner.invoke(['--quiet', 'parse', '--project-dir', str(project), '--profiles-dir', str(project),
                          '--target-path', 'core', '--no-partial-parse'])


def compare(project):
    actual = json.loads((project / 'native/manifest.json').read_text())
    expected = json.loads((project / 'core/manifest.json').read_text())
    contracts.assert_artifact(project / 'native/manifest.json')
    for section in ('nodes', 'sources', 'exposures', 'metrics', 'semantic_models', 'saved_queries', 'macros'):
        left = {key: value for key, value in actual[section].items() if value['package_name'] in ('docs_context', 'pkg')}
        right = {key: value for key, value in expected[section].items() if value['package_name'] in ('docs_context', 'pkg')}
        assert set(left) == set(right), section
        for key, node in left.items():
            for field in ('description', 'source_description', 'doc_blocks'):
                assert node.get(field, []) == right[key].get(field, []), (key, field, node.get(field), right[key].get(field))
            if section == 'macros':
                for field in ('meta', 'docs'):
                    assert node[field] == right[key][field], (key, field)
            for field in ('columns', 'arguments', 'entities', 'dimensions', 'measures', 'query_params'):
                if field in node:
                    assert node[field] == right[key][field], (key, field, node[field], right[key][field])
    return actual, expected


def test_complex_descriptions_package_precedence_and_cache_match_core(tmp_path, core_runner):
    project = tmp_path / 'project'
    create(project)
    actual = native(project, '--debug')
    expected = oracle(project, core_runner)
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    first, _ = compare(project)
    assert first['nodes']['model.pkg.package_model']['description'] == 'Root documentation Package documentation'
    assert first['nodes']['model.docs_context.base']['doc_blocks'] == ['doc.docs_context.shared']
    warm = native(project, '--debug')
    assert warm.returncode == 0, warm.stderr
    assert '"hit":true' in warm.stderr
    second, _ = compare(project)
    assert {key: value for key, value in first.items() if key != 'metadata'} == {
        key: value for key, value in second.items() if key != 'metadata'}
    (project / 'models/docs.md').write_text('{% docs shared %}Changed documentation{% enddocs %}')
    assert native(project).returncode == 0
    expected = oracle(project, core_runner)
    assert expected.success, expected.exception
    changed, _ = compare(project)
    assert changed['nodes']['model.pkg.package_model']['description'].startswith('Changed documentation')
    assert not (project / 'warehouse.duckdb').exists()


def test_all_resource_and_column_descriptions_match_core(tmp_path, core_runner):
    project = tmp_path / 'project'
    create(project)
    (project / 'models/base.sql').write_text("select 1 as id, '2024-01-01'::date as created_at")
    (project / 'models/metricflow_time_spine.sql').write_text("select date '2024-01-01' as date_day")
    schema = project / 'models/schema.yml'
    schema.write_text(schema.read_text() + '''
sources:
  - name: raw
    description: "Source {{ doc('shared') }}"
    schema: main
    tables:
      - name: base
        description: "Table {{ doc('pkg', 'shared') }}"
        columns: [{name: id, description: "{{ doc('only_pkg') }}"}]
analyses: [{name: report, description: "{{ doc('shared') }}"}]
seeds: [{name: lookup, description: "{{ doc('shared') }}", columns: [{name: id, description: "{{ doc('only_pkg') }}"}]}]
snapshots: [{name: history, description: "{{ doc('shared') }}", columns: [{name: id, description: "{{ doc('only_pkg') }}"}]}]
data_tests:
  - name: assertion
    description: "{{ doc('shared') }}"
macros:
  - name: helper
    description: "Macro {{ doc('shared') }}"
    arguments: [{name: value, type: integer, description: "Arg {{ doc('pkg', 'shared') }}"}]
    meta: {owner: {team: analytics}, nested: [1, true, null]}
    docs: {show: false, node_color: '#336699'}
exposures:
  - name: report
    type: dashboard
    owner: {name: Owner, email: owner@example.test}
    depends_on: ["ref('base')"]
    description: "Exposure {{ doc('shared') }}"
semantic_models:
  - name: orders
    model: ref('base')
    description: "Semantic {{ doc('shared') }}"
    defaults: {agg_time_dimension: created_at}
    entities: [{name: id, type: primary, expr: id, description: "{{ doc('only_pkg') }}"}]
    dimensions: [{name: created_at, type: time, type_params: {time_granularity: day}, description: "{{ doc('shared') }}"}]
    measures: [{name: count, agg: count, expr: '1', description: "{{ doc('pkg', 'shared') }}"}]
metrics:
  - name: total
    label: Total
    type: simple
    type_params: {measure: count}
    description: "Metric {{ doc('shared') }}"
saved_queries:
  - name: query
    description: "Query {{ doc('shared') }}"
    query_params: {metrics: [total]}
''')
    for directory in ('analyses', 'seeds', 'snapshots', 'tests', 'macros'):
        (project / directory).mkdir()
    (project / 'analyses/report.sql').write_text('select 1 as id')
    (project / 'seeds/lookup.csv').write_text('id\n1\n')
    (project / 'tests/assertion.sql').write_text("select * from {{ ref('base') }} where id is null")
    (project / 'macros/helper.sql').write_text('{% macro helper(value) %}{{ value }}{% endmacro %}')
    (project / 'snapshots/history.sql').write_text("{% snapshot history %}{{ config(target_schema='history', unique_key='id', strategy='check', check_cols=['id']) }}select * from {{ ref('base') }}{% endsnapshot %}")
    actual = native(project)
    expected = oracle(project, core_runner)
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    compare(project)


@pytest.mark.parametrize('description', ["{{ doc('missing') }}", "{{ doc() }}", "{{ doc('a', 'b', 'c') }}", "{{ doc(12) }}", "{{ ref('base') }}", "{{ config.get('x') }}", "{{ adapter.type() }}", "{{ render('text') }}", "{{ run_query('select 1') }}"])
def test_documentation_errors_match_core_before_database_access(tmp_path, core_runner, description):
    project = tmp_path / 'project'
    create(project, description)
    actual = native(project)
    expected = oracle(project, core_runner)
    assert actual.returncode != 0
    assert not expected.success
    assert not (project / 'warehouse.duckdb').exists()


def test_disabled_description_is_kept_unrendered_like_core(tmp_path, core_runner):
    project = tmp_path / 'project'
    create(project)
    schema = project / 'models/schema.yml'
    schema.write_text('version: 2\nmodels:\n  - name: base\n    config: {enabled: false}\n    description: "{{ doc(\'missing\') }}"\n')
    actual = native(project)
    expected = oracle(project, core_runner)
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    left = json.loads((project / 'native/manifest.json').read_text())['disabled']['model.docs_context.base'][0]
    right = json.loads((project / 'core/manifest.json').read_text())['disabled']['model.docs_context.base'][0]
    assert left['description'] == right['description'] == "{{ doc('missing') }}"
    assert left['doc_blocks'] == right['doc_blocks'] == []


@pytest.mark.parametrize('body', [
    "  {{ 'header' | upper }}{% for item in ['a','b'] %} {{ item }}{% endfor %}  ",
    "{% set label %}first\nsecond{% endset %}{{ label | replace('first', 'changed') }}",
    "{% set state = namespace(count=0) %}{% for item in range(3) %}{% set state.count = state.count + 1 %}{% endfor %}{{ state.count }}",
    "{% raw %}{{ doc('not_rendered') }}{% endraw %}",
    "before {{ missing }} after",
])
def test_docs_definitions_render_with_empty_jinja_context(tmp_path, core_runner, body):
    project = tmp_path / 'project'
    create(project)
    (project / 'models/docs.md').write_text('{# {% docs ignored %} #}{% docs shared %}' + body + '{% enddocs %}')
    actual = native(project)
    expected = oracle(project, core_runner)
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    left, right = compare(project)
    assert left['docs'] == right['docs']


@pytest.mark.parametrize('body', [
    "{{ var('who', 'default') }}", "{{ env_var('HOME', 'default') }}", "{{ doc('shared') }}",
    "{{ ref('base') }}", "{{ helper(1) }}", "{{ modules.re.IGNORECASE }}", "{% docs nested %}nested{% enddocs %}",
    "{% macro emphasize(value) %}<b>{{ value|upper }}</b>{% endmacro %}{{ emphasize('hello') }}",
])
def test_docs_definition_errors_match_core(tmp_path, core_runner, body):
    project = tmp_path / 'project'
    create(project)
    (project / 'models/docs.md').write_text('{% docs shared %}' + body + '{% enddocs %}')
    actual = native(project)
    expected = oracle(project, core_runner)
    assert actual.returncode != 0, actual.stderr
    assert not expected.success
    assert not (project / 'warehouse.duckdb').exists()


@pytest.mark.parametrize('description', [
    "{{ (doc('shared')) }} {{ doc('shared') }}",
    "{{ 'Start ' ~ doc('shared') }} {{ doc('shared') | upper }}",
    "{{ doc('shared') if true else doc('missing') }}",
    "Unknown {{ execute }} / {{ authored_missing }} / {{ model is undefined }}",
])
def test_doc_dependency_metadata_matches_core_ast_calls(tmp_path, core_runner, description):
    project = tmp_path / 'project'
    create(project, description)
    actual = native(project)
    expected = oracle(project, core_runner)
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    compare(project)


def test_macro_yaml_templates_inline_properties_and_duplicate_patches(tmp_path, core_runner):
    project = tmp_path / 'project'
    create(project)
    (project / 'macros').mkdir()
    (project / 'macros/helper.sql').write_text('{% macro helper(value) %}{{ value }}{% endmacro %}')
    schema = project / 'models/schema.yml'
    schema.write_text(schema.read_text() + '''
macros: [{name: helper, description: "{{ doc('shared') }}", arguments: [{name: value, type: "{{ var('kind', 'integer') }}", description: "{{ doc('only_pkg') }}"}], meta: {owner: "{{ var('who') }}", values: "{{ [1, true, none] }}"}, docs: {show: false, node_color: "{{ var('color', '#336699') }}"}, config: {meta: {ignored: true}}}]
''')
    actual = native(project)
    expected = oracle(project, core_runner)
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    left, _ = compare(project)
    assert left['macros']['macro.docs_context.helper']['meta'] == {'owner': 'Native', 'values': '[1, True, None]'}
    (project / 'macros/duplicate.yml').write_text('version: 2\nmacros: [{name: helper}]\n')
    assert native(project).returncode != 0
    assert not oracle(project, core_runner).success


def test_macro_yaml_templated_boolean_is_invalid_like_core(tmp_path, core_runner):
    project = tmp_path / 'project'
    create(project)
    (project / 'macros').mkdir()
    (project / 'macros/helper.sql').write_text('{% macro helper() %}select 1{% endmacro %}')
    schema = project / 'models/schema.yml'
    schema.write_text(schema.read_text() + '\nmacros: [{name: helper, docs: {show: "{{ false }}"}}]\n')
    assert native(project).returncode != 0
    assert not oracle(project, core_runner).success


@pytest.mark.parametrize('argument_type', [None, '', 'string'])
def test_macro_argument_null_and_empty_type_are_preserved(tmp_path, core_runner, argument_type):
    project = tmp_path / 'project'
    create(project)
    (project / 'macros').mkdir()
    (project / 'macros/helper.sql').write_text('{% macro helper(value) %}{{ value }}{% endmacro %}')
    schema = project / 'models/schema.yml'
    patch = [{'name': 'helper', 'arguments': [{'name': 'value', 'type': argument_type}]}]
    schema.write_text(schema.read_text() + '\nmacros: ' + json.dumps(patch) + '\n')
    actual = native(project)
    expected = oracle(project, core_runner)
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    compare(project)


def test_description_environment_and_cli_vars_invalidate_cached_values(tmp_path, core_runner, monkeypatch):
    project = tmp_path / 'project'
    create(project, "{{ doc('shared') }} / {{ env_var('DXT_DOC_OWNER') }} / {{ var('who') }}")
    monkeypatch.setenv('DXT_DOC_OWNER', 'First')
    args = ['--debug', '--vars', '{who: CLI}']
    assert native(project, *args).returncode == 0
    expected = core_runner.invoke(['--quiet', 'parse', '--project-dir', str(project), '--profiles-dir', str(project), '--target-path', 'core', '--no-partial-parse', '--vars', '{who: CLI}'])
    assert expected.success, expected.exception
    first, _ = compare(project)
    assert first['nodes']['model.docs_context.base']['description'] == 'Root documentation / First / CLI'
    assert '\"hit\":true' in native(project, *args).stderr
    monkeypatch.setenv('DXT_DOC_OWNER', 'Second')
    changed = native(project, *args)
    assert changed.returncode == 0, changed.stderr
    assert '\"hit\":false' in changed.stderr
    expected = core_runner.invoke(['--quiet', 'parse', '--project-dir', str(project), '--profiles-dir', str(project), '--target-path', 'core', '--no-partial-parse', '--vars', '{who: CLI}'])
    assert expected.success, expected.exception
    second, _ = compare(project)
    assert second['nodes']['model.docs_context.base']['description'] == 'Root documentation / Second / CLI'


def test_macro_description_base_callable_aliases_match_core(tmp_path, core_runner):
    project = tmp_path / 'project'
    create(project)
    (project / 'macros').mkdir()
    (project / 'macros/helper.sql').write_text('{% macro helper() %}select 1{% endmacro %}')
    schema = project / 'models/schema.yml'
    description = "{% set lookup = doc %}{% set variable = var %}{{ lookup('shared') }} / {{ variable('who') }} / {{ modules.re.sub('a', 'b', 'aab') }}"
    schema.write_text(schema.read_text() + '\nmacros: ' + json.dumps([{'name': 'helper', 'description': description}]) + '\n')
    actual = native(project)
    expected = oracle(project, core_runner)
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    compare(project)


@pytest.mark.parametrize('opening,closing', [('if true', 'endif'), ("for item in ['x']", 'endfor')])
def test_docs_definitions_must_be_top_level_like_core(tmp_path, core_runner, opening, closing):
    project = tmp_path / 'project'
    create(project)
    (project / 'models/docs.md').write_text('{% ' + opening + ' %}{% docs shared %}nested{% enddocs %}{% ' + closing + ' %}')
    assert native(project).returncode != 0
    assert not oracle(project, core_runner).success


def test_fallback_documentation_uses_core_installed_package_order(tmp_path, core_runner):
    project = tmp_path / 'project'
    create(project)
    (project / 'models/docs.md').write_text('{% docs root_only %}Root{% enddocs %}')
    package = project / 'dbt_packages/alpha'
    (package / 'models').mkdir(parents=True)
    (package / 'dbt_project.yml').write_text("name: alpha\nversion: '1.0'\n")
    (package / 'models/docs.md').write_text('{% docs shared %}Alpha fallback{% enddocs %}')
    actual = native(project)
    expected = oracle(project, core_runner)
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    compare(project)


@pytest.mark.parametrize('directory', ['models', 'macros', 'seeds', 'analyses', 'snapshots', 'tests'])
def test_default_docs_paths_cover_all_source_directories(tmp_path, core_runner, directory):
    project = tmp_path / 'project'
    create(project)
    body = (project / 'models/docs.md').read_text()
    (project / 'models/docs.md').unlink()
    (project / directory).mkdir(exist_ok=True)
    (project / directory / 'documentation.md').write_text(body)
    actual = native(project)
    expected = oracle(project, core_runner)
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    left, right = compare(project)
    assert left['docs'] == right['docs']


@pytest.mark.parametrize('paths', [[], None, ['documentation'], ['documentation', 'documentation']])
def test_explicit_docs_paths_overrides_defaults_and_preserves_duplicates(tmp_path, core_runner, paths):
    project = tmp_path / 'project'
    create(project)
    config = project / 'dbt_project.yml'
    config.write_text(config.read_text() + 'docs-paths: ' + json.dumps(paths) + '\n')
    (project / 'documentation').mkdir()
    (project / 'documentation/docs.md').write_text('{% docs shared %}Custom documentation{% enddocs %}')
    actual = native(project)
    expected = oracle(project, core_runner)
    if paths == ['documentation', 'documentation']:
        assert not expected.success
        assert actual.returncode == 2
        assert 'duplicate docs block name' in actual.stderr
        return
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    left, right = compare(project)
    assert left['docs'] == right['docs']
    if paths:
        assert left['nodes']['model.docs_context.base']['description'].startswith('Prefix CUSTOM DOCUMENTATION')
        (project / 'documentation/docs.md').write_text('{% docs shared %}Updated custom docs{% enddocs %}')
        assert native(project).returncode == 0
        expected = oracle(project, core_runner)
        assert expected.success, expected.exception
        changed, _ = compare(project)
        assert changed['nodes']['model.docs_context.base']['description'].startswith('Prefix UPDATED CUSTOM DOCS')


def test_installed_package_docs_paths_are_independent_of_root(tmp_path, core_runner):
    project = tmp_path / 'project'
    create(project)
    package = project / 'dbt_packages/pkg'
    config = package / 'dbt_project.yml'
    config.write_text(config.read_text() + 'docs-paths: [documentation]\n')
    (package / 'documentation').mkdir()
    (package / 'models/docs.md').rename(package / 'documentation/docs.md')
    actual = native(project)
    expected = oracle(project, core_runner)
    assert actual.returncode == 0, actual.stderr
    assert expected.success, expected.exception
    left, right = compare(project)
    assert left['docs'] == right['docs']

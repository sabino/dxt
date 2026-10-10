"""Core cache-read/write controls and measured native parser branches."""
import json
import pstats
import shutil
from pathlib import Path

import pytest
from test_cli import build_dxt  # noqa: F401
from test_usability_adapters import duckdb_environment  # noqa: F401
from test_usability_cli_options import environment, invoke, pinned_core, project  # noqa: F401


def records(result):
    return [json.loads(line) for text in [result.stdout, result.stderr]
            for line in text.splitlines() if line.startswith('{')]


def cache_event(result):
    return next(row['data'] for row in records(result) if row['info']['name'] == 'NativeParseCache')


def cache_path(root, engine):
    return root / 'target' / ('dxt_parse_cache.json' if engine == 'dxt' else 'partial_parse.msgpack')


def parse(engine, root, env, flags=()):
    return invoke(engine, ['--debug', '--no-use-colors', '--log-format=json', *flags,
                          'parse', '--project-dir', root, '--profiles-dir', root], root, env)


def stable_nodes(root):
    return json.loads((root / 'target/manifest.json').read_text())['nodes']


@pytest.mark.parametrize('use_env', [False, True])
def test_core_no_partial_parse_disables_reads_but_saves_current_graph(tmp_path, duckdb_environment, use_env):
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path / engine)
        env = environment(duckdb_environment, **({'DBT_PARTIAL_PARSE': 'false'} if use_env else {}))
        flags = [] if use_env else ['--no-partial-parse']
        first = parse(engine, root, env, flags)
        cache = cache_path(root, engine)
        assert cache.exists(), 'Core saves a full parse even when cache reads are disabled'
        before = cache.stat().st_mtime_ns
        (root / 'models/a.sql').write_text('select 99 as id\n')
        second = parse(engine, root, env, flags)
        assert cache.stat().st_mtime_ns > before
        assert stable_nodes(root)['model.cli_fixture.a']['raw_code'] == 'select 99 as id'
        if engine == 'dxt':
            assert cache_event(first)['reason'] == cache_event(second)['reason'] == 'disabled'
            assert cache_event(second)['hit'] is False
        else:
            assert any(row['info']['name'] == 'PartialParsingNotEnabled' for row in records(second))


def test_core_custom_partial_cache_is_read_only_and_default_target_is_written(tmp_path, duckdb_environment):
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path / engine)
        env = environment(duckdb_environment)
        parse(engine, root, env)
        custom = root / 'saved-cache'
        shutil.copyfile(cache_path(root, engine), custom)
        original = custom.read_bytes()
        hit = parse(engine, root, env, ['--partial-parse-file-path', 'saved-cache'])
        if engine == 'dxt':
            assert cache_event(hit)['hit'] is True
        else:
            assert any(row['info']['name'] == 'PartialParsingSkipParsing' for row in records(hit))
        (root / 'models/a.sql').write_text('select 99 as id\n')
        refreshed = parse(engine, root, env, ['--partial-parse-file-path', custom])
        assert custom.read_bytes() == original
        assert stable_nodes(root)['model.cli_fixture.a']['raw_code'] == 'select 99 as id'
        assert cache_path(root, engine).read_bytes() != original
        if engine == 'dxt':
            assert cache_event(refreshed)['hit'] is False


@pytest.mark.parametrize('invalid', ['missing', 'directory'])
def test_core_custom_cache_path_requires_an_existing_file_even_when_reads_disabled(tmp_path, duckdb_environment, invalid):
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path / engine)
        path = root / invalid
        if invalid == 'directory':
            path.mkdir()
        result = invoke(engine, ['--no-partial-parse', '--partial-parse-file-path', path,
                                 'parse', '--project-dir', root, '--profiles-dir', root],
                        root, environment(duckdb_environment), ok=False)
        assert result.returncode == 2, result.stdout + result.stderr
        assert not (root / 'target/manifest.json').exists()


@pytest.mark.parametrize('static', [True, False])
def test_core_static_parser_flags_change_the_measured_native_parser_branch(tmp_path, duckdb_environment, static):
    observed = {}
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path / engine)
        profile = root / 'parser.prof'
        env = environment(duckdb_environment, DBT_STATIC_PARSER='true' if static else 'false')
        parse(engine, root, env, ['--no-partial-parse', '-r', profile])
        statistics = pstats.Stats(str(profile)).stats
        if engine == 'dxt':
            assert any(key[2] == 'scanSqlStatic' for key in statistics) == static
        observed[engine] = {
            key: {field: node[field] for field in ['raw_code', 'checksum', 'refs', 'sources', 'config', 'depends_on']}
            for key, node in stable_nodes(root).items()
        }
    assert observed['dxt'] == observed['core']


def test_core_partial_file_diff_false_supplies_an_empty_external_diff(tmp_path, duckdb_environment):
    for engine in ['dxt', 'core']:
        env = environment(duckdb_environment)
        cold, _ = project(tmp_path / engine / 'cold')
        parse(engine, cold, env, ['--no-partial-parse-file-diff'])
        artifact = json.loads((cold / 'target/manifest.json').read_text())
        assert artifact['nodes'] == artifact['macros'] == {}
        warm, _ = project(tmp_path / engine / 'warm')
        parse(engine, warm, env)
        original = stable_nodes(warm)['model.cli_fixture.a']['raw_code']
        (warm / 'models/a.sql').write_text('select 99 as id\n')
        reused = parse(engine, warm, env, ['--no-partial-parse-file-diff'])
        assert stable_nodes(warm)['model.cli_fixture.a']['raw_code'] == original
        if engine == 'dxt':
            assert cache_event(reused)['hit'] is True
        else:
            assert any(row['info']['name'] == 'PartialParsingSkipParsing' for row in records(reused))
        parse(engine, warm, env, ['--partial-parse-file-diff'])
        assert stable_nodes(warm)['model.cli_fixture.a']['raw_code'] == 'select 99 as id'


def test_core_parser_environment_overrides_context_arguments_and_custom_path(tmp_path, duckdb_environment):
    observed = {}
    for engine in ['dxt', 'core']:
        root, _ = project(tmp_path / engine)
        cache = root / 'fallback-cache'
        cache.write_bytes(b'{}')
        (root / 'models/a.sql').write_text(
            "{{ config(materialized='table') }}\n"
            "select {{ 1 if flags.STATIC_PARSER else 2 }} as static_mode, "
            '{{ 1 if flags.PARTIAL_PARSE else 2 }} as partial_mode\n'
        )
        env = environment(duckdb_environment, DBT_STATIC_PARSER='true', DBT_PARTIAL_PARSE='true',
                          DBT_PARTIAL_PARSE_FILE_DIFF='false', DBT_PARTIAL_PARSE_FILE_PATH=str(cache))
        result = invoke(engine, ['--no-static-parser', '--no-partial-parse', '--partial-parse-file-diff',
                                 'compile', '--project-dir', root, '--profiles-dir', root, '-s', 'a'], root, env)
        artifact = json.loads((root / 'target/run_results.json').read_text())
        args = artifact['args']
        observed[engine] = {key: args[key] for key in ['static_parser', 'partial_parse', 'partial_parse_file_diff']}
        assert args['partial_parse_file_path'] == str(cache.resolve())
        assert cache.read_bytes() == b'{}'
        assert cache_path(root, engine).exists()
        assert 'select 2 as static_mode, 2 as partial_mode' in artifact['results'][0]['compiled_code']
        assert result.returncode == 0
    assert observed['dxt'] == observed['core'] == dict(static_parser=False, partial_parse=False, partial_parse_file_diff=True)

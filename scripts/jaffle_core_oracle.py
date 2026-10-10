"""Pinned developer oracle for unchanged public Jaffle Shop workflows."""
from __future__ import annotations

import importlib.metadata
import json
import shutil
import tempfile
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import UUID


def validate_metadata(metadata, *, engine):
    from check_jaffle_shop_duckdb_parse import GateError, assert_equal
    assert_equal('artifact product version', metadata['dbt_version'], '1.10.5' if engine == 'core' else '0.0.0')
    try:
        invocation = UUID(metadata['invocation_id'])
        assert str(invocation) == metadata['invocation_id'] and invocation.version == 4
        started = datetime.fromisoformat(metadata['invocation_started_at'].replace('Z', '+00:00'))
        generated = datetime.fromisoformat(metadata['generated_at'].replace('Z', '+00:00'))
        assert started.tzinfo is not None and generated.tzinfo is not None
        assert started <= generated <= datetime.now(timezone.utc) + timedelta(seconds=10)
    except (ValueError, TypeError, KeyError, AssertionError) as error:
        raise GateError(f'invalid {engine} invocation UUID or timestamp ordering') from error


@contextmanager
def reference(project, command='parse'):
    from check_jaffle_shop_duckdb_parse import GateError, run
    for package, expected in [('dbt-core', '1.10.5'), ('dbt-duckdb', '1.9.6')]:
        try:
            actual = importlib.metadata.version(package)
        except importlib.metadata.PackageNotFoundError as error:
            raise GateError(f'{package}=={expected} is required for the public Core oracle') from error
        if actual != expected:
            raise GateError(f'{package}=={expected} required; found {actual}')
    with tempfile.TemporaryDirectory(prefix='dxt-jaffle-core-') as temporary:
        root = Path(temporary)
        copied = root / 'project'
        shutil.copytree(project, copied, ignore=shutil.ignore_patterns('.git', 'target', 'logs', 'dbt_packages', 'dbt_modules', '*.duckdb', '*.duckdb.wal'))
        target = root / 'target'
        common = ['--project-dir', copied, '--target-path', target]
        if command in ['run', 'generate']:
            run(['dbt', '--quiet', '--no-use-colors', 'build' if command == 'generate' else 'seed', '--project-dir', copied, '--target-path', root / 'target-preparation'], cwd=copied)
        action = ['docs', 'generate'] if command == 'generate' else [command]
        run(['dbt', '--quiet', '--no-use-colors', *action, *common], cwd=copied)
        manifest = json.loads((target / 'manifest.json').read_text())
        validate_metadata(manifest['metadata'], engine='core')
        yield copied, target, manifest


def command_for_manifest(path):
    results = path.parent / 'run_results.json'
    if (path.parent / 'catalog.json').exists():
        return 'generate'
    if results.exists():
        which = json.loads(results.read_text())['args']['which']
        return 'generate' if which in ['docs_generate', 'generate'] else which
    return 'parse'


def compare_manifest(actual, expected):
    from check_jaffle_shop_duckdb_parse import assert_equal
    assert_equal('complete macro IDs against Core', sorted(actual['macros']), sorted(expected['macros']))
    assert_equal('complete doc IDs against Core', sorted(actual['docs']), sorted(expected['docs']))
    assert_equal('complete resource IDs against Core', sorted(actual['nodes']), sorted(expected['nodes']))
    for unique_id, node in expected['nodes'].items():
        for key in ['resource_type', 'package_name', 'name', 'database', 'schema', 'alias', 'relation_name', 'path', 'original_file_path', 'fqn', 'raw_code', 'description', 'tags', 'config', 'refs', 'sources', 'depends_on', 'compiled', 'compiled_code', 'test_metadata']:
            assert_equal(f'{unique_id} {key} against Core', actual['nodes'][unique_id].get(key), node.get(key))


def compare_results(actual_path, expected_path):
    from check_jaffle_shop_duckdb_parse import assert_equal, load_schema_validator
    validator = load_schema_validator()
    actual = json.loads(actual_path.read_text())
    expected = json.loads(expected_path.read_text())
    for artifact in [actual, expected]:
        errors = validator.validate_artifact(artifact)
        if errors:
            from check_jaffle_shop_duckdb_parse import GateError
            raise GateError(f'complete Run Results schema failed: {errors}')
    rows = {row['unique_id']: row for row in actual['results']}
    oracle = {row['unique_id']: row for row in expected['results']}
    assert_equal('complete run-result IDs against Core', sorted(rows), sorted(oracle))
    assert_equal('unique native result rows', len(rows), len(actual['results']))
    for unique_id, row in oracle.items():
        for key in ['status', 'failures', 'compiled', 'compiled_code', 'relation_name', 'adapter_response']:
            assert_equal(f'{unique_id} result {key} against Core', rows[unique_id].get(key), row.get(key))

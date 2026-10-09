"""Run the unchanged, pinned public dbt-utils integration project against Core.

Python is exclusively a developer oracle: all product commands use the native
dxt binary. Each engine receives the same project and external profile shape.
"""
from __future__ import annotations

import argparse
from collections import Counter
from contextlib import ExitStack
import datetime
from decimal import Decimal
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

import yaml

from validate_dbt_artifacts import assert_artifact

ROOT = Path(__file__).resolve().parents[1]
REVISION = "ef562bac8583a3dd041437d1a0ed926d356da4fd"
REPOSITORY = "https://github.com/dbt-labs/dbt-utils.git"


def run(arguments, cwd, environment):
    result = subprocess.run([str(argument) for argument in arguments], cwd=cwd,
                            env=environment, text=True, capture_output=True, timeout=600)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {' '.join(map(str, arguments))}\n"
                           f"{result.stdout}\n{result.stderr}")
    return result


def authored_files(package):
    return {str(path.relative_to(package)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in package.rglob('*') if path.is_file()
            and not any(part in {'.git', 'dbt_packages', 'target', 'logs', '__pycache__'}
                        for part in path.relative_to(package).parts)
            and path.name != 'package-lock.yml'}


def comparable(value, database):
    if isinstance(value, dict):
        return {key: comparable(item, database) for key, item in value.items()}
    if isinstance(value, list):
        return [comparable(item, database) for item in value]
    if isinstance(value, str):
        return value.replace(f'"{database}".', '"$database".') if database else value
    return value


def assert_same(label, actual, expected):
    if actual != expected:
        raise AssertionError(f"{label} differs from Core:\nnative={actual!r}\nCore={expected!r}")


def manifest_contract(manifest, database):
    fields = ['resource_type', 'name', 'package_name', 'original_file_path', 'fqn',
              'alias', 'schema', 'refs', 'sources', 'depends_on', 'config', 'columns']
    return comparable({identifier: {key: node[key] for key in fields if key in node}
                       for identifier, node in manifest['nodes'].items()}, database)


def canonical_cell(value):
    if isinstance(value, Decimal):
        return ('decimal', str(value.normalize()))
    if isinstance(value, (datetime.datetime, datetime.date, datetime.time)):
        return (type(value).__name__, value.isoformat())
    if isinstance(value, bytes):
        return ('bytes', value.hex())
    if isinstance(value, (list, tuple)):
        return ('sequence', tuple(canonical_cell(item) for item in value))
    if isinstance(value, dict):
        return ('mapping', tuple(sorted((key, canonical_cell(item)) for key, item in value.items())))
    return (type(value).__name__, str(value))


def relation_rows(connection, schema, identifier):
    quote = lambda name: '"' + name.replace('"', '""') + '"'
    cursor = connection.cursor()
    cursor.execute(f'SELECT * FROM {quote(schema)}.{quote(identifier)}')
    return ([column[0] for column in cursor.description],
            Counter(tuple(canonical_cell(cell) for cell in row) for row in cursor.fetchall()))


def certify(source, temporary, binary, core, adapter):
    environment = dict(os.environ, DBT_SEND_ANONYMOUS_USAGE_STATS='false',
                       DXT_DUCKDB_BACKEND='native')
    with ExitStack() as stack:
        runs = []
        original = authored_files(source)
        for engine, executable in [('Core', core), ('native', binary)]:
            package = temporary / adapter / engine / 'dbt-utils'
            shutil.copytree(source, package, ignore=shutil.ignore_patterns(
                '.git', 'target', 'logs', 'dbt_packages', 'package-lock.yml', '__pycache__'))
            project = package / 'integration_tests'
            profiles = package.parent / 'profiles'
            profiles.mkdir()
            database = package.parent / 'warehouse.duckdb'
            output = {'type': adapter, 'schema': 'main', 'threads': 4}
            if adapter == 'duckdb':
                import duckdb
                output['path'] = str(database)
                connect = lambda path=database: duckdb.connect(str(path), read_only=True)
                database_name = database.stem
            else:
                import pgserver
                import psycopg2
                server = stack.enter_context(pgserver.get_server(package.parent / 'postgres'))
                info = server.get_postmaster_info()
                output.update(host=str(info.socket_dir), port=info.port, dbname='postgres',
                              user='postgres', password='', sslmode='disable')
                connect = lambda uri=server.get_uri(): psycopg2.connect(uri)
                database_name = 'postgres'
            (profiles / 'profiles.yml').write_text(yaml.safe_dump({'integration_tests': {
                'target': 'dev', 'outputs': {'dev': output}}}))
            common = ['--project-dir', project, '--profiles-dir', profiles, '--target', 'dev']
            compiled = None
            build_results = None
            for command in [['deps'], ['parse'], ['seed', '--full-refresh'], ['run'], ['compile'],
                            ['build'], ['docs', 'generate']]:
                run([executable, '--quiet', '--no-use-colors', *command, *common],
                    cwd=project, environment=environment)
                if command[0] != 'deps':
                    for filename in ['manifest.json', 'run_results.json', 'catalog.json']:
                        path = project / 'target' / filename
                        if path.exists():
                            assert_artifact(path)
                    if command[0] == 'compile':
                        compiled = json.loads((project / 'target/manifest.json').read_text())
                    if command[0] == 'build':
                        build_results = json.loads((project / 'target/run_results.json').read_text())
            assert_same(f'{adapter}/{engine} unchanged authored project', authored_files(package), original)
            artifact = lambda name: json.loads((project / 'target' / name).read_text())
            runs.append((artifact('manifest.json'), artifact('catalog.json'),
                         artifact('run_results.json'), connect, database_name, compiled, build_results))
        expected, actual = runs
        assert_same(f'{adapter} complete resource identities/config/dependencies',
                    manifest_contract(actual[0], actual[4]), manifest_contract(expected[0], expected[4]))
        assert_same(f'{adapter} catalog relation identities', set(actual[1]['nodes']), set(expected[1]['nodes']))
        # docs generate replaces run_results; both engines must compile the same resources.
        results = lambda run_: {row['unique_id']: (row['status'], row['failures']) for row in run_[2]['results']}
        assert_same(f'{adapter} docs outcomes', results(actual), results(expected))
        outcomes = lambda artifact_: {row['unique_id']: (row['status'], row['failures']) for row in artifact_['results']}
        assert_same(f'{adapter} build outcomes', outcomes(actual[6]), outcomes(expected[6]))
        compiled_sql = lambda run_: {identifier: comparable(node['compiled_code'].strip(), run_[4])
                                    for identifier, node in run_[5]['nodes'].items() if 'compiled_code' in node}
        assert_same(f'{adapter} every compiled SQL resource', compiled_sql(actual), compiled_sql(expected))
        with expected[3]() as core_connection, actual[3]() as native_connection:
            for identifier, relation in expected[1]['nodes'].items():
                other = actual[1]['nodes'][identifier]
                assert_same(f'{adapter}/{identifier} catalog columns', other['columns'], relation['columns'])
                assert_same(f'{adapter}/{identifier} complete typed rows',
                            relation_rows(native_connection, other['metadata']['schema'], other['metadata']['name']),
                            relation_rows(core_connection, relation['metadata']['schema'], relation['metadata']['name']))
        print(f'{adapter}: unchanged dbt-utils {REVISION}, complete schemas, graph, catalog and every relation passed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project-dir', type=Path)
    parser.add_argument('--dxt', type=Path, default=ROOT / 'zig-out/bin/dxt')
    parser.add_argument('--dbt', default=shutil.which('dbt'))
    parser.add_argument('--adapter', choices=['duckdb', 'postgres', 'all'], default='postgres')
    arguments = parser.parse_args()
    for package, version in [('dbt-core', '1.10.5'), ('dbt-duckdb', '1.9.6'), ('dbt-postgres', '1.9.1')]:
        assert_same(f'pinned {package}', importlib.metadata.version(package), version)
    if not arguments.dbt:
        parser.error('The pinned Core developer executable is required')
    with tempfile.TemporaryDirectory(prefix='dxt-public-utils-') as directory:
        temporary = Path(directory)
        source = arguments.project_dir
        if source is None:
            source = temporary / 'upstream'
            run(['git', 'clone', REPOSITORY, source], cwd=temporary, environment=os.environ)
            run(['git', 'checkout', REVISION], cwd=source, environment=os.environ)
        source = source.resolve()
        revision = run(['git', 'rev-parse', 'HEAD'], cwd=source, environment=os.environ).stdout.strip()
        assert_same('public dbt-utils revision', revision, REVISION)
        for adapter in ['duckdb', 'postgres'] if arguments.adapter == 'all' else [arguments.adapter]:
            certify(source, temporary, arguments.dxt.resolve(), arguments.dbt, adapter)


if __name__ == '__main__':
    main()

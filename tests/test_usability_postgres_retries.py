"""Pinned Core/native connection retry evidence against real PostgreSQL.

Native tests own pure policy/accounting; this module retains independent Core
CLI evidence and actual libpq/psycopg2 transport and SQL boundaries.
"""
import importlib.metadata
import json
import os
from pathlib import Path
import subprocess

import psycopg2
import pytest

from postgres_connection_gate import ConnectionGate

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / 'zig-out/bin/dxt'
DRIVER = ROOT / 'zig-out/bin/dxt-adapter-driver'
MISSING = object()
SECRET = 'synthetic-private-retry-password'


@pytest.fixture(scope='module', autouse=True)
def native_binary():
    for package, expected in [('dbt-core', '1.10.5'), ('dbt-postgres', '1.9.1'), ('dbt-adapters', '1.16.3')]:
        assert importlib.metadata.version(package) == expected
    subprocess.run(['zig', 'build', 'adapter-driver'], cwd=ROOT, check=True)
    subprocess.run(['zig', 'build'], cwd=ROOT, check=True)


@pytest.fixture(scope='module')
def postgres(tmp_path_factory):
    import postgres_fixture
    with postgres_fixture.get_server(tmp_path_factory.mktemp('postgres-retry') / 'data') as server:
        # Reachability failures below are imposed by the gate, not readiness.
        with psycopg2.connect(server.get_uri()) as connection:
            with connection.cursor() as cursor:
                cursor.execute('select 42')
                assert cursor.fetchone() == (42,)
        yield server


def project(path, gate, retries=MISSING, role=None, sql='select 42 as answer'):
    (path / 'macros').mkdir(parents=True)
    (path / 'models').mkdir()
    (path / 'dbt_project.yml').write_text("name: native_demo\nversion: '1.0'\nprofile: native_demo\n")
    output = {'type': 'postgres', 'host': '127.0.0.1', 'port': gate.port,
              'dbname': 'postgres', 'user': 'postgres', 'schema': 'public', 'threads': 1,
              'password': "{{ env_var('DBT_ENV_SECRET_RETRY_PASSWORD') }}", 'sslmode': 'disable',
              'connect_timeout': 1}
    if retries is not MISSING:
        output['retries'] = retries
    if role is not None:
        output['role'] = role
    (path / 'profiles.yml').write_text(json.dumps({'native_demo': {'target': 'dev', 'outputs': {'dev': output}}}))
    (path / 'models/probe.sql').write_text('select 42 as answer')
    (path / 'macros/probe.sql').write_text(
        '{% macro probe() %}{% set result = run_query(' + json.dumps(sql) + ') %}'
        "{% do log('RETRY_RESULT=' ~ result.rows[0][0] ~ ';LIMIT=' ~ target.retries,info=True) %}{% endmacro %}")
    return path


def invoke(path, core=False, command='run-operation'):
    args = ['dbt' if core else str(DXT), command]
    if command == 'run-operation':
        args.append('probe')
    args += ['--project-dir', str(path), '--profiles-dir', str(path), '--no-partial-parse']
    environment = dict(os.environ, DBT_SEND_ANONYMOUS_USAGE_STATS='false', DBT_ENV_SECRET_RETRY_PASSWORD=SECRET)
    result = subprocess.run(args, cwd=ROOT, env=environment, text=True, capture_output=True, timeout=45)
    assert SECRET not in result.stdout + result.stderr
    for directory in ('target', 'logs'):
        for artifact in (path / directory).rglob('*'):
            if artifact.is_file():
                assert SECRET.encode() not in artifact.read_bytes(), artifact.name
    return result


@pytest.mark.parametrize('retries,valid_shape,valid_limit,normalized', [
    (MISSING, True, True, 1), (None, False, False, None),
    (-1, True, False, -1), (False, False, False, None), (True, False, False, None),
    ('2', False, False, None), ('x', False, False, None), (2.5, False, False, None),
    (2.0, True, True, 2), ({'connect_attempts': 2}, False, False, None),
    (0, True, True, 0), (1, True, True, 1), (1000, True, True, 1000),
    (1001, True, False, 1001), (4294967296, True, False, 4294967296),
    (999999999999999999999999999, True, False, 999999999999999999999999999),
    (18446744073709551616.0, True, False, 18446744073709551616),
], ids=['missing', 'null', 'negative', 'false', 'true', 'numeric-string', 'string',
        'fractional-float', 'integral-float', 'object', 'zero', 'one', 'limit',
        'over-limit', 'u32-overflow', 'large-integer', 'large-integral-float'])
def test_postgres_retry_shape_and_open_limits_match_core(tmp_path, postgres, retries, valid_shape, valid_limit, normalized):
    for engine in ('native', 'core'):
        with ConnectionGate(postgres, reject=0) as gate:
            root = project(tmp_path / engine, gate, retries)
            parsed = invoke(root, core=engine == 'core', command='parse')
            assert (parsed.returncode == 0) is valid_shape, parsed.stdout + parsed.stderr
            assert len(gate.attempt_times) == 0
            opened = invoke(root, core=engine == 'core')
            assert (opened.returncode == 0) is valid_limit, opened.stdout + opened.stderr
            assert len(gate.attempt_times) == int(valid_limit)
            if valid_limit:
                assert f'RETRY_RESULT=42;LIMIT={normalized}' in opened.stdout


@pytest.mark.parametrize('retries,rejected,attempts,succeeds', [
    (MISSING, 1, 2, True), (MISSING, 2, 2, False), (0, 1, 1, False),
    (1, 1, 2, True), (1, 2, 2, False), (2, 2, 3, True), (2, 3, 3, False),
    (3, 3, 4, True), (3, 4, 4, False),
], ids=['default-recovery', 'default-exhaustion', 'zero', 'one-recovery',
        'one-exhaustion', 'two-recovery', 'two-exhaustion', 'three-recovery', 'three-exhaustion'])
def test_postgres_connection_fault_recovery_and_exhaustion_match_core(tmp_path, postgres, retries, rejected, attempts, succeeds):
    for engine in ('native', 'core'):
        with ConnectionGate(postgres, reject=rejected) as gate:
            root = project(tmp_path / engine, gate, retries)
            result = invoke(root, core=engine == 'core')
            assert (result.returncode == 0) is succeeds, result.stdout + result.stderr
            assert len(gate.attempt_times) == attempts
            assert gate.forwarded == int(succeeds)
            if succeeds:
                assert 'RETRY_RESULT=42' in result.stdout
            else:
                assert 'RETRY_RESULT=' not in result.stdout
            # Independent native tests assert exact waits without a clock.
            # These real commands additionally prove the 1s and 4s intervals.
            for index, expected in enumerate((0, 1, 4)[:attempts - 1]):
                elapsed = gate.attempt_times[index + 1] - gate.attempt_times[index]
                assert elapsed >= expected * 0.9


@pytest.mark.parametrize('failure', ['role', 'sql', 'disconnect'])
def test_postgres_connection_retry_never_replays_role_sql_or_disconnected_query(tmp_path, postgres, failure):
    for engine in ('native', 'core'):
        with ConnectionGate(postgres, reject=0) as gate:
            sql = 'select 1/0' if failure == 'sql' else 'select pg_terminate_backend(pg_backend_pid())' if failure == 'disconnect' else 'select 42'
            role = 'dxt_retry_missing_role' if failure == 'role' else None
            root = project(tmp_path / engine, gate, 3, role=role, sql=sql)
            result = invoke(root, core=engine == 'core')
            assert result.returncode != 0
            assert len(gate.attempt_times) == 1
            assert gate.forwarded == 1
            assert 'RETRY_RESULT=' not in result.stdout


def test_postgres_sql_failure_does_not_repeat_nontransactional_side_effect(tmp_path, postgres):
    for engine in ('native', 'core'):
        name = 'retry_probe_' + engine
        with psycopg2.connect(postgres.get_uri()) as connection:
            with connection.cursor() as cursor:
                cursor.execute('create sequence ' + name)
        with ConnectionGate(postgres, reject=0) as gate:
            root = project(tmp_path / engine, gate, 3, sql="select nextval('" + name + "'); select 1/0")
            result = invoke(root, core=engine == 'core')
            assert result.returncode != 0
            assert len(gate.attempt_times) == 1
        with psycopg2.connect(postgres.get_uri()) as connection:
            with connection.cursor() as cursor:
                cursor.execute('select last_value,is_called from ' + name)
                assert cursor.fetchone() == (1, True)


@pytest.mark.parametrize('retries,rejected,succeeds', [(2, 2, True), (0, 1, False), (1001, 0, False)])
def test_cross_database_profile_open_consumes_connection_retry_policy(tmp_path, postgres, retries, rejected, succeeds):
    with ConnectionGate(postgres, reject=rejected) as gate:
        root = project(tmp_path / 'native', gate, retries)
        result = subprocess.run([str(DRIVER), 'postgres', 'cross-profile', str(root), 'select 42 as answer'],
                                cwd=ROOT, env=dict(os.environ, DBT_ENV_SECRET_RETRY_PASSWORD=SECRET),
                                text=True, capture_output=True, timeout=15)
        assert (result.returncode == 0) is succeeds, result.stdout + result.stderr
        assert SECRET not in result.stdout + result.stderr
        assert len(gate.attempt_times) == (3 if succeeds else 1 if retries == 0 else 0)
        if succeeds:
            assert json.loads(result.stdout) == [{'answer': 42}]

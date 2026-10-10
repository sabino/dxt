"""Developer SQL clock fixtures preserve exact rows without product changes."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys

import pytest


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'scripts'


def environment():
    value = dict(os.environ, DXT_ORACLE_EPOCH_SECONDS='1791590400')
    value.pop('DXT_PUBLIC_ORACLE_CLOCK_ACTIVE', None)
    value['PYTHONPATH'] = str(SCRIPTS) + os.pathsep + value.get('PYTHONPATH', '')
    return value


def test_public_clock_reexec_preserves_arguments_status_and_real_monotonic_time(tmp_path):
    program = tmp_path / 'probe.py'
    program.write_text("""import json, os, sys, time
from oracle_clock import reexec_current_script, verify_python_clock
status = reexec_current_script(__file__)
if status is not None:
    raise SystemExit(status)
epoch = verify_python_clock()
before = time.monotonic_ns()
time.sleep(0.02)
elapsed = time.monotonic_ns() - before
assert elapsed > 0
print(json.dumps({'epoch':epoch,'realtime_ns':time.time_ns(),'elapsed_ns':elapsed,
                  'arguments':sys.argv[1:],'library':os.environ['LD_PRELOAD'].split(':')[0]}))
raise SystemExit(7)
""")
    result = subprocess.run([sys.executable, program, 'literal argument', '--untouched'],
                            env=environment(), text=True, capture_output=True, timeout=30)
    assert result.returncode == 7, result.stdout + result.stderr
    record = json.loads(result.stdout)
    assert record['epoch'] == 1791590400
    assert record['realtime_ns'] == 1791590400000000000
    assert record['arguments'] == ['literal argument', '--untouched']
    assert record['elapsed_ns'] > 0
    assert not Path(record['library']).exists()


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
def test_public_clock_pins_actual_engines_and_exact_volatile_relation_rows(tmp_path, adapter):
    program = tmp_path / 'sql_probe.py'
    program.write_text("""from contextlib import ExitStack
import json
from pathlib import Path
import sys
from check_dbt_utils import relation_rows
from oracle_clock import verify_python_clock, verify_sql_clock
base=Path(sys.argv[1]); adapter=sys.argv[2]
epoch=verify_python_clock()
connections=[]
with ExitStack() as stack:
    for label in ('native_fixture','core_fixture'):
        if adapter == 'duckdb':
            import duckdb
            connection=duckdb.connect(str(base/(label+'.duckdb')))
        else:
            import postgres_fixture, psycopg2
            server=stack.enter_context(postgres_fixture.get_server(base/label))
            connection=psycopg2.connect(server.get_uri())
        stack.callback(connection.close)
        connections.append(connection)
        cursor=connection.cursor()
        cursor.execute('create schema if not exists main')
        cursor.execute("create view main.recency as select 1 as id, cast(now() + ((interval '1 hour') * (-23)) as timestamp) as created_at")
        cursor.execute('create table main.written as select current_timestamp as created_at')
        if adapter == 'postgres': connection.commit()
        verify_sql_clock(connection,adapter)
    actual,expected=connections
    assert relation_rows(actual,'main','recency') == relation_rows(expected,'main','recency')
    assert relation_rows(actual,'main','written') == relation_rows(expected,'main','written')
    cursor=actual.cursor()
    cursor.execute("create or replace view main.recency as select 1 as id, cast(now() + ((interval '1 hour') * (-22)) as timestamp) as created_at")
    if adapter == 'postgres': actual.commit()
    assert relation_rows(actual,'main','recency') != relation_rows(expected,'main','recency'), 'fixed clock must not conceal real row differences'
    print(json.dumps({'adapter':adapter,'epoch':epoch,'exact_rows':True,'real_difference_detected':True}))
""")
    result = subprocess.run([sys.executable, SCRIPTS / 'oracle_clock.py', '--',
                             sys.executable, program, tmp_path, adapter], env=environment(),
                            text=True, capture_output=True, timeout=90)
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads(result.stdout) == {'adapter': adapter, 'epoch': 1791590400,
                                       'exact_rows': True, 'real_difference_detected': True}


def test_public_clock_rejects_a_claimed_fixture_without_the_actual_preload(tmp_path):
    value = environment()
    program = tmp_path / 'unloaded.py'
    program.write_text("""import os
from oracle_clock import ACTIVE, source_fingerprint, verify_python_clock
os.environ[ACTIVE]=source_fingerprint()
verify_python_clock()
""")
    result = subprocess.run([sys.executable, program], env=value, text=True,
                            capture_output=True, timeout=15)
    assert result.returncode != 0
    assert 'realtime preload is not active' in result.stderr

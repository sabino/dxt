"""Freeze SQL wall time for a developer oracle, keeping monotonic clocks real.

The temporary preload library applies only to the launched fixture process and
its descendants, including PostgreSQL servers and native/Core commands. It is
never linked into the product or used to rewrite SQL or comparison values.
"""
from __future__ import annotations

import datetime
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


SOURCE = Path(__file__).with_suffix('.c')
EPOCH = 'DXT_ORACLE_EPOCH_SECONDS'
ACTIVE = 'DXT_PUBLIC_ORACLE_CLOCK_ACTIVE'


def source_fingerprint():
    return hashlib.sha256(SOURCE.read_bytes()).hexdigest()


def epoch_seconds(environment=None):
    environment = os.environ if environment is None else environment
    value = environment.get(EPOCH, str(int(time.time())))
    if not value.isascii() or not value.isdecimal() or not 0 <= int(value) <= 2**63 - 1:
        raise RuntimeError(f'{EPOCH} must be a nonnegative integer Unix second')
    # Reject epochs outside the Python/date domain before starting a fixture.
    datetime.datetime.fromtimestamp(int(value), datetime.timezone.utc)
    return int(value)


def verify_python_clock():
    if os.environ.get(ACTIVE) != source_fingerprint() or EPOCH not in os.environ:
        raise RuntimeError('Launch this public fixture through scripts/oracle_clock.py')
    epoch = epoch_seconds()
    expected = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)
    if time.time_ns() != epoch * 1_000_000_000 or datetime.datetime.now(datetime.timezone.utc) != expected:
        raise RuntimeError('The developer fixture realtime preload is not active')
    before = time.monotonic_ns()
    time.sleep(0.01)
    if time.monotonic_ns() <= before:
        raise RuntimeError('The developer fixture must preserve advancing monotonic time')
    return epoch


def verify_sql_clock(connection, adapter):
    """Require the actual SQL engine clock, not only Python's clock, to be fixed."""
    epoch = verify_python_clock()
    query = {
        'duckdb': 'select epoch_us(current_timestamp), epoch_us(now())',
        'postgres': 'select (extract(epoch from now())*1000000)::bigint, '
                    '(extract(epoch from clock_timestamp())*1000000)::bigint',
    }[adapter]
    cursor = connection.cursor()
    try:
        cursor.execute(query)
        values = cursor.fetchone()
    finally:
        cursor.close()
    if tuple(values) != (epoch * 1_000_000, epoch * 1_000_000):
        raise RuntimeError(f'{adapter} SQL fixture clock is not fixed: {values!r}')


def run_fixed_clock(command, *, environment=None):
    """Launch a command under one captured UTC second without changing the host."""
    if sys.platform != 'linux':
        raise RuntimeError('The public SQL oracle fixed clock requires Linux')
    environment = dict(os.environ if environment is None else environment)
    compiler = shutil.which(environment.get('CC', 'cc'))
    if compiler is None:
        raise RuntimeError('A native C compiler is required for the developer SQL clock fixture')
    epoch = epoch_seconds(environment)
    with tempfile.TemporaryDirectory(prefix='dxt-public-oracle-clock-') as directory:
        library = Path(directory) / 'clock.so'
        subprocess.run([compiler, '-std=c11', '-shared', '-fPIC', '-O2', '-Wall',
                        '-Wextra', '-Werror', str(SOURCE), '-ldl', '-o', str(library)], check=True)
        preload = environment.get('LD_PRELOAD')
        environment.update({EPOCH: str(epoch), ACTIVE: source_fingerprint(),
                            'LD_PRELOAD': str(library) + (':' + preload if preload else '')})
        return subprocess.run([str(argument) for argument in command], env=environment).returncode


def reexec_current_script(script):
    """Return None in the verified child, or the child's exit code in the launcher."""
    if ACTIVE in os.environ:
        verify_python_clock()
        return None
    return run_fixed_clock([sys.executable, Path(script).resolve(), *sys.argv[1:]])


if __name__ == '__main__':
    arguments = sys.argv[1:]
    if arguments[:1] == ['--']:
        arguments = arguments[1:]
    if not arguments:
        raise SystemExit('Usage: python scripts/oracle_clock.py -- COMMAND [ARGS...]')
    raise SystemExit(run_fixed_clock(arguments))

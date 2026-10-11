"""Developer-only isolated PostgreSQL fixtures on native Linux architectures.

Use the pinned pgserver wheel where available, or installed native PostgreSQL
tools on architectures without that wheel. This never runs inside dxt.
"""
from contextlib import contextmanager
from dataclasses import dataclass
import importlib.util
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import tempfile
from urllib.parse import quote


def _binary_directory():
    configured = os.environ.get('DXT_POSTGRES_BIN')
    if configured:
        directory = Path(configured)
        if not all((directory / name).is_file() for name in ['postgres', 'initdb', 'pg_ctl']):
            raise RuntimeError('DXT_POSTGRES_BIN must contain native postgres, initdb and pg_ctl')
        return directory
    candidates = sorted(Path('/usr/lib/postgresql').glob('*/bin'), reverse=True)
    executable = shutil.which('pg_config')
    if executable:
        result = subprocess.run([executable, '--bindir'], text=True, capture_output=True, check=True)
        candidates.insert(0, Path(result.stdout.strip()))
    return next((path for path in candidates if all((path / name).is_file()
                 for name in ['postgres', 'initdb', 'pg_ctl'])), None)


def available():
    if os.environ.get('DXT_POSTGRES_BIN'):
        return _binary_directory() is not None
    return importlib.util.find_spec('pgserver') is not None or _binary_directory() is not None


@dataclass(frozen=True)
class PostmasterInfo:
    socket_dir: Path
    port: int
    pid: int


class NativeServer:
    def __init__(self, pgdata, binaries, socket_dir, port):
        self.pgdata = Path(pgdata).resolve()
        self.binaries = binaries
        self.socket_dir = Path(socket_dir)
        self.port = port

    def command(self, name, *arguments):
        return subprocess.run([self.binaries / name, *map(str, arguments)],
                              text=True, capture_output=True, check=True, timeout=45)

    def get_postmaster_info(self):
        pid = int((self.pgdata / 'postmaster.pid').read_text().splitlines()[0])
        return PostmasterInfo(self.socket_dir, self.port, pid)

    def get_uri(self, database='postgres'):
        # A URL preserves existing fixture callers that inspect user/database,
        # while libpq receives the private Unix socket through its host option.
        return f'postgresql://postgres@/{quote(database)}?host={quote(str(self.socket_dir), safe="")}&port={self.port}'


@contextmanager
def get_server(pgdata):
    binaries = _binary_directory()
    if not os.environ.get('DXT_POSTGRES_BIN') and importlib.util.find_spec('pgserver') is not None:
        import pgserver
        with pgserver.get_server(pgdata) as server:
            yield server
        return
    if binaries is None:
        raise RuntimeError('Install native PostgreSQL tools or the pinned pgserver developer fixture')
    if os.geteuid() == 0:
        raise RuntimeError('Run native developer PostgreSQL fixtures as a non-root user')
    data = Path(pgdata).resolve()
    data.mkdir(parents=True, exist_ok=True)
    if any(data.iterdir()):
        raise RuntimeError('A native developer PostgreSQL fixture requires a fresh empty data directory')
    with tempfile.TemporaryDirectory(prefix='dxt-pg-socket-') as sockets:
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        server = NativeServer(data, binaries, sockets, port)
        server.command('initdb', '-D', data, '-A', 'trust', '-U', 'postgres',
                       '--no-locale', '--encoding=UTF8')
        options = f"-h '' -k {shlex.quote(sockets)} -p {port} -c fsync=off -c synchronous_commit=off"
        server.command('pg_ctl', '-D', data, '-l', data / 'fixture.log', '-w', '-t', '30', '-o', options, 'start')
        try:
            yield server
        finally:
            server.command('pg_ctl', '-D', data, '-w', '-t', '30', '-m', 'immediate', 'stop')

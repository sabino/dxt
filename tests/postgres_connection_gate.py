"""Developer-only causal connection faults in front of real PostgreSQL.

Each gate owns a bound TCP listener, rejects an exact number of startup
connections, then forwards subsequent sessions to the fixture's Unix socket.
No PostgreSQL SQL, authentication or response is simulated.
"""
import select
import socket
import threading
import time


class ConnectionGate:
    def __init__(self, server, reject):
        info = server.get_postmaster_info()
        self.upstream = str(info.socket_dir / f'.s.PGSQL.{info.port}')
        self.reject = reject
        self.attempt_times = []
        self.forwarded = 0
        self.errors = []
        self._stop = threading.Event()
        self._connections = []
        self._workers = []
        self._listener = socket.socket()
        self._listener.bind(('127.0.0.1', 0))
        self.port = self._listener.getsockname()[1]
        self._listener.listen()
        self._listener.settimeout(0.1)
        self._acceptor = threading.Thread(target=self._accept, daemon=True)

    def __enter__(self):
        self._acceptor.start()
        return self

    def _accept(self):
        while not self._stop.is_set():
            try:
                client, _ = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                if self._stop.is_set():
                    break
                raise
            self.attempt_times.append(time.monotonic())
            self._connections.append(client)
            rejected = len(self.attempt_times) <= self.reject
            worker = threading.Thread(target=self._session, args=(client, rejected), daemon=True)
            self._workers.append(worker)
            worker.start()

    def _session(self, client, rejected):
        upstream = None
        try:
            client.settimeout(10)
            if rejected:
                # Wait for startup bytes so the client has actually attempted
                # its protocol handshake before this transport disappears.
                client.recv(8)
                return
            upstream = socket.socket(socket.AF_UNIX)
            upstream.connect(self.upstream)
            self._connections.append(upstream)
            self.forwarded += 1
            while not self._stop.is_set():
                ready, _, _ = select.select([client, upstream], [], [], 0.1)
                for source in ready:
                    data = source.recv(65536)
                    if not data:
                        return
                    (upstream if source is client else client).sendall(data)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected when a client terminates an established session.
        except OSError as error:
            if not self._stop.is_set():
                self.errors.append(type(error).__name__)
        finally:
            client.close()
            if upstream is not None:
                upstream.close()

    def __exit__(self, *exc):
        self._stop.set()
        self._listener.close()
        self._acceptor.join(timeout=5)
        for connection in self._connections:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        for worker in self._workers:
            worker.join(timeout=5)
        assert not self._acceptor.is_alive()
        assert not any(worker.is_alive() for worker in self._workers)
        assert not self.errors, self.errors

"""Keep in-process Core oracles equivalent to separate Core CLI commands."""
from functools import wraps

import pytest


@pytest.fixture(autouse=True)
def isolate_core_cli_invocations(monkeypatch):
    try:
        from dbt.cli.main import dbtRunner
    except ModuleNotFoundError as error:
        if error.name not in {'dbt', 'dbt.cli', 'dbt.cli.main'}:
            raise
        # Native-only developer tests do not require the optional Core oracle.
        yield
        return

    from dbt.deprecations import buffered_deprecations, reset_deprecations

    original = dbtRunner.invoke

    def reset():
        reset_deprecations()
        buffered_deprecations.clear()

    @wraps(original)
    def invoke(self, *args, **kwargs):
        # Core 1.10.5 resets adapters, flags and event callbacks in preflight,
        # but its module-global deprecation counts and pending callbacks survive
        # both new runners and failed commands. A fresh CLI process has neither.
        reset()
        try:
            return original(self, *args, **kwargs)
        finally:
            reset()

    monkeypatch.setattr(dbtRunner, 'invoke', invoke)
    reset()
    try:
        yield
    finally:
        reset()

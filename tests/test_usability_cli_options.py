"""Mandatory native CLI/environment oracles against pinned dbt Core 1.10.5."""
from __future__ import annotations

import json
import os
import socket
import subprocess
import time
import urllib.request
from importlib.metadata import version
from pathlib import Path

import pytest

from test_cli import ROOT, DXT, build_dxt  # noqa: F401
from test_usability_adapters import duckdb_environment, driver, invoke as native_invoke  # noqa: F401


@pytest.fixture(autouse=True)
def pinned_core(monkeypatch):
    assert version("dbt-core") == "1.10.5"
    assert version("dbt-duckdb") == "1.9.6"
    monkeypatch.setenv("DBT_SEND_ANONYMOUS_USAGE_STATS", "false")


def project(tmp_path: Path):
    root = tmp_path / "project"
    (root / "models").mkdir(parents=True)
    (root / "analyses").mkdir()
    (root / "dbt_project.yml").write_text("name: cli_fixture\nversion: '1.0'\nconfig-version: 2\nprofile: cli_fixture\n")
    (root / "models/a.sql").write_text("{{ config(materialized='table') }} select 7 as id\n")
    (root / "models/b.sql").write_text("select * from {{ ref('a') }}\n")
    (root / "analyses/inspect.sql").write_text("select * from {{ ref('a') }}\n")
    database = root / "warehouse.duckdb"
    write_profile(root, database)
    return root, database


def write_profile(directory, database, *, schema="dev"):
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "profiles.yml").write_text(
        "cli_fixture:\n  target: dev\n  outputs:\n"
        f"    dev:\n      type: duckdb\n      path: '{database}'\n      schema: {schema}\n      threads: 1\n"
        f"    prod:\n      type: duckdb\n      path: '{database}'\n      schema: prod\n      threads: 1\n"
    )


def invoke(engine, args, cwd, environment, *, ok=True):
    executable = str(DXT) if engine == "dxt" else "dbt"
    result = subprocess.run([executable, *map(str, args)], cwd=cwd, env=environment,
                            text=True, capture_output=True, timeout=60)
    if ok:
        assert result.returncode == 0, result.stdout + result.stderr
    return result


def environment(native, **overrides):
    env = {key: value for key, value in native.items() if not key.startswith("DBT_")}
    return dict(env, DBT_SEND_ANONYMOUS_USAGE_STATS="false", **overrides)


def node(target):
    return json.loads((target / "manifest.json").read_text())["nodes"]["model.cli_fixture.a"]


def test_core_global_placement_equals_short_aliases_and_list_resource_filters(tmp_path, duckdb_environment):
    root, _ = project(tmp_path)
    env = environment(duckdb_environment)
    observed = {}
    for engine in ["dxt", "core"]:
        result = invoke(engine, ["--quiet", "-tprod", "list", f"--project-dir={root}", "-sa", "--resource-types", "model", "analysis", "--exclude-resource-type", "analysis", "--output=json", "--output-keys", "unique_id", "resource_type"], root, env)
        observed[engine] = [json.loads(line) for line in result.stdout.splitlines()]
        assert result.stderr == ""
        default = invoke(engine, ["-q", "ls", "-m", "a"], root, env)
        assert default.stdout.strip() == "cli_fixture.a"
    assert observed["dxt"] == observed["core"] == [{"unique_id": "model.cli_fixture.a", "resource_type": "model"}]


def test_core_environment_defaults_and_explicit_cli_precedence(tmp_path, duckdb_environment):
    root, _ = project(tmp_path)
    invocation = tmp_path / "invocation"
    invocation.mkdir()
    env = environment(duckdb_environment, DBT_PROJECT_DIR=str(root), DBT_PROFILES_DIR=str(root), DBT_PROFILE="cli_fixture", DBT_TARGET="prod", DBT_QUIET="true")
    for engine in ["dxt", "core"]:
        target = tmp_path / f"{engine}-target"
        env["DBT_TARGET_PATH"] = str(target)
        result = invoke(engine, ["parse"], invocation, env)
        assert result.stdout == result.stderr == ""
        assert node(target)["schema"] == "prod"
        invoke(engine, ["parse", "--target=dev"], invocation, env)
        assert node(target)["schema"] == "dev"
        duplicate = invoke(engine, ["--target", "prod", "parse", "--target=dev"], invocation, env, ok=False)
        assert duplicate.returncode == 2


def test_core_project_parent_discovery_and_cwd_then_home_profile_precedence(tmp_path, duckdb_environment):
    root, database = project(tmp_path)
    child = root / "nested" / "working"
    child.mkdir(parents=True)
    home = tmp_path / "home"
    write_profile(home / ".dbt", database, schema="home_schema")
    write_profile(child, database, schema="cwd_schema")
    env = environment(duckdb_environment, HOME=str(home))
    for engine in ["dxt", "core"]:
        target = tmp_path / f"{engine}-target"
        invoke(engine, ["-q", "parse", "--target-path", target], child, env)
        assert node(target)["schema"] == "cwd_schema"
    (child / "profiles.yml").unlink()
    for engine in ["dxt", "core"]:
        target = tmp_path / f"{engine}-target"
        invoke(engine, ["-q", "parse", "--target-path", target], child, env)
        assert node(target)["schema"] == "home_schema"


def test_core_relative_duckdb_path_uses_invocation_cwd(tmp_path, duckdb_environment, driver):
    root, _ = project(tmp_path)
    profiles = tmp_path / "profiles"
    write_profile(profiles, "relative.duckdb")
    for engine in ["dxt", "core"]:
        cwd = tmp_path / engine
        cwd.mkdir()
        invoke(engine, ["-q", "run", "--project-dir", root, "--profiles-dir", profiles, "-s", "a", "--target-path", cwd / "target"], cwd, environment(duckdb_environment))
        assert (cwd / "relative.duckdb").exists()
        assert not (profiles / "relative.duckdb").exists()
        result = native_invoke(driver, "duckdb", "query", cwd / "relative.duckdb", duckdb_environment, "select * from dev.a")
        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout) == [{"id": 7}]


@pytest.mark.parametrize("command", ["parse", "run", "compile", "docs"])
def test_core_write_json_policy_preserves_sql_execution_and_docs_exception(tmp_path, duckdb_environment, command):
    root, _ = project(tmp_path)
    for engine in ["dxt", "core"]:
        target = tmp_path / f"{engine}-target"
        args = ["-q", "--no-write-json", command]
        if command == "docs":
            args.append("generate")
        args += ["--project-dir", root, "--target-path", target]
        invoke(engine, args, root, environment(duckdb_environment))
        assert not (target / "run_results.json").exists()
        if command == "docs":
            assert (target / "manifest.json").is_file()
            assert (target / "semantic_manifest.json").is_file()
            assert (target / "catalog.json").is_file()
        else:
            assert not (target / "manifest.json").exists()
            assert not (target / "semantic_manifest.json").exists()
        if command == "compile":
            assert (target / "compiled/cli_fixture/models/a.sql").is_file()


def test_core_warn_error_and_scoped_warning_options_change_test_outcome(tmp_path, duckdb_environment):
    root, _ = project(tmp_path)
    (root / "tests").mkdir()
    (root / "tests/warning.sql").write_text("{{ config(severity='warn') }} select 1 as bad\n")
    for engine in ["dxt", "core"]:
        target = tmp_path / f"{engine}-target"
        common = ["test", "--project-dir", root, "--target-path", target]
        for flag, expected in [([], "warn"), (["--warn-error"], "fail"), (["--warn-error-options", "{error: [LogTestResult]}"], "fail"), (["--warn-error-options", "{error: all, warn: [LogTestResult]}"], "warn")]:
            result = invoke(engine, ["-q", *flag, *common], root, environment(duckdb_environment), ok=False)
            artifact = json.loads((target / "run_results.json").read_text())
            assert artifact["results"][0]["status"] == expected
            assert result.returncode == (1 if expected == "fail" else 0)


def test_native_log_filters_file_format_rotation_and_quiet_errors(tmp_path, duckdb_environment):
    root, _ = project(tmp_path)
    log_dir = tmp_path / "logs"
    args = ["--quiet", "--log-format-file=json", "--log-path", log_dir, "--log-file-max-bytes", "100", "parse", "--project-dir", root]
    for _ in range(2):
        result = invoke("dxt", args, root, environment(duckdb_environment))
        assert result.stdout == result.stderr == ""
    assert (log_dir / "dbt.log.1").is_file()
    records = [json.loads(line) for line in (log_dir / "dbt.log").read_text().splitlines()]
    assert records and all(row["info"]["level"] == "info" for row in records)
    (root / "models/a.sql").write_text("select from invalid syntax")
    result = invoke("dxt", ["--quiet", "--log-level-file", "error", "--log-path", log_dir, "run", "--project-dir", root], root, environment(duckdb_environment), ok=False)
    assert result.returncode == 1 and "error:" in result.stderr
    assert result.stdout == ""


@pytest.mark.parametrize("flags,expected_code", [
    (["--warn-error", "--warn-error-options", "{}"], 2),
    (["--warn-error-options", "{error: [UnrecognizedCoreEvent]}"], 1),
    (["--warn-error-options", "{error: all, include: all}"], 1),
    (["--warn-error-options", "{warn: [LogTestResult]}"], 1),
    (["--warn-error-options", "{include: all, exclude: [LogTestResult]}"], 2),
])
def test_core_warning_policy_invalid_values_and_legacy_deprecation_fail_before_artifacts(tmp_path, duckdb_environment, flags, expected_code):
    root, _ = project(tmp_path)
    for engine in ["dxt", "core"]:
        target = tmp_path / f"{engine}-target"
        result = invoke(engine, ["-q", *flags, "parse", "--project-dir", root, "--target-path", target], root, environment(duckdb_environment), ok=False)
        assert result.returncode == expected_code, result.stdout + result.stderr
        assert not (target / "manifest.json").exists()


def test_core_colors_and_warning_silencing_have_console_and_file_effects(tmp_path, duckdb_environment):
    root, _ = project(tmp_path)
    (root / "models/schema.yml").write_text("version: 2\nmodels:\n  - name: nonexistent\n    description: missing model\n")
    for engine in ["dxt", "core"]:
        log_dir = tmp_path / f"{engine}-logs"
        common = ["--log-path", log_dir, "--no-use-colors-file", "parse", "--project-dir", root]
        plain = invoke(engine, [*common, "--target-path", tmp_path / f"{engine}-plain"], root, environment(duckdb_environment, DBT_USE_COLORS="false"))
        assert "\x1b[" not in plain.stdout + plain.stderr
        assert "\x1b[" not in (log_dir / "dbt.log").read_text()
        colored = invoke(engine, ["--use-colors", *common, "--target-path", tmp_path / f"{engine}-colored"], root, environment(duckdb_environment, DBT_USE_COLORS="false"))
        assert "\x1b[33m" in colored.stdout + colored.stderr
        # Core's global color setting colors warning message text before file
        # formatting, while use-colors-file independently controls its prefix.
        lines = (log_dir / "dbt.log").read_text().splitlines()
        assert all(not line.startswith("\x1b[") for line in lines)
        silent = invoke(engine, ["--warn-error-options", "{silence: [NoNodeForYamlKey]}", *common, "--target-path", tmp_path / f"{engine}-silent"], root, environment(duckdb_environment, DBT_USE_COLORS="false"))
        assert "nonexistent" not in silent.stdout + silent.stderr


def test_core_docs_no_compile_no_json_writes_catalog_into_fresh_target(tmp_path, duckdb_environment):
    root, _ = project(tmp_path)
    for engine in ["dxt", "core"]:
        target = tmp_path / f"{engine}-target"
        invoke(engine, ["-q", "--no-write-json", "docs", "generate", "--no-compile", "--project-dir", root, "--target-path", target], root, environment(duckdb_environment))
        assert json.loads((target / "catalog.json").read_text())["nodes"] == {}
        assert not (target / "manifest.json").exists()
        assert not (target / "semantic_manifest.json").exists()
        assert not (target / "run_results.json").exists()


def test_core_docs_server_address_is_primary_output_under_quiet_json_logs(tmp_path, duckdb_environment):
    root, _ = project(tmp_path)
    for engine in ["dxt", "core"]:
        target = tmp_path / f"{engine}-target"
        invoke(engine, ["-q", "docs", "generate", "--project-dir", root, "--target-path", target], root, environment(duckdb_environment))
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        executable = str(DXT) if engine == "dxt" else "dbt"
        args = ["-q", "--log-format=json", "docs", "serve", "--no-browser", "--project-dir", str(root), "--target-path", str(target), "--port", str(port)]
        child = subprocess.Popen([executable, *args], cwd=root, env=environment(duckdb_environment), text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 15
            while True:
                try:
                    with urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=1) as response:
                        assert response.status == 200
                        assert "html" in response.read().decode().lower()
                    break
                except (OSError, TimeoutError):
                    assert child.poll() is None, child.communicate()
                    assert time.monotonic() < deadline
                    time.sleep(0.05)
        finally:
            child.terminate()
            output, diagnostics = child.communicate(timeout=10)
        assert f"Serving docs at {port}" in output
        assert f"http://" in output
        assert '"CommandStart"' not in diagnostics


def test_core_version_requirement_default_flag_and_environment_overrides(tmp_path, duckdb_environment):
    root, _ = project(tmp_path)
    with (root / "dbt_project.yml").open("a") as stream:
        stream.write("require-dbt-version: ['>=99.0.0']\n")
    for engine in ["dxt", "core"]:
        target = tmp_path / f"{engine}-target"
        args = ["-q", "parse", "--project-dir", root, "--target-path", target]
        failure = invoke(engine, args, root, environment(duckdb_environment), ok=False)
        assert failure.returncode == 2
        assert not (target / "manifest.json").exists()
        invoke(engine, ["--no-version-check", *args], root, environment(duckdb_environment))
        assert node(target)["name"] == "a"
        invoke(engine, args, root, environment(duckdb_environment, DBT_VERSION_CHECK="false"))
        failure = invoke(engine, ["--version-check", *args], root, environment(duckdb_environment, DBT_VERSION_CHECK="false"), ok=False)
        assert failure.returncode == 2


def test_core_print_quiet_and_no_print_preserve_debug_file_messages(tmp_path, duckdb_environment):
    root, _ = project(tmp_path)
    (root / "models/a.sql").write_text("{{ print('VISIBLE_PRINT') }}{{ log('DEBUG_MARKER') }}{{ log('INFO_MARKER', info=true) }} select 7 as id\n")
    for engine in ["dxt", "core"]:
        log_dir = tmp_path / f"{engine}-logs"
        args = ["--no-use-colors", "--no-use-colors-file", "--log-path", log_dir, "--log-level-file", "debug", "compile", "--project-dir", root, "-s", "a"]
        printed = invoke(engine, ["-q", *args], root, environment(duckdb_environment))
        assert "VISIBLE_PRINT" in printed.stdout + printed.stderr
        assert "DEBUG_MARKER" not in printed.stdout + printed.stderr
        assert "INFO_MARKER" not in printed.stdout + printed.stderr
        file = (log_dir / "dbt.log").read_text()
        assert "DEBUG_MARKER" in file and "INFO_MARKER" in file and "VISIBLE_PRINT" in file
        suppressed = invoke(engine, ["-q", "--no-print", *args], root, environment(duckdb_environment))
        assert "VISIBLE_PRINT" not in suppressed.stdout + suppressed.stderr
        env_suppressed = invoke(engine, ["-q", *args], root, environment(duckdb_environment, DBT_PRINT="false"))
        assert "VISIBLE_PRINT" not in env_suppressed.stdout + env_suppressed.stderr
        restored = invoke(engine, ["-q", "--print", *args], root, environment(duckdb_environment, DBT_PRINT="false"))
        assert "VISIBLE_PRINT" in restored.stdout + restored.stderr
        debugging = invoke(engine, ["--debug", "--log-level", "info", *args], root, environment(duckdb_environment))
        assert "DEBUG_MARKER" in debugging.stdout + debugging.stderr


def test_core_list_keeps_empty_top_level_tags_and_ignores_dotted_or_synthetic_keys(tmp_path, duckdb_environment):
    root, _ = project(tmp_path)
    env = environment(duckdb_environment)
    observed = {}
    for engine in ["dxt", "core"]:
        result = invoke(engine, ["--quiet", "ls", "--project-dir", root, "--profiles-dir", root,
                                "--select", "b", "--output", "json", "--output-keys", "name", "tags",
                                "depends_on", "config.materialized", "selector"], root, env)
        observed[engine] = json.loads(result.stdout)
        assert observed[engine]["tags"] == []
        assert "config.materialized" not in observed[engine]
        assert "selector" not in observed[engine]
    assert observed["dxt"] == observed["core"]


def test_core_empty_catalog_skips_warehouse_discovery(tmp_path, duckdb_environment):
    root, _ = project(tmp_path)
    for engine in ['dxt', 'core']:
        target = tmp_path / f'{engine}-target'
        args = ['-q', 'docs', 'generate', '--no-compile', '--empty-catalog', '--project-dir', root, '--target-path', target]
        invoke(engine, args, root, environment(duckdb_environment))
        catalog = json.loads((target / 'catalog.json').read_text())
        assert catalog['nodes'] == catalog['sources'] == {}
        assert not (target / 'run_results.json').exists()


def test_core_event_time_pair_validation_and_command_placement(tmp_path, duckdb_environment):
    root, _ = project(tmp_path)
    for engine in ['dxt', 'core']:
        for command, flags in [
            ('run', ['--event-time-start', '2024-01-01']),
            ('run', ['--event-time-end', '2024-01-02']),
            ('run', ['--event-time-start', '2024-01-02', '--event-time-end', '2024-01-01']),
            ('run', ['--event-time-start', '2024-01-01Z', '--event-time-end', '2024-01-02']),
            ('compile', ['--sample', '1 day']),
            ('parse', ['--empty']),
            ('seed', ['--empty']),
            ('snapshot', ['--sample', '1 day']),
        ]:
            result = invoke(engine, ['-q', command, '--project-dir', root, *flags], root, environment(duckdb_environment), ok=False)
            assert result.returncode == 2, (engine, command, flags, result.stdout, result.stderr)
        # An unrelated command never parses command-specific environment flags.
        invoke(engine, ['-q', 'parse', '--project-dir', root], root,
               environment(duckdb_environment, DBT_EMPTY='invalid', DBT_SAMPLE='invalid', DBT_EVENT_TIME_END='invalid'))


def test_core_sample_validation_and_explicit_override_of_environment(tmp_path, duckdb_environment):
    root, _ = project(tmp_path)
    for engine in ['dxt', 'core']:
        for value in ['bad', '1 minute', '{start: 2024-01-01}', '{start: bad, end: 2024-01-02}', '{start: 2024-01-01, end: 2024-01-02}']:
            result = invoke(engine, ['-q', 'run', '--project-dir', root, '--sample', value], root, environment(duckdb_environment), ok=False)
            assert result.returncode == 2, (engine, value, result.stdout, result.stderr)
        invoke(engine, ['-q', 'run', '--project-dir', root, '-s', 'a', '--sample', '''{start: '2024-01-01', end: '2024-01-02'}'''], root,
               environment(duckdb_environment, DBT_SAMPLE='invalid'))


def test_core_deps_accepts_profile_globals_without_loading_a_profile(tmp_path, duckdb_environment):
    root, _ = project(tmp_path)
    package = tmp_path / 'package'
    package.mkdir()
    (package / 'dbt_project.yml').write_text("name: local_pkg\nversion: '1.0'\nconfig-version: 2\n")
    (root / 'packages.yml').write_text("packages:\n  - local: ../package\n")
    (root / 'profiles.yml').unlink()
    for engine in ['dxt', 'core']:
        invoke(engine, ['-q', '--profile', 'unused', '--target', 'unused', 'deps', '--project-dir', root,
                        '--profiles-dir', tmp_path / 'no-profiles', '--state', tmp_path / 'no-state'], root, environment(duckdb_environment))
        assert (root / 'dbt_packages/local_pkg/dbt_project.yml').exists()
        assert (root / 'package-lock.yml').exists()
    with (root / 'dbt_project.yml').open('a') as stream:
        stream.write("require-dbt-version: ['>=99.0.0']\n")
    for engine in ['dxt', 'core']:
        args = ['-q', 'deps', '--project-dir', root, '--profiles-dir', tmp_path / 'no-profiles']
        result = invoke(engine, args, root, environment(duckdb_environment), ok=False)
        assert result.returncode == 2
        invoke(engine, ['--no-version-check', *args], root, environment(duckdb_environment))

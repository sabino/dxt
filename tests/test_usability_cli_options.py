"""Mandatory native CLI/environment oracles against pinned dbt Core 1.10.5."""
from __future__ import annotations

import json
import os
import subprocess
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

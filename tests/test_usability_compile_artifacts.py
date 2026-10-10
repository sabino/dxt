"""Compile/docs task durability and retry compared with pinned Core."""
import json
import subprocess
import shutil
from pathlib import Path

import pytest
import duckdb

from test_usability_commands import core_runner
from test_usability_artifacts import contracts

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out/bin/dxt"


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


def project_pair(path):
    path.mkdir()
    (path / "models").mkdir()
    (path / "seeds").mkdir()
    (path / "dbt_project.yml").write_text("name: compile_tasks\nversion: '1.0'\nprofile: compile_tasks\n")
    (path / "profiles.yml").write_text(f"compile_tasks:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n      path: {path / 'warehouse.duckdb'}\n      schema: main\n      threads: 1\n      keep_open: false\n")
    (path / "seeds/input.csv").write_text("id\n1\n")
    (path / "models/bad.sql").write_text("{% if execute and var('broken', true) %}{{ exceptions.raise_compiler_error('synthetic failure') }}{% endif %}select 1 as id")


@pytest.mark.parametrize(("command", "static", "empty_catalog"), [("compile", False, False), ("generate", True, False), ("generate", False, False), ("generate", True, True)])
def test_compile_and_docs_errors_produce_results_readable_by_core_retry(tmp_path, core_runner, command, static, empty_catalog):
    project = tmp_path / "project"
    project_pair(project)
    if empty_catalog:
        with duckdb.connect(str(project / "warehouse.duckdb")) as database:
            database.execute("create table bad as select 1 as id")
    args = ["compile"] if command == "compile" else ["docs", "generate", *(["--static"] if static else []), *(["--empty-catalog"] if empty_catalog else [])]
    native_target = project / "native"
    core_target = project / "core"
    common = ["--project-dir", str(project), "--profiles-dir", str(project)]
    native = subprocess.run([DXT, *args, *common, "--target-path", native_target, "--select", "bad"], text=True, capture_output=True)
    assert native.returncode == 1, native.stdout + native.stderr
    oracle = core_runner.invoke(["--quiet", *args, *common, "--target-path", str(core_target), "--select", "bad", "--no-partial-parse"])
    assert not oracle.success
    contracts.assert_artifact(native_target / "run_results.json")

    actual = json.loads((native_target / "run_results.json").read_text())
    assert actual["args"]["which"] == command
    assert {(row["unique_id"], row["status"], row["compiled"], row["failures"]) for row in actual["results"]} == {("model.compile_tasks.bad", "error", False, None)}
    assert actual["results"][0]["execution_time"] > 0
    if command == "generate":
        # Core turns false one-way flags into unsupported --no-* options on retry.
        if empty_catalog:
            assert actual["args"]["empty_catalog"] is True
        else:
            assert "empty_catalog" not in actual["args"]
        if not static:
            assert "static" not in actual["args"]
    # Core CompileTask.raise_on_first_error aborts before writing run results.
    # dxt's durable error artifact is an extension. Certify it by asking Core
    # itself to load that exact artifact and retry the failed model.
    assert not (core_target / "run_results.json").exists()
    shutil.copyfile(native_target / "run_results.json", core_target / "run_results.json")
    native_retry = subprocess.run([DXT, "retry", *common, "--target-path", native_target, "--vars", '{"broken":false}'], text=True, capture_output=True)
    assert native_retry.returncode == 0, native_retry.stdout + native_retry.stderr
    oracle_retry = core_runner.invoke(["--quiet", "retry", *common, "--target-path", str(core_target), "--vars", '{"broken":false}', "--no-partial-parse"])
    assert oracle_retry.success, oracle_retry.exception
    actual = json.loads((native_target / "run_results.json").read_text())
    expected = json.loads((core_target / "run_results.json").read_text())
    assert {(row["unique_id"], row["status"]) for row in actual["results"]} == {(row["unique_id"], row["status"]) for row in expected["results"]} == {("model.compile_tasks.bad", "success")}
    assert actual["results"][0]["compiled_code"].strip() == expected["results"][0]["compiled_code"].strip()
    assert [timing["name"] for timing in actual["results"][0]["timing"]] == ["compile", "execute"]
    if command == "generate":
        assert (native_target / "index.html").exists()
        if static:
            assert actual["args"]["static"] is True
            assert (native_target / "static_index.html").exists()
        else:
            assert "static" not in actual["args"]
            assert not (native_target / "static_index.html").exists()
    contracts.assert_artifact(native_target / "run_results.json")
    if empty_catalog:
        for target in [native_target, core_target]:
            results = json.loads((target / "run_results.json").read_text())
            assert results["args"]["empty_catalog"] is True
            contracts.assert_artifact(target / "run_results.json")
            contracts.assert_artifact(target / "catalog.json")
            catalog = json.loads((target / "catalog.json").read_text())
            assert catalog["nodes"] == catalog["sources"] == {}
        with duckdb.connect(str(project / "warehouse.duckdb")) as database:
            assert database.execute("select id from bad").fetchall() == [(1,)]


def test_compile_seed_emits_success_without_sql_execution(tmp_path, core_runner):
    project = tmp_path / "project"
    project_pair(project)
    common = ["--project-dir", str(project), "--profiles-dir", str(project), "--select", "resource_type:seed"]
    native_target = project / "native"
    core_target = project / "core"
    result = subprocess.run([DXT, "compile", *common, "--target-path", native_target], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    oracle = core_runner.invoke(["--quiet", "compile", *common, "--target-path", str(core_target), "--no-partial-parse"])
    assert oracle.success, oracle.exception
    native_row = json.loads((native_target / "run_results.json").read_text())["results"][0]
    core_row = json.loads((core_target / "run_results.json").read_text())["results"][0]
    for field in ["unique_id", "status", "compiled", "compiled_code", "message", "failures", "adapter_response"]:
        assert native_row[field] == core_row[field], field
    contracts.assert_artifact(native_target / "run_results.json")


@pytest.mark.parametrize("commit", [False, True])
def test_compile_database_jinja_and_statement_transactions_match_core(tmp_path, core_runner, commit):
    observed = {}
    for engine in ["native", "core"]:
        project = tmp_path / engine
        project_pair(project)
        (project / "models/bad.sql").unlink()
        (project / "models/query.sql").write_text("""{% if execute %}
{% set result = run_query('select 7 as id') %}
{% call statement('create_rows') %}create table created as select 9 as id{% endcall %}
""" + ("{% do adapter.commit() %}\n" if commit else "") + """select {{ result.columns[0].values()[0] }} as id
{% else %}select 0 as id{% endif %}""")
        common = ["compile", "--project-dir", str(project), "--profiles-dir", str(project), "--select", "query"]
        if engine == "native":
            completed = subprocess.run([DXT, *common], capture_output=True, text=True)
            assert completed.returncode == 0, completed.stderr
        else:
            completed = core_runner.invoke(["--quiet", *common, "--no-partial-parse"])
            assert completed.success, completed.exception
        artifact = json.loads((project / "target/run_results.json").read_text())["results"][0]
        with duckdb.connect(str(project / "warehouse.duckdb")) as database:
            count = database.execute("select count(*) from information_schema.tables where table_name='created'").fetchone()[0]
        observed[engine] = (artifact["compiled_code"].strip(), artifact["status"], count)
        contracts.assert_artifact(project / "target/run_results.json")
    assert observed["native"] == observed["core"] == ("select 7 as id", "success", int(commit))


def test_nested_argument_fixture_is_valid_in_pinned_core(tmp_path, core_runner):
    project = tmp_path / "arguments"
    shutil.copytree(ROOT / "tests/fixtures/generic_test_arguments", project)
    with (project / "dbt_project.yml").open("a") as stream:
        stream.write("\nprofile: compile_tasks\n")
    (project / "profiles.yml").write_text(f"compile_tasks:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n      path: {project / 'warehouse.duckdb'}\n      schema: main\n")
    common = ["compile", "--project-dir", str(project), "--profiles-dir", str(project), "--select", "test_type:generic"]
    native = subprocess.run([DXT, *common, "--target-path", "native"], capture_output=True, text=True)
    assert native.returncode == 0, native.stderr
    oracle = core_runner.invoke(["--quiet", *common, "--target-path", "core", "--no-partial-parse"])
    assert oracle.success, oracle.exception
    actual = json.loads((project / "native/run_results.json").read_text())
    expected = json.loads((project / "core/run_results.json").read_text())
    assert {(row["unique_id"], row["status"]) for row in actual["results"]} == {(row["unique_id"], row["status"]) for row in expected["results"]}
    for target in ["native", "core"]:
        contracts.assert_artifact(project / target / "manifest.json")
        contracts.assert_artifact(project / target / "run_results.json")

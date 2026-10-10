"""Native authored Python resource metadata and compile artifacts against Core.

These gates never execute authored Python models. Parsing and scaffolding are
native operations; execution is an explicit unsupported preflight outcome.
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path
from importlib.metadata import version

import pytest

from test_usability_artifacts import contracts
from test_usability_commands import core_runner

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out/bin/dxt"


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


@pytest.fixture(scope="module")
def postgres_server(tmp_path_factory):
    import postgres_fixture as pgserver
    assert pgserver.available(), "Python artifact certification requires PostgreSQL tools"
    with pgserver.get_server(tmp_path_factory.mktemp("python-model-postgres") / "data") as server:
        yield server


def project(path, code, adapter="duckdb", server=None, extra=""):
    from urllib.parse import unquote, urlparse
    (path / "models").mkdir(parents=True)
    (path / "models/base.sql").write_text("select 1 as id")
    (path / "models/py_model.py").write_text(code)
    (path / "dbt_project.yml").write_text("name: pyparity\nversion: '1.0'\nprofile: pyparity\n" + extra)
    if adapter == "duckdb":
        config = f"      type: duckdb\n      path: {path / 'warehouse.duckdb'}\n      schema: main\n"
    else:
        info = server.get_postmaster_info()
        user = unquote(urlparse(server.get_uri()).username or "postgres")
        config = f"      type: postgres\n      host: {json.dumps(str(info.socket_dir))}\n      port: {info.port}\n      dbname: postgres\n      user: {user}\n      password: ''\n      schema: pyparity\n"
    (path / "profiles.yml").write_text(f"pyparity:\n  target: dev\n  outputs:\n    dev:\n{config}      threads: 1\n")
    return path


def native(path, command, *args):
    return subprocess.run([DXT, command, "--project-dir", path, "--profiles-dir", path, "--target-path", "native", *args], text=True, capture_output=True)


def oracle(path, core_runner, command, *args):
    result = core_runner.invoke(["--quiet", command, "--project-dir", str(path), "--profiles-dir", str(path), "--target-path", "core", "--no-partial-parse", *args])
    return result


def node(path, target):
    return json.loads((path / target / "manifest.json").read_text())["nodes"]["model.pyparity.py_model"]


def compare(path, compile=False):
    actual, expected = node(path, "native"), node(path, "core")
    fields = ["name", "unique_id", "resource_type", "package_name", "path", "original_file_path", "fqn", "language", "raw_code", "checksum", "refs", "sources", "depends_on", "config", "unrendered_config", "database", "schema", "alias", "relation_name", "description", "columns", "version", "latest_version"]
    if compile:
        fields += ["compiled", "compiled_code", "extra_ctes", "extra_ctes_injected"]
    for field in fields:
        assert actual.get(field) == expected.get(field), (field, actual.get(field), expected.get(field))
    contracts.assert_artifact(path / "native/manifest.json")
    if compile:
        contracts.assert_artifact(path / "native/run_results.json")
        a = json.loads((path / "native/run_results.json").read_text())["results"]
        b = json.loads((path / "core/run_results.json").read_text())["results"]
        assert {row["unique_id"] for row in a} == {row["unique_id"] for row in b}
        ar, br = next(row for row in a if row["unique_id"].endswith("py_model")), next(row for row in b if row["unique_id"].endswith("py_model"))
        for field in ["status", "compiled", "compiled_code", "failures", "message", "adapter_response"]:
            assert ar[field] == br[field], field
        assert (path / "native/compiled/pyparity/models/py_model.py").read_text() == expected["compiled_code"]
    return actual


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_python_parse_and_compile_preserve_code_and_complete_scaffold(tmp_path, core_runner, request, adapter):
    assert version("dbt-postgres") == "1.9.1"
    server = request.getfixturevalue("postgres_server") if adapter == "postgres" else None
    code = '''\n# This file is parsed and compiled, never imported.\ndef model(dbt, session):\n    dbt.config(materialized="table", tags=["python"], meta={"owner": "á<>&'"})\n    count = dbt.config.get("count", 9007199254740993)\n    active = dbt.config.get("active", True)\n    df = dbt.ref("base")\n    return df\n\n'''
    path = project(tmp_path / "project", code, adapter, server)
    result = native(path, "parse")
    assert result.returncode == 0, result.stderr
    expected = oracle(path, core_runner, "parse")
    assert expected.success, expected.exception
    parsed = compare(path)
    assert parsed["language"] == "python"
    assert parsed["raw_code"] == code.strip()
    assert parsed["refs"] == [{"name": "base", "package": None, "version": None}]
    assert parsed["depends_on"]["macros"] == []
    result = native(path, "compile")
    assert result.returncode == 0, result.stderr
    expected = oracle(path, core_runner, "compile")
    assert expected.success, expected.exception
    compiled = compare(path, compile=True)
    assert compiled["depends_on"]["macros"] == ["macro.dbt.py_script_postfix"]
    assert "9007199254740993" in compiled["compiled_code"]


@pytest.mark.parametrize("body", [
    "    return dbt.ref('base')",
    "    x = [dbt.ref('base')]\n    return x",
    "    x = identity([dbt.ref('base')])\n    return x",
    "    x = identity({'left':dbt.ref('base')})\n    return x",
    "    x = identity(f\"{dbt.ref('base')}\")\n    return x",
    "    x = dbt.ref('base').join(dbt.ref('second'))\n    return x",
    "    x = identity(dbt.ref('base') if True else None)\n    return x",
])
def test_python_hidden_ref_traversal_and_call_order_match_core(tmp_path, core_runner, body):
    path = project(tmp_path / "project", "def model(dbt, session):\n" + body + "\n")
    (path / "models/second.sql").write_text("select 2 as id")
    result = native(path, "parse")
    assert result.returncode == 0, result.stderr
    expected = oracle(path, core_runner, "parse")
    assert expected.success, expected.exception
    compare(path)


@pytest.mark.parametrize("code", [
    "def model(dbt, session):\n    return (\n",
    "def model(other, session):\n    return other\n",
    "def model(dbt):\n    return dbt\n",
    "def model(dbt, *, session):\n    return dbt\n",
    "async def model(dbt, session):\n    return dbt\n",
    "def helper(dbt, session):\n    return dbt\n",
    "def model(dbt, session):\n    return dbt\ndef model(dbt, session):\n    return session\n",
    "def model(dbt, session):\n    if True: return dbt\n",
    "def model(dbt, session):\n    return ((dbt, session))\n",
    "def model(dbt, session):\n    return dbt.ref(name)\n",
    "def model(dbt, session):\n    return dbt.ref('base' + suffix)\n",
    "def model(dbt, session):\n    dbt.config(materialized=chosen)\n    return dbt\n",
    "def model(dbt, session):\n    dbt.config.get('x', other)\n    return dbt\n",
    "def model(dbt, session):\n    dbt.config({'materialized':'table'}, tags=['x'])\n    return dbt\n",
    "def model(dbt, session):\n    dbt.config(tags=('a','b'))\n    return dbt\n",
    "def model(dbt, session):\n    dbt.config({'tags':('a','b')})\n    return dbt\n",
    "def model(dbt, session):\n    return '{{ 1 }}'\n",
])
def test_python_invalid_source_or_dynamic_dbt_arguments_reject_like_core(tmp_path, core_runner, code):
    path = project(tmp_path / "project", code)
    result = native(path, "parse")
    expected = oracle(path, core_runner, "parse")
    assert result.returncode == 2, result.stdout + result.stderr
    assert not expected.success
    assert not (path / "warehouse.duckdb").exists()
    assert not (path / "native/manifest.json").exists()


@pytest.mark.parametrize("command", ["run", "build"])
@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_python_execution_fails_visible_before_any_selected_warehouse_writes(tmp_path, request, command, adapter):
    server = request.getfixturevalue("postgres_server") if adapter == "postgres" else None
    path = project(tmp_path / "project", "def model(dbt, session):\n    dbt.config(materialized='table')\n    return dbt.ref('base')\n", adapter, server)
    result = native(path, command)
    assert result.returncode == 2
    assert "authored Python model execution is unavailable" in result.stderr
    if adapter == "duckdb":
        assert not (path / "warehouse.duckdb").exists()
    else:
        import psycopg2
        with psycopg2.connect(server.get_uri()) as connection, connection.cursor() as cursor:
            cursor.execute("select count(*) from information_schema.tables where table_schema='pyparity'")
            assert cursor.fetchone() == (0,)


def test_python_files_are_fingerprinted_and_not_reused_as_sql_cache(tmp_path, core_runner):
    path = project(tmp_path / "project", "def model(dbt, session):\n    dbt.config(materialized='table')\n    return dbt.ref('base')\n")
    for ref in ["base", "second"]:
        (path / "models/second.sql").write_text("select 2 as id")
        (path / "models/py_model.py").write_text(f"def model(dbt, session):\n    dbt.config(materialized='table')\n    return dbt.ref('{ref}')\n")
        result = native(path, "parse")
        assert result.returncode == 0, result.stderr
        assert oracle(path, core_runner, "parse").success
        assert compare(path)["refs"][0]["name"] == ref
    cache = json.loads((path / "native/dxt_parse_cache.json").read_text())
    assert any(item["path"].endswith("models/py_model.py") for item in cache["files"])
    (path / "models/py_model.py").unlink()
    result = native(path, "parse")
    assert result.returncode == 0, result.stderr
    assert "model.pyparity.py_model" not in json.loads((path / "native/manifest.json").read_text())["nodes"]


@pytest.mark.parametrize("body", [
    "    return session",
    "    dbt.config({'materialized':'table', 'tags':['a', 'b'], 'meta':{'text':r'one\\two', 'n':-0x20000000000001, 'f':-1.25, 'nil':None, 'list':['a','b']}})\n    return dbt.ref('base')",
    "    threshold = dbt.config.get('threshold')\n    return session",
])
def test_python_literal_configs_and_empty_dependency_scaffolds_match_core(tmp_path, core_runner, body):
    path = project(tmp_path / "project", "def model(dbt, session):\n" + body + "\n")
    result = native(path, "compile")
    assert result.returncode == 0, result.stderr
    expected = oracle(path, core_runner, "compile")
    assert expected.success, expected.exception
    compare(path, compile=True)


def test_python_source_versioned_refs_and_context_metadata_use_bundled_macros(tmp_path, core_runner):
    path = project(tmp_path / "project", "def model(dbt, session):\n    dbt.config(materialized='table')\n    a = dbt.ref('pyparity', 'base', version=2)\n    b = dbt.source('raw', 'orders')\n    return a\n")
    (path / "models/base.sql").unlink()
    (path / "models/base_v1.sql").write_text("select 1 as id")
    (path / "models/base_v2.sql").write_text("select 2 as id")
    (path / "models/schema.yml").write_text("version: 2\nmodels:\n  - name: base\n    latest_version: 2\n    versions:\n      - v: 1\n      - v: 2\nsources:\n  - name: raw\n    schema: raw\n    tables:\n      - name: orders\n")
    result = native(path, "compile")
    assert result.returncode == 0, result.stderr
    expected = oracle(path, core_runner, "compile")
    assert expected.success, expected.exception
    compare(path, compile=True)


def test_python_parser_and_compiler_never_import_authored_source(tmp_path, core_runner):
    marker = tmp_path / "authored_side_effect"
    code = f"from pathlib import Path\nPath({str(marker)!r}).write_text('executed')\ndef model(dbt, session):\n    return dbt.ref('base')\n"
    path = project(tmp_path / "project", code)
    for command in ["parse", "compile"]:
        result = native(path, command)
        assert result.returncode == 0, result.stderr
        assert oracle(path, core_runner, command).success
        assert not marker.exists()
        compare(path, compile=command == "compile")


def test_project_can_override_python_scaffold_with_typed_model_context(tmp_path, core_runner):
    path = project(tmp_path / "project", "def model(dbt, session):\n    return dbt.ref('base')\n")
    (path / "macros").mkdir()
    (path / "macros/scaffold.sql").write_text("{% macro py_script_postfix(model) %}# language={{ model.language }} refs={{ model.refs | tojson }} fqn={{ model.fqn | tojson }} code={{ model.raw_code | tojson }}{% endmacro %}")
    result = native(path, "compile")
    assert result.returncode == 0, result.stderr
    assert oracle(path, core_runner, "compile").success
    compiled = compare(path, compile=True)
    assert compiled["depends_on"]["macros"] == ["macro.pyparity.py_script_postfix"]


@pytest.mark.parametrize("body", ["print 'python2'", "exec 'x=1'"])
def test_python2_statements_reject_under_pinned_python3_core(tmp_path, core_runner, body):
    path = project(tmp_path / "project", f"def model(dbt, session):\n    {body}\n    return dbt\n")
    result = native(path, "parse")
    assert result.returncode == 2, result.stdout + result.stderr
    assert not oracle(path, core_runner, "parse").success


def test_core_postgres_language_guard_never_executes_authored_python(tmp_path, core_runner, postgres_server):
    marker = tmp_path / "pg_authored_side_effect"
    code = f"from pathlib import Path\nPath({str(marker)!r}).write_text('executed')\ndef model(dbt, session):\n    return dbt.ref('base')\n"
    path = project(tmp_path / "project", code, "postgres", postgres_server)
    expected = oracle(path, core_runner, "run", "--select", "py_model")
    assert not expected.success
    rows = json.loads((path / "core/run_results.json").read_text())["results"]
    assert [(row["unique_id"], row["status"]) for row in rows] == [("model.pyparity.py_model", "error")]
    assert "python" in rows[0]["message"].lower() and "language" in rows[0]["message"].lower()
    assert not marker.exists()
    result = native(path, "run", "--select", "py_model")
    assert result.returncode == 2 and "authored Python model execution is unavailable" in result.stderr
    assert not marker.exists()


def test_relational_parse_identity_and_empty_cte_compilation_match_core(tmp_path, core_runner):
    path = project(tmp_path / "project", "def model(dbt, session):\n    return dbt.ref('base')\n")
    (path / "models/ephemeral.sql").write_text("{{ config(materialized='ephemeral') }}select 2 as id")
    (path / "models/disabled.sql").write_text("{{ config(enabled=false) }}select 3 as id")
    (path / "seeds").mkdir()
    (path / "seeds/input.csv").write_text("id\n1\n")
    (path / "analyses").mkdir()
    (path / "analyses/report.sql").write_text("select 4 as id")
    (path / "snapshots").mkdir()
    (path / "snapshots/history.sql").write_text("{% snapshot history %}{{ config(strategy='timestamp',unique_key='id',updated_at='ts',target_schema='archive') }}select 1 as id, timestamp '2020-01-01' as ts{% endsnapshot %}")
    (path / "tests").mkdir()
    (path / "tests/assert_input.sql").write_text("select 1 as id where false")
    (path / "models/schema.yml").write_text("version: 2\nmodels:\n  - name: base\n    columns:\n      - name: id\n        data_tests: [not_null]\nsources:\n  - name: raw\n    schema: raw\n    tables: [{name: input}]\n")
    (path / "models/mixed.sql").write_text("select * from {{ ref('base') }} union all select * from {{ source('raw','input') }}")
    for command in ["parse", "compile"]:
        result = native(path, command)
        assert result.returncode == 0, result.stderr
        assert oracle(path, core_runner, command).success
        actual = json.loads((path / "native/manifest.json").read_text())
        expected = json.loads((path / "core/manifest.json").read_text())
        for unique_id in expected["nodes"]:
            a, b = actual["nodes"][unique_id], expected["nodes"][unique_id]
            if b["resource_type"] != "test":
                assert a.get("relation_name") == b.get("relation_name"), (unique_id, a.get("relation_name"), b.get("relation_name"))
                assert a["depends_on"] == b["depends_on"], unique_id
            if b.get("compiled"):
                assert a["extra_ctes_injected"] == b["extra_ctes_injected"] is True, unique_id
        assert actual["disabled"]["model.pyparity.disabled"][0]["relation_name"] == expected["disabled"]["model.pyparity.disabled"][0]["relation_name"]
        contracts.assert_artifact(path / "native/manifest.json")


@pytest.mark.parametrize("signature", ["dbt: object, session: object", "dbt, session=None", "dbt: object, session: object=None", "dbt, session, *args, **kwargs", "dbt, session, *args: object, **kwargs: object"])
def test_python_model_signature_annotations_and_defaults_match_core(tmp_path, core_runner, signature):
    path = project(tmp_path / "project", f"def model({signature}):\n    return dbt.ref('base')\n")
    result = native(path, "compile")
    assert result.returncode == 0, result.stderr
    assert oracle(path, core_runner, "compile").success
    compare(path, compile=True)


@pytest.mark.parametrize("code", [
    "def model(dbt=None, session):\n    return dbt\n",
    "def model(dbt, session):\n    x = identity(named=1, dbt.ref('base'))\n    return x\n",
])
def test_python3_ast_rejects_permissive_editor_grammar_forms(tmp_path, core_runner, code):
    path = project(tmp_path / "project", code)
    result = native(path, "parse")
    assert result.returncode == 2, result.stderr
    assert not oracle(path, core_runner, "parse").success


def test_native_python_metadata_preserves_large_literal_beyond_core_msgpack_limit(tmp_path, core_runner):
    path = project(tmp_path / "project", "def model(dbt, session):\n    dbt.config(meta={'n':0x1000000000000000000000000})\n    return session\n")
    result = native(path, "parse")
    assert result.returncode == 0, result.stderr
    assert node(path, "native")["config"]["meta"]["n"] == 2 ** 96
    contracts.assert_artifact(path / "native/manifest.json")
    # Pinned Core evaluates this legal literal, then its mandatory MessagePack
    # parser-cache serialization overflows. Native JSON metadata has no such
    # serializer limit; record the observed difference explicitly.
    expected = oracle(path, core_runner, "parse")
    assert not expected.success and isinstance(expected.exception, OverflowError)

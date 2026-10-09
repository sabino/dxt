"""Native persistent parse reuse and invalidation, with actual pinned Core."""
import json
import os
import subprocess
from pathlib import Path

import pytest

from test_usability_commands import core_runner
from test_usability_groups import project_at, GROUPS
from test_usability_artifacts import contracts

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out/bin/dxt"


@pytest.fixture(scope="module", autouse=True)
def binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


def native(project, *extra, environment=None):
    result = subprocess.run([DXT, "parse", "--debug", "--no-use-colors", "--project-dir", str(project),
                             "--profiles-dir", str(project), "--target-path", "native", *extra],
                            env=environment, capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    events = [json.loads(line) for line in result.stderr.splitlines() if line.startswith('{')]
    cache = next(event["data"] for event in events if event["info"]["name"] == "NativeParseCache")
    manifest = json.loads((project / "native/manifest.json").read_text())
    contracts.assert_artifact(project / "native/manifest.json")
    return cache, manifest


def equivalent(left, right):
    assert {k: v for k, v in left.items() if k != "metadata"} == {
        k: v for k, v in right.items() if k != "metadata"}


def test_persistent_cache_reuses_full_graph_groups_and_unit_configs(tmp_path, core_runner):
    project = tmp_path / "project"
    project_at(project, GROUPS)
    (project / "tests").mkdir()
    (project / "tests/verify.sql").write_text("{{ config(group='finance') }}select * from {{ ref('base') }} where id < 0")
    (project / "models/units.yml").write_text("""version: 2
unit_tests:
  - name: exact
    model: consumer
    given: [{input: "ref('base')", rows: [{id: 1}]}]
    expect: {rows: [{id: 1}]}
""")
    cold, first = native(project)
    warm, second = native(project)
    assert cold == {"hit": False, "reason": "missing", "changed_files": 0, "reused_files": 0}
    assert warm == {"hit": True, "reason": "unchanged", "changed_files": 0, "reused_files": 0}
    equivalent(first, second)
    stored = json.loads((project / "native/dxt_parse_cache.json").read_text())
    for borrowed in ["allocator", "relation_cache", "invocation", "timing_profile", "environment",
                     "connection_info", "command_options", "execution_hooks", "target_context"]:
        assert borrowed not in stored["graph"]
    oracle = core_runner.invoke(["--quiet", "parse", "--project-dir", str(project), "--profiles-dir", str(project),
                                 "--target-path", "core", "--no-partial-parse"])
    assert oracle.success, oracle.exception
    expected = json.loads((project / "core/manifest.json").read_text())
    assert second["groups"] == expected["groups"]
    # Core's creation clock belongs to its invocation, not the parse graph.
    assert {key: {field: value for field, value in unit.items() if field != "created_at"}
            for key, unit in second["unit_tests"].items()} == {
                key: {field: value for field, value in unit.items() if field != "created_at"}
                for key, unit in expected["unit_tests"].items()}
    for key, node in second["nodes"].items():
        if node["package_name"] == "ownership":
            assert node["config"] == expected["nodes"][key]["config"]
            assert node["depends_on"] == expected["nodes"][key]["depends_on"]


@pytest.mark.parametrize("change", ["edit", "delete", "add", "yaml", "macro", "seed", "env", "vars", "package"])
def test_changed_inputs_reparse_and_never_reuse_stale_graph(tmp_path, change):
    project = tmp_path / "project"
    project_at(project, GROUPS, {"base": "select {{ env_var('CACHE_VALUE', '1') }} as id", "consumer": "select * from {{ ref('base') }}"})
    (project / "macros").mkdir()
    (project / "macros/value.sql").write_text("{% macro value() %}{{ return(1) }}{% endmacro %}")
    (project / "seeds").mkdir()
    (project / "seeds/rows.csv").write_text("id\n1\n")
    native(project)
    assert native(project)[0]["hit"]
    extra, environment = [], None
    if change == "edit":
        file = project / "models/base.sql"
        before = file.stat()
        file.write_text(file.read_text().replace("'1'", "'2'"))
        os.utime(file, ns=(before.st_atime_ns, before.st_mtime_ns))
    elif change == "delete":
        (project / "models/consumer.sql").unlink()
        (project / "models/nested/groups.yml").write_text("version: 2\ngroups: [{name: finance, owner: {name: Finance}}]\nmodels: [{name: base, config: {group: finance}}]\n")
    elif change == "add":
        (project / "models/new.sql").write_text("select 3 as id")
    elif change == "yaml":
        file = project / "models/nested/groups.yml"
        file.write_text(file.read_text().replace("Financial reporting", "Changed description"))
    elif change == "macro":
        (project / "macros/value.sql").write_text("{% macro value() %}{{ return(2) }}{% endmacro %}")
    elif change == "seed":
        (project / "seeds/rows.csv").write_text("id\n2\n")
    elif change == "env":
        environment = dict(os.environ, CACHE_VALUE="2")
    elif change == "vars":
        extra = ["--vars", "{team: finance, extra: 2}"]
    elif change == "package":
        package = project / "dbt_packages/dependency"
        (package / "models").mkdir(parents=True)
        (package / "dbt_project.yml").write_text("name: dependency\nversion: '1.0'\n")
        (package / "models/external.sql").write_text("select 5 as id")
    changed, manifest = native(project, *extra, environment=environment)
    assert not changed["hit"] and changed["reason"] == "changed"
    assert native(project, *extra, environment=environment)[0]["hit"]
    if change == "edit": assert "'2'" in manifest["nodes"]["model.ownership.base"]["raw_code"]
    if change == "delete": assert "model.ownership.consumer" not in manifest["nodes"]
    if change == "add": assert "model.ownership.new" in manifest["nodes"]
    if change == "package": assert "model.dependency.external" in manifest["nodes"]


@pytest.mark.parametrize("damage", ["truncated", "schema", "graph", "fingerprint"])
def test_invalid_cache_falls_back_to_real_native_parser(tmp_path, damage):
    project = tmp_path / "project"
    project_at(project, GROUPS)
    _, original = native(project)
    cache = project / "native/dxt_parse_cache.json"
    stored = json.loads(cache.read_text())
    if damage == "truncated": cache.write_text('{"schema":')
    else:
        stored[damage] = "invalid"
        cache.write_text(json.dumps(stored))
    event, reparsed = native(project)
    assert not event["hit"]
    equivalent(original, reparsed)
    assert native(project)[0]["hit"]


def test_changed_literal_model_reuses_unchanged_files_before_applying_current_properties(tmp_path, core_runner):
    project = tmp_path / "project"
    project_at(project, GROUPS)
    native(project)
    (project / "models/base.sql").write_text("{{ config(materialized='table') }}select 2 as id")
    event, changed = native(project)
    assert event == {"hit": False, "reason": "changed", "changed_files": 1, "reused_files": 1}
    oracle = core_runner.invoke(["--quiet", "parse", "--project-dir", str(project), "--profiles-dir", str(project),
                                 "--target-path", "core", "--no-partial-parse"])
    assert oracle.success, oracle.exception
    core = json.loads((project / "core/manifest.json").read_text())
    for key in ["model.ownership.base", "model.ownership.consumer"]:
        for field in ["config", "raw_code", "refs", "depends_on", "columns"]:
            assert changed["nodes"][key][field] == core["nodes"][key][field]
    properties = project / "models/nested/groups.yml"
    properties.write_text(properties.read_text().replace("access: public", "access: protected"))
    event, patched = native(project)
    assert event["reused_files"] == 2 and event["changed_files"] == 1
    assert patched["nodes"]["model.ownership.consumer"]["access"] == "protected"
    assert native(project)[0]["hit"]


def test_dynamic_macro_consumers_reparse_after_macro_edits(tmp_path):
    project = tmp_path / "project"
    project_at(project, "version: 2\n", {"base": "{{ config(meta={'value': value()}) }}select 1 as id", "consumer": "select 2 as id"})
    (project / "macros").mkdir()
    (project / "macros/value.sql").write_text("{% macro value() %}{{ return(1) }}{% endmacro %}")
    native(project)
    (project / "macros/value.sql").write_text("{% macro value() %}{{ return(2) }}{% endmacro %}")
    event, manifest = native(project)
    assert event["reused_files"] == 1
    assert manifest["nodes"]["model.ownership.base"]["config"]["meta"] == {"value": 2}

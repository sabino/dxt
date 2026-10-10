"""Core schema tests render only their seeded, ordered macro dependency closure."""
import json
import subprocess
from pathlib import Path

import pytest

from test_usability_configuration import (
    ConfigurationPair, configuration_oracle, configuration_postgres, configure_adapter,
)
from test_usability_unmatched_generic_tests import compare_tests

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


def setup_case(pair, case):
    for package in ["alpha", "zeta"]:
        folder = ("zz_alpha" if package == "alpha" else "aa_zeta") if case == "folder_order" else package
        pair.write(f"dbt_packages/{folder}/dbt_project.yml", f"name: {package}\nversion: '1.0'\n")
        body = "{{ config(severity='warn',meta={'body':'" + package + "'},tags=['" + package + "']) }}select * from {{ model }} where {{ column_name }} < 0"
        if case in {"hidden_body_error", "visible_body_error"} and package == "alpha":
            body = "{{ exceptions.raise_compiler_error('visible namespace body') }}"
        pair.write(f"dbt_packages/{folder}/macros/positive.sql", "{% test positive(model,column_name) %}" + body + "{% endtest %}")
    root = "models/marts"
    authored = "alpha.positive"
    if case in {"root_override", "transitive_collision", "visible_body_error", "nested_collision", "custom_getwhere", "custom_getwhere_error", "argument_hidden", "argument_visible", "dependency_getwhere", "static_order", "static_reverse_order"}:
        expose = ""
        if case in {"transitive_collision", "visible_body_error"}:
            expose = "{% if false %}{{ alpha.test_positive(model,column_name) }}{% endif %}"
        if case == "nested_collision":
            expose = "{% if false %}{{ alpha.bridge(model,column_name) }}{% endif %}"
            pair.write("dbt_packages/alpha/macros/bridge.sql", "{% macro bridge(model,column_name) %}{% if false %}{{ zeta.test_positive(model,column_name) }}{% endif %}{% endmacro %}")
        if case == "argument_visible":
            expose = "{% if false %}{{ zeta.hidden() }}{% endif %}"
        if case in {"static_order", "static_reverse_order"}:
            packages = ["zeta", "alpha"] if case == "static_reverse_order" else ["alpha", "zeta"]
            expose = "{% if false %}" + "".join("{{ " + package + ".choose() }}" for package in packages) + "{% endif %}"
            for package in packages:
                pair.write(f"dbt_packages/{package}/macros/choose.sql", "{% macro choose() %}{{ return('" + package + "') }}{% endmacro %}")
        config = "{{ config(severity='error',meta={'body':'root'},tags=['root']) }}"
        if case in {"static_order", "static_reverse_order"}:
            config = "{{ config(meta={'choice':choose()}) }}"
        pair.write("macros/positive.sql", "{% test positive(model,column_name,extra=none) %}" + expose + config + "select * from {{ model }} where {{ column_name }} < 0{% endtest %}")
        if case != "root_override":
            authored = "positive"
    if case == "package_local":
        root = "dbt_packages/alpha/models"
        authored = "positive"
    if case == "custom_getwhere":
        pair.write("macros/get_where_subquery.sql", "{% macro get_where_subquery(relation) %}{{ config(meta={'helper':'root'}) }}{{ return(relation) }}{% endmacro %}")
    if case == "custom_getwhere_error":
        pair.write("macros/get_where_subquery.sql", "{% macro get_where_subquery(relation) %}{{ exceptions.raise_compiler_error('visible namespace helper') }}{% endmacro %}")
    if case == "dependency_getwhere":
        root = "dbt_packages/alpha/models"
        for package in ["alpha", "zeta"]:
            pair.write(f"dbt_packages/{package}/macros/get_where_subquery.sql", "{% macro get_where_subquery(relation) %}{{ config(meta={'helper':'" + package + "'}) }}{{ return(relation) }}{% endmacro %}")
    if case in {"argument_hidden", "argument_visible"}:
        pair.write("dbt_packages/zeta/macros/hidden.sql", "{% macro hidden() %}{{ exceptions.raise_compiler_error('visible namespace argument') }}{% endmacro %}")
        authored = {"positive": {"extra": "{{ zeta.hidden() }}"}}
    if case == "builtin_shortcut":
        authored = "not_null"
        pair.write("macros/get_where_subquery.sql", "{% macro get_where_subquery(relation) %}{{ exceptions.raise_compiler_error('shortcut must not render') }}{% endmacro %}")
    pair.write(root + "/input.sql", "select 1 as id")
    pair.write(root + "/schema.yml", json.dumps({"version": 2, "models": [{
        "name": "input", "columns": [{"name": "id", "data_tests": [authored]}],
    }]}))


POSITIVE = ["two_packages", "folder_order", "root_override", "package_local", "transitive_collision", "nested_collision", "custom_getwhere", "dependency_getwhere", "argument_hidden", "hidden_body_error", "builtin_shortcut", "static_order", "static_reverse_order"]


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("case", POSITIVE)
def test_generic_parse_namespace_matches_core(tmp_path, configuration_oracle, request, adapter, case):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    setup_case(pair, case)
    manifests = pair.invoke("parse", flags=["--no-partial-parse"])
    identifiers = compare_tests(pair, manifests)
    assert len(identifiers) == 1
    if case in {"static_order", "static_reverse_order"}:
        packages = ["zeta", "alpha"] if case == "static_reverse_order" else ["alpha", "zeta"]
        expected = [f"macro.{package}.choose" for package in packages]
        for manifest in manifests:
            assert manifest["macros"]["macro.configuration_fixture.test_positive"]["depends_on"]["macros"] == expected


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("case, message", [
    ("argument_visible", "visible namespace argument"),
    ("visible_body_error", "visible namespace body"),
    ("custom_getwhere_error", "visible namespace helper"),
])
def test_visible_generic_macro_keeps_core_error(tmp_path, configuration_oracle, request, adapter, case, message):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    setup_case(pair, case)
    result, reference = pair.invoke("parse", flags=["--no-partial-parse"], success=False)
    assert message in str(reference.exception)
    assert message in result.stdout + result.stderr
    assert "Unsupported" not in result.stderr


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_generic_namespace_order_survives_native_warm_parse(tmp_path, configuration_oracle, request, adapter):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    setup_case(pair, "folder_order")
    cold = pair.invoke("parse", flags=["--no-partial-parse"])
    identifiers = compare_tests(pair, cold)
    warm = pair.invoke("parse")
    assert compare_tests(pair, warm) == identifiers
    for key in identifiers:
        # Core's fresh parses create a new node timestamp. Changing the
        # partial-parse flag also changes the native saved context.
        assert {field: value for field, value in warm[0]["nodes"][key].items() if field != "created_at"} == {
            field: value for field, value in cold[0]["nodes"][key].items() if field != "created_at"}
    cache = json.loads((pair.projects[0] / "target/dxt_parse_cache.json").read_text())
    stored = {macro["package_name"]: macro["namespace_order"] for macro in cache["graph"]["macros"] if macro["name"] == "test_positive"}
    assert stored["alpha"] > stored["zeta"]
    # Logging flags form part of the parse context: use the same flags for a
    # fresh fill and reuse so the debug witness proves a real cache hit.
    command = [ROOT / "zig-out/bin/dxt", "parse", "--debug", "--log-format", "json",
               "--project-dir", pair.projects[0], "--profiles-dir", pair.projects[0]]
    subprocess.run(command, capture_output=True, text=True, check=True)
    filled = json.loads((pair.projects[0] / "target/manifest.json").read_text())
    reused = subprocess.run(command, capture_output=True, text=True, check=True)
    events = [json.loads(line) for line in reused.stderr.splitlines() if line.startswith('{')]
    event = next(row["data"] for row in events if row["info"]["name"] == "NativeParseCache")
    assert event == {"hit": True, "reason": "unchanged", "changed_files": 0, "reused_files": 0}
    restored = json.loads((pair.projects[0] / "target/manifest.json").read_text())
    for key in identifiers:
        assert restored["nodes"][key] == filled["nodes"][key]

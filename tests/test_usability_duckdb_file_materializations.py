"""Native external files and table functions against dbt-duckdb 1.9.6."""
from __future__ import annotations

import json

import pytest
from test_usability_materializations import (
    artifact_validator, build_dxt, invoke, model, oracle_available,
    project_at, query, successful,
)


def pair_at(path):
    oracle_available("duckdb")
    return [project_at(path / name, "duckdb") for name in ("native", "core")]


def run_pair(projects, success=True):
    for project, engine in zip(projects, ("dxt", "dbt")):
        result = invoke(project, engine)
        if success:
            successful(result)
        else:
            assert result.returncode != 0, result.stdout + result.stderr
        artifact_validator.assert_artifact(project / "target/run_results.json")
        rows = json.loads((project / "target/run_results.json").read_text())["results"]
        assert all(row["status"] == ("success" if success else "error") for row in rows)


def contents(projects, relation="history"):
    actual = [query(project, "duckdb", f"select * from {relation} order by all") for project in projects]
    assert actual[0] == actual[1]
    columns = [query(project, "duckdb", f"describe {relation}") for project in projects]
    assert columns[0] == columns[1]
    return actual[0]


@pytest.mark.parametrize("format", ["csv", "parquet", "json"])
def test_external_first_repeat_schema_change_empty_and_copy_failure(tmp_path, format):
    projects = pair_at(tmp_path)
    for project in projects:
        location = project / f"rows.{format}"
        model(project, "select 1 id,'first' as name", "external", f", location='{location}',format='{format}'")
    run_pair(projects)
    assert contents(projects) == [(1, "first")]
    run_pair(projects)
    assert contents(projects) == [(1, "first")]
    for project in projects:
        location = project / f"rows.{format}"
        model(project, "select 2 id,'changed' as name,3 as added", "external", f", location='{location}',format='{format}'")
    run_pair(projects)
    assert contents(projects) == [(2, "changed", 3)]
    for project in projects:
        location = project / f"rows.{format}"
        model(project, "select 2::integer id,'empty'::varchar as name,3::integer as added where false", "external", f", location='{location}',format='{format}'")
    run_pair(projects)
    assert contents(projects) == []
    before = [(project / f"rows.{format}").read_bytes() for project in projects]
    for project in projects:
        location = project / f"rows.{format}"
        model(project, "select 99 as id", "external", f", location='{location}',format='{format}',options={{'compression':'INVALID_COMPRESSION'}}")
    run_pair(projects, success=False)
    for project, original in zip(projects, before):
        assert (project / f"rows.{format}").read_bytes() == original
    assert contents(projects) == []


def test_external_partition_directory_options_and_reader(tmp_path):
    projects = pair_at(tmp_path)
    for project in projects:
        location = project / "parts"
        model(project, "select 1 id,'a' as name union all select 2,'b'", "external", f",location='{location}',format='parquet',options={{'partition_by':'id','compression':'zstd'}},parquet_read_options={{'hive_partitioning':true,'union_by_name':true}}")
    run_pair(projects)
    assert contents(projects) == [("a", 1), ("b", 2)]
    # The stock adapter rejects a nonempty partition directory by default.
    run_pair(projects, success=False)
    assert contents(projects) == [("a", 1), ("b", 2)]
    for project in projects:
        location = project / "parts"
        model(project, "select 3 id,'c' as name", "external", f",location='{location}',format='parquet',options={{'partition_by':'id','overwrite_or_ignore':true}},parquet_read_options={{'hive_partitioning':true,'union_by_name':true}}")
    run_pair(projects)
    assert contents(projects) == [("a", 1), ("b", 2), ("c", 3)]
    assert sorted(str(path.relative_to(projects[0] / "parts")) for path in (projects[0] / "parts").rglob("*.parquet"))


def test_external_root_rendered_location_delimiter_and_read_options(tmp_path):
    projects = pair_at(tmp_path)
    for project in projects:
        profile = project / "profiles.yml"
        profile.write_text(profile.read_text()+f"      external_root: {project / 'outputs'}\n")
        (project / "outputs").mkdir()
        model(project, "select 1 as id,'a;b' as label", "external", ",format='csv',delimiter=';',csv_read_options={'delim':';','auto_detect':true}")
    run_pair(projects)
    assert contents(projects) == [(1, "a;b")]
    for project in projects:
        assert (project / "outputs/history.csv").exists()
        location = project / "{{ this.identifier }}.parquet"
        model(project, "select 9 as id", "external", f",location='{location}'")
    run_pair(projects)
    assert contents(projects) == [(9,)]
    assert all((project / "history.parquet").exists() for project in projects)


@pytest.mark.parametrize("parameters", ["'minimum'", "['minimum']", "'minimum, maximum'"])
def test_table_function_parameters_consumers_and_late_bound_schema(tmp_path, parameters):
    projects = pair_at(tmp_path)
    for project in projects:
        (project / "models/base.sql").write_text("{{ config(materialized='table') }} select 1 as id union all select 2 union all select 3")
        two = "maximum" in parameters
        model(project, "select * from {{ ref('base') }} where id >= minimum" + (" and id <= maximum" if two else ""), "table_function", ",parameters="+parameters)
        (project / "models/consumer.sql").write_text("select * from {{ ref('history') }}(" + ("2,3" if two else "2") + ")")
    run_pair(projects)
    assert contents(projects, "consumer") == [(2,), (3,)]
    for project in projects:
        query(project, "duckdb", "alter table base add column added integer default 7")
        args = "2,3" if "maximum" in parameters else "2"
        assert query(project, "duckdb", f"select * from history({args}) order by id") == [(2, 7), (3, 7)]
        # A table macro has no physical table/view catalog entry.
        assert query(project, "duckdb", "select table_type from information_schema.tables where table_name='history'") == []
        assert query(project, "duckdb", "select function_type from duckdb_functions() where function_name='history'") == [("table_macro",)]


def test_external_native_reader_failure_restores_original_file_and_relation(tmp_path):
    project = project_at(tmp_path / "native", "duckdb")
    location = project / "history.parquet"
    model(project, "select 1 as id", "external", f",location='{location}'")
    successful(invoke(project))
    original = location.read_bytes()
    model(project, "select 2 as id,3 as added", "external", f",location='{location}',parquet_read_options={{'hive_partitioning':'PRIVATE_INVALID_BOOLEAN'}}")
    result = invoke(project)
    assert result.returncode != 0
    assert "PRIVATE_INVALID_BOOLEAN" not in result.stdout+result.stderr
    assert location.read_bytes() == original
    assert query(project, "duckdb", "select * from history") == [(1,)]
    assert not list(project.glob("*.dxt-stage-*"))
    assert not list(project.glob("*.dxt-backup-*"))
    assert query(project, "duckdb", "select table_name from information_schema.tables where table_name='history__dbt_tmp'") == []


def test_external_native_directory_reader_failure_restores_all_partition_files(tmp_path):
    project = project_at(tmp_path / "native", "duckdb")
    location = project / "parts"
    model(project, "select 1 as id,'first' as name", "external", f",location='{location}',format='parquet',options={{'partition_by':'id'}}")
    successful(invoke(project))
    original = {str(path.relative_to(location)): path.read_bytes() for path in location.rglob("*.parquet")}
    model(project, "select 2 as id,'changed' as name,3 as added", "external", f",location='{location}',format='parquet',options={{'partition_by':'id','overwrite_or_ignore':true}},parquet_read_options={{'hive_partitioning':'PRIVATE_INVALID_BOOLEAN'}}")
    result = invoke(project)
    assert result.returncode != 0
    assert {str(path.relative_to(location)): path.read_bytes() for path in location.rglob("*.parquet")} == original
    assert query(project, "duckdb", "select * from history") == [("first", 1)]
    assert not list(project.glob("*.dxt-stage-*"))
    assert not list(project.glob("*.dxt-backup-*"))


def test_external_missing_parent_is_a_transactional_error(tmp_path):
    projects = pair_at(tmp_path)
    for project in projects:
        location = project / "missing" / "history.parquet"
        model(project, "select 1 as id", "external", f",location='{location}'")
    run_pair(projects, success=False)
    for project in projects:
        assert not (project / "missing").exists()
        assert query(project, "duckdb", "select table_name from information_schema.tables where table_name='history'") == []

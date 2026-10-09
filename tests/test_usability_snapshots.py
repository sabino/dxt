"""Real DuckDB SCD2 execution and optional pinned dbt 1.10.5 oracle."""
from __future__ import annotations

import hashlib
import importlib.metadata
import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

from test_cli import build_dxt  # shared session fixture

ROOT = Path(__file__).resolve().parents[1]
DXT = ROOT / "zig-out/bin/dxt"
DUCKDB = shutil.which("duckdb")
pytestmark = pytest.mark.skipif(DUCKDB is None, reason="DuckDB CLI unavailable")


def query(project: Path, sql: str):
    result = subprocess.run([DUCKDB, str(project / "warehouse.duckdb"), "-json", "-batch", "-bail", "-c", sql], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout or "[]")


def project_at(path: Path, config: str, *, strategy="timestamp", updated_at="ts") -> Path:
    (path / "snapshots").mkdir(parents=True)
    (path / "dbt_project.yml").write_text("name: snapshot_runtime\nversion: '1.0'\nconfig-version: 2\nprofile: snapshot_runtime\n")
    (path / "profiles.yml").write_text(f"snapshot_runtime:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n      path: {path / 'warehouse.duckdb'}\n      schema: main\n      threads: 1\n")
    settings = f"strategy='{strategy}',unique_key='id',target_schema='archive'," + (f"updated_at='{updated_at}'," if updated_at else "") + config
    (path / "snapshots/history.sql").write_text("{% snapshot history %}\n{{ config(" + settings.rstrip(",") + ") }}\nselect * from main.input; -- supported trailing comment\n{% endsnapshot %}\n")
    query(path, "create table input(id integer, name varchar, ts timestamp); insert into input values(1, 'Alice', '2020-01-01'),(2, NULL, '2020-01-02')")
    return path


def run(project: Path, command="snapshot", *args: str, executable=DXT):
    env = {**os.environ, "DBT_SEND_ANONYMOUS_USAGE_STATS": "false"}
    return subprocess.run([str(executable), command, "--project-dir", str(project), "--profiles-dir", str(project), *args], text=True, capture_output=True, env=env)


def snapshot(project: Path, **kwargs):
    result = run(project, **kwargs)
    assert result.returncode == 0, result.stdout + result.stderr
    return query(project, "select * from archive.history order by id, dbt_valid_from, dbt_scd_id")


def assert_hashes(rows):
    for row in rows:
        if row.get("dbt_is_deleted") != "True":
            material = f"{row['id'] or ''}|{row['dbt_updated_at'] or ''}".encode()
            assert row["dbt_scd_id"] == hashlib.md5(material).hexdigest()


@pytest.mark.parametrize("deletes", ["ignore", "invalidate", "new_record"])
def test_timestamp_snapshot_mutation_repeat_delete_return(tmp_path, deletes):
    project = project_at(tmp_path / "dxt", f"hard_deletes='{deletes}'")
    initial = snapshot(project)
    assert len(initial) == 2
    assert snapshot(project) == initial
    assert_hashes(initial)
    query(project, "update input set name='Alicia', ts='2020-02-01' where id=1")
    updated = snapshot(project)
    assert len(updated) == 3
    old, current = updated[:2]
    assert old["name"] == "Alice" and old["dbt_valid_to"] == "2020-02-01 00:00:00"
    assert current["name"] == "Alicia" and current["dbt_valid_to"] is None
    assert snapshot(project) == updated
    # Timestamp snapshots ignore value changes with the same or older updated_at.
    query(project, "update input set name='Ignored', ts='2019-01-01' where id=1")
    assert snapshot(project) == updated
    query(project, "delete from input where id=1")
    deleted = snapshot(project)
    assert len(deleted) == 3 + (deletes == "new_record")
    assert snapshot(project) == deleted
    if deletes == "ignore":
        assert deleted[1]["dbt_valid_to"] is None
    else:
        assert deleted[1]["dbt_valid_to"] is not None
    if deletes == "new_record":
        tombstone = deleted[2]
        assert tombstone["dbt_is_deleted"] == "True"
        assert tombstone["dbt_valid_to"] is None
        assert tombstone["dbt_valid_from"] == tombstone["dbt_updated_at"] == deleted[1]["dbt_valid_to"]
        assert tombstone["dbt_scd_id"] == hashlib.md5(f"{deleted[1]['dbt_scd_id']}|{tombstone['dbt_updated_at']}".encode()).hexdigest()
    query(project, "insert into input values(1,'Returned','2020-03-01')")
    returned = snapshot(project)
    assert sum(row["id"] == 1 and row["dbt_valid_to"] is None for row in returned) == 1
    assert any(row["name"] == "Returned" and row["dbt_valid_to"] is None for row in returned)
    result = json.loads((project / "target/run_results.json").read_text())["results"][0]
    assert result["unique_id"] == "snapshot.snapshot_runtime.history" and result["status"] == "success"
    assert result["compiled"] is True and '"archive"."history"' in result["relation_name"]


@pytest.mark.parametrize("columns", ["['name']", "'all'"])
def test_check_snapshot_nulls_and_schema_evolution(tmp_path, columns):
    project = project_at(tmp_path / "dxt", f"check_cols={columns}", strategy="check")
    initial = snapshot(project)
    assert snapshot(project) == initial
    query(project, "update input set name='Bob', ts='2020-02-01' where id=2")
    updated = snapshot(project)
    assert len(updated) == 3
    assert [r for r in updated if r['id'] == 2][0]["dbt_valid_to"] == "2020-02-01 00:00:00"
    query(project, "alter table input add column extra varchar; update input set extra='new'")
    expanded = snapshot(project)
    assert len(expanded) == (5 if columns == "'all'" else 3)
    assert all("extra" in row for row in expanded)
    assert snapshot(project) == expanded
    assert_hashes(expanded)


def test_check_snapshot_default_clock_and_legacy_delete(tmp_path):
    project = project_at(tmp_path / "dxt", "check_cols=['name'],invalidate_hard_deletes=true", strategy="check", updated_at=None)
    initial = snapshot(project)
    assert all(row["dbt_updated_at"] == row["dbt_valid_from"] for row in initial)
    assert snapshot(project) == initial
    query(project, "update input set name='Changed' where id=1")
    changed = snapshot(project)
    old, current = [row for row in changed if row["id"] == 1]
    assert old["dbt_valid_to"] == current["dbt_valid_from"]
    assert_hashes(changed)
    query(project, "delete from input where id=1")
    deleted = snapshot(project)
    assert len(deleted) == 3 and all(r['dbt_valid_to'] is not None for r in deleted if r['id'] == 1)


def test_snapshot_custom_metadata_sentinel_and_composite_key(tmp_path):
    project = project_at(tmp_path / "dxt", "dbt_valid_to_current=\"timestamp '9999-12-31'\",snapshot_meta_column_names={'dbt_scd_id':'scd','dbt_updated_at':'updated','dbt_valid_from':'valid_from','dbt_valid_to':'valid_to'}")
    path = project / "snapshots/history.sql"
    path.write_text(path.read_text().replace("unique_key='id'", "unique_key=['id','name']"))
    assert run(project).returncode == 0
    before = query(project, "select * from archive.history order by id")
    assert before[0]["valid_to"] == "9999-12-31 00:00:00"
    assert run(project).returncode == 0
    assert query(project, "select * from archive.history order by id") == before
    query(project, "update input set ts='2020-02-01' where id=2")
    assert run(project).returncode == 0
    rows = query(project, "select * from archive.history order by id,valid_from")
    assert len(rows) == 3
    assert rows[1]['valid_to'] == '2020-02-01 00:00:00'
    assert rows[2]['valid_to'] == '9999-12-31 00:00:00'


def test_snapshot_runtime_error_is_atomic_and_sanitized(tmp_path):
    project = project_at(tmp_path / "dxt", "check_cols=['name']", strategy="check")
    before = snapshot(project)
    # A successful ALTER precedes the invalid sentinel insert in the transaction.
    query(project, "alter table input add column extra varchar; update input set name='New',ts='2020-02-01'")
    path = project / 'snapshots/history.sql'
    path.write_text(path.read_text().replace("check_cols=['name']", "check_cols=['name'],dbt_valid_to_current=\"cast('PRIVATE_BAD_SENTINEL' as timestamp)\""))
    result = run(project)
    assert result.returncode != 0 and 'PRIVATE_BAD_SENTINEL' not in result.stderr
    assert query(project, "select * from archive.history order by id,dbt_valid_from,dbt_scd_id") == before
    assert not query(project, "select column_name from information_schema.columns where table_schema='archive' and table_name='history' and column_name='extra'")
    results = json.loads((project / 'target/run_results.json').read_text())['results']
    assert results[0]['status'] == 'error' and 'PRIVATE_BAD_SENTINEL' not in results[0]['message']


def test_build_snapshot_and_downstream_model(tmp_path):
    project = project_at(tmp_path / "dxt", "")
    (project / 'models').mkdir()
    (project / 'models/current.sql').write_text("{{ config(materialized='table') }}\nselect * from {{ ref('history') }} where dbt_valid_to is null\n")
    (project / 'tests').mkdir()
    (project / 'tests/history_ok.sql').write_text("select * from {{ ref('history') }} where id < 0\n")
    result = run(project, 'build')
    assert result.returncode == 0, result.stderr
    assert len(query(project, 'select * from main.current')) == 2
    results = json.loads((project / 'target/run_results.json').read_text())['results']
    assert [r['unique_id'] for r in results] == ['snapshot.snapshot_runtime.history','test.snapshot_runtime.history_ok','model.snapshot_runtime.current']
    assert [r['status'] for r in results] == ['success','pass','success']
    assert run(project, 'run').returncode == 0
    assert run(project, 'test').returncode == 0
    assert run(project, 'snapshot', '--select', 'history').returncode == 0


def pinned_dbt():
    dbt = shutil.which('dbt')
    if dbt is None:
        pytest.skip('optional dbt oracle is unavailable')
    assert importlib.metadata.version('dbt-core') == '1.10.5'
    assert importlib.metadata.version('dbt-duckdb') == '1.9.6'
    return dbt


@pytest.mark.parametrize('strategy,config', [('timestamp',"hard_deletes='ignore'"),('timestamp',"hard_deletes='invalidate'"),('timestamp',"hard_deletes='new_record'"),('check',"check_cols='all',hard_deletes='new_record'")])
def test_snapshot_pinned_dbt_relation_oracle(tmp_path, strategy, config, monkeypatch):
    dbt = pinned_dbt()
    monkeypatch.setenv('DBT_SEND_ANONYMOUS_USAGE_STATS','false')
    own = project_at(tmp_path / 'dxt', config, strategy=strategy)
    upstream = project_at(tmp_path / 'dbt', config, strategy=strategy)
    for project in (own, upstream):
        path = project / 'snapshots/history.sql'
        path.write_text(path.read_text().replace('; -- supported trailing comment', ''))
    for mutation in [None,"update input set name='Alicia',ts='2020-02-01' where id=1",None,"delete from input where id=1",None,"insert into input values(1,'Returned','2020-03-01')"]:
        if mutation:
            query(own,mutation);query(upstream,mutation)
        actual = snapshot(own)
        expected = snapshot(upstream,executable=dbt)
        # Delete processing uses each process's transaction clock. Compare row values,
        # closure states, and deterministic source timestamps/hashes; validate clock hashes separately.
        def normalized(rows):
            result=[]
            for row in rows:
                item=dict(row)
                if item.get('dbt_is_deleted')=='True':
                    item['dbt_scd_id']='tombstone hash'
                for field in ('dbt_updated_at','dbt_valid_from','dbt_valid_to'):
                    if item[field] and not item[field].startswith('2020-'):
                        item[field]='snapshot clock'
                result.append(item)
            return sorted(result,key=lambda x:(x['id'],x['name'],str(x['dbt_valid_from']),str(x.get('dbt_is_deleted'))))
        assert normalized(actual)==normalized(expected)
        assert_hashes(actual);assert_hashes(expected)
    # Both runners roll back when the source query fails.
    for project, executable in ((own, DXT), (upstream, dbt)):
        before = query(project, 'select * from archive.history order by id,dbt_valid_from,dbt_scd_id')
        path = project / 'snapshots/history.sql'
        path.write_text(path.read_text().replace('main.input', 'main.missing_relation'))
        failed = run(project, executable=executable)
        assert failed.returncode != 0
        assert query(project, 'select * from archive.history order by id,dbt_valid_from,dbt_scd_id') == before
    import jsonschema
    schema=json.loads((ROOT/'tests/schemas/dbt_manifest_v12_snapshot.schema.json').read_text())
    manifest=json.loads((own/'target/manifest.json').read_text())
    jsonschema.validate(manifest['nodes']['snapshot.snapshot_runtime.history'],schema)


def test_snapshot_empty_source_and_target_overrides(tmp_path):
    project = project_at(tmp_path / 'dxt', "target_database='warehouse',alias='physical_history',tags=['nightly']")
    query(project, 'delete from input')
    result = run(project, 'snapshot', '--select', 'tag:nightly')
    assert result.returncode == 0, result.stderr
    assert query(project, 'select * from archive.physical_history') == []
    query(project, "insert into input values(1,'Alice','2020-01-01')")
    assert run(project).returncode == 0
    assert len(query(project, 'select * from archive.physical_history')) == 1
    manifest = json.loads((project/'target/manifest.json').read_text())
    node = manifest['nodes']['snapshot.snapshot_runtime.history']
    assert (node['database'],node['schema'],node['alias']) == ('warehouse','archive','physical_history')
    assert node['relation_name'] == '"warehouse"."archive"."physical_history"'
    generated = subprocess.run([str(DXT),'docs','generate','--project-dir',str(project),'--profiles-dir',str(project)],text=True,capture_output=True)
    assert generated.returncode == 0, generated.stderr
    catalog = json.loads((project/'target/catalog.json').read_text())['nodes']['snapshot.snapshot_runtime.history']
    assert catalog['metadata']['schema'] == 'archive' and catalog['metadata']['name'] == 'physical_history'
    assert 'dbt_scd_id' in catalog['columns']

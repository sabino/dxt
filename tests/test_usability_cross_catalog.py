"""Actual warehouse commits and fail-closed budgets across catalog retention."""
from __future__ import annotations

import json
import time

import pytest

from test_usability_cross_database import (
    duck_rows, invoke, native_environment, postgres, project, state,
)


def catalog_path(project):
    return project[0] / ".dxt" / "cross-catalog.json"


def read_catalog(project):
    return json.loads(catalog_path(project).read_text())


def assert_published(project, generation, prior_runs):
    catalog = read_catalog(project)
    recorded = state(project)[1]
    assert recorded["models"][0]["status"] == "success"
    assert catalog["generation"] == generation
    assert len(catalog["runs"]) == prior_runs + 1
    assert catalog["runs"][-1]["run_id"] == recorded["run_id"]
    assert catalog["runs"][-1]["tasks"][0]["status"] == "success"
    assert duck_rows(project[3], "select * from marts.joined") == [(1, "O'Brien", 10)]
    return catalog


@pytest.mark.parametrize("seed_kind", ["expired_and_future", "fresh"])
def test_full_catalog_admits_changed_query_after_warehouse_commit(project, native_environment, seed_kind):
    config = project[1]
    source = config["models"]["joined"]["inputs"]["customers"]
    source.pop("estimated_rows")
    source.pop("estimated_bytes")
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode == 0, result.stderr
    catalog = assert_published(project, 1, 0)
    actual = catalog["relation_stats"][0]
    now = int(time.time())
    seeded = []
    for index in range(4096):
        stat = dict(actual, query_hash=f"seed-{index}", observed_epoch=now - 100,
                    expires_epoch=now + 86400)
        if seed_kind == "expired_and_future":
            if index % 2:
                stat.update(observed_epoch=now + 3600, expires_epoch=now + 86400)
            else:
                stat.update(expires_epoch=now - 1)
        seeded.append(stat)
    catalog["relation_stats"] = seeded
    catalog_path(project).write_text(json.dumps(catalog))
    source["filter"] = "enabled and id = 1"
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode == 0, result.stderr
    catalog = assert_published(project, 2, 1)
    stats = catalog["relation_stats"]
    assert len(stats) == (1 if seed_kind == "expired_and_future" else 4096)
    assert stats[-1]["query_hash"] not in {stat["query_hash"] for stat in seeded}
    if seed_kind == "fresh":
        assert [stat["query_hash"] for stat in stats[:-1]] == [f"seed-{index}" for index in range(1, 4096)]
    # Repeating the same complete identity at capacity replaces the observation.
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode == 0, result.stderr
    repeated = assert_published(project, 3, 2)
    assert len(repeated["relation_stats"]) == len(stats)
    assert repeated["relation_stats"][-1]["run_id"] == repeated["runs"][-1]["run_id"]
    assert repeated["relation_stats"][-1]["query_hash"] == stats[-1]["query_hash"]


def test_evicted_actual_query_is_unknown_and_runtime_budget_rolls_back(project, native_environment):
    config = project[1]
    source = config["models"]["joined"]["inputs"]["customers"]
    source.pop("estimated_rows")
    source.pop("estimated_bytes")
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode == 0, result.stderr
    catalog = read_catalog(project)
    actual = catalog["relation_stats"][0]
    now = int(time.time())
    actual.update(observed_epoch=now - 100, expires_epoch=now + 86400)
    catalog["relation_stats"] = [actual] + [
        dict(actual, query_hash=f"newer-{index}", observed_epoch=now - 50)
        for index in range(4095)
    ]
    catalog_path(project).write_text(json.dumps(catalog))
    source["filter"] = "enabled and id = 1"
    result = invoke(project, config, native_environment, "run", "--allow-movement")
    assert result.returncode == 0, result.stderr
    retained = assert_published(project, 2, 1)
    assert len(retained["relation_stats"]) == 4096
    assert actual["query_hash"] not in {stat["query_hash"] for stat in retained["relation_stats"]}
    source["filter"] = "enabled"
    result = invoke(project, config, native_environment, "plan", "--allow-movement")
    assert result.returncode == 0, result.stderr
    plan = json.loads((project[0] / "target" / "dxt_plan.json").read_text())
    assert plan["models"][0]["confidence"] == "unknown"
    assert plan["models"][0]["estimated_rows"] == 0
    import duckdb
    with duckdb.connect(str(project[3])) as connection:
        connection.execute("update marts.joined set quantity = 999")
    before = read_catalog(project)
    result = invoke(project, config, native_environment, "run", "--allow-movement", "--max-bytes", "0")
    assert result.returncode != 0
    assert "budget" in result.stderr.lower()
    assert duck_rows(project[3], "select * from marts.joined") == [(1, "O'Brien", 999)]
    after = read_catalog(project)
    assert after["relation_stats"] == before["relation_stats"]
    assert after["generation"] == before["generation"] + 1
    assert after["runs"][-1]["tasks"][0]["status"] != "success"
    assert state(project)[1]["models"][0]["status"] != "success"

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "agent_os_orchestrator.py"
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("agent_os_orchestrator", SCRIPT)
assert SPEC is not None
agent_os_orchestrator = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(agent_os_orchestrator)


def test_dependency_numbers_from_issue_comments() -> None:
    issue = {
        "number": 158,
        "body": "Primary issue.",
        "comments": [
            {"body": "<!-- dxt-agent-event:v1 status=queued depends_on=#157 -->"},
            {"body": "blocked by: #160 until project fields land"},
        ],
    }

    assert agent_os_orchestrator.issue_dependency_numbers(issue) == {157, 160}


def test_launch_blockers_wait_for_open_dependencies() -> None:
    issue = {
        "number": 158,
        "body": "depends_on=#157",
        "labels": [{"name": "risk:branch-overlap"}, {"name": "type:ci"}],
        "comments": [],
    }
    snapshot = {
        "dependency_states": {157: "OPEN"},
        "active_runs": [],
        "open_prs": [],
        "worktrees": [],
    }

    assert agent_os_orchestrator.launch_blockers(issue, "agent/issue-158", snapshot) == [
        "waiting for dependency #157=OPEN"
    ]


def test_launch_blockers_detect_expected_file_overlap() -> None:
    issue = {
        "number": 158,
        "body": "- files expected: `scripts/agent_os_orchestrator.py`, `docs/AGENT_OS.md`",
        "labels": [{"name": "type:ci"}],
        "comments": [],
    }
    snapshot = {
        "dependency_states": {},
        "active_runs": [],
        "open_prs": [{"number": 31, "files": [{"path": "docs/AGENT_OS.md"}]}],
        "worktrees": [],
    }

    assert agent_os_orchestrator.launch_blockers(issue, "agent/issue-158", snapshot) == [
        "open PR #31 touches expected files docs/AGENT_OS.md"
    ]


def test_merge_queue_blocks_conflicts_and_allows_first_green_pr() -> None:
    prs = [
        {
            "number": 10,
            "isDraft": False,
            "checks_ok": True,
            "checks_summary": "all checks green",
            "mergeStateStatus": "CLEAN",
            "files": [{"path": "scripts/agent_os_orchestrator.py"}],
            "body": "",
        },
        {
            "number": 11,
            "isDraft": False,
            "checks_ok": True,
            "checks_summary": "all checks green",
            "mergeStateStatus": "CLEAN",
            "files": [{"path": "scripts/agent_os_orchestrator.py"}],
            "body": "",
        },
        {
            "number": 12,
            "isDraft": False,
            "checks_ok": True,
            "checks_summary": "all checks green",
            "mergeStateStatus": "DIRTY",
            "files": [{"path": "docs/AGENT_OS.md"}],
            "body": "",
        },
    ]

    queued, blocked = agent_os_orchestrator.plan_merge_queue(prs, {})

    assert [item["number"] for item in queued] == [10]
    assert [item["number"] for item in blocked] == [11, 12]
    assert blocked[0]["blocked_reasons"] == [
        "overlaps PR #10 files: scripts/agent_os_orchestrator.py"
    ]
    assert blocked[1]["blocked_reasons"] == ["requires rebase or repair: merge state DIRTY"]


def test_merge_queue_blocks_open_pr_dependencies() -> None:
    pr = {
        "number": 20,
        "isDraft": False,
        "checks_ok": True,
        "checks_summary": "all checks green",
        "mergeStateStatus": "CLEAN",
        "files": [{"path": "docs/AGENT_OS.md"}],
        "body": "depends_on=#19",
    }

    queued, blocked = agent_os_orchestrator.plan_merge_queue([pr], {19: "OPEN"})

    assert queued == []
    assert blocked[0]["blocked_reasons"] == ["waiting for dependency #19=OPEN"]

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


def test_stale_exited_runs_report_merged_or_closed_without_requiring_live_pr() -> None:
    runs = [
        {
            "issue_number": 158,
            "status": "exited",
            "branch": "agent/issue-158-agent-os-supervisor",
        },
        {
            "issue_number": 159,
            "status": "exited",
            "branch": "agent/issue-159-specialists",
        },
        {
            "issue_number": 160,
            "status": "running",
            "branch": "agent/issue-160-project-fields",
        },
    ]
    issue_details = {159: {"state": "CLOSED"}}
    merged = {
        "agent/issue-158-agent-os-supervisor": True,
        "agent/issue-159-specialists": False,
    }

    stale = agent_os_orchestrator.plan_stale_exited_runs(runs, issue_details, [], merged)

    assert [(item["issue_number"], item["reasons"], item["live_pr"]) for item in stale] == [
        (158, ["branch merged"], False),
        (159, ["issue closed"], False),
    ]


def test_stale_claims_require_exited_worker_or_closed_issue_and_no_live_pr() -> None:
    claimed = [
        {
            "number": 158,
            "state": "OPEN",
            "comments": [
                {
                    "body": "<!-- dxt-agent-event:v1 status=claimed role=supervisor branch=agent/issue-158-supervisor -->"
                }
            ],
        },
        {
            "number": 159,
            "state": "OPEN",
            "comments": [{"body": "- Branch: `agent/issue-159-specialists`"}],
        },
        {
            "number": 160,
            "state": "OPEN",
            "comments": [{"body": "- Branch: `agent/issue-160-project-fields`"}],
        },
    ]
    runs = [
        {"issue_number": 158, "status": "exited", "branch": "agent/issue-158-supervisor"},
        {"issue_number": 159, "status": "running", "branch": "agent/issue-159-specialists"},
    ]

    stale, unresolved = agent_os_orchestrator.plan_stale_claims(claimed, runs, [])

    assert stale == [
        {
            "issue_number": 158,
            "branch": "agent/issue-158-supervisor",
            "reason": "exited worker without live PR",
        }
    ]
    assert unresolved == [
        {
            "issue_number": 160,
            "branch": "agent/issue-160-project-fields",
            "reason": "claimed label has no local exited worker evidence",
        }
    ]


def test_stale_claims_keep_issue_with_live_pr() -> None:
    claimed = [
        {
            "number": 158,
            "state": "OPEN",
            "comments": [{"body": "- Branch: `agent/issue-158-supervisor`"}],
        }
    ]
    runs = [{"issue_number": 158, "status": "exited", "branch": "agent/issue-158-supervisor"}]
    prs = [{"headRefName": "agent/issue-158-supervisor", "closingIssuesReferences": []}]

    stale, unresolved = agent_os_orchestrator.plan_stale_claims(claimed, runs, prs)

    assert stale == []
    assert unresolved == []


def test_worktree_cleanup_only_removes_clean_merged_agent_worktrees(tmp_path, monkeypatch) -> None:
    current = tmp_path / "current"
    merged = tmp_path / "merged"
    dirty = tmp_path / "dirty"
    main = tmp_path / "main"
    for path in (current, merged, dirty, main):
        path.mkdir()

    def fake_merged(branch: str | None, base: str) -> bool:
        return branch in {
            "agent/issue-158-supervisor",
            "agent/issue-159-dirty",
            "main",
        }

    def fake_dirty(path: Path) -> set[str]:
        if path == dirty:
            return {"scripts/agent_os_orchestrator.py"}
        return set()

    def fake_status(path: Path) -> list[str]:
        return [f"## {path.name}"]

    monkeypatch.setattr(agent_os_orchestrator, "branch_merged_into_base", fake_merged)
    monkeypatch.setattr(agent_os_orchestrator, "worktree_dirty_files", fake_dirty)
    monkeypatch.setattr(agent_os_orchestrator, "worktree_status_short", fake_status)

    removable, kept = agent_os_orchestrator.plan_worktree_cleanup(
        [
            {"branch": "agent/issue-161-current", "worktree": str(current)},
            {"branch": "agent/issue-158-supervisor", "worktree": str(merged)},
            {"branch": "agent/issue-159-dirty", "worktree": str(dirty)},
            {"branch": "main", "worktree": str(main)},
        ],
        "origin/main",
        current,
    )

    assert [item["branch"] for item in removable] == ["agent/issue-158-supervisor"]
    kept_by_branch = {item["branch"]: item["reasons"] for item in kept}
    assert kept_by_branch["agent/issue-161-current"] == ["branch not merged", "current worktree"]
    assert kept_by_branch["agent/issue-159-dirty"] == ["dirty worktree"]
    assert kept_by_branch["main"] == ["not an agent branch"]

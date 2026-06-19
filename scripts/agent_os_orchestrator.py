#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from check_agent_os_config import ORCHESTRATOR_PATH, load_json, validate_config


ROOT = Path(__file__).resolve().parents[1]
STATE_DIR = ROOT / ".agent" / "runs" / "agent-os"
STATE_PATH = STATE_DIR / "state.json"


def no_color_env() -> dict[str, str]:
    env = os.environ.copy()
    env["NO_COLOR"] = "1"
    env["CLICOLOR"] = "0"
    env["CLICOLOR_FORCE"] = "0"
    env["GH_FORCE_TTY"] = "0"
    env["TERM"] = "dumb"
    env.pop("FORCE_COLOR", None)
    return env


def run_cmd(
    cmd: list[str],
    *,
    cwd: Path = ROOT,
    check: bool = True,
    capture: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=cwd,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        env=no_color_env(),
    )


def gh(args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return run_cmd(["gh", *args], check=check)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def slugify(value: str, limit: int = 48) -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", value.strip().lower()).strip("-")
    return (slug or "slice")[:limit].strip("-") or "slice"


def default_repo() -> str:
    result = gh(["repo", "view", "--json", "nameWithOwner"], check=False)
    if result.returncode != 0:
        return "sabino/dxt"
    return json.loads(result.stdout)["nameWithOwner"]


def load_orchestrator() -> dict[str, Any]:
    data = load_json(ORCHESTRATOR_PATH)
    if not isinstance(data, dict):
        raise ValueError(".github/agent-team/orchestrator.json must be an object")
    return data


def load_state() -> dict[str, Any]:
    if not STATE_PATH.exists():
        return {"runs": []}
    return json.loads(STATE_PATH.read_text(encoding="utf-8"))


def save_state(state: dict[str, Any]) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(STATE_PATH)


def issue_labels(issue: dict[str, Any]) -> set[str]:
    labels = issue.get("labels") or []
    return {label["name"] for label in labels if isinstance(label, dict) and isinstance(label.get("name"), str)}


def pick_role(config: dict[str, Any], labels: set[str]) -> dict[str, Any]:
    for role in config["role_map"]:
        if role["label"] in labels:
            return role
    return {
        "label": "role:supervisor",
        "agent": config["fallback_agent"],
        "mode": "plan",
        "sandbox": "read-only",
    }


def is_ready(config: dict[str, Any], labels: set[str]) -> bool:
    if labels.intersection(config["blocked_labels"]):
        return False
    return bool(labels.intersection(config["ready_labels"]))


def fetch_candidate_issues(repo: str, config: dict[str, Any], limit: int) -> list[dict[str, Any]]:
    result = gh(
        [
            "issue",
            "list",
            "--repo",
            repo,
            "--state",
            "open",
            "--limit",
            str(max(limit * 4, 20)),
            "--json",
            "number,title,body,labels,url,assignees,comments",
        ],
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip())
    issues = json.loads(result.stdout)
    ready = [issue for issue in issues if is_ready(config, issue_labels(issue))]
    return ready[:limit]


def active_runs(state: dict[str, Any]) -> list[dict[str, Any]]:
    active: list[dict[str, Any]] = []
    for run in state.get("runs", []):
        if run.get("status") != "running":
            continue
        pid = int(run["pid"])
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            run["status"] = "exited"
            run["exited_at"] = utc_now()
        else:
            active.append(run)
    return active


def issue_already_running(state: dict[str, Any], issue_number: int) -> bool:
    for run in active_runs(state):
        if int(run.get("issue_number", -1)) == issue_number:
            return True
    return False


def branch_exists(branch: str) -> bool:
    result = run_cmd(["git", "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"], check=False, capture=False)
    return result.returncode == 0


def ensure_worktree(branch: str, base: str, worktree_root: Path, dry_run: bool) -> Path:
    worktree = worktree_root / branch
    if dry_run:
        return worktree
    if worktree.exists():
        return worktree
    run_cmd(["git", "fetch", "origin"], capture=False)
    worktree.parent.mkdir(parents=True, exist_ok=True)
    if branch_exists(branch):
        run_cmd(["git", "worktree", "add", str(worktree), branch], capture=False)
    else:
        run_cmd(["git", "worktree", "add", str(worktree), "-b", branch, base], capture=False)
    (worktree / ".agent" / "runs").mkdir(parents=True, exist_ok=True)
    return worktree


def safe_issue_text(issue: dict[str, Any]) -> str:
    comments = issue.get("comments") or []
    latest_comments = comments[-5:] if isinstance(comments, list) else []
    payload = {
        "number": issue["number"],
        "title": issue["title"],
        "url": issue["url"],
        "labels": sorted(issue_labels(issue)),
        "body": issue.get("body") or "",
        "latest_comments": [
            {
                "author": item.get("author", {}).get("login", "unknown"),
                "body": item.get("body") or "",
                "createdAt": item.get("createdAt"),
            }
            for item in latest_comments
            if isinstance(item, dict)
        ],
    }
    return json.dumps(payload, indent=2, sort_keys=True)


def worker_prompt(
    *,
    repo: str,
    issue: dict[str, Any],
    role: dict[str, Any],
    branch: str,
    create_pr: bool,
    merge_ready: bool,
) -> str:
    action = "plan/research/comment only"
    if role["mode"] in {"implement", "docs", "qa"}:
        action = "implement one coherent slice if the issue is ready"
    return f"""You are the dxt autonomous worker for GitHub issue #{issue['number']} in {repo}.

Role file: .codex/agents/{role['agent']}.toml
Branch: {branch}
Mode: {role['mode']}
Action: {action}

Required startup:
1. Read AGENTS.md, PLAN.md, docs/AGENT_OS.md, docs/AGENT_PROTOCOLS.md, docs/MULTI_AGENT_WORKFLOW.md, and the role file.
2. Inspect git status and confirm this worktree owns only this issue/branch.
3. Re-read the GitHub issue and recent comments with gh before making decisions, because the user may nudge through issue comments.

Issue payload at launch:
```json
{safe_issue_text(issue)}
```

Rules:
- Product runtime behavior must stay in Zig.
- Python is allowed only for developer scripts, tests, fixtures, dbt oracle checks, schema validation, public-safety scans, and orchestration.
- Keep raw logs under .agent/runs/ only.
- Use public-safe issue comments from docs/AGENT_PROTOCOLS.md for claims, plans, validation, and handoff.
- If scope is unclear, comment a slice plan and stop instead of making broad product changes.
- If you make code/docs changes, run the fastest relevant validation, inspect git diff/status, commit a coherent change, push the branch, and open or update a PR linked to the issue.
- Do not merge the PR yourself unless explicitly instructed by the supervisor loop.

PR policy for this run:
- create_or_update_pr={str(create_pr).lower()}
- supervisor_may_merge_green_prs={str(merge_ready).lower()}

Finish by commenting on the issue with a concise handoff: changed files, validation, PR link if any, and remaining risk.
"""


def claim_issue(repo: str, issue: dict[str, Any], role: dict[str, Any], branch: str, dry_run: bool) -> None:
    body = f"""<!-- dxt-agent-event:v1 status=claimed role={role['agent']} branch={branch} -->
## Agent Claim

- Role: `{role['agent']}`
- Branch: `{branch}`
- Mode: `{role['mode']}`
- Claimed at: `{utc_now()}`
"""
    if dry_run:
        print(f"would claim issue #{issue['number']} as {role['agent']} on {branch}")
        return
    gh(["issue", "comment", str(issue["number"]), "--repo", repo, "--body", body])
    gh(["issue", "edit", str(issue["number"]), "--repo", repo, "--add-label", "status:claimed"], check=False)


def launch_worker(
    *,
    repo: str,
    issue: dict[str, Any],
    role: dict[str, Any],
    branch: str,
    worktree: Path,
    profile: str,
    model: str,
    create_pr: bool,
    merge_ready: bool,
    dry_run: bool,
) -> dict[str, Any]:
    run_dir = worktree / ".agent" / "runs"
    run_dir.mkdir(parents=True, exist_ok=True)
    log_path = run_dir / f"agent-os-issue-{issue['number']}.log"
    last_path = run_dir / f"agent-os-issue-{issue['number']}-last.md"
    prompt = worker_prompt(
        repo=repo,
        issue=issue,
        role=role,
        branch=branch,
        create_pr=create_pr,
        merge_ready=merge_ready,
    )
    cmd = [
        "codex",
        "-p",
        profile,
        "-m",
        model,
        "-C",
        str(worktree),
        "--ask-for-approval",
        "never",
        "--sandbox",
        role["sandbox"],
        "exec",
        "--output-last-message",
        str(last_path),
        prompt,
    ]
    if dry_run:
        print("would launch:")
        print("  " + " ".join(cmd[:13]) + " <prompt>")
        return {
            "issue_number": issue["number"],
            "branch": branch,
            "worktree": str(worktree),
            "role": role["agent"],
            "status": "dry-run",
        }

    log_handle = log_path.open("a", encoding="utf-8")
    process = subprocess.Popen(
        cmd,
        cwd=worktree,
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
        env=no_color_env(),
    )
    return {
        "issue_number": issue["number"],
        "issue_url": issue["url"],
        "branch": branch,
        "worktree": str(worktree),
        "role": role["agent"],
        "mode": role["mode"],
        "pid": process.pid,
        "log": str(log_path),
        "last_message": str(last_path),
        "started_at": utc_now(),
        "status": "running",
    }


def setup(args: argparse.Namespace) -> int:
    findings = validate_config()
    if findings:
        print("Agent OS config check failed:")
        print("\n".join(findings))
        return 1
    repo = args.repo or default_repo()
    from github_agent_os import labels, seed_issues, project

    if args.apply_labels:
        if labels(argparse.Namespace(repo=repo, dry_run=False, check=False, apply=True)) != 0:
            return 1
    else:
        print("labels: skipped; use --apply-labels")

    if args.seed_issues:
        if seed_issues(argparse.Namespace(repo=repo, dry_run=False, apply=True)) != 0:
            return 1
    else:
        print("seed issues: skipped; use --seed-issues")

    if args.apply_project:
        if project(argparse.Namespace(owner=args.owner, repo=repo, dry_run=False, apply=True)) != 0:
            return 1
    else:
        print("project: skipped; use --apply-project after `gh auth refresh -s project`")
    return 0


def run_once(args: argparse.Namespace, config: dict[str, Any], state: dict[str, Any]) -> int:
    repo = args.repo or default_repo()
    active = active_runs(state)
    free_slots = max(args.max_workers - len(active), 0)
    if free_slots == 0:
        print(f"no free worker slots: max-workers={args.max_workers} active={len(active)}")
        save_state(state)
        return 0

    candidates = fetch_candidate_issues(repo, config, free_slots)
    if not candidates:
        print("no ready issues found")
        save_state(state)
        return 0

    base = args.base or config["default_base"]
    profile = args.profile or config["default_profile"]
    model = args.model or config["default_model"]
    worktree_root = Path(args.worktree_root or config["worktree_root"])
    if not worktree_root.is_absolute():
        worktree_root = (ROOT / worktree_root).resolve()

    for issue in candidates:
        number = int(issue["number"])
        if issue_already_running(state, number):
            continue
        labels = issue_labels(issue)
        role = pick_role(config, labels)
        branch = args.branch or f"agent/issue-{number}-{slugify(issue['title'])}"
        worktree = ensure_worktree(branch, base, worktree_root, args.dry_run)
        claim_issue(repo, issue, role, branch, args.dry_run or args.no_claim)
        run = launch_worker(
            repo=repo,
            issue=issue,
            role=role,
            branch=branch,
            worktree=worktree,
            profile=profile,
            model=model,
            create_pr=not args.no_pr,
            merge_ready=args.merge_ready,
            dry_run=args.dry_run,
        )
        state.setdefault("runs", []).append(run)
        print(f"launched issue #{number}: {role['agent']} on {branch}")
    save_state(state)
    return 0


def run_loop(args: argparse.Namespace) -> int:
    config = load_orchestrator()
    state = load_state()
    deadline = None
    if args.max_minutes:
        deadline = time.monotonic() + args.max_minutes * 60
    while True:
        rc = run_once(args, config, state)
        save_state(state)
        if rc != 0 or not args.loop:
            return rc
        if args.merge_ready:
            merge_ready(argparse.Namespace(repo=args.repo, apply=True, delete_branch=True))
        if deadline is not None and time.monotonic() >= deadline:
            print("loop deadline reached")
            return 0
        time.sleep(args.poll_seconds)


def print_status(_: argparse.Namespace) -> int:
    state = load_state()
    active = active_runs(state)
    save_state(state)
    print(f"state: {STATE_PATH}")
    print(f"active workers: {len(active)}")
    for run in state.get("runs", []):
        status = run.get("status", "unknown")
        print(
            f"#{run.get('issue_number')} {status} pid={run.get('pid', '-')} "
            f"role={run.get('role')} branch={run.get('branch')}"
        )
        if run.get("log"):
            print(f"  log: {run['log']}")
        if run.get("last_message"):
            print(f"  last: {run['last_message']}")
    return 0


def nudge(args: argparse.Namespace) -> int:
    repo = args.repo or default_repo()
    body = f"""<!-- dxt-agent-event:v1 status=nudge role=supervisor -->
## Supervisor Nudge

{args.message}
"""
    gh(["issue", "comment", str(args.issue), "--repo", repo, "--body", body])
    print(f"nudged issue #{args.issue}")
    return 0


def pr_checks_green(pr_number: int, repo: str) -> tuple[bool, str]:
    result = gh(["pr", "checks", str(pr_number), "--repo", repo, "--json", "name,state,bucket"], check=False)
    if result.returncode != 0:
        return False, result.stderr.strip() or "checks unavailable"
    checks = json.loads(result.stdout)
    if not checks:
        return False, "no checks reported"
    bad = [check for check in checks if check.get("state") not in {"SUCCESS", "SKIPPED", "NEUTRAL"}]
    if bad:
        return False, ", ".join(f"{item.get('name')}={item.get('state')}" for item in bad)
    return True, "all checks green"


def merge_ready(args: argparse.Namespace) -> int:
    repo = args.repo or default_repo()
    result = gh(
        [
            "pr",
            "list",
            "--repo",
            repo,
            "--state",
            "open",
            "--json",
            "number,title,isDraft,headRefName,url",
            "--limit",
            "50",
        ],
        check=False,
    )
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        return result.returncode
    prs = json.loads(result.stdout)
    ready = []
    for pr in prs:
        if pr.get("isDraft"):
            continue
        ok, why = pr_checks_green(int(pr["number"]), repo)
        print(f"PR #{pr['number']}: {why}")
        if ok:
            ready.append(pr)
    if not args.apply:
        print(f"would merge {len(ready)} green PR(s); use --apply")
        return 0
    for pr in ready:
        cmd = ["pr", "merge", str(pr["number"]), "--repo", repo, "--merge"]
        if args.delete_branch:
            cmd.append("--delete-branch")
        print(f"merging PR #{pr['number']}: {pr['title']}")
        gh(cmd)
    return 0


def stop(args: argparse.Namespace) -> int:
    state = load_state()
    stopped = 0
    for run in active_runs(state):
        if args.issue is not None and int(run.get("issue_number", -1)) != args.issue:
            continue
        pid = int(run["pid"])
        os.killpg(pid, signal.SIGTERM)
        run["status"] = "stopping"
        run["stopped_at"] = utc_now()
        stopped += 1
    save_state(state)
    print(f"sent stop signal to {stopped} worker(s)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Run dxt's local GitHub-backed Codex Agent OS.")
    sub = parser.add_subparsers(dest="command", required=True)

    setup_parser = sub.add_parser("setup", help="Validate and optionally sync GitHub labels, seed issues, and project.")
    setup_parser.add_argument("--repo")
    setup_parser.add_argument("--owner", default="sabino")
    setup_parser.add_argument("--apply-labels", action="store_true")
    setup_parser.add_argument("--seed-issues", action="store_true")
    setup_parser.add_argument("--apply-project", action="store_true")
    setup_parser.set_defaults(func=setup)

    run_parser = sub.add_parser("run", help="Claim ready issues and launch Codex workers in isolated worktrees.")
    run_parser.add_argument("--repo")
    run_parser.add_argument("--profile")
    run_parser.add_argument("--model")
    run_parser.add_argument("--base")
    run_parser.add_argument("--worktree-root")
    run_parser.add_argument("--max-workers", type=int, default=2)
    run_parser.add_argument("--loop", action="store_true")
    run_parser.add_argument("--poll-seconds", type=int, default=900)
    run_parser.add_argument("--max-minutes", type=int, default=0)
    run_parser.add_argument("--branch")
    run_parser.add_argument("--dry-run", action="store_true")
    run_parser.add_argument("--no-claim", action="store_true")
    run_parser.add_argument("--no-pr", action="store_true")
    run_parser.add_argument("--merge-ready", action="store_true")
    run_parser.set_defaults(func=run_loop)

    status_parser = sub.add_parser("status", help="Show local worker state and log paths.")
    status_parser.set_defaults(func=print_status)

    nudge_parser = sub.add_parser("nudge", help="Post a public-safe nudge comment to an issue.")
    nudge_parser.add_argument("issue", type=int)
    nudge_parser.add_argument("message")
    nudge_parser.add_argument("--repo")
    nudge_parser.set_defaults(func=nudge)

    merge_parser = sub.add_parser("merge-ready", help="Merge non-draft PRs with green checks.")
    merge_parser.add_argument("--repo")
    merge_parser.add_argument("--apply", action="store_true")
    merge_parser.add_argument("--delete-branch", action="store_true")
    merge_parser.set_defaults(func=merge_ready)

    stop_parser = sub.add_parser("stop", help="Stop active local Codex workers launched by the orchestrator.")
    stop_parser.add_argument("--issue", type=int)
    stop_parser.set_defaults(func=stop)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())

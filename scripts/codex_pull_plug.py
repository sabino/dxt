#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
STATE_DIR = ROOT / ".agent" / "runs" / "agent-os" / "pull-plug"
REQUEST_PATH = STATE_DIR / "request.json"
HANDOFF_PATH = STATE_DIR / "handoff.md"
GUARDIAN_PATH = STATE_DIR / "guardian.json"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def parse_utc(value: str) -> float:
    normalized = value.replace("Z", "+00:00")
    return datetime.fromisoformat(normalized).timestamp()


def no_color_env() -> dict[str, str]:
    env = os.environ.copy()
    env["NO_COLOR"] = "1"
    env["CLICOLOR"] = "0"
    env["CLICOLOR_FORCE"] = "0"
    env["GH_FORCE_TTY"] = "0"
    env["TERM"] = "dumb"
    env.pop("FORCE_COLOR", None)
    return env


def run_cmd(cmd: list[str], *, check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=ROOT,
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=no_color_env(),
    )


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(content, encoding="utf-8")
    tmp.replace(path)


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    atomic_write(path, json.dumps(payload, indent=2, sort_keys=True) + "\n")


def read_json(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def is_pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def git_value(args: list[str]) -> str:
    result = run_cmd(["git", *args])
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def git_snapshot() -> dict[str, str]:
    return {
        "branch": git_value(["branch", "--show-current"]),
        "head": git_value(["rev-parse", "--short", "HEAD"]),
        "status_short": run_cmd(["git", "status", "--short", "--branch"]).stdout.strip(),
        "diff_stat": run_cmd(["git", "diff", "--stat"]).stdout.strip(),
    }


def resume_prompt(request: dict[str, Any]) -> str:
    snapshot = {
        "reason": request.get("reason", ""),
        "requested_at": request.get("requested_at", ""),
        "branch": request.get("git", {}).get("branch", ""),
        "head": request.get("git", {}).get("head", ""),
        "status_short": request.get("git", {}).get("status_short", ""),
        "diff_stat": request.get("git", {}).get("diff_stat", ""),
        "resume_prompt": request.get("resume_prompt", ""),
    }
    return f"""Resume dxt work after a Codex pull-plug restart request.

Required startup:
1. Read AGENTS.md, PLAN.md, README.md, docs/AGENT_OS.md, docs/AGENT_PROTOCOLS.md, and docs/MULTI_AGENT_WORKFLOW.md.
2. Inspect git status before editing. Work with any existing changes instead of reverting them.
3. If this restart was requested because `.codex/config.toml` or `.codex/agents/` changed, assume this fresh process is allowed to use the updated project-scoped Codex settings.
4. Continue the active dxt Agent OS objective from the GitHub issues/Project and PLAN.md. Keep product runtime behavior in Zig.
5. If the prior branch contains unfinished changes, finish, validate, and commit a coherent slice before launching broader autonomous workers.

Pull-plug request:
```json
{json.dumps(snapshot, indent=2, sort_keys=True)}
```

Stop conditions:
- Do not create competing workers if `.agent/runs/agent-os/state.json` already shows active workers that own the same issue.
- Do not push or merge unless the active workflow explicitly allows it.
- If context is unclear, write a concise handoff under `.agent/runs/` and report status instead of making broad changes.
"""


def request_restart(args: argparse.Namespace) -> int:
    existing = read_json(REQUEST_PATH)
    if existing and existing.get("status") == "requested" and not args.force:
        print(f"restart already requested: {REQUEST_PATH}", file=sys.stderr)
        return 1

    payload = {
        "schema": "dxt-codex-pull-plug-v1",
        "status": "requested",
        "requested_at": utc_now(),
        "reason": args.reason,
        "resume_prompt": args.resume_prompt,
        "profile": args.profile,
        "model": args.model,
        "sandbox": args.sandbox,
        "approval": args.approval,
        "delay_seconds": args.delay_seconds,
        "git": git_snapshot(),
    }
    prompt = resume_prompt(payload)
    if args.dry_run:
        print("would write restart request:")
        print(json.dumps(payload, indent=2, sort_keys=True))
        print(f"would write handoff: {HANDOFF_PATH}")
        return 0
    atomic_write_json(REQUEST_PATH, payload)
    atomic_write(HANDOFF_PATH, prompt)
    print(f"restart requested: {REQUEST_PATH}")
    print(f"handoff written: {HANDOFF_PATH}")
    return 0


def launch_resume(request: dict[str, Any]) -> dict[str, Any]:
    timestamp = utc_now().replace(":", "").replace("-", "")
    log_path = STATE_DIR / f"resume-{timestamp}.log"
    last_path = STATE_DIR / f"resume-{timestamp}-last.md"
    prompt = resume_prompt(request)
    cmd = [
        "codex",
        "-p",
        str(request.get("profile") or "azure"),
        "-m",
        str(request.get("model") or "gpt-5.5"),
        "-C",
        str(ROOT),
        "--ask-for-approval",
        str(request.get("approval") or "never"),
        "--sandbox",
        str(request.get("sandbox") or "workspace-write"),
        "exec",
        "--output-last-message",
        str(last_path),
        prompt,
    ]
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    log_handle = log_path.open("a", encoding="utf-8")
    process = subprocess.Popen(
        cmd,
        cwd=ROOT,
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
        env=no_color_env(),
    )
    request.update(
        {
            "status": "launched",
            "launched_at": utc_now(),
            "pid": process.pid,
            "log": str(log_path),
            "last_message": str(last_path),
        }
    )
    atomic_write_json(REQUEST_PATH, request)
    return request


def watch(args: argparse.Namespace) -> int:
    while True:
        request = read_json(REQUEST_PATH)
        if request and request.get("status") == "requested":
            requested_at = str(request.get("requested_at") or utc_now())
            delay = int(request.get("delay_seconds") or 0)
            remaining = parse_utc(requested_at) + delay - time.time()
            if remaining <= 0:
                launched = launch_resume(request)
                print(f"launched resumed Codex pid={launched['pid']}")
                if args.once:
                    return 0
            elif args.once:
                print(f"restart request is waiting for delay: {int(remaining)}s")
                return 0
        elif args.once:
            print("no pending restart request")
            return 0
        time.sleep(args.poll_seconds)


def start_guardian(args: argparse.Namespace) -> int:
    existing = read_json(GUARDIAN_PATH)
    if existing and is_pid_alive(int(existing.get("pid", -1))) and not args.force:
        print(f"guardian already running pid={existing['pid']}")
        return 0
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    log_path = STATE_DIR / "guardian.log"
    cmd = [
        sys.executable,
        str(Path(__file__).resolve()),
        "watch",
        "--poll-seconds",
        str(args.poll_seconds),
    ]
    if args.dry_run:
        print("would start guardian:")
        print("  " + " ".join(cmd))
        return 0
    log_handle = log_path.open("a", encoding="utf-8")
    process = subprocess.Popen(
        cmd,
        cwd=ROOT,
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
        env=no_color_env(),
    )
    atomic_write_json(
        GUARDIAN_PATH,
        {
            "schema": "dxt-codex-pull-plug-guardian-v1",
            "started_at": utc_now(),
            "pid": process.pid,
            "log": str(log_path),
        },
    )
    print(f"guardian started pid={process.pid}")
    return 0


def stop_guardian(_: argparse.Namespace) -> int:
    state = read_json(GUARDIAN_PATH)
    if not state:
        print("guardian is not registered")
        return 0
    pid = int(state.get("pid", -1))
    if pid > 0 and is_pid_alive(pid):
        os.kill(pid, signal.SIGTERM)
        print(f"guardian stopped pid={pid}")
    else:
        print(f"guardian not running pid={pid}")
    state["stopped_at"] = utc_now()
    state["status"] = "stopped"
    atomic_write_json(GUARDIAN_PATH, state)
    return 0


def status(_: argparse.Namespace) -> int:
    guardian = read_json(GUARDIAN_PATH)
    request = read_json(REQUEST_PATH)
    if guardian:
        pid = int(guardian.get("pid", -1))
        print(f"guardian pid={pid} alive={is_pid_alive(pid)}")
        if guardian.get("log"):
            print(f"guardian log: {guardian['log']}")
    else:
        print("guardian: not registered")
    if request:
        print(f"request status={request.get('status')} requested_at={request.get('requested_at')}")
        if request.get("pid"):
            pid = int(request["pid"])
            print(f"resume pid={pid} alive={is_pid_alive(pid)}")
        if request.get("log"):
            print(f"resume log: {request['log']}")
        if request.get("last_message"):
            print(f"resume last: {request['last_message']}")
    else:
        print("request: none")
    return 0


def cancel(_: argparse.Namespace) -> int:
    request = read_json(REQUEST_PATH)
    if not request:
        print("request: none")
        return 0
    request["status"] = "canceled"
    request["canceled_at"] = utc_now()
    atomic_write_json(REQUEST_PATH, request)
    print("restart request canceled")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Codex pull-plug restart handoff helper for dxt.")
    sub = parser.add_subparsers(dest="command", required=True)

    request_parser = sub.add_parser("request", help="Write a restart request and handoff for a guardian.")
    request_parser.add_argument("--reason", required=True)
    request_parser.add_argument("--resume-prompt", default="")
    request_parser.add_argument("--profile", default="azure")
    request_parser.add_argument("--model", default="gpt-5.5")
    request_parser.add_argument("--sandbox", default="workspace-write")
    request_parser.add_argument("--approval", default="never")
    request_parser.add_argument("--delay-seconds", type=int, default=90)
    request_parser.add_argument("--force", action="store_true")
    request_parser.add_argument("--dry-run", action="store_true")
    request_parser.set_defaults(func=request_restart)

    watch_parser = sub.add_parser("watch", help="Watch for a pending request and launch a fresh Codex run.")
    watch_parser.add_argument("--poll-seconds", type=int, default=30)
    watch_parser.add_argument("--once", action="store_true")
    watch_parser.set_defaults(func=watch)

    guardian_parser = sub.add_parser("start-guardian", help="Start a detached watcher process.")
    guardian_parser.add_argument("--poll-seconds", type=int, default=30)
    guardian_parser.add_argument("--force", action="store_true")
    guardian_parser.add_argument("--dry-run", action="store_true")
    guardian_parser.set_defaults(func=start_guardian)

    stop_parser = sub.add_parser("stop-guardian", help="Stop the detached watcher process.")
    stop_parser.set_defaults(func=stop_guardian)

    status_parser = sub.add_parser("status", help="Show guardian and restart request state.")
    status_parser.set_defaults(func=status)

    cancel_parser = sub.add_parser("cancel", help="Cancel a pending restart request.")
    cancel_parser.set_defaults(func=cancel)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shlex
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
STATE_DIR = ROOT / ".agent" / "runs" / "agent-os" / "tmux-supervisor"
STATE_PATH = STATE_DIR / "state.json"
REQUEST_PATH = STATE_DIR / "request.json"
HANDOFF_PATH = STATE_DIR / "handoff.md"
DEFAULT_SESSION = "dxt-codex"
SHELL_COMMANDS = {"bash", "sh", "zsh", "fish"}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def no_color_env() -> dict[str, str]:
    env = os.environ.copy()
    env["NO_COLOR"] = "1"
    env["CLICOLOR"] = "0"
    env["CLICOLOR_FORCE"] = "0"
    env["GH_FORCE_TTY"] = "0"
    env["TERM"] = env.get("TERM", "xterm-256color")
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


def tmux(args: list[str], *, check: bool = False) -> subprocess.CompletedProcess[str]:
    return run_cmd(["tmux", *args], check=check)


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


def git_snapshot() -> dict[str, str]:
    status = run_cmd(["git", "status", "--short", "--branch"])
    branch = run_cmd(["git", "branch", "--show-current"])
    head = run_cmd(["git", "rev-parse", "--short", "HEAD"])
    return {
        "branch": branch.stdout.strip(),
        "head": head.stdout.strip(),
        "status_short": status.stdout.strip(),
    }


def tmux_has_session(session: str) -> bool:
    return tmux(["has-session", "-t", session]).returncode == 0


def tmux_pane_command(target: str) -> str:
    result = tmux(["display-message", "-p", "-t", target, "#{pane_current_command}"])
    return result.stdout.strip() if result.returncode == 0 else ""


def tmux_pane_pid(target: str) -> int | None:
    result = tmux(["display-message", "-p", "-t", target, "#{pane_pid}"])
    if result.returncode != 0:
        return None
    try:
        return int(result.stdout.strip())
    except ValueError:
        return None


def pane_has_codex_process(target: str) -> bool:
    pane_pid = tmux_pane_pid(target)
    if pane_pid is None:
        return False
    result = run_cmd(["ps", "-eo", "pid=,ppid=,comm=,args="])
    if result.returncode != 0:
        return False

    children: dict[int, list[int]] = {}
    processes: dict[int, tuple[str, str]] = {}
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) < 3:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
        except ValueError:
            continue
        command = parts[2]
        args = parts[3] if len(parts) > 3 else command
        processes[pid] = (command, args)
        children.setdefault(ppid, []).append(pid)

    stack = [pane_pid]
    seen: set[int] = set()
    while stack:
        pid = stack.pop()
        if pid in seen:
            continue
        seen.add(pid)
        command, args = processes.get(pid, ("", ""))
        lowered_args = args.lower()
        if command == "codex":
            return True
        if "codex" in lowered_args and str(ROOT) in args:
            return True
        stack.extend(children.get(pid, []))
    return False


def shell_command(command: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in command)


def codex_command(
    *,
    session_id: str | None,
    use_last: bool,
    prompt: str,
    profile: str,
    model: str,
    sandbox: str,
    approval: str,
) -> list[str]:
    base = [
        "codex",
        "-p",
        profile,
        "-m",
        model,
        "-C",
        str(ROOT),
        "--ask-for-approval",
        approval,
        "--sandbox",
        sandbox,
    ]
    if session_id:
        return [*base, "resume", session_id, prompt]
    if use_last:
        return [*base, "resume", "--last", prompt]
    return [*base, prompt]


def pane_runner(command: list[str]) -> str:
    command_text = shell_command(command)
    return (
        "bash -lc "
        + shlex.quote(
            f"cd {shlex.quote(str(ROOT))}; "
            f"{command_text}; "
            "printf '\\n[codex exited; pane kept alive by dxt tmux supervisor]\\n'; "
            "exec bash -l"
        )
    )


def resume_prompt(request: dict[str, Any]) -> str:
    return f"""Resume this dxt Codex session after a tmux pull-plug restart.

Required startup:
1. Read AGENTS.md, PLAN.md, README.md, docs/AGENT_OS.md, docs/AGENT_PROTOCOLS.md, and docs/MULTI_AGENT_WORKFLOW.md.
2. Inspect git status before editing. Work with existing changes; do not revert user or sibling-agent work.
3. Continue from the handoff and current GitHub issue/Project state.
4. Keep product runtime behavior in Zig.

Restart request:
```json
{json.dumps(request, indent=2, sort_keys=True)}
```
"""


def start(args: argparse.Namespace) -> int:
    if tmux_has_session(args.session) and not args.force:
        print(f"tmux session already exists: {args.session}")
        print(f"attach with: tmux attach -t {args.session}")
        return 0
    if tmux_has_session(args.session):
        tmux(["kill-session", "-t", args.session], check=False)
    command = codex_command(
        session_id=args.session_id,
        use_last=args.last,
        prompt=args.prompt,
        profile=args.profile,
        model=args.model,
        sandbox=args.sandbox,
        approval=args.approval,
    )
    if args.dry_run:
        print("would start tmux-supervised Codex:")
        print(f"  tmux new-session -s {args.session} {pane_runner(command)}")
        return 0
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    result = tmux(["new-session", "-d", "-s", args.session, pane_runner(command)])
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        return result.returncode
    pane = tmux(["display-message", "-p", "-t", args.session, "#{pane_id}"], check=True).stdout.strip()
    state = {
        "schema": "dxt-codex-tmux-supervisor-v1",
        "session": args.session,
        "pane": pane,
        "started_at": utc_now(),
        "session_id": args.session_id,
        "uses_last": args.last,
        "profile": args.profile,
        "model": args.model,
        "sandbox": args.sandbox,
        "approval": args.approval,
        "git": git_snapshot(),
    }
    atomic_write_json(STATE_PATH, state)
    print(f"tmux supervisor started: session={args.session} pane={pane}")
    if args.attach:
        os.execvp("tmux", ["tmux", "attach-session", "-t", args.session])
    print(f"attach with: tmux attach -t {args.session}")
    return 0


def request(args: argparse.Namespace) -> int:
    state = read_json(STATE_PATH)
    if not state:
        print(f"missing tmux supervisor state: {STATE_PATH}", file=sys.stderr)
        return 1
    existing = read_json(REQUEST_PATH)
    if existing and existing.get("status") in {"requested", "ready_to_exit"} and not args.force:
        print(f"restart already pending: {REQUEST_PATH}", file=sys.stderr)
        return 1
    session_id = args.session_id or str(state.get("session_id") or os.environ.get("CODEX_THREAD_ID") or "")
    if not session_id and not args.last:
        print("missing session id; pass --session-id or --last", file=sys.stderr)
        return 2
    payload = {
        "schema": "dxt-codex-tmux-restart-v1",
        "status": "requested",
        "requested_at": utc_now(),
        "reason": args.reason,
        "resume_note": args.resume_note,
        "session": state["session"],
        "pane": state["pane"],
        "session_id": session_id,
        "last": args.last,
        "profile": args.profile or state.get("profile") or "azure",
        "model": args.model or state.get("model") or "gpt-5.5",
        "sandbox": args.sandbox or state.get("sandbox") or "workspace-write",
        "approval": args.approval or state.get("approval") or "never",
        "git": git_snapshot(),
    }
    atomic_write_json(REQUEST_PATH, payload)
    atomic_write(HANDOFF_PATH, resume_prompt(payload))
    print(f"restart requested: {REQUEST_PATH}")
    print("call `python scripts/codex_tmux_supervisor.py ready` when the current turn is safe to exit")
    return 0


def ready(args: argparse.Namespace) -> int:
    request_state = read_json(REQUEST_PATH)
    if not request_state or request_state.get("status") != "requested":
        print("no requested restart is waiting", file=sys.stderr)
        return 1
    request_state["status"] = "ready_to_exit"
    request_state["ready_at"] = utc_now()
    if args.note:
        request_state["ready_note"] = args.note
    atomic_write_json(REQUEST_PATH, request_state)
    print("restart marked ready_to_exit")
    return 0


def send_interactive_exit(target: str) -> None:
    tmux(["send-keys", "-t", target, "/goal pause", "C-m"], check=False)
    time.sleep(1)
    tmux(["send-keys", "-t", target, "/exit", "C-m"], check=False)


def respawn_codex(request_state: dict[str, Any]) -> None:
    command = codex_command(
        session_id=str(request_state.get("session_id") or "") or None,
        use_last=bool(request_state.get("last")),
        prompt=resume_prompt(request_state),
        profile=str(request_state.get("profile") or "azure"),
        model=str(request_state.get("model") or "gpt-5.5"),
        sandbox=str(request_state.get("sandbox") or "workspace-write"),
        approval=str(request_state.get("approval") or "never"),
    )
    tmux(["respawn-pane", "-k", "-t", str(request_state["pane"]), pane_runner(command)], check=True)
    request_state["status"] = "resumed"
    request_state["resumed_at"] = utc_now()
    atomic_write_json(REQUEST_PATH, request_state)


def process_ready_request(request_state: dict[str, Any], *, exit_timeout: int) -> bool:
    target = str(request_state["pane"])
    command = tmux_pane_command(target)
    if not pane_has_codex_process(target):
        request_state["status"] = "failed"
        request_state["failed_at"] = utc_now()
        request_state["failure"] = f"pane {target} command={command or 'unknown'} has no live Codex process descendant"
        atomic_write_json(REQUEST_PATH, request_state)
        return False
    send_interactive_exit(target)
    deadline = time.monotonic() + exit_timeout
    while time.monotonic() < deadline:
        current = tmux_pane_command(target)
        if current in SHELL_COMMANDS and not pane_has_codex_process(target):
            respawn_codex(request_state)
            return True
        time.sleep(1)
    request_state["status"] = "failed"
    request_state["failed_at"] = utc_now()
    request_state["failure"] = f"timed out waiting for pane {target} to return to a shell"
    atomic_write_json(REQUEST_PATH, request_state)
    return False


def watch(args: argparse.Namespace) -> int:
    while True:
        request_state = read_json(REQUEST_PATH)
        if request_state and request_state.get("status") == "ready_to_exit":
            if not process_ready_request(request_state, exit_timeout=args.exit_timeout):
                print(f"tmux restart failed: {request_state.get('failure', 'unknown failure')}", file=sys.stderr)
                return 1
            print("tmux pane resumed Codex")
            if args.once:
                return 0
        elif args.once:
            print("no ready_to_exit restart request")
            return 0
        time.sleep(args.poll_seconds)


def start_guardian(args: argparse.Namespace) -> int:
    state = read_json(STATE_PATH) or {}
    guardian = state.get("guardian") if isinstance(state.get("guardian"), dict) else None
    if guardian and is_pid_alive(int(guardian.get("pid", -1))) and not args.force:
        print(f"tmux guardian already running pid={guardian['pid']}")
        return 0
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    log_path = STATE_DIR / "guardian.log"
    cmd = [
        sys.executable,
        str(Path(__file__).resolve()),
        "watch",
        "--poll-seconds",
        str(args.poll_seconds),
        "--exit-timeout",
        str(args.exit_timeout),
    ]
    if args.dry_run:
        print("would start tmux guardian:")
        print("  " + shell_command(cmd))
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
    state["guardian"] = {"pid": process.pid, "started_at": utc_now(), "log": str(log_path)}
    atomic_write_json(STATE_PATH, state)
    print(f"tmux guardian started pid={process.pid}")
    return 0


def stop_guardian(_: argparse.Namespace) -> int:
    state = read_json(STATE_PATH) or {}
    guardian = state.get("guardian") if isinstance(state.get("guardian"), dict) else None
    if not guardian:
        print("tmux guardian is not registered")
        return 0
    pid = int(guardian.get("pid", -1))
    if pid > 0 and is_pid_alive(pid):
        os.kill(pid, signal.SIGTERM)
        print(f"tmux guardian stopped pid={pid}")
    guardian["stopped_at"] = utc_now()
    guardian["status"] = "stopped"
    atomic_write_json(STATE_PATH, state)
    return 0


def status(_: argparse.Namespace) -> int:
    state = read_json(STATE_PATH)
    request_state = read_json(REQUEST_PATH)
    if state:
        session = str(state.get("session"))
        pane = str(state.get("pane"))
        pane_pid = tmux_pane_pid(pane)
        codex_descendant = pane_has_codex_process(pane)
        print(
            f"session={session} exists={tmux_has_session(session)} pane={pane} "
            f"pane_pid={pane_pid} command={tmux_pane_command(pane)} codex_descendant={codex_descendant}"
        )
        guardian = state.get("guardian") if isinstance(state.get("guardian"), dict) else None
        if guardian:
            pid = int(guardian.get("pid", -1))
            print(f"guardian pid={pid} alive={is_pid_alive(pid)} log={guardian.get('log')}")
    else:
        print("tmux supervisor: no state")
    if request_state:
        print(f"request status={request_state.get('status')} reason={request_state.get('reason')}")
    else:
        print("request: none")
    return 0


def cancel(_: argparse.Namespace) -> int:
    request_state = read_json(REQUEST_PATH)
    if not request_state:
        print("request: none")
        return 0
    request_state["status"] = "canceled"
    request_state["canceled_at"] = utc_now()
    atomic_write_json(REQUEST_PATH, request_state)
    print("tmux restart request canceled")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="tmux supervisor for restarting Codex in the same pane.")
    sub = parser.add_subparsers(dest="command", required=True)

    start_parser = sub.add_parser("start", help="Start an interactive Codex TUI inside a supervised tmux pane.")
    start_parser.add_argument("--session", default=DEFAULT_SESSION)
    start_parser.add_argument("--session-id", default=os.environ.get("CODEX_THREAD_ID", ""))
    start_parser.add_argument("--last", action="store_true")
    start_parser.add_argument("--prompt", default="Resume dxt work. Read AGENTS.md and PLAN.md, inspect git status, then continue.")
    start_parser.add_argument("--profile", default="azure")
    start_parser.add_argument("--model", default="gpt-5.5")
    start_parser.add_argument("--sandbox", default="workspace-write")
    start_parser.add_argument("--approval", default="never")
    start_parser.add_argument("--attach", action="store_true")
    start_parser.add_argument("--force", action="store_true")
    start_parser.add_argument("--dry-run", action="store_true")
    start_parser.set_defaults(func=start)

    request_parser = sub.add_parser("request", help="Request a restart once the current turn marks itself ready.")
    request_parser.add_argument("--reason", required=True)
    request_parser.add_argument("--resume-note", default="")
    request_parser.add_argument("--session-id", default=os.environ.get("CODEX_THREAD_ID", ""))
    request_parser.add_argument("--last", action="store_true")
    request_parser.add_argument("--profile")
    request_parser.add_argument("--model")
    request_parser.add_argument("--sandbox")
    request_parser.add_argument("--approval")
    request_parser.add_argument("--force", action="store_true")
    request_parser.set_defaults(func=request)

    ready_parser = sub.add_parser("ready", help="Mark the current request safe for tmux exit/resume.")
    ready_parser.add_argument("--note", default="")
    ready_parser.set_defaults(func=ready)

    watch_parser = sub.add_parser("watch", help="Watch for ready_to_exit and restart Codex in the same tmux pane.")
    watch_parser.add_argument("--poll-seconds", type=int, default=5)
    watch_parser.add_argument("--exit-timeout", type=int, default=60)
    watch_parser.add_argument("--once", action="store_true")
    watch_parser.set_defaults(func=watch)

    guardian_parser = sub.add_parser("start-guardian", help="Start detached watcher for this tmux supervisor.")
    guardian_parser.add_argument("--poll-seconds", type=int, default=5)
    guardian_parser.add_argument("--exit-timeout", type=int, default=60)
    guardian_parser.add_argument("--force", action="store_true")
    guardian_parser.add_argument("--dry-run", action="store_true")
    guardian_parser.set_defaults(func=start_guardian)

    stop_parser = sub.add_parser("stop-guardian")
    stop_parser.set_defaults(func=stop_guardian)

    status_parser = sub.add_parser("status")
    status_parser.set_defaults(func=status)

    cancel_parser = sub.add_parser("cancel")
    cancel_parser.set_defaults(func=cancel)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())

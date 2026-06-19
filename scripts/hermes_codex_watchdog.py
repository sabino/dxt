#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def run_cmd(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def notify(target: str, message: str) -> None:
    if not target:
        return
    run_cmd(["hermes", "send", "--to", target, "--quiet", message])


def main() -> int:
    parser = argparse.ArgumentParser(description="Hermes-friendly tick for dxt Codex tmux restart supervision.")
    parser.add_argument("--to", default="", help="Optional Hermes send target such as telegram.")
    parser.add_argument("--exit-timeout", type=int, default=60)
    args = parser.parse_args()

    result = run_cmd(
        [
            sys.executable,
            "scripts/codex_tmux_supervisor.py",
            "watch",
            "--once",
            "--exit-timeout",
            str(args.exit_timeout),
        ]
    )
    output = (result.stdout + result.stderr).strip()
    if result.returncode != 0:
        message = f"[dxt codex watchdog] failed\n{output}"
        print(message)
        notify(args.to, message)
        return result.returncode
    if "tmux pane resumed Codex" in output:
        message = "[dxt codex watchdog] resumed Codex in supervised tmux pane"
        print(message)
        notify(args.to, message)
        return 0
    if output and "no ready_to_exit restart request" not in output:
        print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

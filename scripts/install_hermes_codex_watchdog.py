#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HERMES_SCRIPTS = Path.home() / ".hermes" / "scripts"
SCRIPT_NAME = "dxt-codex-watchdog.py"


def run_cmd(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def wrapper_content(target: str, exit_timeout: int) -> str:
    repo_script = ROOT / "scripts" / "hermes_codex_watchdog.py"
    return f"""#!/usr/bin/env python3
import subprocess
import sys

cmd = [
    sys.executable,
    {str(repo_script)!r},
    "--exit-timeout",
    {str(exit_timeout)!r},
]
if {target!r}:
    cmd.extend(["--to", {target!r}])
raise SystemExit(subprocess.run(cmd).returncode)
"""


def main() -> int:
    parser = argparse.ArgumentParser(description="Install an optional Hermes cron wrapper for dxt Codex tmux supervision.")
    parser.add_argument("--name", default="dxt-codex-tmux-watchdog")
    parser.add_argument("--schedule", default="every 1m")
    parser.add_argument("--deliver", default="telegram")
    parser.add_argument("--to", default="telegram")
    parser.add_argument("--exit-timeout", type=int, default=60)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--install-cron", action="store_true")
    args = parser.parse_args()

    if shutil.which("hermes") is None:
        print("hermes not found on PATH", file=sys.stderr)
        return 1

    wrapper_path = HERMES_SCRIPTS / SCRIPT_NAME
    content = wrapper_content(args.to, args.exit_timeout)
    if args.dry_run:
        print(f"would write {wrapper_path}")
        if args.install_cron:
            print("would create Hermes cron job:")
            print(
                "  hermes cron create "
                + " ".join(
                    [
                        repr(args.schedule),
                        "--name",
                        repr(args.name),
                        "--deliver",
                        repr(args.deliver),
                        "--script",
                        repr(SCRIPT_NAME),
                        "--no-agent",
                        "--workdir",
                        repr(str(ROOT)),
                    ]
                )
            )
        return 0

    HERMES_SCRIPTS.mkdir(parents=True, exist_ok=True)
    wrapper_path.write_text(content, encoding="utf-8")
    os.chmod(wrapper_path, 0o755)
    print(f"wrote Hermes script: {wrapper_path}")

    if not args.install_cron:
        print("cron not installed; pass --install-cron to create the Hermes job")
        return 0

    result = run_cmd(
        [
            "hermes",
            "cron",
            "create",
            args.schedule,
            "--name",
            args.name,
            "--deliver",
            args.deliver,
            "--script",
            SCRIPT_NAME,
            "--no-agent",
            "--workdir",
            str(ROOT),
        ]
    )
    if result.returncode != 0:
        print(result.stdout, end="")
        print(result.stderr, end="", file=sys.stderr)
        return result.returncode
    print(result.stdout.strip())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

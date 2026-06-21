from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path

from check_jaffle_shop_duckdb_parse import (
    DEFAULT_DXT,
    DEFAULT_REF,
    DEFAULT_REPO_URL,
    ROOT,
    GateError,
    build_dxt,
    checkout_public_project,
    validate_selectors,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Run a public Jaffle Shop DuckDB ls gate through the Zig dxt binary. "
            "This is a developer-side compatibility harness; product behavior remains Zig."
        )
    )
    parser.add_argument("--project-dir", type=Path, help="Existing Jaffle Shop DuckDB checkout. If omitted, clone the pinned public ref into a temporary directory.")
    parser.add_argument("--repo-url", default=DEFAULT_REPO_URL, help="Public repository URL used when --project-dir is omitted.")
    parser.add_argument("--ref", default=DEFAULT_REF, help="Git ref used when --project-dir is omitted.")
    parser.add_argument("--dxt", type=Path, default=DEFAULT_DXT, help="Path to the dxt binary.")
    parser.add_argument("--no-build", action="store_true", help="Use the existing --dxt binary without running zig build first.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        with tempfile.TemporaryDirectory(prefix="dxt-jaffle-ls-gate-") as tmp:
            workdir = Path(tmp)
            dxt = args.dxt if args.dxt.is_absolute() else ROOT / args.dxt
            if not args.no_build:
                build_dxt(dxt, workdir)
            if not dxt.exists():
                raise GateError(f"dxt binary not found: {dxt}")

            project_dir = args.project_dir
            if project_dir is None:
                project_dir = checkout_public_project(workdir, args.repo_url, args.ref)
            else:
                project_dir = project_dir.resolve()
                if not (project_dir / "dbt_project.yml").exists():
                    raise GateError(f"--project-dir does not look like a dbt project: {project_dir}")

            validate_selectors(dxt, project_dir)
    except GateError as exc:
        print(f"Jaffle ls gate failed: {exc}", file=sys.stderr)
        return 1

    print("Jaffle ls gate passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

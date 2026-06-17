from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path
from typing import Any

from check_jaffle_shop_duckdb_parse import (
    DEFAULT_DXT,
    DEFAULT_REF,
    DEFAULT_REPO_URL,
    ROOT,
    GateError,
    assert_equal,
    build_dxt,
    checkout_public_project,
    load_manifest,
    run,
    validate_manifest_shape,
    validate_selectors,
)


EXPECTED_RESULT_COUNTS = {"model": 5, "seed": 3, "test": 20}
EXPECTED_STATUS_COUNTS = {"pass": 20, "success": 8}


def copy_public_project(source: Path, destination: Path) -> Path:
    def ignore(_: str, names: list[str]) -> set[str]:
        return {name for name in names if name in {".git", "target", "logs", "dbt_packages", "dbt_modules", "jaffle_shop.duckdb"}}

    shutil.copytree(source, destination, ignore=ignore)
    return destination


def load_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise GateError(f"could not read JSON artifact: {path}") from exc
    except json.JSONDecodeError as exc:
        raise GateError(f"artifact is not valid JSON: {path}: {exc}") from exc


def run_build_gate(dxt: Path, project_dir: Path, target_dir: Path) -> tuple[Path, Path]:
    run([dxt, "build", "--project-dir", project_dir, "--target-path", target_dir], cwd=ROOT)
    manifest_path = target_dir / "manifest.json"
    run_results_path = target_dir / "run_results.json"
    if not manifest_path.exists():
        raise GateError(f"build did not write manifest: {manifest_path}")
    if not run_results_path.exists():
        raise GateError(f"build did not write run_results: {run_results_path}")
    return manifest_path, run_results_path


def validate_run_results(path: Path) -> None:
    data = load_json(path)
    results = data.get("results")
    if not isinstance(results, list):
        raise GateError("run_results results must be an array")
    assert_equal("run result count", len(results), 28)
    status_counts = Counter(result.get("status") for result in results)
    assert_equal("run result status counts", dict(sorted(status_counts.items())), EXPECTED_STATUS_COUNTS)
    resource_counts = Counter(str(result.get("unique_id", "")).split(".", 1)[0] for result in results)
    assert_equal("run result resource counts", dict(sorted(resource_counts.items())), EXPECTED_RESULT_COUNTS)
    for result in results:
        unique_id = result.get("unique_id")
        if not isinstance(unique_id, str):
            raise GateError("run result unique_id must be a string")
        if unique_id.startswith("test."):
            if result.get("compiled") is not True:
                raise GateError(f"generic test result should be compiled: {unique_id}")
            if result.get("failures") != 0:
                raise GateError(f"generic test should pass without failures: {unique_id}")
        elif unique_id.startswith("seed."):
            if result.get("compiled") is not None:
                raise GateError(f"seed result should not be compiled: {unique_id}")
        elif unique_id.startswith("model."):
            if result.get("compiled") is not True:
                raise GateError(f"model result should be compiled: {unique_id}")
        else:
            raise GateError(f"unexpected run result resource: {unique_id}")


def query_scalar(duckdb: str, db_path: Path, sql: str) -> str:
    result = subprocess.run(
        [duckdb, str(db_path), "-csv", "-noheader", "-batch", "-bail", "-c", sql],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        raise GateError(f"DuckDB query failed:\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}")
    return result.stdout.strip()


def validate_duckdb_relations(project_dir: Path, duckdb: str) -> None:
    db_path = project_dir / "jaffle_shop.duckdb"
    if not db_path.exists():
        raise GateError(f"build did not create DuckDB database: {db_path}")
    assert_equal("customers row count", query_scalar(duckdb, db_path, 'select count(*) from "main"."customers"'), "100")
    assert_equal("orders row count", query_scalar(duckdb, db_path, 'select count(*) from "main"."orders"'), "99")
    assert_equal(
        "orders static loop columns",
        query_scalar(
            duckdb,
            db_path,
            'select count(*) from pragma_table_info(\'orders\') where name in (\'credit_card_amount\', \'coupon_amount\', \'bank_transfer_amount\', \'gift_card_amount\')',
        ),
        "4",
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Run a public Jaffle Shop DuckDB build gate through the Zig dxt binary. "
            "This is a developer-side compatibility harness; product behavior remains Zig."
        )
    )
    parser.add_argument("--project-dir", type=Path, help="Existing Jaffle Shop DuckDB checkout. It is copied into a temporary directory before build.")
    parser.add_argument("--repo-url", default=DEFAULT_REPO_URL, help="Public repository URL used when --project-dir is omitted.")
    parser.add_argument("--ref", default=DEFAULT_REF, help="Git ref used when --project-dir is omitted.")
    parser.add_argument("--dxt", type=Path, default=DEFAULT_DXT, help="Path to the dxt binary.")
    parser.add_argument("--duckdb", default=shutil.which("duckdb") or "duckdb", help="DuckDB CLI used for relation validation.")
    parser.add_argument("--no-build", action="store_true", help="Use the existing --dxt binary without running zig build first.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        with tempfile.TemporaryDirectory(prefix="dxt-jaffle-build-gate-") as tmp:
            workdir = Path(tmp)
            dxt = args.dxt if args.dxt.is_absolute() else ROOT / args.dxt
            if not args.no_build:
                build_dxt(dxt, workdir)
            if not dxt.exists():
                raise GateError(f"dxt binary not found: {dxt}")
            if shutil.which(args.duckdb) is None and not Path(args.duckdb).exists():
                raise GateError("DuckDB CLI is required for the build gate")

            if args.project_dir is None:
                source_project = checkout_public_project(workdir, args.repo_url, args.ref)
            else:
                source_project = args.project_dir.resolve()
                if not (source_project / "dbt_project.yml").exists():
                    raise GateError(f"--project-dir does not look like a dbt project: {source_project}")
            project_dir = copy_public_project(source_project, workdir / "project")
            target_dir = workdir / "target-dxt"

            manifest_path, run_results_path = run_build_gate(dxt, project_dir, target_dir)
            validate_manifest_shape(manifest_path, project_dir)
            validate_selectors(dxt, project_dir)
            validate_run_results(run_results_path)
            validate_duckdb_relations(project_dir, args.duckdb)
            manifest = load_manifest(manifest_path)
            if "dxt_metadata" in manifest:
                raise GateError("manifest must not emit dxt_metadata in the dbt artifact")
    except GateError as exc:
        print(f"Jaffle build gate failed: {exc}", file=sys.stderr)
        return 1

    print("Jaffle build gate passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

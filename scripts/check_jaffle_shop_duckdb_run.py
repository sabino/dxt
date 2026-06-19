from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
from collections import Counter
from pathlib import Path

from check_jaffle_shop_duckdb_build import copy_public_project, load_json, validate_duckdb_relations
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
    load_schema_validator,
    run,
    validate_manifest_shape,
    validate_selectors,
)


RUN_RESULTS_SCHEMA = ROOT / "tests" / "schemas" / "dbt_run_results_v6_m3_slice.schema.json"
EXPECTED_RUN_MODELS = [
    "model.jaffle_shop.stg_customers",
    "model.jaffle_shop.stg_orders",
    "model.jaffle_shop.stg_payments",
    "model.jaffle_shop.customers",
    "model.jaffle_shop.orders",
]


def validate_run_results_schema(path: Path) -> None:
    schema_validator = load_schema_validator()
    data = load_json(path)
    schema = schema_validator.load_json(RUN_RESULTS_SCHEMA)
    errors = schema_validator.validate_manifest(data, schema)
    if errors:
        formatted = "\n".join(f"  - {error}" for error in errors)
        raise GateError(f"run_results schema slice validation failed:\n{formatted}")


def run_seed_prep(dxt: Path, project_dir: Path, target_dir: Path) -> None:
    run(
        [
            dxt,
            "build",
            "--project-dir",
            project_dir,
            "--target-path",
            target_dir,
            "--select",
            "resource_type:seed",
        ],
        cwd=ROOT,
    )


def run_model_gate(dxt: Path, project_dir: Path, target_dir: Path) -> tuple[Path, Path]:
    run([dxt, "run", "--project-dir", project_dir, "--target-path", target_dir], cwd=ROOT)
    manifest_path = target_dir / "manifest.json"
    run_results_path = target_dir / "run_results.json"
    if not manifest_path.exists():
        raise GateError(f"run did not write manifest: {manifest_path}")
    if not run_results_path.exists():
        raise GateError(f"run did not write run_results: {run_results_path}")
    return manifest_path, run_results_path


def validate_run_results(path: Path) -> None:
    validate_run_results_schema(path)
    data = load_json(path)
    results = data.get("results")
    if not isinstance(results, list):
        raise GateError("run_results results must be an array")
    assert_equal("run model result count", len(results), 5)
    assert_equal("run model unique ids", [result.get("unique_id") for result in results], EXPECTED_RUN_MODELS)
    status_counts = Counter(result.get("status") for result in results)
    assert_equal("run model status counts", dict(sorted(status_counts.items())), {"success": 5})
    for result in results:
        unique_id = result.get("unique_id")
        if not isinstance(unique_id, str) or not unique_id.startswith("model."):
            raise GateError(f"unexpected run result resource: {unique_id!r}")
        if result.get("compiled") is not True:
            raise GateError(f"model result should be compiled: {unique_id}")
        if result.get("compiled_code") in (None, ""):
            raise GateError(f"model result should include compiled code: {unique_id}")
        if result.get("relation_name") in (None, ""):
            raise GateError(f"model result should include relation_name: {unique_id}")
        if result.get("failures") is not None:
            raise GateError(f"model result failures should be null: {unique_id}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Run a public Jaffle Shop DuckDB run gate through the Zig dxt binary. "
            "The harness prepares seed relations first because dbt run does not create seeds."
        )
    )
    parser.add_argument("--project-dir", type=Path, help="Existing Jaffle Shop DuckDB checkout. It is copied into a temporary directory before run.")
    parser.add_argument("--repo-url", default=DEFAULT_REPO_URL, help="Public repository URL used when --project-dir is omitted.")
    parser.add_argument("--ref", default=DEFAULT_REF, help="Git ref used when --project-dir is omitted.")
    parser.add_argument("--dxt", type=Path, default=DEFAULT_DXT, help="Path to the dxt binary.")
    parser.add_argument("--duckdb", default=shutil.which("duckdb") or "duckdb", help="DuckDB CLI used for relation validation.")
    parser.add_argument("--no-build", action="store_true", help="Use the existing --dxt binary without running zig build first.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        with tempfile.TemporaryDirectory(prefix="dxt-jaffle-run-gate-") as tmp:
            workdir = Path(tmp)
            dxt = args.dxt if args.dxt.is_absolute() else ROOT / args.dxt
            if not args.no_build:
                build_dxt(dxt, workdir)
            if not dxt.exists():
                raise GateError(f"dxt binary not found: {dxt}")
            if shutil.which(args.duckdb) is None and not Path(args.duckdb).exists():
                raise GateError("DuckDB CLI is required for the run gate")

            if args.project_dir is None:
                source_project = checkout_public_project(workdir, args.repo_url, args.ref)
            else:
                source_project = args.project_dir.resolve()
                if not (source_project / "dbt_project.yml").exists():
                    raise GateError(f"--project-dir does not look like a dbt project: {source_project}")
            project_dir = copy_public_project(source_project, workdir / "project")
            target_dir = workdir / "target-dxt"

            run_seed_prep(dxt, project_dir, target_dir)
            manifest_path, run_results_path = run_model_gate(dxt, project_dir, target_dir)
            validate_manifest_shape(manifest_path, project_dir)
            validate_selectors(dxt, project_dir)
            validate_run_results(run_results_path)
            validate_duckdb_relations(project_dir, args.duckdb)
            manifest = load_manifest(manifest_path)
            if "dxt_metadata" in manifest:
                raise GateError("manifest must not emit dxt_metadata in the dbt artifact")
    except GateError as exc:
        print(f"Jaffle run gate failed: {exc}", file=sys.stderr)
        return 1

    print("Jaffle run gate passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

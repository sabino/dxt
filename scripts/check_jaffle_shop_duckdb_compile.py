from __future__ import annotations

import argparse
import sys
import tempfile
from collections import Counter
from pathlib import Path
from typing import Any

from check_jaffle_shop_duckdb_build import copy_public_project, load_json
from check_jaffle_shop_duckdb_parse import (
    DEFAULT_DXT,
    DEFAULT_REF,
    DEFAULT_REPO_URL,
    EXPECTED_MODELS,
    EXPECTED_TESTS,
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


EXPECTED_COMPILED_MODELS = EXPECTED_MODELS
EXPECTED_COMPILED_TESTS = EXPECTED_TESTS


def run_compile_gate(dxt: Path, project_dir: Path, target_dir: Path) -> Path:
    run([dxt, "compile", "--project-dir", project_dir, "--target-path", target_dir], cwd=ROOT)
    manifest_path = target_dir / "manifest.json"
    if not manifest_path.exists():
        raise GateError(f"compile did not write manifest: {manifest_path}")
    run_results_path = target_dir / "run_results.json"
    if run_results_path.exists():
        raise GateError(f"compile should not write run_results: {run_results_path}")
    return manifest_path


def assert_compiled_node(manifest: dict[str, Any], target_dir: Path, unique_id: str, *, token: str) -> None:
    node = manifest["nodes"][unique_id]
    if node.get("compiled") is not True:
        raise GateError(f"compiled flag missing for {unique_id}")
    compiled_code = node.get("compiled_code")
    if not isinstance(compiled_code, str) or not compiled_code.strip():
        raise GateError(f"compiled_code missing for {unique_id}")
    if "{{" in compiled_code or "{%" in compiled_code:
        raise GateError(f"compiled_code still contains Jinja syntax for {unique_id}")
    if token not in compiled_code:
        raise GateError(f"compiled_code for {unique_id} did not include expected token {token!r}")
    compiled_path = node.get("compiled_path")
    if not isinstance(compiled_path, str) or not compiled_path:
        raise GateError(f"compiled_path missing for {unique_id}")
    path = Path(compiled_path)
    if not path.is_file():
        raise GateError(f"compiled_path does not exist for {unique_id}: {compiled_path}")
    try:
        path.relative_to(target_dir)
    except ValueError as exc:
        raise GateError(f"compiled_path escaped the target directory for {unique_id}: {compiled_path}") from exc
    if path.read_text(encoding="utf-8") != compiled_code:
        raise GateError(f"compiled_path contents did not match compiled_code for {unique_id}")


def validate_compile_manifest(manifest_path: Path, project_dir: Path, target_dir: Path) -> None:
    validate_manifest_shape(manifest_path, project_dir)
    manifest = load_manifest(manifest_path)
    compiled = sorted(unique_id for unique_id, node in manifest["nodes"].items() if node.get("compiled") is True)
    assert_equal("compiled models and tests", compiled, sorted(EXPECTED_COMPILED_MODELS + EXPECTED_COMPILED_TESTS))
    compiled_counts = Counter(unique_id.split(".", 1)[0] for unique_id in compiled)
    assert_equal("compiled resource counts", dict(sorted(compiled_counts.items())), {"model": 5, "test": 20})

    assert_compiled_node(manifest, target_dir, "model.jaffle_shop.customers", token='"main"."stg_customers"')
    assert_compiled_node(manifest, target_dir, "model.jaffle_shop.orders", token="credit_card_amount")
    assert_compiled_node(manifest, target_dir, "model.jaffle_shop.stg_payments", token="amount / 100 as amount")
    assert_compiled_node(
        manifest,
        target_dir,
        "test.jaffle_shop.accepted_values_orders_status__placed__shipped__completed__return_pending__returned.be6b5b5ec3",
        token="value_field not in",
    )
    assert_compiled_node(
        manifest,
        target_dir,
        "test.jaffle_shop.relationships_orders_customer_id__customer_id__ref_customers_.c6ec7f58f2",
        token="left join parent",
    )

    manifest_text = manifest_path.read_text(encoding="utf-8")
    if str(project_dir) in manifest_text:
        raise GateError("compiled manifest leaked the temporary public project directory")
    if "dxt_metadata" in manifest:
        raise GateError("manifest must not emit dxt_metadata in the dbt artifact")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Run a public Jaffle Shop DuckDB compile gate through the Zig dxt binary. "
            "This is a developer-side compatibility harness; product behavior remains Zig."
        )
    )
    parser.add_argument("--project-dir", type=Path, help="Existing Jaffle Shop DuckDB checkout. It is copied into a temporary directory before compile.")
    parser.add_argument("--repo-url", default=DEFAULT_REPO_URL, help="Public repository URL used when --project-dir is omitted.")
    parser.add_argument("--ref", default=DEFAULT_REF, help="Git ref used when --project-dir is omitted.")
    parser.add_argument("--dxt", type=Path, default=DEFAULT_DXT, help="Path to the dxt binary.")
    parser.add_argument("--no-build", action="store_true", help="Use the existing --dxt binary without running zig build first.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        with tempfile.TemporaryDirectory(prefix="dxt-jaffle-compile-gate-") as tmp:
            workdir = Path(tmp)
            dxt = args.dxt if args.dxt.is_absolute() else ROOT / args.dxt
            if not args.no_build:
                build_dxt(dxt, workdir)
            if not dxt.exists():
                raise GateError(f"dxt binary not found: {dxt}")

            if args.project_dir is None:
                source_project = checkout_public_project(workdir, args.repo_url, args.ref)
            else:
                source_project = args.project_dir.resolve()
                if not (source_project / "dbt_project.yml").exists():
                    raise GateError(f"--project-dir does not look like a dbt project: {source_project}")
            project_dir = copy_public_project(source_project, workdir / "project")
            target_dir = workdir / "target-dxt"

            manifest_path = run_compile_gate(dxt, project_dir, target_dir)
            validate_compile_manifest(manifest_path, project_dir, target_dir)
            validate_selectors(dxt, project_dir)
            if (target_dir / "catalog.json").exists():
                catalog = load_json(target_dir / "catalog.json")
                raise GateError(f"compile should not write catalog.json, found keys: {sorted(catalog)}")
    except GateError as exc:
        print(f"Jaffle compile gate failed: {exc}", file=sys.stderr)
        return 1

    print("Jaffle compile gate passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

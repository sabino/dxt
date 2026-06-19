from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
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


CATALOG_SCHEMA = ROOT / "tests" / "schemas" / "dbt_catalog_v1_docs_slice.schema.json"
EXPECTED_CATALOG_NODES = [
    "model.jaffle_shop.customers",
    "model.jaffle_shop.orders",
    "model.jaffle_shop.stg_customers",
    "model.jaffle_shop.stg_orders",
    "model.jaffle_shop.stg_payments",
    "seed.jaffle_shop.raw_customers",
    "seed.jaffle_shop.raw_orders",
    "seed.jaffle_shop.raw_payments",
]
EXPECTED_COLUMNS = {
    "model.jaffle_shop.customers": [
        "customer_id",
        "first_name",
        "last_name",
        "first_order",
        "most_recent_order",
        "number_of_orders",
        "customer_lifetime_value",
    ],
    "model.jaffle_shop.orders": [
        "order_id",
        "customer_id",
        "order_date",
        "status",
        "credit_card_amount",
        "coupon_amount",
        "bank_transfer_amount",
        "gift_card_amount",
        "amount",
    ],
    "model.jaffle_shop.stg_customers": ["customer_id", "first_name", "last_name"],
    "model.jaffle_shop.stg_orders": ["order_id", "customer_id", "order_date", "status"],
    "model.jaffle_shop.stg_payments": ["payment_id", "order_id", "payment_method", "amount"],
    "seed.jaffle_shop.raw_customers": ["id", "first_name", "last_name"],
    "seed.jaffle_shop.raw_orders": ["id", "user_id", "order_date", "status"],
    "seed.jaffle_shop.raw_payments": ["id", "order_id", "payment_method", "amount"],
}


def validate_catalog_schema(path: Path) -> None:
    schema_validator = load_schema_validator()
    data = load_json(path)
    schema = schema_validator.load_json(CATALOG_SCHEMA)
    errors = schema_validator.validate_manifest(data, schema)
    if errors:
        formatted = "\n".join(f"  - {error}" for error in errors)
        raise GateError(f"catalog schema slice validation failed:\n{formatted}")


def prepare_relations(dxt: Path, project_dir: Path, target_dir: Path) -> None:
    run([dxt, "build", "--project-dir", project_dir, "--target-path", target_dir], cwd=ROOT)


def run_docs_gate(dxt: Path, project_dir: Path, target_dir: Path) -> tuple[Path, Path]:
    run([dxt, "docs", "generate", "--project-dir", project_dir, "--target-path", target_dir], cwd=ROOT)
    manifest_path = target_dir / "manifest.json"
    catalog_path = target_dir / "catalog.json"
    if not manifest_path.exists():
        raise GateError(f"docs generate did not write manifest: {manifest_path}")
    if not catalog_path.exists():
        raise GateError(f"docs generate did not write catalog: {catalog_path}")
    return manifest_path, catalog_path


def validate_catalog(path: Path, project_dir: Path) -> None:
    validate_catalog_schema(path)
    catalog_text = path.read_text(encoding="utf-8")
    if str(project_dir) in catalog_text:
        raise GateError("catalog leaked the temporary public project directory")
    catalog = load_json(path)
    assert_equal("catalog node ids", sorted(catalog["nodes"]), EXPECTED_CATALOG_NODES)
    assert_equal("catalog sources", catalog["sources"], {})
    assert_equal("catalog errors", catalog["errors"], None)
    for unique_id in EXPECTED_CATALOG_NODES:
        entry = catalog["nodes"][unique_id]
        metadata = entry["metadata"]
        assert_equal(f"{unique_id} catalog schema", metadata["schema"], "main")
        assert_equal(f"{unique_id} catalog name", metadata["name"], unique_id.rsplit(".", 1)[1])
        assert_equal(f"{unique_id} catalog columns", list(entry["columns"]), EXPECTED_COLUMNS[unique_id])
        if unique_id.startswith("model.jaffle_shop.stg_"):
            assert_equal(f"{unique_id} catalog type", metadata["type"], "VIEW")
        else:
            assert_equal(f"{unique_id} catalog type", metadata["type"], "BASE TABLE")


def validate_docs_manifest(path: Path, project_dir: Path) -> None:
    validate_manifest_shape(path, project_dir)
    manifest = load_manifest(path)
    compiled = sorted(unique_id for unique_id, node in manifest["nodes"].items() if node.get("compiled") is True)
    assert_equal(
        "docs compiled models",
        compiled,
        [
            "model.jaffle_shop.customers",
            "model.jaffle_shop.orders",
            "model.jaffle_shop.stg_customers",
            "model.jaffle_shop.stg_orders",
            "model.jaffle_shop.stg_payments",
        ],
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Run a public Jaffle Shop DuckDB docs-generate gate through the Zig dxt binary. "
            "The harness builds relations first so catalog introspection has real tables and views."
        )
    )
    parser.add_argument("--project-dir", type=Path, help="Existing Jaffle Shop DuckDB checkout. It is copied into a temporary directory before docs generation.")
    parser.add_argument("--repo-url", default=DEFAULT_REPO_URL, help="Public repository URL used when --project-dir is omitted.")
    parser.add_argument("--ref", default=DEFAULT_REF, help="Git ref used when --project-dir is omitted.")
    parser.add_argument("--dxt", type=Path, default=DEFAULT_DXT, help="Path to the dxt binary.")
    parser.add_argument("--duckdb", default=shutil.which("duckdb") or "duckdb", help="DuckDB CLI used for relation validation.")
    parser.add_argument("--no-build", action="store_true", help="Use the existing --dxt binary without running zig build first.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        with tempfile.TemporaryDirectory(prefix="dxt-jaffle-docs-gate-") as tmp:
            workdir = Path(tmp)
            dxt = args.dxt if args.dxt.is_absolute() else ROOT / args.dxt
            if not args.no_build:
                build_dxt(dxt, workdir)
            if not dxt.exists():
                raise GateError(f"dxt binary not found: {dxt}")
            if shutil.which(args.duckdb) is None and not Path(args.duckdb).exists():
                raise GateError("DuckDB CLI is required for the docs gate")

            if args.project_dir is None:
                source_project = checkout_public_project(workdir, args.repo_url, args.ref)
            else:
                source_project = args.project_dir.resolve()
                if not (source_project / "dbt_project.yml").exists():
                    raise GateError(f"--project-dir does not look like a dbt project: {source_project}")
            project_dir = copy_public_project(source_project, workdir / "project")
            build_target_dir = workdir / "target-build"
            docs_target_dir = workdir / "target-docs"

            prepare_relations(dxt, project_dir, build_target_dir)
            manifest_path, catalog_path = run_docs_gate(dxt, project_dir, docs_target_dir)
            validate_docs_manifest(manifest_path, project_dir)
            validate_selectors(dxt, project_dir)
            validate_catalog(catalog_path, project_dir)
            validate_duckdb_relations(project_dir, args.duckdb)
            manifest = load_manifest(manifest_path)
            if "dxt_metadata" in manifest:
                raise GateError("manifest must not emit dxt_metadata in the dbt artifact")
    except GateError as exc:
        print(f"Jaffle docs gate failed: {exc}", file=sys.stderr)
        return 1

    print("Jaffle docs gate passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

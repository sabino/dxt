from __future__ import annotations

import argparse
import importlib.util
import json
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DXT = ROOT / "zig-out" / "bin" / "dxt"
DEFAULT_REPO_URL = "https://github.com/dbt-labs/jaffle_shop_duckdb.git"
DEFAULT_REF = "36bde6cba69d962b83be1d52fc65a0dce1cb4ebb"
SCHEMA_VALIDATOR_PATH = ROOT / "scripts" / "validate_manifest_schema.py"

EXPECTED_MODELS = [
    "model.jaffle_shop.customers",
    "model.jaffle_shop.orders",
    "model.jaffle_shop.stg_customers",
    "model.jaffle_shop.stg_orders",
    "model.jaffle_shop.stg_payments",
]
EXPECTED_SEEDS = [
    "seed.jaffle_shop.raw_customers",
    "seed.jaffle_shop.raw_orders",
    "seed.jaffle_shop.raw_payments",
]
EXPECTED_DOCS = [
    "doc.jaffle_shop.__overview__",
    "doc.jaffle_shop.orders_status",
]
EXPECTED_STAGING_MODELS = [
    "model.jaffle_shop.stg_customers",
    "model.jaffle_shop.stg_orders",
    "model.jaffle_shop.stg_payments",
]
EXPECTED_TESTS = [
    "test.jaffle_shop.accepted_values_orders_status__placed__shipped__completed__return_pending__returned.be6b5b5ec3",
    "test.jaffle_shop.accepted_values_stg_orders_status__placed__shipped__completed__return_pending__returned.080fb20aad",
    "test.jaffle_shop.accepted_values_stg_payments_payment_method__credit_card__coupon__bank_transfer__gift_card.3c3820f278",
    "test.jaffle_shop.not_null_customers_customer_id.5c9bf9911d",
    "test.jaffle_shop.not_null_orders_amount.106140f9fd",
    "test.jaffle_shop.not_null_orders_bank_transfer_amount.7743500c49",
    "test.jaffle_shop.not_null_orders_coupon_amount.ab90c90625",
    "test.jaffle_shop.not_null_orders_credit_card_amount.d3ca593b59",
    "test.jaffle_shop.not_null_orders_customer_id.c5f02694af",
    "test.jaffle_shop.not_null_orders_gift_card_amount.413a0d2d7a",
    "test.jaffle_shop.not_null_orders_order_id.cf6c17daed",
    "test.jaffle_shop.not_null_stg_customers_customer_id.e2cfb1f9aa",
    "test.jaffle_shop.not_null_stg_orders_order_id.81cfe2fe64",
    "test.jaffle_shop.not_null_stg_payments_payment_id.c19cc50075",
    "test.jaffle_shop.relationships_orders_customer_id__customer_id__ref_customers_.c6ec7f58f2",
    "test.jaffle_shop.unique_customers_customer_id.c5af1ff4b1",
    "test.jaffle_shop.unique_orders_order_id.fed79b3a6e",
    "test.jaffle_shop.unique_stg_customers_customer_id.c7614daada",
    "test.jaffle_shop.unique_stg_orders_order_id.e3b841c71a",
    "test.jaffle_shop.unique_stg_payments_payment_id.3744510712",
]
EXPECTED_ORDERS_PLUS = [
    "model.jaffle_shop.orders",
    "test.jaffle_shop.accepted_values_orders_status__placed__shipped__completed__return_pending__returned.be6b5b5ec3",
    "test.jaffle_shop.not_null_orders_amount.106140f9fd",
    "test.jaffle_shop.not_null_orders_bank_transfer_amount.7743500c49",
    "test.jaffle_shop.not_null_orders_coupon_amount.ab90c90625",
    "test.jaffle_shop.not_null_orders_credit_card_amount.d3ca593b59",
    "test.jaffle_shop.not_null_orders_customer_id.c5f02694af",
    "test.jaffle_shop.not_null_orders_gift_card_amount.413a0d2d7a",
    "test.jaffle_shop.not_null_orders_order_id.cf6c17daed",
    "test.jaffle_shop.relationships_orders_customer_id__customer_id__ref_customers_.c6ec7f58f2",
    "test.jaffle_shop.unique_orders_order_id.fed79b3a6e",
]


class GateError(Exception):
    pass


def display_arg(arg: str) -> str:
    if "://" not in arg:
        return arg
    scheme, rest = arg.split("://", 1)
    authority, _, path = rest.partition("/")
    if "@" not in authority:
        return arg
    _, host = authority.rsplit("@", 1)
    suffix = f"/{path}" if path else ""
    return f"{scheme}://<redacted>@{host}{suffix}"


def display_command(command: list[str]) -> str:
    return " ".join(display_arg(arg) for arg in command)


def load_schema_validator() -> Any:
    spec = importlib.util.spec_from_file_location("validate_manifest_schema", SCHEMA_VALIDATOR_PATH)
    if spec is None or spec.loader is None:
        raise GateError(f"could not load schema validator from {SCHEMA_VALIDATOR_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(args: list[str | Path], *, cwd: Path) -> subprocess.CompletedProcess[str]:
    command = [str(arg) for arg in args]
    try:
        result = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    except FileNotFoundError as exc:
        raise GateError(f"command not found: {command[0]}") from exc
    if result.returncode != 0:
        raise GateError(
            f"command failed with exit code {result.returncode}: {display_command(command)}\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    return result


def build_dxt(dxt: Path, cache_root: Path) -> None:
    if dxt != DEFAULT_DXT:
        return
    run(
        [
            "zig",
            "build",
            "--cache-dir",
            cache_root / "zig-cache",
            "--global-cache-dir",
            cache_root / "zig-global-cache",
        ],
        cwd=ROOT,
    )


def checkout_public_project(workdir: Path, repo_url: str, ref: str) -> Path:
    project = workdir / "jaffle_shop_duckdb"
    project.mkdir()
    run(["git", "init", "-q"], cwd=project)
    run(["git", "remote", "add", "origin", repo_url], cwd=project)
    run(["git", "fetch", "--depth", "1", "origin", ref], cwd=project)
    run(["git", "checkout", "-q", "FETCH_HEAD"], cwd=project)
    return project


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise GateError(f"could not read manifest: {path}") from exc
    except json.JSONDecodeError as exc:
        raise GateError(f"manifest is not valid JSON: {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise GateError("manifest root must be an object")
    return data


def assert_equal(label: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise GateError(f"{label} mismatch\nexpected: {expected!r}\nactual:   {actual!r}")


def assert_no_absolute_paths(value: Any, *, key: str = "$", project_dir: Path) -> None:
    if isinstance(value, dict):
        for child_key, child_value in value.items():
            if child_key in {"path", "original_file_path", "patch_path"} and isinstance(child_value, str):
                if Path(child_value).is_absolute():
                    raise GateError(f"{child_key} leaked an absolute path: {child_value}")
            assert_no_absolute_paths(child_value, key=child_key, project_dir=project_dir)
    elif isinstance(value, list):
        for child_value in value:
            assert_no_absolute_paths(child_value, key=key, project_dir=project_dir)
    elif isinstance(value, str) and str(project_dir) in value:
        raise GateError(f"manifest value leaked the project directory under {key}")


def validate_manifest_shape(manifest_path: Path, project_dir: Path) -> None:
    schema_validator = load_schema_validator()
    manifest = load_manifest(manifest_path)
    schema = schema_validator.load_json(schema_validator.DEFAULT_SCHEMA)
    errors = schema_validator.validate_manifest(manifest, schema)
    if errors:
        formatted = "\n".join(f"  - {error}" for error in errors)
        raise GateError(f"manifest schema slice validation failed:\n{formatted}")

    assert_equal("project name", manifest["metadata"]["project_name"], "jaffle_shop")
    assert_equal("model unique ids", sorted(id for id in manifest["nodes"] if id.startswith("model.")), EXPECTED_MODELS)
    assert_equal("seed unique ids", sorted(id for id in manifest["nodes"] if id.startswith("seed.")), EXPECTED_SEEDS)
    assert_equal("generic test unique ids", sorted(id for id in manifest["nodes"] if id.startswith("test.")), EXPECTED_TESTS)
    assert_equal("docs unique ids", sorted(manifest["docs"]), EXPECTED_DOCS)
    assert_equal("sources", manifest["sources"], {})
    assert_equal("exposures", manifest["exposures"], {})
    assert_equal("macros", manifest["macros"], {})
    assert_equal("disabled", manifest["disabled"], {})
    if "dxt_metadata" in manifest:
        raise GateError("manifest must not emit dxt_metadata in the dbt artifact")

    resource_counts = Counter(node["resource_type"] for node in manifest["nodes"].values())
    assert_equal("resource counts", dict(sorted(resource_counts.items())), {"model": 5, "seed": 3, "test": 20})
    test_counts = Counter(
        node["test_metadata"]["name"]
        for node in manifest["nodes"].values()
        if node["resource_type"] == "test"
    )
    assert_equal(
        "generic test counts",
        dict(sorted(test_counts.items())),
        {"accepted_values": 3, "not_null": 11, "relationships": 1, "unique": 5},
    )

    assert_equal(
        "customers parents",
        manifest["parent_map"]["model.jaffle_shop.customers"],
        [
            "model.jaffle_shop.stg_customers",
            "model.jaffle_shop.stg_orders",
            "model.jaffle_shop.stg_payments",
        ],
    )
    assert_equal(
        "orders parents",
        manifest["parent_map"]["model.jaffle_shop.orders"],
        ["model.jaffle_shop.stg_orders", "model.jaffle_shop.stg_payments"],
    )
    relationships_id = "test.jaffle_shop.relationships_orders_customer_id__customer_id__ref_customers_.c6ec7f58f2"
    assert_equal(
        "relationships test parents",
        manifest["parent_map"][relationships_id],
        ["model.jaffle_shop.customers", "model.jaffle_shop.orders"],
    )
    assert_equal(
        "relationships test macro deps",
        manifest["nodes"][relationships_id]["depends_on"]["macros"],
        ["macro.dbt.test_relationships", "macro.dbt.get_where_subquery"],
    )
    assert_equal(
        "customers depends_on nodes",
        manifest["nodes"]["model.jaffle_shop.customers"]["depends_on"]["nodes"],
        [
            "model.jaffle_shop.stg_customers",
            "model.jaffle_shop.stg_orders",
            "model.jaffle_shop.stg_payments",
        ],
    )
    assert_equal(
        "customers refs",
        manifest["nodes"]["model.jaffle_shop.customers"]["refs"],
        [
            {"name": "stg_customers", "package": None, "version": None},
            {"name": "stg_orders", "package": None, "version": None},
            {"name": "stg_payments", "package": None, "version": None},
        ],
    )
    assert_equal(
        "orders depends_on nodes",
        manifest["nodes"]["model.jaffle_shop.orders"]["depends_on"]["nodes"],
        ["model.jaffle_shop.stg_orders", "model.jaffle_shop.stg_payments"],
    )
    assert_equal(
        "orders refs",
        manifest["nodes"]["model.jaffle_shop.orders"]["refs"],
        [
            {"name": "stg_orders", "package": None, "version": None},
            {"name": "stg_payments", "package": None, "version": None},
        ],
    )
    assert_equal(
        "relationships test depends_on nodes",
        manifest["nodes"][relationships_id]["depends_on"]["nodes"],
        ["model.jaffle_shop.customers", "model.jaffle_shop.orders"],
    )
    assert_equal(
        "relationships test refs",
        manifest["nodes"][relationships_id]["refs"],
        [
            {"name": "customers", "package": None, "version": None},
            {"name": "orders", "package": None, "version": None},
        ],
    )
    assert_equal("customers materialization", manifest["nodes"]["model.jaffle_shop.customers"]["config"]["materialized"], "table")
    assert_equal("orders materialization", manifest["nodes"]["model.jaffle_shop.orders"]["config"]["materialized"], "table")
    for model_id in EXPECTED_STAGING_MODELS:
        assert_equal(f"{model_id} materialization", manifest["nodes"][model_id]["config"]["materialized"], "view")
        assert_equal(f"{model_id} docs color", manifest["nodes"][model_id]["config"]["docs"]["node_color"], "silver")
    for seed_id in EXPECTED_SEEDS:
        assert_equal(f"{seed_id} materialization", manifest["nodes"][seed_id]["config"]["materialized"], "seed")
        assert_equal(f"{seed_id} docs color", manifest["nodes"][seed_id]["config"]["docs"]["node_color"], "#cd7f32")
    assert_equal("customers docs color", manifest["nodes"]["model.jaffle_shop.customers"]["config"]["docs"]["node_color"], "gold")
    assert_equal("orders docs color", manifest["nodes"]["model.jaffle_shop.orders"]["config"]["docs"]["node_color"], "gold")
    assert_no_absolute_paths(manifest, project_dir=project_dir)


def run_parse_gate(dxt: Path, project_dir: Path, target_dir: Path) -> Path:
    run([dxt, "parse", "--project-dir", project_dir, "--target-path", target_dir], cwd=ROOT)
    manifest_path = target_dir / "manifest.json"
    if not manifest_path.exists():
        raise GateError(f"parse did not write manifest: {manifest_path}")
    return manifest_path


def ls_text(dxt: Path, project_dir: Path, selector: str) -> list[str]:
    result = run([dxt, "ls", "--project-dir", project_dir, "--select", selector], cwd=ROOT)
    return result.stdout.splitlines()


def ls_json(dxt: Path, project_dir: Path, selector: str) -> list[str]:
    result = run([dxt, "ls", "--project-dir", project_dir, "--select", selector, "--output", "json"], cwd=ROOT)
    data = json.loads(result.stdout)
    return [item["unique_id"] for item in data]


def ls_resource_type_json(dxt: Path, project_dir: Path, resource_type: str) -> list[str]:
    result = run([dxt, "ls", "--project-dir", project_dir, "--resource-type", resource_type, "--output", "json"], cwd=ROOT)
    data = json.loads(result.stdout)
    return [item["unique_id"] for item in data]


def validate_selectors(dxt: Path, project_dir: Path) -> None:
    assert_equal("model resource-type selector", ls_resource_type_json(dxt, project_dir, "model"), EXPECTED_MODELS)
    assert_equal("seed resource-type selector", ls_resource_type_json(dxt, project_dir, "seed"), EXPECTED_SEEDS)
    assert_equal("view materialization selector", ls_json(dxt, project_dir, "config.materialized:view"), EXPECTED_STAGING_MODELS)
    assert_equal(
        "staging wildcard selector",
        ls_text(dxt, project_dir, "stg_*"),
        [
            "model.jaffle_shop.stg_customers",
            "model.jaffle_shop.stg_orders",
            "model.jaffle_shop.stg_payments",
            "test.jaffle_shop.accepted_values_stg_orders_status__placed__shipped__completed__return_pending__returned.080fb20aad",
            "test.jaffle_shop.accepted_values_stg_payments_payment_method__credit_card__coupon__bank_transfer__gift_card.3c3820f278",
            "test.jaffle_shop.not_null_stg_customers_customer_id.e2cfb1f9aa",
            "test.jaffle_shop.not_null_stg_orders_order_id.81cfe2fe64",
            "test.jaffle_shop.not_null_stg_payments_payment_id.c19cc50075",
            "test.jaffle_shop.unique_stg_customers_customer_id.c7614daada",
            "test.jaffle_shop.unique_stg_orders_order_id.e3b841c71a",
            "test.jaffle_shop.unique_stg_payments_payment_id.3744510712",
        ],
    )
    assert_equal(
        "graph expansion selector",
        ls_text(dxt, project_dir, "customers+"),
        [
            "model.jaffle_shop.customers",
            "test.jaffle_shop.not_null_customers_customer_id.5c9bf9911d",
            "test.jaffle_shop.relationships_orders_customer_id__customer_id__ref_customers_.c6ec7f58f2",
            "test.jaffle_shop.unique_customers_customer_id.c5af1ff4b1",
        ],
    )
    assert_equal(
        "staging path selector",
        ls_json(dxt, project_dir, "path:models/staging/*.sql"),
        EXPECTED_STAGING_MODELS,
    )
    assert_equal("orders graph expansion selector", ls_json(dxt, project_dir, "orders+"), EXPECTED_ORDERS_PLUS)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Run the committed M1 parse gate against public Jaffle Shop DuckDB. "
            "This is a developer-side compatibility harness; dxt product behavior still runs through the Zig binary."
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
        with tempfile.TemporaryDirectory(prefix="dxt-jaffle-gate-") as tmp:
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

            target_dir = workdir / "target-dxt"
            manifest_path = run_parse_gate(dxt, project_dir, target_dir)
            validate_manifest_shape(manifest_path, project_dir)
            validate_selectors(dxt, project_dir)
    except GateError as exc:
        print(f"Jaffle parse gate failed: {exc}", file=sys.stderr)
        return 1

    print("Jaffle parse gate passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

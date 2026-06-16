from __future__ import annotations

import argparse
import importlib.metadata
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DXT = ROOT / "zig-out" / "bin" / "dxt"
DEFAULT_FIXTURES = [
    "single_model",
    "model_ref",
    "seed_ref",
    "source_ref",
    "docs_blocks",
    "model_properties",
    "generic_test_arguments",
    "exposure_artifacts",
    "macro_artifacts",
    "macro_properties",
    "macro_paths_custom",
    "package_macro_namespace",
    "package_ref_selector",
    "project_model_path_config",
]
ALLOWED_MISMATCHES: dict[tuple[str, str, str], tuple[Any, Any, str]] = {
    (
        "package_ref_selector",
        "exposure.util_pkg.package_dashboard",
        "depends_on.nodes",
    ): (
        ["model.util_pkg.pkg_customers"],
        ["model.package_ref_selector.pkg_customers"],
        "dbt Core resolves this installed-package exposure ref to the root same-name model; dxt currently resolves it package-local",
    ),
    (
        "package_ref_selector",
        "exposure.util_pkg.package_dashboard",
        "parent_map",
    ): (
        ["model.util_pkg.pkg_customers"],
        ["model.package_ref_selector.pkg_customers"],
        "same installed-package exposure ref-resolution gap as depends_on.nodes",
    ),
    (
        "package_ref_selector",
        "model.package_ref_selector.pkg_customers",
        "child_map",
    ): (
        [],
        ["exposure.util_pkg.package_dashboard"],
        "same installed-package exposure ref-resolution gap as depends_on.nodes",
    ),
    (
        "package_ref_selector",
        "model.util_pkg.pkg_customers",
        "child_map",
    ): (
        ["exposure.util_pkg.package_dashboard", "model.package_ref_selector.root_customers"],
        ["model.package_ref_selector.root_customers"],
        "same installed-package exposure ref-resolution gap as depends_on.nodes",
    ),
}


class OracleError(Exception):
    pass


def run(args: list[str | Path], *, cwd: Path) -> subprocess.CompletedProcess[str]:
    command = [str(arg) for arg in args]
    try:
        result = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    except FileNotFoundError as exc:
        raise OracleError(f"command not found: {command[0]}") from exc
    if result.returncode != 0:
        raise OracleError(
            f"command failed with exit code {result.returncode}: {' '.join(command)}\n"
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


def load_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise OracleError(f"could not read JSON file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise OracleError(f"invalid JSON file: {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise OracleError(f"expected JSON object: {path}")
    return data


def assert_equal(label: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise OracleError(f"{label} mismatch\nexpected: {expected!r}\nactual:   {actual!r}")


def assert_equal_or_allow(
    fixture: str,
    unique_id: str,
    field: str,
    actual: Any,
    expected: Any,
    allowed: list[str],
) -> None:
    if actual == expected:
        return
    allowed_entry = ALLOWED_MISMATCHES.get((fixture, unique_id, field))
    if allowed_entry is not None:
        allowed_actual, allowed_expected, reason = allowed_entry
        if actual != allowed_actual or expected != allowed_expected:
            raise OracleError(
                f"{fixture} {unique_id} {field} mismatch changed from the allowed gap\n"
                f"allowed expected: {allowed_expected!r}\n"
                f"allowed actual:   {allowed_actual!r}\n"
                f"expected:         {expected!r}\n"
                f"actual:           {actual!r}"
            )
        allowed.append(f"{fixture} {unique_id} {field}: {reason}")
        return
    assert_equal(f"{fixture} {unique_id} {field}", actual, expected)


def import_dbt_runner() -> Any:
    try:
        from dbt.cli.main import dbtRunner
    except ImportError as exc:
        raise OracleError(
            "dbt Core is not importable. Install developer oracle dependencies such as "
            "`dbt-core` and `dbt-duckdb`, then rerun this script."
        ) from exc
    return dbtRunner


def dbt_versions() -> str:
    versions: list[str] = []
    for package in ["dbt-core", "dbt-duckdb"]:
        try:
            versions.append(f"{package} {importlib.metadata.version(package)}")
        except importlib.metadata.PackageNotFoundError:
            versions.append(f"{package} not installed")
    return ", ".join(versions)


def write_default_profile(profile_dir: Path, database_path: Path) -> None:
    profile_dir.mkdir(parents=True)
    (profile_dir / "profiles.yml").write_text(
        "\n".join(
            [
                "default:",
                "  target: dev",
                "  outputs:",
                "    dev:",
                "      type: duckdb",
                f"      path: {database_path}",
                "",
            ]
        ),
        encoding="utf-8",
    )


def run_dbt_parse(
    fixture: str,
    dbt_runner: Any,
    project: Path,
    profile_dir: Path,
    target: Path,
    log_path: Path,
    allow_artifact_on_error: bool,
) -> tuple[dict[str, Any], str | None]:
    previous_usage_stats = os.environ.get("DBT_SEND_ANONYMOUS_USAGE_STATS")
    os.environ["DBT_SEND_ANONYMOUS_USAGE_STATS"] = "false"
    try:
        result = dbt_runner().invoke(
            [
                "--log-path",
                str(log_path),
                "parse",
                "--project-dir",
                str(project),
                "--profiles-dir",
                str(profile_dir),
                "--profile",
                "default",
                "--target-path",
                str(target),
                "--quiet",
            ]
        )
    finally:
        if previous_usage_stats is None:
            os.environ.pop("DBT_SEND_ANONYMOUS_USAGE_STATS", None)
        else:
            os.environ["DBT_SEND_ANONYMOUS_USAGE_STATS"] = previous_usage_stats
    manifest_path = target / "manifest.json"
    warning = None
    if not result.success:
        if not allow_artifact_on_error or not manifest_path.exists():
            raise OracleError(f"dbt parse failed for {fixture}: {result.exception!r}")
        warning = f"{fixture}: dbt parse returned {type(result.exception).__name__} after writing manifest.json"
    return load_json(manifest_path), warning


def run_dxt_parse(dxt: Path, project: Path, target: Path) -> dict[str, Any]:
    run([dxt, "parse", "--project-dir", project, "--target-path", target], cwd=ROOT)
    return load_json(target / "manifest.json")


def filtered_docs(manifest: dict[str, Any]) -> list[str]:
    return sorted(unique_id for unique_id in manifest["docs"] if not unique_id.startswith("doc.dbt."))


def read_project_name(project_file: Path) -> str | None:
    for line in project_file.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped.startswith("name:"):
            continue
        value = stripped.split(":", 1)[1].strip()
        if not value:
            return None
        return value.strip("\"'")
    return None


def fixture_package_names(project: Path) -> set[str]:
    root_name = read_project_name(project / "dbt_project.yml")
    if root_name is None:
        raise OracleError(f"could not read project name from {project / 'dbt_project.yml'}")
    names = {root_name}
    packages_dir = project / "dbt_packages"
    if packages_dir.exists():
        for package_project in sorted(packages_dir.glob("*/dbt_project.yml")):
            package_name = read_project_name(package_project)
            if package_name is not None:
                names.add(package_name)
    return names


def filtered_macros(manifest: dict[str, Any], packages: set[str]) -> list[str]:
    return sorted(
        unique_id
        for unique_id, macro in manifest["macros"].items()
        if macro.get("package_name") in packages
    )


def macro_package(unique_id: str) -> str | None:
    parts = unique_id.split(".")
    if len(parts) < 3 or parts[0] != "macro":
        return None
    return parts[1]


def normalize_macro_deps(macros: Any, packages: set[str]) -> list[str]:
    if not isinstance(macros, list):
        return []
    return sorted(
        macro
        for macro in macros
        if macro.startswith("macro.dbt.") or macro_package(macro) in packages
    )


def normalize_refs(refs: Any) -> list[dict[str, Any]]:
    normalized: list[dict[str, Any]] = []
    if not isinstance(refs, list):
        return normalized
    for ref in refs:
        if isinstance(ref, dict):
            normalized.append(
                {
                    "name": ref.get("name"),
                    "package": ref.get("package"),
                    "version": ref.get("version"),
                }
            )
    return normalized


def normalize_sources(sources: Any) -> list[Any]:
    if not isinstance(sources, list):
        return []
    return sources


def depends_on_nodes(resource: dict[str, Any]) -> list[str]:
    depends_on = resource.get("depends_on", {})
    if not isinstance(depends_on, dict):
        return []
    nodes = depends_on.get("nodes", [])
    if not isinstance(nodes, list):
        return []
    return nodes


def compare_node(
    fixture: str,
    unique_id: str,
    dbt_node: dict[str, Any],
    dxt_node: dict[str, Any],
    packages: set[str],
) -> None:
    label = f"{fixture} {unique_id}"
    assert_equal(f"{label} resource_type", dxt_node.get("resource_type"), dbt_node.get("resource_type"))
    assert_equal(f"{label} depends_on.nodes", sorted(depends_on_nodes(dxt_node)), sorted(depends_on_nodes(dbt_node)))
    assert_equal(
        f"{label} depends_on.macros",
        normalize_macro_deps(dxt_node.get("depends_on", {}).get("macros"), packages),
        normalize_macro_deps(dbt_node.get("depends_on", {}).get("macros"), packages),
    )
    assert_equal(f"{label} refs", normalize_refs(dxt_node.get("refs")), normalize_refs(dbt_node.get("refs")))
    assert_equal(f"{label} sources", normalize_sources(dxt_node.get("sources")), normalize_sources(dbt_node.get("sources")))

    dxt_config = dxt_node.get("config", {})
    dbt_config = dbt_node.get("config", {})
    for key in ["enabled", "materialized"]:
        if key in dxt_config:
            assert_equal(f"{label} config.{key}", dxt_config.get(key), dbt_config.get(key))
    dxt_docs = dxt_config.get("docs", {})
    dbt_docs = dbt_config.get("docs", {})
    if "node_color" in dxt_docs:
        assert_equal(f"{label} config.docs.node_color", dxt_docs.get("node_color"), dbt_docs.get("node_color"))


def compare_source(fixture: str, unique_id: str, dbt_source: dict[str, Any], dxt_source: dict[str, Any]) -> None:
    label = f"{fixture} {unique_id}"
    for key in ["resource_type", "package_name", "source_name", "name"]:
        assert_equal(f"{label} {key}", dxt_source.get(key), dbt_source.get(key))


def compare_exposure(
    fixture: str,
    unique_id: str,
    dbt_exposure: dict[str, Any],
    dxt_exposure: dict[str, Any],
    allowed: list[str],
) -> None:
    label = f"{fixture} {unique_id}"
    for key in ["resource_type", "package_name", "name", "type"]:
        assert_equal(f"{label} {key}", dxt_exposure.get(key), dbt_exposure.get(key))
    assert_equal_or_allow(
        fixture,
        unique_id,
        "depends_on.nodes",
        sorted(depends_on_nodes(dxt_exposure)),
        sorted(depends_on_nodes(dbt_exposure)),
        allowed,
    )
    assert_equal(f"{label} refs", normalize_refs(dxt_exposure.get("refs")), normalize_refs(dbt_exposure.get("refs")))
    assert_equal(f"{label} sources", normalize_sources(dxt_exposure.get("sources")), normalize_sources(dbt_exposure.get("sources")))


def compare_doc(fixture: str, unique_id: str, dbt_doc: dict[str, Any], dxt_doc: dict[str, Any]) -> None:
    label = f"{fixture} {unique_id}"
    for key in ["resource_type", "package_name", "name"]:
        assert_equal(f"{label} {key}", dxt_doc.get(key), dbt_doc.get(key))
    assert_equal(
        f"{label} block_contents",
        dxt_doc.get("block_contents", "").strip(),
        dbt_doc.get("block_contents", "").strip(),
    )


def compare_macro(
    fixture: str,
    unique_id: str,
    dbt_macro: dict[str, Any],
    dxt_macro: dict[str, Any],
    packages: set[str],
) -> None:
    label = f"{fixture} {unique_id}"
    for key in ["resource_type", "package_name", "name"]:
        assert_equal(f"{label} {key}", dxt_macro.get(key), dbt_macro.get(key))
    assert_equal(
        f"{label} depends_on.macros",
        normalize_macro_deps(dxt_macro.get("depends_on", {}).get("macros"), packages),
        normalize_macro_deps(dbt_macro.get("depends_on", {}).get("macros"), packages),
    )


def compare_manifest(
    fixture: str,
    project: Path,
    dbt_manifest: dict[str, Any],
    dxt_manifest: dict[str, Any],
    allowed: list[str],
) -> None:
    assert_equal(f"{fixture} project_name", dxt_manifest["metadata"]["project_name"], dbt_manifest["metadata"]["project_name"])
    assert_equal(f"{fixture} node ids", sorted(dxt_manifest["nodes"]), sorted(dbt_manifest["nodes"]))
    assert_equal(f"{fixture} source ids", sorted(dxt_manifest["sources"]), sorted(dbt_manifest["sources"]))
    assert_equal(f"{fixture} exposure ids", sorted(dxt_manifest["exposures"]), sorted(dbt_manifest["exposures"]))
    assert_equal(f"{fixture} doc ids", sorted(dxt_manifest["docs"]), filtered_docs(dbt_manifest))

    packages = fixture_package_names(project)
    assert_equal(f"{fixture} macro ids", sorted(dxt_manifest["macros"]), filtered_macros(dbt_manifest, packages))

    for unique_id, dxt_node in dxt_manifest["nodes"].items():
        compare_node(fixture, unique_id, dbt_manifest["nodes"][unique_id], dxt_node, packages)
        assert_equal(
            f"{fixture} parent_map {unique_id}",
            sorted(dxt_manifest["parent_map"].get(unique_id, [])),
            sorted(dbt_manifest["parent_map"].get(unique_id, [])),
        )
        assert_equal_or_allow(
            fixture,
            unique_id,
            "child_map",
            sorted(dxt_manifest["child_map"].get(unique_id, [])),
            sorted(dbt_manifest["child_map"].get(unique_id, [])),
            allowed,
        )

    for unique_id, dxt_source in dxt_manifest["sources"].items():
        compare_source(fixture, unique_id, dbt_manifest["sources"][unique_id], dxt_source)

    for unique_id, dxt_exposure in dxt_manifest["exposures"].items():
        compare_exposure(fixture, unique_id, dbt_manifest["exposures"][unique_id], dxt_exposure, allowed)
        assert_equal_or_allow(
            fixture,
            unique_id,
            "parent_map",
            sorted(dxt_manifest["parent_map"].get(unique_id, [])),
            sorted(dbt_manifest["parent_map"].get(unique_id, [])),
            allowed,
        )
        assert_equal(
            f"{fixture} child_map {unique_id}",
            sorted(dxt_manifest["child_map"].get(unique_id, [])),
            sorted(dbt_manifest["child_map"].get(unique_id, [])),
        )

    for unique_id, dxt_doc in dxt_manifest["docs"].items():
        compare_doc(fixture, unique_id, dbt_manifest["docs"][unique_id], dxt_doc)

    for unique_id, dxt_macro in dxt_manifest["macros"].items():
        compare_macro(fixture, unique_id, dbt_manifest["macros"][unique_id], dxt_macro, packages)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Compare dxt M1 parse artifacts against dbt Core for supported synthetic fixtures. "
            "This is a developer-side oracle harness; product behavior still runs through the Zig binary."
        )
    )
    parser.add_argument("--dxt", type=Path, default=DEFAULT_DXT, help="Path to the dxt binary.")
    parser.add_argument("--fixtures", nargs="+", default=DEFAULT_FIXTURES, help="Fixture names under tests/fixtures to compare.")
    parser.add_argument("--no-build", action="store_true", help="Use the existing --dxt binary without running zig build first.")
    parser.add_argument("--allow-dbt-artifact-on-error", action="store_true", help="Accept a written dbt manifest when dbt returns a known post-artifact error.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        dbt_runner = import_dbt_runner()
        warnings: list[str] = []
        allowed: list[str] = []
        with tempfile.TemporaryDirectory(prefix="dxt-dbt-oracle-") as tmp:
            workdir = Path(tmp)
            dxt = args.dxt if args.dxt.is_absolute() else ROOT / args.dxt
            if not args.no_build:
                build_dxt(dxt, workdir)
            if not dxt.exists():
                raise OracleError(f"dxt binary not found: {dxt}")

            for fixture in args.fixtures:
                fixture_source = ROOT / "tests" / "fixtures" / fixture
                if not (fixture_source / "dbt_project.yml").exists():
                    raise OracleError(f"unknown fixture or missing dbt_project.yml: {fixture}")
                fixture_dir = workdir / fixture
                project = fixture_dir / "project"
                shutil.copytree(
                    fixture_source,
                    project,
                    ignore=shutil.ignore_patterns("target", "target-*", "logs", ".user.yml", "__pycache__"),
                )
                profile_dir = fixture_dir / "profiles"
                write_default_profile(profile_dir, fixture_dir / "oracle.duckdb")
                dbt_manifest, warning = run_dbt_parse(
                    fixture,
                    dbt_runner,
                    project,
                    profile_dir,
                    fixture_dir / "target-dbt",
                    fixture_dir / "logs-dbt",
                    args.allow_dbt_artifact_on_error,
                )
                if warning is not None:
                    warnings.append(warning)
                dxt_manifest = run_dxt_parse(dxt, project, fixture_dir / "target-dxt")
                compare_manifest(fixture, project, dbt_manifest, dxt_manifest, allowed)
    except OracleError as exc:
        print(f"dbt Core M1 oracle failed: {exc}", file=sys.stderr)
        return 1

    print(f"dbt Core M1 oracle passed for {len(args.fixtures)} fixture(s).")
    print(f"dbt oracle packages: {dbt_versions()}")
    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)
    for warning in sorted(set(allowed)):
        print(f"allowed gap: {warning}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

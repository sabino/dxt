"""Developer-only cold/warm compilation budgets against the pinned Core oracle."""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import os
import shutil
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

from validate_dbt_artifacts import assert_artifact

ROOT = Path(__file__).resolve().parents[1]


def make_project(project: Path, models: int) -> None:
    for directory in ["models", "macros"]:
        (project / directory).mkdir(parents=True)
    (project / "dbt_project.yml").write_text("name: performance\nversion: '1.0'\nprofile: performance\nvars:\n  initial: 1\n")
    (project / "profiles.yml").write_text("performance:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n      path: warehouse.duckdb\n      schema: main\n      threads: 4\n      keep_open: false\n")
    (project / "macros/arithmetic.sql").write_text("{% macro arithmetic(value) %}({{ value }} + 1){% endmacro %}")
    for index in range(models):
        expression = "var('initial')" if index % 20 == 0 else "'id'"
        dependency = "" if index % 20 == 0 else f" from {{{{ ref('model_{index - 1:04d}') }}}}"
        (project / f"models/model_{index:04d}.sql").write_text(f"select {{{{ arithmetic({expression}) }}}} as id{dependency}\n")


def invoke(command: list[str], project: Path) -> float:
    started = time.perf_counter()
    completed = subprocess.run(command, cwd=project, env={**os.environ, "DBT_SEND_ANONYMOUS_USAGE_STATS": "false"}, text=True, capture_output=True, timeout=120)
    elapsed = time.perf_counter() - started
    if completed.returncode:
        raise RuntimeError(f"Compilation failed: {completed.stdout}\n{completed.stderr}")
    return elapsed


def compiled_sql(target: Path, models: int) -> dict[str, str]:
    assert_artifact(target / "manifest.json")
    assert_artifact(target / "run_results.json")
    artifact = json.loads((target / "manifest.json").read_text())
    rows = json.loads((target / "run_results.json").read_text())["results"]
    if len(rows) != models or any(row["status"] != "success" for row in rows):
        raise AssertionError("Performance project did not compile every model successfully")
    return {key: " ".join(node["compiled_code"].split()) for key, node in artifact["nodes"].items() if node["resource_type"] == "model"}


def measure(binary: Path, models: int, repetitions: int) -> dict:
    if importlib.metadata.version("dbt-core") != "1.10.5":
        raise RuntimeError("Performance certification requires dbt Core 1.10.5")
    core = shutil.which("dbt")
    if not core:
        raise RuntimeError("Performance certification requires the dbt oracle executable")
    observations = {engine: {phase: [] for phase in ["cold", "warm"]} for engine in ["dxt", "dbt"]}
    with tempfile.TemporaryDirectory(prefix="dxt-performance-") as temporary:
        project = Path(temporary)
        make_project(project, models)
        targets = {engine: project / f"target-{engine}" for engine in observations}
        for _ in range(repetitions):
            for engine, executable in [("dxt", str(binary)), ("dbt", core)]:
                target = targets[engine]
                shutil.rmtree(target, ignore_errors=True)
                arguments = [executable, "compile", "--project-dir", str(project), "--profiles-dir", str(project), "--target-path", str(target)]
                observations[engine]["cold"].append(invoke(arguments, project))
                observations[engine]["warm"].append(invoke(arguments, project))
            if compiled_sql(targets["dxt"], models) != compiled_sql(targets["dbt"], models):
                raise AssertionError("Native and Core compiled SQL differ in the performance fixture")
    medians = {engine: {phase: statistics.median(samples) for phase, samples in phases.items()} for engine, phases in observations.items()}
    return {
        "schema": "dxt/performance/v1",
        "dbt_core": "1.10.5",
        "dbt_duckdb": importlib.metadata.version("dbt-duckdb"),
        "models": models,
        "repetitions": repetitions,
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "includes_process_startup": True,
        "seconds": observations,
        "median_seconds": medians,
        "native_to_core_ratio": {phase: medians["dxt"][phase] / medians["dbt"][phase] for phase in ["cold", "warm"]},
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dxt", type=Path, default=ROOT / "zig-out/bin/dxt")
    parser.add_argument("--models", type=int, default=250)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--maximum-seconds", type=float, default=3.0)
    parser.add_argument("--maximum-ratio", type=float, default=1.0)
    parser.add_argument("--report", type=Path, default=ROOT / ".agent/runs/performance.json")
    args = parser.parse_args()
    if args.models <= 0 or args.repetitions < 2:
        parser.error("Use at least one model and two repetitions")
    report = measure(args.dxt.resolve(), args.models, args.repetitions)
    report["budgets"] = {"maximum_seconds": args.maximum_seconds, "maximum_ratio": args.maximum_ratio}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    for phase in ["cold", "warm"]:
        elapsed = report["median_seconds"]["dxt"][phase]
        ratio = report["native_to_core_ratio"][phase]
        print(f"{phase}: dxt {elapsed:.3f}s; Core {report['median_seconds']['dbt'][phase]:.3f}s; ratio {ratio:.3f}")
        if elapsed > args.maximum_seconds or ratio > args.maximum_ratio:
            raise SystemExit(f"{phase} compilation exceeded its performance budget")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

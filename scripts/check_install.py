"""Certify an extracted native binary with no CLI/Python subprocess fallback."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import duckdb

from validate_dbt_artifacts import assert_artifact

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dxt", type=Path, default=ROOT / "zig-out/bin/dxt")
    parser.add_argument("--version", default="0.0.0")
    args = parser.parse_args()
    library = os.environ.get("DXT_DUCKDB_LIBRARY")
    if not library or not Path(library).is_file():
        parser.error("Set DXT_DUCKDB_LIBRARY to the certified DuckDB native library")
    with tempfile.TemporaryDirectory(prefix="dxt-clean-install-") as temporary:
        install = Path(temporary)
        binary = install / "bin/dxt"
        binary.parent.mkdir()
        shutil.copy2(args.dxt.resolve(), binary)
        project = install / "project"
        for directory in ["models", "seeds", "macros"]:
            (project / directory).mkdir(parents=True)
        (project / "dbt_project.yml").write_text("name: clean_install\nversion: '1.0'\nprofile: clean_install\nmodels:\n  clean_install:\n    +materialized: table\n")
        (project / "profiles.yml").write_text(f"clean_install:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n      path: {project / 'warehouse.duckdb'}\n      schema: analytics\n      threads: 2\n")
        (project / "seeds/input.csv").write_text("id,label\n1,one\n2,two\n")
        (project / "models/output.sql").write_text("select * from {{ ref('input') }}")
        (project / "models/schema.yml").write_text("version: 2\nmodels:\n  - name: output\n    columns:\n      - name: id\n        tests: [not_null, unique]\n")
        environment = {**os.environ, "PATH": str(install / "no-subprocess-executables"), "DXT_DUCKDB_BACKEND": "native", "DXT_DUCKDB_LIBRARY": str(Path(library).resolve())}
        def invoke(arguments):
            result = subprocess.run([binary, *arguments], cwd=project, env=environment, capture_output=True, text=True, timeout=30)
            if result.returncode:
                raise RuntimeError(f"Extracted binary failed: {result.stdout}\n{result.stderr}")
            return result
        invoke(["--help"])
        if invoke(["version"]).stdout.strip() != args.version:
            raise AssertionError("Extracted binary version mismatch")
        for command in [["debug"], ["build"], ["docs", "generate", "--static"]]:
            invoke([*command, "--project-dir", str(project), "--profiles-dir", str(project)])
        for artifact in ["manifest.json", "run_results.json", "catalog.json"]:
            assert_artifact(project / "target" / artifact)
        rows = json.loads((project / "target/run_results.json").read_text())["results"]
        if not rows or any(row["status"] != "success" for row in rows):
            raise AssertionError("Extracted binary did not compile every selected resource")
        with duckdb.connect(str(project / "warehouse.duckdb"), read_only=True) as database:
            if database.execute("select * from analytics.output order by id").fetchall() != [(1, "one"), (2, "two")]:
                raise AssertionError("Extracted binary produced incorrect relation contents")
        if (project / "target/static_index.html").stat().st_size < 1_000_000:
            raise AssertionError("Extracted binary did not include the documentation application")
    print("Clean native installation passed without a runtime CLI or Python executable")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

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


def certify_adapter(install, binary, library, version, postgres_uri=None):
    adapter = "postgres" if postgres_uri else "duckdb"
    project = install / adapter
    schema = "install_" + install.name.rsplit("-", 1)[-1].replace("-", "_")
    for directory in ["models", "seeds", "macros"]:
        (project / directory).mkdir(parents=True)
    (project / "dbt_project.yml").write_text("name: clean_install\nversion: '1.0'\nprofile: clean_install\nmodels:\n  clean_install:\n    +materialized: table\n")
    output = {"type": adapter, "schema": schema, "threads": 2}
    if postgres_uri:
        import psycopg2
        output.update(psycopg2.extensions.parse_dsn(postgres_uri))
        if "port" in output:
            output["port"] = int(output["port"])
    else:
        output["path"] = str(project / "warehouse.duckdb")
    (project / "profiles.yml").write_text(json.dumps({"clean_install": {
        "target": "dev", "outputs": {"dev": output}}}))
    (project / "seeds/input.csv").write_text("id,label\n1,one\n2,two\n")
    (project / "models/output.sql").write_text("select * from {{ ref('input') }}")
    (project / "models/schema.yml").write_text("version: 2\nmodels:\n  - name: output\n    columns:\n      - name: id\n        tests: [not_null, unique]\n")
    environment = {**os.environ, "PATH": str(install / "no-subprocess-executables"),
                   "DXT_DUCKDB_BACKEND": "native", "DXT_DUCKDB_LIBRARY": str(Path(library).resolve())}

    def invoke(arguments):
        result = subprocess.run([binary, *arguments], cwd=project, env=environment,
                                capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise RuntimeError(f"Extracted {adapter} binary failed: {result.stdout}\n{result.stderr}")
        return result

    invoke(["--help"])
    if invoke(["version"]).stdout.strip() != version:
        raise AssertionError("Extracted binary version mismatch")
    for command in [["debug"], ["build"], ["docs", "generate", "--static"]]:
        invoke([*command, "--project-dir", str(project), "--profiles-dir", str(project)])
    for artifact in ["manifest.json", "run_results.json", "catalog.json"]:
        assert_artifact(project / "target" / artifact)
    rows = json.loads((project / "target/run_results.json").read_text())["results"]
    if not rows or any(row["status"] != "success" for row in rows):
        raise AssertionError("Extracted binary did not compile every selected resource")
    catalog = json.loads((project / "target/catalog.json").read_text())["nodes"]
    if set(catalog) != {"model.clean_install.output", "seed.clean_install.input"}:
        raise AssertionError("Extracted binary did not discover the actual warehouse catalog")
    database = (psycopg2.connect(postgres_uri) if postgres_uri else
                duckdb.connect(str(project / "warehouse.duckdb"), read_only=True))
    try:
        cursor = database.cursor()
        cursor.execute(f'select * from "{schema}"."output" order by id')
        if cursor.fetchall() != [(1, "one"), (2, "two")]:
            raise AssertionError("Extracted binary produced incorrect relation contents")
        if postgres_uri:
            cursor.execute(f'drop schema "{schema}" cascade')
            database.commit()
    finally:
        database.close()
    if (project / "target/static_index.html").stat().st_size < 1_000_000:
        raise AssertionError("Extracted binary did not include the documentation application")
    print(f"Clean native {adapter} installation passed without a runtime CLI or Python executable")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dxt", type=Path, default=ROOT / "zig-out/bin/dxt")
    parser.add_argument("--version", default="0.0.0")
    parser.add_argument("--postgres-uri", default=os.environ.get("DXT_INSTALL_POSTGRES_URI"),
                        help="Also certify an isolated PostgreSQL fixture supplied by the developer/CI")
    parser.add_argument("--require-postgres", action="store_true")
    args = parser.parse_args()
    library = os.environ.get("DXT_DUCKDB_LIBRARY")
    if not library or not Path(library).is_file():
        parser.error("Set DXT_DUCKDB_LIBRARY to the certified DuckDB native library")
    if args.require_postgres and not args.postgres_uri:
        parser.error("PostgreSQL installation certification requires its isolated fixture URI")
    with tempfile.TemporaryDirectory(prefix="dxt-clean-install-") as temporary:
        install = Path(temporary)
        binary = install / "bin/dxt"
        binary.parent.mkdir()
        shutil.copy2(args.dxt.resolve(), binary)
        certify_adapter(install, binary, library, args.version)
        if args.postgres_uri:
            certify_adapter(install, binary, library, args.version, args.postgres_uri)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

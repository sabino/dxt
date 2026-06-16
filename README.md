# dxt

`dxt` is **Data eXecution & Transformation**: a dbt-project-compatible transformation engine written in Zig.

The first target is dbt Core compatibility for public projects such as Jaffle Shop. The long-term architecture also accounts for semantic resources, metrics, Fusion-style static analysis, and efficient cross-database execution.

This repository is pre-alpha. It currently has a native Zig parser slice for a small dbt project subset, with broader dbt Core compatibility tracked in [PLAN.md](PLAN.md).

## Principles

- Artifact compatibility first.
- dbt Core project semantics before cloud-only or Fusion-only behavior.
- Zig product runtime only; Python is allowed for developer scripts, tests, and compatibility harnesses.
- Local deterministic fixtures before live warehouses.
- Adapter boundaries before adapter breadth.
- Public-safe development with no local paths, credentials, logs, or private data in committed files.

## Current CLI

Build and smoke-test the native CLI:

```sh
zig build
zig build test
zig build -Doptimize=ReleaseSafe
./zig-out/bin/dxt --help
./zig-out/bin/dxt version
```

Implemented pre-alpha commands:

```sh
./zig-out/bin/dxt parse --project-dir tests/fixtures/model_ref --target-path target-dxt
./zig-out/bin/dxt ls --project-dir tests/fixtures/model_ref
./zig-out/bin/dxt ls --project-dir tests/fixtures/model_ref --output json
```

`parse` and `ls` currently support only the documented M1 parser subset: `dbt_project.yml` name/model paths/seed paths/macro paths/target path, SQL model discovery, CSV seed discovery, installed package SQL model and CSV seed discovery from `dbt_packages`, source discovery, installed package source discovery, exposure discovery, installed package exposure discovery, project macro discovery, installed package macro discovery from `dbt_packages`, project and package docs block discovery, literal `ref` to models or seeds, two-argument package refs, package-local refs in installed package models and exposures, dbt-style fallback from unqualified refs to a unique installed-package model or seed, literal `source`, package-local sources in installed package models, dbt-style fallback from unqualified sources to a unique installed-package source, literal `doc` in descriptions, package-qualified and package-local macro dependencies, basic inline `config`, narrow project and package YAML model and macro properties, project and package model/seed `+docs.node_color`, root-project model config overrides for installed packages, simple columns, tags, materialization and disabled SQL models, dbt-shaped generic test nodes for `unique`, `not_null`, `accepted_values`, and `relationships`, model/test `refs` and `sources` artifact fields, deterministic partial `manifest.json`, and basic name/tag/path/package/resource/config materialization selectors with exact `package:`/`package:this`, comma intersections, whitespace unions, multi-argument selector lists, repeated selector flags, and graph expansion. `compile`, `build`, and `docs generate` remain planned placeholders.

## Development

Run tests from the repository root:

```sh
zig build
zig build test
pytest -q
python scripts/check_public_safety.py
python scripts/check_runtime_boundary.py
python scripts/validate_manifest_schema.py target/manifest.json
```

The product runtime requires Zig `0.16.0`. Python remains in this repository only for developer-side validation utilities, not for the `dxt` product runtime.

Use the test layers deliberately:

- `zig build` compiles the native CLI and should run after edits that affect product code or imports.
- `zig build test` runs fast native unit/regression tests for core Zig logic. Add these for parser helpers, selector matching and graph expansion, Jinja scanning, dependency resolution, manifest writer helpers, deterministic ordering, JSON escaping, and internal CLI option logic.
- `pytest -q` runs black-box integration and compatibility checks against the compiled Zig binary. It exists because dbt compatibility is fixture-heavy: tests copy synthetic dbt projects, invoke `dxt`, compare artifacts, validate schema slices, and can use dbt Core oracle behavior. Pytest should not implement product runtime behavior.
- `python scripts/check_runtime_boundary.py` verifies Python has not crossed into product runtime responsibilities.
- `python scripts/check_public_safety.py` scans for committed local paths, secrets, caches, logs, and private artifacts.

When a feature touches both core logic and user-visible CLI/artifact behavior, prefer both a Zig test for the core rule and a pytest integration/dbt-compatibility test for the end-to-end contract. Mechanical module extractions should pass `zig build test` after each step; run `pytest -q tests/test_cli.py` when CLI output, artifacts, fixtures, selectors, or manifest behavior are touched.

## Status

Pre-alpha. Do not use for production data transformations yet.

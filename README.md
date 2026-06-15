# dxt

`dxt` is **Data Transformation eXecutor**: a dbt-project-compatible transformation engine written in Zig.

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

`parse` and `ls` currently support only the documented M1 parser subset: `dbt_project.yml` name/model paths/seed paths/macro paths/target path, SQL model discovery, CSV seed discovery, source discovery, exposure discovery, project macro discovery, installed package macro discovery from `dbt_packages`, docs block discovery, literal `ref` to models or seeds, literal `source`, literal `doc` in descriptions, package-qualified macro dependencies, basic inline `config`, narrow YAML model and project macro properties, simple columns, tags, materialization and disabled SQL models, dbt-shaped generic test nodes for `unique`, `not_null`, `accepted_values`, and `relationships`, deterministic partial `manifest.json`, and basic name/tag/path/resource/config materialization selectors with comma intersections and graph expansion. `compile`, `build`, and `docs generate` remain planned placeholders.

## Development

Run tests from the repository root:

```sh
zig build
zig build test
pytest -q
python scripts/check_public_safety.py
python scripts/check_runtime_boundary.py
```

The product runtime requires Zig `0.16.0`. Python remains in this repository only for developer-side validation utilities, not for the `dxt` product runtime.

## Status

Pre-alpha. Do not use for production data transformations yet.

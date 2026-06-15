# dxt

`dxt` is the **Data Transformation eXecutor**: a planned dbt-project-compatible transformation engine written in Zig.

The first target is dbt Core compatibility for public projects such as Jaffle Shop. The long-term architecture also accounts for semantic resources, metrics, Fusion-style static analysis, and efficient cross-database execution.

This repository is at the planning and scaffolding stage. See [PLAN.md](PLAN.md) for the active execution plan.

## Principles

- Artifact compatibility first.
- dbt Core project semantics before cloud-only or Fusion-only behavior.
- Zig product runtime only; Python is allowed for developer scripts, tests, and compatibility harnesses.
- Local deterministic fixtures before live warehouses.
- Adapter boundaries before adapter breadth.
- Public-safe development with no local paths, credentials, logs, or private data in committed files.

## Current CLI

The current Zig CLI is a placeholder so future work has a stable command surface:

```sh
zig build
zig build test
zig build -Doptimize=ReleaseSafe
./zig-out/bin/dxt --help
./zig-out/bin/dxt version
```

Planned commands include `parse`, `ls`, `compile`, `build`, and `docs generate`.

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

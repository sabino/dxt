# dxt

`dxt` is the **Data Transformation eXecutor**: a planned dbt-project-compatible transformation engine.

The first target is dbt Core compatibility for public projects such as Jaffle Shop. The long-term architecture also accounts for semantic resources, metrics, Fusion-style static analysis, and efficient cross-database execution.

This repository is at the planning and scaffolding stage. See [PLAN.md](PLAN.md) for the active execution plan.

## Principles

- Artifact compatibility first.
- dbt Core project semantics before cloud-only or Fusion-only behavior.
- Local deterministic fixtures before live warehouses.
- Adapter boundaries before adapter breadth.
- Public-safe development with no local paths, credentials, logs, or private data in committed files.

## Current CLI

The current CLI is a placeholder so future work has a stable command surface:

```sh
python -m dxt --help
python -m dxt version
```

Planned commands include `parse`, `ls`, `compile`, `build`, and `docs generate`.

## Development

Run tests from the repository root:

```sh
PYTHONPATH=src pytest -q
```

## Status

Pre-alpha. Do not use for production data transformations yet.

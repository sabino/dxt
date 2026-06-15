# M1 Seed Ref Slice

## Scope

This slice adds read compatibility for CSV seeds in the native Zig parser. It is parser/artifact-only and does not execute or load seed data.

Implemented surface:

- `seed-paths` from `dbt_project.yml`, defaulting to `seeds`.
- Recursive `.csv` seed discovery under configured seed paths.
- Seed nodes with `seed.<package>.<name>` unique IDs.
- Duplicate seed-name diagnostics for basename collisions across recursive seed paths.
- Literal `ref()` resolution to active models first, then active seeds.
- Seed entries in manifest `nodes`, `parent_map`, `child_map`, and `dxt ls`.
- `dxt ls --resource-type seed`.

## Compatibility Notes

The slice exists to unblock public Jaffle Shop DuckDB parse read-compatibility, where staging models reference CSV seeds such as `raw_customers`, `raw_orders`, and `raw_payments`.

Seed execution, CSV type inference, catalog generation, and full dbt seed artifact fidelity remain later work. The partial manifest intentionally records only the fields needed by the current M1 graph and selector surface.

## Validation

Synthetic fixtures cover deterministic seed discovery, seed-aware `ref()` dependency resolution, parent/child maps, seed listing, and duplicate seed-name diagnostics. The public Jaffle Shop DuckDB clone is used as a non-committed manual gate and parses into a partial manifest with five model nodes and three seed nodes.

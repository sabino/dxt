# M3 DuckDB Seed Build Slice

This slice starts seed execution through `dxt build` without widening `dxt run`
or mixed-resource build scheduling.

## Scope

- `dxt build` only.
- DuckDB adapter only.
- Root-project CSV seed nodes only.
- Seed-only selections only. Mixed seed/model/test selections remain an explicit
  boundary until the runner can schedule all selected resource types together.
- Default comma-delimited, headered CSV loading through DuckDB.
- External `duckdb` CLI backend reused from the first SQL-model execution slice,
  wrapped by Zig product code.
- `manifest.json` and minimal dbt-shaped `run_results.json` v6 output.

## Upstream References

dbt Core v1:

- `core/dbt/parser/seeds.py::SeedParser`: seeds parse as nodes, keep
  `root_path`, and do not render with context.
- `core/dbt/artifacts/resources/v1/seed.py::SeedConfig` and `Seed`: seed
  materialization is `seed`; seeds are parsed resources, not SQL defaults.
- `core/dbt/context/providers.py::load_agate_table`: runtime seed loading
  resolves the seed file from project/package root and `original_file_path`.
- `core/dbt/task/seed.py::SeedRunner`: `compile()` returns the seed node
  unchanged; seed execution attaches an agate table result.
- `core/dbt/task/seed.py::SeedTask`: seed command selects only
  `NodeType.Seed`.
- `core/dbt/task/build.py::BuildTask.RUNNER_MAP`: build routes
  `NodeType.Seed` to `SeedRunner`.
- `core/dbt/artifacts/schemas/run/v5/run.py::process_run_result`: non-compiled
  resources emit `compiled`, `compiled_code`, and `relation_name` as null in
  run results.
- `schemas/dbt/run-results/v6.json`: required run-results fields and nullable
  compiled fields.

dbt Core v2 / Fusion:

- `crates/dbt-parser/src/resolve/resolve_seeds.rs`: seed resolution, duplicate
  handling, checksum/path metadata, config validation, relation components, and
  root path storage.
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/seeds/seed.sql`:
  default seed materialization flow.
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/seeds/helpers.sql`:
  default CSV table creation, reset, and row loading helpers.
- `crates/dbt-loader/src/dbt_macro_assets/dbt-duckdb/macros/seed.sql`:
  DuckDB fast seed row loading uses direct CSV file access.
- `crates/dbt-adapter/src/adapter/mod.rs::get_seed_file_path`: seed file path
  is `root_path + original_file_path`.
- `crates/dbt-schemas/src/schemas/run_results.rs::RunResultOutput`: nullable
  compiled fields in Fusion-compatible run results.

## dxt Ownership

- `src/project/duckdb.zig`: root-project seed file path rendering, DuckDB CSV
  load SQL, SQL string escaping, and CLI execution reuse.
- `src/project.zig`: seed-only `build` orchestration and mixed-selection
  boundary.
- `src/project/run_results.zig`: generic node result writer that keeps seed
  compiled fields null.
- `src/project/compiler.zig`: existing relation naming and quoting helpers for
  seed table names.
- `tests/schemas/dbt_run_results_v6_m3_slice.schema.json`: pinned v6 schema
  slice; nullable compiled fields already cover seeds.

## Validation

- Native Zig tests cover seed SQL rendering, SQL string escaping, and seed
  run-results null compiled fields.
- Pytest black-box coverage executes `dxt build --select raw_customers`,
  validates `run_results.json`, queries the DuckDB table, and verifies a stale
  view at the seed target relation is dropped before the seed table load.
- Pytest keeps mixed `+stg_customers` seed/model build selection unsupported
  before DuckDB side effects.

## Stop Conditions

- Do not add `dxt seed`.
- Do not make `dxt run` execute seeds.
- Do not execute package seeds until seed nodes store a package/root path.
- Do not execute mixed seed/model/test build DAGs in this slice.
- Do not implement seed configs such as custom delimiters, `quote_columns`,
  `column_types`, hooks, grants, docs persistence, full-refresh semantics, or
  adapter-specific materialization macro execution.
- Do not replace the external DuckDB CLI backend here.

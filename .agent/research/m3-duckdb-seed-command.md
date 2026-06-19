# M3 DuckDB Seed Command Slice

This slice adds the `dxt seed` command by reusing the existing Zig-owned
root-project DuckDB CSV seed execution boundary from `dxt build`.

## Scope

- `dxt seed` command dispatch and help.
- DuckDB adapter only.
- Selected seed resources only.
- Root-project CSV seed nodes only.
- Default comma-delimited, headered CSV loading through DuckDB.
- External `duckdb` CLI backend reused from the SQL-model and seed-build
  execution slices, wrapped by Zig product code.
- `manifest.json` and minimal dbt-shaped `run_results.json` v6 output.

## Upstream References

dbt Core v1:

- `core/dbt/parser/seeds.py::SeedParser`: seeds parse as nodes, keep
  `root_path`, and do not render with context.
- `core/dbt/artifacts/resources/v1/seed.py::SeedConfig` and `Seed`: seed
  materialization is `seed`; seeds are parsed resources.
- `core/dbt/context/providers.py::load_agate_table`: runtime seed loading
  resolves the seed file from project/package root and `original_file_path`.
- `core/dbt/task/seed.py::SeedRunner`: `compile()` returns the seed node
  unchanged.
- `core/dbt/task/seed.py::SeedTask`: seed command uses `ResourceTypeSelector`
  with `resource_types=[NodeType.Seed]`, filtering mixed selections to seed
  nodes.
- `core/dbt/task/build.py::BuildTask.RUNNER_MAP`: build routes seed nodes to
  the seed runner.
- `core/dbt/artifacts/schemas/run/v5/run.py::process_run_result` and
  `schemas/dbt/run-results/v6.json`: seed run results keep `compiled`,
  `compiled_code`, and `relation_name` null.

dbt Core v2 / Fusion:

- `crates/dbt-parser/src/resolve/resolve_seeds.rs`: seed resolution, duplicate
  handling, checksum/path metadata, config validation, relation components, and
  root path storage.
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/seeds/seed.sql`:
  default seed materialization flow.
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/seeds/helpers.sql`:
  default CSV table creation, reset, and row loading helpers.
- `crates/dbt-loader/src/dbt_macro_assets/dbt-duckdb/macros/seed.sql`: DuckDB
  fast seed row loading uses direct CSV file access.
- `crates/dbt-adapter/src/adapter/mod.rs::get_seed_file_path`: seed file path
  is derived from root path plus original file path.
- `crates/dbt-schemas/src/schemas/run_results.rs::RunResultOutput`: nullable
  compiled fields in Fusion-compatible run results.

## dxt Ownership

- `src/root.zig`: `dxt seed` dispatch, help, option parsing, and command errors.
- `src/project.zig`: selected seed command orchestration until runner
  extraction.
- `src/project/duckdb.zig`: root-project seed file path rendering, DuckDB CSV
  load SQL, SQL string escaping, and CLI execution reuse.
- `src/project/run_results.zig`: node result writer that keeps seed compiled
  fields null.
- `tests/schemas/dbt_run_results_v6_m3_slice.schema.json`: pinned v6 schema
  slice for current execution rows.

## Artifact Fields

- `manifest.json`: same graph and seed node shape as the existing parser/build
  slice.
- `run_results.json`: selected seed result rows with `compiled`,
  `compiled_code`, and `relation_name` set to null.

## Validation

- Native Zig CLI tests cover `dxt seed` help and selector-list option parsing.
- Pytest executes `dxt seed --select raw_customers`, validates
  `manifest.json` and `run_results.json`, and queries the loaded DuckDB table.
- Pytest verifies mixed seed/model selections execute only selected seeds.
- Pytest verifies selections that match no seeds are rejected before
  `dxt.duckdb` or `run_results.json` are created.
- Runtime-boundary and public-safety scans keep Python as test/harness code
  only.

## Stop Conditions

- Do not make `dxt run` execute seeds.
- Do not execute package seeds until seed nodes store a package/root path.
- Do not change mixed `dxt build` DAG scheduling in this command slice.
- Do not implement seed configs such as custom delimiters, `quote_columns`,
  `column_types`, hooks, grants, docs persistence, full-refresh semantics, or
  adapter-specific materialization macro execution.
- Do not replace the external DuckDB CLI backend here.

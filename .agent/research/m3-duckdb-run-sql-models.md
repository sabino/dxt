# M3 DuckDB SQL Model Run Slice

This slice starts real execution without broadening the runtime surface beyond a
small, source-grounded DuckDB path.

## Scope

- `dxt run` only.
- DuckDB adapter only.
- Enabled SQL model nodes only.
- `table` and `view` materializations only.
- Sequential execution only.
- External `duckdb` CLI backend for this first execution slice, wrapped by Zig
  product code so it can be replaced by an embedded `libduckdb` backend later.
- Local DuckDB database file paths only. Relative profile paths resolve from
  the loaded `profiles.yml` directory. `:memory:` and MotherDuck connection
  strings are rejected until the adapter backend can preserve a connection
  across nodes and initialize extensions/tokens correctly.
- `manifest.json`, compiled SQL files, and a minimal dbt-shaped
  `run_results.json` v6 slice.

## Upstream References

dbt Core v1:

- `schemas/dbt/run-results/v6.json`: top-level `metadata`, `results`,
  `elapsed_time`; per-result `status`, `timing`, `thread_id`,
  `execution_time`, `adapter_response`, `message`, `failures`, `unique_id`,
  `compiled`, `compiled_code`, and `relation_name`.
- `core/dbt/artifacts/schemas/run/v5/run.py::RunResultOutput` and
  `process_run_result`: maps executed compiled nodes into run-result fields.
- `core/dbt/compilation.py::Compiler.compile_node` and `write_graph_file`:
  compiled SQL is attached to the node and written before execution artifacts.

dbt Core v2 / Fusion:

- `crates/dbt-schemas/src/schemas/run_results.rs::RunResultOutput` and
  `RunResultsArtifact`: Rust run-results shape and relation-name propagation.
- `crates/dbt-tasks-core/src/stats_to_results.rs`: status, compile/execute
  timing, thread ID, execution time, adapter response, failures, and unique ID
  mapping from task stats.
- `crates/dbt-tasks-core/src/utils.rs::build_run_results_artifact`: v6
  metadata and results artifact assembly.
- `crates/dbt-auth/src/duckdb/mod.rs::DuckDbAuth.configure`: DuckDB profile
  `path` is the database file option.
- `crates/dbt-loader/src/dbt_macro_assets/dbt-duckdb/macros/adapters.sql`
  `duckdb__create_table_as` and `duckdb__create_view_as`: SQL primitives use
  `create table ... as (...)` and `create view ... as (...)`.
- `crates/dbt-loader/src/dbt_macro_assets/dbt-duckdb/macros/materializations/table.sql`
  and `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/models/view.sql`:
  full dbt table/view materializations stage through intermediate and backup
  relations. dxt intentionally stops short of that full parity in this slice.

## dxt Ownership

- `src/project/duckdb.zig`: DuckDB CLI-backed database path resolution,
  local-file path guardrails, table/view materialization SQL rendering, and
  execution.
- `src/project/run_results.zig`: minimal v6 `run_results.json` rendering for
  successful SQL model runs.
- `src/project/profile.zig`: narrow scalar DuckDB `path` capture.
- `src/project.zig`: current command facade orchestration for `run`.
- `tests/schemas/dbt_run_results_v6_m3_slice.schema.json`: pinned schema slice
  for the emitted run-results fields.

## Validation

- Native Zig tests cover DuckDB materialization SQL rendering, unsupported
  materialization rejection, DuckDB profile `path` capture, and run-results JSON
  shape.
- Pytest black-box coverage executes `dxt run` against copied and generated
  fixtures, verifies dependency-order execution where lexical order conflicts
  with graph order, checks profile-relative DuckDB paths, queries the resulting
  DuckDB database through the DuckDB CLI, validates `run_results.json` against
  the pinned schema slice, and keeps non-model, non-DuckDB,
  unsupported-materialization, and `build` boundaries explicit.

## Stop Conditions

- Do not implement `dxt build` execution in this slice.
- Do not implement seeds, tests, snapshots, incremental, ephemeral, Python
  models, hooks, grants, docs persistence, catalog introspection, relation
  staging/backup rename semantics, adapter caching, or threaded scheduling.
- Do not call DuckDB from Python product code. Python remains a black-box test
  harness only.
- Do not treat the external CLI backend as the long-term adapter ABI; replace it
  with embedded `libduckdb` when adapter packaging work starts.

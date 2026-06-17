# M3 DuckDB Generic Test Execution Slice

This slice implements the first executable generic-test boundary for `dxt build`
while keeping product runtime behavior in Zig.

## Scope

- Execute test-only `dxt build` selections when every selected resource is a
  generic test.
- Support DuckDB only.
- Support only column-level `not_null` and `unique` generic tests.
- Render the supported built-in SQL directly from the parsed `GenericTestNode`
  and its attached relation. Do not execute dbt macros in this slice.
- Write dbt Run Results v6-shaped `run_results.json` with test statuses
  `pass` or `fail`, integer `failures`, `compiled: true`, and the compiled
  failure-row SQL as `compiled_code`.
- Return exit code `1` when any selected generic test fails.

## Upstream References

dbt Core v1 / Python:

- `core/dbt/task/build.py::BuildTask.RUNNER_MAP` maps `NodeType.Test` to
  `TestRunner` during `dbt build`.
- `core/dbt/task/test.py::TestRunner.execute_data_test` runs the test
  materialization and expects one result row with `failures`, `should_warn`, and
  `should_error`.
- `core/dbt/task/test.py::TestRunner.build_test_run_result` maps the result row
  into `pass`, `fail`, or `warn`, and records `failures`.
- `core/dbt/artifacts/resources/v1/generic_test.py::GenericTest` models generic
  tests as compiled test resources with `column_name`, `attached_node`, and
  `test_metadata`.
- `core/dbt/artifacts/schemas/run/v5/run.py::process_run_result` serializes
  compiled resources into run-results `compiled`, `compiled_code`, and
  `relation_name` fields.
- `schemas/dbt/run-results/v6.json` defines the artifact contract.

dbt Core v2 / Fusion:

- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/tests/generic/builtin.sql`
  defines built-in generic test wrappers for `unique`, `not_null`,
  `accepted_values`, and `relationships`.
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/generic_test_sql/not_null.sql`
  renders failing rows where the column is null.
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/generic_test_sql/unique.sql`
  renders duplicate non-null groups as failing rows.
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/tests/test.sql`
  runs data tests through the test materialization.
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/tests/helpers.sql`
  wraps failing-row SQL with `failures`, `should_warn`, and `should_error`.
- `crates/dbt-schemas/src/schemas/run_results.rs::ContextRunResult` records
  status, message, failures, unique id, compiled fields, and relation fields.
- `crates/dbt-tasks-core/src/test_aggregation.rs` is a Fusion optimization
  reference for eligible `not_null` and `unique` tests, but this slice does not
  implement aggregation.

## dxt Ownership

- `src/project.zig` owns the current test-only `build` branch until a runner
  module exists.
- `src/project/duckdb.zig` owns direct DuckDB rendering/execution for
  `not_null` and `unique` generic tests.
- `src/project/run_results.zig` owns the minimal v6 run-results writer for
  model, seed, and generic-test results.
- `src/root.zig` owns the CLI exit-code mapping for failed tests.
- `tests/test_cli.py` owns black-box native-binary pass/fail coverage.

## Validation

- Native Zig tests cover generic-test SQL rendering and run-results test result
  serialization.
- Python integration tests first run a model into DuckDB, then execute selected
  generic tests against the same target database and validate
  `run_results.json` against the local Run Results v6 schema slice.
- The failure fixture verifies non-zero test failure exit behavior and persisted
  failure counts.

## Stop Conditions

- Do not add mixed build DAG scheduling.
- Do not execute arbitrary macros or adapter dispatch.
- Do not implement `accepted_values`, `relationships`, custom generic tests,
  singular tests, unit tests, source tests, `where`, `limit`, `severity`,
  `warn_if`, `error_if`, or `store_failures`.
- Do not implement package test runtime behavior beyond graph-selected nodes
  whose attached relation already exists.
- Do not add Python product runtime behavior.

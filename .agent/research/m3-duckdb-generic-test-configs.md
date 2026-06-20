# M3 DuckDB Generic Test Configs

## Slice

This slice extends the already-supported built-in DuckDB generic-test execution
path for model, seed, and source tests with the first dbt-compatible config
surface:

- `where`
- `limit`
- `severity`
- `warn_if`
- `error_if`

The product runtime behavior stays in Zig. Python coverage is limited to
black-box CLI, artifact, fixture, and dbt-oracle checks.

## Upstream References

dbt Core v1:

- `core/dbt/parser/schema_generic_tests.py::SchemaGenericTestParser`
- `core/dbt/parser/generic_test_builders.py::TestBuilder`
- `core/dbt/task/test.py::TestRunner.execute_data_test`
- `core/dbt/task/test.py::TestRunner.build_test_run_result`
- `core/dbt/artifacts/resources/v1/generic_test.py::GenericTest`
- `schemas/dbt/manifest/v12.json`
- `schemas/dbt/run-results/v6.json`

Fusion / dbt Core v2:

- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/tests/helpers.sql`
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/generic_test_sql/not_null.sql`
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/generic_test_sql/unique.sql`
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/generic_test_sql/accepted_values.sql`
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/generic_test_sql/relationships.sql`
- `crates/dbt-schemas/src/schemas/run_results.rs::ContextRunResult`

## dxt Ownership

- `src/project/types.zig` stores the parsed generic-test config on
  `GenericTestDef` and materialized `GenericTestNode`.
- `src/project/parse.zig` parses supported source generic-test config scalars.
- `src/project.zig` parses model/seed generic-test config scalars, classifies
  pass/warn/fail behavior from failure counts, and preserves warning exit-code
  behavior.
- `src/project/compiler.zig` applies `where` and `limit` to the supported
  built-in failure-row SQL.
- `src/project/manifest.zig` emits the supported config fields in test nodes.
- `src/project/run_results.zig` continues to serialize dbt-shaped statuses,
  messages, failures, and compiled SQL for test results.

## Boundaries

- No `store_failures` relation materialization.
- No custom generic-test macro execution.
- No adapter-dispatched generic-test overrides.
- No unit-test execution.
- No full indirect-selection parity.
- Threshold expressions are limited to simple integer comparisons against the
  current failure count, such as `> 0`, `>= 1`, `= 0`, and `!= 0`.

## Validation

- Native Zig tests cover config parsing, manifest emission, SQL rendering, and
  threshold classification.
- Focused CLI pytest covers manifest config fields for model, seed, and source
  tests plus `dxt test` / `dxt build` pass, warn, fail, `where`, and `limit`
  behavior.
- A local dbt Core 1.10 DuckDB oracle check was used to confirm manifest config
  field shape and warn/fail run-result status/message behavior for the same
  synthetic fixture shape.

# M3 DuckDB Relationships Generic Test Slice

## Scope

This slice extends the DuckDB generic-test execution path to the built-in
column-level `relationships` generic test when the test is ref-backed and both
`to` and `field` arguments were parsed.

The product runtime remains Zig. Python coverage is limited to black-box CLI,
artifact, and fixture integration tests.

## Upstream References

dbt Core v1:

- `core/dbt/parser/schema_generic_tests.py::SchemaGenericTestParser.parse_generic_test`
- `core/dbt/parser/schema_generic_tests.py::render_test_update`
- `core/dbt/artifacts/resources/v1/generic_test.py::GenericTest`
- `core/dbt/artifacts/resources/v1/generic_test.py::TestMetadata`
- `core/dbt/task/build.py::BuildTask.RUNNER_MAP`
- `core/dbt/task/test.py::TestRunner.execute_data_test`
- `core/dbt/task/test.py::TestRunner.build_test_run_result`
- `schemas/dbt/run-results/v6.json`

dbt Core v2 / Fusion:

- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/tests/generic/builtin.sql`
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/generic_test_sql/relationships.sql`
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/tests/test.sql`
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/tests/helpers.sql`
- `crates/dbt-schemas/src/schemas/run_results.rs`

## dxt Ownership

- `src/project.zig` owns the selected-test execution preflight until a runner
  module exists.
- `src/project/duckdb.zig` owns the direct DuckDB rendering and execution for
  built-in generic tests in this M3 CLI-backed adapter slice.
- `src/project/run_results.zig` owns the generic-test `pass`/`fail`
  run-results serialization.

## Behavior

- Accept selected DuckDB column-level `relationships` tests only when
  `column_name`, `to`, and `field` are present.
- Use the already-parsed relationship `ref()` dependency to identify the parent
  relation. Self-relationships fall back to the attached node relation.
- Render the dbt built-in failure-row SQL shape directly in Zig:
  select non-null child values, select parent field values, left join, and
  return child values with no parent match.
- Preserve dbt's null behavior for this built-in SQL shape: null child values do
  not fail `relationships`; users combine `relationships` with `not_null` when
  nulls must fail.
- Reuse the existing standard test materialization wrapper that returns
  `failures`, `should_warn`, and `should_error`.
- Reuse the existing run-results behavior: zero failures is `pass`, nonzero
  failures is `fail`, and any failed selected generic test exits with code `1`.

## Validation

- Native Zig coverage for relationship SQL rendering and unsupported missing
  relationship target/field shapes.
- Python CLI coverage for test-only, model+test, and seed+model+test build
  paths through the compiled Zig binary and DuckDB CLI backend.
- Run-results schema-slice validation remains unchanged.

## Stop Conditions

- Do not implement generic-test macro execution, adapter dispatch, or macro
  overrides.
- Do not implement singular tests, unit tests, source tests, custom test
  configs, `where`, `limit`, `severity`, `warn_if`, `error_if`,
  `store_failures`, or warning status behavior.
- Do not change selector semantics, indirect selection, queue interleaving,
  skip/fail-fast behavior, threading, or partial failure artifacts.
- Do not add Python product runtime behavior.
- Treat non-ref relationship targets and source relationship tests as future
  parser/runtime work.

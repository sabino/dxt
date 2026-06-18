# M3 DuckDB Accepted Values Generic Test Slice

## Scope

This slice extends the existing DuckDB generic-test execution path from
`not_null` and `unique` to the built-in column-level `accepted_values` generic
test when parsed `values` are present.

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
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/generic_test_sql/accepted_values.sql`
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/tests/test.sql`
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/tests/helpers.sql`
- `crates/dbt-schemas/src/schemas/run_results.rs`

## dxt Ownership

- `src/project.zig` owns the current selected-test execution preflight until a
  runner module exists.
- `src/project/duckdb.zig` owns the direct DuckDB rendering and execution for
  built-in generic tests in this M3 CLI-backed adapter slice.
- `src/project/run_results.zig` owns the generic-test `pass`/`fail`
  run-results serialization.

## Behavior

- Accept selected DuckDB column-level `accepted_values` tests only when
  `column_name` is present and the parsed value list is non-empty.
- Render the dbt built-in failure-row query shape directly in Zig:
  group observed values first, then return grouped values not in the accepted
  literal list.
- Preserve dbt's default null behavior for this built-in SQL shape: null values
  do not fail `accepted_values`; users combine `accepted_values` with
  `not_null` when nulls must fail.
- Escape SQL string literals for accepted values.
- Reuse the existing standard test materialization wrapper that returns
  `failures`, `should_warn`, and `should_error`.
- Reuse the existing run-results behavior: zero failures is `pass`, nonzero
  failures is `fail`, and any failed selected generic test exits with code `1`.

## Validation

- Native Zig coverage for accepted-values SQL rendering, SQL literal escaping,
  and unsupported empty/table-level shapes.
- Python CLI coverage for test-only, model+test, and seed+model+test build
  paths through the compiled Zig binary and DuckDB CLI backend.
- Run-results schema-slice validation remains unchanged.

## Stop Conditions

- Do not implement `relationships`, singular tests, unit tests, source tests, or
  package-provided/custom generic tests.
- Do not implement generic-test macro execution, adapter dispatch, or macro
  overrides.
- Do not implement `where`, `limit`, `severity`, `warn_if`, `error_if`,
  `store_failures`, custom test configs, or warning status behavior.
- Do not change selector semantics, indirect selection, queue interleaving,
  skip/fail-fast behavior, threading, or partial failure artifacts.
- Do not add Python product runtime behavior.
- Explicit `quote: false` parser, artifact, and execution behavior is covered
  by `.agent/research/m3-duckdb-accepted-values-quote-false.md`; this original
  slice established the default quoted values path.

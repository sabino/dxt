# M3 DuckDB Accepted Values Quote False Slice

## Scope

This slice extends the supported built-in `accepted_values` generic-test path
to preserve explicit `quote: false` metadata and execute raw accepted-value
SQL literals for model and source column tests.

The product runtime remains Zig. Python coverage is limited to black-box CLI,
artifact, fixture, and schema validation tests.

## Upstream References

dbt Core v1:

- `core/dbt/parser/generic_test_builders.py::TestBuilder.extract_test_args`
- `core/dbt/parser/generic_test_builders.py::get_synthetic_test_names`
- `core/dbt/parser/schema_generic_tests.py::SchemaGenericTestParser.create_test_node`
- `core/dbt/parser/schema_generic_tests.py::get_hashable_md`
- `core/dbt/artifacts/resources/v1/generic_test.py::TestMetadata`
- `core/dbt/task/test.py::TestRunner.execute_data_test`
- `core/dbt/task/test.py::TestRunner.build_test_run_result`

dbt Core v2 / Fusion:

- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/generic_test_sql/accepted_values.sql`
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/tests/test.sql`
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/tests/helpers.sql`
- `crates/dbt-schemas/src/schemas/run_results.rs`

## dxt Ownership

- `src/project.zig` owns current model property parsing and generic-test
  materialization until parser/runner extraction moves those pieces behind
  focused internal modules.
- `src/project/parse.zig` owns source YAML parsing plus generic-test synthetic
  names and dbt-style hash identities.
- `src/project/types.zig` owns the parsed and materialized generic-test
  `accepted_values_quote` metadata.
- `src/project/manifest.zig` owns `test_metadata.kwargs.quote` serialization.
- `src/project/duckdb.zig` owns direct DuckDB SQL rendering/execution.
- `tests/test_cli.py` owns black-box native-binary coverage.

## Behavior

- Preserve dbt's default behavior when `quote` is omitted: accepted values are
  SQL string literals.
- Preserve explicit `quote: true` / `quote: false` as boolean metadata in
  Manifest `test_metadata.kwargs`.
- Include explicit `True` / `False` in synthetic accepted-values test names,
  matching dbt's non-`model` kwargs naming behavior.
- Hash explicit quote metadata using dbt's stringified scalar metadata shape,
  such as `'quote': 'False'`.
- Render raw accepted values for DuckDB execution when `quote: false`.

Current accepted-value manifest entries still store parsed values as strings in
the local schema slice. Native typed scalar value parity is a future artifact
compatibility slice.

## Validation

- Native Zig parser coverage for model/source YAML `quote: false` parsing.
- Native Zig identity coverage for dbt-style synthetic names and hash suffixes.
- Native Zig DuckDB SQL rendering coverage for raw accepted values.
- Python CLI coverage for passing and failing model-attached tests plus passing
  source column tests through the native binary and DuckDB CLI backend.
- Manifest and Run Results schema-slice validation remains part of the CLI
  integration coverage.

## Stop Conditions

- Do not implement arbitrary generic-test macro execution or adapter overrides.
- Do not implement custom test configs, `where`, `limit`, `severity`,
  `warn_if`, `error_if`, `store_failures`, or warning status behavior.
- Do not implement typed scalar manifest values in this slice.
- Do not add table-level source tests, source relationship tests, singular
  tests, seed-attached column tests, unit-test execution, or full dbt queue
  parity.
- Do not add Python product runtime behavior.

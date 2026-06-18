# M3 DuckDB Source Relationships Generic Test Slice

This slice extends the existing source-backed generic-test execution path to
ref-backed `relationships` tests while keeping product runtime behavior in Zig.

## Scope

- Parse source table column `relationships` tests with literal `to: ref(...)`
  and `field` arguments.
- Materialize source-style generic test nodes with a `source_relationships_`
  synthetic name, `attached_node: null`, source dependencies, and target model
  or seed refs.
- Execute selected source+test DuckDB builds for source column relationships
  against an already-existing source relation and already-built target relation.
- Write Manifest v12-shaped test metadata and Run Results v6-shaped pass/fail
  rows through the existing artifact writers.

The product runtime remains Zig. Python coverage in this slice is black-box
CLI, fixture, and artifact-schema validation only.

## Upstream References

dbt Core v1 references:

- `core/dbt/parser/sources.py::SourcePatcher.construct_sources`
- `core/dbt/parser/sources.py::SourcePatcher.get_source_tests`
- `core/dbt/parser/sources.py::SourcePatcher.parse_source_test`
- `core/dbt/parser/schema_generic_tests.py::SchemaGenericTestParser`
- `core/dbt/parser/generic_test_builders.py::TestBuilder.get_synthetic_test_names`
- `core/dbt/parser/generic_test_builders.py::TestBuilder.build_model_str`
- `core/dbt/artifacts/resources/v1/generic_test.py::GenericTest`
- `core/dbt/artifacts/resources/v1/generic_test.py::TestMetadata`
- `core/dbt/task/build.py::BuildTask.RUNNER_MAP`
- `core/dbt/task/test.py::TestRunner.execute_data_test`
- `core/dbt/task/test.py::TestRunner.build_test_run_result`
- `schemas/dbt/manifest/v12.json`
- `schemas/dbt/run-results/v6.json`

Fusion references:

- `crates/dbt-parser/src/resolve/resolve_sources.rs::resolve_sources`
- `crates/dbt-parser/src/resolve/resolve_tests/persist_generic_data_tests.rs::TestableTable`
- `crates/dbt-parser/src/resolve/resolve_tests/resolve_data_tests.rs`
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/generic_test_sql/relationships.sql`
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/tests/test.sql`
- `crates/dbt-schemas/src/schemas/run_results.rs`

## dxt Owners

- `src/project/parse.zig` parses source column relationship arguments.
- `src/project.zig` materializes supported source relationship test nodes,
  records the target `ref`, and keeps source+test build orchestration until a
  runner module exists.
- `src/project/duckdb.zig` renders the dbt built-in relationship failure-row
  SQL against the source relation and referenced target relation.
- `src/project/manifest.zig` serializes `attached_node: null`, source
  dependencies, refs, and `test_metadata.kwargs`.
- `src/project/run_results.zig` serializes pass/fail rows for the selected
  source relationship test.
- `tests/test_cli.py` validates the native binary with synthetic DuckDB source
  and model relations.

## Behavior

- Source relationships use source-style names such as
  `source_relationships_raw_orders_customer_id__customer_id__ref_customers_`.
- `attached_node` remains `null`, matching source generic-test behavior.
- `test_metadata.kwargs.model` uses
  `{{ get_where_subquery(source('raw', 'orders')) }}`.
- `test_metadata.kwargs.to` keeps the literal `ref('customers')` argument and
  `field` keeps the target column.
- `refs` contains the referenced target relation.
- `sources` contains the logical source/table pair.
- `depends_on.nodes` includes the source unique ID first, then the target node,
  matching dbt's source-before-ref processing order.
- DuckDB execution uses the source physical relation as the child side and the
  referenced model or seed relation as the parent side, ignoring null child
  values in the dbt built-in relationships shape.

## Stop Conditions

- Source relationship `to` must be a simple `ref(...)` target.
- The source relation and referenced target relation must already exist or be
  selected/built by a prior command in the supported workflow.
- Do not implement source-to-source relationship targets.
- Do not implement table-level source tests.
- Do not execute arbitrary test macros or adapter dispatch.
- Do not add singular tests, unit tests, custom generic tests, custom configs,
  `where`, `limit`, `severity`, `warn_if`, `error_if`, `store_failures`, or
  native typed accepted-value manifest scalars.
- Do not add Python product runtime behavior.

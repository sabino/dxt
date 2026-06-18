# M3 DuckDB Source Column Generic Test Slice

This slice adds the first source-backed generic-test execution path for
`dxt build` while keeping product runtime behavior in Zig.

## Scope

- Parse source table `columns:` entries with column-level `tests` /
  `data_tests` entries.
- Materialize dbt-shaped generic test nodes for supported source column tests.
- Support DuckDB direct SQL execution for source column `not_null`, `unique`,
  default-quoted or explicit `quote: false` `accepted_values`, and ref-backed
  `relationships` tests. Source relationships were added by the follow-up slice
  documented in `.agent/research/m3-duckdb-source-relationships-generic-tests.md`.
- Let selected source+test build selections, such as
  `--select source:raw.customers+`, execute source column tests against
  already-existing DuckDB source tables.
- Emit manifest test nodes with source-style `test_metadata.kwargs.model`
  using `source('source_name', 'table_name')`, `sources` dependency fields, and
  `attached_node: null` to match the dbt/Fusion source-test boundary.

## Upstream References

dbt Core v1 / Python:

- `core/dbt/parser/sources.py::SourcePatcher.construct_sources` patches source
  definitions and extracts source tests before converting to
  `SourceDefinition`.
- `core/dbt/parser/sources.py::SourcePatcher.get_source_tests` iterates
  `target.get_tests()` for source table and column tests.
- `core/dbt/parser/sources.py::SourcePatcher.parse_source_test` delegates each
  source test to `SchemaGenericTestParser`.
- `core/dbt/parser/schema_generic_tests.py::SchemaGenericTestParser.parse_generic_test`
  creates source generic test nodes and records source dependencies for the
  built-in `not_null` / `unique` fast path.
- `core/dbt/parser/schema_generic_tests.py::SchemaGenericTestParser._lookup_attached_node`
  intentionally skips `attached_node` for `UnpatchedSourceDefinition` targets.
- `core/dbt/parser/generic_test_builders.py::TestBuilder.get_synthetic_test_names`
  prefixes source test names with `source_`.
- `core/dbt/parser/generic_test_builders.py::TestBuilder.build_model_str`
  renders source generic-test `model` kwargs as
  `{{ get_where_subquery(source('source_name', 'table_name')) }}`.
- `core/dbt/task/build.py::BuildTask.RUNNER_MAP` and
  `core/dbt/task/test.py::TestRunner.execute_data_test` define `dbt build`
  execution of selected generic tests.

dbt Core v2 / Fusion:

- `crates/dbt-parser/src/resolve/resolve_sources.rs::resolve_sources` wraps
  enabled source tables in `TestableTable` and persists generic tests into the
  collected test list.
- `crates/dbt-parser/src/resolve/resolve_tests/persist_generic_data_tests.rs::TestableTable`
  exposes table-level and column-level source tests.
- `crates/dbt-parser/src/resolve/resolve_tests/persist_generic_data_tests.rs`
  synthesizes source test identifiers with a `source_` prefix and
  source/resource naming.
- `crates/dbt-parser/src/resolve/resolve_tests/resolve_data_tests.rs` matches
  dbt Core by leaving `attached_node` unset for source tests.
- Fusion built-in generic-test SQL macro assets for `not_null`, `unique`,
  `accepted_values`, and `relationships` remain the SQL behavior reference.

## dxt Ownership

- `src/project/parse.zig` owns source YAML table and column parsing for this
  slice.
- `src/project/types.zig` owns source column/test data and optional generic-test
  `attached_node` shape.
- `src/project.zig` owns generic-test materialization and the current `build`
  orchestration branch until a runner module exists.
- `src/project/duckdb.zig` owns direct DuckDB source-relation SQL rendering.
- `src/project/manifest.zig` owns manifest source-test JSON fields.
- `src/project/selector.zig` owns graph expansion from selected source nodes to
  dependent source tests.
- `tests/test_cli.py` owns black-box native-binary execution coverage.

## Artifact Fields

This slice affects `manifest.json` node entries for source generic tests:

- source entries under `sources` now include parsed source table `columns`
- `resource_type: "test"`
- `attached_node: null`
- `column_name`
- `test_metadata.name`
- `test_metadata.kwargs.model` using `source(...)`
- `test_metadata.kwargs.column_name`
- optional `test_metadata.kwargs.values`
- optional `test_metadata.kwargs.to` and `test_metadata.kwargs.field` for
  relationships
- `depends_on.nodes` including the source unique id
- `depends_on.macros` including `macro.dbt.test_<name>` and
  `macro.dbt.get_where_subquery` for `accepted_values` and `relationships`
- `refs` containing the target ref for source relationships
- `sources: [[source_name, table_name]]`

It also writes existing Run Results v6-shaped test rows for executed tests.

## Validation

Native Zig coverage:

- Source YAML parser records source columns and column tests.
- Manifest writer emits source generic tests with `attached_node: null` and
  `source(...)` model kwargs.
- DuckDB SQL renderer targets the quoted source relation for source column
  `not_null`, `unique`, `accepted_values`, and `relationships`.

Python integration coverage:

- A synthetic DuckDB source table selected with `source:<source>.<table>+`
  executes source column generic tests through the native `dxt` binary.
- The emitted `manifest.json` and `run_results.json` contain the expected
  source-test identity and pass/fail rows.

## Stop Conditions

- Do not implement table-level source tests in this slice.
- Do not implement source-to-source relationship targets in this slice.
- Do not execute arbitrary test macros or adapter dispatch.
- Do not add singular tests, unit tests, custom generic tests, custom configs,
  `where`, `limit`, `severity`, `warn_if`, `error_if`, `store_failures`, or
  native typed accepted-value manifest scalars.
- Do not add Python product runtime behavior.

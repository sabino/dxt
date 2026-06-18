# M3 DuckDB Table-Level Generic Test Column Name Slice

This slice extends the supported built-in generic-test path to table-level
`data_tests` / `tests` entries that provide an explicit `column_name`
argument. It keeps the product runtime in Zig and uses Python only for
black-box native-binary integration coverage.

## Scope

- Parse table-level model, seed, and source generic tests with
  `arguments.column_name`.
- Materialize supported built-in `not_null`, `unique`, `accepted_values`, and
  ref-backed `relationships` tests only when an effective column name exists.
- Execute selected DuckDB model, seed, and source table-level tests through the
  existing direct SQL renderer.
- Preserve existing column-level generic-test behavior and dbt-style names,
  unique IDs, manifest kwargs, dependencies, and run-results rows.

## Upstream References

dbt Core v1 / Python:

- `core/dbt/parser/generic_test_builders.py::TestBuilder.__init__` stores the
  parser-provided column name and builds the test `model` kwarg.
- `core/dbt/parser/generic_test_builders.py::TestBuilder.extract_test_args`
  injects the column-level parser column name when present, keeps explicit
  `column_name` as a top-level generic-test argument, and merges nested
  `arguments` into test kwargs.
- `core/dbt/parser/generic_test_builders.py::TestBuilder.build_raw_code`
  emits the raw generic-test macro invocation.
- `core/dbt/parser/schemas.py::TestablePatchParser` covers seed and snapshot
  schema patches; model parsing follows the same `NodePatchParser` generic-test
  path.
- Source generic-test behavior remains grounded in
  `core/dbt/parser/sources.py::SourcePatcher.get_source_tests` and
  `parse_source_test`, which include source table and column tests.
- `core/dbt/task/build.py::BuildTask.RUNNER_MAP` and
  `core/dbt/task/test.py::TestRunner.execute_data_test` define `dbt build`
  execution of selected generic tests.

dbt Core v2 / Fusion:

- `crates/dbt-schemas/src/schemas/data_tests.rs::CustomTestInner` and
  `CustomTestMultiKey` expose `column_name` on generic data tests.
- `crates/dbt-schemas/src/schemas/data_tests.rs::DataTests::column_name`
  extracts table-level generic-test column names.
- `crates/dbt-schemas/src/schemas/properties/source_properties.rs::Tables`
  carries table-level `data_tests` / `tests`.
- `crates/dbt-parser/src/resolve/resolve_tests/persist_generic_data_tests.rs`
  persists generic data tests for testable model/seed/source tables.
- Fusion built-in generic-test SQL macro assets for `not_null`, `unique`,
  `accepted_values`, and `relationships` remain the SQL behavior reference.

## dxt Ownership

- `src/project/types.zig` owns `GenericTestDef.column_name`.
- `src/project.zig` owns model/seed property table-level generic-test parsing,
  materialization, and current build orchestration until those move behind
  focused parser and runner modules.
- `src/project/parse.zig` owns source table-level generic-test parsing and
  generic-test identity/hash helpers.
- `src/project/duckdb.zig` owns direct DuckDB SQL rendering and execution.
- `src/project/manifest.zig` owns Manifest v12-shaped test kwargs and
  dependencies.
- `tests/test_cli.py` validates native-binary execution and artifacts.

## Artifact Fields

This slice affects `manifest.json` test nodes for supported table-level
generic tests:

- top-level `column_name` remains `null`, matching dbt's table-level test
  attachment semantics.
- `test_metadata.kwargs.column_name` is emitted.
- `test_metadata.kwargs.model` remains `ref(...)` for model/seed tests and
  `source(...)` for source tests.
- `attached_node` remains set for model/seed tests and `null` for source tests.
- `depends_on.nodes`, `refs`, and `sources` reuse the existing supported
  generic-test dependency shapes.

It also writes existing Run Results v6-shaped rows for executed tests.

## Validation

Native Zig coverage:

- Model/seed property parser records table-level `column_name` arguments.
- Source parser records table-level source test `column_name`, list values, and
  quote flags.
- Manifest writer keeps top-level `column_name: null` for table-level tests
  while emitting `test_metadata.kwargs.column_name`.

Python integration coverage:

- `dxt build` executes table-level model and seed generic tests selected through
  graph expansion.
- `dxt build` executes a table-level source generic test selected through
  `source:<source>.<table>+`.
- `manifest.json` and `run_results.json` validate against the local schema
  slices for the supported fields.

## Stop Conditions

- No arbitrary generic-test macro execution.
- No package-provided generic test overrides or adapter-dispatched test macros.
- No custom test configs such as `where`, `limit`, `severity`, `warn_if`,
  `error_if`, or `store_failures`.
- No source-to-source relationship targets.
- No singular tests or unit-test execution.
- No typed scalar accepted-value Manifest parity beyond the existing
  string-backed supported values.
- No Python product runtime behavior.

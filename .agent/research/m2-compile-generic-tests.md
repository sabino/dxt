# M2 Compile Generic Data Tests

## Slice

Extend the render-only `dxt compile` boundary from selected SQL models and
singular SQL data tests to selected supported built-in generic data tests.
Generic tests are already parsed, selected, serialized in `manifest.json`, and
executed by the existing DuckDB `test` / `build` paths, so this slice only adds
compile artifacts for that already-supported SQL subset.

Supported generic test names in this slice:

- `not_null`
- `unique`
- `accepted_values`
- `relationships`

## Upstream References

dbt Core v1:

- `core/dbt/task/compile.py::CompileTask.get_node_selector` selects executable
  node types for compile, including tests.
- `core/dbt/task/compile.py::CompileRunner.compile` delegates selected nodes to
  `Compiler.compile_node`.
- `core/dbt/compilation.py::Compiler.compile_node` renders raw SQL into
  compiled SQL and writes compiled files through `_write_node`.
- `core/dbt/contracts/graph/nodes.py::GenericTestNode` is a compiled test node.
- `core/dbt/parser/schema_generic_tests.py::SchemaGenericTestParser` and
  `core/dbt/parser/generic_test_builders.py::TestBuilder` construct generic
  test nodes and kwargs.
- `core/dbt/task/test.py::TestRunner.execute_data_test` executes data tests from
  compiled failure-row SQL.

Fusion / dbt Core v2:

- `crates/dbt-parser/src/resolve/resolve_tests/resolve_data_tests.rs` resolves
  generic data-test nodes.
- `crates/dbt-schemas/src/schemas/manifest/v12.rs::into_map_compiled_sql`
  includes test nodes in compiled SQL maps.
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/generic_test_sql/*.sql`
  contains the built-in generic test SQL shapes for `not_null`, `unique`,
  `accepted_values`, and `relationships`.

## dxt Ownership

- `src/project.zig` orchestrates selected model and data-test compilation.
- `src/project/compiler.zig` owns `compileGenericTest` for the supported
  built-in failure-row SQL.
- `src/project/duckdb.zig` reuses the compiler entrypoint for generic test
  execution so compile and execution do not drift.
- `src/project/types.zig` stores optional compiled fields on `GenericTestNode`.
- `src/project/manifest.zig` emits compiled Manifest fields only when a generic
  test was compiled.

## Artifact Impact

- `manifest.json` may include `compiled`, `compiled_code`, `compiled_path`,
  `extra_ctes`, and `extra_ctes_injected` on selected compiled generic test
  nodes.
- Compiled files are written under
  `target/compiled/<package>/<test_alias>.sql`.
- `run_results.json` is not written by `dxt compile`.
- No catalog, sources, or semantic artifacts are changed.

## Validation

- Native Zig tests cover built-in generic-test SQL compilation and Manifest
  compiled field serialization.
- Python CLI coverage runs `dxt compile --select test_type:generic`, checks the
  compiled SQL files and Manifest fields, and verifies no DuckDB database or
  run-results artifact is created.
- Runtime-boundary and public-safety scans must stay green.

## Stop Conditions

- Do not compile custom generic test macros.
- Do not add generic test configs such as `where`, `limit`, `severity`,
  `warn_if`, `error_if`, `store_failures`, or `fail_calc`.
- Do not add new generic test types beyond the already-supported built-ins.
- Do not execute DuckDB or write run-results from `dxt compile`.
- Do not change indirect-selection semantics.
- Do not add general Jinja, macro execution, materialization macro execution,
  adapter dispatch execution, or Python product-runtime behavior.

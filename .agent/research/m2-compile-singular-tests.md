# M2 Compile Singular SQL Tests

## Slice

Extend the render-only `dxt compile` boundary from selected SQL models to
selected singular SQL data tests. Singular tests are already parsed, selected,
rendered by the Zig compiler, and executed by the existing DuckDB `test` /
`build` paths, so this slice only adds compile artifacts.

## Upstream References

dbt Core v1:

- `core/dbt/task/compile.py::CompileTask.get_node_selector` selects executable
  node types for compile, including tests.
- `core/dbt/task/compile.py::CompileRunner.compile` delegates selected nodes to
  `Compiler.compile_node`.
- `core/dbt/compilation.py::Compiler.compile_node` renders raw SQL into
  compiled SQL and writes compiled files through `_write_node`.
- `core/dbt/contracts/graph/nodes.py::SingularTestNode` is a compiled SQL node.
- `core/dbt/parser/singular_test.py::SingularTestParser.get_compiled_path`
  derives singular test compiled paths from the original test path.

Fusion / dbt Core v2:

- `crates/dbt-schemas/src/schemas/manifest/v12.rs::into_map_compiled_sql`
  includes test nodes in compiled SQL maps.
- `crates/dbt-schemas/src/schemas/manifest/manifest_nodes.rs` carries
  `compiled_path`, `compiled`, and `compiled_code` on manifest nodes.
- `crates/dbt-parser/src/renderer.rs` owns compile-phase rendering context.
- `crates/dbt-parser/src/resolve/resolve_tests/resolve_data_tests.rs`
  distinguishes singular data tests from generic tests.

## dxt Ownership

- `src/project.zig` orchestrates selected model and singular-test compilation.
- `src/project/compiler.zig` owns the current render-only SQL/Jinja subset and
  existing `compileSingularTest`.
- `src/project/types.zig` stores optional compiled fields on
  `SingularTestNode`.
- `src/project/manifest.zig` emits compiled Manifest fields only when a singular
  test was compiled.

## Artifact Impact

- `manifest.json` may include `compiled`, `compiled_code`, `compiled_path`,
  `extra_ctes`, and `extra_ctes_injected` on selected compiled singular test
  nodes.
- `run_results.json` is not written by `dxt compile`.
- No catalog, sources, or semantic artifacts are changed.

## Validation

- Native Zig tests cover singular-test Manifest compiled field serialization.
- Python CLI coverage runs `dxt compile --select test_type:singular`, checks the
  compiled SQL file and Manifest fields, and verifies no DuckDB database is
  created.
- Runtime-boundary and public-safety scans must stay green.

## Stop Conditions

- Do not compile generic tests in this slice.
- Do not execute DuckDB or write run-results from `dxt compile`.
- Do not add singular YAML patches/configs such as `where`, `limit`, severity,
  thresholds, or `store_failures`.
- Do not change indirect-selection semantics.
- Do not add general Jinja, macro execution, materialization macro execution,
  or adapter dispatch execution.
- Do not implement product compile behavior in Python.

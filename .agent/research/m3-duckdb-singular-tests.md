# M3 DuckDB Singular SQL Test Slice

This slice adds first-class singular SQL data tests to the existing Zig parser,
selector, manifest, and DuckDB execution path. It deliberately stops before full
dbt test parity: singular YAML patches/configs, severity thresholds,
`store_failures`, indirect-selection parity, and custom macro-backed test
behavior remain separate compatibility slices.

## Upstream References

dbt Core v1 / Python:

- `core/dbt/parser/read_files.py`: `get_source_files` and parser wiring split
  singular tests from `test_paths` while generic test blocks come from
  `generic_test_paths`; singular discovery skips `generic/` and `fixtures/`.
- `core/dbt/parser/singular_test.py`: `SingularTestParser` maps SQL test files
  to `NodeType.Test` resources.
- `core/dbt/parser/base.py`: `generate_unique_id` gives singular tests the
  `test.<package>.<name>` identity shape used for the current v1 target.
- `core/dbt/artifacts/resources/v1/singular_test.py`: singular test resources
  reject generic-only fields such as `test_metadata`, `column_name`, and
  `attached_node`.
- `core/dbt/contracts/graph/nodes.py`: singular tests are data tests with
  `test_node_type == "singular"`.
- `core/dbt/graph/selector_methods.py`: `test_type:` supports `generic`,
  `singular`, `data`, and `unit`.
- `core/dbt/task/test.py`: data-test execution accepts both singular and
  generic test nodes and counts returned failure rows.

dbt Core v2 / Fusion:

- `crates/dbt-parser/src/resolve/resolve_tests/resolve_data_tests.rs`: resolves
  SQL tests without generic-test metadata as singular data tests. Fusion uses a
  hash-suffixed singular identity shape; this slice keeps the dbt Core v1
  identity shape until version targeting is explicit.
- `crates/dbt-parser/src/renderer.rs`: parse/render behavior preserves
  execute-time boundaries and recovered refs/sources.
- `crates/dbt-schemas/src/schemas/manifest/manifest.rs`: schema-backed manifest
  construction and parent/child maps keep data tests in the graph artifact.

## dxt Ownership

- `src/project/types.zig`: `SingularTestNode`, `Graph.singular_tests`, and
  deinit ownership.
- `src/project/config.zig`: `test-paths` defaults and parsing.
- `src/project/loader.zig`: deterministic singular SQL file discovery under
  configured test paths, skipping `generic/` and `fixtures/`.
- `src/project.zig`: singular test parsing, selected data-test execution order,
  build/test orchestration, failure/skipped run-result propagation.
- `src/project/resolve.zig`: singular test dependency resolution, sorting, and
  duplicate checks.
- `src/project/selector.zig`: `resource_type:test`, `test_type:singular`, and
  `test_type:data` matching plus graph expansion.
- `src/project/compiler.zig`: render-only compilation for singular SQL tests.
- `src/project/duckdb.zig`: failure-row counting for compiled singular SQL.
- `src/project/manifest.zig`: Manifest v12-shaped singular test nodes and graph
  maps without generic-only fields.
- `src/project/run_results.zig`: Run Results v6-shaped rows for singular tests.
- `src/root.zig`: command selector validation for `test_type:data`.

## Artifact Fields

Manifest node fields in scope:

- `unique_id`, `resource_type`, `package_name`, `name`, `alias`, `path`,
  `original_file_path`, `patch_path`, `language`, `raw_code`, `config`,
  `depends_on`, `refs`, and `sources`.
- `parent_map` and `child_map` include singular test dependencies.
- `test_metadata`, `column_name`, and `attached_node` are intentionally omitted.

Run-results fields in scope:

- `unique_id`, `status`, `failures`, `message`, `compiled`, `compiled_code`,
  `relation_name`, `adapter_response`, `execution_time`, and `thread_id` in the
  existing v6-shaped writer.

## Validation

Native Zig coverage:

- Selector coverage for singular type, data type, path/file selectors, and
  graph expansion, including bare parent model selectors for dependent singular
  tests.
- Manifest writer coverage for singular test fields and absence of generic-only
  fields.
- Compiler coverage for singular test `ref()` and `source()` rendering.
- DuckDB wrapper coverage for semicolon/comment trimming before failure-row
  counting.

Python integration coverage:

- `dxt parse` writes singular test manifest nodes, dependency maps, and skips
  `tests/generic` plus `tests/fixtures`, including when `test-paths` entries
  include trailing slashes.
- `dxt ls --select test_type:singular` and `test_type:data` select singular
  tests through the native binary.
- `dxt build --select model+` builds a model and executes its selected singular
  test.
- `dxt test --select customers` executes a failing dependent singular test
  against an existing DuckDB relation and writes a fail row.

## Stop Conditions

- Do not parse generic test macros from `tests/generic` in this slice.
- Do not implement singular YAML patches, configs, severity thresholds, `where`,
  `limit`, or `store_failures`.
- Do not implement full indirect-selection modes beyond the existing
  parent-name dependency matching used by this subset.
- Do not switch singular unique IDs to the Fusion hash form until version
  targeting is explicit.
- Do not move product behavior into Python.

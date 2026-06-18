# M3 DuckDB Source-Target Relationships Generic Test Slice

This slice extends the supported built-in `relationships` generic test so the
`to` argument may be a literal `source('source_name', 'table_name')` target, not
only a `ref(...)` target.

The product runtime remains Zig. Python coverage is limited to black-box CLI,
fixture, dbt-oracle, and artifact-schema validation.

## Scope

- Parse literal `source('raw', 'customers')` relationship targets.
- Materialize model, seed, and source generic test nodes with source target
  dependencies that match dbt Manifest v12 shape.
- Keep the raw `to` argument for dbt-style synthetic names, hashes, and
  `test_metadata.kwargs`.
- Execute selected DuckDB `relationships` tests where the parent side is a
  source relation and the child side is a model, seed, or source relation.
- Preserve existing ref-backed relationship behavior.

## Upstream References

dbt Core v1 references:

- `core/dbt/parser/generic_test_builders.py::TestBuilder.build_raw_code`
- `core/dbt/parser/generic_test_builders.py::TestBuilder.build_model_str`
- `core/dbt/parser/schema_generic_tests.py::SchemaGenericTestParser`
- `core/dbt/context/providers.py::ParseSourceResolver`
- `core/dbt/context/providers.py::ParseRefResolver`
- `core/dbt/contracts/graph/nodes.py::GenericTestNode`
- `core/dbt/contracts/graph/manifest.py::Manifest`
- `schemas/dbt/manifest/v12.json`
- `schemas/dbt/run-results/v6.json`

Fusion references:

- `crates/dbt-parser/src/resolve/resolve_tests/resolve_data_tests.rs`
- `crates/dbt-parser/src/resolve/resolve_tests/persist_generic_data_tests.rs`
- `crates/dbt-parser/src/resolver.rs`
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/generic_test_sql/relationships.sql`

## Observed dbt Oracle Shape

For `to: source('raw', 'customers')`, dbt records the target source as a
source dependency, not as a ref.

Model and seed tests:

- `attached_node` is the tested model or seed unique ID.
- `refs` contains the tested model or seed ref.
- `sources` contains only `["raw", "customers"]`.
- `depends_on.nodes` lists the target source first, then the attached node.
- `test_metadata.kwargs.model` remains a `ref(...)` get-where-subquery wrapper.

Source-to-source tests:

- `attached_node` is `null`.
- `refs` is empty.
- `sources` lists the target source first and tested source second.
- `depends_on.nodes` lists the target source first and tested source second.
- `test_metadata.kwargs.model` remains the tested source
  `get_where_subquery(source(...))` wrapper.

For table-level tests with explicit `arguments.column_name`, dbt keeps the
top-level test node `column_name` null and writes the effective column name only
under `test_metadata.kwargs.column_name`.

## dxt Owners

- `src/project/types.zig` stores explicit source-target state on generic test
  nodes.
- `src/project/parse.zig` parses literal relationship `source(...)` targets.
- `src/project.zig` materializes source-target dependencies for model, seed,
  and source generic tests.
- `src/project/manifest.zig` writes dbt-shaped source target refs, dependency
  maps, and model kwargs.
- `src/project/duckdb.zig` renders parent relations from source targets.
- `tests/test_cli.py` validates parse artifacts and DuckDB execution through
  the native binary.

## Stop Conditions

- Only literal `source('source_name', 'table_name')` targets are supported.
- Dynamic source arguments, general Jinja in `to`, adapter-dispatched test
  overrides, custom generic tests, singular tests, unit tests, custom configs,
  `where`, `limit`, `severity`, `warn_if`, `error_if`, and `store_failures`
  remain out of scope.
- No new Python product runtime behavior.

# M3 DuckDB Seed Column Generic Test Slice

## Scope

This slice extends the existing Zig parser and DuckDB build boundary to
root-project CSV seed-attached column generic tests. It parses `seeds:` YAML
properties from configured model and seed paths, patches matching seed nodes
with columns and supported test definitions, materializes selected generic test
nodes, writes seed column and patch metadata into the Manifest v12-shaped slice,
and executes selected root-project seed+test builds through the Zig-owned
DuckDB CLI backend.

The product runtime remains Zig. Python coverage in this slice is black-box
CLI, fixture, artifact-schema, and run-results validation only.

## Upstream References

dbt Core v1 references:

- `core/dbt/parser/schemas.py::SchemaParser.parse_file`
- `core/dbt/parser/schemas.py::TestablePatchParser`
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

- `crates/dbt-parser/src/resolve/resolve_seeds.rs::resolve_seeds`
- `crates/dbt-parser/src/resolve/resolve_tests/persist_generic_data_tests.rs`
- `crates/dbt-parser/src/resolve/resolve_tests/resolve_data_tests.rs`
- built-in generic test SQL macros for `not_null`, `unique`,
  `accepted_values`, and `relationships`
- `crates/dbt-schemas/src/schemas/run_results.rs`

## dxt Owners

- `src/project/loader.zig` discovers YAML property files under seed paths.
- `src/project.zig` currently owns model/seed property parsing, property
  application, generic-test materialization, seed+test build orchestration, and
  warnings until these move into focused parser/runner modules.
- `src/project/types.zig` stores the generalized model/seed property resource
  type.
- `src/project/resolve.zig` owns resource-type-aware node lookup.
- `src/project/manifest.zig` serializes seed patch metadata, descriptions,
  doc blocks, columns, and config tags.
- `src/project/duckdb.zig` renders and executes supported generic test SQL.
- `src/project/run_results.zig` serializes seed and test run results.
- `tests/test_cli.py` validates the native binary against synthetic seed
  fixtures and pinned local artifact schemas.

## Behavior

- Seed YAML entries create seed properties when the top-level resource section
  is `seeds:`.
- Matching seed nodes receive column metadata, descriptions, docs, tags, and
  supported generic test definitions without changing their `seed`
  materialization.
- Supported seed column generic tests use the same dbt-style synthetic naming
  and dependency shape as attached model tests: no `seed_` prefix, `attached_node`
  points at the seed unique ID, `refs` contains the seed ref, and
  `test_metadata.kwargs.model` uses `{{ get_where_subquery(ref('<seed>')) }}`.
- `dxt build --select raw_seed+` builds the selected root-project seed before
  its selected seed-attached generic tests and writes one Run Results v6-shaped
  artifact.
- Ref-backed seed `relationships` tests require the referenced relation to be
  selected or already present so the narrow build branch can execute against a
  materialized target.

## Stop Conditions

- Root-project CSV seeds only.
- No package seed execution.
- No `dxt seed` command.
- No seed configs such as `quote_columns`, `column_types`, or full materialized
  seed macro semantics.
- No table-level seed tests.
- No custom generic-test macro execution or adapter-dispatched test overrides.
- No singular tests or unit-test execution.
- No custom test configs such as `where`, `limit`, `severity`, `warn_if`,
  `error_if`, or `store_failures`.
- No full dbt queue interleaving, skip/fail-fast, or partial-failure run-result
  semantics.
- No typed scalar accepted-value Manifest parity; current supported values are
  serialized through the existing string-backed generic-test definition.

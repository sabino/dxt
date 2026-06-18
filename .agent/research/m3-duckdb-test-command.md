# M3 DuckDB Test Command Slice

This slice adds `dxt test` as a narrow command wrapper around the existing
Zig-owned DuckDB generic-test execution path. It improves command-surface
coverage without changing parser semantics, selector semantics, generic-test SQL
rendering, or build DAG behavior.

## Upstream References

dbt Core v1 / Python:

- `core/dbt/cli/main.py`: wires `dbt test` to the test task.
- `core/dbt/task/test.py::TestTask`: filters execution to dbt test node types
  and uses `ResourceTypeSelector` for selection.
- `core/dbt/task/test.py::TestRunner`: dispatches generic/singular data tests
  and unit tests, then builds run results from failures and severity.
- `core/dbt/task/build.py::BuildTask.RUNNER_MAP`: reuses `TestRunner` for test
  and unit resources during `dbt build`.
- `core/dbt/graph/selector_methods.py`: defines `test_type:` matching for
  generic, singular/data, and unit tests.

dbt Core v2 / Fusion:

- `crates/dbt-clap-core/src/commands.rs`: keeps `test` as a first-class command
  with static-analysis-aware command args.
- `crates/dbt-parser/src/resolve/resolve_tests/resolve_data_tests.rs`: resolves
  generic data tests, metadata, attached nodes, and relation components.
- `crates/dbt-schemas/src/schemas/data_tests.rs`: models data-test input forms
  and table-level `column_name`.
- `crates/dbt-schemas/src/schemas/run_results.rs`: keeps failures and command
  args as part of run-results artifact shape.

## dxt Ownership

- `src/root.zig` owns `dxt test` command dispatch, option parsing, help, and
  build-only flag rejection.
- `src/project.zig` owns the current `testPreflight` orchestration and reuses
  existing graph loading, dependency resolution, selected generic-test ordering,
  validation, DuckDB execution, and Run Results writing.
- `src/project/selector.zig` is unchanged; `dxt test` calls
  `selectResources(..., "test", ...)`, so existing attached-node selectors such
  as `--select customers` select only generic tests for execution.
- `src/project/duckdb.zig` continues to own supported built-in generic-test SQL
  rendering and DuckDB CLI execution.
- `src/project/run_results.zig` continues to own the Run Results v6-shaped writer
  for pass/fail generic-test rows.
- `tests/test_cli.py` validates native-binary command behavior and artifacts.

## Supported Scope

- Executes selected supported DuckDB generic test nodes only.
- Supported tests are the existing built-in subset:
  `not_null`, `unique`, `accepted_values`, and `relationships` for model, seed,
  and source-backed tests with the already-supported argument shapes.
- Writes `manifest.json` and `run_results.json`.
- Returns exit code `1` through the existing `TestFailure` path when any selected
  generic test fails.
- Requires referenced relations to already exist in the target DuckDB database;
  `dxt test` does not build or run parent models, seeds, or sources.

## Artifact Fields

This slice reuses existing artifact writers:

- `manifest.json` remains the current Manifest v12-shaped graph slice.
- `run_results.json` remains the current Run Results v6-shaped slice with
  generic-test `status`, `failures`, `message`, `compiled`, `compiled_code`, and
  null `relation_name`.

## Validation

Native Zig coverage:

- `src/root.zig` tests cover `dxt test` selector option parsing before runtime
  execution and rejection of build-only `--full-refresh`.

Python integration coverage:

- `dxt test --select customers` executes attached model generic tests against a
  relation prepared by `dxt run` and writes only test rows to `run_results.json`.
- A failing `relationships` generic test returns exit code `1`, writes a fail
  row, and preserves the existing failure message shape.
- `resource_type:unit_test` remains explicitly unsupported for `dxt test`.

## Stop Conditions

- No unit-test execution.
- No singular test parsing or execution.
- No custom generic-test macro execution or adapter-dispatched test overrides.
- No `where`, `limit`, `severity`, `warn_if`, `error_if`, or `store_failures`
  semantics.
- No model/seed/source materialization from `dxt test`.
- No selector semantic changes beyond filtering command execution to test
  resources.
- No Python product runtime behavior.

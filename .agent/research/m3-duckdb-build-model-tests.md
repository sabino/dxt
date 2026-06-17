# M3 DuckDB Model And Generic-Test Build Slice

This slice implements the first mixed `dxt build` execution path for selected
DuckDB SQL models and selected supported generic tests while keeping product
runtime behavior in Zig.

## Scope

- Execute `dxt build` selections that contain selected enabled SQL models and,
  optionally, selected generic test resources.
- Support DuckDB only.
- Support SQL model materializations already supported by `dxt run`: `table`
  and `view`.
- Support only column-level `not_null` and `unique` generic tests.
- Execute selected models in dependency order, then execute selected supported
  generic tests against the built relations.
- Write one dbt Run Results v6-shaped `run_results.json` containing model
  successes followed by generic test `pass` or `fail` results.
- Return exit code `1` when any selected generic test fails.

## Upstream References

dbt Core v1 / Python:

- `core/dbt/task/build.py::BuildTask.RUNNER_MAP` maps build resource types to
  model, seed, snapshot, and test runners.
- `core/dbt/task/runnable.py::get_graph_queue` and `run_queue` drive DAG
  execution over selected graph nodes.
- `core/dbt/graph/selector.py::get_graph_queue` and
  `core/dbt/graph/queue.py::GraphQueue` define graph-ordered selected resource
  execution.
- `core/dbt/task/run.py::ModelRunner` owns model execution behavior.
- `core/dbt/task/test.py::TestRunner.execute_data_test` and
  `build_test_run_result` own data-test execution and pass/fail result mapping.
- `core/dbt/artifacts/schemas/run/v5/run.py::process_run_result` serializes
  compiled resources into run-results fields.
- `schemas/dbt/run-results/v6.json` defines the artifact contract.

dbt Core v2 / Fusion:

- `crates/dbt-dag/src/schedule.rs::Schedule` and
  `crates/dbt-dag/src/deps_mgmt.rs::topological_sort` are DAG ordering
  references.
- `crates/dbt-tasks-core/src/stats_to_results.rs` and
  `crates/dbt-tasks-core/src/utils.rs::build_run_results_artifact` map task
  results to artifacts.
- `crates/dbt-schemas/src/schemas/run_results.rs` records run-result and
  context-run-result fields.
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/generic_test_sql/not_null.sql`
  and `unique.sql` define the built-in failing-row SQL.
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/tests/test.sql`
  and `helpers.sql` define test materialization wrapping.

## dxt Ownership

- `src/project.zig` owns the current `build` orchestration branch until a runner
  module exists.
- `src/project/duckdb.zig` owns direct DuckDB SQL model, seed, and generic-test
  execution for the current CLI-backed backend.
- `src/project/run_results.zig` owns minimal Run Results v6 serialization.
- `src/root.zig` owns CLI exit-code and diagnostic mapping.
- `tests/test_cli.py` owns black-box native-binary build coverage.

## Validation

- Native Zig tests cover mixed model and generic-test run-results ordering.
- Python integration tests run `dxt build --select <model>` through the native
  binary, verify DuckDB relation contents, validate `run_results.json` against
  the local Run Results v6 schema slice, and cover both passing and failing
  generic tests.
- Boundary tests verify unsupported model-attached generic tests fail before
  creating DuckDB side effects.

## Stop Conditions

- Do not execute seed+model or seed+model+test DAGs in this slice.
- Do not change selector semantics, `--indirect-selection`, YAML selectors, or
  test-selection provenance.
- Do not implement `accepted_values`, `relationships`, singular tests, unit
  tests, source tests, custom generic tests, `where`, `limit`, `severity`,
  `warn_if`, `error_if`, or `store_failures`.
- Do not implement materialization macro execution, adapter dispatch, hooks,
  grants, docs persistence, catalog introspection, full relation staging or
  backup parity, threaded scheduling, or partial/failed model run-results.
- Do not add Python product runtime behavior.

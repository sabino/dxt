# M3 DuckDB Seed Model Build DAG Slice

This slice implements the first mixed `dxt build` path for selected root-project
DuckDB seeds, selected DuckDB SQL models, and selected supported generic tests
while keeping product runtime behavior in Zig.

## Scope

- `dxt build` only.
- DuckDB adapter only.
- Root-project CSV seed nodes only.
- SQL model materializations already supported by `dxt run`: `table` and `view`.
- Column-level `not_null` and `unique` generic tests only.
- Execute selected seed and model nodes in deterministic dependency order for
  selected `seed.*` and `model.*` dependencies, then execute selected supported
  generic tests against the built model relations.
- Write one dbt Run Results v6-shaped `run_results.json` preserving execution
  order.
- Return exit code `1` when any selected generic test fails.

## Upstream References

dbt Core v1 / Python:

- `core/dbt/task/build.py::BuildTask.RUNNER_MAP` maps build resource types to
  seed, model, snapshot, and test runners.
- `core/dbt/task/runnable.py::get_graph_queue` and `run_queue` drive selected
  graph execution.
- `core/dbt/graph/selector.py::get_graph_queue` and
  `core/dbt/graph/queue.py::GraphQueue` define graph-ordered selected resource
  execution.
- `core/dbt/task/seed.py::SeedRunner` and `SeedTask` own seed execution.
- `core/dbt/context/providers.py::load_agate_table` resolves runtime seed data.
- `core/dbt/task/run.py::ModelRunner` owns model execution.
- `core/dbt/task/test.py::TestRunner.execute_data_test` and
  `build_test_run_result` own generic-test execution and pass/fail result
  mapping.
- `core/dbt/artifacts/schemas/run/v5/run.py::process_run_result` and
  `schemas/dbt/run-results/v6.json` define run-result serialization.

dbt Core v2 / Fusion:

- `crates/dbt-dag/src/schedule.rs::Schedule` and
  `crates/dbt-dag/src/deps_mgmt.rs::topological_sort` are DAG ordering
  references.
- `crates/dbt-tasks-core/src/stats_to_results.rs` and
  `crates/dbt-tasks-core/src/utils.rs::build_run_results_artifact` map task
  results to artifacts.
- `crates/dbt-parser/src/resolve/resolve_seeds.rs` and DuckDB seed
  materialization helpers document seed relation setup and file-path behavior.
- Fusion built-in generic-test SQL and test materialization helper macros remain
  the reference for supported `not_null` and `unique` failure-row SQL.

## dxt Ownership

- `src/project.zig` owns the current mixed seed/model/test `build`
  orchestration branch and selected seed/model dependency ordering until a
  runner module exists.
- `src/project/duckdb.zig` owns direct DuckDB seed, model, and generic-test
  execution for the current CLI-backed backend.
- `src/project/run_results.zig` owns minimal Run Results v6 serialization.
- `src/root.zig` owns CLI exit-code and diagnostic mapping.
- `tests/test_cli.py` owns black-box native-binary build coverage.

## Validation

- Native Zig tests cover selected seed-before-model dependency ordering and
  seed/model/generic-test run-results shape.
- Python integration tests run `dxt build --select +<model>` through the native
  binary, verify DuckDB relation contents, validate `run_results.json` against
  the local Run Results v6 schema slice, and cover passing and failing
  seed-backed generic tests.
- Boundary tests verify unsupported generic tests fail before creating DuckDB
  side effects.

## Stop Conditions

- Do not add `dxt seed`.
- Do not make `dxt run` execute seeds.
- Do not execute package seeds.
- Do not implement seed configs such as delimiters, quoting, or column types.
- Do not implement `accepted_values`, `relationships`, singular tests, unit
  tests, source tests, custom generic tests, test configs, `store_failures`, or
  adapter materialization macro execution.
- Do not implement hooks, grants, docs persistence, catalog introspection,
  threaded scheduling, fail-fast skip semantics, or partial failed-model
  run-results.
- Do not replace the external DuckDB CLI backend here.

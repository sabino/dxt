# M3 Run/Build Skipped Results

Status: implemented in the `feature/run-build-skipped-results` slice.

## Upstream References

dbt Core v1 reference commit: `9e5b8fcf5de195e394ab17b8813cf952d43e02fb`

- `core/dbt/task/runnable.py`
  - `mark_node_as_skipped` returns a `RunStatus.Skipped` result only when the node was not already executed.
  - `GraphRunnableTask._handle_result` records completed results and marks dependent nodes when a result status should block descendants.
  - `GraphRunnableTask._mark_dependent_errors` stores dependent node IDs in `_skipped_children`.
  - `GraphRunnableTask.interpret_results` treats non-exposure skipped results as unsuccessful command outcomes.
- `core/dbt/task/base.py`
  - `BaseRunner.do_skip` and skip execution return `RunStatus.Skipped`; ordinary upstream skips have no error message unless caused by an ephemeral compilation error.
- `core/dbt/task/build.py`
  - `BuildTask.MARK_DEPENDENT_ERRORS_STATUSES` includes `Error`, `Fail`, `Skipped`, and `PartialSuccess`.
  - `BuildTask.handle_job_queue_node` and `call_model_and_unit_tests_runner` apply queued skip decisions before execution.
- `core/dbt/graph/queue.py`
  - `GraphQueue.mark_done` removes completed nodes and advances dependent nodes through the selected DAG.
- `core/dbt/artifacts/schemas/run/v5/run.py`
  - `process_run_result` writes compiled fields only for compiled resources and preserves per-node status/message/failure values.
- `schemas/dbt/run-results/v6.json`
  - Run Results v6 includes `skipped` as a valid result status.

dbt Core v2 / Fusion reference commit: `a641eae6d2212d11cbc6edd9e1551c71c48d2e8a`

- `crates/dbt-schemas/src/schemas/run_results.rs`
  - `ContextRunResult` and `RunResultOutput` model `status`, `message`, `failures`, `unique_id`, compiled fields, and relation name as artifact fields.
- `crates/dbt-tasks-core/src/stats_to_results.rs`
  - Task stats are converted into run-result artifact rows after execution.
- `crates/dbt-tasks-core/src/utils.rs`
  - `build_run_results_artifact` assembles the final artifact from recorded stats.
- `crates/dbt-dag/src/schedule.rs`
  - Schedule data separates selected nodes from frontier nodes.
- `crates/dbt-dag/src/deps_mgmt.rs`
  - `topological_sort` and `topological_levels` provide deterministic DAG ordering references.

## dxt Scope

Owning modules:

- `src/project.zig`: current M3 runner/orchestration facade for `run` and `build` execution loops.
- `src/project/run_results.zig`: Run Results v6-shaped artifact writer.

Implemented behavior:

- When a selected `dxt run` model fails during DuckDB execution, dxt appends the existing sanitized `status: "error"` row, appends `status: "skipped"` rows for selected model descendants blocked by that failure, writes `run_results.json`, and returns exit code `1`.
- When a supported `dxt build` seed/model execution node fails during DuckDB execution, dxt appends the error row, appends skipped rows for selected blocked seed/model descendants and selected blocked generic tests, writes `run_results.json`, and returns exit code `1`.
- Skipped rows are limited to the post-`--exclude` selected set.
- Skipped rows preserve compiled model fields when the model was compiled before execution. Generic-test skipped rows keep message and failures null.

## Stop Conditions

This slice does not implement:

- Full dbt `GraphQueue`, threaded scheduling, fail-fast, retry, or independent-resource continuation after a failure.
- Test-failure-driven downstream skipping.
- Generic-test runtime-error rows.
- Unit-test execution.
- Package seed execution or seed config expansion.
- Selector grammar changes, YAML selectors, state/result/source-status selectors, or `ls` JSON parity changes.
- Raw DuckDB stderr in public artifacts.
- Python product-runtime behavior.

## Validation

Required gates:

- Native Zig tests for skipped run-result shape and blocked-resource helper behavior.
- Pytest coverage for `run` and `build` model failure with blocked selected descendants.
- Pytest coverage that `--exclude` removes would-be skipped descendants from `run_results.json`.
- Pytest coverage for a selected seed execution failure blocking a selected dependent model and its selected generic tests.
- Existing Run Results v6 schema slice validation.
- Runtime-boundary and public-safety scans before PR handoff.

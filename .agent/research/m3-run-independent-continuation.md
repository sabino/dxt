# M3 Run Independent Failure Continuation

## Slice

This slice narrows `dxt run` failure continuation for selected DuckDB SQL
models: a selected model execution error records an `error` row, selected model
descendants are recorded as `skipped` when encountered in dependency order, and
later selected models with no dependency on the failed node continue executing.

## Upstream References

dbt Core v1 source references:

- `core/dbt/task/runnable.py`: `GraphRunnableTask._handle_result`,
  `_mark_dependent_errors`, `mark_node_as_skipped`, and `interpret_results`
  define failure recording, descendant skip propagation, and failed command
  interpretation while the graph queue can continue with runnable independent
  nodes.
- `core/dbt/task/run.py`: `RunTask` and `ModelRunner` use the shared runnable
  task machinery for model execution.
- `core/dbt/graph/queue.py`: `GraphQueue.mark_done` advances independent graph
  nodes after completed or failed nodes are handled.
- `schemas/dbt/run-results/v6.json`: permits `success`, `error`, and `skipped`
  result rows in one Run Results artifact.

dbt Core v2 / Fusion direction:

- `crates/dbt-dag/src/schedule.rs` and `crates/dbt-dag/src/deps_mgmt.rs` keep
  runnable dependency scheduling explicit. This dxt slice remains a sequential
  approximation, not a scheduler rewrite.
- `crates/dbt-schemas/src/schemas/run_results.rs` models the shared
  run-result status, message, failures, compiled fields, and relation fields.

## dxt Ownership

- `src/project.zig`: current run orchestration facade; tracks blocked selected
  model IDs during `dxt run` and continues independent selected models.
- `src/project/run_results.zig`: existing Run Results v6-shaped writer for
  mixed `success`, `error`, and `skipped` model rows.
- `src/project/duckdb.zig`: unchanged Zig-owned DuckDB CLI execution boundary.

## Artifact Impact

- `target/run_results.json`: `dxt run` can now contain an `error` row, one or
  more later independent `success` rows, and selected descendant `skipped` rows
  in the same artifact.
- `target/manifest.json`: unchanged shape.

## Boundaries

- No `dxt build` independent-resource continuation.
- No seed command continuation.
- No test-failure continuation beyond existing build test blocking.
- No threaded dbt queue, retry, fail-fast flag, relation staging, raw DuckDB
  stderr exposure, or non-DuckDB adapter behavior.
- No Python product-runtime behavior.

## Validation

- Native Zig test covers blocked-dependency skip row creation while independent
  nodes are not skipped.
- Focused pytest covers a failing model, a selected descendant skip, an
  independent selected model success, Run Results v6 schema validation, and the
  independent DuckDB relation contents.

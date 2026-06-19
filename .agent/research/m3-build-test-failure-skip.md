# M3 Build Data-Test Failure Blocking

## Slice

This slice narrows `dxt build` behavior for selected DuckDB model/seed builds:
selected data tests that are ready after a selected seed/model completes run
before selected downstream seed/model resources. If one of those tests fails,
`dxt` writes the failed test row, appends `skipped` rows for selected downstream
seed/model descendants and selected downstream data tests, writes
`run_results.json`, avoids creating the blocked downstream relations, and exits
with code `1`.

## Upstream References

dbt Core v1 source references:

- `core/dbt/task/build.py`: `BuildTask` selects runner types and wires build
  resources through the runnable task machinery.
- `core/dbt/task/runnable.py`: `mark_node_as_skipped`,
  `GraphRunnableTask._handle_result`, `_skipped_children`, and
  `execute_nodes()` define how failed upstream results mark downstream graph
  children as skipped.
- `core/dbt/task/base.py`: runner `skip`, `skip_cause`, `do_skip`, and
  `on_skip()` define skipped runner result behavior.
- `core/dbt/task/test.py`: data tests are regular runnable resources in the
  build graph and produce pass/fail run-result rows.
- `core/dbt/graph/selector.py` and `core/dbt/graph/selector_spec.py`: selected
  resources and graph expansion decide which tests/downstream resources can
  participate before execution.

dbt Core v2 / Fusion direction:

- `crates/dbt-scheduler/*`: Fusion-era scheduling makes graph execution order
  and dependency readiness explicit. This dxt slice remains a small sequential
  approximation, not a scheduler rewrite.
- `crates/dbt-schemas/src/schemas/run_results/*`: run-result statuses remain
  schema-backed artifacts rather than ad hoc CLI text.

## dxt Ownership

- `src/project.zig`: current build orchestration facade, selected resource
  ordering, test readiness checks, test failure blocker propagation, and
  skipped-result appending.
- `src/project/run_results.zig`: no schema change; existing mixed model/test
  rows and skipped rows are reused.
- Future extraction target: move this scheduling logic into a focused runner
  or graph-scheduler module once `src/project.zig` shrinks.

## Artifact Impact

- `target/run_results.json`: model/seed build paths may now contain a failing
  data-test row before downstream selected `skipped` rows.
- `target/manifest.json`: unchanged shape.
- DuckDB database: blocked downstream relations are not created in this slice.

## Validation

Native Zig tests:

- skipped data-test failure propagation skips selected downstream nodes and
  unexecuted downstream tests without duplicating the failed test row.
- data-test readiness waits for selected seed/model dependencies.

Python integration tests:

- model-only selected build: failing `not_null` on `customers` skips selected
  downstream `orders` and leaves the `orders` relation absent.
- seed+model selected build: failing `not_null` after seed and model execution
  skips selected downstream `orders` and leaves the `orders` relation absent.

## Boundaries

- No full threaded dbt queue implementation.
- No independent-resource continuation after a test failure.
- No `--indirect-selection` modes.
- No unit-test execution.
- No custom generic test macros or custom test config semantics.
- No Python product-runtime behavior.

# M3 DuckDB Run/Build Failure Run Results Slice

This slice hardens `dxt run` and `dxt build` so DuckDB model or seed execution
failures still produce a dbt-shaped `run_results.json` artifact with completed
prior results and an `error` row for the failed resource.

## Scope

- `dxt run` and existing DuckDB model/seed branches of `dxt build`.
- DuckDB adapter only.
- Selected SQL models with `table` or `view` materializations.
- Root-project CSV seeds in the already-supported build branches.
- Sanitized execution-error messages only; do not capture raw DuckDB stderr into
  public artifacts yet.
- Preserve preflight/unsupported selection behavior: unsupported selections and
  materializations still fail before writing `run_results.json`.

## Upstream References

dbt Core v1 / Python, branch `1.latest`, inspected at commit `9e5b8fc`:

- `schemas/dbt/run-results/v6.json`: allows `status: "error"` rows and defines
  per-result `message`, `failures`, `compiled`, `compiled_code`, and
  `relation_name`.
- `core/dbt/artifacts/schemas/run/v5/run.py::RunResultOutput` and
  `process_run_result`: maps result status, message, failures, compiled node
  fields, and relation name into the artifact.
- `core/dbt/task/runnable.py::_handle_thread_exception`: runtime exceptions are
  converted into `RunStatus.Error` results with a message and no failures.
- `core/dbt/task/runnable.py::_handle_result` and `interpret_results`: errored
  results remain in node results and make the command fail.
- `core/dbt/task/run.py::ModelRunner` and `core/dbt/task/seed.py::SeedRunner`:
  model and seed execution report through the same run-result artifact path.
- `core/dbt/task/build.py::BuildTask.RUNNER_MAP`: build uses model, seed, and
  test runners under one artifact contract.

dbt Core v2 / Fusion foundation, branch `main`, inspected at commit `a641eae`:

- `crates/dbt-schemas/src/schemas/run_results.rs::RunResultOutput`:
  documents status values such as `success`, `error`, `pass`, `fail`, compiled
  fields, relation name, message, and failures.
- `crates/dbt-tasks-core/src/stats_to_results.rs::stats_to_results`: converts
  task stats into context run results with status, timing, adapter response,
  message, failures for tests, and node identity.
- `crates/dbt-tasks-core/src/utils.rs::build_run_results_artifact`: assembles
  run results into a v6 artifact from accumulated stats.
- `crates/dbt-dag/src/schedule.rs` remains the future scheduling reference;
  this slice does not implement full queue or skip semantics.

## dxt Ownership

- `src/project.zig`: current `run` and `build` orchestration catches
  `DuckDbExecutionFailed` from model/seed execution, appends an `error` result,
  writes `run_results.json`, and returns a command failure.
- `src/project/run_results.zig`: Run Results v6-shaped serialization for
  success, pass/fail, and now error result rows.
- `src/project/duckdb.zig`: remains the Zig-owned DuckDB CLI execution boundary.
  It still returns a generic execution failure instead of exposing raw stderr.
- `src/root.zig`: maps the new command-level execution failure to exit code `1`
  without changing unsupported-option/preflight usage failures.

## Validation

- Native Zig tests cover model error row serialization with compiled fields,
  sanitized message, null failures, and relation name.
- Pytest integration runs the native binary for:
  - `dxt run --select +orders` where a parent model succeeds and the selected
    child model fails;
  - `dxt build --select +orders` with the same partial model failure;
  - `dxt build --select customers` where a failing model prevents selected
    generic tests from running.
- The integration tests validate the local Run Results v6 schema slice and
  assert that unsupported preflight behavior remains covered by existing tests.

## Stop Conditions

- Do not add generic-test runtime-error rows in this slice.
- Do not add dbt skip propagation, fail-fast, retries, threaded scheduling, or
  full graph queue semantics.
- Do not expose raw DuckDB stderr in artifacts until path/secret scrubbing is
  designed.
- Do not implement relation staging/backup rename parity, incremental,
  ephemeral, snapshots, hooks, grants, or docs persistence.
- Do not change selectors, compile rendering, docs generation, docs serving, or
  `ls` output.
- Do not move product behavior into Python.

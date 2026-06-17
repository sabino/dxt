# M3 DuckDB Source Freshness Slice

## Scope

This slice adds the first `dxt source freshness` execution path for selected
DuckDB source tables that define table-level `loaded_at_field` and table-level
`freshness` thresholds. It writes a dbt-shaped `sources.json` v3 artifact.

The slice is intentionally narrow:

- supported: selected source resources, DuckDB local database files, table-level
  `loaded_at_field` SQL text, table-level `freshness.warn_after` /
  `freshness.error_after`, `minute` / `hour` / `day` periods, success rows, and
  runtime-error rows. `freshness.filter` is appended as raw SQL in the
  loaded-at-field query. Empty or all-null loaded-at values are emitted as
  stale freshness results;
- not supported: source-level inheritance, executing `loaded_at_query`,
  metadata freshness, `config:` freshness overrides, hooks, concurrency,
  source-status selectors, non-DuckDB adapters, or Python product runtime
  behavior.

## Upstream References

dbt Core v1:

- `core/dbt/task/freshness.py::FreshnessRunner.execute` defines the runtime
  freshness paths: custom loaded-at query, loaded-at field, adapter metadata,
  status calculation, and result construction.
- `FreshnessRunner.execute` passes `compiled_node.freshness.filter` into
  `adapter.calculate_freshness` for loaded-at-field freshness.
- `core/dbt/task/freshness.py::FreshnessSelector.node_is_match` selects source
  nodes only when `node.has_freshness` is true.
- `core/dbt/task/freshness.py::FreshnessTask.result_path` and
  `FreshnessTask.get_result` write `sources.json`.
- `core/dbt/artifacts/schemas/freshness/v3/freshness.py` defines
  `FreshnessExecutionResultArtifact`, `SourceFreshnessOutput`, and
  `SourceFreshnessRuntimeError`.
- `schemas/dbt/sources/v3.json` is the artifact schema contract.
- `core/dbt/parser/sources.py::SourceParser.parse_source` stores
  `loaded_at_field`, `loaded_at_query`, and `freshness` on source definitions.
- `core/dbt/parser/sources.py::calculate_loaded_at_field_query_from_raw_target`
  and `merge_source_freshness` define the wider inheritance/config behavior
  that this slice explicitly defers.

dbt Core v2 / Fusion:

- `crates/dbt-schemas/src/schemas/sources.rs::FreshnessResultsArtifact`,
  `FreshnessResultsMetadata`, and `FreshnessResultsNode` preserve the
  `sources.json` compatibility shape.
- `crates/dbt-scheduler/src/node_selector.rs::match_source_status` treats
  `sources.json` as the future source-status selector input.

## dxt Ownership

- `src/root.zig` owns the `dxt source freshness` command dispatch and CLI
  option surface.
- `src/project.zig` owns the first orchestration path until a runner module is
  extracted.
- `src/project/types.zig` owns the source freshness data model fields.
- `src/project/parse.zig` owns table-level source freshness YAML parsing for
  this slice.
- `src/project/duckdb.zig` owns DuckDB loaded-at-field query rendering and the
  CLI-backed query boundary.
- `src/project/source_freshness.zig` owns threshold status calculation and
  `sources.json` v3 rendering.

## Artifact Fields

This slice writes:

- `sources.json.metadata` with the v3 schema URL and deterministic dxt metadata;
- `sources.json.results[]` success rows with `unique_id`, `max_loaded_at`,
  `snapshotted_at`, `max_loaded_at_time_ago_in_s`, `status`, `criteria`,
  `adapter_response`, `timing`, `thread_id`, and `execution_time`;
- `sources.json.results[]` runtime-error rows with `unique_id`, `error`, and
  `status: "runtime error"`.

It also writes `manifest.json` as the current dxt command artifact baseline.

## Validation

Native Zig coverage:

- table-level `loaded_at_field` and `freshness` parser regression;
- table-level unsupported `loaded_at_query` and `freshness.filter` parser
  regression;
- threshold status order: `error_after`, then `warn_after`, then `pass`;
- success and runtime-error `sources.json` writer shapes;
- DuckDB query SQL rendering, relation identifier quoting, raw
  `loaded_at_field` SQL-expression rendering, and empty loaded-at sentinel
  handling.
- raw `freshness.filter` SQL placement in the loaded-at-field freshness query.

Python integration coverage:

- selected DuckDB source freshness creates a schema-valid warning result;
- SQL-expression `loaded_at_field` creates a schema-valid warning result;
- `freshness.filter` changes the selected max loaded-at value and is preserved
  in the emitted criteria;
- empty loaded-at sources create schema-valid stale `error` results;
- selected source missing `loaded_at_field` creates a schema-valid runtime-error
  result and exits with failure.
- selected sources with unsupported `loaded_at_query` create schema-valid
  runtime-error results instead of silently ignoring the config.

Schema coverage:

- `tests/schemas/dbt_sources_v3_m3_slice.schema.json` validates the emitted v3
  artifact subset.

## Stop Conditions

Stop before implementing source-level inheritance, `loaded_at_query`, metadata
freshness, config overrides, hooks, source-status selectors, non-DuckDB
adapters, threaded scheduling, or broader dbt command behavior.

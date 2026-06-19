# Semantic Layer And MetricFlow Compatibility Map

## Scope

This is the source-grounded research note for issue #137. It maps dbt semantic
models, metrics, saved queries, `semantic_manifest.json`, and later MetricFlow
query planning to dxt-owned slices.

This spike does not change product runtime behavior. Future product behavior
must stay in Zig. Python is allowed only for dbt oracle checks, schema
validation helpers, public fixture harnesses, and safety scans.

## Source Snapshots

- dbt Core v1 compatibility reference: `dbt-labs/dbt-core` branch `1.latest`,
  commit `9e5b8fc`.
- dbt Core v2 / Fusion architecture reference: `dbt-labs/dbt-core` branch
  `main`, commit `6c5e56f`.
- dbt Semantic Interfaces reference: `dbt-labs/dbt-semantic-interfaces` branch
  `main`, commit `c2ba16a`.
- MetricFlow planning reference: `dbt-labs/metricflow` branch `main`, commit
  `286a01e`.

Use dbt Core v1 output parity and published artifacts as the compatibility
contract. Use Fusion, dbt Semantic Interfaces, and MetricFlow as architecture
and validation references only until their behavior is observable through dbt
Core-compatible artifacts.

## Current dxt Baseline

- `manifest.json` currently includes empty `metrics`, `saved_queries`, and
  `semantic_models` top-level maps.
- `src/project/manifest.zig` owns the current manifest writer.
- `src/project/parse.zig`, `src/project/loader.zig`, and remaining callbacks in
  `src/project.zig` own YAML/resource parsing boundaries today.
- `src/project/resolve.zig` owns current graph dependency mutation.
- `src/project/selector.zig` owns selectable resource matching and output.
- Semantic resources are not first-class dxt resources yet.
- `semantic_manifest.json` is not emitted yet.

## Upstream Reference Map

### dbt Core v1 Parse And Manifest Flow

- `core/dbt/parser/schema_yaml_readers.py::SemanticModelParser` parses
  standalone legacy `semantic_models:` entries, model-attached v2 semantic
  model declarations, entities, dimensions, measures, defaults, primary
  entity, config, metadata, and the model `ref()` expression. It also creates
  simple metrics for legacy measures with `create_metric: true`.
- `core/dbt/parser/schema_yaml_readers.py::MetricParser` parses legacy and v2
  metric YAML, including simple, ratio, derived, cumulative, and conversion
  metric type parameters; v2 simple metrics must be attached to a semantic
  model through aggregation parameters.
- `core/dbt/parser/schema_yaml_readers.py::SavedQueryParser` parses
  `saved_queries:`, query parameters (`metrics`, `group_by`, `where`,
  `order_by`, `limit`), exports, export config, tags, and enabled/disabled
  config.
- `core/dbt/parser/manifest.py::ManifestLoader.load` calls `process_refs`,
  `process_unit_tests`, `process_docs`, `process_metrics`,
  `process_saved_queries`, model-inferred primary key processing, group config
  validation, and semantic manifest validation before writing artifacts.
- `core/dbt/parser/manifest.py::process_metrics` resolves metric dependencies
  on semantic models, input metrics, and resources that reference metrics.
- `core/dbt/parser/manifest.py::process_saved_queries` populates saved-query
  metric dependencies. The upstream TODO still calls out unresolved dependency
  processing for saved-query `where` and `group_by`.
- `core/dbt/parser/manifest.py::update_semantic_model` fills
  `SemanticModel.node_relation` after the referenced model's relation fields
  have been resolved.
- `core/dbt/parser/manifest.py::write_manifest` also writes
  `semantic_manifest.json` and the OSI document through
  `write_semantic_manifest`.
- `core/dbt/contracts/graph/semantic_manifest.py::SemanticManifest` converts
  manifest semantic models, metrics, saved queries, and time spine models into
  dbt Semantic Interfaces pydantic objects, validates them, writes
  `semantic_manifest.json`, and attempts OSI document generation.

### dbt Semantic Interfaces

- `dbt_semantic_interfaces/protocols/semantic_manifest.py` defines the semantic
  manifest contract as `semantic_models`, `metrics`, `project_configuration`,
  and `saved_queries`.
- `protocols/semantic_model.py` defines semantic model concepts used by query
  planning: `node_relation`, primary entity, entities, measures, dimensions,
  defaults, partition/validity dimensions, references, metadata, config, and
  label.
- `protocols/metric.py` defines metric inputs, input measures, cumulative and
  conversion type params, metric references, time windows, filters, and
  granularity-related fields.
- `protocols/saved_query.py` defines saved-query query parameters and exports.
- `validations/semantic_manifest_validator.py` composes validation rules for
  non-empty resources, entities, measures, metric rules, aggregation time
  dimensions, primary entity, saved queries, semantic models, time dimensions,
  time spines, reserved keywords, and unique valid names.

### dbt Core v2 / Fusion References

- `crates/dbt-schemas/src/schemas/semantic_layer/semantic_manifest.rs`
  converts resolved manifest `Nodes` into semantic manifest arrays and project
  configuration.
- `crates/dbt-schemas/src/schemas/semantic_layer/semantic_model.rs` maps
  manifest semantic models into semantic-manifest semantic models and
  intentionally leaves semantic-manifest `measures` empty for current
  compatibility.
- `crates/dbt-schemas/src/schemas/semantic_layer/metric.rs` maps manifest
  metrics into semantic-manifest metrics and carries metric type parameters.
- `crates/dbt-schemas/src/schemas/semantic_layer/saved_query.rs` maps saved
  query attributes and export configs into semantic-manifest saved queries.
- `crates/dbt-parser/src/resolve/resolve_semantic_models.rs` resolves
  model-attached semantic models from typed model properties, model relation
  identity, project config, dimensions, entities, and metrics-as-measures.
- `crates/dbt-parser/src/resolve/validate_semantic_models.rs` covers time spine
  validation and version checks.
- `crates/dbt-parser/src/resolve/resolve_metrics.rs` resolves metric resources,
  semantic-model attachment, config, dependencies, and raw YAML config.
- `crates/dbt-parser/src/resolve/validate_metrics.rs` covers metric name and
  metric window validation.
- `crates/dbt-parser/src/resolve/resolve_saved_queries.rs` resolves saved query
  config, metrics dependencies, export relation config, and raw export config.

### MetricFlow Query Planning References

- `metricflow/engine/metricflow_engine.py::MetricFlowEngine` builds a
  `SemanticManifestLookup`, converts semantic models to source datasets,
  constructs source nodes, builds a `DataflowPlanBuilder`, converts the plan to
  SQL/execution, supports saved-query requests, and lists metrics/saved
  queries.
- `metricflow/dataflow/builder/dataflow_plan_builder.py::DataflowPlanBuilder`
  builds dataflow plans from metric query specs, metric evaluation plans,
  source node recipes, join descriptions, time spine nodes, predicate pushdown
  state, aggregations, conversions, cumulative metrics, and derived metrics.
- `metricflow_semantics/model/semantic_manifest_lookup.py` centralizes semantic
  model lookup, metric lookup, manifest object lookup, pathfinding, and time
  spine source construction.

MetricFlow is a design reference for dxt's future metric planner. dxt should
not embed MetricFlow Python or implement product metric runtime behavior in
Python.

## dxt Ownership Proposal

- `src/project/semantic.zig` should own semantic resource data structures,
  YAML field normalization, type-param parsing, resource-specific validation,
  and semantic-manifest transformation helpers once the surface outgrows the
  current parser modules.
- `src/project/parse.zig` should keep low-level scalar/list/object YAML helpers
  and narrow parsing routines that are already shared by resources.
- `src/project/loader.zig` should keep parse/load sequencing and installed
  package traversal.
- `src/project/resolve.zig` should own semantic dependency resolution:
  semantic-model model refs, metric-to-semantic-model dependencies,
  metric-to-metric dependencies, saved-query-to-metric dependencies, disabled
  target behavior, and parent/child map participation.
- `src/project/manifest.zig` should emit Manifest v12 `metrics`,
  `semantic_models`, and `saved_queries` maps plus the separate
  `semantic_manifest.json` artifact when schema support is added.
- `src/project/selector.zig` should add `metric:`, `semantic_model:`,
  `saved_query:`, and `resource_type:` matching only after the graph contains
  first-class semantic resources.
- Future `src/project/planner.zig`, `src/project/metric_plan.zig`, or a
  similarly focused module should own metric query logical planning. It should
  reuse adapter capability data, cost estimates, movement policy, and staging
  rules from the future cross-database planner instead of creating a separate
  semantic execution path.

## Proposed Slices

### 1. Semantic Resource Skeleton And Manifest Maps

In scope:

- Add Zig data structures for semantic models, metrics, and saved queries with
  only identity, package, path, description, tags, config enabled, dependencies,
  and disabled placement.
- Keep `semantic_manifest.json` out of scope.
- Keep query planning out of scope.
- Preserve existing empty maps for projects without semantic resources.

Validation:

- Native Zig tests for unique IDs, enabled/disabled placement, deterministic
  ordering, and parent/child map participation.
- Focused Python/dbt oracle fixture that compares resource counts and unique
  IDs in `manifest.json`.
- Manifest schema slice expansion for only the emitted fields.

### 2. Model-Attached Semantic Models And Simple Metrics

In scope:

- Parse model-attached v2 `semantic_model:` declarations from model YAML.
- Parse column dimensions/entities and model-level primary entity / defaults
  needed by the current v2 surface.
- Parse simple metrics attached to a semantic model.
- Resolve semantic model `node_relation` from the referenced model relation
  after model config and relation identity have been resolved.

Out of scope:

- Legacy standalone `semantic_models:` measure semantics.
- Derived, ratio, cumulative, and conversion metrics.
- Saved queries.
- Metric query execution.

Validation:

- Native Zig tests for semantic model field parsing and relation backfill.
- dbt oracle comparison against a synthetic public-safe fixture with one
  semantic model and one simple metric.
- `dxt ls` support only if this slice explicitly includes selector updates;
  otherwise keep semantic resources artifact-only.

### 3. Metric Dependency Resolver

In scope:

- Add ratio and derived metrics whose inputs are existing metrics.
- Add cumulative and conversion type-param parsing only after simple metric
  attachment is stable.
- Resolve metric-to-metric and metric-to-semantic-model dependencies in the
  graph.
- Preserve dbt-style disabled/missing-target diagnostics for unsupported or
  missing references.

Out of scope:

- Metric SQL generation.
- MetricFlow dataflow planning.
- Runtime adapter behavior.

Validation:

- Native Zig tests for dependency graph edges and cycles/unsupported shapes as
  explicit diagnostics.
- dbt oracle fixture comparing `depends_on.nodes` and disabled target behavior.

### 4. Saved Query Parsing And Dependencies

In scope:

- Parse `saved_queries:` identity, query params, tags, exports, and config.
- Resolve saved-query metric dependencies.
- Emit manifest saved-query map fields needed by dbt schema parity.

Out of scope:

- Saved-query export materialization.
- Dependency resolution for saved-query `where` and `group_by` beyond the
  upstream-supported metric dependency baseline.
- Metric query execution.

Validation:

- Native Zig tests for query params, export config, enabled/disabled placement,
  and dependency edges.
- dbt oracle fixture comparing `saved_queries` map and saved-query dependencies.

### 5. Semantic Manifest Writer

In scope:

- Emit `semantic_manifest.json` from the resolved Zig graph.
- Include `semantic_models`, `metrics`, `saved_queries`, and
  `project_configuration`.
- Add time-spine project configuration only after model time-spine parsing is
  represented in the graph.
- Validate against pinned dbt semantic manifest shape or dbt Semantic
  Interfaces oracle output.

Out of scope:

- OSI document output unless a dedicated source-grounded slice maps that
  artifact and its failure behavior.
- Metric query execution.
- Cross-database execution.

Validation:

- Native Zig tests for deterministic JSON emission and omitted/null field
  policy.
- Python/dbt oracle that runs dbt parse on semantic fixtures and compares a
  normalized `semantic_manifest.json` subset.
- Public-safety scan because artifact fixtures can easily include generated
  path metadata.

### 6. Selector And Listing Support For Semantic Resources

In scope:

- Add `resource_type:metric`, `resource_type:semantic_model`,
  `resource_type:saved_query`, and direct `metric:`, `semantic_model:`, and
  `saved_query:` selectors after the graph maps exist.
- Add compact `ls --output-keys` fields only for fields already present in the
  graph.

Out of scope:

- State/result/source-status selectors for semantic resources.
- Metric query execution.
- Full dbt JSON node output parity.

Validation:

- Native selector tests for exact, wildcard, package, graph expansion, and
  excludes where dbt supports them.
- Focused CLI tests comparing dbt and dxt selected unique IDs for semantic
  fixtures.

### 7. Metric Query Logical Plan Prototype

In scope:

- Add a Zig metric query logical IR for one simple metric over one semantic
  model.
- Resolve metric time dimension, group-by fields, and filters into a logical
  plan without executing SQL first.
- Record adapter capability and relation identity requirements for DuckDB.

Out of scope:

- Derived/ratio/cumulative/conversion query planning.
- Saved-query export execution.
- Cross-engine movement.
- Distributed joins.

Validation:

- Native Zig tests for logical plan construction.
- A Python/dbt oracle may compare generated SQL through dbt/MetricFlow only as
  developer evidence; the dxt product planner remains Zig.

### 8. Metric Execution And Cross-Database Planning

In scope:

- Execute simple metric plans through DuckDB after logical planning is stable.
- Reuse the future cross-database planner for pushdown, staging, movement
  policy, cost reporting, and sensitive-data movement gates.
- Add saved-query execution only after metric query execution has a stable
  runner boundary.

Out of scope:

- External semantic API serving.
- BI tool integration.
- Python product runtime.

Validation:

- Native planner tests for strategy selection and policy rejection.
- Focused CLI integration tests for DuckDB metric results.
- Cross-database tests only after adapter capability contracts and staging
  metadata exist.

## Risks

- dbt Core v1 and Fusion semantic YAML shapes differ; dxt should pin observable
  dbt Core artifact parity before adopting Fusion-only structure.
- Semantic manifest output can drift independently from Manifest v12 maps.
- `node_relation` depends on model relation config, so semantic parsing must
  happen before final relation backfill but semantic emission must happen after
  relation resolution.
- Metric dependency recursion and missing/disabled targets need deterministic
  diagnostics before query planning.
- Saved-query `where` and `group_by` dependency handling is not fully resolved
  upstream, so dxt should not invent stronger semantics in the first slice.
- MetricFlow query planning is broader than artifact compatibility and should
  not pull product runtime behavior into Python.
- Cross-database metric execution carries the same null, timestamp, collation,
  decimal, JSON, cost-estimate, spill, and sensitive-data movement risks as the
  broader cross-database planner.

## Stop Conditions

- Stop before implementing product semantic runtime behavior in Python.
- Stop before emitting `semantic_manifest.json` without a pinned schema/oracle
  validation plan.
- Stop before metric query execution if semantic manifest parity is not stable.
- Stop before cross-database metric execution if adapter capability data,
  movement policy, and staging metadata do not exist.
- Stop before mixing parser extraction, semantic resource behavior, selector
  behavior, and metric runtime behavior in one PR.
- Stop before using Fusion-only behavior to override dbt Core-compatible
  artifact output.

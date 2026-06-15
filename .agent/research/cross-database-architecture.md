# Cross-Database Transformation Architecture

## Purpose

DXT should execute transformation models that read from one or more database
engines and produce reliable tables, views, or metric outputs with predictable
cost, correctness, and operational behavior.

The system should support two execution classes:

1. Single-engine execution, where all inputs and outputs live in one adapter and
   the compiled SQL can be pushed down almost entirely.
2. Cross-engine execution, where inputs span adapters and DXT must choose between
   remote pushdown, extracted staging, local joins, or staged joins inside a
   selected destination engine.

The core design principle is to separate logical transformation intent from
physical execution. Models, metrics, and semantic definitions compile into a
logical plan. The planner then chooses a physical plan using adapter
capabilities, catalog statistics, run state, freshness requirements, and explicit
cost controls.

## Goals

- Support multiple named source and destination connections in one project.
- Plan joins, filters, projections, aggregations, and materializations across
  heterogeneous engines.
- Prefer pushdown when it is correct and cheaper, but fall back to
  extract-stage-join when engines cannot interoperate directly.
- Expose adapter contracts that make capabilities, type mappings, SQL dialects,
  copy mechanisms, and transaction behavior explicit.
- Maintain catalog and state metadata needed for incremental models, lineage,
  schema drift detection, semantic metrics, and cost estimation.
- Make data movement visible and controllable before expensive execution.
- Keep execution idempotent and recoverable without requiring distributed
  transactions across databases.

## Non-Goals For The First Architecture Slice

- Full distributed SQL with arbitrary query rewrites across every engine.
- Exactly-once distributed transactions spanning multiple databases.
- Transparent movement of unlimited data without user-visible cost policy.
- Replacing specialized compute engines. DXT orchestrates and plans; adapters and
  optional execution backends do the heavy data work.

## High-Level Components

```text
Project files
  models, sources, semantic definitions, metrics, policies
        |
        v
Parser and compiler
  validates refs, builds logical DAG, emits logical relational plan
        |
        v
Catalog and state service <----> Adapter registry
  schemas, stats, capabilities, freshness, run history, watermarks
        |
        v
Cross-engine planner
  chooses pushdown, stage, local execution, join locality, materialization
        |
        v
Execution coordinator
  schedules tasks, leases locks, manages retries, stages data, commits outputs
        |
        v
Adapters and execution backends
  source databases, warehouses, object storage, local/embedded engine
```

The project compiler must not decide where a query runs. It should emit a
logical plan with enough structure for the planner to choose physical execution:
relations, projections, filters, joins, aggregates, windows, sorts,
materialization targets, dependencies, required freshness, and metric
definitions.

## Multi-Source Connections

Connections should be first-class project resources:

```yaml
connections:
  crm:
    adapter: postgres
    role: source
  billing:
    adapter: mysql
    role: source
  warehouse:
    adapter: snowflake
    role: destination
  lake:
    adapter: object_storage
    role: stage
```

Connection configuration should separate logical names from secrets. Project
files may define adapter type, role, default schema, allowed staging locations,
and cost policy. Secrets should be resolved at runtime from environment,
secret-store, or profile providers.

Each source declaration should bind to a connection:

```yaml
sources:
  crm.customers:
    connection: crm
    relation: public.customers
    primary_key: customer_id
  billing.invoices:
    connection: billing
    relation: finance.invoices
    primary_key: invoice_id
```

Models can then reference multiple sources:

```sql
select
  c.customer_id,
  c.segment,
  sum(i.amount) as lifetime_revenue
from {{ source("crm", "customers") }} c
join {{ source("billing", "invoices") }} i
  on i.customer_id = c.customer_id
group by 1, 2
```

At compile time, DXT should preserve relation identity instead of substituting
raw SQL strings too early. A source reference should carry:

- Connection name.
- Adapter family and dialect.
- Relation identifier.
- Column metadata and logical types.
- Freshness and snapshot policy.
- Statistics, when available.
- Capability constraints, such as "cannot push down regex" or "no lateral join".

## Adapter Model

Adapters are the boundary between DXT's logical plan and physical systems. The
adapter interface should be small but explicit.

### Core Adapter Responsibilities

- Introspection: schemas, columns, primary keys, indexes, partitions, row counts,
  size estimates, freshness metadata, and native object identifiers.
- SQL generation: quote identifiers, render expressions, map logical types,
  render functions, render DDL, and explain unsupported constructs.
- Capability declaration: supported joins, windows, CTE behavior, merge support,
  temporary tables, unload/load formats, transactions, isolation, and native
  federation features.
- Execution: run SQL, stream result batches, create/drop stage relations, load
  batches, unload query results, and fetch query profiles.
- Cost estimation: estimate scan bytes, result bytes, egress cost, query cost,
  load cost, and expected row counts.
- State hooks: begin run, record relation metadata, commit materialization,
  cleanup stale staging objects, and report query IDs.

### Suggested Interface Shape

```text
Adapter
  name()
  dialect()
  capabilities()
  connect(runtime_secrets)
  introspect_relation(relation_ref)
  estimate(logical_subplan)
  render_sql(logical_subplan, target_context)
  execute_sql(sql, options)
  stream_query(sql, batch_size)
  create_stage_relation(schema)
  load_batches(stage_relation, arrow_or_rows)
  unload_to_stage(sql, stage_uri, format)
  begin_transaction()
  commit_transaction()
  rollback_transaction()
  supports_atomic_replace(materialization)
```

Adapters should not implement cross-database planning. They should expose enough
capabilities for the planner to make consistent choices.

### Capability Matrix

Capabilities should be data, not code branches scattered through the planner.
Examples:

```yaml
capabilities:
  sql:
    joins: [inner, left, right, full]
    windows: true
    recursive_cte: false
    merge: true
    create_view: true
    create_table_as: true
  types:
    decimal_max_precision: 38
    timestamp_timezones: true
    json: native
  transactions:
    ddl_transactional: false
    atomic_rename: true
    isolation_levels: [read_committed, repeatable_read]
  movement:
    stream_read: true
    bulk_unload: true
    bulk_load: true
    preferred_formats: [parquet, arrow, csv]
  federation:
    can_query_external_postgres: false
    can_query_external_mysql: false
```

The planner should use this matrix to decide whether a subplan is executable on
an engine and whether additional casts or staging are required.

## Logical Plan And Cross-Engine Query Planning

DXT should plan in phases:

1. Resolve model refs, source refs, semantic entities, and metric definitions.
2. Build a logical relational plan with typed operators.
3. Annotate each leaf relation with connection, catalog stats, freshness, and
   constraints.
4. Split the plan into maximal single-engine subplans.
5. Estimate each feasible physical strategy.
6. Select a strategy using cost policy and correctness constraints.
7. Emit an executable task graph.

### Logical Operators

The planner should model at least:

- `Scan(connection, relation)`
- `Filter(predicate)`
- `Project(expressions)`
- `Aggregate(keys, measures)`
- `Join(left, right, condition, type)`
- `Window(partition, order, frame)`
- `Union`
- `SortLimit`
- `Materialize(target, mode)`

Raw SQL models can still be supported, but they reduce planner visibility. For
raw SQL, DXT should parse enough to identify source refs and conservative
barriers. A model that contains unsupported opaque SQL should be marked as
"adapter-local only" unless the user declares an extract boundary.

### Physical Strategies

For a cross-engine model, the planner should evaluate these strategies.

#### Strategy A: Full Pushdown To One Engine

Use when all referenced relations are accessible from one engine through native
federation, external tables, database links, or co-located schemas.

Benefits:

- Minimal DXT-managed data movement.
- Native optimizer can choose join order.
- Simpler transaction and output commit.

Constraints:

- Requires adapter-declared federation or shared engine context.
- Type mappings and function semantics must be compatible.
- Remote scans may still incur hidden egress or slow query behavior.

#### Strategy B: Pushdown Subplans, Stage Results, Join In Destination

Each source engine performs local filters, projections, and partial aggregates.
DXT unloads reduced result sets to a staging area and loads them into the chosen
destination engine, then executes joins and final materialization there.

Benefits:

- Keeps heavy filtering and aggregation close to data.
- Uses destination engine for final materialized output.
- Easier to make output atomic with destination-specific replace semantics.

Constraints:

- Requires destination bulk load support.
- Requires careful type normalization.
- Data movement can be expensive for high-cardinality intermediate results.

#### Strategy C: Pushdown Subplans, Join In Embedded Execution Backend

Source engines stream reduced result batches into an embedded execution backend,
such as an Arrow-compatible local engine. The backend joins and writes output to
the destination adapter.

Benefits:

- Useful when the destination cannot efficiently load temporary stage tables.
- Good for small to medium cross-source joins.
- Keeps implementation portable for development and test.

Constraints:

- Local memory and disk become execution limits.
- Output commit still depends on destination adapter.
- Not suitable for very large joins unless backed by spill and strict budgets.

#### Strategy D: Extract Raw Inputs, Stage, Then Transform

DXT extracts source tables or partitions into staging with minimal pushdown, then
runs the transformation from staged copies.

Benefits:

- Most general fallback.
- Useful for engines with weak SQL support.
- Enables repeatable replays from captured stage snapshots.

Constraints:

- Highest data movement cost.
- Highest storage and cleanup burden.
- Should usually require explicit policy approval above small thresholds.

### Join Locality Selection

For each join, the planner should estimate:

- Left and right row counts after filters.
- Projected byte size after column pruning.
- Join key cardinality and null rates, if known.
- Whether either side can be broadcast.
- Whether one side is already materialized in a candidate engine.
- Destination materialization target.
- Network egress and load costs.
- User policy, such as "never move PII out of source" or "prefer warehouse".

Simple decision rules for an MVP:

- If both sides are on the same connection, push the join down.
- If one side is below a configured broadcast threshold, move the small side to
  the large side's engine when the large side can host staging.
- If the output target is a warehouse and both sides can be reduced heavily,
  push down reductions and join in the warehouse.
- If neither source can host staging and the estimated result is below local
  execution limits, join in the embedded backend.
- If estimated movement exceeds budget, fail planning with an actionable cost
  report unless the model has explicit override policy.

## Pushdown Rules

DXT should push down operations that reduce data movement and are semantically
safe for the source adapter.

Good pushdown candidates:

- Column pruning.
- Deterministic filters.
- Partition predicates.
- Local joins within one engine.
- Partial aggregates before cross-source joins.
- Deduplication on declared primary keys.
- Incremental watermarks.
- Source-local casts that preserve logical type semantics.

Pushdown barriers:

- UDFs not available in the source engine.
- Non-deterministic functions when semantics differ by engine.
- Collation-sensitive string comparisons across engines.
- Time zone conversions with incompatible behavior.
- Precision-sensitive decimal calculations.
- Opaque raw SQL blocks that cannot be analyzed.
- Policy constraints forbidding movement of raw columns.

When a pushdown is rejected, the planner should record the reason. The final
plan explanation should tell users which operations were pushed down, staged, or
executed locally.

## Extract, Stage, And Join

Staging should be a first-class execution layer, not a side effect. Each staged
dataset needs:

- Stable run-scoped identifier.
- Source relation and source query hash.
- Schema with logical and physical types.
- Row count and byte count.
- Partition metadata, if present.
- Checksums or sample hashes where feasible.
- Retention policy and cleanup status.
- Sensitivity classification.

Preferred stage formats should be columnar and typed. The architecture should
favor Arrow batches in memory and Parquet files for durable stage. CSV should be
a compatibility fallback only.

Staging modes:

- `ephemeral`: deleted after successful run or failed cleanup window.
- `cached`: reusable across runs when source query hash and freshness match.
- `snapshot`: retained as a reproducibility artifact for a declared period.

The execution coordinator should make stage writes idempotent by writing to a
temporary object or relation, validating counts/schema, then marking it ready in
state. Consumers should only read ready stage artifacts.

## State And Catalog Metadata

DXT needs a local or service-backed metadata store. It can start as an embedded
database and later move to a shared service if team scheduling requires it.

### Catalog Tables

Suggested metadata domains:

- `connections`: logical connection name, adapter type, role, policy tags.
- `relations`: source and target relation identifiers, columns, logical types,
  physical types, owners, sensitivity tags.
- `relation_stats`: row counts, byte estimates, freshness, partition summaries,
  histograms or sketches when available.
- `capabilities`: adapter version, dialect features, transaction features,
  movement features.
- `models`: compiled model hash, dependencies, materialization mode, target.
- `semantic_objects`: entities, dimensions, measures, metric definitions,
  grain, join paths.
- `runs`: run ID, project hash, selection, start/end time, status.
- `tasks`: task graph nodes, physical strategy, query IDs, retries, duration.
- `stage_artifacts`: stage URI or relation, schema, row count, byte count,
  retention, cleanup status.
- `watermarks`: per incremental model and per source watermark state.
- `lineage_edges`: source-to-stage, stage-to-model, model-to-metric edges.
- `schema_observations`: detected drift, accepted drift, rejected drift.

### State Rules

- State writes should be append-first. Mutating current status is acceptable, but
  run evidence should be preserved.
- A physical plan should be reproducible from project hash, catalog snapshot,
  adapter versions, policies, and run inputs.
- State should distinguish "compiled successfully", "planned successfully",
  "staged successfully", and "committed output".
- Failed runs should retain enough metadata to clean up orphaned stage artifacts.

## Concurrency And Scheduling

The execution coordinator should schedule a task graph, not a linear list.
Concurrency must be limited by both global resources and per-connection resource
pools.

Concurrency controls:

- Global max concurrent tasks.
- Per-connection max queries.
- Per-connection max streaming readers.
- Per-destination max loaders.
- Per-stage backend bandwidth or object count limits.
- Per-model materialization lock.
- Optional priority classes for interactive metrics vs batch builds.

Backpressure should propagate from adapters. If a source adapter reports rate
limits, lock contention, or warehouse queueing, the coordinator should reduce
parallelism for that connection during the run.

Task types:

- Introspection refresh.
- Source-local subquery execution.
- Unload or stream extract.
- Stage validation.
- Destination load.
- Cross-engine join.
- Final materialization.
- Semantic metric query.
- Cleanup.

For correctness, DXT should prevent two runs from writing the same target
relation at the same time unless the materialization explicitly supports
concurrent partitions. Per-target locks should live in the state store and have
leases so failed processes do not block forever.

## Transactions And Commit Semantics

DXT should not require distributed transactions in the default architecture.
Instead, it should use idempotent tasks, run-scoped staging, validation, and
destination-local atomic commit where available.

### Materialization Commit Pattern

For table materializations:

1. Build output into a run-scoped temporary relation.
2. Validate schema, row counts, constraints, and optional data tests.
3. In a destination-local transaction when available, swap or rename the temp
   relation into the target name.
4. Record committed relation metadata and lineage.
5. Mark old temp and stage artifacts for cleanup.

For incremental materializations:

1. Build a delta relation from source changes.
2. Validate deduplication keys and watermark bounds.
3. Merge, insert-overwrite partitions, or append according to adapter
   capability.
4. Commit new watermark only after destination commit succeeds.

If a destination lacks atomic rename or transactional DDL, DXT should expose a
weaker commit mode in the plan explanation and optionally require explicit
project policy.

### Failure Recovery

DXT should classify failures by phase:

- Before extract: no cleanup beyond task status.
- During staging: remove incomplete stage artifacts.
- After staging before materialization: reusable artifacts may be retained if
  checks pass and policy allows.
- During destination load: drop run-scoped temp relations.
- After destination commit before state update: reconcile by checking target
  relation metadata and query IDs.

The recovery logic should be adapter-aware but coordinated by common run state.

## Incremental Models Across Databases

Incremental cross-database models are harder than single-source models because
each input can advance independently. DXT should model watermarks per source and
per output.

Supported incremental modes:

- `append`: insert new rows based on source watermark.
- `merge`: upsert by unique key.
- `insert_overwrite`: replace affected partitions.
- `snapshot`: detect changed rows using hashes or source change metadata.

For a model with multiple sources, DXT should track:

- Source watermarks used for the last successful output commit.
- Current source watermarks observed at planning time.
- Join dependency windows, such as "invoice changes may require customer rows".
- Late-arriving data tolerance.
- Lookback window per source.
- Unique key and conflict behavior.

Example:

```yaml
models:
  customer_revenue:
    materialized: incremental
    unique_key: customer_id
    incremental_policy:
      sources:
        crm.customers:
          watermark: updated_at
          lookback: 2 days
        billing.invoices:
          watermark: invoice_updated_at
          lookback: 7 days
      join_recompute:
        strategy: affected_keys
        key: customer_id
```

The planner should avoid the naive assumption that only changed fact rows matter.
If dimensions can change, it should recompute affected keys or partitions. For
large models, DXT should support a two-step incremental plan:

1. Build an affected-key set from all changed sources.
2. Recompute output rows for those keys using current source state.

Watermarks should be committed only after the output commit succeeds. On retry,
the run should reuse the previous committed watermark plus the configured
lookback, not the failed run's partial state.

## Semantic Layer And Metrics Flow

The semantic layer should compile through the same planner instead of bypassing
cross-engine rules.

Semantic objects:

- Entities: business keys and relationships.
- Dimensions: attributes with grain and source relation.
- Measures: aggregations with filters and default time dimensions.
- Metrics: measure compositions, ratios, derived calculations, and constraints.
- Join paths: allowed paths between semantic models.

Metrics flow:

1. User requests a metric query with dimensions, filters, time grain, and
   freshness requirement.
2. Semantic compiler resolves entities, measures, join paths, and required
   source relations.
3. Compiler emits a logical plan with metric grain and aggregation rules.
4. Cross-engine planner chooses pushdown and staging strategy.
5. Execution returns result rows or materializes an aggregate table.
6. Catalog records metric lineage, freshness, query cost, and cache eligibility.

Metric planning should prefer aggregate pushdown. For example, if revenue facts
live in one engine and customer dimensions live in another, DXT should aggregate
facts to the join grain before movement when the requested metric allows it.

DXT should also support metric materializations:

- `live`: plan and execute at query time.
- `cached`: reuse a prior metric result within freshness policy.
- `aggregate_table`: build scheduled rollups using the model runner.

Semantic definitions must include grain and join constraints so the planner can
avoid fanout errors. When a requested metric crosses incompatible grains, DXT
should fail validation before execution.

## Data Movement Cost Controls

Cost controls should be part of planning, not logging after the fact.

### Estimates

Before execution, DXT should estimate:

- Source scan bytes.
- Rows and bytes after pushdown filters/projections.
- Stage bytes written.
- Network egress bytes by source and destination.
- Destination load bytes.
- Local spill bytes.
- Query compute cost if adapter can report it.
- Number of stage files or temporary relations.

Estimates should include confidence levels. For unknown stats, DXT should either
sample, run `EXPLAIN`, or mark the estimate as low confidence.

### Policies

Project-level and model-level policies can control movement:

```yaml
policies:
  movement:
    default_max_bytes: 10GB
    require_approval_above: 100GB
    deny_sensitive_columns_to_local: true
    prefer_stage_connection: lake
    allow_cached_stage_reuse: true
```

Policy actions:

- `allow`: run normally.
- `warn`: run but record warning.
- `require_approval`: stop planning unless invoked with explicit approval.
- `deny`: fail planning.

Cost reports should be explainable:

```text
Plan rejected:
  model: customer_revenue
  reason: estimated movement 184GB exceeds policy limit 100GB
  largest movement: billing.invoices projected extract, 171GB
  suggested fixes:
    - add invoice_updated_at filter
    - aggregate invoices by customer_id before join
    - materialize invoices_daily in billing first
```

### Runtime Guards

Estimates can be wrong, so execution needs runtime controls:

- Stop extract when byte or row limits are exceeded.
- Abort local join when spill limit is exceeded.
- Enforce maximum stage object count.
- Cancel source queries exceeding timeout or cost budget.
- Validate that actual movement stays within configured overrun tolerance.

## Validation Scenarios

### Scenario 1: Same-Engine Model

Inputs:

- `orders` and `customers` both on one warehouse connection.

Expected behavior:

- Planner emits one adapter-local SQL query.
- No stage artifacts are created.
- Output uses destination-local atomic table replacement where supported.
- Lineage records both source relations and target relation.

Validation:

- Compare generated SQL against expected dialect rendering.
- Confirm task graph has one execution task plus commit and metadata tasks.
- Confirm cost report shows zero DXT-managed movement.

### Scenario 2: Small Dimension Broadcast

Inputs:

- Large fact table in warehouse.
- Small CRM customer dimension in PostgreSQL.
- Target table in warehouse.

Expected behavior:

- Push down CRM filter/projection.
- Extract customer dimension only.
- Load dimension into warehouse temp table.
- Join fact table and staged dimension inside warehouse.

Validation:

- Planner chooses warehouse join because small side is below broadcast threshold.
- Runtime row count for staged dimension matches source query count.
- Sensitive columns not referenced by the model are not extracted.
- Cleanup removes temp table and stage files after successful commit.

### Scenario 3: Aggregation Before Movement

Inputs:

- Invoice facts in MySQL.
- Account dimensions in warehouse.
- Metric asks for monthly revenue by account segment.

Expected behavior:

- Push down invoice filter and monthly aggregation in MySQL.
- Move aggregated rows, not raw invoices.
- Join aggregated facts to account dimension in warehouse.

Validation:

- Physical plan includes partial aggregate before extract.
- Cost estimate for moved bytes is lower than raw extract estimate.
- Metric result matches a control query on a small fixture dataset.

### Scenario 4: Local Embedded Join Fallback

Inputs:

- Two source engines with no staging support.
- Estimated post-filter result sets below local execution threshold.
- Target is a file or lightweight database.

Expected behavior:

- Stream both reduced subplans to embedded backend.
- Execute join locally with memory and spill limits.
- Write output through destination adapter.

Validation:

- Planner explains why neither source nor destination was selected as join host.
- Runtime guard aborts if actual streamed bytes exceed threshold.
- Retry does not duplicate output rows.

### Scenario 5: Movement Policy Rejection

Inputs:

- Cross-source join requires moving a high-volume table with no filter.
- Policy limit is lower than estimated movement.

Expected behavior:

- Planning fails before execution.
- Error includes estimated movement, largest contributor, and suggested changes.

Validation:

- No source query starts.
- No stage artifacts are created.
- Run state records planning rejection and policy name.

### Scenario 6: Multi-Source Incremental Model

Inputs:

- Changed invoices in billing source.
- Changed customers in CRM source.
- Output is customer-level revenue table.

Expected behavior:

- Planner computes affected customer IDs from both sources.
- Recomputes rows for affected keys using source lookback windows.
- Merges output by `customer_id`.
- Advances both source watermarks only after successful merge.

Validation:

- Late-arriving invoice inside lookback is included.
- Changed customer segment recomputes output even if revenue did not change.
- Failed merge leaves prior watermarks unchanged.

### Scenario 7: Semantic Metric Fanout Protection

Inputs:

- Metric joins account-level measures to user-level dimensions.
- Semantic model lacks a valid grain-preserving join path.

Expected behavior:

- Semantic compiler rejects query before physical planning.
- Error identifies incompatible grains and missing join path.

Validation:

- No source execution occurs.
- Adding an allowed bridge or aggregate definition makes the metric plannable.

### Scenario 8: Transaction Weakness Disclosure

Inputs:

- Destination adapter cannot atomically replace tables.

Expected behavior:

- Plan marks commit mode as non-atomic.
- Project policy decides whether execution is allowed.
- If allowed, DXT uses best-effort temp relation and rename/drop sequence.

Validation:

- Plan explanation includes weaker guarantee.
- Failure during rename can be reconciled by inspecting destination state.

## Risks And Mitigations

### Incorrect Cross-Engine Semantics

Risk:

Different engines handle nulls, collations, decimal precision, timestamps, JSON,
and non-deterministic functions differently.

Mitigation:

- Maintain logical type system and adapter-specific casts.
- Mark unsafe operations as pushdown barriers.
- Add conformance tests per adapter.
- Require explicit user casts for ambiguous semantics.

### Cost Estimate Drift

Risk:

Catalog stats can be stale, causing DXT to select a plan that moves far more
data than expected.

Mitigation:

- Track estimate confidence.
- Refresh stats opportunistically.
- Use runtime row and byte guards.
- Record actual movement to improve future estimates.

### Partial Failure Leaves Orphaned Data

Risk:

Failed runs can leave temp tables, stage files, or partially loaded outputs.

Mitigation:

- Use run-scoped identifiers.
- Record every artifact before it is consumed.
- Make cleanup a task with retry.
- Provide `dxt cleanup --run <id>` and age-based cleanup.

### Adapter Capability Gaps

Risk:

Adapters may claim support for features that differ subtly across versions or
cloud configurations.

Mitigation:

- Version capabilities.
- Validate capabilities during connection checks.
- Record adapter and server versions in run state.
- Add feature probes for critical operations.

### Planner Complexity

Risk:

An overly ambitious optimizer can become hard to explain and debug.

Mitigation:

- Start with deterministic rules and clear plan explanations.
- Keep physical strategies enumerable.
- Add cost-based decisions only after catalog stats are reliable.
- Store rejected alternatives for debugging.

### Security And Governance

Risk:

Cross-database execution can move sensitive columns into less controlled systems.

Mitigation:

- Carry sensitivity tags through logical plans.
- Enforce movement policies before execution.
- Redact secrets from state and logs.
- Support deny rules for local execution or external staging.

### Incremental Correctness

Risk:

Multi-source incremental models can miss updates when dimension changes affect
existing fact rows or when late-arriving data falls outside the window.

Mitigation:

- Track per-source watermarks.
- Support affected-key recompute.
- Require unique keys for merge models.
- Make lookback windows explicit and testable.

### Lock Contention And Run Overlap

Risk:

Concurrent runs can overload source systems or write the same target relation.

Mitigation:

- Use per-connection pools and per-target leases.
- Apply adaptive backpressure on adapter errors.
- Make locks visible in run state.
- Support cancellation and lease expiry.

## Implementation Phases

### Phase 1: Single-Engine Foundation

- Project parser and logical model DAG.
- Adapter interface for one SQL adapter.
- Catalog tables for connections, relations, models, runs, and tasks.
- Adapter-local SQL rendering and table materialization.
- Plan explanation for simple pushdown.

### Phase 2: Multi-Connection Planning

- Multiple connection profiles.
- Source refs carrying connection identity.
- Capability matrix.
- Logical plan splitting into single-engine subplans.
- Rule-based strategy selection.
- Cost report with estimated movement.

### Phase 3: Staging And Cross-Engine Execution

- Stage artifact metadata.
- Stream extract and bulk load adapter methods.
- Pushdown projection/filter/partial aggregate.
- Warehouse-hosted staged joins.
- Local embedded join fallback for bounded data.
- Cleanup and retry behavior.

### Phase 4: Incremental And Semantic Layer

- Per-source watermarks.
- Affected-key incremental planning.
- Semantic entities, dimensions, measures, and metrics.
- Metric query planning through the same logical planner.
- Metric cache and aggregate materializations.

### Phase 5: Cost And Governance Hardening

- Runtime byte and row guards.
- Sensitivity-aware movement policy.
- Adapter feature probes.
- Actual-vs-estimated feedback.
- Plan alternative logging and diagnostics.

## Open Design Decisions

- Whether DXT should embed a default local execution backend from the start or
  require all cross-engine joins to land in a destination engine for the MVP.
- Whether the catalog/state store should be a local embedded database only or
  have an optional server mode from day one.
- How much raw SQL parsing is required before a model is treated as an opaque
  adapter-local block.
- Which stage formats are mandatory for adapter certification.
- Whether semantic metrics should be available before incremental models, or
  built after watermarks and lineage are stable.

## Recommended MVP Shape

The first useful version should implement deterministic rule-based planning with
strong explanations:

- Single-engine pushdown as the fast path.
- Cross-engine join by staging reduced source subplans into the destination
  engine.
- Local embedded join only for explicitly bounded small data.
- No distributed transactions; use destination-local atomic replace when
  available.
- Per-source watermarks for incremental models, with affected-key recompute for
  multi-source joins.
- Semantic metrics compile into the same logical plan and inherit the same cost
  and movement policies.

This gives DXT a concrete path to useful cross-database transformations without
pretending to be a universal distributed database.

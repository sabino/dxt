# Changelog

Notable changes to `dxt` are recorded here. Unreleased entries describe native
implementations and their focused evidence, not a completed release or
universal dbt certification. The initial execution scope is SQL models on
DuckDB and PostgreSQL.

## Unreleased

### Added

- Native DuckDB C API and PostgreSQL libpq adapters with held sessions, typed
  nullable results, DML responses, introspection, cancellation, readonly
  boundaries and connection recovery.
- Dependency workers for mixed seed/model/snapshot/unit/data-test builds,
  physical readiness through ephemeral ancestry, real thread limits,
  fail-fast cancellation, independent continuation and durable blocked rows.
- Native table/view and adapter-specific incremental execution with first,
  repeated and full-refresh runs, unique keys, predicates, schema policies
  and merge column controls; PostgreSQL unlogged/index/materialized-view
  behavior.
- Calendar microbatch orchestration, lookback, event-time/sample input bounds,
  native typed batch timestamps, partial outcomes, batch rollback and retry.
  Stock DuckDB microbatch is an explicit extension to the pinned adapter.
- Native SQL/YAML timestamp/check snapshots on both adapters, including
  updates/deletes/returning rows, metadata configs and schema evolution.
- State-defined DuckDB/PostgreSQL clone view copies with existing-relation,
  full-refresh, no-op/error and real adapter-response behavior.
- DuckDB local external CSV/JSON/Parquet publication/reader views and
  parameterized table-function models; cloud publication/registration remains
  outside the current scope.
- Resource pre/post hooks and project on-run-start/on-run-end operations with
  native contexts, held transactions, rollback and artifact results.
- Native grants and persist-docs execution through bundled adapter dispatch,
  including PostgreSQL role revocation and actual relation/column comments.
  DuckDB grants retain its upstream warning capability.
- Native generic/singular data-test configs, SQL thresholds and persisted
  failure tables/views; dict/CSV/SQL unit fixtures, sparse/empty inputs, typed
  macro/var/env overrides and versioned models.
- Shared native YAML parsing, typed project/profile/env/var handling, complete
  config layering, package overlays, disabled resources, versions and
  groups/access validation.
- Typed Jinja expressions, Unicode/numeric/tuple/container values, filters,
  scoped control/capture/call blocks, macro defaults/kwargs/returns, namespace
  mutation and adapter dispatch.
- Embedded pinned dbt Core/DuckDB/PostgreSQL SQL macros and native
  Relation/Column/timestamp/query-result objects, database queries/statements,
  named results and adapter metadata caches.
- Native Tree-sitter Python resource discovery, static literal metadata and
  dbt scaffold compilation. Authored Python is never evaluated; selected Python
  execution fails before warehouse writes under the initial SQL-only scope.
- Local/Git/registry/tarball dependency installation with transitive resolution,
  safe archives/paths, reproducible lock files, upgrade/offline behavior and
  installed package macro execution.
- Recursive named YAML selectors, defaults/indirect modes, state comparisons,
  Core fresher selection, defer/favor-state/separate state and exact-ID retry.
- Working debug/init/run-operation/retry/clone commands, effective command/env
  flags, warning/logging/output/profiling controls and input sampling.
- Full upstream artifact schema checks for Manifest v12, Run Results v6,
  Catalog v1 and Sources v3, plus semantic-interface validation.
- Embedded dbt docs application, native catalog/freshness execution, static
  offline docs and native HTTP serving.
- Native semantic resources and MetricFlow-style simple/derived/ratio/
  cumulative/conversion planning, join/grain/time checks, saved queries and
  locked transactional exports on supported adapters.
- Native dialect SQL grammars, typed logical IR, column lineage, source
  diagnostics, readonly analysis/explain and dependency-aware cache reuse.
- Governed cross-database plans and execution: named connections, pushdown and
  source reduction, typed broadcast/staged/embedded movement, policy/budget
  guards, retained caches/snapshots, source watermarks, locks, recoverable run
  records and adaptive task/query retries.
- Versioned environment planning/apply, immutable model versions and physical
  reuse, isolated views, UTC interval/backfill accounting, blocking audits,
  promotion and rollback.
- Native persistent parse and relation caches with input-safe invalidation.
  The native parse cache is separate from Core's MessagePack format.
- Deterministic release archives with embedded-source licenses/provenance,
  checksum/architecture/safety checks and actual extracted installation gates
  for both adapters with PATH empty.
- Actual Linux x86_64/ARM full compatibility/install CI configuration, portable
  native PostgreSQL fixtures and browser setup, plus correctness-aware
  cold/warm performance gates.
- GitHub-backed Agent OS coordination, isolated worktree helper workflows and
  public-safe developer restart/handoff tooling.

### Fixed

- Physical ancestors and failing unit/data tests now gate consumers correctly,
  while independent resources continue and earlier completed results remain.
- Built-in generic, singular and unit SQL errors produce sanitized durable
  error rows instead of aborting before result emission.
- Source generic-test IDs hash original metadata/arguments while retaining
  source-prefixed display names, matching pinned Core identities.
- Compiled resource artifacts, relation identities, dependency ordering and
  retry arguments have pinned Core comparisons; compile/docs errors retain
  durable extension results consumable by Core retry.
- Actual option effects replace the previous stored-only threads and ignored
  full-refresh behavior.

### Compatibility And Acceptance

- Comparisons target dbt Core **1.10.5**, dbt-duckdb **1.9.6**, dbt-postgres
  **1.9.1**, MetricFlow **0.208.1** and semantic interfaces **0.9.0**; native
  fixtures pin DuckDB **1.4.2** and Zig **0.16.0**.
- Contract/constraint runtime enforcement, authored custom materializations and
  remaining naming-policy/DuckDB profile initialization are active completion
  work.
- Focused native/CLI/Core/MetricFlow evidence exists across the implemented
  tracks. Final whole-tree/public-project, both-adapter archive, platform and
  performance acceptance remains pending.
- Python, cloud adapters, external cloud publication and newer Core/platform
  targets do not inherit execution certification from the initial SQL scope.
- See [Compatibility](docs/COMPATIBILITY.md) and the
  [roadmap](docs/DBT_REPLACEMENT_ROADMAP.md) for current boundaries and final
  gates. Historical release entries below retain their original scope.

## 0.0.0-pre-alpha

### Added

- Zig product runtime scaffold with `dxt` CLI entrypoint, help, and version
  command.
- Artifact-first parser slices for supported dbt project files, SQL models,
  CSV seeds, sources, exposures, docs blocks, macros, materialization blocks,
  and generic test nodes.
- Deterministic Manifest v12-shaped artifact writer for the supported resource
  subset.
- Selector engine subset for names/FQN, tags, paths, files, packages, resource
  types, materialization config, sources, exposures, wildcards, graph expansion,
  and excludes.
- Render-only compile support for literal and narrow scalar var-backed
  `ref()` / `source()`, literal `doc()`, inline `config()`, selected `target`
  and `this` fields, static string-list `{% set %}`, and simple `{% for %}`
  loops.
- Static macro dependency extraction, macro property parsing, macro argument
  validation support, and project `dispatch:` search-order parsing for literal
  `adapter.dispatch(...)` dependency extraction.
- Narrow `profiles.yml` adapter identity support for adapter type, target
  schema, profile name, target name, and DuckDB database path.
- DuckDB `run` execution for selected SQL models with `table` and `view`
  materializations.
- DuckDB `build` execution for root-project CSV seeds, selected model DAG
  subsets, selected seed/model/test subsets, and supported built-in column
  generic tests.
- DuckDB generic test execution for model column `not_null`, `unique`,
  default-quoted and explicit `quote: false` `accepted_values`, and ref-backed
  `relationships`.
- DuckDB seed column generic test execution for root-project seed column
  `not_null`, `unique`, default-quoted or explicit `quote: false`
  `accepted_values`, and ref-backed `relationships`.
- DuckDB source column generic test execution for source column `not_null`,
  `unique`, default-quoted or explicit `quote: false` `accepted_values`, and
  ref-backed `relationships`.
- DuckDB docs catalog generation for selected existing model, seed, and source
  relations.
- DuckDB source freshness execution with table-level `loaded_at_field`,
  optional freshness filters, table-level `loaded_at_query`, Sources v3-shaped
  success/runtime-error rows, and stale empty/all-null handling.
- Run Results v6-shaped, Catalog v1-shaped, and Sources v3-shaped artifact
  slices for supported execution paths.
- Developer-side public Jaffle Shop DuckDB parse/build gates.
- Developer-side dbt Core oracle harness for supported synthetic M1 fixtures.
- Runtime-boundary and public-safety scan scripts.

### Changed

- `src/project.zig` is treated as a public/orchestration facade in transition,
  with product logic moving toward focused `src/project/*.zig` modules.
- Documentation and planning now require each compatibility slice to name
  upstream dbt Core v1 and relevant Fusion source references.

### Compatibility

- Current compatibility is a documented dbt Core subset, not full dbt Core
  parity.
- Python remains developer-only and does not implement product CLI, parser,
  compiler, artifact writer, runner, planner, adapter, or runtime behavior.

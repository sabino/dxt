# Compatibility Matrix

The initial execution contract is **SQL models on native DuckDB and PostgreSQL**.
The implementation has focused native, CLI, warehouse and upstream comparison
evidence. Final integrated release verification is in progress; an implemented
row below does not establish universal dbt parity.

| Contract | Pinned version |
| --- | --- |
| dbt Core | 1.10.5 |
| dbt-duckdb | 1.9.6 |
| dbt-postgres | 1.9.1 |
| Native DuckDB fixture | 1.4.2 |
| MetricFlow | 0.208.1 |
| dbt semantic interfaces | 0.9.0 |
| Zig toolchain | 0.16.0 |

Other dbt versions, database adapters and operating systems require separate
certification. Python is used for developer oracles and fixtures. Product
loading, compilation, planning, artifacts and execution run through the native
binary; no installed Python/dbt runtime is required.

## Commands And Resources

| Surface | Implemented behavior | Focused evidence |
| --- | --- | --- |
| `parse`, `ls` / `list` | Shared YAML/project/profile/config handling; enabled/disabled resources, package namespaces, model versions, groups/access, selected IDs and Core-style listing. | [Configuration](../tests/test_usability_configuration.py), [groups](../tests/test_usability_groups.py), [CLI options](../tests/test_usability_cli_options.py). |
| `compile` | Typed SQL/Jinja rendering for models, analyses, snapshots and data tests; seeds receive compile results; ephemeral CTEs and database-backed compile contexts are supported. Python models retain source and receive a native-rendered dbt scaffold. | [Jinja](../tests/test_usability_jinja.py), [compile artifacts](../tests/test_usability_compile_artifacts.py), [Python resources](../tests/test_usability_python_models.py). |
| `run`, `build` | Dependency scheduling through physical and ephemeral ancestors; mixed seed/model/snapshot/unit/data-test work; durable errors, blocked skips and independent continuation. | [Scheduler](../tests/test_usability_scheduler.py), [test errors](../tests/test_usability_test_errors.py), [threading](../tests/test_usability_threading.py). |
| `seed` | Native CSV loading, quoting/types, repeat reload, full-refresh and seed display behavior on both adapters. | [CLI execution](../tests/test_usability_cli_execution.py), [adapters](../tests/test_usability_adapters.py). |
| `test` | Built-in and authored generic tests, singular SQL tests, severity/thresholds and persisted failure tables/views. Unit tests use dict/CSV/SQL fixtures, sparse/empty inputs, typed macro/var/env overrides and model versions. Tests use existing relations unless the build graph selects their parents. | [Configuration](../tests/test_usability_configuration.py), [unit fixtures](../tests/test_usability_unit_fixtures.py), [unit metadata](../tests/test_usability_unit_metadata.py), [failure audits](../tests/test_usability_cli_execution.py). |
| `snapshot` | SQL and YAML resources; timestamp/check history, updates/deletes/returning rows, metadata columns, schema evolution and atomic failure behavior on both adapters. | [DuckDB snapshots](../tests/test_usability_snapshots.py), [PostgreSQL snapshots](../tests/test_usability_postgres_snapshots.py). |
| `debug`, `init`, `run-operation` | Real connection checks, buildable DuckDB scaffolding, typed operation arguments, native query/statement execution and durable operation results. Returning SQL text alone does not execute it. | [Commands](../tests/test_usability_commands.py), [adapter context](../src/project/adapter_context.zig). |
| `retry`, `clone` | Restore prior command arguments and exact unsuccessful resource IDs; compile/docs error artifacts can be consumed by Core retry. Clone creates state-defined DuckDB/PostgreSQL view copies, respects existing relations/full-refresh and records no-op/error/success outcomes. | [Commands](../tests/test_usability_commands.py), [compile retry](../tests/test_usability_compile_artifacts.py), [PostgreSQL clone](../tests/test_usability_postgres_clone.py). |
| `deps`, `clean` | Local/Git/registry/tarball dependencies, transitive versions, lock files, offline reinstall and safe package installation. Clean removes protected project-relative generated paths without requiring a profile. | [Dependencies](../tests/test_usability_dependencies.py), [clean implementation](../src/project/clean.zig). |
| `docs generate`, `docs serve` | Embedded dbt docs application, catalog introspection, static offline docs and native HTTP serving. Catalog includes supported relation/column/type/comment/owner metadata. | [Artifacts and browser](../tests/test_usability_artifacts.py), [catalog](../tests/test_usability_catalog.py), [PostgreSQL catalog](../tests/test_usability_configuration.py). |
| `source freshness` | Loaded-at field/query checks, native adapter execution, warning/error criteria and Sources v3 outcomes. Metadata-only freshness is unavailable for the initial adapters and produces a visible error. | [Freshness implementation](../src/project/freshness_runner.zig), [parallel commands](../tests/test_usability_parallel_commands.py), [state/freshness](../tests/test_usability_state.py). |

Python model metadata is collected statically from supported literal
`dbt.ref()`, `dbt.source()`, `dbt.config()` and `dbt.config.get()` calls.
Invalid syntax, dynamic metadata arguments and unsupported literal forms fail
visibly. Authored Python is never imported or evaluated. Selecting a Python
model for `run` or `build` fails before warehouse mutations; execution is
outside the user-confirmed initial SQL scope.

## Configuration, Jinja And Selection

| Surface | Native behavior and evidence |
| --- | --- |
| YAML and configuration | Anchors, merges, flow/block values, typed vars/env values, profile discovery and layered project/package/property/inline config. [YAML](../tests/test_usability_yaml.py), [configuration](../tests/test_usability_configuration.py), [config contract](../tests/test_usability_config_contract.py). |
| Typed Jinja | Scoped control/capture/call blocks, expressions, integer/float/tuple/container identity, Unicode operations, filters, macro defaults/kwargs/returns and dispatch. [Expressions](../tests/test_usability_expression_types.py), [JSON filters](../tests/test_usability_tojson.py), [conditionals](../tests/test_usability_conditionals.py). |
| dbt context | Typed Relation/Column/timestamps; model/config/graph/flags; database queries, named results and native adapter introspection. Pinned bundled Core/adapter SQL macros are embedded with licenses. [Configuration/context](../tests/test_usability_configuration.py), [commands](../tests/test_usability_commands.py). |
| Selectors | Names/FQN, paths/packages/tags/resource/config/version/group/access, wildcards, graph expansion, recursive named YAML selectors and eager/cautious/buildable/empty indirect selection. [State/selector cases](../tests/test_usability_state.py), [versions](../tests/test_usability_configuration.py), [groups](../tests/test_usability_groups.py). |
| State and defer | New/old/modified/unmodified and tested body/config/relation/macro/contract/description comparisons; result statuses, Core `source_status:fresher`, defer/favor-state and separate defer state. [State](../tests/test_usability_state.py). |
| Effective flags | Actual workers/cancellation for threads/fail-fast; adapter-specific full-refresh; empty/sample/event-time input bounds; failure audits; env/CLI precedence, warnings, quiet/print/colors, JSON/file logging and parser/cache/profiling controls. Unsupported command placements/values reject. [CLI options](../tests/test_usability_cli_options.py), [execution](../tests/test_usability_cli_execution.py), [profiling](../tests/test_usability_cli_profiling.py), [parser options](../tests/test_usability_parser_options.py), [worker logs](../tests/test_usability_worker_logs.py). |

Package-heavy compatibility is checked separately from individual macro
features. The unchanged PostgreSQL dbt-utils public project gate is configured;
its final ladder remains pending native regular-expression provider completion
and a fresh run. A bundled macro definition or an accepted flag alone is not
execution parity.

## Adapters And Materializations

DuckDB uses its C API and PostgreSQL uses libpq. Both expose held sessions,
nullable typed results, DML responses, introspection, transactions, cancellation
and recovery. [Adapter tests](../tests/test_usability_adapters.py) exercise real
databases, including cancellation and simultaneous DuckDB writers.

| Materialization | Current execution evidence |
| --- | --- |
| Table/view | First/repeated runs, relation-kind switches and rollback on both adapters. PostgreSQL also supports unlogged tables, indexes and materialized-view policies. [Materializations](../tests/test_usability_materializations.py). |
| Incremental | Adapter-specific append/default/delete+insert/merge paths, composite/null keys, predicates, merge column controls, schema policies and full-refresh. [DuckDB](../tests/test_usability_incremental.py), [PostgreSQL](../tests/test_usability_postgres_incremental.py). |
| Microbatch | Calendar batches/lookback, first/repeated/full-refresh runs, event-time/sample bounds, typed batch context, partial failures, atomic batch rollback and failed-batch retry. [Microbatch](../tests/test_usability_microbatch.py). |
| Seeds/snapshots/clone | Native lifecycles and state relation identities on both adapters, with focused repeated-run and failure fixtures linked above. |
| DuckDB external/table function | Local CSV/JSON/Parquet output, reader views, partitioned publication and parameterized table macros. Cloud publication and plugin registration are outside the current boundary. [File materializations](../tests/test_usability_duckdb_file_materializations.py). |
| Resource/project hooks | Held-session pre/post resource hooks and on-run-start/on-run-end operation discovery/context/results. Transactional hook failures preserve prior relations. [Resource hooks](../tests/test_usability_resource_hooks.py), [global hooks](../tests/test_usability_global_hooks.py). |
| Grants/persist-docs | Native adapter-dispatched privileges/comments, repeat behavior, PostgreSQL role revocation and rollback on invalid roles/comments. DuckDB follows its upstream grants warning capability. [Grants and docs](../tests/test_usability_grants_docs.py). |

Contract/constraint metadata and config precedence are parsed and emitted.
**Runtime contract enforcement, cross-host warning deduplication and authored
custom-materialization execution remain active lifecycle completion work.**
Custom schema/alias/database naming policy closure is also being verified,
including versions, snapshots, seeds, audit relations and warm-cache identity.
DuckDB attach/extensions/settings/secrets initialization is also being completed;
preserved profile options do not yet establish their runtime effects.
Remote DuckLake/MotherDuck and other cloud adapters are not certified targets.

DuckDB requires a native library; PostgreSQL requires libpq and a reachable
database. Library overrides are `DXT_DUCKDB_LIBRARY` and
`DXT_POSTGRES_LIBRARY`. `DXT_DUCKDB_BACKEND=native` requires the native driver.
A legacy DuckDB CLI fallback remains for supported autocommit calls; held
transactions, native analysis and concurrency require the native boundary.
Package transports can require `git`, `curl` and `tar`.

## Artifacts, Caches And Proposed Feature Tracks

| Surface | Implementation and evidence |
| --- | --- |
| Complete dbt schemas | Manifest v12, Run Results v6, Catalog v1 and Sources v3 use the full pinned upstream schema classes. Semantic resources also validate against the semantic-interface contract. [Validator](../scripts/validate_dbt_artifacts.py), [artifacts](../tests/test_usability_artifacts.py), [semantic tests](../tests/test_usability_semantics.py). |
| Results and metadata | Native invocation IDs/timestamps, timings/thread IDs/adapter responses; durable compile/docs and execution outcomes. [Compile artifacts](../tests/test_usability_compile_artifacts.py), [diagnostics](../tests/test_usability_compile_diagnostics.py). |
| Caches | Content-safe whole-graph and unchanged literal-file parse reuse, invocation relation caches and typed SQL-analysis invalidation. `dxt_parse_cache.json` is a native versioned cache, not a claim of Core MessagePack interchange. [Parse cache](../tests/test_usability_parse_cache.py), [relation cache](../tests/test_usability_relation_cache.py), [SQL analysis](../tests/test_usability_sql_analysis.py). |
| Semantic/MetricFlow-style planning | Models/entities/measures/dimensions, simple/derived/ratio/cumulative/conversion metrics, saved queries, join/grain checks, time spines, non-additive dimensions, offsets/windows and locked transactional exports. [Metric planner](../src/project/metric_plan.zig), [semantic/query evidence](../tests/test_usability_semantics.py), [export locks](../tests/test_usability_metric_export_locks.py). |
| Typed SQL analysis | PostgreSQL grammar and DuckDB AST, logical IR, bound columns/types, lineage, source locations, readonly analysis and cache invalidation. [SQL analysis](../src/project/sql_analysis.zig), [evidence](../tests/test_usability_sql_analysis.py). |
| Cross-database execution | Named secret-free plans; same-engine pushdown; source reduction, broadcast/staged/embedded joins; exact typed movement, cost confidence, trust/sensitivity/budget guards, retained caches/snapshots, watermarks, task limits, adaptive retries, locks and recovery. [Cross-database modules](../src/project/cross_database.zig), [evidence](../tests/test_usability_cross_database.py). |
| Versioned environments | Immutable model versions, physical reuse, isolated views, direct/indirect changes, half-open UTC intervals/backfills, audits, promotion and rollback. These are dxt state contracts. [Workflow](../src/project/workflow.zig), [evidence](../tests/test_usability_workflow.py). |

## Explicit Differences

- `source_status:pass/warn/error` are dxt extensions. Core parity uses its
  `source_status:fresher` comparison.
- Durable compilation-error results extend Core behavior where Core exits
  before writing results. Their successful artifact shape and retry
  interoperability are tested separately.
- Stock DuckDB microbatch is a dxt extension; the pinned dbt-duckdb fixture
  uses a custom strategy for the comparable Core batch orchestration.
- Bounded own-time metric offsets cover a documented MetricFlow assertion
  divergence. Upstream-failing cases are not counted as positive parity.
- Native large integer metadata can exceed Core's MessagePack cache range;
  upstream overflow cases are explicit differences.
- Clone/external failure fixtures retain a stronger native rollback guarantee
  in observed upstream transaction/file-publication edge cases. Successful
  rows, ordering and no-op behavior have separate Core comparisons.
- Semantic commands, movement plans and versioned environments use dxt
  artifacts. They do not claim to implement a dbt Fusion or SQLMesh runtime.

## Validation Status

Focused feature gates exercise real native adapters and pinned Core/MetricFlow
outputs, with negative cases and complete applicable schemas. Earlier public
Jaffle parse/list/compile/build/run/docs steps passed. The final integrated
Jaffle rerun, unchanged dbt-utils ladder, full native/pytest suites, both-adapter
archive installation and cold/warm performance reruns are pending acceptance.

Actual Linux x86_64 and ARM full compatibility/install jobs are configured in
[CI](../.github/workflows/ci.yml) and [release](../.github/workflows/release.yml).
Remote ARM results remain pending; cross-compilation is not a substitute for
running the full suite on that architecture. Existing skipped historical
fixtures do not count as parity evidence.

See [the roadmap](DBT_REPLACEMENT_ROADMAP.md) for the remaining gates and
[release process](RELEASES.md) for archive/platform requirements.

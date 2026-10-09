# Roadmap To A dbt Replacement

The Core delivery ladder and proposed feature tracks now have native
implementations and focused compatibility evidence. This document tracks their
coverage and the remaining acceptance work. It does **not** declare the entire
roadmap or release complete before the final integrated gates pass.

The initial release executes **SQL models on DuckDB and PostgreSQL**, as
confirmed for this project. Python resources are discovered, parsed, selected
and compiled without evaluating authored code; execution rejects before
warehouse writes. Additional adapters and platforms require their own drivers
and certification.

[Compatibility](COMPATIBILITY.md) records the support boundary and intentional
differences. [PLAN.md](../PLAN.md) remains the active integration/sequencing
contract.

## Versioned Acceptance Contract

The declared comparison targets are dbt Core **1.10.5**, dbt-duckdb **1.9.6**,
dbt-postgres **1.9.1**, native DuckDB **1.4.2**, MetricFlow **0.208.1** and
semantic interfaces **0.9.0**, built with Zig **0.16.0**.

For each claimed surface, compare unchanged project files, profiles, packages
and command arguments against the pinned upstream implementation. Evidence
must cover resource IDs, dependencies, configuration, compiled SQL, relation
contents/schema, exit codes and pass/warn/fail/error/skipped outcomes.
Normalize only documented volatile metadata such as invocation IDs,
timestamps and timings.

Manifest v12, Run Results v6, Catalog v1 and Sources v3 are validated with the
complete pinned upstream artifact schema classes. Semantic manifests also use
the semantic-interface schema/validator. These are complete schema checks,
rather than the former partial schema slices; schema validity still does not
replace runtime and field-parity comparisons.

Product behavior remains native Zig, with embedded native grammar/data
dependencies where needed. Python is restricted to developer comparisons,
fixtures and release tooling. An accepted flag, preserved configuration value,
empty artifact map or discovered macro is insufficient evidence for execution.

## Core Delivery Ladder

“Implemented” here means native code plus focused evidence exist. The final
integrated release run remains a separate gate.

| Ladder | Current implementation | Evidence and remaining work |
| --- | --- | --- |
| 1. Reliable execution | Physical/ephemeral readiness, mixed seed/model/snapshot/unit/data-test graphs, durable errors/skips, independent continuation, bounded workers, cancellation and transactional replacement. [Scheduler](../src/project/scheduler.zig), [workers](../src/project/concurrent_runner.zig). | [Scheduler fixtures](../tests/test_usability_scheduler.py), [test errors](../tests/test_usability_test_errors.py), [threading/cancellation](../tests/test_usability_threading.py). Final combined suite rerun remains. |
| 2. Parser/configuration | Shared YAML and typed env/vars; layered project/package/property/inline configs; sources, tests, snapshots, versions, groups/access and Python static resources. [Loader](../src/project/loader.zig), [config](../src/project/resource_config.zig), [groups](../src/project/group_access.zig). | [Configuration](../tests/test_usability_configuration.py), [groups](../tests/test_usability_groups.py), [Python resources](../tests/test_usability_python_models.py). Runtime enforcement of declared contracts is tracked in ladder 4. Newer-Core resources require a new version contract. |
| 3. Jinja/macros | Typed expressions/containers, filters/control/capture/call blocks, defaults/kwargs/returns, namespaces/dispatch, bundled macros and database-backed Relation/Column/query contexts. [Compiler](../src/project/compiler.zig), [context](../src/project/dbt_context.zig). | [Jinja](../tests/test_usability_jinja.py), [expression types](../tests/test_usability_expression_types.py), [context](../tests/test_usability_configuration.py). The unchanged public dbt-utils ladder awaits regular-expression provider completion and rerun. |
| 4. Materializations | Table/view, PostgreSQL materialized views, adapter-specific incremental/schema policies, microbatch, seeds, SQL/YAML snapshots, clone and DuckDB local external/table functions; native resource/project hooks, grants and persisted docs. [Lifecycle](../src/project/materialization_runtime.zig), [microbatch](../src/project/microbatch_run.zig), [snapshots](../src/project/snapshot_runner.zig). | [Materializations](../tests/test_usability_materializations.py), [microbatch](../tests/test_usability_microbatch.py), [PostgreSQL snapshots](../tests/test_usability_postgres_snapshots.py), [hooks](../tests/test_usability_resource_hooks.py), [grants/docs](../tests/test_usability_grants_docs.py). Runtime contracts/constraints, warning deduplication and authored custom-materialization execution remain active completion work. |
| 5. Dependencies | Local/Git/registry/tarball declarations, transitive resolution/conflicts, lock files, upgrade/offline behavior, safe installs and executable installed-package macros. [Dependencies](../src/project/dependencies.zig). | [Dependency fixtures](../tests/test_usability_dependencies.py). Actual package-heavy public project validation remains a final gate; live transport availability is distinct from deterministic registry fixture evidence. |
| 6. State/CI workflows | Recursive YAML selectors, defaults/indirect modes, graph/config/version/group/access selectors, state comparisons, result statuses, Core fresher comparison and defer/favor-state/separate-state. [Selection](../src/project/selection_expression.zig), [state](../src/project/state.zig), [defer](../src/project/defer.zig). | [State and selector oracles](../tests/test_usability_state.py), [CLI controls](../tests/test_usability_cli_options.py). Native caches use their own format; no Core MessagePack interchange claim. |
| 7. Commands/integration | Debug/init/operations, snapshots/retry/clone, effective flags/env precedence, structured logs, docs browser/catalog, freshness and native metadata. [Commands](../src/project/commands.zig), [CLI](../src/project/cli_options.zig), [global hooks](../src/project/hook_operations.zig). | [Commands](../tests/test_usability_commands.py), [compile retry](../tests/test_usability_compile_artifacts.py), [CLI](../tests/test_usability_cli_execution.py), [global hooks](../tests/test_usability_global_hooks.py), [docs browser](../tests/test_usability_artifacts.py). Final orchestration/archive run remains. |
| 8. Native adapters | DuckDB C API and libpq sessions, typed results, quoting/introspection, transactions, cancellation, readonly boundaries and recovery. [Adapter](../src/project/adapter.zig), [DuckDB](../src/project/native_duckdb.zig), [PostgreSQL](../src/project/native_postgres.zig). | [Actual driver fixtures](../tests/test_usability_adapters.py). DuckDB attach/extensions/settings/secrets initialization is active completion work. Other adapters and remote DuckLake/MotherDuck remain later certification scope. |
| 9. Release acceptance | Complete artifact validation, actual-platform CI, deterministic archives/notices/checksums, extracted installation with both adapters and PATH empty, browser fixtures and correctness-aware performance budgets. | [CI](../.github/workflows/ci.yml), [release](../.github/workflows/release.yml), [installation](../scripts/check_install.py), [performance](../scripts/check_performance.py). Final integrated/local and remote platform results are pending; no completion claim yet. |

The former immediate correctness queue is implemented: ephemeral ancestry,
built-in/singular/unit SQL error outcomes, mixed unit build gates, effective
threads/full-refresh and snapshot execution all have regression fixtures.
Those historical missing-queue descriptions no longer describe the current
runtime.

## Proposed Feature Tracks

These tracks are implemented dxt capabilities with namespaced commands and
artifacts. Their focused gates are distinct from the remaining release
acceptance run and from certification of another product's entire runtime.

| Track | Native implementation | Observable evidence |
| --- | --- | --- |
| Semantic resources and MetricFlow-style planning | Semantic models/entities/measures/dimensions/metrics/saved queries; simple, derived, ratio, cumulative and conversion SQL; joins/entity grain/fanout checks, time spines, non-additive dimensions, offsets/windows, query execution and locked transactional exports. [Resources](../src/project/semantic.zig), [planner](../src/project/metric_plan.zig), [commands](../src/project/metric_command.zig). | [Core/MetricFlow query and artifact fixtures](../tests/test_usability_semantics.py), [export locks](../tests/test_usability_metric_export_locks.py), including both-adapter and cross-database metric execution. Upstream-assertion edge cases are explicit differences, not positive parity. |
| Typed static analysis | Native PostgreSQL grammar and DuckDB AST, normalized logical IR, warehouse/project binding, types/column lineage, source-location diagnostics, readonly analysis/explain and dependency-aware caches. [Grammar](../src/project/sql_parser.zig), [IR](../src/project/sql_ir.zig), [analysis](../src/project/sql_analysis.zig). | [Positive/negative analysis and invalidation fixtures](../tests/test_usability_sql_analysis.py), complete compiled/executed comparisons and the [performance gate](PERFORMANCE.md). This does not claim dbt Fusion binary compatibility. |
| Cross-database transformation | Named profile-bound connections, logical identity preservation, source reduction and same-engine pushdown, broadcast/staged/embedded execution, typed movement, trust/sensitivity/row/byte/memory/spill/cost guards, retained cache/snapshot stages, source watermarks, task/resource limits, locks and recoverable run records. [Facade](../src/project/cross_database.zig), [execution](../src/project/cross_database_run.zig), [retention](../src/project/cross_database_cache.zig), [scheduler](../src/project/cross_database_schedule.zig). | [Actual DuckDB/PostgreSQL movement fixtures](../tests/test_usability_cross_database.py) cover exact rows/types, early policy denial, rollback/cleanup, idempotent recovery, catalog/cost confidence and adaptive retries of confirmed aborted source transactions. Plans preserve unknown estimates; retries do not assume distributed transactions or replay ambiguous commits. |
| Versioned stateful planning | Immutable model-version fingerprints, physical reuse, isolated environment views, direct/indirect changes, half-open UTC intervals, lookback/backfills, audits, promotion and rollback. [Workflow](../src/project/workflow.zig), [intervals](../src/project/workflow_intervals.zig). | [Warehouse/state fixtures](../tests/test_usability_workflow.py) prove idempotency, environment isolation, interval coverage, blocking audits and rollback. Dxt versions/intervals do not reinterpret Core snapshots or incremental models and do not claim SQLMesh runtime interchange. |

Reference maps remain source/design context:

- [dbt Core and Fusion](../.agent/research/dbt-upstream-reference-map.md)
- [Semantic layer and MetricFlow](../.agent/research/semantic-layer-metricflow-compatibility-map.md)
- [Cross-database architecture](../.agent/research/cross-database-architecture.md)
- [SQLMesh reference](../.agent/research/sqlmesh-future-reference-map.md)

## Remaining Acceptance Work

| Gate | Current status | Required completion evidence |
| --- | --- | --- |
| Lifecycle/identity closure | Runtime contracts/constraints, cross-host warning deduplication, authored custom materializations, custom naming policies and native DuckDB profile initialization are in active implementation. | Actual Core first/repeated/failure cases, parsed/compiled/warm-cache identities, effective configuration and complete artifacts, with no accepted-but-ignored settings. |
| Package-heavy public project | Unchanged PostgreSQL dbt-utils ladder is configured; native regex provider completion is pending after an observed stock `slugify` stop. | Successful unchanged dependency/compile/build/artifact/row ladder against Core. |
| Public Jaffle project | Earlier parse/list/compile/build/run/docs gates passed. | Rerun all six steps on the final integrated tree and retain their outputs. |
| Complete integrated checks | Focused worker and integration gates have passed; final whole-tree reruns remain. | Debug/ReleaseSafe builds, native tests, full pytest with pinned real adapters/browser, complete schema checks, safety/runtime scans and reviewed skips. |
| Installation/archives | Deterministic real archive packaging and extracted native checks have earlier evidence; both-adapter final candidate rerun remains. | Exact archive notices/checksums/architecture verified; debug/build/static docs/rows/artifacts pass after extraction with PATH empty on both adapters. |
| Actual platforms | Linux x86_64/ARM full compatibility and installation jobs are configured; remote ARM acceptance remains pending. | Native execution of the full suite and real archive on each published architecture, including PostgreSQL/browser fixtures. |
| Performance | Earlier correctness-aware cold/warm budget passed. | Final ReleaseSafe rerun compares every compiled model and full artifacts before accepting measured budgets. |
| Publication | Final verified counts, candidate timings and CI links have not yet been recorded. | Document exact candidate versions/scope/results, then publish the reviewed PR and release only through their green-gate workflow. |

Cloud adapters, remote external publication/plugin registration and non-Linux
platforms remain explicit later certification targets. The initial SQL scope
does not authorize or require authored Python execution.

## Completion Rule

Close a feature only when its native implementation, negative cases, pinned
oracle evidence and applicable complete schemas pass. Close the release only
after the integrated public-project, installation, platform and performance
gates also pass. Record remaining differences plainly; one successful adapter,
fixture or accepted argument cannot establish universal replacement parity.

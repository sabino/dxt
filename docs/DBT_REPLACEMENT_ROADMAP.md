# Roadmap To A dbt Replacement

The initial Core delivery ladder and four dxt feature tracks are implemented.
The accepted initial candidate passed integrated, public-project, archive,
performance and actual-platform gates. [Validation](VALIDATION.md) records the
exact source and evidence. This roadmap distinguishes that delivered scope
from production rollout work and later implementation.

> **Prerelease — not production ready.** Initial acceptance is complete for the
> recorded source. Production use still requires validation against your
> workloads, warehouse configuration and operating procedures.

The initial release targets **SQL models on DuckDB and PostgreSQL on Linux
x86_64 and ARM**. Python resources are discovered,
parsed, selected and compiled without evaluating authored code; execution rejects before
warehouse writes. Additional adapters and platforms require their own drivers
and certification.

[Compatibility](COMPATIBILITY.md) records the support boundary and intentional
differences. [PLAN.md](../PLAN.md) remains the active integration/sequencing
contract.

There are **12 functional implementation tracks**: eight Core tracks and the
four dxt feature tracks below. The ninth Core row covers recurring release
acceptance. This is a track count, not a count of individually certified features.

## Remaining Work

| Area | Status | Next work |
| --- | --- | --- |
| Initial Linux SQL scope | Delivered and accepted for the recorded source. | Preserve the complete native, compatibility, public-project, archive and performance gates as changes land. |
| Observed compatibility and operational gaps | The completed track ladder does not cover every behavior within a track. | The [current hardening batch](https://github.com/sabino/dxt/issues/225) covers state comparisons, PostgreSQL profile/session handling, authored incremental strategies and native publication recovery. Follow-ups cover [contract-breaking state diagnostics](https://github.com/sabino/dxt/issues/231), [PostgreSQL connection retries](https://github.com/sabino/dxt/issues/232) and [catalog retention](https://github.com/sabino/dxt/issues/233); these remain unimplemented. |
| Production rollout and operations | Project-specific validation remains. | Exercise representative workloads and warehouse privileges, establish monitoring and failure handling, and rehearse backup, rollback and recovery procedures. Measure concurrency, latency and movement budgets in the intended deployment. |
| Release publication | Candidate-specific process. | Verify the exact source/version, tested archives, checksums and compatibility limits before publishing a release. Acceptance of a source does not publish a version automatically. |
| Snowflake, BigQuery and Redshift | Planned; native drivers and conformance are not implemented. | Add adapter capabilities, native execution and actual warehouse contract tests before claiming support. |
| Remote DuckDB providers | Later scope; local native profile behavior is implemented. | Implement and validate remote DuckLake/MotherDuck and credential-provider integration with real service evidence. Python-dependent profile facilities currently fail visibly. |
| Cloud publication and stage adapters | Later scope; local DuckDB external files and supported local movement are implemented. | Add cloud destination publication, plugin registration and dedicated object-storage/stage adapters with permissions, cleanup and recovery evidence. |
| Additional platforms | macOS and Windows are not supported release targets. | Port Linux-specific discovery, add native dependency packaging and run the complete suite and extracted archives on each actual platform. |
| New upstream versions | Outside the pinned contract. | Follow the [planned upgrade process](TEST_OPTIMIZATION_PLAN.md#12-prepare-repeatable-upstream-release-upgrades): compare accepted/candidate CLI behavior, scope native regressions and repeat applicable certification. |
| Fusion/dbt v2 certification | Separate assessment planned; no certified Fusion oracle. | Map versioned CLI surfaces, adapters and evidence gaps before proposing [bounded certification tasks](TEST_OPTIMIZATION_PLAN.md#13-assess-the-fusion-replacement-boundary). |

Core's free-form model deprecation date parsing is also an
[observed follow-up](https://github.com/sabino/dxt/issues/237); current metadata
evidence covers common ISO forms and their state/cache behavior.

Authored Python execution is outside the initial SQL scope. Static Python
resource support does not create a remaining execution obligation.

## Versioned Acceptance Contract

The declared comparison targets are dbt Core **1.10.5**, dbt-duckdb **1.9.6**,
dbt-postgres **1.9.1**, native DuckDB **1.4.2**, MetricFlow **0.208.1** and
semantic interfaces **0.9.0**, built with Zig **0.16.0**.
Native helper semantics use CPython **3.12** as the canonical reference;
version-specific Core 3.11 differences are documented in the compatibility matrix.

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

“Implemented” means native code and focused evidence exist. Initial integrated
acceptance is recorded separately; later candidates repeat the applicable gates.

| Ladder | Current implementation | Evidence and scope |
| --- | --- | --- |
| 1. Reliable execution | Physical/ephemeral readiness, mixed seed/model/snapshot/unit/data-test graphs, durable errors/skips, independent continuation, bounded workers, cancellation and transactional replacement. [Scheduler](../src/project/scheduler.zig), [workers](../src/project/concurrent_runner.zig). | [Scheduler fixtures](../tests/test_usability_scheduler.py), [test errors](../tests/test_usability_test_errors.py), [threading/cancellation](../tests/test_usability_threading.py). |
| 2. Parser/configuration | Shared YAML and typed env/vars; layered configs, database/schema/alias naming; sources, tests, snapshots, versions, groups/access and Python static resources. [Loader](../src/project/loader.zig), [config](../src/project/resource_config.zig), [naming](../src/project/naming.zig), [groups](../src/project/group_access.zig). | [Configuration](../tests/test_usability_configuration.py), [named identities/cache](../tests/test_usability_naming.py), [groups](../tests/test_usability_groups.py), [Python resources](../tests/test_usability_python_models.py). Executed audit identity/publication, inherited test metadata and configured runtime path/null publication have focused Core evidence. Newer-Core resources require a new version contract. |
| 3. Jinja/macros | Typed expressions/containers, string formatting, restricted native re/datetime/pytz/itertools providers, filters/control/capture/call blocks, defaults/kwargs/returns, namespaces/dispatch, bundled macros and database-backed Relation/Column/query contexts. [Compiler](../src/project/compiler.zig), [context](../src/project/dbt_context.zig), [regex](../src/project/regex_context.zig). | [Jinja](../tests/test_usability_jinja.py), [expression types](../tests/test_usability_expression_types.py), [regex](../tests/test_usability_regex.py), [context](../tests/test_usability_configuration.py). [Formatting](../tests/test_usability_string_format.py), [temporal formats](../tests/test_usability_temporal_format.py), [module providers](../tests/test_usability_modules_provider.py), [lazy iterators](../tests/test_usability_itertools.py), class protocols and literal/receiver identity have focused Core certificates. The unchanged public dbt-utils ladder is a separate candidate acceptance gate. Arbitrary Python execution is outside scope. |
| 4. Materializations | Table/view, enforced contracts/constraints, authored SQL materializations, PostgreSQL materialized views, incremental/schema policies, microbatch, seeds, snapshots, clone and DuckDB local external/table functions; hooks, grants and persisted docs. [Lifecycle](../src/project/materialization_runtime.zig), [custom macros](../src/project/custom_materialization.zig), [microbatch](../src/project/microbatch_run.zig), [snapshots](../src/project/snapshot_runner.zig). | [Materializations](../tests/test_usability_materializations.py), [contracts](../tests/test_usability_contracts.py), [custom macros](../tests/test_usability_custom_materializations.py), [microbatch](../tests/test_usability_microbatch.py), [PostgreSQL snapshots](../tests/test_usability_postgres_snapshots.py), [hooks](../tests/test_usability_resource_hooks.py), [grants/docs](../tests/test_usability_grants_docs.py). Executed data-test helpers/publication, invocation-wide warnings, stock main responses, [microbatch custom lifecycle](../tests/test_usability_microbatch_lifecycle.py), configured path/split publication and builtin-override deprecation have focused actual Core certificates. |
| 5. Dependencies | Local/Git/registry/tarball declarations, transitive resolution/conflicts, lock files, upgrade/offline behavior, safe installs and executable installed-package macros. [Dependencies](../src/project/dependencies.zig). | [Dependency fixtures](../tests/test_usability_dependencies.py). Package-heavy public project validation is a candidate acceptance gate; live transport availability is distinct from deterministic registry fixture evidence. |
| 6. State/CI workflows | Recursive YAML selectors, defaults/indirect modes, graph/config/version/group/access selectors, state comparisons, result statuses, Core fresher comparison and defer/favor-state/separate-state. [Selection](../src/project/selection_expression.zig), [state](../src/project/state.zig), [defer](../src/project/defer.zig). | [State and selector oracles](../tests/test_usability_state.py), [CLI controls](../tests/test_usability_cli_options.py). Native caches use their own format; no Core MessagePack interchange claim. |
| 7. Commands/integration | Debug/init/operations, snapshots/retry/clone, effective flags/env precedence, structured logs, docs browser/catalog, freshness and native metadata. [Commands](../src/project/commands.zig), [CLI](../src/project/cli_options.zig), [global hooks](../src/project/hook_operations.zig). | [Commands](../tests/test_usability_commands.py), [compile retry](../tests/test_usability_compile_artifacts.py), [CLI](../tests/test_usability_cli_execution.py), [global hooks](../tests/test_usability_global_hooks.py), [docs browser](../tests/test_usability_artifacts.py). |
| 8. Native adapters | DuckDB C API and libpq sessions, typed results, quoting/introspection, transactions, cancellation, readonly boundaries and recovery; native DuckDB profile initialization, private settings/secrets, attachments and retry policies. [Adapter](../src/project/adapter.zig), [DuckDB](../src/project/native_duckdb.zig), [PostgreSQL](../src/project/native_postgres.zig), [profiles](../src/project/duckdb_profile.zig). | [Actual driver fixtures](../tests/test_usability_adapters.py), [native profile Core cases](../tests/test_usability_duckdb_profiles.py). Live remote extension/credential-provider availability is separate from local profile evidence; Python-dependent profile facilities fail visibly. Other adapters and remote DuckLake/MotherDuck remain later certification scope. |
| 9. Release acceptance | Complete artifact validation, actual-platform CI, deterministic archives/notices/checksums, extracted installation with both adapters and PATH empty, browser fixtures and correctness-aware performance budgets. | Initial acceptance is recorded in [Validation](VALIDATION.md). Recurring gates are defined in [CI](../.github/workflows/ci.yml), [release](../.github/workflows/release.yml), [installation](../scripts/check_install.py) and [performance](../scripts/check_performance.py). |

The former immediate correctness queue is implemented: ephemeral ancestry,
built-in/singular/unit SQL error outcomes, mixed unit build gates, effective
threads/full-refresh and snapshot execution all have regression fixtures.
Those historical missing-queue descriptions no longer describe the current
runtime.

## dxt Feature Tracks

These tracks are implemented dxt capabilities with namespaced commands and
artifacts. Their focused gates are distinct from candidate release
acceptance and from certification of another product's entire runtime.

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

## Recurring Candidate Acceptance Gates

All of these gates passed for the accepted initial source in
[Validation](VALIDATION.md). They remain requirements for later release claims;
historical counts and timings cannot certify changed source or archives.

| Gate | Required candidate evidence |
| --- | --- |
| Lifecycle and identity | Actual Core first/repeated/failure cases, full executed naming/dependency artifacts, effective configuration and complete schemas, including contracts, authored materializations, tests, paths and microbatch lifecycle. |
| Native contexts | Actual Core values/errors and stage/consumption/alias comparisons on both adapters, including typed cursors, bindings, fetched tables, formatting and restricted module providers under the CPython 3.12 contract. |
| Public package project | The unchanged PostgreSQL dbt-utils dependency/compile/build/artifact/row ladder: seven Native/Core command pairs (14 commands), with full graph/config/dependencies, exact SQL, catalog and typed rows. |
| Public Jaffle project | All six unchanged parse/list/compile/build/run/docs steps with retained outputs. |
| Complete integrated checks | Debug/ReleaseSafe builds, native tests, full pytest with pinned real adapters/browser, complete schemas, safety/runtime scans and zero skipped/xfail cases in canonical reports. |
| Installation and archives | Exact archive notices/checksums/architecture verified; debug/build/static docs/rows/artifacts pass after extraction with PATH empty on both adapters. |
| Actual platforms | Native execution of the complete canonical suite and real archive on every published architecture, including PostgreSQL/browser fixtures. |
| Performance | ReleaseSafe cold/warm measurements with every model's exact compiled SQL and complete artifacts verified per phase; unchanged 70,000-binding seed rows, bindings and artifacts retained. |
| Publication | Accepted reports, exact versions/scope/results and applicable green checks for the published head, followed by review of the exact draft release assets. |

Cloud adapters, remote external publication/plugin registration and non-Linux
platforms remain explicit later certification targets. The initial SQL scope
does not authorize or require authored Python execution.

The unchanged public package's positive ladder uses PostgreSQL. The pinned
dbt-utils integration project does not configure DuckDB; actual Core CLI and
native comparisons reproduce the same DuckDB date-spine binder error and
relation-discovery catalog errors, with identical date-spine SQL and matching
macro dependencies. Retain this shared-negative evidence and the unchanged
fixture. DuckDB's positive public-project ladder is the six Jaffle gates,
alongside the mandatory both-adapter focused compatibility comparisons.

## Completion Rule

Close a feature only when its native implementation, negative cases, pinned
oracle evidence and applicable complete schemas pass. Close the release only
after the integrated public-project, installation, platform and performance
gates also pass. Record remaining differences plainly; one successful adapter,
fixture or accepted argument cannot establish universal replacement parity.

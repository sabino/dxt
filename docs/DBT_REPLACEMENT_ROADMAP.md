# Roadmap To A dbt Replacement

`dxt` is pre-alpha. A successful Jaffle Shop build proves a useful subset; it
does not establish drop-in compatibility. This roadmap turns the remaining dbt
Core work and proposed features into observable release gates. The support
matrix in [COMPATIBILITY.md](COMPATIBILITY.md) describes shipped behavior;
[PLAN.md](../PLAN.md) remains the implementation and sequencing contract.

## Compatibility Contract

A release must name its dbt Core version, artifact versions, adapters and
adapter versions. The snapshot foundation is checked against dbt Core 1.10.5,
dbt-duckdb 1.9.6, and Manifest v12. That fixture-level evidence does not claim
compatibility with every 1.10 feature or newer Core releases. Expand and update
the pinned oracle before advertising a wider version range.

For a claimed project surface, run the same unchanged project, profiles,
packages, selectors and command arguments with dbt and dxt. Compare selected
IDs, dependencies, compiled SQL, relation contents, schema, exit codes,
pass/warn/fail/error/skipped outcomes and artifacts. Normalize only documented
volatile fields such as invocation IDs, timing and generated timestamps.
Validate complete artifacts against the published schemas before claiming
complete artifact compatibility; the existing schema slices remain partial
gates. Performance and binary packaging are separate acceptance gates.

Drop-in support also requires command/flag behavior, environment variables,
logs consumed by integrations, project/profile discovery, package resolution,
and existing orchestration workflows. Accepting an argument is insufficient
when its effect is missing. Unsupported behavior must produce a deterministic
diagnostic before warehouse mutations rather than silently changing results.

## Immediate Correctness Queue

These findings come from the implementation audit, not completed fixes in the
snapshot PR. Address them before widening execution claims.

| Priority | Missing behavior | Owner and regression gate |
| --- | --- | --- |
| P0 | Physical dependency readiness and failure propagation through ephemeral chains. The current run/build helpers skip the immediate ephemeral dependency without checking its selected physical ancestors. | `project.zig` readiness/blocked-descendant helpers and `resolve.zig`; a physical parent whose name sorts after its consumer, multiple ephemeral levels, and parent failure must preserve dependency order and skip affected consumers while allowing independent work. |
| P0 | Runtime-error results for built-in generic and singular tests. Their DuckDB errors can escape before final run-results emission; only the static custom generic-test error path currently records rows. | `duckdb.zig`, `project.zig`, `run_results.zig`; a missing relation and invalid SQL must record error rows, preserve earlier rows, continue independent resources where dbt does, and exit nonzero. |
| P1 | Mixed `build` scheduling with unit tests. Test-only dict-fixture unit tests work, but adding selected seeds/models rejects the selection. | `project.zig`, `unit_test.zig`; unit tests run before their model materialization, failed units block that model and its descendants, rollback leaves target data intact, independent branches continue, and downstream data tests run after successful materialization. |
| P1 | Flag semantics. `--threads` is stored without execution semantics; `build --full-refresh` is accepted and discarded. | `main.zig`, `types.zig`, runner; implement or explicitly reject unsupported values. Verify actual concurrency and first-run/repeated-run/full-refresh relation contents rather than checking argument parsing alone. |
| P1 | Snapshot graph foundation, issue #213. SQL snapshots were undiscovered resources. | `snapshot.zig`, loader, graph, selector, manifest and command preflight; named blocks, multiple resources per file, configured paths, literal configs, disabled nodes, references and Manifest v12 fields. This PR adds read/list support; execution remains gated. |

## Core Delivery Ladder

Each row is a group of small source-grounded PRs, with its own dbt oracle
fixtures. Run independent slices in isolated worktrees; sequence shared
compiler/runner/artifact ownership in PLAN before editing.

| Order | Work to complete | Evidence required to leave the milestone |
| --- | --- | --- |
| 1. Reliable DuckDB execution | Resolve the correctness queue; unify dependency scheduling and cancellation; implement `--threads`, fail-fast, transaction/rollback and relation replacement semantics; finish built-in/custom/singular/unit test error and config behavior. | Mixed seed/model/ephemeral/unit/data-test DAGs match dbt outcomes, ordering constraints and final relations under success, warning, failure, execution error and cancellation. Every selected executed or blocked resource has the correct result row. |
| 2. Parser and configuration | Complete YAML/project/profile/env/var handling and precedence; project/package resource overlays; disabled resources; model versions, groups/access, contracts/constraints, functions where supported by the chosen Core version; full source, analysis, seed, test and snapshot properties. | Unchanged projects parse to equivalent resource sets, dependencies, relation identities and configs. Invalid and unsupported definitions fail deterministically; they are never silently omitted. Full Manifest schema and normalized field comparisons pass for the claimed resource family. |
| 3. Jinja and macro runtime | General expressions, filters, scoped sets/loops and whitespace; parse `execute=false` versus compile/run context; macro calls, return values, namespace/dispatch; bundled dbt macros; `env_var`, `log`, exceptions, `graph`, `model`, flags, selected resources; database-backed `run_query`, statements and adapter introspection. | Package-heavy projects compile and run without changing their SQL or macros. Hidden dependencies and parse/runtime branches match Core. Database-backed Jinja uses the native adapter boundary; Python stays exclusively in developer tooling. |
| 4. Materializations | Incremental first/repeated/full-refresh execution, unique keys, schema changes and supported adapter strategies; finish ephemeral readiness; seed replacement; snapshot timestamp/check strategies, deletes and history; hooks, grants, contracts, persistence and custom materializations. | Repeated runs with inserted/updated/deleted rows and schema changes match dbt tables and history. Failed materializations preserve the documented transaction boundary. Snapshot YAML definitions and newer snapshot configs are included before claiming that version's full snapshot support. |
| 5. Dependencies | Implement `deps` for the declared local/Git/registry dependency surface, transitive resolution, versions, lock files, reproducible installs, package config and executable package macros/tests. | A clean checkout can resolve and build a pinned package-heavy public project. Offline/invalid/conflicting dependency cases fail clearly; installed-package parity does not depend on manually prepared directories. |
| 6. CI workflows | YAML selector unions/intersections/excludes, defaults and indirect-selection modes; remaining selector methods; state modified/old/unmodified and submethods; defer/favor-state/separate defer-state; result statuses and retries. | Baseline/current fixtures select the same IDs and use the same deferred relations as Core. Snapshot/source/unit resources participate correctly. `source_status:fresher` is grounded in Core; current `source_status:pass/warn/error` extensions must not be mistaken for Core parity. |
| 7. Commands and integration | Complete `debug`, `init`, `run-operation`, `snapshot`, `retry`, `clone` and command-specific flags; profiles and environment behavior; docs UI, catalog metadata, source freshness capabilities, structured logging, exit codes and orchestration contracts. | Scripted end-to-end workflows use unchanged dbt-style commands and projects through the declared executable interface. Debug validates real connection readiness; retry/clone and docs/freshness artifacts match their chosen Core/adapter contract. |
| 8. Native adapter contract | Move the DuckDB CLI backend to a native embedded boundary; explicit relation/introspection/type/quoting/transaction/capability APIs; certify Postgres, then each cloud adapter independently. | Adapter contract tests cover DDL, data types, schema changes, tests, freshness, transactions, credentials and query errors. A Postgres fixture ladder passes; unsupported capabilities fail before execution. One adapter's success never implies another's support. |
| 9. Release claim | Complete artifact schema validation and oracle CI, wider pinned public projects, installation and orchestration tests, platform portability, version stamping, diagnostics and performance budgets. | An explicit Core/adapter compatibility manifest accompanies the release. Clean-install smoke tests, binary safety scans and the full compatibility suite pass on each published platform. Unimplemented flags/resources remain visible in the support matrix. |

The milestones overlap only when their dependencies and module ownership are
clear. Package execution depends on the macro engine; state/defer depends on
stable relation identity and artifacts; snapshot execution depends on the
snapshot graph and adapter/materialization contract. A broader adapter must
not bypass the DuckDB correctness gates.

## Proposed Features Beyond Core Parity

These are planned product capabilities, not shipped functionality. Keep dxt
planning/state extensions in namespaced commands and artifacts, preserving
dbt-visible outputs and semantics. Use the existing reference maps as starting
points and pin inspected upstream versions for each implementation slice.

| Track | Implementation sequence | Acceptance gate |
| --- | --- | --- |
| Semantic resources and MetricFlow-style planning | Parse semantic models, entities, measures, dimensions, metrics and saved queries; resolve relation/metric dependencies; emit and validate `semantic_manifest.json`; implement grain/join/fanout checks, simple metrics, then derived/ratio/cumulative/conversion metrics, time spines and saved-query exports. | Normalized semantic artifacts match the declared semantic-interface version. Invalid grain and fanout fail before execution. Single-engine metric queries and time-window edge cases match pinned MetricFlow fixture outputs before cross-engine planning is added. |
| Fusion-style static analysis | Native dialect-aware SQL parser and logical IR; resolved column/type lineage; location-aware diagnostics; incremental parsing/cache invalidation; explain output and performance budgets. | Correct diagnostics on positive and negative fixtures, invalidation after source/macro/config/package changes, equivalent compiled/executed results and measured cold/warm performance. A lexical scanner alone is insufficient evidence for typed SQL analysis. |
| Cross-database transformation | Named secret-free connections and adapter capabilities; preserve logical relation identity; plan pushdown, filter/projection reduction, staging, destination joins and bounded local execution; cost confidence, sensitivity and movement policy; runtime byte/row/spill guards, cleanup and recovery. | Same-engine work causes no dxt-managed movement. A two-engine join has a reviewable plan and correct output. Policy denial occurs before source execution; budget overruns cancel and clean stages; retry is idempotent without assuming distributed transactions. |
| Stateful planning inspired by SQLMesh | Persist namespaced model-version/run-state fingerprints; environment namespaces and physical table reuse; plan/apply explanations; processed interval accounting and backfills; audit gates; promotion/rollback and multi-engine gateways. | Repeated apply is idempotent, changed upstreams invalidate appropriate consumers, interval boundaries and late arrivals are covered, blocking audits prevent promotion and rollback restores the declared environment. These features never reinterpret dbt snapshot resources or change Core incremental behavior. |

Reference maps:

- [dbt Core and Fusion](../.agent/research/dbt-upstream-reference-map.md)
- [Semantic layer and MetricFlow](../.agent/research/semantic-layer-metricflow-compatibility-map.md)
- [Cross-database architecture](../.agent/research/cross-database-architecture.md)
- [SQLMesh future reference](../.agent/research/sqlmesh-future-reference-map.md)

## Completion Rule

Close a gap only when its native implementation, negative cases, dbt oracle
evidence, applicable complete artifact schemas and public fixture gate pass.
Record the supported versions, limitations and validation in the PR and matrix.
Do not mark the entire replacement complete from a read-only resource slice,
a single adapter, empty artifact maps, accepted flags, or architecture notes.

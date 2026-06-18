# SQLMesh Future Reference Map

This note records SQLMesh ideas that are worth evaluating after dxt reaches a
more complete dbt Core compatibility baseline. It is a planning reference, not a
compatibility claim and not a vendoring plan.

dxt remains a Zig product runtime. SQLMesh is Python-based, so any adopted idea
must be redesigned and implemented in Zig, validated against dxt's dbt
compatibility contract, and kept separate from Python test/oracle tooling.

## Source Snapshot

- SQLMesh upstream: `SQLMesh/sqlmesh` default branch `main`, commit `b44fdf6`,
  inspected on 2026-06-18.

Public source references used for this note:

- `README.md`
- `docs/concepts/environments.md`
- `docs/concepts/plans.md`
- `docs/concepts/state.md`
- `docs/concepts/architecture/snapshots.md`
- `docs/concepts/audits.md`
- `docs/guides/incremental_time.md`
- `docs/guides/multi_engine.md`
- `docs/integrations/dbt.md`
- `sqlmesh/core/environment.py`
- `sqlmesh/core/plan/definition.py`
- `sqlmesh/core/config/gateway.py`
- `sqlmesh/core/engine_adapter/base.py`
- `sqlmesh/dbt/loader.py`
- `sqlmesh/dbt/manifest.py`

## Adoption Rules

- Do not delay dbt Core parity work for SQLMesh-inspired behavior.
- Do not import SQLMesh or SQLGlot into the product runtime.
- Do not claim SQLMesh compatibility until dxt can parse, plan, execute, and
  validate a defined SQLMesh fixture surface.
- Do not use SQLMesh "snapshot" terminology for dxt model-version state in a
  way that can be confused with dbt snapshot resources.
- Every future SQLMesh-inspired slice must name upstream SQLMesh files, owning
  dxt Zig modules, affected dbt/dxt artifacts, native Zig tests, integration
  tests, and stop conditions.
- dbt artifact compatibility remains the first external contract. SQLMesh ideas
  may improve dxt architecture, planning, safety, and efficiency only where they
  do not break dbt behavior.

## Concepts Worth Evaluating Later

| SQLMesh concept | Why it matters for dxt | Candidate dxt owner |
| --- | --- | --- |
| Virtual data environments | SQLMesh models development and production environments as isolated namespaces that point at versioned physical model snapshots. This is a strong reference for future dxt state/defer, preview, promotion, and rollback behavior. | Future `src/project/state.zig`, `src/project/environment.zig`, `src/project/planner.zig`, and adapter relation modules. |
| Plan/apply workflow | SQLMesh creates a reviewable plan by diffing local project state against a target environment, classifying direct and indirect changes, identifying missing intervals, and applying only approved changes. dxt should eventually have a non-dbt namespaced plan explanation for cross-database and stateful execution. | Future `src/project/planner.zig`, `src/project/state.zig`, `src/project/runner.zig`, and CLI command modules. |
| Model-version fingerprints and reusable physical tables | SQLMesh snapshots fingerprint model logic plus upstream dependencies and reuse existing physical tables when safe. dxt should evaluate this for parse caches, state/defer, incremental execution, and environment promotion, but should call the dxt concept model-version or run-state fingerprints to avoid ambiguity with dbt snapshot resources. | Future `src/project/state.zig`, `src/project/model_state.zig`, `src/project/cache.zig`, `src/project/manifest.zig`, and adapter relation modules. |
| Interval-aware incremental execution | SQLMesh records processed time intervals and schedules only missing intervals. dxt should use this as a design reference when moving beyond dbt-compatible incremental materialization into efficient native planning. | Future `src/project/incremental.zig`, `src/project/scheduler.zig`, `src/project/run_results.zig`, and adapter modules. |
| Blocking and non-blocking audits | SQLMesh audits run after model execution and can block promotion before invalid data reaches production. dxt can map this concept to dbt tests, source freshness, future semantic checks, and cross-database plan gates. | Future `src/project/audit.zig`, `src/project/runner.zig`, existing generic-test execution, and semantic modules. |
| Multi-engine gateways and virtual layers | SQLMesh separates gateway connections, state connections, test connections, model execution gateways, and shared or gateway-managed virtual layers. This directly informs dxt's cross-database planner and multiple-source connection design. | Future `src/project/adapter.zig`, `src/project/connection.zig`, `src/project/planner.zig`, `src/project/policy.zig`. |
| Engine adapter capability surface | SQLMesh exposes adapter capabilities such as transactions, cloning, catalogs, materialized views, grants, comments, replace-table support, identifier limits, and query tracking. dxt should make these capabilities data-driven before broader adapters land. | Future `src/project/adapter.zig` and `src/project/sql.zig`. |
| dbt project ingestion bridge | SQLMesh has a dbt loader/manifest bridge that uses dbt configuration and profiles while adding SQLMesh state/planning behavior. dxt should study the boundaries, but dxt must keep its dbt parser/compiler/runtime in Zig rather than delegating to dbt libraries. | Existing `src/project/loader.zig`, `src/project/profile.zig`, `src/project/config.zig`, and future dbt-compatibility parser modules. |
| Dialect-aware SQL analysis and transpilation | SQLMesh uses SQLGlot for SQL understanding and dialect translation. dxt should evaluate Zig-native parser/transpiler options or a carefully bounded native IR before making static-analysis promises. | Future `src/project/sql.zig`, `src/project/compiler.zig`, `src/project/planner.zig`. |

## Future Slice Candidates

1. **State artifact model and environment vocabulary**
   - Upstream SQLMesh references: `docs/concepts/state.md`,
     `docs/concepts/environments.md`, `sqlmesh/core/environment.py`.
   - dxt owners: future `src/project/state.zig` and
     `src/project/environment.zig`.
   - Tests: native Zig serialization tests for a dxt-namespaced state artifact;
     Python public-safety tests to ensure no credentials or local paths leak.
   - Stop before implementing environment promotion or changing dbt artifacts.

2. **dbt state/defer bridge with future environment hooks**
   - Upstream SQLMesh references: `docs/concepts/environments.md`,
     `docs/concepts/state.md`, `sqlmesh/core/environment.py`.
   - dbt references: use the dbt upstream reference map's M5 state/defer
     selector and deferred relation references when this slice starts.
   - dxt owners: future `src/project/state.zig`, existing
     `src/project/selector.zig`, and future relation-resolution modules.
   - Tests: Zig tests for state manifest comparison primitives and deferred
     relation lookup; Python dbt-oracle tests for dbt-visible state/defer
     selectors and artifacts.
   - Stop before adding SQLMesh plan/apply UX or dxt-specific environment
     promotion.

3. **Plan explanation skeleton**
   - Upstream SQLMesh references: `docs/concepts/plans.md`,
     `sqlmesh/core/plan/definition.py`.
   - dxt owners: future `src/project/planner.zig` and `src/root.zig`.
   - Tests: Zig tests for direct/indirect graph change summaries using synthetic
     manifests; Python CLI tests for a namespaced dry-run explanation once the
     command exists.
   - Stop before executing stateful plans, prompt workflows, or modifying
     existing `dxt run` / `dxt build` semantics.

4. **Adapter capability matrix**
   - Upstream SQLMesh references: `sqlmesh/core/config/gateway.py`,
     `sqlmesh/core/engine_adapter/base.py`, `docs/guides/multi_engine.md`.
   - dxt owners: future `src/project/adapter.zig`,
     `src/project/connection.zig`, and `src/project/policy.zig`.
   - Tests: native Zig capability parsing/default tests and cross-database
     strategy rejection tests.
   - Stop before adding live non-DuckDB warehouse execution.

5. **Incremental interval bookkeeping design**
   - Upstream SQLMesh references: `docs/guides/incremental_time.md`,
     `docs/concepts/architecture/snapshots.md`, `docs/concepts/state.md`.
   - dxt owners: future `src/project/incremental.zig`,
     `src/project/model_state.zig`, `src/project/state.zig`, and
     `src/project/scheduler.zig`.
   - Tests: Zig interval math tests; Python DuckDB fixture tests only after
     dbt-compatible incremental materialization is already present.
   - Stop before deviating from dbt incremental output parity.

6. **Audit/test gate unification**
   - Upstream SQLMesh references: `docs/concepts/audits.md`,
     `sqlmesh/core/audit/*`.
   - dxt owners: future `src/project/audit.zig`, existing generic-test runner
     paths, and semantic validation modules.
   - Tests: Zig pass/fail classification tests; Python CLI tests for blocking
     behavior when it maps to dbt-compatible tests or dxt-namespaced audits.
   - Stop before inventing dbt artifact fields or changing current generic-test
     result semantics.

## Validation Gates For Any SQLMesh-Inspired Slice

- `zig build`
- `zig build test`
- `pytest -q` when CLI, filesystem, fixture, or artifacts are touched
- `python scripts/check_runtime_boundary.py`
- `python scripts/check_public_safety.py`
- dbt oracle/schema validation when dbt artifacts or behavior are affected
- SQLMesh fixture validation only after dxt explicitly defines a SQLMesh
  compatibility surface

## Current Decision

Keep SQLMesh as a future architecture reference for M7+ state, planner,
cross-database, incremental, environment, and audit design. Do not implement
SQLMesh-specific syntax or behavior until M1/M2/M3 dbt Core command and artifact
parity is materially stronger.

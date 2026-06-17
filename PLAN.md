# dxt ExecPlan

## Name And Product Contract

`dxt` means **Data eXecution & Transformation**.

The product goal is a dbt-project-compatible transformation engine written in Zig. The first promise is compatibility with dbt Core project semantics and artifacts, not a private or unofficial dbt fork. Fusion-era capabilities, semantic resources, metrics, static analysis, and cross-database planning shape the architecture, but dbt Core compatibility is the required base.

Public wording must avoid implying dbt Labs affiliation.

## Hard Runtime Requirement

`dxt` must be implemented as a native Zig product runtime. The pinned initial toolchain is Zig `0.16.0`.

Python may remain only for developer-side scripts, tests, fixture generation, dbt Core oracle harnesses, artifact comparison, schema validation helpers, and public-safety scans. Python must not implement the product CLI, parser, compiler, artifact writer, runner, planner, adapter layer, or user-facing runtime behavior.

Every user-facing command must run through the Zig binary. CI and PR review must reject new Python product-runtime code.

## Objective

Build `dxt` into a practical dbt alternative that can eventually run real public dbt projects, starting with Jaffle Shop variants. It must:

- Build and ship as a fast native Zig binary.
- Parse dbt projects and reproduce graph semantics.
- Compile common dbt SQL/Jinja behavior.
- Execute models, seeds, tests, snapshots, and docs workflows for supported adapters.
- Emit dbt-compatible artifacts such as `manifest.json`, `run_results.json`, `catalog.json`, `sources.json`, and later `semantic_manifest.json`.
- Support semantic models and metrics as first-class graph resources.
- Add efficient cross-database transformation through explicit multi-connection planning, pushdown, staging, and cost controls.
- Maintain public-safe repo hygiene and a PR/review/green-check release workflow.

## Operating Loop

Each development loop must:

1. Read this plan and current repo state.
2. Choose the smallest coherent milestone slice.
3. Use subagents or `codex exec` for independent review, planning, or verification when the slice is large enough.
4. Make scoped edits.
5. Run the fastest relevant verification.
6. Inspect changed files for secrets, local paths, and generated noise.
7. Commit only when the diff is coherent and verified.
8. Open a PR after the remote repository is configured; merge only after green checks and review.

Use local tests and targeted self-checks during implementation. Use subagents or
`codex exec` for planning or specific blockers when they add value, but reserve
second-agent/Codex review for the coherent PR boundary instead of reviewing every
small edit.

Long-running loops must have explicit stop conditions and logs under ignored paths such as `.agent/runs/`.

## Public Safety Rules

- Do not commit local absolute paths, private hostnames, shell history, credentials, API keys, tokens, session transcripts, or private data.
- Keep fixtures synthetic or public and pinned.
- Keep generated targets, caches, logs, package directories, and virtualenvs out of Git.
- Prefer relative paths in docs, tests, and artifacts.
- Before publication, scan package contents for secrets and path leakage.

## Compatibility Definition

`dxt` is compatible with a dbt surface when it can ingest the same relevant project files, accept equivalent command flags, resolve the same graph dependencies, execute equivalent behavior for supported adapters, and emit artifacts that validate against the intended dbt artifact schemas.

Compatibility levels:

- **Read compatibility:** parse project files and resource definitions.
- **Compile compatibility:** render SQL/Jinja with refs, sources, macros, configs, vars, target/profile context, and dispatch.
- **Artifact compatibility:** emit dbt-shaped JSON artifacts.
- **Execution compatibility:** run materializations, tests, seeds, snapshots, docs, and source freshness for supported adapters.
- **Workflow compatibility:** support selectors, packages, state comparison, deferral, retries, and CI patterns.

Version targets must be explicit per release. The initial planning target is the current dbt Core artifact family used by modern Jaffle Shop projects, with schema validation pinned in tests.

## MVP Scope

The first useful version should run local public fixtures through DuckDB and produce inspectable artifacts.

Required MVP commands:

- `dxt parse`
- `dxt ls`
- `dxt compile`
- `dxt run`
- `dxt build`
- `dxt docs generate`

Initial flags:

- `--project-dir`
- `--profiles-dir`
- `--profile`
- `--target`
- `--target-path`
- `--vars`
- `--select`
- `--exclude`
- `--threads`
- `--full-refresh`
- `--output json` for listing and machine-readable inspection

Deferred commands:

- `debug`
- `clean`
- `deps`
- `init`
- `run-operation`
- `snapshot`
- `source freshness`
- `retry`
- `clone`
- `docs serve`

## dbt Core Surface Area

The implementation must account for:

- `dbt_project.yml`, `profiles.yml`, `packages.yml`, `dependencies.yml`, `selectors.yml`.
- `models`, `macros`, `seeds`, `snapshots`, `analyses`, `tests`, `docs`, and package directories.
- `ref`, `source`, `config`, `var`, `env_var`, `doc`, `log`, `exceptions`, `return`, `run_query`, `statement`, `target`, `this`, `graph`, `model`, `flags`, and `selected_resources`.
- Parse-time versus execute-time Jinja behavior.
- Macro namespace resolution, package overrides, and adapter dispatch.
- Resource configs, column properties, tests, tags, meta, groups, access, versions, contracts, disabled nodes, docs blocks, exposures, metrics, and semantic models.
- Materializations: view, table, incremental, ephemeral, seed, test, snapshot, materialized view where supported, and custom materializations later.
- Selectors: names, `+`, `@`, comma intersection, `--exclude`, tags, paths, files, packages, configs, resource types, sources, exposures, states, results, source status, test types, and YAML selectors.
- State/defer: `--state`, `--defer`, `--defer-state`, `--favor-state`, `state:new`, `state:modified`, and result selectors.

## Artifact Requirements

Artifacts are compatibility contracts, not incidental output.

Required:

- `manifest.json`
- `run_results.json`
- `catalog.json`
- `sources.json`

Later:

- `semantic_manifest.json`
- `partial_parse.msgpack` or a separate dxt parse cache
- `dxt_metadata.json` for namespaced data that does not belong in dbt schemas

Rules:

- Validate generated JSON against published schemas where available.
- Normalize nondeterministic fields in parity tests.
- Do not invent dbt field names.
- Keep dxt-specific metadata separate unless the schema explicitly permits it.

## Architecture

Core components:

1. **Project Loader:** reads project, profile, package, selector, and resource files.
2. **Parser:** extracts resources, configs, refs, sources, macros, docs, tests, exposures, and semantic objects.
3. **Manifest Graph:** stores nodes, dependencies, parent/child maps, disabled resources, and selector indexes.
4. **Jinja/Macro Engine:** models dbt parse/compile/run contexts and adapter dispatch.
5. **Compiler:** renders SQL and builds a logical relational plan when possible.
6. **Selector Engine:** evaluates dbt selector syntax against the manifest graph.
7. **Adapter ABI:** handles relation naming, quoting, SQL execution, introspection, transactions, materialization primitives, and capability declarations.
8. **Runner:** schedules DAG tasks, materializations, tests, docs generation, and artifact writes.
9. **State Store:** records runs, task state, watermarks, catalog snapshots, stage artifacts, and lineage.
10. **Cross-Database Planner:** chooses pushdown, staging, embedded execution, destination-hosted joins, and policy outcomes.

All core components above are Zig product-runtime components.

## Cross-Database Execution

Cross-database execution must separate logical transformation intent from physical execution.

Connection resources should be first-class and secret-free in project files. Runtime credentials come from profiles, environment, secret stores, or future providers.

Physical strategies:

- Full pushdown to one engine when federation or shared context supports it.
- Push down filters/projections/aggregates, stage reduced results, and join in the destination engine.
- Stream reduced results into an embedded execution backend for bounded local joins.
- Extract/stage raw inputs only as an explicit fallback with cost approval.

Planner requirements:

- Preserve source relation identity after `ref` and `source` resolution.
- Track adapter capabilities as data.
- Estimate scan bytes, moved bytes, load bytes, local spill, row counts, confidence, and query cost when available.
- Enforce movement policies before execution.
- Enforce runtime byte, row, spill, and object-count guards.
- Carry sensitivity tags through planning and deny unsafe movement.
- Record rejected strategies and plan explanations.

MVP cross-database behavior:

- Single-engine pushdown first.
- Destination-hosted staged joins for reduced subplans.
- Local embedded joins only for explicitly bounded small data.
- No distributed transactions; rely on idempotent tasks and destination-local atomic commit where available.

## Semantic Layer And Metrics

Semantic resources should enter the same graph and planner, not a separate execution path.

Required resource concepts:

- Semantic models
- Entities
- Dimensions
- Measures
- Metrics
- Join paths
- Time grains
- Freshness and cache policy

Initial milestones:

- Parse semantic YAML without losing metadata.
- Emit `semantic_manifest.json` when schema support is added.
- Validate grain and join-path constraints before execution.
- Compile metric queries into logical plans.
- Reuse cross-database pushdown, staging, and movement policy for metric execution.

Semantic query serving and external APIs are later than artifact and local CLI compatibility.

## Adapter Roadmap

1. DuckDB for local public fixtures and deterministic tests.
2. Postgres for server-database semantics, transactions, schemas, and relation introspection.
3. Snowflake, BigQuery, and Redshift after adapter ABI and conformance tests stabilize.
4. Object storage/stage adapter for Parquet/Arrow staging.
5. Optional embedded execution backend for bounded cross-source joins.

Adapter certification must include capability probes and contract tests.

## Validation Harness

Build a compatibility harness that runs dbt Core and `dxt` against the same pinned fixtures into separate target directories.

Compare:

- Parse success and diagnostics.
- Resource counts by type.
- Unique IDs.
- Parent and child maps.
- Selected resource sets.
- Manifest slices.
- Compiled SQL after normalization.
- Run statuses and relation names.
- Row counts and query results for supported adapters.
- Catalog columns and types where adapter differences permit.
- JSON schema validity.

Normalize:

- Invocation IDs.
- Generated timestamps.
- Elapsed times.
- Absolute paths where dbt emits them.
- Adapter response fields known to differ.

## Source-Grounded Compatibility Method

dbt execution remains the artifact and behavior oracle, but future compatibility
slices must also name the upstream source files that define the behavior being
implemented. The public source map lives in
`.agent/research/dbt-upstream-reference-map.md`.

Every compatibility slice must record:

- dbt Core v1 source references and, when relevant, dbt Core v2 / Fusion source
  references.
- The owning dxt Zig module or planned module.
- The dbt artifact maps and pinned schemas affected.
- Native Zig tests for parser, selector, graph, manifest, Jinja, or adapter core
  logic.
- Python/dbt oracle tests for CLI, filesystem fixtures, artifact parity, schema
  validation, and public-safety boundaries.
- Stop conditions that keep mechanical extractions separate from behavior
  changes and prevent Python from crossing into product runtime behavior.

Current vars-backed dependency slice source note:
`.agent/research/m2-vars-ref-source-slice.md` maps upstream dbt Core v1 and
Fusion var/ref/source behavior to the narrow dxt implementation. This slice is
only scalar `var('name')` / `var('name', 'default')` dependency-argument
support for `ref()` and `source()`, not general dbt `var()` compatibility.

Current macro argument validation source note:
`.agent/research/m1-macro-arg-validation-slice.md` maps upstream dbt Core v1
`MacroParser` and `MacroPatchParser` behavior plus Fusion macro patch references
to the narrow dxt implementation. This slice is only
`flags.validate_macro_args` macro signature argument extraction and YAML patch
argument validation/replacement for manifest artifacts, not macro execution,
namespace precedence, adapter dispatch, or Fusion-only default/type behavior.

Current macro namespace search-order source note:
`.agent/research/m1-macro-namespace-search-order-slice.md` maps upstream dbt
Core v1 `MacroNamespace`, dependency-oriented `MacroResolver`, and Fusion macro
namespace registries to dxt's static dependency lookup. This slice is only
current-package, root-project, other-package macro-body fallback, and
graph-present internal `dbt` macro lookup for `depends_on.macros`; macro
execution, adapter dispatch, bundled dbt macros, and materialization lookup
remain separate M2 work.

Current static adapter dispatch dependency source note:
`.agent/research/m2-static-adapter-dispatch-deps.md` maps upstream dbt Core v1
`BaseDatabaseWrapper.dispatch` and Fusion `DispatchObject` behavior to dxt's
static `depends_on.macros` extraction for literal `adapter.dispatch(...)` calls.
This slice records dispatch macro dependencies only. It does not execute
dispatched macros, implement project `dispatch:` config, or run adapters.

Current profile-derived adapter identity source note:
`.agent/research/m2-profile-adapter-dispatch-identity.md` maps upstream dbt Core
v1 profile/target selection, manifest `adapter_type`, and dispatch prefix
behavior plus Fusion `AdapterType` and `get_adapter_prefixes` behavior to dxt's
narrow scalar `profiles.yml` parser. This slice lets parse-time static
`adapter.dispatch(...)` dependency extraction use the selected profile output
`type`, including `redshift -> postgres -> default` and
`databricks -> spark -> default` parent fallbacks. It does not render Jinja in
profiles, validate credentials, read host-global profile locations, implement
project `dispatch:` config, execute macros, or open adapter connections.

Current DuckDB seed build source note:
`.agent/research/m3-duckdb-build-seeds.md` maps upstream dbt Core v1
`SeedParser`, `SeedRunner`, `BuildTask`, `load_agate_table`, and run-results
serialization plus Fusion seed resolution and DuckDB CSV materialization
references to dxt's first seed execution slice. This slice is only root-project
CSV seed-only `dxt build` execution through the Zig DuckDB CLI backend. It does
not add `dxt seed`, `dxt run` seed execution, package seed execution, seed
configs, mixed build DAG scheduling, tests, hooks, grants, docs persistence,
full-refresh semantics, or adapter materialization macro execution.

Current DuckDB generic test execution source note:
`.agent/research/m3-duckdb-generic-tests.md` maps upstream dbt Core v1
`BuildTask`, `TestRunner`, `GenericTest`, and run-result serialization plus
Fusion built-in generic-test macros and test materialization helpers to dxt's
first executable generic-test slice. This slice lets test-only `dxt build`
selections execute selected DuckDB column-level `not_null` and `unique` generic
tests against already-existing attached relations, write `pass`/`fail`
Run Results v6-shaped artifacts, and return exit code `1` on test failure. It
does not add mixed build DAG scheduling, generic macro execution,
`accepted_values`, `relationships`, singular tests, unit tests, source tests,
custom configs, `store_failures`, or package/runtime macro behavior.

Current DuckDB accepted-values generic test execution source note:
`.agent/research/m3-duckdb-accepted-values-generic-tests.md` maps upstream dbt
Core v1 schema generic-test parsing, build/test runner behavior, and
run-results serialization plus Fusion's built-in `accepted_values` SQL macro
and test materialization helpers to dxt's first executable
`accepted_values` slice. This slice lets test-only, model+test, and
seed+model+test `dxt build` selections execute selected DuckDB column-level
`accepted_values` tests with non-empty parsed values, using the dbt built-in
grouped failure-row SQL shape and existing Run Results v6-shaped artifact
behavior. It does not add `relationships`, generic macro execution,
adapter-dispatched test overrides, `quote: false`, singular tests, unit tests,
source tests, custom configs, `store_failures`, or package/runtime macro
behavior.

Current DuckDB relationships generic test execution source note:
`.agent/research/m3-duckdb-relationships-generic-tests.md` maps upstream dbt
Core v1 schema generic-test parsing, build/test runner behavior, and
run-results serialization plus Fusion's built-in `relationships` SQL macro and
test materialization helpers to dxt's first executable `relationships` slice.
This slice lets test-only, model+test, and seed+model+test `dxt build`
selections execute selected DuckDB column-level ref-backed `relationships`
tests when `to` and `field` arguments are present, using the dbt built-in
non-null child left-join failure-row SQL shape and existing Run Results
v6-shaped artifact behavior. It does not add generic macro execution,
adapter-dispatched test overrides, non-ref relationship targets, source tests,
singular tests, unit tests, custom configs, `store_failures`, or
package/runtime macro behavior.

Current DuckDB model and generic-test build source note:
`.agent/research/m3-duckdb-build-model-tests.md` maps upstream dbt Core v1
build runner queue/model/test behavior plus Fusion DAG and run-results
references to dxt's first mixed model+test `build` branch. This slice lets
selected DuckDB `table`/`view` SQL models execute before selected supported
column-level `not_null`/`unique`/`accepted_values`/`relationships` generic
tests, writes one Run Results v6-shaped artifact, and returns exit code `1` on
test failure. It does
not add seed+model or seed+model+test DAG scheduling, wider tests, selector
semantic changes, materialization macro execution, hooks, grants, docs
persistence, catalog introspection, threaded scheduling, or partial/failed model
run-results.

Current DuckDB seed/model/test build DAG source note:
`.agent/research/m3-duckdb-build-seed-model-dag.md` maps upstream dbt Core v1
build queue/seed/model/test behavior plus Fusion DAG and run-results references
to dxt's first selected seed/model dependency-order `build` branch. This slice
lets selected root-project DuckDB CSV seeds execute before selected dependent
DuckDB `table`/`view` SQL models, then executes selected supported column-level
`not_null`/`unique`/`accepted_values`/`relationships` generic tests, writes one
Run Results v6-shaped artifact, and returns exit code `1` on test failure. It
does not add package seeds, wider tests, full dbt queue interleaving,
skip/fail-fast
semantics, materialization macro execution, hooks, grants, docs persistence,
catalog introspection, threaded scheduling, or partial/failed model run-results.

Current project dispatch config source note:
`.agent/research/m2-project-dispatch-config.md` maps upstream dbt Core v1
project `dispatch:` validation, `get_macro_search_order`, and
`BaseDatabaseWrapper.dispatch` package/prefix search order plus Fusion
`DISPATCH_CONFIG` and `MACRO_DISPATCH_ORDER` behavior to dxt's narrow
root-project dispatch config parser. This slice lets static
`adapter.dispatch(...)` dependency extraction honor configured package
`search_order` for a literal namespace. It does not execute dispatched macros,
parse installed-package dispatch as root config, render Jinja in project config,
or run adapters.

Current target schema and `this` compile context source note:
`.agent/research/m2-target-schema-this-compile.md` maps upstream dbt Core v1
profile target context, model `this`, relation-name assignment, and compile
context behavior plus Fusion target-context and compile-context references to
dxt's narrow render-only implementation. This slice lets `compile`, `docs
generate`, and run/build preflight compile selected models with profile-derived
target schema, `target.name`, `target.target_name`, `target.schema`,
`target.type`, `target.profile_name`, `this`, `this.schema`, `this.name`,
`this.table`, and `this.identifier`. It does not implement arbitrary Jinja,
adapter-specific target fields, custom schema/alias/database generation, live
adapter connections, materialization execution, catalog introspection, or
run-results artifacts.

Current inline schema and alias relation source note:
`.agent/research/m2-inline-schema-alias-relations.md` maps upstream dbt Core v1
inline config capture, relation-name assignment, `this`, and runtime `ref`
relation behavior plus Fusion default `generate_schema_name`,
`generate_alias_name`, and relation-component resolution to dxt's narrow
render-only implementation. This slice lets `compile`, `docs generate`, and
run/build preflight render quoted literal inline `config(schema=..., alias=...)`
through dbt's default no-custom-macro relation behavior for `this`, refs to
model nodes, and compiled manifest `relation_name`. It does not implement
project/YAML `schema` or `alias` precedence, custom schema/alias macros,
database/include policy, arbitrary Jinja, live adapter connections,
materialization execution, catalog introspection, or run-results artifacts.

Current DuckDB SQL model run source note:
`.agent/research/m3-duckdb-run-sql-models.md` maps dbt Core v1 Run Results v6
schema and run-result processing plus Fusion run-results structs, task stats,
DuckDB profile `path`, DuckDB table/view SQL primitives, and dbt/Fusion DAG
queue ordering to dxt's first execution slice. This slice lets `dxt run`
execute selected enabled DuckDB SQL models with `table` and `view`
materializations through a Zig-owned external DuckDB CLI backend, write compiled
SQL, `manifest.json`, and a minimal success-only `run_results.json`, and reject
non-model selections, non-DuckDB adapters, and unsupported materializations
explicitly. It does not implement `build` execution, seeds, tests, snapshots,
incremental, ephemeral, hooks, grants, docs persistence, catalog introspection,
failed or partial run-results artifacts, relation staging/backup rename parity,
threaded scheduling, or embedded `libduckdb`.

The next source-grounded M1/M2 slices after macro block variant support are:

1. Extend the render-only artifact boundary to adapter-free docs generation:
   route `dxt docs generate` through the Zig parser graph, apply `--select` and
   `--exclude` to compiled SQL model output, render supported `config`, literal
   `ref`, scalar `var()`-backed `ref`, literal `source`, and scalar
   `var()`-backed `source` calls without executing SQL, write compiled SQL
   under `target/compiled/<package>/...`, emit compile fields only for compiled
   model nodes, write `manifest.json`, and write an empty dbt-shaped
   `catalog.json` until adapter introspection exists. Stop before macro
   execution, materializations, tests, DuckDB connections, non-empty catalog
   introspection, `run_results.json`, or docs serving.
2. Continue M3 execution from the narrow `dxt run` DuckDB SQL-model slice:
   replace the external CLI backend with an embedded adapter ABI or keep the CLI
   isolated behind that ABI, add proper task timing/adapter responses, and then
   extend execution to `build` DAG ordering only after seeds/tests have their own
   source-grounded slices. Stop before mixing adapter packaging, seed loading,
   generic test execution, and DAG scheduling into one PR.
3. Finish macro patch and namespace parity beyond the current macro artifact
   surface: parser-controlled macro argument extraction when the dbt
   `validate_macro_args` behavior is exposed, macro patch validation, macro
   `docs`/`meta` patch fields, duplicate patch diagnostics, and namespace
   precedence, using v1 `MacroParser`, `MacroPatchParser`, and
   `MacroNamespaceBuilder` plus v2 macro resolution and dependency listener
   behavior.
4. Start the M2 parse-time Jinja context boundary with explicit `execute=false`
   semantics, using v1 providers and v2 renderer/dbt namespace interception as
   references.
5. Grow artifact schema coverage only alongside emitted fields, using v1 JSON
   schemas and v2 manifest builder behavior while keeping dxt-specific metadata
   out of dbt schemas.
6. Continue adapter relation identity beyond the current two-part
   profile-schema relation rendering and literal inline schema/alias defaults:
   project/YAML config precedence, database include policy, quoting config,
   adapter-specific target fields, custom schema/alias/database macro
   execution, versioned alias defaults, and source/model relation parity, using
   v1 compile runner/compiler behavior plus v2 adapter core/SQL identity
   references.

## Fixture Ladder

Tier 0 synthetic fixtures:

- One standalone model.
- Two models with `ref`.
- One source and model with `source`.
- YAML properties with columns, descriptions, tags, meta, and tests.
- One macro.
- One docs block and `doc`.
- One exposure.
- One disabled model.
- Custom path config.

Tier 1 DuckDB execution:

- Seeds.
- Table and view models.
- Ephemeral model.
- Generic tests: `unique`, `not_null`, default-quoted `accepted_values`, and
  ref-backed `relationships` are started; wider generic-test config parity
  remains.
- Singular test.
- Simple incremental model.
- Docs generation and catalog introspection.

Tier 2 packages and macros:

- Local package with cross-package `ref`.
- Macro override.
- Adapter dispatch.
- Package-provided generic test.
- Selector YAML.

Tier 3 state/defer:

- Baseline manifest and run results.
- Modified model body.
- Modified config.
- Modified seed.
- New downstream model.
- Deferred upstream relation.

Tier 4 multi-adapter:

- Postgres container fixture.
- Parse/compile-only cloud profile fixtures.
- Optional live warehouse smoke tests gated by environment variables.

Public fixtures:

- `dbt-labs/jaffle_shop_duckdb`
- `dbt-labs/jaffle-shop`
- `dbt-labs/jaffle-shop-classic`
- `dbt-labs/dbt-learn-demo`
- `gmyrianthous/dbt-dummy`
- Pinned projects from public dbt project indexes after review.

## Milestones

### M0: Repository Baseline

Deliverables:

- Public-safe README, plan, agent rules, security policy, and ignore rules.
- Minimal Zig package skeleton and native CLI entrypoint.
- Minimal tests and local verification command.
- Initial commit and remote setup.

Exit criteria:

- `zig build` passes.
- `zig build test` passes.
- Native CLI smoke tests pass.
- Developer-side `pytest` passes while Python utility tests remain.
- No committed local paths or secrets.
- `PLAN.md` exists and is current.

### M1: Artifact-First Parser

Deliverables:

- Project loader.
- YAML config/property parser.
- SQL/Jinja dependency extractor.
- Graph builder.
- Basic selector engine for names, tags, paths, resource types, `+`, and `--exclude`.
- `manifest.json` writer.
- dbt oracle tests for Tier 0.

Exit criteria:

- Tier 0 fixtures pass.
- Jaffle Shop DuckDB parses.
- Manifest validates against pinned schema slices.

### M1A: Architecture And Test Structure Hardening

Purpose:

- Shrink `src/project.zig` from a mega-file into a thin public/orchestration facade while preserving dbt Core behavior.
- Keep runtime behavior Zig-first and keep Python as integration, compatibility, schema, fixture, and safety tooling only.
- Build a clearer testing pyramid so core parser/selector/graph/manifest logic has fast native Zig coverage and fixture-heavy/dbt-oracle behavior stays in pytest.

Target module layout:

```text
src/
  main.zig
  root.zig
  project.zig
  project/
    types.zig
    util.zig
    config.zig
    fs.zig
    loader.zig
    parse.zig
    jinja.zig
    resolve.zig
    selector.zig
    manifest.zig
```

Staged extraction order:

1. Extract `src/project/types.zig` for `Runtime`, `Options`, graph/resource/config structs, and data-model deinit helpers.
2. Extract selector parsing, wildcard matching, resource matching, and graph expansion into `src/project/selector.zig`, carrying selector Zig tests with the module.
3. Extract selected-resource JSON and `manifest.json` writers into `src/project/manifest.zig`, carrying JSON escaping and deterministic ordering tests with the module.
4. Extract shared path/string/YAML scalar/sort/hash helpers into `src/project/util.zig` only when at least two modules need them.
5. Extract config, filesystem discovery, loader orchestration, resource parsing, Jinja scanning, and dependency resolution in that order, keeping imports acyclic: `types`/`util` first, then `jinja`/`parse`/`selector`/`manifest`, then `loader` and the `project.zig` facade.

Validation gates:

- After each mechanical extraction: `zig fmt --check` on touched Zig files and `zig build test`.
- When CLI, artifact shape, fixtures, selectors, or manifests are touched: `pytest -q tests/test_cli.py`.
- Before merging an architecture slice: `zig build`, `zig build test`, `pytest -q`, `python scripts/check_runtime_boundary.py`, `python scripts/check_public_safety.py`, and `git diff --check`.

Risk and rollback notes:

- Zig file-level privacy can force temporary `pub` exposure across internal modules. Prefer internal module imports over re-exporting from `root.zig`; only public API should be exposed by `root.zig`.
- Keep extraction commits behavior-preserving. If a move requires semantic changes, stop and split the behavior change into a separate feature slice with dbt oracle evidence.
- Avoid import cycles by moving shared helpers downward into `types` or `util`, never upward into `loader` or `project.zig`.
- Roll back a failed extraction by reverting the extraction commit rather than editing unrelated parser or selector behavior.

Stop conditions:

- Stop after any extraction if `zig build test` fails for a reason that is not a direct import/privacy fix.
- Stop before further extraction if the diff mixes mechanical moves with behavior changes that need dbt Core oracle review.
- Stop before pushing if the worktree contains generated targets, logs, caches, local paths, secrets, or unrelated changes.

### M2: Compiler And Macro Core

Deliverables:

- Jinja environment.
- dbt context functions.
- Macro registry and namespace resolution.
- Basic adapter dispatch.
- Ephemeral CTE injection.
- Compiled SQL outputs.

Exit criteria:

- Tier 0 and Tier 1 compile-only cases pass.
- Compiled SQL matches dbt on supported fixtures after normalization.

### M3: DuckDB Execution MVP

Deliverables:

- DuckDB adapter.
- Seed loading.
- Table/view materializations.
- Generic tests.
- DAG scheduler.
- `run_results.json`.
- Minimal `catalog.json` and `docs generate`.

Exit criteria:

- Jaffle Shop DuckDB runs through `build` and `docs generate`.
- Row counts, tests, and core artifacts match expected baselines.

### M4: Packages And Custom Macros

Deliverables:

- Package loader.
- Local/Git/dbt Hub dependency strategy.
- Lock handling.
- Dispatch config.
- Package-provided tests and macros.

Exit criteria:

- Tier 2 fixtures pass.
- At least one package-heavy public project parses and compiles.

### M5: Selectors, State, And Defer

Deliverables:

- Full selector methods.
- YAML selectors.
- State manifest comparison.
- Result selectors.
- Deferred relation resolution.
- `--defer-state` and `--favor-state`.

Exit criteria:

- Tier 3 fixtures pass against dbt oracle output.
- CI-style selection commands match dbt selected sets.

### M6: Snapshots, Incremental Matrix, And Postgres

Deliverables:

- Snapshot strategies.
- Incremental strategy matrix.
- Source freshness and `sources.json`.
- Unit tests.
- Postgres adapter.
- Adapter contract suite.

Exit criteria:

- Tier 4 Postgres fixture passes.
- Adapter certification suite is required for new adapters.

### M7: Cross-Database Planner

Deliverables:

- Multiple named connections.
- Adapter capability matrix.
- Logical plan splitting.
- Rule-based physical strategy selection.
- Staging metadata.
- Destination-hosted staged joins.
- Cost report and movement policies.

Exit criteria:

- Same-engine plans produce no dxt-managed movement.
- Small dimension broadcast scenario passes.
- Movement policy rejection fails before source execution.

### M8: Semantic Artifacts And Metric Planning

Deliverables:

- Semantic YAML parser.
- Semantic manifest emitter.
- Grain and join-path validation.
- Metric query logical plans.
- Metric materialization through the runner.

Exit criteria:

- Semantic fixtures validate.
- Metric fanout errors fail before execution.
- Simple metrics execute through DuckDB and cross-database planner where supported.

### M9: Fusion-Style Static Analysis

Deliverables:

- SQL parser-backed logical IR for supported dialects.
- Static diagnostics.
- Plan explanation.
- Incremental parse cache.
- Performance budgets.

Exit criteria:

- Parse/compile performance is measured against dbt Core on medium fixtures.
- Diagnostics are stable and location-aware.

### M10: Public Release Discipline

Deliverables:

- GitHub repository under `sabino/dxt`.
- Branch protection and required checks.
- CI for lint, tests, package, and secret/path scans.
- Release packaging.
- Changelog and versioning policy.

Exit criteria:

- PRs merge only after green checks and review.
- Release artifacts install and run smoke tests.
- Package scans show no secrets or local paths.

## Risks

- Jinja semantic drift.
- Macro dispatch complexity.
- Artifact schema fidelity.
- State/defer correctness.
- Adapter-specific behavior leaking into the compiler.
- Incremental and snapshot correctness.
- Package resolution and locks.
- Profile rendering and credential safety.
- Partial parsing invalidation.
- dbt version drift.
- Fusion feature ambiguity.
- Test ID and selector edge cases.
- Catalog differences by adapter and permissions.
- Cross-engine semantic differences for nulls, timestamps, collations, decimals, JSON, and nondeterministic functions.
- Data movement cost estimate drift.
- Partial failures leaving stage artifacts or temp relations.
- Sensitive data movement across trust boundaries.

## Current Status

- M0 is complete as the Zig `0.16.0` runtime scaffold.
- M1 has started on stacked branches with native Zig artifact-first parser slices.
- M1A has started with behavior-preserving `src/project/types.zig`, `src/project/selector.zig`, `src/project/manifest.zig`, `src/project/util.zig`, `src/project/config.zig`, `src/project/fs.zig`, `src/project/jinja.zig`, `src/project/resolve.zig`, `src/project/parse.zig`, and `src/project/loader.zig` extractions. `src/project/manifest.zig` owns selected-resource JSON and partial `manifest.json` writing with native tests for selected JSON shape, JSON escaping, exposure dependency ordering, disabled-resource filtering, graph-map output, and macro `supported_languages` emission. `src/project/util.zig` owns shared display, membership, append-dedup, string sorting, and narrow YAML scalar/list helpers. `src/project/config.zig` owns `dbt_project.yml` loading, project path/docs config parsing, narrow scalar top-level `vars` parsing, CLI `--vars` scalar map parsing, and applying parsed project path/docs configs to graph nodes. `src/project/fs.zig` owns deterministic resource file discovery, Linux directory traversal helpers, and resource path/name helpers. `src/project/jinja.zig` owns lexical Jinja call, parenthesis, quoted string, literal and var-backed argument helpers, supported model SQL scanning, inline config/tag parsing, and known macro-call scanning with native tests. `src/project/resolve.zig` owns graph lookup/count helpers, canonical graph resource ordering, duplicate resource validation, macro unique-id package extraction, low-level ref/source resolution helpers, and dependency-map mutation for refs, sources, and known macro dependencies. `src/project/parse.zig` owns narrow parser scalar helpers for YAML booleans, JSON-compatible scalar classification, source YAML table parsing, exposure YAML resource parsing, current top-level `{% macro %}`, `{% test %}`, `{% data_test %}`, and `{% materialization %}` block parsing, materialization `supported_languages` parsing, macro property YAML parsing, generic-test YAML item names, generic-test definition construction/cloning, generic-test relationship target ref parsing, exposure dependency parsing, exposure meta parsing, macro-property application, and generic-test identity/name/hash helpers with native tests. `src/project/loader.zig` owns graph loading order, target-path lookup, project/package resource traversal, root project and CLI vars application, macro/property application sequencing, duplicate checks, and graph sorting while using explicit callbacks into parser helpers that still live in the facade. `src/project.zig` remains the public parser/list facade and still owns docs block parsing, YAML model property parsing, model/seed parsing, generic-test materialization, warnings, and some resolver orchestration until follow-up extractions move those pieces behind focused internal modules.
- CI format validation now covers every tracked Zig source file under `src/`, including extracted `src/project/*.zig` modules, so M1A module splits remain under the same formatting gate as the root CLI files.
- `dxt parse` now targets the supported Tier 0 subset: project name/model paths/seed paths/macro paths, target path, narrow top-level scalar project `vars`, CLI `--vars` scalar overrides, project and package model path configs for literal `+materialized`, `+tags`, and model/seed `+docs.node_color`, root-project model config overrides for installed packages, SQL model discovery, CSV seed discovery, installed package SQL model and CSV seed discovery from `dbt_packages`, source discovery, installed package source discovery, exposure discovery, installed package exposure discovery, project macro discovery, dbt-shaped generic test macro and materialization macro block discovery, installed package macro discovery from `dbt_packages`, macro property YAML for project macro descriptions, arguments, `docs`, and scalar JSON-compatible `meta`, project and package docs block discovery, literal and narrow scalar `var('name')` / `var('name', 'default')`-backed `ref` to models or seeds, two-argument package refs, package-local refs in installed package models and exposures, unique installed-package fallback for unqualified refs, literal and narrow scalar `var('name')` / `var('name', 'default')`-backed `source`, package-local sources in installed package models, unique installed-package fallback for unqualified sources, literal `doc` in project and package descriptions, inline `config(materialized=..., tags=...)`, known project/package-qualified/package-local macro call dependencies, narrow project and package YAML model properties for scalar descriptions, simple columns, tags, materialization, disabled SQL models, dbt-shaped `unique`, `not_null`, `accepted_values`, and `relationships` generic test nodes, model/test `refs` and `sources` artifact fields, dependency maps, and deterministic partial `manifest.json`. The manifest includes the v12 top-level maps needed by the M1 artifact shape and is covered by a pinned local dbt Manifest v12 schema slice. YAML generic test arguments are currently supported for scalar values plus inline and block lists required by public Jaffle Shop DuckDB-style tests. Full dbt `var()` semantics remain explicitly deferred until the parse/compile Jinja context work covers package scoping, `vars.yml`, non-string values, rendered var values, `has_var`, missing-var parse/runtime behavior, project/profile rendering, and partial-parse invalidation.
- `dxt ls` now lists dbt-selectable resources from the same parser graph, including scalar project/CLI var-resolved dependency edges, with stable text/JSON output and basic name/FQN wildcards, tag wildcards, slash-aware `path:` wildcards, exact `package:`/`package:this`, `source:` wildcards including package-qualified source selectors, `exposure:` wildcards, `resource_type:`, `test_type:generic`, config materialization, comma intersection, whitespace union, multi-argument selector lists, repeated selector flags, leading/trailing `+` graph expansion, and exact exclude filters; macros are emitted in artifacts but not exposed as `ls` resources.
- `dxt compile` has started as a render-only M2 boundary for the current graph subset. It loads and resolves the same Zig parser graph, applies `--select` and `--exclude`, compiles selected enabled SQL model nodes, writes compiled SQL under `target/compiled/<package>/...`, and emits `compiled`, `compiled_code`, `compiled_path`, `relation_name`, `extra_ctes`, and `extra_ctes_injected` only for compiled model nodes. The current compiler renders `config` to empty text, literal or narrow scalar var-backed `ref`/`source` calls to deterministic quoted relation names, profile-derived `target.*`, current-model `this`, and quoted literal inline `config(schema=..., alias=...)` as default dbt relation schema/identifier components without opening a database connection.
- `dxt docs generate` has started as an adapter-free docs artifact boundary. It loads and resolves the same Zig parser graph, applies `--select` and `--exclude` to compiled model output, writes compiled SQL, writes `manifest.json`, and writes an empty dbt-shaped `catalog.json` because adapter relation introspection is not implemented yet. Macro execution, materializations, tests, profiles-derived relation identity, adapters, `run_results.json`, non-empty `catalog.json`, and `docs serve` remain out of scope.
- `dxt run` has started the M3 DuckDB execution path for selected enabled SQL models. It loads and resolves the same Zig parser graph, applies supported selectors/excludes, compiles selected SQL models, validates that selected models use only `table` or `view` materializations before opening DuckDB, executes selected models in dependency order through a Zig-owned external DuckDB CLI backend, writes compiled SQL, writes `manifest.json`, and writes a minimal dbt-shaped success-only `run_results.json` v6 slice after completed runs. It supports default `target/dxt.duckdb` output plus scalar DuckDB profile `path` resolved relative to the loaded `profiles.yml` directory as a deterministic dxt-local path-base choice for this first CLI-backed slice. It does not execute seeds, tests, snapshots, incremental, ephemeral, hooks, grants, docs persistence, catalog introspection, failure/partial run-results artifacts, relation staging/backup rename parity, threaded scheduling, `:memory:`, MotherDuck, or embedded `libduckdb`.
- `dxt build` has started the M3 DuckDB execution path for root-project CSV seed-only selections, selected DuckDB SQL models with `table` and `view` materializations, selected root-project seed+model builds, selected seed+model+supported-generic-test builds, selected model+generic-test builds without seeds, and test-only selected DuckDB column-level `not_null`/`unique` generic tests. It loads and resolves the same Zig parser graph, applies supported selectors/excludes, writes `manifest.json`, loads seeds through the Zig-owned DuckDB CLI backend, executes selected seed/model nodes in dependency order for selected seed/model dependencies, executes supported generic tests against built or already-existing attached relations, writes a minimal dbt-shaped `run_results.json` v6 slice, and returns exit code `1` when any selected generic test fails. Package seeds, seed configs, wider generic tests, singular tests, unit tests, source tests, custom test configs, hooks, grants, docs persistence, full-refresh semantics, `store_failures`, full dbt queue interleaving, skip/fail-fast semantics, partial/failed model run-results, and adapter materialization macro execution remain explicit boundaries.
- Synthetic fixtures cover one model, model refs, seed refs, source refs, narrow scalar var-backed model/source refs with CLI overrides and positional string defaults, exposure refs to models and sources, combined source/model YAML, inline config/tag selection, config materialization selection, comma-intersection selection, YAML model properties and columns, emitted `unique`, `not_null`, `accepted_values`, and `relationships` generic test nodes, project macro artifacts, macro block variants, macro materialization `supported_languages`, and macro properties including patched `docs` and `meta`, configured `macro-paths` replacing the default macro directory, installed package macros with package-qualified calls and package-local macro calls, installed package models, seeds, sources, docs, exposures, package YAML model properties, root package config overrides, and package-qualified/package-local refs/sources, macro calls recorded in model and macro `depends_on.macros`, docs blocks with literal `doc` descriptions, disabled models, disabled ref diagnostics, unmatched model-property warnings, duplicate model and docs diagnostics, unsupported dynamic doc diagnostics, unresolved var diagnostics for var-backed refs without scalar/default values, missing doc diagnostics, malformed docs block diagnostics, unresolved package macro diagnostics, and unsupported unknown macro-call diagnostics.
- The committed M1 public Jaffle gate lives in `scripts/check_jaffle_shop_duckdb_parse.py`. It clones a pinned public Jaffle Shop DuckDB ref into a temporary directory by default, runs the Zig `dxt` binary, validates the current M1 manifest schema slice, asserts the supported partial manifest shape with five SQL models, three CSV seeds, two docs blocks, twenty supported generic test nodes, model/test `refs` artifact fields, dependency maps, materialization/docs config, and checks representative `dxt ls` selector behavior for resource types, materialization config, wildcards, path selectors, and graph expansion. It is a developer-side Python compatibility harness only; product parse/list behavior remains implemented in Zig. Remaining M1 work includes package-provided generic tests/macros beyond the current narrow macro call surface and deeper Jaffle artifact parity.
- Selector wildcard behavior is currently pinned to observed dbt Core 1.10 behavior. dbt Fusion preview currently differs for resource-type-prefixed wildcard selectors such as `model.<package>.*` and filename-suffix path selectors such as `path:*orders.sql`; a future Fusion-compatibility slice must decide whether to support a selector dialect switch or a compatible superset.
- Compatibility planning now uses a source-grounded reference map under `.agent/research/dbt-upstream-reference-map.md`; future feature slices should name upstream dbt v1/v2 source references, dxt Zig owners, affected artifact fields, validation gates, and stop conditions before implementation.
- The committed dbt Core M1 oracle harness lives in `scripts/check_dbt_core_m1_oracle.py`. It is optional developer-side Python tooling that requires `dbt-core` and `dbt-duckdb`, invokes dbt Core through its Python runner, runs `dxt parse` through the Zig binary, and compares stable manifest slices for the supported synthetic M1 fixture ladder. It ignores dbt internal package docs/macros that are outside the current dxt artifact scope, records a known allowed gap for installed-package exposure refs that dbt Core resolves to a root same-name model while dxt currently resolves package-local, and leaves full source-map parity, full artifact schemas, and execution parity for later slices.
- Before broadening M2 product implementation, close or explicitly re-scope the remaining M1 macro-compatibility behavior gaps. Macro `docs`/`meta` patch fields are covered for the current scalar artifact subset. Macro argument extraction under dbt Core v1 `flags.validate_macro_args` semantics and YAML patch argument validation/replacement are implemented for the manifest artifact surface. Static macro dependency lookup now uses the supported dbt order of current package, root project, other-package fallback for macro bodies, graph-present internal `dbt` macros, and literal `adapter.dispatch(...)` dependency extraction. Parse-time dispatch prefixes now come from a narrow source-grounded `profiles.yml` adapter identity parser and emit manifest `metadata.adapter_type`, with default DuckDB behavior preserved when no profile file is loaded. Root-project `dispatch:` config search order is now honored for static `adapter.dispatch(...)` dependency extraction. Macro execution, bundled dbt internal macros, full target context, credential validation, and materialization runtime lookup remain planned. `{% data_test %}` has native source-grounded parser coverage, but the local dbt Core 1.10 oracle rejects that tag before writing artifacts, so dbt-oracle coverage currently pins `{% test %}` and `{% materialization %}` block parity.

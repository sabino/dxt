# dxt ExecPlan

## Name And Product Contract

`dxt` means **Data eXecution & Transformation**.

The product goal is a dbt-project-compatible transformation engine written in Zig. The first promise is compatibility with dbt Core project semantics and artifacts, not a private or unofficial dbt fork. Fusion-era capabilities, semantic resources, metrics, static analysis, and cross-database planning shape the architecture, but dbt Core compatibility is the required base.

Public wording must avoid implying dbt Labs affiliation.

## Hard Runtime Requirement

`dxt` must be implemented as a native Zig product runtime. The pinned initial toolchain is Zig `0.16.0`.

Python may remain only for developer-side scripts, tests, fixture generation, dbt Core oracle harnesses, artifact comparison, schema validation helpers, and public-safety scans. Python must not implement the product CLI, parser, compiler, artifact writer, runner, planner, adapter layer, or user-facing runtime behavior.

Every user-facing command must run through the Zig binary. CI and local safety checks must reject new Python product-runtime code.

## Objective

Build `dxt` into a practical dbt alternative that can eventually run real public dbt projects, starting with Jaffle Shop variants. It must:

- Build and ship as a fast native Zig binary.
- Parse dbt projects and reproduce graph semantics.
- Compile common dbt SQL/Jinja behavior.
- Execute models, seeds, tests, snapshots, and docs workflows for supported adapters.
- Emit dbt-compatible artifacts such as `manifest.json`, `run_results.json`, `catalog.json`, `sources.json`, and later `semantic_manifest.json`.
- Support semantic models and metrics as first-class graph resources.
- Add efficient cross-database transformation through explicit multi-connection planning, pushdown, staging, and cost controls.
- Maintain public-safe repo hygiene and a PR/green-check release workflow.

## Operating Loop

Each development loop must:

1. Read this plan and current repo state.
2. Choose the smallest coherent milestone slice.
3. Use subagents or `codex exec` for planning, focused research, or blocker investigation when they add clear value. Do not run mandatory second-agent reviews unless explicitly requested.
4. Make scoped edits.
5. Run the fastest relevant verification.
6. Inspect changed files for secrets, local paths, and generated noise.
7. Commit only when the diff is coherent and verified.
8. Open a PR after the remote repository is configured; merge after green required checks.

Use local tests and targeted self-checks during implementation. Use subagents or
`codex exec` for planning or specific blockers when they add value, but do not
make second-agent/Codex review a required PR gate unless the active workflow
explicitly asks for it.

Concurrent implementation must use isolated git worktrees. Each active editing
Codex instance owns one branch and one worktree, records disposable local notes
under `.agent/runs/`, keeps durable sequencing changes in `PLAN.md`, and
converges by opening a focused PR. Branches should start from `origin/main`
unless explicitly stacked. Overlapping file ownership must be planned before
implementation. The canonical workflow is `docs/MULTI_AGENT_WORKFLOW.md`.
When work spans several roles, branches, issues, or review specialties, use the
GitHub-backed Agent OS in `docs/AGENT_OS.md`, `docs/AGENT_PROTOCOLS.md`, and
`docs/GITHUB_PROJECTS.md`. GitHub Issues/Projects hold public coordination
state; `PLAN.md` remains the sequencing and risk source of truth.
For unattended local execution, use `scripts/agent_os_orchestrator.py` to claim
ready GitHub issues, create isolated worktrees, launch `codex exec` workers with
the configured profile/model, record ignored run state, and optionally merge
green PRs. Issues are the durable queue; the orchestrator is the local engine.
Project-scoped Codex subagent configuration lives in `.codex/config.toml` and
`.codex/agents/*.toml`; keep these repo-specific settings out of global Codex
configuration.
When project-scoped Codex settings change and a fresh process is required, use
`scripts/codex_pull_plug.py` for detached/noninteractive handoffs, or
`scripts/codex_tmux_supervisor.py` when Codex must be restarted in the same
visible terminal pane. The tmux path is two-phase: request first, then mark the
request ready only after the current agent finishes the coherent slice and is
safe to exit. Neither path may create competing workers for the same dirty
branch or issue.

Local validation should stay focused while CI carries the broader matrix:
native Zig tests for touched core logic, targeted pytest for changed
CLI/artifact behavior, runtime-boundary and public-safety scans before PR, then
GitHub CI for the full Python integration matrix and public fixture gates.

Long-running loops must have explicit stop conditions and logs under ignored paths such as `.agent/runs/`.

## Documentation And Release Automation

Durable public documentation now has a dedicated home under `docs/`:

- `docs/PRIMER.md` explains the product contract, runtime boundary, source-grounded compatibility loop, and validation layers.
- `docs/COMPATIBILITY.md` is the current support matrix for commands, flags, resources, Jinja, selectors, artifacts, adapters, and validation.
- `docs/ARCHITECTURE.md` records the Zig module ownership map and Mermaid diagrams for runtime, parse/artifact, execution, and future cross-database planning.
- `docs/AGENT_OS.md`, `docs/AGENT_PROTOCOLS.md`, and `docs/GITHUB_PROJECTS.md` record the GitHub-backed multidisciplinary agent operating model, issue/PR communication protocol, and project bootstrap rules.
- `docs/MULTI_AGENT_WORKFLOW.md` records the concurrent Codex/worktree workflow, project-scoped agent roles, autonomous local orchestration, validation expectations, and PR convergence rules.
- `docs/RELEASES.md` documents the GitHub release process and native binary artifact policy.
- `CHANGELOG.md` tracks shipped pre-alpha slices and should be updated for every coherent PR that changes user-visible behavior, compatibility scope, docs, release automation, or safety rules.

Keep `README.md` as a concise front door. Keep active sequencing, risks, stop
conditions, and milestone status in this ExecPlan. Promote stable conclusions
from `.agent/research/` into docs when they become durable public behavior.

GitHub release automation lives in `.github/workflows/release.yml`. Tagged
`v*.*.*` releases build `ReleaseSafe` native Zig binaries for the initial Linux
target matrix, package public docs, generate checksums, and create a draft
GitHub Release. Release jobs must keep running public-safety and runtime-boundary
checks before upload, block tag/version mismatches, validate packaged archive
shape and binary/doc string safety with `scripts/check_release_archive.py`, and
avoid macOS or Windows artifacts until the Linux-specific filesystem discovery
code is portable.

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
- `dxt clean`
- `dxt compile`
- `dxt run`
- `dxt seed`
- `dxt test`
- `dxt build`
- `dxt docs generate`
- `dxt docs serve`
- `dxt source freshness`

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
- `deps`
- `init`
- `run-operation`
- `snapshot`
- `retry`
- `clone`

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

Current semantic layer source note:
`.agent/research/semantic-layer-metricflow-compatibility-map.md` maps dbt Core
v1, Fusion, dbt Semantic Interfaces, and MetricFlow references to dxt's future
semantic slices. The recommended sequence is first-class manifest resource maps,
model-attached semantic models plus simple metrics, metric dependency
resolution, saved-query parsing, `semantic_manifest.json` emission, selector
support, and only then metric query planning/execution through Zig-owned planner
modules.

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

Immediate source-grounded queue, refreshed on 2026-06-17 in
`.agent/research/dbt-upstream-reference-map.md`:

1. Selector parity for remaining `file:` edge cases and wider
   selector/listing parity.
2. Parse/compile `execute` boundary and static `{% if %}` handling.
3. Read-only unit-test artifact parsing for newer Jaffle-style projects.
4. Broader source config parity beyond resolved relation identity:
   project-level source config, metadata freshness, and source-status selectors.
5. Command-surface hardening for `ls`, `compile`, `run`, `build`, and
   `docs generate` against the current public fixture ladder.

Each item must remain a Zig product-runtime slice with native tests first and
Python/dbt oracle coverage only for CLI, filesystem, fixture, or artifact
parity.

## Future SQLMesh Reference Track

After the dbt Core M1/M2/M3 baseline is materially stronger, evaluate SQLMesh
as an architecture reference for dxt's state store, environment model,
plan/apply explanations, interval-aware incremental execution, audits,
multi-engine gateways, adapter capability matrix, and cross-database planner.
The public planning note lives in
`.agent/research/sqlmesh-future-reference-map.md`.

This is not an active compatibility target and must not replace dbt Core/Fusion
source-grounded work. SQLMesh is useful as a design reference once dxt needs
stateful planning and multi-engine efficiency, but any adopted behavior must be
reimplemented in Zig, validated through dxt-owned tests, and namespaced unless
it is part of dbt compatibility. Avoid using SQLMesh-style "snapshot"
terminology for dxt model-version state in a way that can be confused with dbt
snapshot resources.

Future SQLMesh-inspired slices must record:

- SQLMesh upstream source/doc references and inspected commit.
- The owning dxt Zig module or planned module.
- Whether the behavior affects dbt artifacts, dxt namespaced artifacts, or only
  planner internals.
- Native Zig tests for state, planner, adapter capability, interval, audit, or
  graph logic.
- Python integration/oracle tests only for CLI, filesystem, fixture, artifact,
  or safety validation.
- Stop conditions that prevent SQLMesh-style planning from changing current dbt
  command semantics prematurely.

Current vars-backed dependency slice source note:
`.agent/research/m2-vars-ref-source-slice.md` maps upstream dbt Core v1 and
Fusion var/ref/source behavior to the narrow dxt implementation. This slice is
only scalar `var('name')` / `var('name', 'default')` dependency-argument
support for `ref()` and `source()`, not general dbt `var()` compatibility.

Current source config/freshness inheritance source note:
`.agent/research/m2-source-config-freshness-inheritance.md` maps upstream dbt
Core v1 source parser/load behavior and Fusion source resolution helpers to
dxt's source/table YAML `config:` inheritance slice. This slice resolves
literal and narrow `{{ target.schema }}` source schemas, source/table
`loaded_at_field`, `loaded_at_query`, dbt-shaped freshness inheritance,
`freshness: null`, root-project `dbt_project.yml` project-level `sources:`
configs for the same supported relation/freshness subset, and expanded
Manifest v12-shaped source fields. Source table `identifier` support is
documented separately in
`.agent/research/m2-source-table-identifier.md`. It does not implement general
Jinja in source properties, metadata freshness, source-status selectors,
installed-package project source config application, or non-DuckDB source
freshness execution.

Current source table identifier source note:
`.agent/research/m2-source-table-identifier.md` maps dbt Core v1 source
parsing and Fusion source resolution behavior to dxt's table-level
`identifier` slice. Logical source `name` remains the unique-id, selector,
FQN, and dependency key, while optional `identifier` controls physical
relation rendering for `source()` compilation, Manifest source `identifier`
and `relation_name`, DuckDB source catalog lookup, source freshness SQL, and
source generic-test SQL. Source/table database and database/schema/identifier
quoting are now covered by the source relation identity slice. It does not
implement metadata freshness or general Jinja rendering in source properties.

Current file selector source note:
`.agent/research/m2-file-selector-parity.md` maps dbt Core v1
`FileSelectorMethod` and Fusion path/selector references to dxt's first
`file:` selector slice. This slice matches selectable resource
`original_file_path` basenames and stems for `ls` and all commands that reuse
the common selector engine. Remaining selector gaps include YAML selectors,
state/result/source-status selectors, path normalization, richer `ls` output
formats, and fnmatch escaping beyond literal `[` through `[[]`.

Current depth-limited plus selector source note:
`.agent/research/m2-depth-limited-plus-selectors.md` maps dbt Core v1
selector regex and graph-neighbor depth handling plus Fusion selector depth
serialization to dxt's first bounded parent/child selector expansion slice.
This slice supports CLI validation and selector matching for `1+model`,
`model+1`, and `1+model+1` while preserving existing unlimited `+model`,
`model+`, and `+model+` behavior. It does not implement YAML selectors,
state/result/source-status selectors, indirect-selection flags, or richer `ls`
output formats.

Current `@` selector source note:
`.agent/research/m2-at-graph-selector.md` maps dbt Core v1
`select_childrens_parents` and Fusion `childrens_parents` selector references
to dxt's first `@` graph expansion slice. This slice supports CLI validation
and selector matching for `@model`-style terms, selecting descendants plus the
parents needed for those descendants in the supported graph subset. It does not
implement YAML selectors, state/result/source-status selectors, indirect
selection flags, or richer `ls` output formats.

Current YAML selector and state/defer roadmap source note:
`.agent/research/m2-yaml-selectors-state-defer-roadmap.md` maps dbt Core v1
`selectors.yml`, `--selector`, `--state`, result/source-status selectors, and
defer flags plus Fusion selector/state references to dxt ownership boundaries
and a staged implementation sequence. The current implemented selector slices
support root-project `selectors.yml` entries whose `definition` is a scalar
string or a narrow composition of supported selector leaves through `union`,
`intersection`, and `exclude`, then lower `--selector <name>` to the existing
Zig selector and exclude expressions for commands sharing the selector engine.
They do not implement method: selector references, default selectors,
indirect-selection overrides, package/config YAML method broadening,
state/result/source-status matching, state artifact loading, or deferral
semantics.

Current `ls` output formats source note:
`.agent/research/m2-ls-output-formats.md` maps dbt Core v1 `ListTask` output
generators and CLI `--output` choices to dxt's first richer listing output
slice. This slice supports dbt-style `name`, `path`, and `selector` outputs
alongside the existing legacy `text` unique-id output and existing JSON shape.
That slice did not implement `--output-keys`, metrics, semantic models, saved
queries, unit tests, or full dbt JSON object parity.

Current `ls --output-keys` source note:
`.agent/research/m2-ls-output-keys.md` maps dbt Core v1 `ListTask.generate_json`
and CLI `output_keys` behavior to dxt's narrow compact JSON field filter. This
slice supports `unique_id`, `resource_type`, and `name` keys for existing
selected-resource JSON output. It does not implement full dbt node JSON parity,
nested keys, metrics, semantic models, saved queries, unit tests, or additional
selected-resource JSON fields.

Current `ls --output-keys` resource-field source note:
`.agent/research/m2-ls-output-keys-resource-fields.md` maps dbt Core v1
`ListTask.generate_json`, path/name/selector generators, CLI `output_keys`
docs, and unit coverage to dxt's compact selected-resource field expansion.
This slice adds dbt-grounded `package_name`, source-only `source_name`, `path`,
and `original_file_path` keys plus `selector` as a dxt compact selected-resource
extension based on the existing selector output mode, while keeping unknown-key
skipping, repeated-key de-duplication, and requested key order. It does not
implement full dbt node JSON parity, nested keys such as
`config.materialized`, relation/config fields, metrics, semantic models, saved
queries, state/result/source-status selectors, or additional resource types.
Local dbt Core 1.10.15 still filters `output_keys` as top-level node fields;
upstream `1.latest` source has nested-key traversal here, so nested key support
became a separately scoped pinned-version compatibility slice for compact
config keys.

Current `ls --output-keys` compact config-field source note:
`.agent/research/m2-ls-output-keys-config-fields.md` maps upstream dbt Core
v1 `ListTask._get_nested_value`, `ListTask.generate_json`, CLI
`--output-keys` documentation, and nested-key unit coverage to dxt's narrow
compact selected-resource support for flat output keys `config.materialized`
and `config.tags`. This slice carries existing Zig-parsed materialization and
tag config from selected graph resources into compact JSON output while
preserving unknown-key skipping, duplicate-key de-duplication, and requested
key order. It does not implement full dbt node JSON parity, arbitrary nested
key traversal, `config.meta`, relation fields, metrics, semantic models, saved
queries, state/result/source-status selectors, or additional resource types.

Current `ls --output-keys` identity-field source note:
`.agent/research/m2-ls-output-keys-identity-fields.md` maps upstream dbt Core
v1 `ListTask.generate_json`, selected-node serialization, and CLI
`--output-keys` documentation to dxt's compact support for `alias` on
model/seed/test resources and source-only `identifier`. This slice exposes
already-parsed default and inline model aliases plus source physical
identifiers in selected-resource JSON while preserving missing-key omission for
resource types that do not carry those fields. It does not implement full dbt
node JSON parity, `fqn`, relation fields, database/schema fields, arbitrary
nested traversal, metrics, semantic models, saved queries, or state/result
selectors.

Current `ls --output-keys` dependency/config-key source note:
`.agent/research/m2-ls-output-keys-depends-config.md` maps upstream dbt Core
v1 `ListTask.ALLOWED_KEYS`, `_get_nested_value`, `generate_json`, and nested-key
unit coverage to dxt's compact support for `tags`, `config.enabled`,
`config.docs.show`, `depends_on.nodes`, and `depends_on.macros`. This slice
exposes already-resolved Zig graph tags and dependency arrays without changing
dxt's compact JSON array shape. It does not implement full dbt node JSON
parity, arbitrary nested traversal, `config.meta`, whole-object `config` or
`depends_on`, relation fields, metrics, semantic models, saved queries, or
state/result selectors.

Current analysis resource source note:
`.agent/research/m2-analysis-parse-compile.md` maps dbt Core v1
`AnalysisParser`, `analysis_paths` file routing, and listable resource values
plus Fusion `resolve_analyses.rs` / manifest path normalization to dxt's
first-class analysis resources. This slice defaults `analysis-paths` to
`analyses`, discovers root and package analysis SQL/YAML/docs, emits
`analysis.<package>.<name>` Manifest nodes with `materialized: analysis`,
supports `resource_type:analysis` and `--resource-type analysis`, applies the
current narrow YAML description/tag/column patch subset, resolves refs/sources
and known macro dependencies, and compiles selected analyses under
`target/compiled/<package>/analysis/...`. It does not implement multi-statement
analysis splitting, tests on analyses, full config precedence, custom Jinja or
macro execution, dbt docs UI parity, or DuckDB execution semantics for analyses.

Current static `{% if %}` render boundary source note:
`.agent/research/m2-static-if-render-boundary.md` maps dbt Core v1 parse/runtime
`execute` context and Fusion static source recovery to dxt's narrow render-only
compiler branch selection. This slice renders literal `true`/`false`,
`execute`, `not execute`, `is_incremental()`, and `not is_incremental()`
conditionals with `execute=true` for compile/run-style rendering and
`is_incremental()=false` until incremental materialization state exists, while
preserving raw scanner dependency recovery inside branches that may render
false. It does not implement database-backed `run_query`, adapter
introspection, `elif`, complex expressions, or incremental materialization
semantics.

Current parse-time Jinja context boundary source note:
issue #150 adds an explicit Zig parse context in `src/project/jinja.zig` where
`execute=false`, supported parse-time `config()` returns empty text while
mutating parser-owned node config, and literal `ref()` / `source()` calls
return deterministic placeholders while preserving dependency records. It keeps
the existing raw scanner's static dependency recovery inside branches that may
render false. It does not implement general Jinja evaluation, database-backed
`run_query`, `statement`, adapter introspection, macro execution, hook hidden
dependencies, dispatch execution, or materialization lookup.

Current static loop ref/source compile source note:
`.agent/research/m2-static-loop-ref-source-compile.md` maps upstream dbt Core
v1 and Fusion compile-time `ref()` / `source()` resolution to dxt's narrow
render-only static loop-variable argument support. This slice renders
`ref(loop_var)`, `ref('package', loop_var)`, and `source('raw', loop_var)` in
the existing static string-list loop subset for `compile`, `docs generate`,
`run`, and `build`. It does not add general Jinja evaluation, dynamic lists,
inline list loops, tuple unpacking, loop metadata, filters, mutation, macro
execution, adapter dispatch execution, selector semantics, or graph dependency
changes.

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

Current DuckDB seed config source note:
Issue #179 extends the seed execution references above for dbt Core v1
`SeedConfig`, `SeedRunner`, and DuckDB-backed CSV loading to dxt's first
supported seed config slice. This slice parses seed YAML `quote_columns` and
`column_types` for root-project and installed-package CSV seeds, emits those
dbt-shaped config fields in `manifest.json`, and applies them through DuckDB
`read_csv_auto` column-name normalization and type maps for `dxt seed` and
seed paths inside `dxt build`. It does not implement delimiter config, hooks,
grants, full-refresh behavior, full materialization macro execution, adapter
portable type coercion, or embedded `libduckdb`.

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
behavior. The follow-up note
`.agent/research/m3-duckdb-accepted-values-quote-false.md` covers explicit
`quote: false` parser, Manifest metadata, identity, and DuckDB execution
behavior. These slices do not add generic macro execution, adapter-dispatched
test overrides, singular tests, unit tests, custom configs, typed scalar value
artifact parity, `store_failures`, or package/runtime macro behavior.

Current DuckDB relationships generic test execution source note:
`.agent/research/m3-duckdb-relationships-generic-tests.md` maps upstream dbt
Core v1 schema generic-test parsing, build/test runner behavior, and
run-results serialization plus Fusion's built-in `relationships` SQL macro and
test materialization helpers to dxt's first executable `relationships` slice.
This slice lets test-only, model+test, and seed+model+test `dxt build`
selections execute selected DuckDB column-level ref-backed and literal
source-target `relationships` tests when `to` and `field` arguments are
present, using the dbt built-in non-null child left-join failure-row SQL shape
and existing Run Results v6-shaped artifact behavior. It does not add generic
macro execution, adapter-dispatched test overrides, dynamic relationship
targets, source tests, singular tests, unit tests, custom configs,
`store_failures`, or package/runtime macro behavior. Literal source-target
relationship behavior is documented in
`.agent/research/m3-duckdb-source-target-relationships.md`.

Current DuckDB source column generic-test source note:
`.agent/research/m3-duckdb-source-column-generic-tests.md` maps upstream dbt
Core v1 source patching, source generic-test parsing, source-style test naming,
and build/test runner behavior plus Fusion `TestableTable` persistence and
source-test `attached_node` handling to dxt's first executable source column
generic-test slice. This slice parses source table columns and column-level
`tests` / `data_tests`, materializes source-style generic test nodes, and lets
selected source+test DuckDB builds execute source column `not_null`, `unique`,
default-quoted or explicit `quote: false` `accepted_values`, and ref-backed
`relationships` tests against already-existing source and target relations,
including literal `source('source', 'table')` relationship targets. The
follow-up notes `.agent/research/m3-duckdb-source-relationships-generic-tests.md`
and `.agent/research/m3-duckdb-source-target-relationships.md` cover the source
`relationships` extensions. These slices do not add generic macro execution,
adapter-dispatched test overrides, singular tests, unit tests, custom test
configs, `where`, `limit`, `severity`, `warn_if`, `error_if`,
`store_failures`, or native typed accepted-value manifest scalars.

Current DuckDB table-level generic-test source note:
`.agent/research/m3-duckdb-table-level-generic-tests.md` maps upstream dbt
Core v1 generic-test builder `column_name` argument handling, schema patch
generic-test parsing, build/test runner behavior, and Fusion data-test schemas
to dxt's first table-level built-in generic-test slice. This slice parses
explicit `arguments.column_name` on model, seed, and source table-level
`tests` / `data_tests`, materializes supported built-in generic test nodes only
when an effective column name exists, and lets selected DuckDB builds execute
table-level model, seed, and source tests through the existing direct SQL
renderer while keeping top-level test-node `column_name` null for table-level
dbt artifact parity. Literal source-target `relationships` now reuse this
effective-column path. It does not add arbitrary generic-test macro execution,
adapter-dispatched test overrides, dynamic relationship targets, custom test
configs, singular tests, unit-test execution, typed scalar accepted-value
manifest parity, `store_failures`, or package/runtime macro behavior.

Current DuckDB seed column generic-test source note:
`.agent/research/m3-duckdb-seed-column-generic-tests.md` maps upstream dbt Core
v1 seed property parsing, schema generic-test construction, build/test runner
behavior, and run-results serialization plus Fusion seed resolution and generic
data-test persistence to dxt's first executable seed column generic-test slice.
This slice parses `seeds:` YAML properties found under model and seed paths,
patches root-project CSV seed columns, materializes seed-attached generic test
nodes, emits seed columns/patch metadata in the Manifest v12-shaped slice, and
lets selected seed+test DuckDB builds execute seed column `not_null`, `unique`,
default-quoted or explicit `quote: false` `accepted_values`, and ref-backed
`relationships` tests. It does not add package seed execution, seed configs,
table-level seed tests, generic macro execution, adapter-dispatched test
overrides, singular tests, unit tests, custom test configs, `where`, `limit`,
`severity`, `warn_if`, `error_if`, `store_failures`, full dbt queue
interleaving, or native typed accepted-value manifest scalars.

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

Current inline enabled config source note:
`.agent/research/m2-inline-enabled-config.md` maps dbt Core v1 parse-time
`config()` capture, disabled-node cleanup, and Manifest disabled maps plus
Fusion renderer/resolver disabled-map behavior to dxt's narrow literal model
`config(enabled=true|false)` parser slice. Inline-disabled SQL models reuse the
existing disabled manifest path and are excluded from active graph maps,
selectors, compile, run, and build. This slice does not implement dynamic
enabled expressions, disabled seeds/sources/tests, or full config precedence.

Current inline disabled singular SQL test source note:
`.agent/research/m2-inline-disabled-singular-tests.md` maps dbt Core v1
singular test parsing, parse-time `config()` capture, disabled-node cleanup,
and Manifest disabled maps plus Fusion renderer/resolver disabled-map behavior
to dxt's narrow literal singular SQL test `config(enabled=false)` parser
slice. Inline-disabled singular tests are emitted under `manifest.disabled` and
excluded from active graph maps, dependency resolution, selectors, compile,
test, and build. This slice does not implement YAML singular test
patches/configs, generic-test `enabled`, dynamic enabled expressions, severity
or threshold configs, `where`, `limit`, `store_failures`, or full
indirect-selection parity.

Current DuckDB SQL model run source note:
`.agent/research/m3-duckdb-run-sql-models.md` maps dbt Core v1 Run Results v6
schema and run-result processing plus Fusion run-results structs, task stats,
DuckDB profile `path`, DuckDB table/view SQL primitives, and dbt/Fusion DAG
queue ordering to dxt's first execution slice. This slice lets `dxt run`
execute selected enabled DuckDB SQL models with `table` and `view`
materializations through a Zig-owned external DuckDB CLI backend, write compiled
SQL, `manifest.json`, and a minimal success `run_results.json`, and reject
non-model selections, non-DuckDB adapters, and unsupported materializations
explicitly. It does not implement `build` execution, seeds, tests, snapshots,
incremental, ephemeral, hooks, grants, docs persistence, catalog introspection,
relation staging/backup rename parity, threaded scheduling, or embedded
`libduckdb`.

Current DuckDB run/build failure artifact source note:
`.agent/research/m3-duckdb-run-build-failure-results.md` maps dbt Core v1
Run Results v6 `error` rows, run-result processing, runnable exception/result
handling, and build runner reuse plus Fusion run-results artifact assembly to
dxt's first partial failure artifact slice. This slice lets `dxt run` and
supported DuckDB model/seed branches of `dxt build` catch model or seed
`DuckDbExecutionFailed`, append a sanitized `status: "error"` run-result row
for the failed resource after completed prior rows, write `run_results.json`,
and return exit code `1`. It does not add generic-test runtime-error rows, dbt
skip propagation, fail-fast/retry/threaded queue semantics, raw DuckDB stderr in
artifacts, relation staging/backup rename parity, incremental, ephemeral,
snapshots, hooks, grants, docs persistence, selector changes, or Python product
runtime behavior.

Current DuckDB run/build skipped-result source note:
`.agent/research/m3-run-build-skipped-results.md` maps dbt Core v1
`mark_node_as_skipped`, dependent-error marking, build runner skip handling,
Run Results v6 `skipped` status, and Fusion run-result/schedule references to
dxt's first selected blocked-resource skipped-result slice. This slice lets
`dxt run` append `status: "skipped"` rows for selected blocked model
descendants after a selected model DuckDB execution error, and lets supported
DuckDB model/seed branches of `dxt build` append skipped rows for selected
blocked seed/model descendants and selected blocked generic tests after a
model/seed DuckDB execution error. It preserves the post-`--exclude` selected
set and then writes `run_results.json` before returning exit code `1`. It does
not add full dbt queue semantics, independent-resource continuation after a
failure, test-failure-driven downstream skipping, fail-fast/retry/threaded
scheduling, generic-test runtime-error rows, selector changes, or Python
product runtime behavior.

Current DuckDB run independent failure continuation source note:
`.agent/research/m3-run-independent-continuation.md` maps dbt Core v1 runnable
task result handling, graph queue continuation, and Run Results v6 status rows
plus Fusion scheduler/run-results references to dxt's first `dxt run`
independent-resource continuation slice. This slice lets selected DuckDB SQL
models with no dependency on a failed selected model continue executing, while
selected descendants of the failed model are recorded as `skipped` rows when
encountered in dependency order. It does not add `dxt build` independent
continuation, seed command continuation, test-failure continuation, threaded
queue parity, retries/fail-fast flags, raw DuckDB stderr in artifacts, relation
staging, non-DuckDB adapters, or Python product runtime behavior.

Current DuckDB docs catalog source note:
`.agent/research/m3-duckdb-docs-catalog.md` maps dbt Core v1 docs catalog
generation and Fusion legacy catalog schemas to dxt's first DuckDB-backed
`catalog.json` introspection slice. This slice lets `dxt docs generate` keep
the existing empty catalog when no local DuckDB database exists, and emit
selected model/seed catalog node entries and selected source catalog entries
with relation metadata and ordered columns when the selected relations already
exist in the target DuckDB file. It does not execute resources during docs
generation, implement source relation config overrides, source freshness,
comments, owners, stats beyond `has_stats`, non-DuckDB adapters, browser/UI
assets, or embedded `libduckdb`.

Current static docs serve source note:
`.agent/research/m3-docs-serve-static.md` maps dbt Core v1 `docs serve` and
Fusion docs serve references to dxt's first static target-directory server. The
slice adds `dxt docs serve` in Zig, resolves the project target directory,
writes a small dxt-owned `index.html`, serves existing generated docs artifacts
over localhost HTTP, parses dbt Core-style `--host`, `--port`,
`--browser`/`--no-browser` and Fusion-style `--no-open`, rejects traversal
paths, and keeps `manifest.json` and `catalog.json` unchanged. Browser opening,
dbt's bundled docs SPA, Fusion docs v2/index API endpoints, live reload,
directory listings, TLS, and docs artifact generation inside `docs serve`
remain out of scope.

Current clean command source note:
`.agent/research/m1-clean-command.md` maps dbt Core v1 `clean` and Fusion clean
safety references to dxt's first destructive filesystem command slice. The
slice adds `dxt clean` in Zig, parses `clean-targets`, defaults to the
effective target path when `clean-targets` is omitted, accepts
`--project-dir`, `--profiles-dir`, `--target-path`, `--vars`, and
`--clean-project-files-only`, rejects `--no-clean-project-files-only`, absolute
or parent-traversing targets, project-root targets, and protected source
directories, skips missing paths and plain files, and does not require a
profile. Fusion positional file args, outside-project deletion, symlink/canonical
path parity, richer event output, graph loading, adapters, and artifact writes
remain out of scope.

Current DuckDB source freshness source note:
`.agent/research/m3-duckdb-source-freshness.md` maps dbt Core v1
`FreshnessRunner`, `FreshnessSelector`, and Sources v3 artifact behavior plus
Fusion freshness artifact structs and source-status selector inputs to dxt's
first `sources.json` execution slice. This slice lets `dxt source freshness`
select source nodes with table-level freshness criteria, query selected DuckDB
source tables through table-level `loaded_at_field` SQL text and optional raw
`freshness.filter` SQL or through table-level raw `loaded_at_query` SQL,
classify `pass` / `warn` / `error`, write dbt-shaped success and runtime-error
rows to `sources.json`, treat empty or all-null loaded-at results as stale
freshness results, and return failure when freshness status is `error` or a
runtime-error row is produced. It does not implement source-level inheritance,
Jinja rendering inside `loaded_at_query`, metadata freshness, `config:`
overrides, hooks, concurrency, non-DuckDB adapters, or embedded `libduckdb`.

Current source-status selector source note:
Issue #192 adds the first read-only Sources v3 state input for selectors. When
a resolved selector expression contains `source_status:pass`,
`source_status:warn`, or `source_status:error`, commands that reuse the shared
Zig selector engine can read `--state/sources.json`, validate the dbt Sources
v3 schema URL, index result `unique_id` / `status` rows, and match source
nodes plus graph expansions such as `source_status:warn+`. This slice does not
implement `state:`, `result:`, `source_status:fresher`, manifest comparison,
deferral, source freshness execution changes, metadata freshness, or
non-DuckDB adapter behavior.

Current DuckDB test command source note:
`.agent/research/m3-duckdb-test-command.md` maps dbt Core v1 `TestTask`,
`TestRunner`, build/test runner reuse, and selector test-type behavior plus
Fusion command/data-test/run-results references to dxt's first `dxt test`
command slice. The follow-up `.agent/research/m3-duckdb-singular-tests.md`
extends that command path to singular SQL data tests. Together these slices
execute selected supported DuckDB generic test nodes and singular SQL test nodes
against already-existing target relations, write `manifest.json`, write Run
Results v6-shaped pass/fail rows, and return exit code `1` on test failures.
They do not build parent models or seeds, execute unit tests, run custom generic
test macros, honor singular YAML patches or test configs such as
`where`/`limit`/`severity`/`warn_if`/`error_if`, store failures, change
indirect-selection semantics, or add Python product runtime behavior.

Current DuckDB generic-test config/severity source note:
`.agent/research/m3-duckdb-generic-test-configs.md` maps upstream dbt Core v1
generic-test config parsing, test materialization threshold handling, and
Manifest/Run Results fields plus Fusion built-in generic-test helper references
to dxt's first config slice for supported built-in DuckDB generic tests. This
slice parses `where`, `limit`, `severity`, `warn_if`, `error_if`, and
`store_failures` for model, seed, and source generic tests, emits the supported
Manifest config fields, applies `where` and `limit` to supported built-in
failure-row SQL, classifies pass/warn/fail statuses from simple integer
failure-count threshold comparisons, and optionally persists DuckDB audit
failure tables. It does not implement `store_failures_as`, custom generic-test
macro execution, adapter-dispatched generic-test overrides, unit-test execution,
full indirect-selection parity, or a general expression evaluator.

Current compile singular-test source note:
`.agent/research/m2-compile-singular-tests.md` maps dbt Core v1
`CompileTask`, `Compiler.compile_node`, singular test parser/path behavior, and
CompiledNode artifact fields plus Fusion Manifest v12 compiled SQL maps to
dxt's narrow compile artifact slice for singular SQL data tests. This slice lets
`dxt compile` select supported singular SQL tests, render them through the
existing Zig compile context, write compiled SQL under
`target/compiled/<package>/tests/...`, and emit compiled Manifest fields only
for selected compiled singular test nodes. It does not compile generic tests,
honor singular YAML patches/configs, execute DuckDB, write run-results, change
indirect-selection semantics, or expand the general Jinja/macro runtime.

Current compile generic-test source note:
`.agent/research/m2-compile-generic-tests.md` maps dbt Core v1 compile/test
node behavior, generic test compiled-node artifact fields, Fusion Manifest v12
compiled SQL maps, and Fusion bundled built-in generic-test SQL to dxt's narrow
compile artifact slice for already-supported built-in generic data tests. This
slice lets `dxt compile` select supported `not_null`, `unique`,
`accepted_values`, and `relationships` generic tests, write compiled failure-row
SQL under `target/compiled/<package>/<test_alias>.sql`, and emit compiled
Manifest fields without opening DuckDB or writing `run_results.json`. It does
not add custom generic macro execution, generic test configs, `store_failures`,
new test types, or adapter dispatch execution.

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
- Generic tests: model column and explicit table-level `column_name` `unique`,
  `not_null`, default-quoted and explicit `quote: false` `accepted_values`,
  and ref-backed `relationships` are started; source column and explicit
  table-level `column_name` `not_null`, `unique`, and default-quoted or
  explicit `quote: false` `accepted_values`, and ref-backed `relationships`
  are started; root-project CSV seed column and explicit table-level
  `column_name` `not_null`, `unique`, default-quoted or explicit
  `quote: false` `accepted_values`, and ref-backed `relationships` are
  started; wider generic-test config parity remains.
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
    json.zig
    manifest.zig
```

Staged extraction order:

1. Extract `src/project/types.zig` for `Runtime`, `Options`, graph/resource/config structs, and data-model deinit helpers.
2. Extract selector parsing, wildcard matching, resource matching, and graph expansion into `src/project/selector.zig`, carrying selector Zig tests with the module.
3. Extract selected-resource JSON and `manifest.json` writers into `src/project/manifest.zig`, carrying JSON escaping and deterministic ordering tests with the module.
3a. Centralize artifact/string JSON emission helpers in `src/project/json.zig` before broadening artifact schemas, so manifest, run-results, catalog, and sources writers share Zig `std.json` escaping and native tests instead of per-module ad hoc helpers.
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
- Narrow source-grounded compile-time Jinja slices may land before the full
  engine when they unblock public fixtures, but each must name the dbt Core v1
  and Fusion source references, stay in Zig, and reject unsupported Jinja
  shapes loudly.

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
- Broader source freshness and `sources.json` parity.
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
- SQLMesh-inspired gateway and virtual-layer design review, after dbt-compatible
  adapter ABI and manifest/run artifact behavior are stable enough to avoid
  changing the active dbt contract.

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

- PRs merge after green required checks; second-agent or human review is optional unless explicitly requested for that PR.
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
- Premature SQLMesh-style planning that changes dbt command semantics before
  dbt Core parity is strong enough.
- Test ID and selector edge cases.
- Catalog differences by adapter and permissions.
- Cross-engine semantic differences for nulls, timestamps, collations, decimals, JSON, and nondeterministic functions.
- Data movement cost estimate drift.
- Partial failures leaving stage artifacts or temp relations.
- Sensitive data movement across trust boundaries.
- Concurrent agents editing the same Zig module or fixture can create semantic
  conflicts even when Git merges cleanly.
- Dirty worktrees can make validation results ambiguous.
- Local run notes, absolute paths, shell history, session transcripts, and raw
  Codex output can leak if copied from `.agent/runs/` into tracked docs without
  scanning.
- Stacked worktree branches can pass locally but fail after upstream PRs merge
  unless rebased and revalidated.
- GitHub Projects can drift from repo-local manifests if labels, project fields,
  or seed issues are edited manually without re-running the Agent OS bootstrap
  checks.
- Autonomous local workers can make progress without a human in the loop, but
  they must still use one issue, one branch, and one worktree per slice, and
  merge only after green checks.

## Current Status

- Issue #187 is the active Manifest v12 node identity/checksum slice. Branch
  `agent/issue-187-artifact-manifest-v12-node-identity-and-checksum` owns
  `src/project/manifest.zig`, the seed raw-content load in `src/project.zig`,
  the pinned Manifest v12 schema slice, focused CLI/schema assertions, and the
  dbt Core M1 oracle comparison for node `database`, `schema`, `alias`, `fqn`,
  and `checksum` fields. The slice is limited to currently supported model,
  analysis, seed, generic data-test, singular data-test, and disabled-node
  artifact shapes.
- Issue #180 is the active store-failures implementation slice. Branch
  `agent/issue-180-compat-store-failures-config-for-duckdb-data-tes` owns the
  current data-test `store_failures` config, manifest/run-results shape, and
  DuckDB audit-table execution path for supported generic and singular data
  tests. A concurrent #181 source-config branch is also editing
  `src/project/parse.zig` and `src/project/types.zig`; #180 is limited to the
  test-config fields and must rebase before final validation if #181 lands
  first.
- M0 is complete as the Zig `0.16.0` runtime scaffold.
- GitHub-backed agent coordination now has repo-local issue forms, label/project
  manifests, seed issue definitions, project-scoped specialist roles,
  including a product-manager board monitor role, developer-side
  bootstrap/validation scripts, and a local autonomous
  orchestrator that can claim ready issues, spawn Codex worker subprocesses in
  isolated worktrees, record ignored state/logs, accept issue-comment nudges,
  and merge green PRs when explicitly run with merge enabled. The supervisor
  loop now builds a principal snapshot of ready issues, active worker state,
  git worktrees, open PRs, dependency comments, changed PR files, merge state,
  and CI checks before launches or merges, and the merge-ready queue skips draft,
  red, conflicting, overlapping, or dependency-blocked PRs while posting fan-in
  summaries back to linked issues after applied merges. The local
  supervision layer includes a detached `codex exec` pull-plug handoff and a
  two-phase tmux/Hermes watchdog path for exact-terminal Codex restarts after
  project-scoped `.codex/` changes. The product-manager prompt and docs now
  require roadmap-gap issue creation when the queue is empty or stale, define
  the PM-created issue contract, and expose board/roadmap context in dry-run
  output. Project item sync can dry-run or apply unambiguous field
  reconciliation from labels and public `dxt-agent-event` comments for role,
  status, validation, source grounding, readiness, branch, and dependency
  fields. Agent OS cleanup now has a dry-run-first command that reports exited
  stale runs, clean merged agent worktree removal candidates, and stale
  `status:claimed` labels before any `--apply` action. Creating/updating the
  live GitHub Project requires GitHub CLI project scopes.
- Multi-agent development now has a dedicated worktree workflow under
  `docs/MULTI_AGENT_WORKFLOW.md`, with project-scoped Codex agent roles under
  `.codex/agents/` and helper scripts for starting, finishing, and pruning
  worktrees.
- CI now separates native Zig/safety gates, Python integration matrix gates, and
  a public Jaffle parse/build/run/docs compatibility gate with a pinned,
  checksum-verified DuckDB CLI.
  Pytest jobs emit JUnit reports for review, and local development guidance now
  favors focused pytest runs plus native/safety gates instead of full local
  pytest after every small slice. The main CI workflow cancels superseded branch
  and PR runs, uses bounded job timeouts, and a separate GitHub `Coverage`
  workflow collects native Zig test coverage map artifacts for Zig source or
  build-file PRs, pushes to `main`, and manual coverage runs. This first
  coverage artifact reports native test declarations by source module rather
  than line coverage, avoiding misleading Python coverage claims for the Zig
  runtime. The public Jaffle job fetches the pinned fixture checkout once per
  run and passes it to all four public harnesses to avoid repeated public
  network clones. Release packaging now has a reusable developer-side archive
  safety validator that checks tarball shape, version/target naming, allowed
  members, binary/doc string leaks, executable metadata, and checksum coverage
  before upload.
- M1 has started on stacked branches with native Zig artifact-first parser slices.
- M1A has started with behavior-preserving `src/project/types.zig`, `src/project/selector.zig`, `src/project/manifest.zig`, `src/project/util.zig`, `src/project/config.zig`, `src/project/fs.zig`, `src/project/jinja.zig`, `src/project/resolve.zig`, `src/project/parse.zig`, `src/project/loader.zig`, and `src/project/json.zig` extractions. `src/project/json.zig` centralizes shared JSON string, nullable-string, boolean, object string-field, and string-array emission on top of Zig `std.json` with native tests, and is used by the manifest, run-results, catalog, and sources artifact writers. `src/project/manifest.zig` owns selected-resource JSON and partial `manifest.json` writing with native tests for selected JSON shape, JSON escaping, exposure dependency ordering, disabled-resource filtering, graph-map output, and macro `supported_languages` emission. `src/project/util.zig` owns shared display, membership, append-dedup, string sorting, and narrow YAML scalar/list helpers. `src/project/config.zig` owns `dbt_project.yml` loading, project path/docs config parsing, narrow scalar top-level `vars` parsing, CLI `--vars` scalar map parsing, and applying parsed project path/docs configs to graph nodes. `src/project/fs.zig` owns deterministic resource file discovery, Linux directory traversal helpers, and resource path/name helpers. `src/project/jinja.zig` owns lexical Jinja call, parenthesis, quoted string, literal and var-backed argument helpers, supported model SQL scanning, inline config/tag parsing, and known macro-call scanning with native tests. `src/project/resolve.zig` owns graph lookup/count helpers, canonical graph resource ordering, duplicate resource validation, macro unique-id package extraction, low-level ref/source resolution helpers, and dependency-map mutation for refs, sources, and known macro dependencies. `src/project/parse.zig` owns narrow parser scalar helpers for YAML booleans, JSON-compatible scalar classification, source YAML table parsing, exposure YAML resource parsing, current top-level `{% macro %}`, `{% test %}`, `{% data_test %}`, and `{% materialization %}` block parsing, materialization `supported_languages` parsing, macro property YAML parsing, generic-test YAML item names, generic-test definition construction/cloning, generic-test relationship target ref parsing, exposure dependency parsing, exposure meta parsing, macro-property application, and generic-test identity/name/hash helpers with native tests. `src/project/loader.zig` owns graph loading order, target-path lookup, project/package resource traversal, root project and CLI vars application, macro/property application sequencing, duplicate checks, and graph sorting while using explicit callbacks into parser helpers that still live in the facade. `src/project.zig` remains the public parser/list facade and still owns docs block parsing, YAML model property parsing, model/seed parsing, generic-test materialization, warnings, and some resolver orchestration until follow-up extractions move those pieces behind focused internal modules.
- CI format validation now covers every tracked Zig source file under `src/`, including extracted `src/project/*.zig` modules, so M1A module splits remain under the same formatting gate as the root CLI files.
- `dxt parse` now targets the supported Tier 0 subset: project name/model paths/analysis paths/seed paths/macro paths/test paths, target path, narrow top-level scalar project `vars`, CLI `--vars` scalar overrides including strict JSON object input with stringified scalar values parsed through Zig `std.json` plus the existing loose inline YAML-style scalar maps, project and package model path configs for literal `+materialized`, `+tags`, and model/seed `+docs.node_color`, root-project model config overrides for installed packages, SQL model discovery, SQL analysis discovery from configured `analysis-paths` / default `analyses`, CSV seed discovery, installed package SQL model, SQL analysis, and CSV seed discovery from `dbt_packages`, source discovery, installed package source discovery, exposure discovery, installed package exposure discovery, singular SQL test discovery under configured `test-paths` while skipping `generic/` and `fixtures/`, read-only root-project unit-test discovery for dict-style YAML `given`/`expect` row fixtures, project macro discovery, dbt-shaped generic test macro and materialization macro block discovery, installed package macro discovery from `dbt_packages`, macro property YAML for project macro descriptions, arguments, `docs`, and scalar JSON-compatible `meta`, project and package docs block discovery, literal, narrow scalar `var('name')` / `var('name', 'default')`-backed, and static string-list loop-var `ref` to models or seeds, two-argument package refs, package-local refs in installed package models, analyses, and exposures, unique installed-package fallback for unqualified refs, literal, narrow scalar `var('name')` / `var('name', 'default')`-backed, and static string-list loop-var `source`, package-local sources in installed package models and analyses, unique installed-package fallback for unqualified sources, literal `doc` in project and package descriptions, inline model/analysis `config(tags=..., enabled=...)`, inline model `config(materialized=...)`, inline singular SQL test `config(enabled=false)`, known project/package-qualified/package-local macro call dependencies, narrow project and package YAML model/analysis properties for scalar descriptions, simple columns, tags, materialization for models, disabled SQL models/analyses, dbt-shaped `unique`, `not_null`, `accepted_values`, and `relationships` generic test nodes including literal source-target relationship dependencies, active singular SQL test nodes with supported top-level `tests:` / `data_tests:` YAML patches for description, config tags, enabled, severity, warn/error thresholds, `where`, and `limit` without generic-only fields, disabled singular SQL tests from inline or YAML config under `manifest.disabled`, model/analysis/test `refs` and `sources` artifact fields, dependency maps including enabled singular tests and read-only unit tests depending on their tested model, and deterministic partial `manifest.json`. The manifest includes the v12 top-level maps needed by the M1 artifact shape, including non-empty read-only `unit_tests`, and is covered by a pinned local dbt Manifest v12 schema slice. YAML generic test arguments are currently supported for scalar values plus inline and block lists required by public Jaffle Shop DuckDB-style tests. Multi-statement analysis splitting, tests on analyses, dynamic singular-test `enabled`, generic-test `enabled`, unit-test execution, CSV/SQL fixtures, overrides, version expansion, disabled-unit-test placement, and SQL comparison remain explicitly deferred. Full dbt `var()` semantics remain explicitly deferred until the parse/compile Jinja context work covers package scoping, `vars.yml`, non-string values, rendered var values, `has_var`, missing-var parse/runtime behavior, project/profile rendering, and partial-parse invalidation.
- `dxt ls` now lists dbt-selectable resources from the same parser graph, including scalar project/CLI var-resolved and static string-list loop-resolved dependency edges, with stable legacy text, compact JSON with narrow resource/config/identity/dependency `--output-keys` including `unique_id`, `resource_type`, `name`, `package_name`, source-only `source_name`, `alias`, source-only `identifier`, `path`, `original_file_path`, `tags`, `config.materialized`, `config.tags`, `config.enabled`, `config.docs.show`, `depends_on.nodes`, `depends_on.macros`, and `selector`, dbt-style name, path, and selector output, and basic name/FQN wildcards, tag wildcards, slash-aware `path:` wildcards, `file:` basename/stem selectors, fnmatch-style bracket character classes for selector wildcards, exact `package:`/`package:this`, `source:` wildcards including package-qualified source selectors, `source_status:pass` / `source_status:warn` / `source_status:error` from a dbt Sources v3 `--state/sources.json` input, `exposure:` wildcards, `unit_test:` selectors for read-only unit-test resources, `resource_type:` including analyses, `test_type:generic`, `test_type:singular`, `test_type:data`, `test_type:unit`, config materialization, comma intersection, whitespace union, multi-argument selector lists, repeated selector flags, root `selectors.yml` scalar aliases plus narrow YAML `union`/`intersection`/`exclude` composition over supported selector leaves, leading/trailing and depth-limited `+` graph expansion, `@` graph expansion, and exact exclude filters; macros are emitted in artifacts but not exposed as `ls` resources.
- `dxt clean` has started as a source-grounded filesystem command. It parses project `clean-targets`, defaults omitted `clean-targets` to the effective target path, deletes only project-relative directories, protects model/seed/macro and common dbt source directories, rejects outside-project deletion including `--no-clean-project-files-only`, skips missing paths and plain files, and does not require profile configuration. It does not load the graph, write artifacts, execute adapters, support selectors, delete outside the project, or support Fusion positional file args.
- `dxt compile` has started as a render-only M2 boundary for the current graph subset. It loads and resolves the same Zig parser graph, applies `--select` and `--exclude`, compiles selected enabled SQL model nodes, selected enabled analysis nodes, selected supported built-in generic test nodes, and selected enabled singular SQL test nodes, writes compiled SQL under `target/compiled/<package>/...`, and emits `compiled`, `compiled_code`, `compiled_path`, `extra_ctes`, and `extra_ctes_injected` for compiled model, analysis, and data-test nodes while model nodes also emit `relation_name` and analysis nodes emit `relation_name: null`. The current compiler renders `config` to empty text, literal, narrow scalar var-backed, and static string-list loop-var `ref`/`source` calls to deterministic quoted relation names, profile-derived `target.*`, current-model `this`, quoted literal inline `config(schema=..., alias=...)` as default dbt relation schema/identifier components, and a narrow source-grounded compile-time Jinja subset for unescaped `{% set name = ['string', ...] %}` string lists plus `{% for item in name %}` body expansion, and static `{% if %}` branches for literal `true`/`false`, `execute`, `not execute`, `is_incremental()`, and `not is_incremental()` without opening a database connection. It also renders a narrow Jaffle-style macro dispatch subset for literal model and analysis macro calls such as `{{ cents_to_dollars('subtotal') }}`, wrapper bodies shaped as `return(adapter.dispatch(...)(column_name))`, and selected adapter/default implementation bodies with positional parameter interpolation. The analysis parse/list/compile slice is documented in `.agent/research/m2-analysis-parse-compile.md`; the static list-loop slice is documented in `.agent/research/m2-static-jinja-set-for-loops.md`; the static loop dependency slice is documented in `.agent/research/m2-static-loop-dependencies.md`; the static loop ref/source compile slice is documented in `.agent/research/m2-static-loop-ref-source-compile.md`; the static conditional slice is documented in `.agent/research/m2-static-if-render-boundary.md`; the minimal macro dispatch slice is documented in `.agent/research/m2-minimal-macro-dispatch-rendering.md`; the singular test compile slice is documented in `.agent/research/m2-compile-singular-tests.md`; the generic test compile slice is documented in `.agent/research/m2-compile-generic-tests.md`. The compiler intentionally rejects scalar set values, unquoted or escaped list entries, filters, complex conditionals, `elif`, loop metadata, dynamic lists, general expression evaluation, statement tags inside macro bodies, custom generic test macro compilation, materialization macro execution, and arbitrary macro runtime behavior.
- `ephemeral` model support has started as a narrow compiler and DuckDB
  execution slice grounded in dbt Core compile CTE injection references
  (`Compiler._recursively_prepend_ctes`, `inject_ctes_into_sql`,
  `compile_node`) and the current Fusion compile context direction named in
  `.agent/research/dbt-upstream-reference-map.md`. Supported downstream SQL
  models now compile literal/ref-resolved ephemeral parents into deterministic
  `__dbt__cte__<identifier>` CTEs, including simple chained ephemeral parents,
  emit model Manifest `extra_ctes`, `extra_ctes_injected`, `compiled_code`, and
  `compiled_path`, and execute selected downstream DuckDB `run` / `build`
  models without materializing standalone ephemeral relations. This slice
  remains bounded to the existing narrow compiler/Jinja subset and still
  rejects cycles, unsupported Jinja in ephemeral parents, selected standalone
  ephemeral execution, non-table/view downstream execution, custom
  materialization macros, adapter-specific relation staging, incremental,
  snapshots, and broader scheduler semantics.
- `dxt docs generate` has started as a docs artifact boundary. It loads and resolves the same Zig parser graph, applies `--select` and `--exclude` to compiled model output, writes compiled SQL, writes `manifest.json`, and writes dbt-shaped `catalog.json`. The catalog remains empty when no local DuckDB database exists or when selected relations are absent, and includes selected model/seed node relation metadata plus selected source relation metadata and ordered columns when an existing target DuckDB file can be introspected through the Zig-owned DuckDB CLI backend, including configured source database matching through DuckDB `table_catalog` for the current source relation identity contract and supported project-level/YAML source config inheritance. `dxt docs serve` has started as a static target-directory HTTP server for existing generated artifacts. Macro execution, docs-time materialization, tests, source freshness inside docs, comments, owners, richer stats, non-DuckDB adapters, `run_results.json`, dbt's bundled docs SPA, browser opening, and Fusion docs v2 endpoints remain out of scope.
- `dxt source freshness` has started the M3 DuckDB `sources.json` execution path. It loads and resolves the same Zig parser graph, applies supported source selectors/excludes including `source_status:pass` / `source_status:warn` / `source_status:error` from a prior dbt Sources v3 `--state/sources.json`, filters to source nodes with resolved source/table freshness criteria, queries selected DuckDB source tables through resolved relation identity plus resolved `loaded_at_field` SQL text and optional raw `freshness.filter` SQL or through resolved raw `loaded_at_query` SQL, classifies `pass` / `warn` / `error` from `warn_after` and `error_after`, writes `manifest.json`, writes dbt-shaped `sources.json` v3 success rows including stale empty/all-null loaded-at results, writes dbt-shaped runtime-error rows for unsupported per-source execution gaps such as missing loaded-at configuration, and returns exit code `1` when any freshness status is `error` or runtime error. Root-project `dbt_project.yml` `sources:` configs for supported relation/freshness fields, source/table `config:` inheritance for `loaded_at_field`, `loaded_at_query`, and `freshness`, dbt-shaped threshold inheritance, final `freshness: null`, narrow `schema: "{{ target.schema }}"` rendering, source table `identifier` physical-name overrides, source/table database and database/schema/identifier quoting relation identity, resolved source database/schema/identifier use in compile/catalog/freshness/test paths, and expanded source manifest fields are implemented. General Jinja inside `loaded_at_query`, metadata freshness, hooks, threaded scheduling, installed-package project source config application, non-DuckDB adapters, `state:`, `result:`, defer, and embedded `libduckdb` remain future source-grounded slices.
- `dxt run` has started the M3 DuckDB execution path for selected enabled SQL models. It loads and resolves the same Zig parser graph, applies supported selectors/excludes, compiles selected SQL models, validates that selected models use only `table` or `view` materializations before opening DuckDB, executes selected models in dependency order through a Zig-owned external DuckDB CLI backend, writes compiled SQL, writes `manifest.json`, and writes a minimal dbt-shaped `run_results.json` v6 slice after completed runs. When a selected model fails with a DuckDB execution error, it writes completed prior rows plus a sanitized `status: "error"` row for the failed model, records `status: "skipped"` rows for selected blocked model descendants that survived `--exclude`, continues executing later selected models that do not depend on the failed node, writes `run_results.json`, and returns exit code `1`. It supports default `target/dxt.duckdb` output plus scalar DuckDB profile `path` resolved relative to the loaded `profiles.yml` directory as a deterministic dxt-local path-base choice for this first CLI-backed slice. It does not execute seeds, tests, snapshots, incremental, ephemeral, hooks, grants, docs persistence, catalog introspection, build/seed independent-resource continuation after failure, relation staging/backup rename parity, threaded scheduling, `:memory:`, MotherDuck, or embedded `libduckdb`.
- `dxt seed` has started the M3 DuckDB seed command path for selected root-project and installed-package CSV seeds. It loads and resolves the same Zig parser graph, applies supported selectors/excludes, filters mixed selections to seed resources in the dbt `SeedTask` / `ResourceTypeSelector` shape, rejects selections that match no seeds before opening DuckDB, writes `manifest.json`, loads selected seeds through the existing Zig-owned DuckDB CLI backend from the loaded root or package project root, writes seed-shaped Run Results v6 rows with null compiled fields, and prints a seed-specific success summary. Package seed execution supports name, package, and dependency selector paths when the final runnable set is seed resources. Supported seed YAML `quote_columns` and `column_types` configs are parsed for root-project and installed-package CSV seeds, emitted in dbt-shaped Manifest seed configs, and applied through DuckDB CSV name-normalization and type-map options. Hooks, grants, docs persistence, full-refresh semantics, full materialization macro execution, threaded scheduling, broader seed config parity, and embedded `libduckdb` remain future source-grounded slices.
- `dxt test` has started the M3 DuckDB data-test command path. It loads and resolves the same Zig parser graph, filters selection to test resources, executes selected supported DuckDB generic tests and enabled singular SQL tests against already-existing target relations through the existing Zig-owned DuckDB CLI backend, writes `manifest.json`, writes Run Results v6-shaped pass/fail/warn rows, and returns exit code `1` when any selected test fails while warning tests do not fail the command. It supports the built-in `not_null`, `unique`, `accepted_values`, and `relationships` generic-test subset already implemented for `build`, including model/seed/source generic-test `where`, `limit`, `severity`, `warn_if`, `error_if`, and `store_failures` configs for simple failure-count threshold comparisons and deterministic DuckDB audit-table persistence, plus singular SQL test files discovered from configured `test-paths` while skipping `generic/` and `fixtures/` subdirectories. Supported singular YAML patches can set description, config tags, enabled, `where`, `limit`, severity, warn/error thresholds, and `store_failures`; `where` and `limit` are applied to failure-row SQL, and threshold classification matches the existing supported generic-test model. Literal inline or YAML `config(enabled=false)` singular SQL tests are preserved under `manifest.disabled` and omitted from active selectors and execution, with inline enabled config taking precedence over YAML patch enabled config; literal inline singular `config(store_failures=true|false)` is also supported. Singular manifest nodes intentionally omit generic-only fields such as `test_metadata`, `column_name`, and `attached_node`, and selectors now cover `test_type:singular`, `test_type:data`, and patched singular tags. It does not build parent models or seeds, execute unit tests, run custom generic-test macros, support dynamic singular `enabled`, support `store_failures_as`, broaden singular config parity, change indirect-selection semantics, or use Python product runtime behavior.
- `dxt build` has started the M3 DuckDB execution path for root-project and installed-package CSV seed-only selections with supported seed YAML `quote_columns` and `column_types` configs, selected DuckDB SQL models with `table` and `view` materializations, selected seed+model builds in the supported DAG subset, selected seed+model+supported-generic-test builds, selected seed+test builds for CSV seed column or explicit table-level `column_name` generic tests, selected model+generic-test builds without seeds, selected model+singular-test builds when singular dependencies are selected, test-only selected DuckDB model column or explicit table-level `column_name` `not_null`/`unique`/default-quoted or explicit `quote: false` `accepted_values`/ref-backed or literal source-target `relationships` generic tests, source+test selected DuckDB source column or explicit table-level `column_name` `not_null`/`unique`/default-quoted or explicit `quote: false` `accepted_values`/ref-backed or literal source-target `relationships` generic tests, and selected seed+test DuckDB seed column or explicit table-level `column_name` `not_null`/`unique`/default-quoted or explicit `quote: false` `accepted_values`/ref-backed or literal source-target `relationships` generic tests. It loads and resolves the same Zig parser graph, applies supported selectors/excludes, writes `manifest.json`, loads seeds through the Zig-owned DuckDB CLI backend from the loaded root or package project root, executes selected seed/model nodes in dependency order for selected seed/model dependencies, executes supported generic and singular SQL tests against built or already-existing attached/source/target relations, applies supported model/seed/source generic-test and singular-test `where`, `limit`, `severity`, `warn_if`, `error_if`, and `store_failures` configs, writes a minimal dbt-shaped `run_results.json` v6 slice, returns exit code `1` when any selected test fails while warning tests do not fail the command, writes completed prior rows plus a sanitized `status: "error"` row when supported model or seed execution fails before downstream tests, and appends `status: "skipped"` rows for selected blocked seed/model descendants and selected blocked data tests that survived `--exclude`. For selected model-only, seed-only, and seed+model build paths, ready selected data tests now run as soon as their selected seed/model dependencies have completed; a failing selected data test writes its `fail` row, appends `skipped` rows for selected downstream seed/model descendants and unexecuted selected downstream data tests, avoids creating blocked downstream relations, writes `run_results.json`, and exits with code `1`. Selecting read-only unit-test resources writes a valid manifest and returns a clear unsupported-execution error without writing unit-test run results. Wider generic tests, broader singular-test configs, unit-test execution, typed scalar accepted-value artifact parity, unsupported custom generic-test configs, hooks, grants, docs persistence, full-refresh semantics, broader seed config parity, `store_failures_as`, full dbt queue interleaving, independent-resource continuation after failure, full indirect-selection modes, generic-test runtime-error rows, and adapter materialization macro execution remain explicit boundaries. The seed config slice is documented above in the issue #179 source note; the data-test failure blocking slice is documented in `.agent/research/m3-build-test-failure-skip.md`; the generic-test config/severity slice is documented in `.agent/research/m3-duckdb-generic-test-configs.md`.
- Synthetic fixtures cover one model, model refs, seed refs, source refs, narrow scalar var-backed model/source refs with CLI overrides and positional string defaults, exposure refs to models and sources, combined source/model YAML, inline config/tag/model-enabled parsing, inline-disabled singular SQL tests, singular SQL test YAML patches/configs and execution, config materialization selection, comma-intersection selection, YAML model properties and columns, emitted `unique`, `not_null`, `accepted_values`, and `relationships` generic test nodes, singular SQL test nodes and execution, project macro artifacts, macro block variants, macro materialization `supported_languages`, and macro properties including patched `docs` and `meta`, configured `macro-paths` replacing the default macro directory, installed package macros with package-qualified calls and package-local macro calls, installed package models, seeds, sources, docs, exposures, package YAML model properties, root package config overrides, and package-qualified/package-local refs/sources, macro calls recorded in model and macro `depends_on.macros`, docs blocks with literal `doc` descriptions, disabled models, disabled singular tests, disabled ref diagnostics, unmatched model-property warnings, duplicate model and docs diagnostics, unsupported dynamic doc diagnostics, unresolved var diagnostics for var-backed refs without scalar/default values, missing doc diagnostics, malformed docs block diagnostics, unresolved package macro diagnostics, and unsupported unknown macro-call diagnostics.
- The committed M1 public Jaffle gate lives in `scripts/check_jaffle_shop_duckdb_parse.py`. It clones a pinned public Jaffle Shop DuckDB ref into a temporary directory by default, runs the Zig `dxt` binary, validates the current M1 manifest schema slice, asserts the supported partial manifest shape with five SQL models, three CSV seeds, two docs blocks, twenty supported generic test nodes, model/test `refs` artifact fields, dependency maps, materialization/docs config, and checks representative `dxt ls` selector behavior for resource types, materialization config, wildcards, path selectors, and graph expansion. It is a developer-side Python compatibility harness only; product parse/list behavior remains implemented in Zig. The M3 public Jaffle build gate lives in `scripts/check_jaffle_shop_duckdb_build.py` and runs the same pinned public fixture through `dxt build`, then validates manifest shape, selector behavior, `run_results.json` resource/status counts, and representative DuckDB relation contents. The M3 public Jaffle run gate lives in `scripts/check_jaffle_shop_duckdb_run.py`; it prepares only seed relations, runs `dxt run`, and validates model-only Run Results v6 shape, dependency order, compiled model results, and representative DuckDB relation contents. The public Jaffle docs gate lives in `scripts/check_jaffle_shop_duckdb_docs.py`; it builds the fixture, runs `dxt docs generate`, and validates compiled docs manifest fields plus a populated Catalog v1-shaped model/seed catalog. GitHub CI runs all four public Jaffle gates in the existing public-fixture context, installing a pinned and checksum-verified DuckDB CLI for execution/docs gates and reusing the already-built Zig binary. Remaining M1/M2/M3 work includes package-provided tests/macros beyond the current narrow macro call surface, deeper artifact parity, full Jinja/macro behavior, and broader execution semantics beyond the supported public Jaffle DuckDB subset.
- Selector wildcard behavior is currently pinned to observed dbt Core 1.10 behavior. dbt Fusion preview currently differs for resource-type-prefixed wildcard selectors such as `model.<package>.*` and filename-suffix path selectors such as `path:*orders.sql`; a future Fusion-compatibility slice must decide whether to support a selector dialect switch or a compatible superset.
- Compatibility planning now uses a source-grounded reference map under `.agent/research/dbt-upstream-reference-map.md`; future feature slices should name upstream dbt v1/v2 source references, dxt Zig owners, affected artifact fields, validation gates, and stop conditions before implementation.
- The committed dbt Core M1 oracle harness lives in `scripts/check_dbt_core_m1_oracle.py`. It is optional developer-side Python tooling that requires `dbt-core` and `dbt-duckdb`, invokes dbt Core through its Python runner, runs `dxt parse` through the Zig binary, and compares stable manifest slices for the supported synthetic M1 fixture ladder. It ignores dbt internal package docs/macros that are outside the current dxt artifact scope, records a known allowed gap for installed-package exposure refs that dbt Core resolves to a root same-name model while dxt currently resolves package-local, and leaves full source-map parity, full artifact schemas, and execution parity for later slices.
- Before broadening M2 product implementation, close or explicitly re-scope the remaining M1 macro-compatibility behavior gaps. Macro `docs`/`meta` patch fields are covered for the current scalar artifact subset. Macro argument extraction under dbt Core v1 `flags.validate_macro_args` semantics and YAML patch argument validation/replacement are implemented for the manifest artifact surface. Static macro dependency lookup now uses the supported dbt order of current package, root project, other-package fallback for macro bodies, graph-present internal `dbt` macros, literal `adapter.dispatch(...)` dependency extraction, and return-wrapper dispatch dependency extraction. Parse-time dispatch prefixes now come from a narrow source-grounded `profiles.yml` adapter identity parser and emit manifest `metadata.adapter_type`, with default DuckDB behavior preserved when no profile file is loaded. Root-project `dispatch:` config search order is now honored for static `adapter.dispatch(...)` dependency extraction. Compile/runtime macro rendering is limited to the Jaffle-style dispatch wrapper subset documented in `.agent/research/m2-minimal-macro-dispatch-rendering.md`; bundled dbt internal macros, full target context inside macros, credential validation, general macro execution, and materialization runtime lookup remain planned. `{% data_test %}` has native source-grounded parser coverage, but the local dbt Core 1.10 oracle rejects that tag before writing artifacts, so dbt-oracle coverage currently pins `{% test %}` and `{% materialization %}` block parity.

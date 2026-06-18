# Changelog

All notable changes to `dxt` are documented here.

This project is pre-alpha. Entries describe supported slices, not full dbt
compatibility.

## Unreleased

### Added

- Documentation baseline with a reader-focused README, primer, compatibility
  matrix, architecture diagrams, release process, and changelog.
- GitHub Actions release workflow for tagged native Zig binary artifacts and
  checksums.
- Source-grounded upstream reference-map refresh with the next five small
  dbt Core/Fusion-backed compatibility slices.
- Future SQLMesh reference-map note for later state, plan/apply,
  environment, audit, incremental, multi-engine gateway, and adapter capability
  design once the dbt Core baseline is mature enough.
- Table-level model, seed, and source built-in generic tests with explicit
  `arguments.column_name`, including Manifest kwargs and DuckDB `build`
  execution for the existing supported test types while preserving dbt's
  table-level `column_name: null` artifact attachment semantics.
- Literal `source('source', 'table')` targets for built-in `relationships`
  generic tests on models, seeds, and sources, including dbt-shaped Manifest
  source dependency ordering and DuckDB source-to-source execution.
- Root-project seed column generic-test parsing and DuckDB execution for
  `not_null`, `unique`, explicit `accepted_values` `quote: false`, and
  ref-backed `relationships`, including seed-path schema YAML discovery,
  seed manifest columns/patch metadata, and seed+test run-results coverage.
- Source column ref-backed `relationships` generic-test parsing and DuckDB
  execution, including source-style manifest refs/sources dependencies and
  pass/fail run-results coverage against existing source and target relations.
- Explicit `accepted_values` `quote: false` support for model and source column
  DuckDB generic tests, including dbt-style synthetic names, hash metadata,
  Manifest kwargs, raw SQL rendering, and pass/fail execution.
- Narrow Zig compile/runtime rendering for Jaffle-style macro dispatch wrappers
  such as `cents_to_dollars`, including adapter/default implementation
  selection, manifest macro dependency coverage, and DuckDB run/build
  integration coverage.
- Source/table `config:` parsing for `loaded_at_field`, `loaded_at_query`, and
  freshness inheritance, narrow source `schema: "{{ target.schema }}_raw"`
  rendering, expanded Manifest v12-shaped source fields, and DuckDB source
  freshness execution against resolved inherited source settings.
- Source table `identifier` parsing as a physical relation-name override for
  `source()` compilation, manifest source fields, DuckDB docs catalog lookup,
  source freshness SQL, and source generic-test relation rendering while
  preserving logical source selectors and unique IDs.
- Read-only unit-test artifact support for dict-style YAML `unit_tests:`
  entries, Manifest v12-shaped `unit_tests`, tested-model dependency maps,
  `ls` resource-type/unit-test/test-type selectors, and explicit unsupported
  `build` behavior without unit-test `run_results.json`.
- `file:` selector support for basename/stem matching across selectable graph
  resources, with selector reuse covered through `ls` and `docs generate`.
- Depth-limited dbt-style `+` graph selectors for parent and child expansion,
  including `1+model`, `model+1`, and combined `1+model+1` forms.
- `@` graph selector support for selecting descendants and the parents needed
  to build those descendants in the supported graph subset.
- `dxt ls --output name`, `--output path`, and `--output selector` formats,
  while preserving the legacy text and JSON outputs.
- Narrow `dxt ls --output json --output-keys ...` filtering for compact
  selected-resource JSON fields.
- Narrow compile rendering for static `{% if %}` branches, including
  compile-phase `execute` and static dependency recovery for guarded refs and
  sources.

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

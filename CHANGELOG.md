# Changelog

All notable changes to `dxt` are documented here.

This project is pre-alpha. Entries describe supported slices, not full dbt
compatibility.

## Unreleased

### Added

- `dxt seed` command for selected root-project DuckDB CSV seeds, reusing the
  Zig seed execution boundary, writing `manifest.json` and seed-shaped Run
  Results v6 rows, filtering mixed selections to seeds, and rejecting
  selections that match no seeds before DuckDB side effects.
- Singular SQL data tests in the Zig runtime, including `test-paths`
  discovery with `generic/` and `fixtures/` skipped, Manifest nodes without
  generic-only fields, `test_type:singular` / `test_type:data` selection, and
  DuckDB `build` / `test` execution through dbt-style failure-row counting.
- Documentation baseline with a reader-focused README, primer, compatibility
  matrix, architecture diagrams, release process, and changelog.
- GitHub Actions release workflow for tagged native Zig binary artifacts and
  checksums.
- Source-grounded upstream reference-map refresh with the next five small
  dbt Core/Fusion-backed compatibility slices.
- Future SQLMesh reference-map note for later state, plan/apply,
  environment, audit, incremental, multi-engine gateway, and adapter capability
  design once the dbt Core baseline is mature enough.
- `dxt test` command for the existing DuckDB generic-test execution subset,
  writing `manifest.json` and Run Results v6-shaped `run_results.json` for
  supported `not_null`, `unique`, `accepted_values`, and `relationships` tests
  against already-existing target relations.
- Partial DuckDB execution-failure artifacts for `dxt run` and supported
  `dxt build` model/seed branches, writing completed prior `run_results.json`
  rows plus a sanitized `status: "error"` row for the failed resource and
  returning exit code `1`.
- Partial skipped-result propagation for `dxt run` and supported `dxt build`
  model/seed execution failures, writing `status: "skipped"` rows for selected
  blocked descendants and selected blocked generic tests while preserving
  `--exclude`.
- Selector wildcard parity for bracket character classes in the shared Zig
  selector engine, covering `file:` and slash-aware `path:` selectors used by
  `dxt ls` and other selector-backed commands.
- CI validation pyramid split into native Zig/safety, Python integration matrix,
  and public Jaffle parse/build/run/docs gates with a pinned and
  checksum-verified DuckDB CLI, pytest JUnit reports, and focused local
  validation guidance.
- GitHub CI stale-run cancellation, job timeouts, and a native Zig test coverage
  map artifact workflow for Zig source/build changes, main pushes, and manual
  coverage runs. The coverage summary now renders as Markdown with real native
  test declaration counts instead of escaped newline text. The public Jaffle job
  now fetches the pinned fixture checkout once and passes it to each public
  harness to reduce repeated network clone work.
- Shared Zig JSON writer helpers for artifact emission, replacing duplicated
  per-artifact string escaping helpers across manifest, run-results, catalog,
  and sources writers while keeping behavior stable.
- Strict JSON object parsing for stringified scalar `--vars` / project vars in
  the Zig parser, while preserving the existing loose inline YAML-style scalar
  map support for current fixtures.
- `dxt ls --output json --output-keys` compact selected-resource expansion for
  `package_name` and source-only `source_name`.
- Table-level model, seed, and source built-in generic tests with explicit
  `arguments.column_name`, including Manifest kwargs and DuckDB `build`
  execution for the existing supported test types while preserving dbt's
  table-level `column_name: null` artifact attachment semantics.
- Literal `source('source', 'table')` targets for built-in `relationships`
  generic tests on models, seeds, and sources, including dbt-shaped Manifest
  source dependency ordering and DuckDB source-to-source execution.
- Static `dxt docs serve` command in the Zig runtime, serving generated
  target-directory docs artifacts over localhost HTTP with dbt-style host,
  port, no-browser/browser flag parsing, traversal protection, and integration
  coverage that verifies `manifest.json` and `catalog.json` are not mutated.
- Safe `dxt clean` command in the Zig runtime, including `clean-targets`
  parsing, effective `target-path` fallback, project-relative deletion guards,
  source-directory protection, profile-free execution, and CLI safety tests.
- Parse/list dependency recovery for static Jinja string-list loops, so
  `ref(loop_var)` and `source('raw', loop_var)` inside supported `{% for %}`
  loops populate manifest dependencies and selector graph expansion.
- Compile-time relation rendering for static Jinja string-list loop variables,
  so supported `ref(loop_var)`, `ref('package', loop_var)`, and
  `source('raw', loop_var)` calls render through `compile`, `docs generate`,
  `run`, and `build`.
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
- `dxt ls --output json --output-keys ...` support for compact resource
  locator fields `path`, `original_file_path`, and `selector`.
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

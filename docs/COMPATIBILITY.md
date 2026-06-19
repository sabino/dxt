# Compatibility Matrix

`dxt` is pre-alpha. The current surface is a documented subset of dbt Core
behavior, with DuckDB as the first deterministic execution adapter.

## Commands

| Command | Status | Current support | Planned gaps |
| --- | --- | --- | --- |
| `dxt parse` | Partial | Loads supported project files and writes a deterministic Manifest v12-shaped slice, including analysis SQL resources, disabled SQL models from YAML properties, literal inline model `config(enabled=false)`, and literal inline singular test `config(enabled=false)`. | Full dbt parser parity, saved queries, semantic resources, full package behavior. |
| `dxt ls` | Partial | Lists selected graph resources in text or JSON for supported selector syntax. | YAML selectors, state/result/source-status selectors, full indirect-selection parity. |
| `dxt clean` | Partial | Deletes configured project-relative `clean-targets`, defaulting to the effective target path; protects source directories, rejects outside-project deletion, skips missing paths and plain files, and does not require a profile. | `--no-clean-project-files-only`, Fusion positional file args, symlink/canonical-path parity, richer dbt event output. |
| `dxt compile` | Partial | Compiles selected enabled SQL models, selected analyses, selected supported built-in generic tests, and selected singular SQL tests through the supported render-only Jinja subset and writes compiled SQL plus manifest fields without opening DuckDB. | Custom generic test macro compilation, full Jinja, macro execution, adapter dispatch execution, arbitrary expressions, filters, hooks. |
| `dxt run` | Partial | Executes selected enabled DuckDB SQL models with `table` and `view` materializations; writes completed prior rows plus a sanitized `error` run-result row when a selected model fails during DuckDB execution, followed by `skipped` rows for selected blocked model descendants. | Seeds, tests, snapshots, incremental, ephemeral, hooks, grants, independent-resource continuation after failures, full materialization macros. |
| `dxt seed` | Partial | Executes selected root-project DuckDB CSV seeds, writes `manifest.json` and seed-shaped `run_results.json`, filters mixed selections to seed resources, and rejects selections that match no seeds before opening DuckDB. | Package seed execution, seed configs, `quote_columns`, `column_types`, hooks, grants, full-refresh semantics, full materialization macros. |
| `dxt test` | Partial | Executes selected supported DuckDB generic tests and singular SQL tests against existing target relations and writes `manifest.json` plus `run_results.json`. | Unit-test execution, custom generic macros, singular YAML patches/configs, test configs, store failures, building parents before tests. |
| `dxt build` | Partial | Executes root-project CSV seeds, selected DuckDB models, supported model/source/seed column generic tests, singular SQL tests, explicit table-level `column_name` built-in tests, source-target `relationships`, and mixed selected seed/model/test subsets; writes sanitized model/seed execution-error rows and `skipped` rows for selected blocked descendants/tests before exiting; selected model/seed builds now run ready data tests before downstream selected resources and skip selected blocked descendants after a failing data test. | Full dbt queue semantics, package seeds, seed configs, wider tests, full singular-test configs/patches, unit-test execution, generic-test runtime errors, independent-resource continuation, full indirect-selection modes, store failures. |
| `dxt docs generate` | Partial | Writes `manifest.json`, compiled SQL, and `catalog.json`; introspects selected existing DuckDB model/seed/source relations when available. | Docs-time execution, comments/owners/stats, richer source config, bundled dbt docs UI assets. |
| `dxt docs serve` | Partial | Serves generated target-directory docs artifacts over localhost HTTP with `--host`, `--port`, `--no-browser`, `--browser`, and `--no-open` parsing; writes a small dxt-owned `index.html`; does not mutate `manifest.json` or `catalog.json`. | Browser opening, dbt's bundled docs SPA, Fusion docs v2/index API server, live reload, richer static asset handling. |
| `dxt source freshness` | Partial | Queries selected DuckDB source tables with resolved source/table `loaded_at_field`, `loaded_at_query`, and freshness settings, then writes Sources v3-shaped results. | Metadata freshness, Jinja in freshness queries beyond narrow source schema rendering, source-status selectors, concurrency, non-DuckDB adapters. |
| `version`, help | Supported | Basic CLI metadata and help. | Release version stamping beyond current build metadata. |
| `debug`, `deps`, `init`, `run-operation`, `snapshot`, `retry`, `clone` | Planned | Not implemented. | Command-specific dbt parity. |

## Flags

| Flag | Status | Notes |
| --- | --- | --- |
| `--project-dir` | Supported | Used by all project commands. |
| `--profiles-dir`, `--profile`, `--target` | Partial | Narrow scalar `profiles.yml` handling for adapter type, schema, target name, profile name, and DuckDB path. |
| `--target-path` | Supported | Overrides project target path for artifacts and default DuckDB file. |
| `--vars` | Partial | Scalar CLI vars for narrow `ref()` / `source()` argument resolution, accepting strict JSON objects with stringified scalar values and the existing loose inline YAML-style scalar maps. |
| `--select`, `--exclude` | Partial | Supported selector subset with graph expansion. |
| `--threads`, `--full-refresh` | Accepted/planned | Product semantics are not complete yet. |
| `--output`, `--output-keys` | Partial | `ls` supports legacy `text`, compact `json`, dbt-style `name`, `path`, and `selector` formats. `--output-keys` filters compact JSON to `unique_id`, `resource_type`, `name`, `package_name`, `source_name`, `alias`, source-only `identifier`, `path`, `original_file_path`, `tags`, `config.materialized`, `config.tags`, `config.enabled`, `config.docs.show`, `depends_on.nodes`, `depends_on.macros`, and dxt's compact `selector` extension; full dbt node JSON and arbitrary nested-key traversal are not implemented. |
| `--host`, `--port`, `--no-browser`, `--browser`, `--no-open` | Partial | `docs serve` parses these dbt Core/Fusion-shaped flags. Browser opening is intentionally unsupported in this slice; use `--no-browser`. |
| `--clean-project-files-only`, `--no-clean-project-files-only` | Partial | `clean` accepts the default safe `--clean-project-files-only` mode. `--no-clean-project-files-only` is rejected in this first destructive-command slice. |

## dbt Resources

| Resource | Status | Current support | Planned gaps |
| --- | --- | --- | --- |
| Models | Partial | SQL discovery, refs/sources/docs/macros, YAML properties, columns, tags, materialized config, literal inline `enabled`, compile/run/build subset. | Full config precedence, contracts, versions, groups, access, incremental/ephemeral/snapshots, hooks/grants. |
| Analyses | Partial | SQL discovery from `analysis-paths`/default `analyses`, refs/sources/macros, YAML descriptions/tags/columns, Manifest nodes, `resource_type:analysis` listing, and selected `compile` output under `target/compiled/<package>/analysis/...`. | Multi-statement analysis splitting, full configs, tests on analyses, docs/UI parity, and execution semantics if dbt/Fusion require them. |
| Seeds | Partial | CSV discovery, root-project DuckDB `seed` and `build` execution, seed YAML column metadata, and supported root-project seed column or explicit table-level `column_name` generic tests including ref-backed and source-target relationships. | Package seed execution, seed configs, `quote_columns`, `column_types`, full materialization semantics. |
| Sources | Partial | YAML source tables, source/table freshness config inheritance, narrow source schema rendering, table `identifier` physical-name overrides, source refs, source columns, source column and explicit table-level `column_name` tests including ref-backed and source-target relationships, catalog/source freshness subset. | Richer relation config such as database/quoting/project-level source config, metadata freshness. |
| Exposures | Partial | YAML exposure parsing with refs/sources, tags, metadata, owner fields. | Full validation and richer artifact parity. |
| Macros | Partial | Macro/test/data_test/materialization block extraction, macro properties, static macro dependency lookup. | Macro execution, namespace execution, adapter dispatch execution, bundled dbt internals. |
| Docs blocks | Partial | Markdown docs block parsing and literal `doc()` descriptions. | Dynamic doc expressions and full dbt docs UI behavior. |
| Generic tests | Partial | Manifest nodes, `compile` artifacts, and DuckDB execution for supported model, seed, and source column built-ins plus explicit table-level `column_name` built-ins, including explicit `accepted_values` `quote: false` and literal source-target `relationships`. | Custom macro-backed tests, configs, typed scalar value artifact parity, store failures. |
| Singular tests | Partial | SQL files under configured `test-paths` are parsed as singular data tests, excluding `generic/` and `fixtures/`; literal inline `config(enabled=false)` disables singular tests into `manifest.disabled`; manifest nodes omit generic-only fields, selectors support `test_type:singular` and `test_type:data`, `compile` writes selected compiled artifact paths, and DuckDB `build`/`test` executes them through failure-row counting. | YAML patches/configs, dynamic enabled expressions, severity and threshold configs, `where`, `limit`, `store_failures`, indirect-selection parity, broader Jinja/macros. |
| Unit tests | Partial | Read-only YAML parsing for dict-style `given`/`expect` row fixtures, Manifest v12-shaped `unit_tests`, parent/child maps, `resource_type:unit_test`, `unit_test:`, and `test_type:unit` listing. | Execution, fixture materialization, CSV/SQL fixtures, overrides, version expansion, disabled-unit-test placement, SQL comparison, and run-results. |
| Snapshots, semantic models, metrics, saved queries, functions, groups | Planned | Not first-class yet or only empty artifact maps where needed. | Full parser, graph, artifact, and execution semantics. |

## Jinja And Macros

| Surface | Status | Notes |
| --- | --- | --- |
| `ref()` | Partial | Literal, narrow scalar var-backed, and static loop-var refs in parse/list and compile-time relation rendering. |
| `source()` | Partial | Literal, narrow scalar var-backed, and static loop-var sources in parse/list and compile-time relation rendering. |
| `config()` | Partial | Inline tags, materialized, schema, alias, literal model `enabled`, and literal singular-test `enabled` in supported forms. |
| `var()` | Partial | Scalar CLI/project vars for selected dependency arguments; strict JSON object input is parsed through Zig `std.json` and scalar values are stringified for the current dependency-argument resolver, with loose inline YAML-style scalar maps still accepted. |
| `doc()` | Partial | Literal doc references. |
| `target`, `this` | Partial | Narrow compile context for selected fields. |
| `{% set %}` / `{% for %}` / `{% if %}` | Partial | Static string-list assignments, simple loops, loop-var dependency recovery and relation rendering, and narrow static conditionals only. |
| `execute`, `run_query`, `statement`, adapter introspection | Partial/planned | Compile/run-style rendering treats `execute` as true for static `if`; database-backed Jinja behavior remains planned. |
| Macro execution and dispatch | Partial | Static discovery/dependency extraction plus a narrow Jaffle-style adapter dispatch wrapper rendering subset. |

## Selectors

| Selector surface | Status |
| --- | --- |
| Names/FQN subset | Partial |
| `+` graph expansion | Partial; includes dbt-style unlimited and depth-limited parent/child forms such as `+model`, `model+`, `1+model`, `model+1`, and `1+model+1`. |
| `@` graph expansion | Partial; selects descendants plus the parents needed for those descendants in the supported graph subset. |
| `--exclude` | Partial |
| `tag:`, `path:`, `file:`, `package:`, `resource_type:`, `test_type:`, `config.materialized:` | Partial; wildcard matching includes `*`, `?`, and fnmatch-style bracket character classes in the supported selector methods. |
| `source:`, `exposure:`, selected generic test names | Partial |
| Wildcards | Partial; pinned to observed dbt Core behavior where tested. |
| YAML selectors, state/result/source-status/access/group/version selectors | Planned |

## Artifacts

| Artifact | Status | Current support |
| --- | --- | --- |
| `manifest.json` | Partial | Deterministic Manifest v12-shaped slice for supported resources, dependencies, source columns, tests, and maps. |
| `run_results.json` | Partial | Run Results v6-shaped rows for supported model/seed/test execution, including sanitized model/seed execution `error` rows and selected blocked-resource `skipped` rows in the supported run/build branches. |
| `catalog.json` | Partial | Catalog v1-shaped entries for selected existing DuckDB relations. |
| `sources.json` | Partial | Sources v3-shaped freshness rows for supported source freshness queries. |
| `semantic_manifest.json` | Planned | Semantic resource support remains future work. |
| `partial_parse.msgpack` / parse cache | Planned | Future performance/state work. |

## Adapters And Execution

| Adapter/execution area | Status | Notes |
| --- | --- | --- |
| DuckDB | Partial | Current execution uses a Zig-owned external DuckDB CLI backend. |
| Embedded DuckDB | Planned | Long-term native adapter direction. |
| Postgres | Planned | Next server-database semantics target after adapter ABI. |
| Snowflake, BigQuery, Redshift | Planned | After adapter ABI and conformance tests stabilize. |
| Cross-database planner | Planned | Architecture requires pushdown, staging, movement policy, and cost guards. |

## Validation

| Gate | Status | Purpose |
| --- | --- | --- |
| `zig build` | Supported | Native compile gate. |
| `zig build test` | Supported | Native unit/regression gate. |
| Focused local pytest | Supported | Fast black-box CLI/artifact fixture checks for touched behavior. |
| Full pytest matrix | Supported in CI | Full black-box CLI/artifact fixture gate on Python 3.11 and 3.12 with JUnit reports. |
| Native Zig coverage artifacts | Supported in CI | Optional GitHub native Zig test coverage map artifacts for Zig source/build changes, main pushes, and manual coverage runs. |
| Runtime-boundary scan | Supported | Prevents Python product-runtime drift. |
| Public-safety scan | Supported | Prevents secrets/local paths/generated noise. |
| Jaffle parse/build/run/docs scripts | Partial | Public fixture compatibility gates for current supported subset; CI runs the public parse, DuckDB build, DuckDB run, and docs-generate gates with a pinned, checksum-verified DuckDB CLI. Local build/run/docs gate runs require the `duckdb` CLI on `PATH`. |
| dbt Core oracle harness | Partial | Optional developer-side comparison for supported M1 fixtures. |

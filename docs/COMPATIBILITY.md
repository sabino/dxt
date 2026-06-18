# Compatibility Matrix

`dxt` is pre-alpha. The current surface is a documented subset of dbt Core
behavior, with DuckDB as the first deterministic execution adapter.

## Commands

| Command | Status | Current support | Planned gaps |
| --- | --- | --- | --- |
| `dxt parse` | Partial | Loads supported project files and writes a deterministic Manifest v12-shaped slice. | Full dbt parser parity, disabled resource maps, saved queries, semantic resources, full package behavior. |
| `dxt ls` | Partial | Lists selected graph resources in text or JSON for supported selector syntax. | YAML selectors, state/result/source-status selectors, full indirect-selection parity. |
| `dxt compile` | Partial | Compiles selected enabled SQL models through the supported render-only Jinja subset and writes compiled SQL plus manifest fields. | Full Jinja, macro execution, adapter dispatch execution, arbitrary expressions, filters, hooks. |
| `dxt run` | Partial | Executes selected enabled DuckDB SQL models with `table` and `view` materializations. | Seeds, tests, snapshots, incremental, ephemeral, hooks, grants, failure/partial run-results, full materialization macros. |
| `dxt build` | Partial | Executes root-project CSV seeds, selected DuckDB models, supported model/source/seed column generic tests, explicit table-level `column_name` built-in tests, source-target `relationships`, and mixed selected seed/model/test subsets. | Full dbt queue semantics, package seeds, seed configs, wider tests, singular/unit tests, skip/fail-fast, store failures. |
| `dxt docs generate` | Partial | Writes `manifest.json`, compiled SQL, and `catalog.json`; introspects selected existing DuckDB model/seed/source relations when available. | Docs-time execution, comments/owners/stats, richer source config, bundled dbt docs UI assets. |
| `dxt docs serve` | Partial | Serves generated target-directory docs artifacts over localhost HTTP with `--host`, `--port`, `--no-browser`, `--browser`, and `--no-open` parsing; writes a small dxt-owned `index.html`; does not mutate `manifest.json` or `catalog.json`. | Browser opening, dbt's bundled docs SPA, Fusion docs v2/index API server, live reload, richer static asset handling. |
| `dxt source freshness` | Partial | Queries selected DuckDB source tables with resolved source/table `loaded_at_field`, `loaded_at_query`, and freshness settings, then writes Sources v3-shaped results. | Metadata freshness, Jinja in freshness queries beyond narrow source schema rendering, source-status selectors, concurrency, non-DuckDB adapters. |
| `version`, help | Supported | Basic CLI metadata and help. | Release version stamping beyond current build metadata. |
| `debug`, `clean`, `deps`, `init`, `run-operation`, `snapshot`, `retry`, `clone` | Planned | Not implemented. | Command-specific dbt parity. |

## Flags

| Flag | Status | Notes |
| --- | --- | --- |
| `--project-dir` | Supported | Used by all project commands. |
| `--profiles-dir`, `--profile`, `--target` | Partial | Narrow scalar `profiles.yml` handling for adapter type, schema, target name, profile name, and DuckDB path. |
| `--target-path` | Supported | Overrides project target path for artifacts and default DuckDB file. |
| `--vars` | Partial | Scalar CLI vars for narrow `ref()` / `source()` argument resolution. |
| `--select`, `--exclude` | Partial | Supported selector subset with graph expansion. |
| `--threads`, `--full-refresh` | Accepted/planned | Product semantics are not complete yet. |
| `--output`, `--output-keys` | Partial | `ls` supports legacy `text`, compact `json`, dbt-style `name`, `path`, and `selector` formats. `--output-keys` filters compact JSON to `unique_id`, `resource_type`, and `name`; full dbt node JSON and nested keys are not implemented. |
| `--host`, `--port`, `--no-browser`, `--browser`, `--no-open` | Partial | `docs serve` parses these dbt Core/Fusion-shaped flags. Browser opening is intentionally unsupported in this slice; use `--no-browser`. |

## dbt Resources

| Resource | Status | Current support | Planned gaps |
| --- | --- | --- | --- |
| Models | Partial | SQL discovery, refs/sources/docs/macros, YAML properties, columns, tags, materialized config, compile/run/build subset. | Full config precedence, contracts, versions, groups, access, incremental/ephemeral/snapshots, hooks/grants. |
| Seeds | Partial | CSV discovery, root-project DuckDB seed build execution, seed YAML column metadata, and supported root-project seed column or explicit table-level `column_name` generic tests including ref-backed and source-target relationships. | Package seed execution, seed configs, `quote_columns`, `column_types`, `dxt seed`, full materialization semantics. |
| Sources | Partial | YAML source tables, source/table freshness config inheritance, narrow source schema rendering, table `identifier` physical-name overrides, source refs, source columns, source column and explicit table-level `column_name` tests including ref-backed and source-target relationships, catalog/source freshness subset. | Richer relation config such as database/quoting/project-level source config, metadata freshness. |
| Exposures | Partial | YAML exposure parsing with refs/sources, tags, metadata, owner fields. | Full validation and richer artifact parity. |
| Macros | Partial | Macro/test/data_test/materialization block extraction, macro properties, static macro dependency lookup. | Macro execution, namespace execution, adapter dispatch execution, bundled dbt internals. |
| Docs blocks | Partial | Markdown docs block parsing and literal `doc()` descriptions. | Dynamic doc expressions and full dbt docs UI behavior. |
| Generic tests | Partial | Manifest nodes and DuckDB execution for supported model, seed, and source column built-ins plus explicit table-level `column_name` built-ins, including explicit `accepted_values` `quote: false` and literal source-target `relationships`. | Custom macro-backed tests, singular tests, configs, typed scalar value artifact parity, store failures. |
| Unit tests | Partial | Read-only YAML parsing for dict-style `given`/`expect` row fixtures, Manifest v12-shaped `unit_tests`, parent/child maps, `resource_type:unit_test`, `unit_test:`, and `test_type:unit` listing. | Execution, fixture materialization, CSV/SQL fixtures, overrides, version expansion, disabled-unit-test placement, SQL comparison, and run-results. |
| Analyses, snapshots, semantic models, metrics, saved queries, functions, groups | Planned | Not first-class yet or only empty artifact maps where needed. | Full parser, graph, artifact, and execution semantics. |

## Jinja And Macros

| Surface | Status | Notes |
| --- | --- | --- |
| `ref()` | Partial | Literal and narrow scalar var-backed refs. |
| `source()` | Partial | Literal and narrow scalar var-backed sources. |
| `config()` | Partial | Inline tags, materialized, schema, alias in supported literal forms. |
| `var()` | Partial | Scalar CLI vars for selected dependency arguments. |
| `doc()` | Partial | Literal doc references. |
| `target`, `this` | Partial | Narrow compile context for selected fields. |
| `{% set %}` / `{% for %}` / `{% if %}` | Partial | Static string-list assignments, simple loops, and narrow static conditionals only. |
| `execute`, `run_query`, `statement`, adapter introspection | Partial/planned | Compile/run-style rendering treats `execute` as true for static `if`; database-backed Jinja behavior remains planned. |
| Macro execution and dispatch | Partial | Static discovery/dependency extraction plus a narrow Jaffle-style adapter dispatch wrapper rendering subset. |

## Selectors

| Selector surface | Status |
| --- | --- |
| Names/FQN subset | Partial |
| `+` graph expansion | Partial; includes dbt-style unlimited and depth-limited parent/child forms such as `+model`, `model+`, `1+model`, `model+1`, and `1+model+1`. |
| `@` graph expansion | Partial; selects descendants plus the parents needed for those descendants in the supported graph subset. |
| `--exclude` | Partial |
| `tag:`, `path:`, `file:`, `package:`, `resource_type:`, `test_type:`, `config.materialized:` | Partial |
| `source:`, `exposure:`, selected generic test names | Partial |
| Wildcards | Partial; pinned to observed dbt Core behavior where tested. |
| YAML selectors, state/result/source-status/access/group/version selectors | Planned |

## Artifacts

| Artifact | Status | Current support |
| --- | --- | --- |
| `manifest.json` | Partial | Deterministic Manifest v12-shaped slice for supported resources, dependencies, source columns, tests, and maps. |
| `run_results.json` | Partial | Run Results v6-shaped rows for supported model/seed/test execution. |
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
| `pytest -q` | Supported | Black-box CLI/artifact fixture gate. |
| Runtime-boundary scan | Supported | Prevents Python product-runtime drift. |
| Public-safety scan | Supported | Prevents secrets/local paths/generated noise. |
| Jaffle parse/build scripts | Partial | Public fixture compatibility gates for current supported subset. |
| dbt Core oracle harness | Partial | Optional developer-side comparison for supported M1 fixtures. |

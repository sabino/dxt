# dxt

`dxt` is **Data eXecution & Transformation**: a dbt-project-compatible transformation engine written in Zig.

The first target is dbt Core compatibility for public projects such as Jaffle Shop. The long-term architecture also accounts for semantic resources, metrics, Fusion-style static analysis, and efficient cross-database execution.

This repository is pre-alpha. It currently has a native Zig parser slice for a small dbt project subset, with broader dbt Core compatibility tracked in [PLAN.md](PLAN.md).

## Principles

- Artifact compatibility first.
- dbt Core project semantics before cloud-only or Fusion-only behavior.
- Zig product runtime only; Python is allowed for developer scripts, tests, and compatibility harnesses.
- Local deterministic fixtures before live warehouses.
- Adapter boundaries before adapter breadth.
- Public-safe development with no local paths, credentials, logs, or private data in committed files.

## Current CLI

Build and smoke-test the native CLI:

```sh
zig build
zig build test
zig build -Doptimize=ReleaseSafe
./zig-out/bin/dxt --help
./zig-out/bin/dxt version
```

Implemented pre-alpha commands:

```sh
./zig-out/bin/dxt parse --project-dir tests/fixtures/model_ref --target-path target-dxt
./zig-out/bin/dxt parse --project-dir tests/fixtures/profile_adapter_dispatch --profiles-dir tests/fixtures/profile_adapter_dispatch --target-path target-dxt
./zig-out/bin/dxt parse --project-dir tests/fixtures/adapter_dispatch_project_config --target-path target-dxt
./zig-out/bin/dxt ls --project-dir tests/fixtures/model_ref
./zig-out/bin/dxt ls --project-dir tests/fixtures/model_ref --output json
./zig-out/bin/dxt compile --project-dir tests/fixtures/compile_basic --target-path target-dxt
./zig-out/bin/dxt compile --project-dir tests/fixtures/dynamic_var_ref --target-path target-dxt --vars "{customer_model: alt_customers}"
./zig-out/bin/dxt run --project-dir tests/fixtures/compile_basic --target-path target-dxt --select orders
./zig-out/bin/dxt build --project-dir tests/fixtures/compile_basic --target-path target-dxt --select +orders
./zig-out/bin/dxt build --project-dir tests/fixtures/seed_ref --target-path target-dxt --select raw_customers
./zig-out/bin/dxt build --project-dir tests/fixtures/seed_ref --target-path target-dxt --select +stg_customers
./zig-out/bin/dxt run --project-dir tests/fixtures/model_properties --target-path target-dxt --select customers
./zig-out/bin/dxt build --project-dir tests/fixtures/model_properties --target-path target-dxt --select "not_null_customers_customer_id unique_customers_customer_id"
./zig-out/bin/dxt build --project-dir tests/fixtures/source_column_tests --target-path target-dxt --select "source:raw.customers+"
./zig-out/bin/dxt docs generate --project-dir tests/fixtures/docs_blocks --target-path target-dxt
./zig-out/bin/dxt source freshness --project-dir tests/fixtures/source_freshness --target-path target-dxt --select source:raw.customers
```

`parse`, `ls`, `compile`, `run`, `build`, `docs generate`, and `source freshness` currently support only the documented M1/M2 parser and first M3 DuckDB execution subset: `dbt_project.yml` name/profile/model paths/seed paths/macro paths/target path, root-project `dispatch:` search order for static `adapter.dispatch(...)` dependency extraction, `flags.validate_macro_args` for macro manifest argument validation, narrow scalar `profiles.yml` adapter type, schema, and DuckDB local-file `path` selection, scalar `vars`, SQL model and CSV seed discovery, installed package model/seed/source/exposure/macro/docs discovery from `dbt_packages`, literal and narrow scalar var-backed `ref` and `source`, literal `doc`, macro dependency extraction, inline `config`, narrow compile-time Jinja static string-list `set` for unescaped quoted values plus simple `for` loop expansion, narrow YAML model and macro properties, dbt-shaped generic test nodes, deterministic partial `manifest.json`, and the currently implemented selectors.

This is not full dbt `var()` or profile compatibility yet: `vars.yml`, nested/package-scoped vars, non-string values, `var.has_var`, Jinja-rendered var values, profile/project rendering with vars, credential validation, host-global profile lookup, adapter-specific target fields, project/YAML `schema` or `alias` precedence, custom schema/alias macros, and general `var()` usage remain planned.

`compile` applies selectors/excludes to enabled SQL models, writes supported compiled SQL to `target/compiled/<package>/...`, and emits compile fields for compiled models. `run` executes selected enabled DuckDB SQL models with `table` and `view` materializations through a Zig-owned external `duckdb` CLI backend, validates supported materializations before opening DuckDB, executes selected models in dependency order, writes `manifest.json`, writes compiled SQL, materializes relations into either the profile `path` resolved relative to the loaded `profiles.yml` directory or `target/dxt.duckdb`, and emits a minimal dbt-shaped success-only `run_results.json` v6 slice after completed runs. `build` executes root-project DuckDB CSV seed-only selections, selected DuckDB SQL models with `table` and `view` materializations, selected root-project seed+model builds, selected seed+model+supported-generic-test builds, selected model+generic-test builds without seeds, test-only selected DuckDB model/seed column `not_null`/`unique`/default-quoted `accepted_values`/ref-backed `relationships` generic tests, and source+test selected DuckDB source column `not_null`/`unique`/default-quoted `accepted_values` generic tests through the same Zig-owned DuckDB CLI backend. Seed results keep dbt Core-compatible null compiled fields; generic test results use dbt-shaped `pass`/`fail` statuses, integer failure counts, `compiled: true`, and the compiled failure-row SQL as `compiled_code`. Unsupported mixed `build` selections remain truthful preflight boundaries.

`run` does not execute seeds, tests, snapshots, incremental, ephemeral, hooks, grants, docs persistence, failure/partial model run-results artifacts, `:memory:`, MotherDuck, or full dbt intermediate/backup relation semantics yet. `build` does not execute package seeds, seed configs, singular tests, unit tests, table-level source tests, source relationship tests, non-ref relationship targets, custom test configs, hooks, grants, docs persistence, full-refresh semantics, `store_failures`, full dbt queue interleaving, skip/fail-fast semantics, adapter-dispatched/custom generic-test macro overrides, `accepted_values quote: false`, or adapter materialization macros yet. Test-only generic builds require the attached, source, and relationship-parent relations to already exist in the target DuckDB database, such as after a prior `dxt run` into the same `--target-path` for model tests or pre-created source tables for source tests. `docs generate` uses the same render-only compiler, writes `manifest.json`, writes compiled SQL for selected enabled SQL models, and emits `catalog.json`; the catalog remains empty when no local DuckDB database exists, and includes selected model/seed node and source relation metadata and columns when the existing target DuckDB file can be introspected. `source freshness` selects source nodes with table-level freshness criteria, queries selected DuckDB source tables through table-level `loaded_at_field` SQL text plus optional raw `freshness.filter` SQL or through table-level raw `loaded_at_query` SQL, writes `manifest.json`, emits dbt-shaped `sources.json` v3 success rows, emits stale freshness results for empty or all-null loaded-at values, and emits runtime-error rows for unsupported per-source execution gaps such as missing loaded-at configuration or conflicting `loaded_at_field`/`loaded_at_query`. It does not support source-level inheritance, Jinja rendering inside `loaded_at_query`, metadata freshness, `config:` overrides, source-status selectors, hooks, threaded scheduling, or non-DuckDB adapters yet. The compiler currently renders only `config`, literal and narrow scalar var-backed `ref`, literal and narrow scalar var-backed `source`, compile-time `{% set name = ['value'] %}` unescaped string lists plus `{% for item in name %}` body expansion, profile-derived `target.name` / `target.target_name` / `target.schema` / `target.type` / `target.profile_name`, current-model `this` / `this.schema` / `this.name` / `this.table` / `this.identifier`, and default relation schema/identifier output for quoted literal inline `config(schema=..., alias=...)`; macro execution, dynamic dispatch, arbitrary Jinja expressions, filters, loop metadata such as `loop.last`, full adapter-specific target context, source relation config, catalog stats/comments/owners, and `docs serve` remain planned.

## Development

Run tests from the repository root:

```sh
zig build
zig build test
pytest -q
python scripts/check_public_safety.py
python scripts/check_runtime_boundary.py
python scripts/validate_manifest_schema.py target/manifest.json
```

The product runtime requires Zig `0.16.0`. Python remains in this repository only for developer-side validation utilities, not for the `dxt` product runtime.

The first M3 `dxt run`, `dxt build`, docs catalog, and source freshness execution slices use a Zig wrapper around the external
`duckdb` CLI. Install `duckdb` on `PATH` to exercise DuckDB execution tests.
This is a temporary adapter backend boundary; the long-term adapter ABI should
move to embedded DuckDB/linking rather than Python runtime calls.

Use the test layers deliberately:

- `zig build` compiles the native CLI and should run after edits that affect product code or imports.
- `zig build test` runs fast native unit/regression tests for core Zig logic. Add these for parser helpers, selector matching and graph expansion, Jinja scanning, dependency resolution, manifest writer helpers, deterministic ordering, JSON escaping, and internal CLI option logic.
- `pytest -q` runs black-box integration and compatibility checks against the compiled Zig binary. It exists because dbt compatibility is fixture-heavy: tests copy synthetic dbt projects, invoke `dxt`, compare artifacts, validate schema slices, and can use dbt Core oracle behavior. Pytest should not implement product runtime behavior.
- `python scripts/check_runtime_boundary.py` verifies Python has not crossed into product runtime responsibilities.
- `python scripts/check_public_safety.py` scans for committed local paths, secrets, caches, logs, and private artifacts.
- `python scripts/check_jaffle_shop_duckdb_parse.py` clones a pinned public Jaffle Shop DuckDB ref into a temporary directory, runs the Zig `dxt` binary, validates the current M1 manifest schema slice, and checks the supported Jaffle resource/selector shape. Use `--project-dir path/to/jaffle_shop_duckdb` to run against an existing local checkout without cloning.
- `python scripts/check_jaffle_shop_duckdb_build.py` runs the same pinned public Jaffle Shop DuckDB project through `dxt build`, validates the supported manifest and selector shape, checks `run_results.json` resource/status counts, and validates representative DuckDB relations. This is a developer-side compatibility gate for the Zig binary.
- `python scripts/check_dbt_core_m1_oracle.py` is an optional dbt Core oracle harness for supported synthetic M1 fixtures. It requires developer-installed `dbt-core` and `dbt-duckdb`, invokes dbt Core through Python against temporary fixture copies, runs `dxt parse` through the Zig binary, and compares stable manifest slices. Use `--allow-dbt-artifact-on-error` only for known local dbt failures that happen after `manifest.json` is written.

When a feature touches both core logic and user-visible CLI/artifact behavior, prefer both a Zig test for the core rule and a pytest integration/dbt-compatibility test for the end-to-end contract. Mechanical module extractions should pass `zig build test` after each step; run `pytest -q tests/test_cli.py` when CLI output, artifacts, fixtures, selectors, or manifest behavior are touched.

The Jaffle Shop DuckDB gates are public-fixture compatibility checks, not part of the offline local test baseline. Their default mode uses the network to fetch the pinned public ref; pass `--project-dir path/to/jaffle_shop_duckdb` to either Jaffle script when working offline from an existing checkout.

The dbt Core oracle harness is also outside the default CI baseline because this repository does not vendor dbt Core. It is intended for local compatibility evidence before parser/artifact changes are merged.

## Status

Pre-alpha. Do not use for production data transformations yet.

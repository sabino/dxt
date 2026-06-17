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
./zig-out/bin/dxt build --project-dir tests/fixtures/compile_basic --target-path target-dxt --select orders
./zig-out/bin/dxt build --project-dir tests/fixtures/seed_ref --target-path target-dxt --select raw_customers
./zig-out/bin/dxt docs generate --project-dir tests/fixtures/docs_blocks --target-path target-dxt
```

`parse`, `ls`, `compile`, `run`, `build`, and `docs generate` currently support only the documented M1/M2 parser and first M3 DuckDB execution subset: `dbt_project.yml` name/profile/model paths/seed paths/macro paths/target path, root-project `dispatch:` search order for static `adapter.dispatch(...)` dependency extraction, `flags.validate_macro_args` for macro manifest argument validation, narrow scalar `profiles.yml` adapter type, schema, and DuckDB local-file `path` selection, scalar `vars`, SQL model and CSV seed discovery, installed package model/seed/source/exposure/macro/docs discovery from `dbt_packages`, literal and narrow scalar var-backed `ref` and `source`, literal `doc`, macro dependency extraction, inline `config`, narrow YAML model and macro properties, dbt-shaped generic test nodes, deterministic partial `manifest.json`, and the currently implemented selectors.

This is not full dbt `var()` or profile compatibility yet: `vars.yml`, nested/package-scoped vars, non-string values, `var.has_var`, Jinja-rendered var values, profile/project rendering with vars, credential validation, host-global profile lookup, adapter-specific target fields, project/YAML `schema` or `alias` precedence, custom schema/alias macros, and general `var()` usage remain planned.

`compile` applies selectors/excludes to enabled SQL models, writes supported compiled SQL to `target/compiled/<package>/...`, and emits compile fields for compiled models. `run` executes selected enabled DuckDB SQL models with `table` and `view` materializations through a Zig-owned external `duckdb` CLI backend, validates supported materializations before opening DuckDB, executes selected models in dependency order, writes `manifest.json`, writes compiled SQL, materializes relations into either the profile `path` resolved relative to the loaded `profiles.yml` directory or `target/dxt.duckdb`, and emits a minimal dbt-shaped success-only `run_results.json` v6 slice after completed runs. `build` executes root-project DuckDB CSV seed-only selections through the same Zig-owned DuckDB CLI backend and writes `run_results.json` with dbt Core-compatible null compiled fields for seed results; model, test, and mixed seed/model/test `build` selections remain truthful preflight boundaries.

`run` does not execute seeds, tests, snapshots, incremental, ephemeral, hooks, grants, docs persistence, catalog introspection, failure/partial run-results artifacts, `:memory:`, MotherDuck, or full dbt intermediate/backup relation semantics yet. `build` does not execute package seeds, mixed DAGs, seed configs, tests, hooks, grants, docs persistence, full-refresh semantics, or adapter materialization macros yet. `docs generate` uses the same render-only compiler, writes `manifest.json`, writes compiled SQL for selected enabled SQL models, and emits an adapter-free empty `catalog.json` until relation introspection exists. The compiler currently renders only `config`, literal and narrow scalar var-backed `ref`, literal and narrow scalar var-backed `source`, profile-derived `target.name` / `target.target_name` / `target.schema` / `target.type` / `target.profile_name`, current-model `this` / `this.schema` / `this.name` / `this.table` / `this.identifier`, and default relation schema/identifier output for quoted literal inline `config(schema=..., alias=...)`; macro execution, dynamic dispatch, arbitrary Jinja expressions, full adapter-specific target context, mixed build execution, tests, non-empty catalog introspection, and `docs serve` remain planned.

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

The first M3 `dxt run` execution slice uses a Zig wrapper around the external
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
- `python scripts/check_dbt_core_m1_oracle.py` is an optional dbt Core oracle harness for supported synthetic M1 fixtures. It requires developer-installed `dbt-core` and `dbt-duckdb`, invokes dbt Core through Python against temporary fixture copies, runs `dxt parse` through the Zig binary, and compares stable manifest slices. Use `--allow-dbt-artifact-on-error` only for known local dbt failures that happen after `manifest.json` is written.

When a feature touches both core logic and user-visible CLI/artifact behavior, prefer both a Zig test for the core rule and a pytest integration/dbt-compatibility test for the end-to-end contract. Mechanical module extractions should pass `zig build test` after each step; run `pytest -q tests/test_cli.py` when CLI output, artifacts, fixtures, selectors, or manifest behavior are touched.

The Jaffle Shop DuckDB gate is a public-fixture compatibility check, not part of the offline local test baseline. Its default mode uses the network to fetch the pinned public ref; use `python scripts/check_jaffle_shop_duckdb_parse.py --project-dir path/to/jaffle_shop_duckdb` when working offline from an existing checkout.

The dbt Core oracle harness is also outside the default CI baseline because this repository does not vendor dbt Core. It is intended for local compatibility evidence before parser/artifact changes are merged.

## Status

Pre-alpha. Do not use for production data transformations yet.

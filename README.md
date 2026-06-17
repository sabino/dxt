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
./zig-out/bin/dxt docs generate --project-dir tests/fixtures/docs_blocks --target-path target-dxt
```

`parse`, `ls`, `compile`, `run`, `build`, and `docs generate` currently support only the documented M1/M2 parser and render-only subset: `dbt_project.yml` name/profile/model paths/seed paths/macro paths/target path, root-project `dispatch:` search order for static `adapter.dispatch(...)` dependency extraction, `flags.validate_macro_args` for macro manifest argument validation, narrow scalar `profiles.yml` adapter type and schema selection for parse-time dispatch identity plus compile-time target schema, and top-level scalar `vars`, CLI `--vars` scalar overrides, SQL model discovery, CSV seed discovery, installed package SQL model and CSV seed discovery from `dbt_packages`, source discovery, installed package source discovery, exposure discovery, installed package exposure discovery, project macro discovery, installed package macro discovery from `dbt_packages`, project and package docs block discovery, literal and narrow scalar `var('name')` / `var('name', 'default')`-backed `ref` to models or seeds, two-argument package refs, package-local refs in installed package models and exposures, dbt-style fallback from unqualified refs to a unique installed-package model or seed, literal and narrow scalar `var('name')` / `var('name', 'default')`-backed `source`, package-local sources in installed package models, dbt-style fallback from unqualified sources to a unique installed-package source, literal `doc` in descriptions, package-qualified, package-local, root-fallback, macro-body other-package fallback, graph-present internal `dbt` macro dependencies, and literal `adapter.dispatch(...)` macro dependencies using the selected adapter prefix plus `default` with source-grounded parent fallbacks for Redshift and Databricks, basic inline `config`, narrow project and package YAML model properties and macro properties including patched macro `docs`, scalar `meta`, YAML `arguments`, and dbt Core v1-style macro argument annotation warnings, project and package model/seed `+docs.node_color`, root-project model config overrides for installed packages, simple columns, tags, materialization and disabled SQL models, dbt-shaped generic test nodes for `unique`, `not_null`, `accepted_values`, and `relationships`, model/test `refs` and `sources` artifact fields, deterministic partial `manifest.json`, and basic name/tag/path/package/resource/config materialization selectors with exact `package:`/`package:this`, comma intersections, whitespace unions, multi-argument selector lists, repeated selector flags, and graph expansion. This is not full dbt `var()` or profile compatibility yet: `vars.yml`, nested/package-scoped vars, non-string values, `var.has_var`, Jinja-rendered var values, profile/project rendering with vars, credential validation, host-global profile lookup, adapter-specific target fields, and general `var()` usage remain planned. `compile` applies selectors/excludes to enabled SQL models, writes supported compiled SQL to `target/compiled/<package>/...`, and emits compile fields for compiled models. `run` and `build` are truthful execution preflight commands: they parse, resolve, apply selectors/excludes, compile supported selected models, write `manifest.json`, and then fail before execution with a clear adapter-runner boundary error. They do not run SQL, materialize relations, run tests, or write `run_results.json`. `docs generate` uses the same render-only compiler, writes `manifest.json`, writes compiled SQL for selected enabled SQL models, and emits an adapter-free empty `catalog.json` until relation introspection exists. The compiler currently renders only `config`, literal and narrow scalar var-backed `ref`, literal and narrow scalar var-backed `source`, profile-derived `target.name` / `target.target_name` / `target.schema` / `target.type` / `target.profile_name`, and current-model `this` / `this.schema` / `this.name` / `this.table` / `this.identifier`; macro execution, dynamic dispatch, arbitrary Jinja expressions, full adapter-specific target context, materializations, tests, real `run`/`build` execution, non-empty catalog introspection, and `docs serve` remain planned.

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

# dxt

<p align="center">
  <strong>Data eXecution & Transformation</strong>
  <br />
  A Zig-first, dbt-project-compatible transformation engine.
</p>

<p align="center">
  <a href="https://github.com/sabino/dxt/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/sabino/dxt/ci.yml?branch=main&label=CI" alt="CI" /></a>
  <a href="https://github.com/sabino/dxt/releases"><img src="https://img.shields.io/github/v/release/sabino/dxt?include_prereleases&label=release" alt="Release" /></a>
  <img src="https://img.shields.io/badge/runtime-Zig%200.16.0-f7a41d" alt="Zig 0.16.0 runtime" />
  <img src="https://img.shields.io/badge/status-pre--alpha-red" alt="Pre-alpha" />
</p>

`dxt` is building toward a fast native alternative for dbt Core projects. The
first target is artifact-compatible dbt Core behavior for public DuckDB fixtures
such as Jaffle Shop. Fusion-era static analysis, semantic resources, metrics,
and cross-database execution shape the architecture, but dbt Core compatibility
comes first.

This repository is **pre-alpha**. Do not use it for production data
transformations yet.

## Why dxt Exists

- **Native runtime:** implemented product surfaces are Zig; planned parser,
  compiler, planner, adapter, graph, artifact, and runner work must stay Zig.
- **Artifact-first compatibility:** generated artifacts are treated as public
  contracts and validated against pinned dbt-shaped schema slices.
- **Source-grounded implementation:** feature slices name the dbt Core v1 and
  Fusion source files they are matching.
- **Deterministic local validation:** synthetic fixtures and public Jaffle-style
  projects come before live warehouses.
- **Future cross-database execution:** relation identity, adapter capabilities,
  staging, and movement policies are explicit architecture concerns.

## Quick Start

Install Zig `0.16.0`, then build and smoke-test the native binary:

```sh
zig build
zig build test
./zig-out/bin/dxt --help
./zig-out/bin/dxt version
```

Run a small parse/list/compile flow:

```sh
./zig-out/bin/dxt parse --project-dir tests/fixtures/model_ref --target-path target-dxt
./zig-out/bin/dxt ls --project-dir tests/fixtures/model_ref --output json
./zig-out/bin/dxt ls --project-dir tests/fixtures/model_ref --output json --output-keys unique_id name
./zig-out/bin/dxt compile --project-dir tests/fixtures/compile_basic --target-path target-dxt
```

Run the current DuckDB execution slices:

```sh
./zig-out/bin/dxt run --project-dir tests/fixtures/compile_basic --target-path target-dxt --select orders
./zig-out/bin/dxt build --project-dir tests/fixtures/seed_ref --target-path target-dxt --select +stg_customers
./zig-out/bin/dxt run --project-dir tests/fixtures/model_properties --target-path target-dxt-tests --select customers
./zig-out/bin/dxt test --project-dir tests/fixtures/model_properties --target-path target-dxt-tests --select "not_null_customers_customer_id unique_customers_customer_id"
./zig-out/bin/dxt build --project-dir tests/fixtures/model_properties --target-path target-dxt --select "not_null_customers_customer_id unique_customers_customer_id"
./zig-out/bin/dxt build --project-dir tests/fixtures/source_column_tests --target-path target-dxt --select "source:raw.customers+"
./zig-out/bin/dxt docs generate --project-dir tests/fixtures/docs_blocks --target-path target-dxt
./zig-out/bin/dxt source freshness --project-dir tests/fixtures/source_freshness --target-path target-dxt --select source:raw.customers
```

DuckDB execution tests require the `duckdb` CLI on `PATH`. The current DuckDB
backend is a Zig-owned CLI boundary; the long-term adapter ABI should move to
embedded DuckDB or another native adapter boundary, not Python runtime calls.

## Documentation

| Document | Purpose |
| --- | --- |
| [Primer](docs/PRIMER.md) | Product goals, current workflow, architecture map, and development loop. |
| [Compatibility Matrix](docs/COMPATIBILITY.md) | Truthful current support vs planned dbt surfaces. |
| [Architecture](docs/ARCHITECTURE.md) | Module ownership, execution flow, and Mermaid diagrams. |
| [Release Process](docs/RELEASES.md) | GitHub release workflow, binary artifacts, checksums, and safety gates. |
| [Changelog](CHANGELOG.md) | Human-readable history of shipped pre-alpha slices. |
| [ExecPlan](PLAN.md) | Active engineering plan and milestone tracker. |
| [Agent Rules](AGENTS.md) | Durable rules for Zig runtime, planning, tests, PRs, and public safety. |

## Current Support Snapshot

| Area | Supported Now | Planned |
| --- | --- | --- |
| Commands | `parse`, `ls`, `clean`, `compile`, `run`, `test`, `build`, `docs generate`, `docs serve`, `source freshness`, `version`, help | `debug`, `deps`, `init`, `run-operation`, `snapshot`, `retry`, `clone` |
| Runtime | Zig product runtime | Broader native adapter ABI and runner |
| Adapter | DuckDB through a Zig-owned external CLI backend | Embedded DuckDB, Postgres, cloud adapters, cross-database planner |
| Artifacts | `manifest.json`, `run_results.json`, `catalog.json`, `sources.json` slices | fuller dbt schemas, `semantic_manifest.json`, parse cache/state artifacts |
| dbt resources | models, seeds, sources with schema/freshness/identifier slices, exposures, docs, macros, generic tests in the supported subset, read-only unit-test manifest/list artifacts | snapshots, analyses, singular tests, unit-test execution, semantic models, metrics, saved queries |
| Jinja | literal, narrow scalar var-backed, and static loop-var `ref`/`source`, `doc`, inline `config`, static list `set` + simple `for`, narrow static `if`, selected `target`/`this` context | full parse/runtime context, macro execution, dispatch, filters, database-backed `execute`, adapter introspection |
| Selectors and listing | names/FQN, tags, paths/files, packages, resource types, sources, exposures, unit tests, config materialization, `*`/`?`/bracket-class wildcards, `+` and `@` graph expansion, excludes, `ls` `json`/`name`/`path`/`selector` output formats, and narrow compact-JSON resource `--output-keys` in the supported subset | YAML selectors, state/defer/result/source-status selectors, full dbt JSON and nested `--output-keys` |

See [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) for the detailed matrix.

## System Map

```mermaid
flowchart LR
    CLI[dxt CLI] --> Loader[Project Loader]
    Loader --> Parser[Parser and YAML Readers]
    Parser --> Graph[Manifest Graph]
    Graph --> Selector[Selector Engine]
    Graph --> Compiler[Compiler]
    Compiler --> DuckDB[DuckDB Adapter Boundary]
    DuckDB --> Results[Run Results and Catalog Artifacts]
    Graph --> Manifest[manifest.json]
    Graph --> Sources[sources.json]
```

## Development

Run the standard local gate from the repository root:

```sh
zig build
zig build test
pytest -q
python scripts/check_runtime_boundary.py
python scripts/check_public_safety.py
```

Use the test layers deliberately:

- `zig build` compiles the native CLI.
- `zig build test` runs fast native unit/regression tests for core Zig logic.
- `pytest -q` runs black-box integration and compatibility checks against the
  compiled Zig binary.
- `python scripts/check_runtime_boundary.py` verifies Python has not crossed
  into product runtime responsibilities.
- `python scripts/check_public_safety.py` scans for local paths, secrets, caches,
  logs, and private artifacts.

Optional compatibility gates:

```sh
python scripts/check_jaffle_shop_duckdb_parse.py
python scripts/check_jaffle_shop_duckdb_build.py
python scripts/check_dbt_core_m1_oracle.py
```

The Jaffle scripts use public fixtures and may clone their pinned refs by
default. Pass `--project-dir path/to/jaffle_shop_duckdb` to run against an
existing checkout.

## Release Builds

Tagged releases are built by [release.yml](.github/workflows/release.yml).
Release artifacts are native `dxt` binaries packaged per target with a
`SHA256SUMS.txt` file. Initial binary releases are Linux-only because current
file discovery is Linux-specific; macOS and Windows artifacts are planned after
that path is portable. See [docs/RELEASES.md](docs/RELEASES.md).

## Status

Pre-alpha. The shipped surface is intentionally narrow and documented. The next
work remains dbt Core compatibility first: wider Jinja/macro behavior, stronger
runner semantics, broader selector parity, fuller artifacts, and public
Jaffle-style build coverage.

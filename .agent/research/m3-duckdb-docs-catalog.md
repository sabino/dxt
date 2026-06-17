# M3 DuckDB Docs Catalog Slice

## Goal

Make `dxt docs generate` emit dbt-shaped `catalog.json` node entries for
selected model and seed relations that already exist in the local DuckDB target
database.

This is a docs artifact compatibility slice. It does not execute resources
during docs generation and it preserves the existing empty catalog behavior when
the DuckDB file is absent or selected relations are not materialized.

## Upstream References

dbt Core v1:

- `core/dbt/task/docs/generate.py::GenerateTask.run`
- `core/dbt/task/docs/generate.py::Catalog`
- `core/dbt/task/docs/generate.py::Catalog.make_unique_id_map`
- `core/dbt/task/docs/generate.py::build_catalog_table`
- `core/dbt/task/docs/generate.py::format_stats`
- `core/dbt/artifacts/schemas/catalog/v1/catalog.py::CatalogArtifact`
- `core/dbt/artifacts/schemas/catalog/v1/catalog.py::CatalogResults`

dbt Core v2 / Fusion:

- `crates/dbt-schemas/src/schemas/legacy_catalog/catalog.rs::CatalogTable`
- `crates/dbt-schemas/src/schemas/legacy_catalog/catalog.rs::TableMetadata`
- `crates/dbt-schemas/src/schemas/legacy_catalog/catalog.rs::ColumnMetadata`
- `crates/dbt-schemas/src/schemas/legacy_catalog/catalog.rs::CatalogNodeStats`
- `crates/dbt-schemas/src/schemas/legacy_catalog/catalog.rs::DbtCatalog`
- `crates/dbt-index-core/src/ingest/ingest_state.rs` for future scalable
  catalog metadata directions.

## dxt Ownership

- `src/project.zig` owns `docs generate` orchestration.
- `src/project/catalog.zig` owns deterministic dbt-shaped `catalog.json`
  serialization.
- `src/project/duckdb.zig` owns this slice's DuckDB CLI-backed
  relation/column introspection for already-materialized selected model and
  seed nodes.

## Supported Behavior

- `docs generate` still compiles selected enabled SQL models and writes
  `manifest.json`.
- If the resolved DuckDB file does not exist, `catalog.json` remains empty.
- If the selected relation does not exist in the DuckDB file, that selected node
  is omitted from `catalog.json`.
- If an existing DuckDB file contains selected model or seed relations, the
  catalog `nodes` map includes:
  - `metadata.type` from DuckDB `information_schema.tables.table_type`;
  - `metadata.schema`;
  - `metadata.name`;
  - `metadata.database`, `comment`, and `owner` as null for now;
  - ordered `columns` with `type`, `index`, `name`, and null `comment`;
  - `stats.has_stats` with `include: false`;
  - `unique_id`.
- The implementation uses a single read-only `duckdb -json` query and parses
  JSON in Zig.

## Explicit Boundaries

- Do not run models, seeds, tests, snapshots, or materializations during docs
  generation.
- Do not catalog sources yet.
- Do not emit comments, owners, row counts, table size, freshness, or richer
  stats.
- Do not support non-DuckDB adapter catalog introspection in this slice.
- Do not create a DuckDB file merely to generate docs.
- Keep `:memory:` and MotherDuck-style paths out of this CLI-backed
  introspection path.

## Artifact And Validation Surface

Affected artifacts:

- `catalog.json` `nodes` map for selected model/seed relations.
- The local catalog schema slice now allows dbt-shaped catalog table entries.

Validation gates:

- native Zig catalog writer tests for empty and non-empty catalog shape;
- native Zig DuckDB JSON row mapping test;
- pytest CLI coverage for empty docs catalogs without a database;
- pytest CLI coverage for build-then-docs catalog entries from an existing
  DuckDB file;
- `zig build test`;
- focused docs/catalog pytest;
- runtime-boundary and public-safety scans before publication.

## Stop Conditions

Stop before adding source catalog entries, docs persistence, adapter comments,
owners, richer stats, live non-DuckDB catalog adapters, `docs serve`, embedded
DuckDB, or a generic adapter ABI refactor.

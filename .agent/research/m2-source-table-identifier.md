# M2 Source Table Identifier Slice

## Scope

Add dbt source table `identifier` support as a narrow physical-relation-name
override. The logical source table `name` remains the key used by
`source(source_name, table_name)`, unique IDs, selectors, dependency maps, and
artifact `name` / `fqn` fields. The optional table `identifier` controls the
rendered relation identifier, manifest `identifier`, DuckDB source catalog
lookup, source freshness SQL, and source generic-test SQL.

## Upstream References

- dbt Core v1:
  - `core/dbt/parser/sources.py::SourcePatcher.parse_source` defaults source
    table `identifier` from table `name` while keeping logical `name` separate.
  - `core/dbt/parser/sources.py::SourcePatcher._get_relation_name` builds the
    rendered relation name from source relation components.
  - `core/dbt/contracts/graph/nodes.py::SourceDefinition.same_database_representation`
    treats `identifier` as part of source relation identity.
  - `core/dbt/context/providers.py::ParseSourceResolver.resolve` and
    `RuntimeSourceResolver.resolve`, plus
    `core/dbt/contracts/graph/manifest.py::Manifest.resolve_source`, resolve
    by logical source/table names.
  - `schemas/dbt/manifest/v12.json` requires source `identifier` separately
    from source `name`.
- dbt Core v2 / Fusion:
  - `crates/dbt-parser/src/resolve/resolve_sources.rs::resolve_sources`
    defaults table `identifier` from table `name`, preserves raw configured
    identifiers for source attributes, normalizes relation components, and
    builds relation names from database/schema/identifier.
  - `crates/dbt-schemas/src/schemas/nodes.rs::DbtSourceAttr` stores
    `identifier` separately from `source_name`.

## dxt Ownership

- `src/project/types.zig`: `SourceDef.identifier`.
- `src/project/parse.zig`: table-level YAML `identifier` parsing.
- `src/project/compiler.zig`: `sourceIdentifier` and `relationNameForSource`.
- `src/project/manifest.zig`: source `identifier` and `relation_name` fields.
- `src/project/duckdb.zig`: source freshness, catalog, and source generic-test
  relation rendering.

## Validation

- Native Zig parser test for logical table name plus physical identifier.
- Native compiler, manifest, and DuckDB tests proving relation rendering uses
  the configured identifier.
- Python CLI tests proving compile/manifest/selector behavior preserves logical
  source keys while rendered SQL, catalog, and source freshness use the physical
  identifier.

## Stop Conditions

- Do not implement source `database`, `quoting`, project-level source config, or
  metadata freshness in this slice.
- Do not change selector semantics or source unique IDs from logical table
  names.
- Do not add general Jinja rendering for source properties.
- Product behavior remains Zig; Python is only black-box CLI/artifact coverage.

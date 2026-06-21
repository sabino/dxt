# M2 Source Config And Freshness Inheritance

## Upstream References

- dbt Core v1 `core/dbt/parser/sources.py`:
  `calculate_freshness_from_raw_target`,
  `calculate_loaded_at_field_query_from_raw_target`, and source target parsing.
- dbt Core v1 `core/dbt/contracts/graph/nodes.py`: `SourceDefinition`
  manifest fields such as `schema`, `identifier`, `loaded_at_field`,
  `loaded_at_query`, `freshness`, and `config`.
- dbt Core v1 `schemas/dbt/manifest/v12.json` and
  `schemas/dbt/sources/v3.json`: artifact contracts affected by source nodes
  and freshness result rows.
- dbt Core v2 / Fusion `crates/dbt-parser/src/resolve/resolve_sources.rs`:
  source merge helpers for loaded-at field/query pairs and freshness
  inheritance.
- dbt Core v2 / Fusion `crates/dbt-schemas/src/schemas/manifest/manifest.rs`:
  schema-backed source manifest representation.

## dxt Ownership

- `src/project/config.zig` owns the current `dbt_project.yml` `sources:`
  config parser slice for root-project supported fields.
- `src/project/loader.zig` copies root project source configs onto the graph
  before parsing root project source YAML.
- `src/project/parse.zig` owns the current YAML slice for source-level and
  table-level top-level/config keys and applies project-level defaults before
  YAML source/table overrides.
- `src/project/types.zig` carries resolved source relation and freshness
  fields in `SourceDef`.
- `src/project/compiler.zig` centralizes resolved source relation rendering for
  `source()`.
- `src/project/duckdb.zig` uses resolved source schema names for source
  freshness, source generic tests, and catalog source lookup.
- `src/project/manifest.zig` emits the expanded Manifest v12-shaped source
  field subset.

## Implemented Slice

- Source-level `schema:` supports literal values and the narrow
  `{{ target.schema }}` token form, including suffixes such as
  `{{ target.schema }}_raw`.
- Root-project `dbt_project.yml` `sources:` configs support the current
  relation/freshness subset for root project source definitions:
  `+database`, `+schema`, `+identifier`, `+quoting`, `+loaded_at_field`,
  `+loaded_at_query`, and `+freshness`.
- Project-level source configs are lower precedence than source YAML and table
  YAML values. Package-level configs feed source defaults, source-level project
  configs refine those defaults, and table-level project configs apply before
  table YAML overrides.
- Source-level and table-level `loaded_at_field`, `loaded_at_query`, and
  `freshness` are parsed both as top-level source/table keys and under
  `config:`.
- Table `loaded_at_query` can override an inherited `loaded_at_field` for
  execution while preserving the inherited field in the resolved source state,
  matching dbt's resolved source shape. Runtime freshness SQL prefers
  `loaded_at_query` when both are present. Table `loaded_at_field` still clears
  an inherited query when explicitly configured.
- Freshness thresholds merge at the dbt Core object boundary: complete
  table/source `warn_after` and `error_after` values override inherited values,
  while incomplete time values do not replace a complete inherited threshold.
- `freshness: null` clears inherited freshness at the final table layer, so the
  source remains in the manifest but is not runnable by `dxt source freshness`.
- Same-layer non-null loaded-at field/query conflicts are rejected during parse.
- Manifest source entries now include the resolved `schema`, `identifier`,
  `relation_name`, `loaded_at_field`, `loaded_at_query`, `freshness`, and
  source `config` fields for this compatibility slice.

## Stop Conditions

- No general Jinja rendering in source properties.
- No metadata freshness or adapter metadata APIs.
- No package-installed project source config application from root
  `dbt_project.yml`.
- No external table, richer source metadata, source-level `identifier`
  semantics, or adapter-specific relation behavior beyond the current resolved
  database/schema/table identifier contract stored on `SourceDef`.
- No source-status selectors.
- No Python product runtime.

## Validation

- Native parser tests cover project-level and YAML source config inheritance,
  table overrides, incomplete threshold preservation, `freshness: null`, narrow
  target-schema rendering, and same-layer loaded-at conflicts.
- Native compiler, DuckDB, and manifest tests cover resolved source relation
  rendering and Manifest v12-shaped source fields.
- Python CLI coverage exercises inherited source freshness, resolved source
  schema rendering, table `loaded_at_query`, table freshness overrides,
  project-level relation/freshness configs across compile/docs/freshness/test,
  skipped null freshness, `sources.json`, and schema-validated `manifest.json`.

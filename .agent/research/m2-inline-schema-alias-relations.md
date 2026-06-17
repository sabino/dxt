# M2 Inline Schema And Alias Relation Slice

This slice extends dxt's render-only compiler with literal inline
`config(schema=..., alias=...)` relation identity for SQL models. It implements
the default dbt custom-schema and custom-alias behavior for the current narrow
compiler surface only. It does not execute macros, evaluate arbitrary Jinja,
read project or YAML `+schema` / `+alias`, or implement custom
`generate_schema_name` / `generate_alias_name` overrides.

## Upstream References

dbt Core v1, branch `1.latest`, commit `566b75d`:

- `core/dbt/context/providers.py::ParseConfigObject.__call__` records inline
  `config(...)` kwargs into parse-time configuration.
- `core/dbt/parser/base.py::ConfiguredParser.update_parsed_node_config` builds
  the final config dictionary from project, properties, and inline config calls.
- `core/dbt/parser/base.py::ConfiguredParser.update_parsed_node_relation_names`
  applies database, schema, then alias before assigning `relation_name`.
- `core/dbt/parser/base.py::ConfiguredParser._update_node_relation_name` renders
  `relation_name` through the adapter relation class for relational nodes.
- `core/dbt/context/providers.py::ModelContext.this` exposes the current model
  as a relation object in model Jinja context.
- `core/dbt/context/providers.py::RuntimeRefResolver.resolve` resolves refs to
  manifest nodes and returns relation objects for target resources.

dbt Core v2 / Fusion foundation, branch `main`, commit `0529e06`:

- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/get_custom_name/get_custom_schema.sql::default__generate_schema_name`
  returns `target.schema` when custom schema is none, otherwise
  `target.schema ~ "_" ~ trim(custom_schema)`.
- `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/get_custom_name/get_custom_alias.sql::default__generate_alias_name`
  returns trimmed custom alias when present, otherwise `node.name` for
  unversioned nodes.
- `crates/dbt-parser/src/utils.rs::update_node_relation_components` generates
  database and schema before alias so alias generation can observe the resolved
  schema.
- `crates/dbt-parser/src/resolve/resolve_models.rs::resolve_models` passes model
  config database, schema, and alias into relation component generation.
- `crates/dbt-jinja-utils/src/phases/compile/compile_node_context.rs` builds
  compile-time `this` relation context from resolved node relation components.

## dxt Ownership

- `src/project/jinja.zig` owns lexical inline `config(...)` scanning for this
  narrow quoted-literal surface.
- `src/project/types.zig` stores the parsed optional `config_schema` and
  `config_alias` relation components on model nodes.
- `src/project/compiler.zig` owns default relation-name rendering for compiled
  refs and `this`.
- `src/project.zig` remains the compile orchestration facade and assigns
  manifest `relation_name` from the compiler.

## Supported Surface

- Quoted literal inline `config(schema="...", alias="...")` and equivalent
  single-quoted values in SQL models.
- Default schema generation:
  - no custom schema: `target.schema`
  - custom schema: `target.schema` + `_` + trimmed custom schema
- Default alias generation:
  - custom alias with non-empty trimmed value: trimmed custom alias
  - otherwise: node name
- Render-only effect on:
  - `{{ this }}`
  - `{{ this.schema }}`
  - `{{ this.name }}`
  - `{{ this.table }}`
  - `{{ this.identifier }}`
  - `{{ ref(...) }}` relation strings for referenced nodes
  - compiled model `relation_name`

## Unsupported Surface

- Project path configs, YAML properties, or package overrides for `schema` and
  `alias`.
- `database`, custom database generation, adapter include policy, and
  adapter-specific relation rendering.
- Versioned model alias defaults, custom schema/alias macros, macro execution,
  adapter dispatch execution, arbitrary Jinja expressions, and materialization
  runtime behavior.
- Source relation naming changes. The current source renderer remains the
  existing narrow `source_name.table_name` surface.

## Validation

- Native Zig tests cover parsing inline schema/alias literals and applying them
  to relation names plus `this` attributes.
- Pytest fixture `inline_relation_config` validates the native `dxt compile`
  path, compiled SQL files, refs to aliased models, manifest `relation_name`,
  and the pinned manifest schema slice.

## Stop Conditions

- Stop before adding project/YAML schema or alias precedence.
- Stop before adding custom `generate_schema_name` or `generate_alias_name`
  macro execution.
- Stop before adding live adapter connections, materialization execution,
  catalog introspection, or run-results artifacts.
- Stop if a fixture needs private profiles, credentials, live warehouses, or
  local absolute paths.

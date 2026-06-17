# M2 Target Schema And This Compile Context Slice

This slice extends dxt's render-only compiler with a narrow profile-derived
target context and current-model relation context. It does not execute SQL,
validate credentials, implement custom schema or alias generation, render
arbitrary Jinja expressions, or open adapter connections.

## Upstream References

dbt Core v1, branch `1.latest`, commit `566b75d`:

- `core/dbt/config/profile.py::Profile.render_profile` selects the target from
  CLI override, profile `target:`, then `default`.
- `core/dbt/config/profile.py::Profile.to_target_dict` exposes selected target
  credentials plus `type`, `threads`, `name`, `target_name`, and
  `profile_name`.
- `core/dbt/context/target.py::TargetContext.target` defines the shared
  `target` context, including `name`, `schema`, `type`, and `threads`.
- `core/dbt/context/providers.py::ModelContext.this` exposes the current model
  as an adapter relation; its documented values include `{{ this }}`,
  `{{ this.schema }}`, `{{ this.table }}`, and `{{ this.name }}`.
- `core/dbt/context/providers.py::generate_parser_model_context` and
  `generate_runtime_model_context` keep the model context shape stable while
  provider behavior changes between parse and runtime.
- `core/dbt/parser/base.py::ConfiguredParser.update_parsed_node_relation_names`
  and `_update_node_relation_name` assign relation names through the adapter
  relation class after database, schema, and alias resolution.
- `core/dbt/compilation.py::Compiler._create_node_context`, `_compile_code`,
  and `compile_node` render raw SQL through the model context before writing
  compiled output.

dbt Core v2 / Fusion foundation, branch `main`, commit `0529e06`:

- `crates/dbt-profile/src/resolve.rs::resolve_target`,
  `resolve_with_env`, `ResolvedProfile::schema`, and
  `ResolvedProfile::database` keep profile target resolution and default
  database/schema identity as data.
- `crates/dbt-jinja-utils/src/phases/utils.rs::build_target_context_map`
  inserts `profile_name`, `name`, and `target_name` into the target map.
- `crates/dbt-schemas/src/schemas/profiles.rs::TargetContext`,
  `CommonTargetContext`, and `TryFrom<DbConfig> for TargetContext` define
  common `database`, `schema`, `type`, and `threads`; DuckDB defaults missing
  schema to `main`.
- `crates/dbt-jinja-utils/src/phases/compile/compile_node_context.rs` builds
  compile-time `this` relation data and exposes `this`, `database`, `schema`,
  and `identifier`.
- `crates/dbt-jinja-ctx/src/compile.rs::CompileNodeCtx` defines the typed
  compile context contract.
- `crates/dbt-adapter/src/relation/relation_impl.rs` and
  `crates/dbt-schemas/src/schemas/relations/base.rs` define adapter relation
  rendering and include-policy behavior.

## dxt Ownership

- `src/project/profile.zig` parses selected profile output scalar `type` and
  now scalar `schema`.
- `src/project/types.zig` carries `Graph.target_schema` and
  `AdapterIdentity.target_schema`.
- `src/project/loader.zig` copies profile-derived target schema into the graph
  before parser and compiler use.
- `src/project/compiler.zig` owns the render-only relation formatter and the
  narrow `target.*` / `this` expression surface.
- `src/project.zig` keeps the compile orchestration path and assigns manifest
  `relation_name` through the compiler.

## Supported Surface

- Select profile from CLI `--profile`, falling back to `dbt_project.yml`
  `profile:`.
- Select target from CLI `--target`, falling back to profile `target:`, then
  `default`.
- Read selected output scalar `schema`; default to `main` only for selected
  DuckDB targets when missing.
- Render supported model/ref relations with the graph target schema.
- Render literal compile expressions:
  - `target.name`
  - `target.target_name`
  - `target.schema`
  - `target.type`
  - `target.profile_name`
  - `this`
  - `this.schema`
  - `this.name`
  - `this.table`
  - `this.identifier`

## Unsupported Surface

- General Jinja expression evaluation, filters, indexing, conditionals, loops,
  concatenation, macro execution, and adapter calls.
- Adapter-specific target fields such as database, dbname, project, dataset,
  host, user, warehouse, or role.
- Node-level custom schema, alias, database, config rendering, and
  `generate_schema_name` / `generate_alias_name` / `generate_database_name`.
- Ephemeral/deferred/unit-test `this`, operation context, source freshness
  context, hooks, and materialization runtime behavior.
- Adapter include policy beyond the current two-part quoted
  `schema.identifier` model relation format.

## Validation

- Native Zig tests cover profile schema extraction/defaulting, target-schema
  relation rendering for refs, and compile rendering for `target.*` plus
  `this` fields.
- Pytest fixture `profile_target_context` validates the native CLI compile
  path, selected profile target schema/type/name/profile fields, ref rendering,
  compiled SQL files, manifest `relation_name`, and manifest schema slice.
- Schema validation is run against the fixture `manifest.json`.

## Stop Conditions

- Stop before adding arbitrary Jinja expression support.
- Stop before implementing custom schema/alias/database semantics.
- Stop before adding live adapter connections, materialization SQL execution,
  catalog introspection, or run-results artifacts.
- Stop if a fixture requires secrets, private profile values, live credentials,
  or local absolute paths.

# M2 Static Loop Dependency Slice

This note maps the narrow parse-time dependency recovery slice for static
Jinja string-list loops.

## Upstream References

dbt Core v1 reference files:

- `core/dbt/parser/models.py`: the SQL model parser first attempts static
  extraction, then falls back to full parse rendering when static parsing cannot
  prove dependencies.
- `core/dbt/parser/base.py`: parse rendering calls the Jinja renderer with
  macro capture and mutates the parse-time node dependency state.
- `core/dbt/context/providers.py`: parse-time `ref()` and `source()` resolvers
  validate evaluated string arguments and append dependency metadata to the
  parsed node.
- `core/dbt/clients/jinja_static.py`: the literal static helper is narrower
  than render fallback and only proves literal refs/sources.

Fusion/dbt Core v2 reference files:

- `crates/dbt-jinja-utils/src/phases/parse/resolve_model_context.rs`: the
  parse context installs `ref` and `source` functions that record resources
  when called during render.
- `crates/dbt-jinja-utils/src/phases/parse/sql_resource.rs`: parse resources
  distinguish rendered refs/sources from static source recovery.
- `crates/dbt-parser/src/renderer.rs`: Fusion augments static `source()`
  discovery for sources hidden behind dead branches.

## dxt Scope

The implementation remains scanner-only and Zig-only:

- `src/project/jinja.zig` tracks static `{% set name = ['a', 'b'] %}` string
  lists and scoped `{% for item in name %}` loop variables while scanning SQL
  for dependencies.
- Inside known static-list loops, `ref(item)`, `ref('package', item)`, and
  `source('source', item)` style calls resolve the loop variable to string
  values and append normal node-owned refs/sources.
- Unknown loops preserve the previous best-effort literal scanning path and do
  not resolve loop variables.
- This feeds existing graph dependency maps and selector expansion. It does not
  add general Jinja evaluation or command execution behavior.

## Boundaries

This slice does not support dynamic lists, `var()`-produced lists, list
indexing, concatenation, filters, loop metadata, tuple unpacking, mutation,
macros, adapter dispatch execution, or arbitrary expression evaluation.

`dxt compile`, `run`, `build`, and `docs generate` still require a follow-up
compiler argument-resolution slice before `ref(item)` or `source('raw', item)`
can render successfully in compiled SQL.

## Validation

- Native Zig tests cover loop-generated refs/sources, node-owned loop value
  storage, literal refs inside unknown loops, and unsupported unbound dynamic
  loop variables.
- Python CLI tests cover `dxt parse` manifest refs/sources/dependency maps and
  `dxt ls` graph expansion over loop-discovered dependencies.

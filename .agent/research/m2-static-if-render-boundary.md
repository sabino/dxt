# M2 Static `{% if %}` Render Boundary

## Scope

This slice adds a narrow render-only compiler boundary for static Jinja
conditionals.

Supported conditions:

- `true`
- `false`
- `execute`
- `not execute`
- `is_incremental()`
- `not is_incremental()`
- `elif` chains using the same static condition subset
- `==` / `!=` comparisons between supported static booleans, quoted strings,
  static loop variables, `target.name`, `target.target_name`, `target.schema`,
  `target.type`, `target.profile_name`, `this.schema`, `this.name`,
  `this.table`, and `this.identifier`

For this compiler slice, `execute` renders as true, matching dbt's compile/run
render phase. `is_incremental()` remains false because dxt has not implemented
incremental materialization state. Parse-time dependency recovery stays with the
raw SQL scanner, which records literal `ref()` and `source()` calls inside
branches that may render false.

Out of scope:

- Database-backed runtime Jinja behavior beyond this static `execute` branch
  selection.
- `run_query`, `statement`, adapter introspection, and database-returned Jinja
  values.
- Complex boolean expressions such as `and` / `or`, filters, tests, arithmetic,
  numeric comparison, non-string literals, arbitrary function calls, and
  general expression evaluation.
- Materialization-specific incremental execution semantics.
- General macro/control-flow execution.

## Upstream References

dbt Core v1:

- `core/dbt/context/providers.py::ParseProvider`
- `core/dbt/context/providers.py::RuntimeProvider`
- `core/dbt/context/providers.py::ProviderContext.execute`
- `core/dbt/parser/base.py::render_update`

dbt Core v2 / Fusion:

- `crates/dbt-parser/src/renderer.rs`
- `crates/dbt-parser/src/dbt_namespace.rs`

## dxt Ownership

- `src/project/compiler.zig` owns render-only static conditional selection.
- `src/project/jinja.zig` owns raw SQL scanning that recovers literal
  dependency calls even in branches that render false.
- `tests/test_cli.py` covers compile-time behavior, optional dbt Core compile
  oracle comparison when dbt Core and dbt-duckdb are installed, and manifest
  dependency preservation through the native CLI.

## Validation

- Native Zig tests cover static condition rendering, `elif` branch selection,
  simple comparison rendering, unsupported reached conditions, and raw scanner
  dependency recovery inside false branches.
- Python CLI tests cover `dxt compile` output and manifest dependencies for a
  fixture with guarded `ref()` and `source()` calls.

## Stop Conditions

Stop before implementing runtime Jinja, database-backed `run_query`, adapter
introspection, `elif`, complex expressions, or incremental materialization
semantics. Those require separate source-grounded slices.

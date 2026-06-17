# M2 Static Jinja Set/For Compile Slice

## Purpose

Public Jaffle Shop DuckDB uses a compile-time Jinja pattern in `orders.sql`:

- assign a static list of payment method strings with `{% set payment_methods = [...] %}`;
- loop over that list with `{% for payment_method in payment_methods %}`;
- interpolate `{{ payment_method }}` into generated SQL identifiers and string literals.

This slice makes `dxt compile`, `dxt docs generate`, `dxt run`, and `dxt build`
render that narrow pattern in Zig. It is a compatibility bridge for common dbt
projects, not a general Jinja implementation.

## Upstream References

dbt Core v1 reference points:

- `core/dbt/compilation.py::Compiler._compile_code`
- `core/dbt/compilation.py::Compiler.compile_node`
- `core/dbt/clients/jinja.py::get_rendered`
- `core/dbt/context/providers.py::generate_runtime_model_context`
- `core/dbt/context/providers.py::ModelContext`

dbt Core v2 / Fusion reference points:

- `crates/dbt-parser/src/renderer.rs::render_sql_file_inner`
- `crates/dbt-jinja-utils/src/phases/compile/compile_node_context.rs::build_compile_node_context_inner`
- `crates/dbt-jinja-utils/src/environment_builder.rs::JinjaEnvBuilder`
- MiniJinja parser/render snapshots for `set` and `for` behavior under
  `crates/dbt-jinja/minijinja/tests/snapshots/`

The upstream shape is full Jinja rendering with dbt runtime model context.
`dxt` does not yet have that full engine, so this slice implements only the
deterministic static subset needed by the public fixture and keeps unsupported
Jinja loud.

## dxt Ownership

- `src/project/compiler.zig` owns the render-only compile boundary and this
  static list-loop expansion.
- `src/project/jinja.zig` remains the lexical helper module for calls,
  identifiers, whitespace skipping, and literal/var-backed arguments.
- Python remains developer-side only through pytest and public fixture gates.

## Supported Behavior

- `{% set name = ['a', "b"] %}` creates a compile-local string list for
  unescaped quoted values.
- `{% set name = [] %}` creates an empty compile-local list.
- `{% for item in name %}...{% endfor %}` expands the body once per list item.
- `{{ item }}` inside the loop renders the current string value.
- Existing compile expressions keep working inside loop bodies, including
  supported `ref`, `source`, `config`, `target.*`, and `this`.
- Empty loops still validate the skipped body so unsupported syntax is not
  silently hidden.

## Explicit Boundaries

Unsupported shapes must fail with the existing unsupported-Jinja diagnostics:

- scalar `set` values such as `{% set name = 'x' %}`;
- unquoted list entries such as `{% set name = [x] %}`;
- escaped string-list values, until dxt implements a Jinja-compatible escape
  subset;
- dynamic list expressions, filters, conditionals, `do`, namespaces, mutation,
  tuple unpacking, loop metadata such as `loop.last`, macros, adapter dispatch
  execution, and arbitrary expressions;
- Python product-runtime behavior.

Whitespace trimming is execution-safe but not exact dbt whitespace parity yet.
Exact compiled SQL normalization belongs in a later full Jinja compatibility
slice.

## Artifact And Validation Surface

Affected artifacts:

- `manifest.json` compiled model fields when `compile`, `docs generate`, `run`,
  or `build` compiles a model;
- `run_results.json` only indirectly, when `run` or `build` can now execute a
  previously unsupported compiled model.

Validation gates:

- native Zig compiler tests for static loops, empty lists, refs inside loop
  compile context, unknown loop lists, scalar `set` rejection, unquoted and
  escaped list rejection, and unsupported syntax hidden inside empty loops;
- pytest integration coverage for compile and build on a synthetic
  Jaffle-shaped model;
- `scripts/check_jaffle_shop_duckdb_parse.py` for the pinned public parse/list
  contract;
- `scripts/check_jaffle_shop_duckdb_build.py` for the pinned public build
  contract, including run-result counts and DuckDB relation checks;
- runtime-boundary and public-safety scans before publication.

## Stop Conditions

Stop rather than broadening this slice if support requires full macro
execution, adapter dispatch execution, general Jinja evaluation, selector
changes, runner scheduling changes, catalog introspection, or Python
product-runtime code.

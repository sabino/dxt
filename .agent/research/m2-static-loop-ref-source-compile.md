# M2 Static Loop Ref/Source Compile Slice

This note maps the narrow compile-time relation rendering follow-up for static
Jinja string-list loops.

## Upstream References

dbt Core v1 reference files:

- `core/dbt/compilation.py`: compilation creates a node context and renders SQL
  through Jinja before persisting compiled fields.
- `core/dbt/clients/jinja.py`: `get_rendered` evaluates supported Jinja syntax,
  including `set`, `for`, and expression calls.
- `core/dbt/context/providers.py`: runtime `ref()` and `source()` resolvers
  receive evaluated string arguments and return adapter relation objects.

Fusion/dbt Core v2 reference files:

- `crates/dbt-parser/src/renderer.rs`: compile rendering flows through the Jinja
  environment and records normalized rendered code.
- `crates/dbt-jinja-utils/src/phases/compile/compile_node_context.rs`: compile
  context construction exposes dbt runtime model context.
- `crates/dbt-jinja-utils/src/phases/compile_and_run_context.rs`: `RefFunction`
  and `SourceFunction` resolve evaluated arguments for compile/run contexts.
- `crates/dbt-jinja/minijinja/tests/snapshots/`: MiniJinja set/for snapshots
  document baseline loop rendering behavior.

## dxt Scope

The implementation remains Zig-only and render-only:

- `src/project/compiler.zig` resolves compile-local static loop variables when
  parsing arguments to supported `ref()` and `source()` expressions.
- The supported expression argument set is now literal strings, narrow scalar
  `var()` values/defaults, and currently bound static loop identifiers.
- `ref(model_name)`, `ref('package', model_name)`, and
  `source('source', table_name)` render to the same deterministic quoted
  relation names as literal `ref()` and `source()` calls.
- This affects `compile`, `docs generate`, `run`, and `build` only through the
  existing `compileModel` path.

## Boundaries

This slice does not add general Jinja evaluation, dynamic list expressions,
inline list loops, tuple unpacking, loop metadata, filters, mutation, macro
execution, adapter dispatch execution, selector semantics, graph dependency
changes, or Python product-runtime behavior.

## Validation

- Native Zig compiler tests cover loop-local `ref()` and `source()` arguments,
  plus package refs with loop-local model names.
- Python CLI tests cover `dxt compile --select looped` on the static-loop
  fixture and assert compiled relation names plus manifest compiled fields.

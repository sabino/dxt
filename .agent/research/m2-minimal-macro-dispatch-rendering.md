# M2 Minimal Macro Dispatch Rendering

Date: 2026-06-17

## Upstream Reference

- dbt Core v1: runtime macro rendering and namespace behavior in
  `core/dbt/context/providers.py`, `core/dbt/context/macros.py`, and
  `core/dbt/clients/jinja.py`.
- dbt Fusion direction: compile-node context construction in
  `crates/dbt-jinja-utils/src/phases/compile/compile_node_context.rs`.
- Public fixture shape: Fusion Jaffle Shop
  `crates/dbt-init/assets/jaffle_shop/macros/cents_to_dollars.sql`.

## dxt Scope

This slice adds a narrow Zig-only compile/runtime path for Jaffle-style macro
dispatch:

- model expression calls such as `{{ cents_to_dollars('subtotal') }}`;
- wrapper macro bodies shaped as
  `{{ return(adapter.dispatch('cents_to_dollars')(column_name)) }}`;
- selected adapter/default implementation macro bodies that are static SQL
  templates with positional parameter interpolation such as
  `{{ column_name }}`.

Dispatch selection reuses the existing Zig resolver and adapter-prefix rules.
DuckDB falls back to `default__*` unless a `duckdb__*` implementation exists.

## Explicit Boundaries

This is not a general Jinja or dbt macro interpreter. The compiler still
rejects statement tags inside macro bodies, unsupported dynamic arguments,
general conditionals, loops, filters, runtime context objects, materialization
execution, arbitrary return values, and non-dispatch nested macro execution.

Python remains test/oracle tooling only; all product behavior is in Zig.

## Validation

- Native Zig tests cover wrapper dispatch rendering, adapter-specific dispatch
  preference, return-wrapper dependency scanning, and unsupported macro
  statements.
- Python integration coverage uses a synthetic Jaffle-style fixture through
  `compile`, `docs generate`, `run`, and `build`, checking compiled SQL,
  manifest macro dependencies, run-results schema slices, and DuckDB output.

## Follow-Up

The next macro slices should handle upstream source-grounded package namespace
edge cases, macro defaults/keyword arguments, and broader parse-vs-runtime
Jinja boundaries only as separate PRs with their own dbt Core/Fusion reference
notes and stop conditions.

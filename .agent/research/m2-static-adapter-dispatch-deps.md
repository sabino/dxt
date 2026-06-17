# M2 Static Adapter Dispatch Dependency Slice

This slice adds static dependency extraction for literal `adapter.dispatch(...)`
calls. It records `depends_on.macros` only. It does not execute macros, evaluate
the callable returned by dispatch, implement materializations, parse profiles,
open adapter connections, or support project `dispatch:` config.

## Upstream References

dbt Core v1, branch `1.latest`, commit `566b75d`:

- `core/dbt/context/providers.py::BaseDatabaseWrapper._get_adapter_macro_prefixes`
  defines adapter prefix order as adapter type hierarchy plus `default`.
- `core/dbt/context/providers.py::BaseDatabaseWrapper._get_search_packages`
  defines dispatch package search: no namespace uses flattened lookup, configured
  dispatch order wins, and dependency namespace searches root project then the
  dependency package.
- `core/dbt/context/providers.py::BaseDatabaseWrapper.dispatch` rejects dotted
  macro names and deprecated `packages`, then searches
  `{adapter_prefix}__{macro_name}` candidates.
- `core/dbt/context/providers.py::ParseProvider` and `RuntimeProvider` expose
  the adapter wrapper to Jinja contexts. dxt only uses the static dependency
  shape here.

dbt Core v2 / Fusion foundation, branch `main`, commit `0529e06`:

- `crates/dbt-jinja/minijinja/src/dispatch_object.rs::DispatchObject` and
  `Object for DispatchObject::call` model dispatch as a callable object.
- `dispatch_object.rs::get_adapter_prefixes`,
  `DispatchObject::get_search_packages`, and
  `macro_namespace_template_resolver` provide the Fusion architecture reference
  for prefix and namespace lookup.

## dxt Ownership

- `src/project/resolve.zig` owns the static dispatch lookup helper.
- `src/project/jinja.zig` recognizes literal `adapter.dispatch(...)` while
  scanning model SQL and macro SQL.
- `src/project/manifest.zig` already serializes the affected
  `depends_on.macros` arrays.

## Supported Surface

- `adapter.dispatch("macro_name")`
- `adapter.dispatch("macro_name", "macro_namespace")`
- `adapter.dispatch("macro_name", macro_namespace="macro_namespace")`

The first implementation uses the current local default prefix list
`duckdb`, then `default`, until profile-derived adapter identity exists.

Unsupported shapes fail or remain ignored according to the existing scanner
boundary: dynamic names, dynamic namespaces, dotted macro names,
`packages=...`, non-string namespaces, extra args, and malformed nested calls.

## Validation

- Native Zig tests cover prefix precedence, default fallback, package namespace
  root override before dependency package, dotted-name rejection, unsupported
  argument shapes, and scanner dependency recording for both model SQL and macro
  SQL.
- Pytest fixture `adapter_dispatch_static` validates manifest
  `depends_on.macros` through the Zig binary.
- Pytest fixture `adapter_dispatch_missing` validates a missing static dispatch
  target fails as an unresolved macro.

## Stop Conditions

- Do not execute dispatched macros in this slice.
- Do not implement adapter profile parsing or dispatch config parsing.
- Do not add bundled dbt internal macros.
- Do not add DuckDB connections, materialization execution, `run_results.json`,
  catalog introspection, or Python product runtime behavior.

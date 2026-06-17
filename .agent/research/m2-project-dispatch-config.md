# M2 Project Dispatch Config Slice

This slice adds root-project `dbt_project.yml` `dispatch:` parsing for static
`adapter.dispatch(...)` dependency extraction. It records `depends_on.macros`
only. It does not execute dispatched macros, implement macro runtime,
materializations, bundled dbt internal macros, adapter connections, or dynamic
dispatch names/namespaces.

## Upstream References

dbt Core v1, branch `1.latest`, commit `566b75d`:

- `core/dbt/contracts/project.py::Project` defines `dispatch` as a list and
  validates each non-empty entry requires `macro_namespace` and list-valued
  `search_order`.
- `core/dbt/config/project.py::Project.from_project_config` carries
  `cfg.dispatch` into runtime project config.
- `core/dbt/config/project.py::Project.get_macro_search_order` returns the
  first matching entry's `search_order` for a namespace.
- `core/dbt/context/providers.py::BaseDatabaseWrapper._get_search_packages`
  applies dispatch config before dependency fallback. No namespace searches the
  flattened namespace, configured namespace search order wins, dependency
  namespaces fall back to root project then dependency package, and empty search
  order behaves like no configured order because dbt Core checks truthiness.
- `core/dbt/context/providers.py::BaseDatabaseWrapper.dispatch` rejects dotted
  macro names and deprecated `packages`, then loops packages first and adapter
  prefixes second for `{prefix}__{macro_name}`.

dbt Core v2 / Fusion foundation, branch `main`, commit `0529e06`:

- `crates/dbt-schemas/src/schemas/project/dbt_project.rs::_Dispatch` models
  `macro_namespace: String` and `search_order: Vec<String>`.
- `crates/dbt-loader/src/loader.rs` loads root-project dispatch config into the
  global `DISPATCH_CONFIG` map.
- `crates/dbt-jinja-utils/src/phases/compile_and_run_context.rs` exposes that
  map as `MACRO_DISPATCH_ORDER` using typed `Vec<String>` values.
- `crates/dbt-jinja/minijinja/src/dispatch_object.rs::DispatchObject::get_search_packages`
  uses configured dispatch order before dependency fallback.
- `dispatch_object.rs::get_adapter_prefixes` preserves the adapter prefix
  fallback shape used by the prior profile-derived adapter identity slice.

## dxt Ownership

- `src/project/config.zig` parses the narrow root-project `dispatch:` YAML
  surface.
- `src/project/types.zig` stores `DispatchConfig` on `ProjectConfig` and
  `Graph`.
- `src/project/loader.zig` copies only root project dispatch config into the
  graph before macro and SQL scanning. Installed package `dispatch:` does not
  affect root dispatch config in this slice.
- `src/project/resolve.zig` applies configured package search order before the
  existing dependency fallback.
- `src/project/jinja.zig` continues to recognize literal
  `adapter.dispatch(...)` and records the resolved macro ID.

## Supported Surface

- Root `dbt_project.yml` block list:
  - `macro_namespace: <string>`
  - `search_order: [<package>, ...]`
- Block-form `search_order` lists.
- Empty inline `search_order: []` is accepted and follows dbt Core v1 behavior:
  it falls through as no truthy configured order.

Unsupported shapes fail through the existing narrow YAML boundary: missing
`macro_namespace`, missing `search_order`, scalar `search_order`, extra dispatch
entry keys, inline maps, dynamic dispatch values, deprecated `packages=`, and
Jinja-rendered project config.

## Validation

- Native Zig tests cover dispatch config parsing, malformed config rejection,
  configured search-order lookup, dbt Core v1 empty-list fallback, and SQL
  scanner dependency recording.
- Pytest fixture `adapter_dispatch_project_config` validates manifest
  `depends_on.macros` through the Zig binary.
- Manifest schema-slice validation remains the artifact gate.

## Stop Conditions

- Do not execute dispatched macros in this slice.
- Do not implement general macro runtime or materialization lookup.
- Do not add adapter connections, DuckDB execution, catalog introspection,
  `run_results.json`, or `docs serve`.
- Do not parse installed-package dispatch config as root config.
- Do not add Python product runtime behavior.

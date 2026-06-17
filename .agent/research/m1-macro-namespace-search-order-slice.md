# M1 Macro Namespace Search Order Slice

This slice makes dxt's macro lookup paths explicit and pins the dbt namespace
order currently supported by the Zig parser. Model SQL uses the runtime-like
namespace order of current package, root project, then graph-present internal
`dbt` macros. Macro-body static dependency extraction uses dbt Core's
dependency-oriented fallback of current package, root project, other
non-internal packages, then graph-present internal `dbt` macros. It does not
execute macros, implement adapter dispatch, load bundled dbt macros, or render
materializations.

## Upstream References

dbt Core v1, branch `1.latest`, commit `566b75d`:

- `core/dbt/context/macros.py::MacroNamespace._search_order` defines flattened
  macro lookup as local package, root package, package namespace objects, `dbt`
  internal namespace, then internal flat namespace.
- `core/dbt/context/macros.py::MacroNamespace.get_from_package` keeps explicit
  package-qualified lookup separate from flattened unqualified lookup.
- `core/dbt/context/macros.py::MacroNamespaceBuilder.add_macro` and
  `build_namespace` separate node-local, root, non-internal package, and
  internal package macro namespaces.
- `core/dbt/context/macro_resolver.py::MacroResolver.get_macro` is the
  dependency-resolution-oriented path: explicit package/local package first,
  then the standard macro-by-name order.
- `core/dbt/parser/manifest.py::ManifestLoader.macro_depends_on` statically
  extracts possible macro calls and records macro unique IDs without executing
  macros.
- `core/dbt/context/providers.py::dispatch` is a later adapter-dispatch slice;
  it searches adapter-prefixed macro names across dispatch package order.

dbt Core v2 / Fusion foundation, branch `main`, commit `0529e06`:

- `crates/dbt-jinja-utils/src/environment_builder.rs` builds macro namespace
  and template registries for root, package, and internal package macros.
- `crates/dbt-jinja/minijinja/src/dispatch_object.rs::macro_namespace_template_resolver`
  searches current package, root package, then internal packages.
- `crates/dbt-jinja-utils/src/listener.rs::MacroDependencyListener` records
  rendered macro dependency unique IDs as `macro.<package>.<name>`.

## dxt Ownership

- `src/project/resolve.zig` owns package-qualified lookup, unqualified
  runtime-like namespace lookup, and unqualified macro-body dependency lookup.
- `src/project/jinja.zig` owns lexical model-SQL and macro-body dependency
  scanning and now calls the explicit namespace helper.
- `src/project/manifest.zig` serializes affected `depends_on.macros` fields.

## Validation

- Native Zig tests cover package-local precedence, root fallback,
  other-package macro-body fallback, and graph-present `dbt` internal fallback
  for model SQL and macro body scanning.
- Pytest fixture `macro_namespace_search_order` validates manifest
  `nodes[*].depends_on.macros` and `macros[*].depends_on.macros` across root
  and installed package resources, including macro-body fallback to another
  installed package.
- Existing Manifest v12 slice validation remains the artifact gate.

## Stop Conditions

- Do not implement macro execution in this slice.
- Do not implement `adapter.dispatch` or adapter prefix search in this slice.
- Do not load or vendor dbt internal macros.
- Do not add profile-derived adapter identity or database execution behavior.

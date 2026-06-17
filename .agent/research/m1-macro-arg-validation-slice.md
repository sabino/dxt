# M1 Macro Argument Validation Slice

## Scope

This slice implements the dbt Core v1 `flags.validate_macro_args` parser
surface for macro manifest arguments in Zig.

It covers:

- Reading `flags.validate_macro_args` from `dbt_project.yml`, defaulting to
  false.
- Extracting top-level macro/test/data_test callable argument names when the
  flag is true.
- Keeping extracted signature arguments as manifest macro `arguments` when no
  YAML macro patch arguments are supplied.
- Replacing signature arguments with YAML macro patch arguments when YAML
  `arguments` are supplied.
- Emitting warnings for YAML argument name mismatch, argument count mismatch,
  and invalid v1 type annotations.

## Upstream References

dbt Core v1:

- `core/dbt/contracts/project.py::ProjectFlags.validate_macro_args` sets the
  project flag default to false.
- `core/dbt/parser/macros.py::MacroParser.parse_unparsed_macros` extracts
  `macro`, `materialization`, `test`, and `data_test` blocks, and only calls
  `_extract_args` when `validate_macro_args` is enabled.
- `core/dbt/parser/macros.py::MacroParser._extract_args` builds
  `MacroArgument(name=arg.name)` from the Jinja macro AST.
- `core/dbt/parser/schemas.py::MacroPatchParser.parse_patch` applies macro YAML
  patches and replaces macro `arguments` with patch arguments, while preserving
  extracted signature arguments if validation is enabled and no YAML arguments
  exist.
- `core/dbt/parser/schemas.py::MacroPatchParser._check_patch_arguments` emits
  warnings for YAML/Jinja argument mismatch, count mismatch, and invalid types.
- `core/dbt/parser/schemas.py::is_valid_type` and related helper functions
  define v1 macro argument type syntax.

Fusion / dbt Core v2:

- `crates/dbt-parser/src/utils.rs::parse_macro_statements` and
  `extract_sql_resources_from_ast` retain parsed macro argument specs.
- `crates/dbt-parser/src/resolve/resolve_macros.rs::apply_macro_patches`
  applies macro YAML patches and validates macro argument annotations.
- `crates/dbt-parser/src/resolver.rs` currently defaults
  `validate_macro_args` to true in the v2 path. dxt intentionally keeps the v1
  default false for the current dbt Core compatibility target.

## dxt Ownership

- `src/project/config.zig` parses the top-level `flags.validate_macro_args`
  project flag.
- `src/project/loader.zig` carries the flag into the loaded graph.
- `src/project/types.zig` stores `ProjectConfig.validate_macro_args`,
  `Graph.validate_macro_args`, internal macro `signature_arguments`, and
  warning strings.
- `src/project/parse.zig` extracts macro signature arguments, validates YAML
  patch arguments, and applies dbt v1 replacement semantics.
- `src/project/manifest.zig` continues to own manifest macro `arguments`
  serialization.
- `src/project.zig` emits warning text through the existing parse warning path.

## Validation

- Native Zig tests cover project flag parsing, macro signature extraction,
  YAML argument replacement, validation warnings, and v1 type parsing.
- Pytest covers the native CLI parse path and manifest macro arguments for a
  synthetic fixture.

## Stop Conditions

This slice does not implement macro execution, adapter dispatch, materialization
runtime, `run-operation`, namespace precedence changes, Fusion-only type grammar,
general Jinja runtime evaluation, DuckDB execution, catalog introspection, or
`run_results.json`.

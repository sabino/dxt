# M2 Analysis Parse/List/Compile Source Map

## Scope

This slice adds first-class read/list/compile support for dbt `analysis` SQL
resources in the Zig runtime. It does not execute analyses in `run`, `build`, or
DuckDB materialization paths.

## Upstream References

- dbt Core v1: `core/dbt/parser/analysis.py::AnalysisParser`
  - analyses are `SimpleSQLParser` resources with `NodeType.Analysis`;
  - compiled path uses an `analysis/` prefix for legacy dbt Core manifests.
- dbt Core v1: `core/dbt/parser/read_files.py::get_file_types_for_project`
  - `analysis_paths` plus SQL/Jinja SQL extensions are routed to
    `AnalysisParser`.
- dbt Core v1: `core/dbt/task/list.py::ALL_RESOURCE_VALUES`
  - `NodeType.Analysis` is part of listable resource values.
- dbt Fusion/main: `crates/dbt-parser/src/resolve/resolve_analyses.rs`
  - analyses are resolved from configured analysis paths, get
    `analysis.<package>.<name>` unique ids, carry refs/sources/macros, and use
    `DbtMaterialization::Analysis`.
- dbt Fusion/main: `crates/dbt-schemas/src/schemas/manifest/manifest.rs`
  - manifest serialization normalizes analysis paths with an `analysis/`
    prefix after stripping configured analysis roots.

## dxt Ownership

- `src/project/config.zig`: default `analysis-paths` to `analyses`.
- `src/project/loader.zig`: discover root and package analysis SQL/YAML/docs.
- `src/project.zig`: parse analysis SQL into `Node` resources, apply YAML
  properties, compile selected analyses, and keep execution unsupported.
- `src/project/selector.zig` and `src/root.zig`: make `analysis` selectable by
  resource type and `resource_type:analysis`.
- `src/project/manifest.zig`: emit node `resource_type` from the graph node so
  analysis nodes do not serialize as models.

## Validation Gates

- Native Zig: `zig build test`.
- Integration: `pytest -q tests/test_cli.py::test_parse_list_and_compile_analysis_resources tests/test_cli.py::test_ls_rejects_unsupported_resource_type_and_selector`.
- Safety: runtime-boundary and public-safety scans before PR.

## Stop Conditions

- Stop if analysis execution semantics become necessary; execution is not in
  this slice.
- Stop if arbitrary dbt analysis schema config, tests on analyses, custom
  materializations, or full manifest schema parity are needed; those require
  separate source-grounded slices.

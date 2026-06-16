# dbt Upstream Reference Map

This note maps dbt upstream source code to the dxt Zig ownership model. It is a
planning reference, not a vendoring plan. dxt should keep using dbt execution and
artifact schemas as validation oracles, but feature work should also name the
upstream source files that define the behavior being matched.

Use dbt Core `1.latest` as the observed compatibility contract for M1/M2 parity:
parse the same fixture or project with dbt and dxt, compare normalized JSON
artifacts, and validate against pinned dbt schemas. Use dbt Core v2 / Fusion
`main` as an architecture reference for performance, static analysis, Parquet
metadata, adapter capability shape, and semantic-layer direction. Because v2 is
alpha, it should not override v1 output parity unless the behavior is already
observable in published artifacts or dbt Core-compatible outputs.

## Source Snapshots

- dbt Core v1 Python implementation: `dbt-labs/dbt-core` branch `1.latest`,
  commit `566b75d`.
- dbt Core v2 / Fusion foundation: `dbt-labs/dbt-core` branch `main`, commit
  `9141939`.

Do not copy upstream code. Use these paths to identify behavior, artifact fields,
validation cases, and ownership boundaries.

## Slice Method

Every compatibility slice should record:

- upstream v1 reference files and functions or classes;
- upstream v2 / Fusion reference files and functions or structs, when relevant;
- owning dxt Zig module or planned module;
- affected dbt artifact maps and schema files;
- native Zig tests for core logic;
- Python/dbt oracle tests for CLI, filesystem, fixture, or artifact behavior;
- schema validation gates;
- stop conditions that prevent mixed mechanical and behavior changes.

## Reference Areas

| Compatibility area | Upstream v1 references | Upstream v2 / Fusion references | dxt owner |
| --- | --- | --- | --- |
| Project load and parse order | `core/dbt/parser/manifest.py::ManifestLoader.load`, `parse_project`, `load_and_parse_macros`, `load_macros`, `process_sources`, `process_refs`, `process_docs`, `process_metrics`, `process_unit_tests`, `cleanup_disabled`, `_backfill_direct_parents`, `write_manifest` | `crates/dbt-loader/src/loader.rs::load`, `load_inner`, `load_dbtignore`, `collect_paths`, `merge_vars`; `crates/dbt-parser/src/resolver.rs::resolve`, `resolve_inner`, `resolve_package_waves` | Current `src/project.zig`; future `src/project/loader.zig` orchestration with resource-specific work delegated to `config`, `fs`, `parse`, `jinja`, and `resolve` |
| Parse-time node creation and config | `core/dbt/parser/base.py::ConfiguredParser`, `_create_parsetime_node`, `render_with_context`, `update_parsed_node_config`, `update_parsed_node_relation_names`, `render_update`, `add_result_node`, `parse_node` | `crates/dbt-parser/src/renderer.rs::render_sql_file_inner`, config resolver calls, disabled root-overlay handling, final status/config resolution | `src/project/config.zig`, `src/project/jinja.zig`, future `src/project/parse.zig` resource parsers and `src/project/compiler.zig` |
| Macro parsing | `core/dbt/parser/macros.py::MacroParser`, `parse_macro`, `parse_unparsed_macros`, block types `macro`, `materialization`, `test`, `data_test` | `crates/dbt-parser/src/resolver.rs` macro resolution; `crates/dbt-parser/src/renderer.rs` macro dependency listener | Current macro scanning in `src/project.zig` plus `src/project/jinja.zig`; future `src/project/parse.zig` macro parser and `src/project/resolve.zig` namespace resolver |
| Macro namespace and dispatch | `core/dbt/context/macros.py::MacroNamespace`, `_search_order`, `MacroNamespaceBuilder.add_macro`, `add_macros`, `build_namespace` | `crates/dbt-parser/src/resolver.rs` macro unit construction and package runtime config; adapter dispatch references in adapter/Jinja crates | `src/project/resolve.zig` for lookup semantics; future `src/project/jinja.zig` or `src/project/macro.zig` for executable namespace and dispatch |
| YAML properties and resource patches | `core/dbt/parser/schemas.py::SchemaParser`, `SourceParser`, `PatchParser`, `ModelPatchParser`, `MacroPatchParser`; `core/dbt/parser/schema_yaml_readers.py::ExposureParser`, `MetricParser`, `SemanticModelParser`, `SavedQueryParser` | `crates/dbt-parser/src/resolver.rs::resolve_inner` resource order: sources, seeds, snapshots, groups, models, analyses, functions, exposures, semantic models, metrics, saved queries, data tests, unit tests | Current `src/project.zig` YAML routines and `src/project/parse.zig` helpers; future `src/project/parse.zig` plus narrower modules if needed |
| Exposure, source, ref, metric dependency resolution | `core/dbt/parser/manifest.py::_process_refs`, `_process_sources_for_node`, `_process_sources_for_exposure`, `_process_metrics_for_node` | `crates/dbt-jinja-utils/src/node_resolver.rs::resolve_dependencies`; `crates/dbt-parser/src/resolver.rs` access validation, relation uniqueness, primary-key inference | `src/project/resolve.zig`; current higher-level orchestration still in `src/project.zig` |
| Parse vs runtime Jinja context | `core/dbt/context/providers.py::ParseProvider`, `RuntimeProvider`, `ProviderContext.ref`, `source`, `execute`, `var`, `graph`, `env_var`, `selected_resources`, `generate_parser_model_context`, `generate_runtime_model_context`, `generate_parse_exposure`, `generate_parse_semantic_models` | `crates/dbt-parser/src/renderer.rs` execute=false render, static source recovery behind false branches, hook dependency rendering; `crates/dbt-parser/src/dbt_namespace.rs` parse-mode interception of `get_relation` and `get_columns_in_relation` | Current lexical `src/project/jinja.zig`; future parse context and compile/runtime context modules before M2 |
| Manifest data model and maps | `core/dbt/contracts/graph/manifest.py::Manifest` maps for nodes, sources, macros, docs, exposures, metrics, groups, selectors, files, disabled, semantic_models, unit_tests, saved_queries, fixtures; `build_flat_graph`, `build_parent_and_child_maps`, lookup rebuilders, resource adders | `crates/dbt-schemas/src/schemas/manifest/manifest.rs::build_manifest`, `build_disabled_map`, `build_parent_and_child_maps`, path normalization, `nodes_from_dbt_manifest` | `src/project/types.zig`, `src/project/manifest.zig`, `src/project/resolve.zig` |
| Selector grammar and methods | `core/dbt/graph/selector_spec.py`, `selector.py`, `selector_methods.py`, `cli.py`, `graph.py`, `queue.py`; methods include FQN, tag, group, access, source, exposure, metric, semantic_model, saved_query, unit_test, path, file, package, config, resource_type, test_name, test_type, state, result, source_status, version, selector | `crates/dbt-parser/src/resolver.rs` selector YAML loading; command flags in `crates/dbt-clap-core/src/commands.rs` | `src/project/selector.zig` and CLI validation in `src/root.zig`; future state/result/source-status work in `src/project/state.zig` |
| Artifact schemas | `schemas/dbt/manifest/v12.json`, `schemas/dbt/run-results/v6.json`, `schemas/dbt/sources/v3.json`, `schemas/dbt/catalog/v1.json` | v2 still emits JSON for compatibility and adds Parquet artifacts per README; manifest builder in `crates/dbt-schemas/src/schemas/manifest/manifest.rs` | `src/project/manifest.zig`, future run/catalog/source writers and schema validators under tests/scripts |
| Command surface | dbt v1 command behavior through parser/runner contracts and artifacts | `crates/dbt-clap-core/src/commands.rs::CoreCommand`, static-analysis flags and command parsing | `src/root.zig`, `src/main.zig`, future command-specific modules |
| Adapter capability and SQL identity | v1 adapter behavior is distributed across adapters and context providers | `crates/dbt-adapter-core/src/lib.rs::AdapterType`, `quote_char`, static-analysis support matrix, microbatch capability; `crates/dbt-adapter-sql/src/ident.rs`, `statements.rs`, `types/*` | Future `src/project/adapter.zig`, `src/project/sql.zig`, and cross-database planner modules |
| Fusion-style scalable artifacts | v1 JSON artifacts remain the base compatibility contract | README v2 notes JSON compatibility plus Parquet artifacts; `crates/dbt-index-core/src/ingest/ingest_state.rs`, `crates/dbt-index-core/src/db.rs` define metadata parquet directories and DuckDB views under `dbt.*` and `dbt_rt.*` | Future parse cache/state store, not M1 product behavior |
| Semantic layer and metrics | `schema_yaml_readers.py::MetricParser`, `SemanticModelParser`, `SavedQueryParser`; `manifest.py::process_metrics`, semantic manifest validation and writer | `crates/dbt-schemas/src/schemas/semantic_layer/*`, `crates/dbt-schemas/src/schemas/manifest/semantic_model.rs`, `crates/dbt-parser/src/resolve/resolve_semantic_models.rs`, `crates/dbt-parser/src/resolve/validate_semantic_models.rs`, `crates/dbt-metricflow/*` | Future `src/project/semantic.zig`, semantic manifest writer, metric planner; M1 should keep empty maps schema-valid until implemented |

## Current dxt Baseline

- Product runtime is Zig and remains so.
- Current implemented command surface is `parse`, `ls`, `version`, and help;
  `compile`, `build`, and `docs generate` are placeholders.
- `src/project.zig` is still the facade plus remaining loader/resource parser
  orchestration. It owns high-level graph loading, installed-package resource
  loading, docs block parsing, macro block parsing, YAML source/exposure/model
  property parsing, model/seed parsing, generic-test materialization, warnings,
  and remaining resolver orchestration.
- Existing extracted modules are `types`, `util`, `config`, `fs`, `jinja`,
  `resolve`, `parse`, `selector`, and `manifest`.
- The test base includes native Zig tests for module-level helpers and pytest
  integration tests for CLI/artifact fixtures plus a pinned local Manifest v12
  schema slice.
- M1 should not be treated as closed until the project has a reproducible
  public Jaffle Shop DuckDB parse gate, a dbt-vs-dxt oracle harness for the M1
  fixture ladder, and documented schema-slice expansion rules for fields beyond
  the current emitted manifest surface.
- M2 implementation should wait until M1/M1A gates above are either complete or
  explicitly re-scoped. A source-grounded M2 preplan can proceed first because
  it will clarify parse-time Jinja, macro namespace, adapter dispatch, and
  compiled artifact boundaries without changing product behavior.

## Next Five Source-Grounded Slices

### 1. M1A Loader Facade Extraction

- Upstream references: v1 `ManifestLoader.load`; v2 `dbt-loader/src/loader.rs`,
  `dbt-parser/src/resolver.rs::resolve`.
- dxt files: create `src/project/loader.zig`; shrink `src/project.zig` to call
  loader and manifest/selector facades.
- Tests: native Zig smoke test for loader orchestration over an in-memory or
  temp fixture if practical; keep pytest fixture coverage unchanged.
- Artifact validation: existing Manifest v12 slice for all parse fixtures.
- Stop conditions: stop if extraction changes resource counts, selector output,
  manifest ordering, or diagnostics.

### 2. M1 Source and Exposure YAML Parser Ownership

- Upstream references: v1 `SourceParser`, `ExposureParser`,
  `_process_sources_for_exposure`; v2 `resolve_sources`, `resolve_exposures`.
- dxt files: move source/exposure YAML parsing from `src/project.zig` into
  `src/project/parse.zig` or a follow-up `src/project/schema.zig`.
- Tests: native tests for source tables, exposure owners, maturity, URL,
  `ref`, `source`, and unsupported dependency forms; pytest for fixture
  manifests and `ls source:` / `ls exposure:` behavior.
- Artifact validation: Manifest v12 source/exposure entries, parent/child maps,
  and `depends_on.nodes`.
- Stop conditions: do not add semantic metrics or new selector behavior in this
  extraction.

### 3. M1 Macro Block and Macro Patch Parity

- Upstream references: v1 `MacroParser`, `MacroPatchParser`,
  `MacroNamespaceBuilder`; v2 resolver macro phases and renderer macro
  dependency listener.
- dxt files: move macro block parsing and macro property parsing ownership out
  of `src/project.zig`; extend `src/project/jinja.zig` only for lexical helpers.
- Tests: native tests for macro/materialization/test/data_test block extraction,
  package-qualified macro IDs, argument patch merge, and namespace precedence.
- Python/dbt oracle: compare macro manifest entries and model macro dependencies
  on synthetic package fixtures.
- Artifact validation: Manifest v12 `macros` map and `depends_on.macros`.
- Stop conditions: do not implement macro execution or adapter dispatch in the
  same slice.

### 4. M2 Parse-Time Jinja Context Boundary

- Upstream references: v1 `ParseProvider`, `RuntimeProvider`, provider methods
  for `ref`, `source`, `config`, `var`, `env_var`, `execute`, `this`, `graph`,
  `selected_resources`; v2 `renderer.rs` execute=false rendering,
  `dbt_namespace.rs` adapter introspection capture.
- dxt files: future parse-context module plus `src/project/jinja.zig` scanner
  integration and eventual compiler module.
- Tests: native tests for `execute`-guarded calls, unsupported `run_query` at
  parse time, var/env defaults, and hook dependency capture; pytest/dbt oracle
  for compiled SQL and manifest dependency parity.
- Artifact validation: manifest `refs`, `sources`, `depends_on`, `config`, and
  later compiled SQL outputs.
- Stop conditions: do not start warehouse execution or DuckDB adapter behavior
  until parse/compile context behavior has deterministic fixtures.

### 5. M1/M2 Artifact Schema Expansion

- Upstream references: v1 `Manifest` maps and artifact schemas
  `manifest/v12.json`, `run-results/v6.json`, `sources/v3.json`,
  `catalog/v1.json`; v2 `build_manifest` and JSON compatibility notes.
- dxt files: `src/project/manifest.zig`, future run-results/source/catalog
  writer modules.
- Tests: native deterministic JSON escaping/ordering tests plus pytest schema
  validation against pinned schema slices that grow only when dxt emits the
  corresponding fields.
- Python/dbt oracle: normalize invocation IDs, timestamps, elapsed time,
  adapter responses, and absolute paths before comparison.
- Stop conditions: never invent dbt field names; keep dxt-only metadata in a
  namespaced artifact outside dbt schemas.

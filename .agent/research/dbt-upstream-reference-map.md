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
  `0529e06`.

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
| Project load and parse order | `core/dbt/parser/manifest.py::ManifestLoader.load`, `parse_project`, `load_and_parse_macros`, `load_macros`, `process_sources`, `process_refs`, `process_docs`, `process_metrics`, `process_unit_tests`, `cleanup_disabled`, `_backfill_direct_parents`, `write_manifest` | `crates/dbt-loader/src/loader.rs::load`, `load_inner`, `load_dbtignore`, `collect_paths`, `merge_vars`; `crates/dbt-parser/src/resolver.rs::resolve`, `resolve_package_waves`, `resolve_dependencies` | `src/project/loader.zig` owns graph loading order, package traversal, target path lookup, duplicate-check sequencing, and graph sorting; `src/project.zig` still supplies parser callbacks until resource parsers move down |
| Parse-time node creation and config | `core/dbt/parser/base.py::ConfiguredParser`, `_create_parsetime_node`, `render_with_context`, `update_parsed_node_config`, `update_parsed_node_relation_names`, `render_update`, `add_result_node`, `parse_node` | `crates/dbt-parser/src/renderer.rs::render_sql_file_inner`, config resolver calls, disabled root-overlay handling, final status/config resolution | `src/project/config.zig`, `src/project/jinja.zig`, future `src/project/parse.zig` resource parsers and `src/project/compiler.zig` |
| Macro parsing | `core/dbt/parser/macros.py::MacroParser`, `parse_macro`, `parse_unparsed_macros`, `_extract_args`, block types `macro`, `materialization`, `test`, `data_test`; `core/dbt/clients/jinja.py::get_supported_languages` | `crates/dbt-parser/src/utils.rs::parse_macro_statements`; `crates/dbt-parser/src/sql_file_info.rs::SqlFileInfo`; `crates/dbt-jinja/minijinja/src/compiler/parser.rs` materialization parsing | `src/project/parse.zig` owns current macro/test/data_test/materialization block scanning, materialization supported-language parsing, and dbt Core v1 `flags.validate_macro_args` signature argument extraction; `src/project/jinja.zig` owns lexical macro-call scanning; future `src/project/resolve.zig` or `src/project/macro.zig` owns namespace/dispatch semantics |
| Macro namespace and dispatch | `core/dbt/context/macros.py::MacroNamespace`, `_search_order`, `MacroNamespaceBuilder.add_macro`, `add_macros`, `build_namespace` | `crates/dbt-parser/src/resolver.rs` macro unit construction and package runtime config; adapter dispatch references in adapter/Jinja crates | `src/project/resolve.zig` for lookup semantics; future `src/project/jinja.zig` or `src/project/macro.zig` for executable namespace and dispatch |
| YAML properties and resource patches | `core/dbt/parser/schemas.py::SchemaParser`, `SourceParser`, `PatchParser`, `ModelPatchParser`, `MacroPatchParser`; `core/dbt/parser/schema_yaml_readers.py::ExposureParser`, `MetricParser`, `SemanticModelParser`, `SavedQueryParser` | `crates/dbt-parser/src/resolver.rs::resolve_package_waves` resource order: sources, seeds, snapshots, groups, models, analyses, functions, exposures, semantic models, metrics, saved queries, data tests, unit tests | Current `src/project.zig` YAML routines and `src/project/parse.zig` helpers; future `src/project/parse.zig` plus narrower modules if needed |
| Exposure, source, ref, metric dependency resolution | `core/dbt/parser/manifest.py::_process_refs`, `_process_sources_for_node`, `_process_sources_for_exposure`, `_process_metrics_for_node` | `crates/dbt-jinja-utils/src/node_resolver.rs::resolve_dependencies`; `crates/dbt-parser/src/resolver.rs` access validation, relation uniqueness, primary-key inference | `src/project/resolve.zig`; current higher-level orchestration still in `src/project.zig` |
| Parse vs runtime Jinja context | `core/dbt/context/providers.py::ParseProvider`, `RuntimeProvider`, `ProviderContext.ref`, `source`, `execute`, `var`, `graph`, `env_var`, `selected_resources`, `generate_parser_model_context`, `generate_runtime_model_context`, `generate_parse_exposure`, `generate_parse_semantic_models` | `crates/dbt-parser/src/renderer.rs::render_sql_file_inner`, `augment_sql_resources_with_static_sources`; `crates/dbt-parser/src/dbt_namespace.rs::DbtNamespace` parse-mode interception of `get_relation` and `get_columns_in_relation` | Current lexical `src/project/jinja.zig`; future parse context and compile/runtime context modules before M2 |
| Compile-time Jinja rendering | `core/dbt/compilation.py::Compiler._compile_code`, `compile_node`; `core/dbt/clients/jinja.py::get_rendered`; `core/dbt/context/providers.py::generate_runtime_model_context`, `ModelContext` | `crates/dbt-parser/src/renderer.rs::render_sql_file_inner`; `crates/dbt-jinja-utils/src/phases/compile/compile_node_context.rs::build_compile_node_context_inner`; `crates/dbt-jinja-utils/src/environment_builder.rs::JinjaEnvBuilder`; MiniJinja parser/render snapshots for `set` and `for` | `src/project/compiler.zig` owns the current render-only compiler, including the intentionally narrow static string-list `set` plus simple `for` loop expansion required by public Jaffle DuckDB. Future full context/macro execution must not be hidden inside this narrow parser. |
| Profile, target context, and relation identity | `core/dbt/config/profile.py::Profile.pick_profile_name`, `render_profile`, `from_raw_profile_info`, `_get_profile_data`, `_credentials_from_profile`, `to_target_dict`; `core/dbt/config/runtime.py::load_profile`, `RuntimeConfig.get_metadata`; `core/dbt/context/target.py::TargetContext.target`; `core/dbt/context/providers.py::ParseConfigObject.__call__`, `ModelContext.this`, `RuntimeRefResolver.resolve`, `generate_parser_model_context`, `generate_runtime_model_context`; `core/dbt/parser/base.py::ConfiguredParser.update_parsed_node_config`, `update_parsed_node_relation_names`, `_update_node_relation_name`; `core/dbt/compilation.py::Compiler._create_node_context`, `_compile_code`, `compile_node` | `crates/dbt-loader/src/load_profiles.rs::load_profiles`; `crates/dbt-profile/src/resolve.rs`; `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/get_custom_name/get_custom_schema.sql::default__generate_schema_name`; `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/get_custom_name/get_custom_alias.sql::default__generate_alias_name`; `crates/dbt-parser/src/utils.rs::update_node_relation_components`; `crates/dbt-parser/src/resolve/resolve_models.rs`; `crates/dbt-jinja-utils/src/phases/utils.rs::build_target_context_map`; `crates/dbt-schemas/src/schemas/profiles.rs::DbConfig::adapter_type`, `TargetContext`, `CommonTargetContext`; `crates/dbt-jinja-utils/src/phases/compile/compile_node_context.rs`; `crates/dbt-adapter-core/src/lib.rs::AdapterType`; `crates/dbt-adapter/src/relation/relation_impl.rs`; `crates/dbt-schemas/src/schemas/relations/base.rs` | `src/project/profile.zig` owns the current scalar `profiles.yml` adapter-type and schema parser; `src/project/config.zig` owns `dbt_project.yml` `profile:`; `src/project/jinja.zig` owns narrow quoted-literal inline `config(schema=..., alias=...)` scanning; `src/project/compiler.zig` owns current two-part quoted relation rendering, default inline schema/alias relation components, and narrow `target.*`/`this` compile expressions; future profile/context/relation modules own Jinja rendering, credentials, adapter-specific target fields, target database, include policy, project/YAML schema/alias precedence, custom schema/alias/database macro execution, and full relation identity |
| Manifest data model and maps | `core/dbt/contracts/graph/manifest.py::Manifest` maps for nodes, sources, macros, docs, exposures, metrics, groups, selectors, files, disabled, semantic_models, unit_tests, saved_queries, fixtures; `build_flat_graph`, `build_parent_and_child_maps`, lookup rebuilders, resource adders | `crates/dbt-schemas/src/schemas/manifest/manifest.rs::build_manifest`, `build_disabled_map`, `build_parent_and_child_maps`, path normalization, `nodes_from_dbt_manifest` | `src/project/types.zig`, `src/project/manifest.zig`, `src/project/resolve.zig` |
| Selector grammar and methods | `core/dbt/graph/selector_spec.py`, `selector.py`, `selector_methods.py`, `cli.py`, `graph.py`, `queue.py`; methods include FQN, tag, group, access, source, exposure, metric, semantic_model, saved_query, unit_test, path, file, package, config, resource_type, test_name, test_type, state, result, source_status, version, selector | `crates/dbt-parser/src/resolver.rs` selector YAML loading; command flags in `crates/dbt-clap-core/src/commands.rs` | `src/project/selector.zig` and CLI validation in `src/root.zig`; future state/result/source-status work in `src/project/state.zig` |
| Artifact schemas | `schemas/dbt/manifest/v12.json`, `schemas/dbt/run-results/v6.json`, `schemas/dbt/sources/v3.json`, `schemas/dbt/catalog/v1.json` | v2 still emits JSON for compatibility and adds Parquet artifacts per README; manifest builder in `crates/dbt-schemas/src/schemas/manifest/manifest.rs` | `src/project/manifest.zig`, future run/catalog/source writers and schema validators under tests/scripts |
| Docs catalog generation | `core/dbt/task/docs/generate.py::GenerateTask.run`, selected source handling in `_get_selected_source_ids`, `Catalog`, `Catalog.make_unique_id_map`, `build_catalog_table`, `format_stats`; `core/dbt/artifacts/schemas/catalog/v1/catalog.py::CatalogArtifact`, `CatalogResults` | `crates/dbt-schemas/src/schemas/legacy_catalog/catalog.rs::CatalogTable`, `ColumnMetadata`, `CatalogNodeStats`, `DbtCatalog`, `build_catalog`; Fusion index metadata in `crates/dbt-index-core/src/ingest/ingest_state.rs` | `src/project.zig` owns current docs orchestration; `src/project/catalog.zig` owns dbt-shaped catalog JSON for `nodes` and `sources`; `src/project/duckdb.zig` owns the first local DuckDB relation/column introspection for already-materialized selected model/seed nodes and selected source relations |
| Source freshness and `sources.json` | `core/dbt/task/freshness.py::FreshnessRunner.execute`, `FreshnessSelector.node_is_match`, `FreshnessTask.result_path`, `FreshnessTask.get_result`; `core/dbt/artifacts/schemas/freshness/v3/freshness.py::FreshnessExecutionResultArtifact`, `SourceFreshnessOutput`, `SourceFreshnessRuntimeError`; `core/dbt/parser/sources.py::SourceParser.parse_source`, `calculate_loaded_at_field_query_from_raw_target`, `merge_source_freshness`; `schemas/dbt/sources/v3.json` | `crates/dbt-schemas/src/schemas/sources.rs::FreshnessResultsArtifact`, `FreshnessResultsMetadata`, `FreshnessResultsNode`; `crates/dbt-scheduler/src/node_selector.rs::match_source_status`; wider parse merge references in `crates/dbt-parser/src/resolve/resolve_sources.rs` | `src/root.zig` owns `dxt source freshness` command dispatch; `src/project.zig` owns first orchestration until runner extraction; `src/project/types.zig` owns source freshness fields; `src/project/parse.zig` owns table-level YAML parsing; `src/project/duckdb.zig` owns DuckDB loaded-at-field query execution; `src/project/source_freshness.zig` owns status calculation and `sources.json` v3 rendering |
| Source table identifier | `core/dbt/parser/sources.py::SourcePatcher.parse_source`, `_get_relation_name`; `core/dbt/artifacts/resources/v1/source_definition.py::ParsedSourceMandatory`; `core/dbt/context/providers.py::ParseSourceResolver.resolve`, `RuntimeSourceResolver.resolve`; `core/dbt/contracts/graph/manifest.py::SourceLookup`, `Manifest.resolve_source`; `core/dbt/graph/selector_methods.py::SourceSelectorMethod.search`; `core/dbt/task/list.py::ListTask.generate_selectors`; `schemas/dbt/manifest/v12.json` source `name` and `identifier` fields | `crates/dbt-parser/src/resolve/resolve_sources.rs::resolve_sources`; `crates/dbt-schemas/src/schemas/manifest/manifest_nodes.rs::ManifestSource`; `crates/dbt-schemas/src/schemas/nodes.rs::DbtSourceAttr`, `DbtSource::search_name`, `DbtSource::selector_string`; `crates/dbt-parser/src/resolve/resolve_tests/persist_generic_data_tests.rs::format_node_unique_id` | `src/project/types.zig` owns `SourceDef.identifier`; `src/project/parse.zig` parses table-level YAML `identifier`; `src/project/compiler.zig` owns source physical relation rendering; `src/project/manifest.zig` emits source `identifier` and `relation_name`; `src/project/duckdb.zig` uses physical source identifiers for catalog, freshness, and source generic-test relation SQL while logical selectors/deps stay unchanged |
| Command surface | dbt v1 command behavior through parser/runner contracts and artifacts | `crates/dbt-clap-core/src/commands.rs::CoreCommand`, static-analysis flags and command parsing | `src/root.zig`, `src/main.zig`, future command-specific modules |
| Adapter capability and SQL identity | v1 adapter behavior is distributed across adapters and context providers | `crates/dbt-adapter-core/src/lib.rs::AdapterType`, `quote_char`, static-analysis support matrix, microbatch capability; `crates/dbt-adapter-sql/src/ident.rs`, `statements.rs`, `types/*` | Future `src/project/adapter.zig`, `src/project/sql.zig`, and cross-database planner modules |
| DuckDB SQL model execution and run results | `schemas/dbt/run-results/v6.json`; `core/dbt/artifacts/schemas/run/v5/run.py::RunResultOutput`, `process_run_result`, `RunResultsArtifact.from_execution_results`; `core/dbt/compilation.py::Compiler.compile_node`, `write_graph_file` | `crates/dbt-auth/src/duckdb/mod.rs::DuckDbAuth.configure`; `crates/dbt-loader/src/dbt_macro_assets/dbt-duckdb/macros/adapters.sql::duckdb__create_table_as`, `duckdb__create_view_as`; `crates/dbt-loader/src/dbt_macro_assets/dbt-duckdb/macros/materializations/table.sql`; `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/models/view.sql`; `crates/dbt-schemas/src/schemas/run_results.rs::RunResultOutput`, `RunResultsArtifact`; `crates/dbt-tasks-core/src/stats_to_results.rs`, `utils.rs::build_run_results_artifact` | `src/project/duckdb.zig` owns the first CLI-backed DuckDB execution slice, local-file path guardrails, and table/view SQL rendering; `src/project.zig` currently owns selected-model dependency ordering until a runner module exists; `src/project/run_results.zig` owns the minimal v6 run-results writer; future adapter ABI should replace the CLI backend with embedded DuckDB/linking and add task timing, adapter responses, relation staging, DAG scheduling, seeds, and tests |
| DuckDB seed build execution and run results | `core/dbt/parser/seeds.py::SeedParser`; `core/dbt/artifacts/resources/v1/seed.py::SeedConfig`, `Seed`; `core/dbt/context/providers.py::load_agate_table`; `core/dbt/task/seed.py::SeedRunner`, `SeedTask`; `core/dbt/task/build.py::BuildTask.RUNNER_MAP`; `core/dbt/artifacts/schemas/run/v5/run.py::process_run_result`; `schemas/dbt/run-results/v6.json` | `crates/dbt-parser/src/resolve/resolve_seeds.rs`; `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/seeds/seed.sql`; `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/seeds/helpers.sql`; `crates/dbt-loader/src/dbt_macro_assets/dbt-duckdb/macros/seed.sql`; `crates/dbt-adapter/src/adapter/mod.rs::get_seed_file_path`; `crates/dbt-schemas/src/schemas/run_results.rs::RunResultOutput` | `src/project/duckdb.zig` owns the first root-project CSV seed load SQL and file-path rendering; `src/project.zig` owns the seed-only `build` boundary until a runner module exists; `src/project/run_results.zig` owns null compiled fields for seed results; future work must add package seed roots, seed configs, `dxt seed`, mixed build DAG scheduling, and full materialization semantics |
| DuckDB generic test execution and run results | `core/dbt/task/build.py::BuildTask.RUNNER_MAP`; `core/dbt/task/test.py::TestRunner.execute_data_test`, `build_test_run_result`; `core/dbt/parser/sources.py::SourcePatcher.construct_sources`, `get_source_tests`, `parse_source_test`; `core/dbt/parser/schema_generic_tests.py::SchemaGenericTestParser`; `core/dbt/parser/generic_test_builders.py::TestBuilder.get_synthetic_test_names`, `build_model_str`; `core/dbt/artifacts/resources/v1/generic_test.py::GenericTest`; `core/dbt/artifacts/resources/v1/generic_test.py::TestMetadata`; `core/dbt/artifacts/schemas/run/v5/run.py::process_run_result`; `schemas/dbt/run-results/v6.json` | `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/tests/generic/builtin.sql`; `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/generic_test_sql/not_null.sql`; `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/generic_test_sql/unique.sql`; `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/generic_test_sql/accepted_values.sql`; `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/generic_test_sql/relationships.sql`; `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/tests/test.sql`; `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/tests/helpers.sql`; `crates/dbt-parser/src/resolve/resolve_sources.rs::resolve_sources`; `crates/dbt-parser/src/resolve/resolve_tests/persist_generic_data_tests.rs::TestableTable`, `persist_generic_data_tests`; `crates/dbt-parser/src/resolve/resolve_tests/resolve_data_tests.rs`; `crates/dbt-schemas/src/schemas/run_results.rs::ContextRunResult`; `crates/dbt-tasks-core/src/test_aggregation.rs` | `src/project/parse.zig` owns current source table column and column-test parsing; `src/project.zig` owns current generic-test materialization and the test-only/source+test `build` branches until a runner module exists; `src/project/manifest.zig` owns source-test `attached_node: null`, `sources`, source dependency, and `test_metadata.kwargs.model` serialization; `src/project/duckdb.zig` owns the first direct DuckDB rendering/execution for model/seed `not_null`, `unique`, default-quoted `accepted_values`, ref-backed `relationships`, and source column `not_null`, `unique`, default-quoted `accepted_values` generic tests; `src/project/run_results.zig` owns `pass`/`fail` generic-test result serialization; future work must add mixed build DAG scheduling, macro-backed test execution, wider generic/singular/unit tests, table-level source tests, source relationships, configs, non-ref relationship targets, `accepted_values quote: false`, and store-failures semantics |
| DuckDB model and generic-test build execution | `core/dbt/task/build.py::BuildTask.RUNNER_MAP`; `core/dbt/task/runnable.py::get_graph_queue`, `run_queue`; `core/dbt/graph/selector.py::get_graph_queue`; `core/dbt/graph/queue.py::GraphQueue`; `core/dbt/task/run.py::ModelRunner`; `core/dbt/task/test.py::TestRunner.execute_data_test`, `build_test_run_result`; `core/dbt/artifacts/schemas/run/v5/run.py::process_run_result`; `schemas/dbt/run-results/v6.json` | `crates/dbt-dag/src/schedule.rs::Schedule`; `crates/dbt-dag/src/deps_mgmt.rs::topological_sort`; `crates/dbt-tasks-core/src/stats_to_results.rs`; `crates/dbt-tasks-core/src/utils.rs::build_run_results_artifact`; `crates/dbt-schemas/src/schemas/run_results.rs`; Fusion generic-test SQL and materialization helper macros listed above | `src/project.zig` owns the first model+supported-generic-test `build` branch until a runner module exists; `src/project/duckdb.zig` owns DuckDB execution; `src/project/run_results.zig` owns mixed model/test artifact ordering; seed+model DAGs are covered by the separate seed/model build slice; future work must add wider tests, selector-indirect-selection parity, threaded scheduling, and full materialization semantics |
| DuckDB seed/model/generic-test build execution | `core/dbt/task/build.py::BuildTask.RUNNER_MAP`; `core/dbt/task/runnable.py::get_graph_queue`, `run_queue`; `core/dbt/graph/selector.py::get_graph_queue`; `core/dbt/graph/queue.py::GraphQueue`; `core/dbt/task/seed.py::SeedRunner`; `core/dbt/task/run.py::ModelRunner`; `core/dbt/task/test.py::TestRunner.execute_data_test`, `build_test_run_result`; `core/dbt/artifacts/schemas/run/v5/run.py::process_run_result`; `schemas/dbt/run-results/v6.json` | `crates/dbt-dag/src/schedule.rs::Schedule`; `crates/dbt-dag/src/deps_mgmt.rs::topological_sort`; `crates/dbt-tasks-core/src/stats_to_results.rs`; `crates/dbt-tasks-core/src/utils.rs::build_run_results_artifact`; Fusion seed and generic-test SQL/materialization helper macros listed above | `src/project.zig` owns the first selected seed/model dependency-order `build` branch until a runner module exists; `src/project/duckdb.zig` owns DuckDB execution; `src/project/run_results.zig` owns mixed seed/model/test artifact ordering; future work must add package seeds, wider tests, full dbt queue parity, skip/fail-fast semantics, threaded scheduling, and full materialization semantics |
| Fusion-style scalable artifacts | v1 JSON artifacts remain the base compatibility contract | README v2 notes JSON compatibility plus Parquet artifacts; `crates/dbt-index-core/src/ingest/ingest_state.rs`, `crates/dbt-index-core/src/db.rs` define metadata parquet directories and DuckDB views under `dbt.*` and `dbt_rt.*` | Future parse cache/state store, not M1 product behavior |
| Semantic layer and metrics | `schema_yaml_readers.py::MetricParser`, `SemanticModelParser`, `SavedQueryParser`; `manifest.py::process_metrics`, semantic manifest validation and writer | `crates/dbt-schemas/src/schemas/semantic_layer/*`, `crates/dbt-schemas/src/schemas/manifest/semantic_model.rs`, `crates/dbt-parser/src/resolve/resolve_semantic_models.rs`, `crates/dbt-parser/src/resolve/validate_semantic_models.rs`, `crates/dbt-metricflow/*` | Future `src/project/semantic.zig`, semantic manifest writer, metric planner; M1 should keep empty maps schema-valid until implemented |

## Current dxt Baseline

- Product runtime is Zig and remains so.
- Current implemented command surface is `parse`, `ls`, `compile`, `docs
  generate`, `source freshness`, `run`, `build`, `version`, and help. `compile` and `docs generate`
  are render-only artifact boundaries for the supported parser graph. `run`
  executes selected enabled DuckDB SQL models with `table` and `view`
  materializations through a Zig-owned external CLI backend, validates
  supported materializations before opening DuckDB, executes selected models in
  dependency order, writes `manifest.json`, compiled SQL, and a minimal v6
  `run_results.json`. `build` executes root-project CSV seed-only selections,
  selected DuckDB SQL models with `table` and `view` materializations, selected
  root-project seed+model builds, selected seed+model+supported-generic-test
  builds, selected model+generic-test builds without seeds, and test-only
  selected DuckDB column `not_null`/`unique`/default-quoted
  `accepted_values`/ref-backed `relationships` generic tests against built or
  already-existing attached relations. Package
  seeds, wider generic/singular/unit tests, full dbt queue parity, and full
  materialization semantics remain future work.
- `dxt source freshness` selects source nodes with resolved source/table
  freshness criteria, queries selected DuckDB source tables through resolved
  `loaded_at_field` SQL text plus optional raw `freshness.filter` SQL or
  through resolved raw `loaded_at_query` SQL, classifies `pass` / `warn` /
  `error`, writes `manifest.json`, writes dbt-shaped `sources.json` v3 success
  rows, writes dbt-shaped runtime-error rows for unsupported per-source
  execution gaps such as missing loaded-at configuration, and returns failure
  when a selected source is stale past `error_after` or has a runtime error.
  Empty or all-null loaded-at values are emitted as stale freshness results.
  Source/table `config:` inheritance, dbt-shaped freshness threshold merging,
  final `freshness: null`, narrow source schema rendering, and source table
  `identifier` physical-name overrides are documented in
  `.agent/research/m2-source-config-freshness-inheritance.md` and
  `.agent/research/m2-source-table-identifier.md`. Jinja rendering inside
  `loaded_at_query`, metadata freshness, source-status selectors, hooks,
  threaded scheduling, non-DuckDB adapters, and embedded `libduckdb` remain
  future work.
- `src/project/loader.zig` now owns graph loading order, installed-package
  traversal, target-path lookup, project/package resource traversal,
  macro/property application sequencing, duplicate checks, and graph sorting.
- `src/project.zig` is now the public parse/list facade plus remaining resource
  parser callbacks. It still owns docs block parsing, YAML model property
  parsing, model/seed parsing, generic-test materialization, warnings, and
  remaining resolver orchestration.
- `src/project/parse.zig` owns current top-level `{% macro %}`, `{% test %}`,
  `{% data_test %}`, and `{% materialization %}` block parsing, materialization
  `supported_languages` parsing, macro property YAML parsing,
  macro-property application, dbt Core v1 `flags.validate_macro_args`
  signature argument extraction, YAML argument replacement, argument annotation
  warning collection, and native parser tests for that surface. Macro
  `docs`/`meta` fields are covered for the current scalar artifact subset.
  Macro namespace precedence remains a behavior slice.
- Existing extracted modules are `types`, `util`, `config`, `fs`, `jinja`,
  `loader`, `resolve`, `parse`, `selector`, `manifest`, `compiler`, and
  `catalog`.
- `src/project/compiler.zig` now owns a bounded compile-time Jinja slice for
  bracketed static string-list assignments and simple loops over those lists.
  It is source-grounded in dbt Core v1 runtime rendering and Fusion compile
  context references, but it is deliberately not a general Jinja interpreter:
  scalar set values, unquoted list entries, filters, `if`, loop metadata,
  macros, dynamic lists, and arbitrary expressions remain unsupported.
- Root-project `dispatch:` config is parsed in `src/project/config.zig`, copied
  into the graph by `src/project/loader.zig`, and consumed by
  `src/project/resolve.zig` for static `adapter.dispatch(...)`
  `depends_on.macros` extraction. This is documented in
  `.agent/research/m2-project-dispatch-config.md`.
- Profile-derived target schema is parsed in `src/project/profile.zig`, copied
  into the graph by `src/project/loader.zig`, and consumed by
  `src/project/compiler.zig` for render-only model/ref relation names and
  narrow `target.*` / `this` compile expressions. This is documented in
  `.agent/research/m2-target-schema-this-compile.md`.
- DuckDB profile `path` is parsed in `src/project/profile.zig`, copied into the
  graph by `src/project/loader.zig`, and consumed by `src/project/duckdb.zig`
  for the first `dxt run` execution slice. Relative paths resolve from the
  loaded `profiles.yml` directory; `:memory:` and MotherDuck connection strings
  are rejected for this CLI-backed slice. This is documented in
  `.agent/research/m3-duckdb-run-sql-models.md`.
- Root-project CSV seed-only `dxt build` execution uses the same
  `src/project/duckdb.zig` CLI-backed DuckDB boundary and
  `src/project/run_results.zig` v6 writer. Seed results keep
  `compiled`, `compiled_code`, and `relation_name` null, matching dbt Core's
  non-compiled resource run-results serialization. Mixed seed/model/test build
  execution is covered by a later M3 slice; package seeds, seed configs,
  `dxt seed`, and full materialization semantics remain future work. This is documented in
  `.agent/research/m3-duckdb-build-seeds.md`.
- Test-only `dxt build` execution now supports selected DuckDB column-level
  `not_null`, `unique`, default-quoted `accepted_values`, and ref-backed
  `relationships` generic tests. It renders the dbt built-in failing-row query
  shape directly in Zig, wraps it in the standard `failures`, `should_warn`,
  and `should_error` projection, writes `pass`/`fail` run-results entries, and
  returns exit code `1` on failed tests. Mixed build scheduling, macro-backed
  generic tests, singular tests, unit tests, source tests, custom test configs,
  non-ref relationship targets, `accepted_values` `quote: false`, and
  store-failures remain future work. This is documented in
  `.agent/research/m3-duckdb-generic-tests.md`,
  `.agent/research/m3-duckdb-accepted-values-generic-tests.md`, and
  `.agent/research/m3-duckdb-relationships-generic-tests.md`.
- Literal inline model `config(schema=..., alias=...)` is scanned in
  `src/project/jinja.zig`, stored on `src/project/types.zig` nodes, and consumed
  by `src/project/compiler.zig` for default render-only relation names, refs to
  compiled model nodes, `this` attributes, and compiled manifest
  `relation_name`. This is documented in
  `.agent/research/m2-inline-schema-alias-relations.md`.
- The test base includes native Zig tests for module-level helpers and pytest
  integration tests for CLI/artifact fixtures plus a pinned local Manifest v12
  schema slice.
- M1 now has a reproducible public Jaffle Shop DuckDB parse gate and a dbt-vs-dxt
  oracle harness for the M1 fixture ladder. M1 should still not be treated as
  closed until the known installed-package exposure ref gap is either fixed or
  explicitly re-scoped, and schema-slice expansion rules are applied to each new
  emitted artifact field.
- M2 implementation has started with narrow render-only compile/docs boundaries
  and scalar var-backed dependency arguments. The public Jaffle DuckDB build
  gate now exercises static list-loop compilation through `dxt build` for the
  supported fixture subset. `dxt docs generate` can now keep an empty catalog
  when no local DuckDB database exists and emit selected model/seed catalog
  entries with relation metadata and ordered columns when an existing target
  DuckDB file can be introspected. Selected sources whose DuckDB relations
  already exist are emitted under `catalog.json.sources` using the current
  source relation contract. Broader parse-time Jinja context, macro namespace,
  adapter dispatch, docs-time execution, source relation config, catalog
  comments/owners/stats, source-status selectors, and broader source freshness behavior remain future
  source-grounded slices.

## Next Source-Grounded Slices

### 1. M1 Macro Namespace Parity

- Upstream references: v1 `core/dbt/parser/macros.py::MacroParser`,
  `parse_unparsed_macros`, `parse_macro`, `_extract_args`,
  `core/dbt/parser/schemas.py::MacroPatchParser.parse_patch`,
  `_check_patch_arguments`, `is_valid_type`,
  `core/dbt/context/macros.py::MacroNamespaceBuilder`,
  `core/dbt/contracts/graph/manifest.py::MacroMethods`; v2
  `crates/dbt-parser/src/resolve/resolve_macros.rs::resolve_macros`,
  `resolve_docs_macros`, `process_docs_macro_file`, `is_valid_macro_arg_type`,
  `apply_macro_patches`,
  `crates/dbt-jinja-utils/src/listener.rs::MacroDependencyListener`,
  and macro namespace registries in the Jinja environment builder.
- dxt files: current top-level macro block parsing and macro property YAML
  ownership lives in `src/project/parse.zig`; keep lexical scanning helpers in
  `src/project/jinja.zig` and lookup/namespace behavior in
  `src/project/resolve.zig`. Introduce a future `src/project/macro.zig` only if
  macro execution, namespace, and dispatch logic would otherwise make
  `parse.zig` too broad.
- Tests: native tests already cover parser-controlled macro argument extraction
  under `flags.validate_macro_args`, YAML argument replacement, invalid argument
  type diagnostics, duplicate macro patch rejection, and patch
  `description`/`docs`/`meta`. The remaining namespace slice needs native tests
  for package/root/global search order and dispatch lookup. Existing native and
  Python tests now cover top-level `{% macro %}`, `{% materialization %}`, and
  `{% test %}` artifact extraction plus materialization supported languages;
  `{% data_test %}` has native source-grounded coverage because local dbt Core
  1.10 rejects the tag before writing oracle artifacts.
- Python/dbt oracle: compare macro manifest entries and model macro dependencies
  on synthetic package fixtures, including package macro namespace fixtures.
- Artifact validation: Manifest v12 `macros` map and `depends_on.macros`.
- Stop conditions: do not implement macro execution or adapter dispatch in the
  same slice; do not implement materialization runtime behavior here.

### 2. M2 Parse-Time Jinja Context Boundary

- Upstream references: v1 `core/dbt/context/README.md`,
  `core/dbt/context/configured.py::SchemaYamlContext`,
  `generate_schema_yml_context`, `core/dbt/context/providers.py::ParseProvider`,
  `RuntimeProvider`, `ParseConfigObject`, `ParseRefResolver`,
  `ParseSourceResolver`, `ProviderContext.ref`, `source`, `ctx_config`,
  `execute`, `generate_parser_model_context`, `generate_parse_exposure`,
  `generate_parse_semantic_models`; v2
  `crates/dbt-parser/src/renderer.rs::render_sql_file_inner`,
  `render_unresolved_sql_files`, `augment_sql_resources_with_static_sources`,
  `SqlFileRenderResult`, `RenderCtx`,
  `crates/dbt-jinja-utils/src/phases/parse/init.rs::initialize_parse_jinja_environment`,
  `crates/dbt-jinja-utils/src/phases/parse/resolve_model_context.rs`,
  `crates/dbt-jinja-utils/src/phases/parse/sql_resource.rs::SqlResource`, and
  `crates/dbt-parser/src/dbt_namespace.rs::DbtNamespace`.
- dxt files: add a narrow `src/project/context.zig` or
  `src/project/jinja_context.zig` for parse-time context data/callbacks; keep
  scanner-level helpers in `src/project/jinja.zig`; have
  `src/project/resolve.zig` consume collected `Ref`, `Source`, `StaticSource`,
  `ConfigCall`, and macro dependency records; reserve compiled SQL behavior for
  a later `src/project/compiler.zig`.
- Tests: native tests that `execute` is false at parse time,
  `config(materialized=..., tags=...)` records config and returns empty text,
  literal `ref`/`source` record dependencies and deterministic placeholder
  relation text, dynamic `ref(var(...))` remains unsupported, static
  `source()` discovery from false branches does not become a normal runtime
  dependency edge, `var`/`env_var` defaults are captured, and parse adapter
  `get_relation`/`get_columns_in_relation` calls are recorded as metadata rather
  than executed. Add pytest/dbt oracle fixtures for parse-time `execute`,
  `run_query`, refs/sources inside macros, and manifest dependency parity.
- Artifact validation: manifest `refs`, `sources`, `depends_on`, `config`, and
  macro dependencies only. No compiled fields yet.
- Stop conditions: do not start warehouse execution or DuckDB adapter behavior
  until parse/compile context behavior has deterministic fixtures; do not add
  general-purpose Jinja interpretation if deterministic parse extraction is
  enough; do not serialize static source metadata as normal dbt dependency
  fields.

### 3. M1/M2 Artifact Schema Expansion

- Upstream references: v1
  `core/dbt/artifacts/schemas/manifest/v12/manifest.py::WritableManifest`,
  `ManifestMetadata`, `core/dbt/artifacts/resources/base.py::BaseResource`,
  `GraphResource`, `Docs`, `FileHash`,
  `core/dbt/artifacts/resources/v1/components.py::ParsedResource`,
  `CompiledResource`, `DependsOn`, `MacroDependsOn`, plus v1 resource classes
  for model, source definition, exposure, macro, and seed; v2
  `crates/dbt-schemas/src/schemas/manifest/manifest.rs::build_manifest`,
  `build_disabled_map`, `build_parent_and_child_maps`, `build_group_map`,
  `path_config_for_package`, path normalization helpers, and
  `crates/dbt-schemas/src/schemas/manifest/v12.rs::DbtManifestV12`.
- dxt files: grow `src/project/types.zig` and `src/project/manifest.zig` in
  small field clusters; add a later `src/project/artifacts.zig` only when
  run-results, sources, or catalog writers exist; keep path normalization
  centralized.
- Tests: native deterministic JSON writer tests for metadata, checksum, docs
  config, source config, source columns, macro config, stable null/default
  emission, parent/child map leaf entries, sorted and deduped dependencies,
  disabled map serialization, patch path normalization, and package path
  normalization. Add pytest/dbt field comparison with nondeterministic
  timestamp/invocation/path normalization.
- Artifact validation: grow the pinned Manifest v12 schema slice only for fields
  actually emitted. Practical next clusters are metadata
  `dbt_schema_version`/`dbt_version`/`generated_at`/`adapter_type`/`quoting`,
  model/seed relation fields, source descriptive/config fields, and macro
  `config`/`created_at`.
- Stop conditions: one schema cluster per slice; never invent dbt field names;
  keep dxt-only metadata in a namespaced artifact outside dbt schemas; do not
  vendor a full generated schema unless it is used by validation.

### 4. M2 First Compile Boundary And Adapter Relation Identity

- Upstream references: v1 `core/dbt/task/compile.py::CompileRunner.compile`,
  `CompileRunner.execute`, `CompileTask`,
  `core/dbt/compilation.py::Compiler._create_node_context`, `_compile_code`,
  `_recursively_prepend_ctes`, `_write_node`, `compile_node`,
  `inject_ctes_into_sql`, `core/dbt/task/run.py::ModelRunner._get_materialization_macro`,
  `_execute_model`, `_materialization_relations`,
  `_validate_materialization_relations_dict`, `execute`; v2
  `crates/dbt-adapter-core/src/lib.rs::AdapterType`, `quote_char`,
  static-analysis and microbatch capability helpers,
  `crates/dbt-adapter-sql/src/ident.rs`, `statements.rs`, `types/mod.rs`, and
  metadata/index direction from `crates/dbt-index-core` and
  `crates/dbt-metadata-parquet`.
- dxt files: introduce `src/project/compiler.zig` for render-only compile
  output and `src/project/adapter.zig`, `src/project/sql.zig`, or
  `src/project/relation.zig` for adapter kind, quoting, identifier formatting,
  relation identity, target profile values, and SQL statement classification.
  Reserve `src/project/runner.zig`, live connections, and metadata/index
  writers for later.
- Tests: native tests for compiling simple refs/sources into deterministic
  relation strings, compiled target-path layout, adapter aliases such as
  `postgres`/`postgresql`, quote chars, must-quote identifiers, max identifier
  length, relation naming from database/schema/alias, capability matrices, and
  rejecting missing materialization macros at the boundary without executing
  anything.
- Python/dbt oracle: compare `dbt compile` vs `dxt compile` for `single_model`,
  `model_ref`, `source_ref`, and inline config fixtures, normalizing
  `compiled_code`, `compiled_path`, `relation_name`, and selected manifest
  compiled fields without opening a warehouse connection.
- Artifact validation: add compile-only manifest fields only when emitted:
  `compiled_code`, `compiled`, `compiled_path`, `extra_ctes_injected`,
  `extra_ctes`, and `relation_name`. Do not emit successful `run_results.json`
  until a materialization actually executes.
- Stop conditions: no table/view creation, DuckDB adapter execution,
  materialization macro execution, adapter cache mutation, transactions,
  cross-database movement, Parquet dependency, or Python product behavior in
  this slice.

## 2026-06-17 Refresh: Next Five Small Slices

This refresh used three read-only GPT-5.5/Azure passes over dbt Core v1,
dbt Core v2/Fusion, and the current dxt Zig modules. The conclusion is to keep
dbt Core v1 as the behavior/artifact oracle, use Fusion as an architecture
reference, and land the next work as small Zig-owned slices with native tests
plus Python/dbt oracle checks where CLI, files, fixtures, or artifacts are
touched.

### 1. M2 Minimal Macro Dispatch Rendering For Jaffle `cents_to_dollars`

- Upstream references: v1 `core/dbt/context/macros.py::MacroNamespace`,
  `core/dbt/context/providers.py::RuntimeProvider`,
  `core/dbt/clients/jinja.py::get_rendered`; Fusion
  `crates/dbt-jinja-utils/src/phases/compile/compile_node_context.rs` and
  `crates/dbt-init/assets/jaffle_shop/macros/cents_to_dollars.sql`.
- dxt files: `src/project/parse.zig`, `src/project/jinja.zig`,
  `src/project/resolve.zig`, `src/project/compiler.zig`; introduce
  `src/project/macro.zig` only if lookup/rendering would otherwise spread
  across parser code.
- Native tests: macro namespace lookup for root/package wrapper macros,
  dispatch to `default__cents_to_dollars`, one literal string argument
  substitution, and loud rejection for arbitrary or multi-statement macros.
- Python/dbt oracle: synthetic Jaffle-style fixture with
  `{{ cents_to_dollars('subtotal') }}` through `compile`, `docs generate`,
  `run`, and `build`; compare normalized compiled SQL and artifact slices.
- Artifact validation: Manifest v12 `compiled_code` and
  `depends_on.macros`; Run Results v6 for `run`/`build`; Catalog v1 after docs
  generation when a relation exists.
- Stop conditions: no general Jinja interpreter, materialization macro
  execution, arbitrary macro return values, or Python product runtime.

### 2. M1/M2 Source `config:` And Freshness Inheritance

- Upstream references: v1 `core/dbt/parser/sources.py`
  `calculate_freshness_from_raw_target`,
  `calculate_loaded_at_field_query_from_raw_target`, and
  `merge_source_freshness`; source artifact models in
  `core/dbt/artifacts/resources/v1/source_definition.py`; Fusion
  `crates/dbt-parser/src/resolve/resolve_sources.rs`.
- dxt files: `src/project/types.zig`, `src/project/parse.zig`,
  `src/project/compiler.zig` or a source relation helper,
  `src/project/duckdb.zig`, `src/project/source_freshness.zig`,
  `src/project/manifest.zig`.
- Native tests: source-level/table-level `config.loaded_at_field`,
  `config.loaded_at_query`, dbt-shaped freshness merge/override/null behavior,
  conflict rejection across top-level/config loaded-at syntax, and narrow source
  schema rendering for `{{ target.schema }}_raw`.
- Python/dbt oracle: fixture with inherited source freshness, table override,
  table null override, and DuckDB `dxt source freshness --select source:...`.
- Artifact validation: Manifest v12 source fields after schema-slice expansion,
  Sources v3 `sources.json`, and Catalog v1 selected source entries.
- Stop conditions: no metadata freshness, adapter metadata APIs, source-status
  selectors, or broad Jinja in source schema beyond the explicit target-schema
  expression.

### 3. M2 Selector Parity For Remaining `file:` And `ls`

- Upstream references: v1 `core/dbt/graph/selector_spec.py::RAW_SELECTOR_PATTERN`,
  `SelectionCriteria`, `core/dbt/graph/selector.py::collect_specified_neighbors`,
  `core/dbt/graph/selector_methods.py::FileSelectorMethod`,
  `core/dbt/graph/graph.py::select_childrens_parents`,
  `core/dbt/task/list.py::ListTask`; Fusion command and selector loading in
  `crates/dbt-clap-core/src/commands.rs` and
  `crates/dbt-parser/src/resolver.rs`, plus path/selector centralization in
  `crates/dbt-scheduler/src/node_selector.rs`.
- dxt files: selector validation in `src/root.zig`, matching/expansion in
  `src/project/selector.zig`, and selected JSON output helpers where relevant.
- Native tests: reject invalid combinations, continue expanding `file:` after
  the basename/stem, depth-limited `+`, and `@` slices, preserve current union,
  intersection, wildcard, and exclude behavior, and keep `ls` output helpers
  deterministic.
- Python/dbt oracle: `dxt ls` vs `dbt ls` on selector fixtures and
  Jaffle-style projects for `@stg_orders`, `+orders`, `orders+`, and
  `file:orders.sql`; reuse selectors through `compile`, `docs generate`, and
  `build` smoke fixtures.
- Artifact validation: `ls` writes no artifacts; commands that reuse selectors
  must validate Manifest v12, Catalog v1, or Run Results v6 as applicable.
- Stop conditions: no YAML selectors, state/result/source-status selectors,
  broad indirect-selection flags, full dbt list JSON parity, or nested
  `--output-keys` in this slice.

### 4. M2 Parse/Compile `execute` Boundary And Static `{% if %}`

- Upstream references: v1 `core/dbt/context/providers.py::ProviderContext.execute`,
  `ParseProvider`, `RuntimeProvider`, `generate_parser_model_context`; Fusion
  `crates/dbt-parser/src/renderer.rs` and
  `crates/dbt-parser/src/dbt_namespace.rs`.
- dxt files: `src/project/jinja.zig` for dependency scanning,
  `src/project/compiler.zig` for render-only compile, and possibly
  `src/project/context.zig` for parse/compile mode constants.
- Native tests: parse phase treats `execute` as false; compile/run/build/docs
  render phase supports `{% if execute %}`, `{% if not execute %}`, `{% else %}`;
  unsupported conditions reject clearly.
- Python/dbt oracle: fixture with `run_query` guarded by `{% if execute %}` and
  static fallback in `{% else %}`; compare manifest dependencies and compiled
  SQL.
- Artifact validation: Manifest v12 `refs`, `sources`, `depends_on`, and
  `compiled_code`; Run Results v6 only when executed through DuckDB.
- Stop conditions: no database calls from Jinja, general expression evaluator,
  filters/tests, loop metadata, or Python-backed product rendering.

### 5. M1 Read-Only Unit Test Artifact Surface

- Upstream references: v1 `core/dbt/parser/schema_yaml_readers.py` unit-test
  parsing path, `core/dbt/artifacts/resources/v1/unit_test_definition.py`,
  `core/dbt/graph/selector_methods.py::UnitTestSelectorMethod`; Fusion
  `crates/dbt-parser/src/resolve/resolve_tests/resolve_unit_tests.rs`.
- dxt files: `src/project/types.zig`, `src/project/parse.zig`,
  `src/project/manifest.zig`, `src/project/selector.zig`, `src/root.zig`.
- Native tests: parse `unit_tests:` with model input refs, given rows, expected
  rows, dependency refs, and selector handling for `resource_type:unit_test`.
- Python/dbt oracle: newer Jaffle-style YAML with unit tests; compare
  `manifest.unit_tests`, parent/child maps, and `dxt ls` behavior against dbt.
- Artifact validation: expand the Manifest v12 slice for `unit_tests`; assert
  `run_results.json` is not produced for read-only unit-test parsing.
- Stop conditions: no unit-test execution in `build`, fixture materialization,
  or SQL comparison engine. If selected for `build`, return a clear unsupported
  execution error after writing a valid manifest.

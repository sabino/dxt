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
| Profile, target context, and relation identity | `core/dbt/config/profile.py::Profile.pick_profile_name`, `render_profile`, `from_raw_profile_info`, `_get_profile_data`, `_credentials_from_profile`, `to_target_dict`; `core/dbt/config/runtime.py::load_profile`, `RuntimeConfig.get_metadata`; `core/dbt/context/target.py::TargetContext.target`; `core/dbt/context/providers.py::ParseConfigObject.__call__`, `ModelContext.this`, `RuntimeRefResolver.resolve`, `generate_parser_model_context`, `generate_runtime_model_context`; `core/dbt/parser/base.py::ConfiguredParser.update_parsed_node_config`, `update_parsed_node_relation_names`, `_update_node_relation_name`; `core/dbt/compilation.py::Compiler._create_node_context`, `_compile_code`, `compile_node` | `crates/dbt-loader/src/load_profiles.rs::load_profiles`; `crates/dbt-profile/src/resolve.rs`; `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/get_custom_name/get_custom_schema.sql::default__generate_schema_name`; `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/get_custom_name/get_custom_alias.sql::default__generate_alias_name`; `crates/dbt-parser/src/utils.rs::update_node_relation_components`; `crates/dbt-parser/src/resolve/resolve_models.rs`; `crates/dbt-jinja-utils/src/phases/utils.rs::build_target_context_map`; `crates/dbt-schemas/src/schemas/profiles.rs::DbConfig::adapter_type`, `TargetContext`, `CommonTargetContext`; `crates/dbt-jinja-utils/src/phases/compile/compile_node_context.rs`; `crates/dbt-adapter-core/src/lib.rs::AdapterType`; `crates/dbt-adapter/src/relation/relation_impl.rs`; `crates/dbt-schemas/src/schemas/relations/base.rs` | `src/project/profile.zig` owns the current scalar `profiles.yml` adapter-type and schema parser; `src/project/config.zig` owns `dbt_project.yml` `profile:`; `src/project/jinja.zig` owns narrow quoted-literal inline `config(schema=..., alias=...)` scanning; `src/project/compiler.zig` owns current two-part quoted relation rendering, default inline schema/alias relation components, and narrow `target.*`/`this` compile expressions; future profile/context/relation modules own Jinja rendering, credentials, adapter-specific target fields, target database, include policy, project/YAML schema/alias precedence, custom schema/alias/database macro execution, and full relation identity |
| Manifest data model and maps | `core/dbt/contracts/graph/manifest.py::Manifest` maps for nodes, sources, macros, docs, exposures, metrics, groups, selectors, files, disabled, semantic_models, unit_tests, saved_queries, fixtures; `build_flat_graph`, `build_parent_and_child_maps`, lookup rebuilders, resource adders | `crates/dbt-schemas/src/schemas/manifest/manifest.rs::build_manifest`, `build_disabled_map`, `build_parent_and_child_maps`, path normalization, `nodes_from_dbt_manifest` | `src/project/types.zig`, `src/project/manifest.zig`, `src/project/resolve.zig` |
| Selector grammar and methods | `core/dbt/graph/selector_spec.py`, `selector.py`, `selector_methods.py`, `cli.py`, `graph.py`, `queue.py`; methods include FQN, tag, group, access, source, exposure, metric, semantic_model, saved_query, unit_test, path, file, package, config, resource_type, test_name, test_type, state, result, source_status, version, selector | `crates/dbt-parser/src/resolver.rs` selector YAML loading; command flags in `crates/dbt-clap-core/src/commands.rs` | `src/project/selector.zig` and CLI validation in `src/root.zig`; future state/result/source-status work in `src/project/state.zig` |
| Artifact schemas | `schemas/dbt/manifest/v12.json`, `schemas/dbt/run-results/v6.json`, `schemas/dbt/sources/v3.json`, `schemas/dbt/catalog/v1.json` | v2 still emits JSON for compatibility and adds Parquet artifacts per README; manifest builder in `crates/dbt-schemas/src/schemas/manifest/manifest.rs` | `src/project/manifest.zig`, future run/catalog/source writers and schema validators under tests/scripts |
| Command surface | dbt v1 command behavior through parser/runner contracts and artifacts | `crates/dbt-clap-core/src/commands.rs::CoreCommand`, static-analysis flags and command parsing | `src/root.zig`, `src/main.zig`, future command-specific modules |
| Adapter capability and SQL identity | v1 adapter behavior is distributed across adapters and context providers | `crates/dbt-adapter-core/src/lib.rs::AdapterType`, `quote_char`, static-analysis support matrix, microbatch capability; `crates/dbt-adapter-sql/src/ident.rs`, `statements.rs`, `types/*` | Future `src/project/adapter.zig`, `src/project/sql.zig`, and cross-database planner modules |
| DuckDB SQL model execution and run results | `schemas/dbt/run-results/v6.json`; `core/dbt/artifacts/schemas/run/v5/run.py::RunResultOutput`, `process_run_result`, `RunResultsArtifact.from_execution_results`; `core/dbt/compilation.py::Compiler.compile_node`, `write_graph_file` | `crates/dbt-auth/src/duckdb/mod.rs::DuckDbAuth.configure`; `crates/dbt-loader/src/dbt_macro_assets/dbt-duckdb/macros/adapters.sql::duckdb__create_table_as`, `duckdb__create_view_as`; `crates/dbt-loader/src/dbt_macro_assets/dbt-duckdb/macros/materializations/table.sql`; `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/models/view.sql`; `crates/dbt-schemas/src/schemas/run_results.rs::RunResultOutput`, `RunResultsArtifact`; `crates/dbt-tasks-core/src/stats_to_results.rs`, `utils.rs::build_run_results_artifact` | `src/project/duckdb.zig` owns the first CLI-backed DuckDB execution slice, local-file path guardrails, and table/view SQL rendering; `src/project.zig` currently owns selected-model dependency ordering until a runner module exists; `src/project/run_results.zig` owns the minimal v6 run-results writer; future adapter ABI should replace the CLI backend with embedded DuckDB/linking and add task timing, adapter responses, relation staging, DAG scheduling, seeds, and tests |
| DuckDB seed build execution and run results | `core/dbt/parser/seeds.py::SeedParser`; `core/dbt/artifacts/resources/v1/seed.py::SeedConfig`, `Seed`; `core/dbt/context/providers.py::load_agate_table`; `core/dbt/task/seed.py::SeedRunner`, `SeedTask`; `core/dbt/task/build.py::BuildTask.RUNNER_MAP`; `core/dbt/artifacts/schemas/run/v5/run.py::process_run_result`; `schemas/dbt/run-results/v6.json` | `crates/dbt-parser/src/resolve/resolve_seeds.rs`; `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/seeds/seed.sql`; `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/seeds/helpers.sql`; `crates/dbt-loader/src/dbt_macro_assets/dbt-duckdb/macros/seed.sql`; `crates/dbt-adapter/src/adapter/mod.rs::get_seed_file_path`; `crates/dbt-schemas/src/schemas/run_results.rs::RunResultOutput` | `src/project/duckdb.zig` owns the first root-project CSV seed load SQL and file-path rendering; `src/project.zig` owns the seed-only `build` boundary until a runner module exists; `src/project/run_results.zig` owns null compiled fields for seed results; future work must add package seed roots, seed configs, `dxt seed`, mixed build DAG scheduling, and full materialization semantics |
| DuckDB generic test execution and run results | `core/dbt/task/build.py::BuildTask.RUNNER_MAP`; `core/dbt/task/test.py::TestRunner.execute_data_test`, `build_test_run_result`; `core/dbt/artifacts/resources/v1/generic_test.py::GenericTest`; `core/dbt/artifacts/schemas/run/v5/run.py::process_run_result`; `schemas/dbt/run-results/v6.json` | `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/tests/generic/builtin.sql`; `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/generic_test_sql/not_null.sql`; `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/generic_test_sql/unique.sql`; `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/tests/test.sql`; `crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/materializations/tests/helpers.sql`; `crates/dbt-schemas/src/schemas/run_results.rs::ContextRunResult`; `crates/dbt-tasks-core/src/test_aggregation.rs` | `src/project/duckdb.zig` owns the first direct DuckDB rendering/execution for `not_null` and `unique` column generic tests; `src/project.zig` owns the test-only `build` branch until a runner module exists; `src/project/run_results.zig` owns `pass`/`fail` generic-test result serialization; future work must add mixed build DAG scheduling, macro-backed test execution, wider generic/singular/unit/source tests, configs, and store-failures semantics |
| DuckDB model and generic-test build execution | `core/dbt/task/build.py::BuildTask.RUNNER_MAP`; `core/dbt/task/runnable.py::get_graph_queue`, `run_queue`; `core/dbt/graph/selector.py::get_graph_queue`; `core/dbt/graph/queue.py::GraphQueue`; `core/dbt/task/run.py::ModelRunner`; `core/dbt/task/test.py::TestRunner.execute_data_test`, `build_test_run_result`; `core/dbt/artifacts/schemas/run/v5/run.py::process_run_result`; `schemas/dbt/run-results/v6.json` | `crates/dbt-dag/src/schedule.rs::Schedule`; `crates/dbt-dag/src/deps_mgmt.rs::topological_sort`; `crates/dbt-tasks-core/src/stats_to_results.rs`; `crates/dbt-tasks-core/src/utils.rs::build_run_results_artifact`; `crates/dbt-schemas/src/schemas/run_results.rs`; Fusion generic-test SQL and materialization helper macros listed above | `src/project.zig` owns the first model+supported-generic-test `build` branch until a runner module exists; `src/project/duckdb.zig` owns DuckDB execution; `src/project/run_results.zig` owns mixed model/test artifact ordering; future work must add seed+model DAGs, wider tests, selector-indirect-selection parity, threaded scheduling, and full materialization semantics |
| Fusion-style scalable artifacts | v1 JSON artifacts remain the base compatibility contract | README v2 notes JSON compatibility plus Parquet artifacts; `crates/dbt-index-core/src/ingest/ingest_state.rs`, `crates/dbt-index-core/src/db.rs` define metadata parquet directories and DuckDB views under `dbt.*` and `dbt_rt.*` | Future parse cache/state store, not M1 product behavior |
| Semantic layer and metrics | `schema_yaml_readers.py::MetricParser`, `SemanticModelParser`, `SavedQueryParser`; `manifest.py::process_metrics`, semantic manifest validation and writer | `crates/dbt-schemas/src/schemas/semantic_layer/*`, `crates/dbt-schemas/src/schemas/manifest/semantic_model.rs`, `crates/dbt-parser/src/resolve/resolve_semantic_models.rs`, `crates/dbt-parser/src/resolve/validate_semantic_models.rs`, `crates/dbt-metricflow/*` | Future `src/project/semantic.zig`, semantic manifest writer, metric planner; M1 should keep empty maps schema-valid until implemented |

## Current dxt Baseline

- Product runtime is Zig and remains so.
- Current implemented command surface is `parse`, `ls`, `compile`, `docs
  generate`, `run`, `build`, `version`, and help. `compile` and `docs generate`
  are render-only artifact boundaries for the supported parser graph. `run`
  executes selected enabled DuckDB SQL models with `table` and `view`
  materializations through a Zig-owned external CLI backend, validates
  supported materializations before opening DuckDB, executes selected models in
  dependency order, writes `manifest.json`, compiled SQL, and a minimal v6
  `run_results.json`. `build` executes root-project CSV seed-only selections,
  selected DuckDB SQL models with `table` and `view` materializations, selected
  model+generic-test builds without seeds, and test-only selected DuckDB column
  `not_null`/`unique` generic tests against built or already-existing attached
  relations. Seed+model scheduling, wider generic/singular/unit tests, and full
  materialization semantics remain future work.
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
  execution, package seeds, seed configs, `dxt seed`, and full materialization
  semantics remain future work. This is documented in
  `.agent/research/m3-duckdb-build-seeds.md`.
- Test-only `dxt build` execution now supports selected DuckDB column-level
  `not_null` and `unique` generic tests. It renders the dbt built-in failing-row
  query shape directly in Zig, wraps it in the standard `failures`,
  `should_warn`, and `should_error` projection, writes `pass`/`fail` run-results
  entries, and returns exit code `1` on failed tests. Mixed build scheduling,
  macro-backed generic tests, `accepted_values`, `relationships`, singular
  tests, unit tests, source tests, custom test configs, and store-failures remain
  future work. This is documented in
  `.agent/research/m3-duckdb-generic-tests.md`.
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
  and scalar var-backed dependency arguments. Broader parse-time Jinja context,
  macro namespace, adapter dispatch, materialization execution, catalog
  introspection, and run-results behavior remain future source-grounded slices.

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

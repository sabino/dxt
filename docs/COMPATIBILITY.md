# Compatibility Matrix

The initial execution contract is **SQL models on native DuckDB and PostgreSQL**.
The implementation has focused native, CLI, warehouse and upstream comparison
evidence. Release acceptance requires the candidate-specific gates below; an
implemented row does not establish universal dbt parity.

| Contract | Pinned version |
| --- | --- |
| dbt Core | 1.10.5 |
| dbt-duckdb | 1.9.6 |
| dbt-postgres | 1.9.1 |
| Native DuckDB fixture | 1.4.2 |
| MetricFlow | 0.208.1 |
| dbt semantic interfaces | 0.9.0 |
| Zig toolchain | 0.16.0 |
| Canonical Core helper semantics | CPython 3.12 |

Other dbt versions, database adapters and operating systems require separate
certification. Python is used for developer oracles and fixtures. Product
loading, compilation, planning, artifacts and execution run through the native
binary; no installed Python/dbt runtime is required.

## Commands And Resources

| Surface | Implemented behavior | Focused evidence |
| --- | --- | --- |
| `parse`, `ls` / `list` | Shared YAML/project/profile/config handling; enabled/disabled resources, package namespaces, model versions, groups/access, selected IDs and Core-style listing. | [Configuration](../tests/test_usability_configuration.py), [groups](../tests/test_usability_groups.py), [CLI options](../tests/test_usability_cli_options.py). |
| `compile` | Typed SQL/Jinja rendering for models, analyses, snapshots and data tests; seeds receive compile results; ephemeral CTEs and database-backed compile contexts are supported. Generic tests retain typed helper values and authored SQL. Python models retain source and receive a native-rendered dbt scaffold. | [Jinja](../tests/test_usability_jinja.py), [compile artifacts](../tests/test_usability_compile_artifacts.py), [generic bodies/Relation arguments](../tests/test_usability_test_compilation.py), [ephemeral data tests](../tests/test_usability_ephemeral_tests.py), [Python resources](../tests/test_usability_python_models.py). |
| `run`, `build` | Dependency scheduling through physical and ephemeral ancestors; mixed seed/model/snapshot/unit/data-test work; durable errors, blocked skips and independent continuation. | [Scheduler](../tests/test_usability_scheduler.py), [test errors](../tests/test_usability_test_errors.py), [threading](../tests/test_usability_threading.py). |
| `seed` | Native CSV loading, quoting/types, repeat reload, full-refresh and seed display behavior on both adapters. | [CLI execution](../tests/test_usability_cli_execution.py), [adapters](../tests/test_usability_adapters.py). |
| `test` | Built-in and authored generic tests, singular SQL tests, severity/thresholds and persisted failure tables/views. Unit tests use dict/CSV/SQL fixtures, sparse/empty inputs, typed macro/var/env overrides and model versions. Tests use existing relations unless the build graph selects their parents. | [Configuration](../tests/test_usability_configuration.py), [unit fixtures](../tests/test_usability_unit_fixtures.py), [unit metadata](../tests/test_usability_unit_metadata.py), [failure audits](../tests/test_usability_cli_execution.py). |
| `snapshot` | SQL and YAML resources; timestamp/check history, updates/deletes/returning rows, metadata columns, schema evolution and atomic failure behavior on both adapters. | [DuckDB snapshots](../tests/test_usability_snapshots.py), [PostgreSQL snapshots](../tests/test_usability_postgres_snapshots.py). |
| `debug`, `init`, `run-operation` | Real connection checks, buildable DuckDB scaffolding, typed operation arguments, native query/statement execution and durable operation results. Returning SQL text alone does not execute it. | [Commands](../tests/test_usability_commands.py), [adapter context](../src/project/adapter_context.zig). |
| `retry`, `clone` | Restore prior command arguments and exact unsuccessful resource IDs; opt-in compile/docs error artifacts can be consumed by Core retry. Clone creates state-defined DuckDB/PostgreSQL view copies, respects existing relations/full-refresh and records no-op/error/success outcomes. | [Commands](../tests/test_usability_commands.py), [compile retry](../tests/test_usability_compile_artifacts.py), [PostgreSQL clone](../tests/test_usability_postgres_clone.py). |
| `deps`, `clean` | Local/Git/registry/tarball dependencies, transitive versions, lock files, offline reinstall and safe package installation. Clean removes protected project-relative generated paths without requiring a profile. | [Dependencies](../tests/test_usability_dependencies.py), [clean implementation](../src/project/clean.zig). |
| `docs generate`, `docs serve` | Embedded dbt docs application, catalog introspection, static offline docs and native HTTP serving. Catalog includes supported relation/column/type/comment/owner metadata. | [Artifacts and browser](../tests/test_usability_artifacts.py), [catalog](../tests/test_usability_catalog.py), [PostgreSQL catalog](../tests/test_usability_configuration.py). |
| `source freshness` | Loaded-at field/query checks, native adapter execution, warning/error criteria and Sources v3 outcomes. Metadata-only freshness is unavailable for the initial adapters and produces a visible error. | [Freshness implementation](../src/project/freshness_runner.zig), [parallel commands](../tests/test_usability_parallel_commands.py), [state/freshness](../tests/test_usability_state.py). |

Python model metadata is collected statically from supported literal
`dbt.ref()`, `dbt.source()`, `dbt.config()` and `dbt.config.get()` calls.
Invalid syntax, dynamic metadata arguments and unsupported literal forms fail
visibly. Authored Python is never imported or evaluated. Selecting a Python
model for `run` or `build` fails before warehouse mutations; execution is
outside the user-confirmed initial SQL scope.

## Configuration, Jinja And Selection

| Surface | Native behavior and evidence |
| --- | --- |
| YAML and configuration | Anchors, merges, flow/block values, typed vars/env values, profile discovery and layered project/package/property/inline config. [YAML](../tests/test_usability_yaml.py), [configuration](../tests/test_usability_configuration.py), [config contract](../tests/test_usability_config_contract.py). |
| Naming policies | Database/schema/alias generators resolve parsed identities with root/package scopes, dispatch, macro vars and version aliases. Models, seeds, snapshots, tests and saved-query exports retain resolved identities through compilation, execution and warm-cache invalidation. [Naming](../src/project/naming.zig), [Core identity cases](../tests/test_usability_naming.py), [executed helpers/audits](../tests/test_usability_test_helpers.py). |
| Typed Jinja | Scoped control/capture/call blocks, expressions, integer/float/tuple/container identity, Unicode operations, filters, macro defaults/kwargs/returns and dispatch. [Expressions](../tests/test_usability_expression_types.py), [JSON filters](../tests/test_usability_tojson.py), [conditionals](../tests/test_usability_conditionals.py). |
| Regular expressions | Native `modules.re` functions, pattern/match objects, captures, substitutions, iteration and flags use a Zig compatibility layer over statically linked PCRE2. [Regex implementation](../src/project/regex_context.zig), [positive and negative Core cases](../tests/test_usability_regex.py). |
| String formatting | Native `str.format`/`format_map`, positional/named/subscript/member fields, conversions, nested numeric/Unicode specifications and date/datetime/time formatting. Actual Core failures cover invalid types, specs and sandbox traversal. [Formatting](../tests/test_usability_string_format.py), [temporal protocols](../tests/test_usability_temporal_format.py). |
| Restricted module providers | Core's `datetime`, `pytz` and fourteen `itertools` exports use native typed values and pinned timezone data. Iterators preserve lazy consumption, shared cursors, tee buffering and active Jinja callbacks. [Provider cache](../tests/test_usability_modules_provider.py), [datetime](../tests/test_usability_datetime.py), [strptime](../tests/test_usability_datetime_strptime.py), [pytz](../tests/test_usability_pytz.py), [itertools](../tests/test_usability_itertools.py). These are defined native providers, not an arbitrary Python import facility. |
| dbt context | Typed Relation/Column/timestamps; model/config/graph/flags; database queries, named results and native adapter introspection. Held cursors and fetched Agate tables preserve their separate type, naming and consumption contracts. Pinned bundled Core/adapter SQL macros are embedded with licenses. [Configuration/context](../tests/test_usability_configuration.py), [commands](../tests/test_usability_commands.py), [cursor/bindings](../tests/test_usability_query_bindings.py). |
| Selectors | Names/FQN, paths/packages/tags/resource/config/version/group/access, wildcards, graph expansion, recursive named YAML selectors and eager/cautious/buildable/empty indirect selection. [State/selector cases](../tests/test_usability_state.py), [versions](../tests/test_usability_configuration.py), [groups](../tests/test_usability_groups.py). |
| State and defer | New/old/modified/unmodified and tested body/config/relation/macro/contract/description comparisons; result statuses, Core `source_status:fresher`, defer/favor-state and separate defer state. [State](../tests/test_usability_state.py). |
| Effective flags | Actual workers/cancellation for threads/fail-fast; adapter-specific full-refresh; empty/sample/event-time input bounds; failure audits; env/CLI precedence, warnings, quiet/print/colors, JSON/file logging and parser/cache/profiling controls. Unsupported command placements/values reject. [CLI options](../tests/test_usability_cli_options.py), [execution](../tests/test_usability_cli_execution.py), [profiling](../tests/test_usability_cli_profiling.py), [parser options](../tests/test_usability_parser_options.py), [worker logs](../tests/test_usability_worker_logs.py). |

Package-heavy compatibility is checked separately from individual macro
features. Each release candidate must pass the unchanged PostgreSQL dbt-utils
ladder: seven Native/Core command pairs, complete schemas,
graph/config/dependencies, compiled SQL, catalog columns and typed rows.

The pinned dbt-utils integration project does not configure DuckDB. Running it
on the pinned DuckDB adapter also fails under Core: its date-spine model emits
an uncast string-plus-interval expression, and its relation-discovery models
query a catalog-qualified information schema that DuckDB rejects. Actual Core
CLI comparisons retain byte-identical date-spine SQL, matching macro dependencies
and the shared database errors. These unchanged upstream failures are recorded
separately from the positive PostgreSQL package ladder and the six positive
DuckDB Jaffle gates. No project SQL or selected resource is changed to manufacture
a successful package run.

## Adapters And Materializations

DuckDB uses its C API and PostgreSQL uses libpq. Both expose held sessions,
nullable typed results, DML responses, introspection, transactions, cancellation
and recovery. [Adapter tests](../tests/test_usability_adapters.py) exercise real
databases, including cancellation and simultaneous DuckDB writers.

`adapter.add_query` uses actual typed bindings and held cursors. Its original
driver values retain exact numerics, embedded NUL/binary data, temporal/session
timezone values, composites and description metadata. `run_query` and fetched
statements separately perform Agate's column inference and duplicate-name
handling. Positive and negative cases cover recursive/named bindings, cursor
aliases, PostgreSQL memoryview methods/release, DuckDB type descriptors and
UUIDs. Returned PostgreSQL numeric/temporal ranges retain stock scalar/array
type inference and the upstream nonfinite numeric-range adaptation error.
See the [cursor/binding](../tests/test_usability_query_bindings.py),
[Decimal](../tests/test_usability_cursor_decimal.py),
[UUID](../tests/test_usability_cursor_uuid.py) and
[range](../tests/test_usability_range_bindings.py) comparisons.

| Materialization | Current execution evidence |
| --- | --- |
| Table/view | First/repeated runs, relation-kind switches and rollback on both adapters. PostgreSQL also supports unlogged tables, indexes and materialized-view policies. [Materializations](../tests/test_usability_materializations.py). |
| Contracts/constraints | Enforced table/view/incremental contracts, declared column order, schema/type validation and supported primary-key, unique, not-null, check/custom and PostgreSQL foreign-key constraints. Invalid schema/data preserves the prior relation. Adapter capability warnings remain observable. [Contracts](../tests/test_usability_contracts.py). |
| Authored materializations | Adapter/package selection and builtin override policy, native SQL and authored hook execution, relation-return validation, transaction cleanup and authored `main` response metadata. [Custom materializations](../src/project/custom_materialization.zig), [both-adapter Core cases](../tests/test_usability_custom_materializations.py). |
| Incremental | Adapter-specific append/default/delete+insert/merge paths, composite/null keys, predicates, merge column controls, schema policies and full-refresh. [DuckDB](../tests/test_usability_incremental.py), [PostgreSQL](../tests/test_usability_postgres_incremental.py). |
| Microbatch | Calendar batches/lookback, first/repeated/full-refresh runs, event-time/sample bounds, typed batch context, partial failures, atomic batch rollback and failed-batch retry. Authored materializations and first/last-batch hooks follow Core lifecycle boundaries; legacy unbatched custom strategies retain their main response. [Microbatch](../tests/test_usability_microbatch.py), [lifecycle](../tests/test_usability_microbatch_lifecycle.py). |
| CSV seeds | Actual DuckDB COPY and PostgreSQL client bindings through the bundled lifecycle macros; typed/null/quoted data, batch overrides, first/repeated/full-refresh behavior and load failure rollback. The unchanged wide PostgreSQL case retains all 10,000 rows, seven columns, 70,000 placeholders and actual main-file/warehouse assertions. [Seeds](../tests/test_usability_seed_bindings.py), [retained aliases](../tests/test_usability_seed_alias_scaling.py). |
| Snapshots/clone | Native lifecycles and state relation identities on both adapters, with focused repeated-run and failure fixtures linked above. |
| DuckDB external/table function | Local CSV/JSON/Parquet output, reader views, partitioned publication and parameterized table macros. Cloud publication and plugin registration are outside the current boundary. [File materializations](../tests/test_usability_duckdb_file_materializations.py). |
| Resource/project hooks | Held-session pre/post resource hooks and on-run-start/on-run-end operation discovery/context/results. Transactional hook failures preserve prior relations. [Resource hooks](../tests/test_usability_resource_hooks.py), [global hooks](../tests/test_usability_global_hooks.py). |
| Grants/persist-docs | Native adapter-dispatched privileges/comments, repeat behavior, PostgreSQL role revocation and rollback on invalid roles/comments. DuckDB follows its upstream grants warning capability. [Grants and docs](../tests/test_usability_grants_docs.py). |

Native snapshot run files record the optimized SQL actually executed, so their
statement text can differ from dbt Core's. The snapshot fixtures compare rows,
types, lifecycle, paths and artifact schemas.

Native DuckDB profiles apply configuration/settings, attachments, extension
installation/loading and secrets, plus connection lifetime, transaction and
typed retry policies. Private credentials stay outside public target/cache
artifacts. [Profile fixtures](../tests/test_usability_duckdb_profiles.py) exercise
actual settings, attachments, local secrets, writer-lock retries and visible
failures. Successful live remote extension/credential-provider access remains
separate from local fixture evidence. Python-dependent plugins, filesystems,
module paths and remote drivers fail visibly. Remote DuckLake/MotherDuck and
other cloud adapters are not certified targets.

Executed data-test helpers/publication, inherited test metadata, invocation-wide
`warn_once`, stock main responses and microbatch custom-materialization/hooks
have focused Core certificates. Runtime path/null publication,
builtin-override deprecation, class protocols and literal/receiver identity
also have focused evidence. Native providers cover their declared APIs; general Python
standard-library execution remains outside the product contract.

DuckDB requires a native library; PostgreSQL requires libpq and a reachable
database. Library overrides are `DXT_DUCKDB_LIBRARY` and
`DXT_POSTGRES_LIBRARY`. `DXT_DUCKDB_BACKEND=native` requires the native driver.
The retained `adapter.queryJson` API can execute autocommit queries through the
DuckDB CLI. Database-backed commands use held native sessions and reject forced
`DXT_DUCKDB_BACKEND=cli`. [Driver conformance](../tests/test_usability_adapters.py)
separately verifies CLI SELECT, NULL and empty-result behavior.
Package transports can require `git`, `curl` and `tar`.

## Artifacts, Caches And Proposed Feature Tracks

| Surface | Implementation and evidence |
| --- | --- |
| Complete dbt schemas | Manifest v12, Run Results v6, Catalog v1 and Sources v3 use the full pinned upstream schema classes. Semantic resources also validate against the semantic-interface contract. [Validator](../scripts/validate_dbt_artifacts.py), [artifacts](../tests/test_usability_artifacts.py), [semantic tests](../tests/test_usability_semantics.py). |
| Results and metadata | Native invocation IDs/timestamps, timings/thread IDs/adapter responses; execution outcomes and opt-in durable compile/docs error results. [Compile artifacts](../tests/test_usability_compile_artifacts.py), [diagnostics](../tests/test_usability_compile_diagnostics.py). |
| Test metadata/publication | Inherited meta/docs/group/column fields, source file keys and parse provenance; actual helper execution, compiled SQL/dependencies and retained audit kind switches. Configured compiled paths, dataclass null omission and actual write/build-path publication before later errors have both-adapter Core evidence. [Provenance](../tests/test_usability_test_provenance.py), [helpers](../tests/test_usability_test_helpers.py). |
| Caches | Content-safe whole-graph and unchanged literal-file parse reuse, invocation relation caches and typed SQL-analysis invalidation. `dxt_parse_cache.json` is a native versioned cache, not a claim of Core MessagePack interchange. [Parse cache](../tests/test_usability_parse_cache.py), [relation cache](../tests/test_usability_relation_cache.py), [SQL analysis](../tests/test_usability_sql_analysis.py). |
| Semantic/MetricFlow-style planning | Models/entities/measures/dimensions, simple/derived/ratio/cumulative/conversion metrics, saved queries, join/grain checks, time spines, non-additive dimensions, offsets/windows and locked transactional exports. [Metric planner](../src/project/metric_plan.zig), [semantic/query evidence](../tests/test_usability_semantics.py), [export locks](../tests/test_usability_metric_export_locks.py). |
| Typed SQL analysis | PostgreSQL grammar and DuckDB AST, logical IR, bound columns/types, lineage, source locations, readonly analysis and cache invalidation. [SQL analysis](../src/project/sql_analysis.zig), [evidence](../tests/test_usability_sql_analysis.py). |
| Cross-database execution | Named secret-free plans; same-engine pushdown; source reduction, broadcast/staged/embedded joins; exact typed movement, cost confidence, trust/sensitivity/budget guards, retained caches/snapshots, watermarks, task limits, adaptive retries, locks and recovery. [Cross-database modules](../src/project/cross_database.zig), [evidence](../tests/test_usability_cross_database.py). |
| Versioned environments | Immutable model versions, physical reuse, isolated views, direct/indirect changes, half-open UTC intervals/backfills, audits, promotion and rollback. These are dxt state contracts. [Workflow](../src/project/workflow.zig), [evidence](../tests/test_usability_workflow.py). |

## Explicit Differences

- Native helper semantics target CPython **3.12**, independent of the Python
  version running developer tests. Core on 3.11 differs for existing-iterator
  `tee` identity and compensated floating-point `sum`: native behavior follows
  3.12. [Iterator version case](../tests/test_usability_itertools.py) and
  [aggregate precision cases](../tests/test_usability_aggregate_precision.py) record the
  version-specific results and consumption behavior explicitly.
  Zero-dimensional memoryviews also follow 3.12: length and boolean evaluation
  raise an error, whereas 3.11 treats their length as one. The complete cursor
  oracle uses the canonical runtime; the 3.11 job runs developer/CLI checks.
- `source_status:pass/warn/error` are dxt extensions. Core parity uses its
  `source_status:fresher` comparison.
- Ordinary compile/docs compilation failures return exit code 2 and preserve
  earlier results and catalog artifacts, as Core does. A completed
  `compile --fail-fast` execution failure instead returns exit code 1 and
  publishes its invocation results, matching the observed Core behavior.
  Preflight failures still return exit code 2 and preserve earlier artifacts,
  including with fail-fast enabled. Set
  `DXT_DURABLE_COMPILE_ERRORS=true` to publish durable compilation-error
  results for failed resources. This native extension retains exit code 2;
  preflight failures still preserve earlier artifacts. Its complete artifact
  schemas and retry interoperability are tested separately, including actual
  Core retry of unchanged native results. The native option is absent from
  recorded Core command arguments.
- Published diagnostics and console/file log messages mask declared
  `DBT_ENV_SECRET_*` values; durable error messages follow the same rule.
  Native captured diagnostics remain bounded, and capture does not split a
  complete declared secret at the truncation boundary. Authored SQL/config,
  raw source artifacts, primary SQL/data output and successful custom result
  metadata retain their values, as in the observed Core controls.
- Docs results omit default-false `static` and `empty_catalog` argument keys.
  Core 1.10.5 records them but cannot retry its own default docs artifact:
  it generates unsupported `--no-static` and `--no-empty-catalog` options.
  Omitting those keys preserves their false defaults and lets Core replay
  native results. Enabled flags remain present, and the dual `compile` flag
  retains both boolean values. The original static and added default docs
  failure fixtures pass the unchanged native artifact to actual Core retry.
- Stock DuckDB microbatch is a dxt extension; the pinned dbt-duckdb fixture
  uses a custom strategy for the comparable Core batch orchestration.
- Bounded own-time metric offsets cover a documented MetricFlow assertion
  divergence. Upstream-failing cases are not counted as positive parity.
- Native large integer metadata can exceed Core's MessagePack cache range;
  upstream overflow cases are explicit differences.
- Quoted DuckDB contract column names containing whitespace work natively;
  the pinned adapter's unquoted INSERT helper independently fails that case.
  The [contract regression](../tests/test_usability_contracts.py) records both
  outcomes rather than counting the upstream failure as positive parity.
- Clone/external failure fixtures retain a stronger native rollback guarantee
  in observed upstream transaction/file-publication edge cases. Successful
  rows, ordering and no-op behavior have separate Core comparisons.
- In the [sampled-once SQL unit fixture](../tests/test_usability_unit_fixtures.py),
  native compilation exposes the sampled mock input to authored `run_query`.
  Pinned Core 1.10.5 instead errors because `__dbt__cte__base` is unavailable
  to that lookup. This input-introspection extension is separate from positive
  Core unit-fixture comparisons; it does not establish a general limitation
  on Core's unit-test callbacks.
- Semantic commands, movement plans and versioned environments use dxt
  artifacts. They do not claim to implement a dbt Fusion or SQLMesh runtime.

## Validation Status

Candidate-specific test counts, remaining blockers and final CI outcomes are
recorded in [PR #221](https://github.com/sabino/dxt/pull/221) and
[issue #220](https://github.com/sabino/dxt/issues/220). Historical focused
passes cannot certify a subsequent product change.

Focused feature gates exercise real native adapters and pinned Core/MetricFlow
outputs, with negative cases and complete applicable schemas. Candidate
acceptance also requires all six unchanged public Jaffle CLI steps, the
unchanged PostgreSQL dbt-utils ladder, full native/pytest suites, both-adapter
archive installation and correctness-aware cold/warm performance checks.

Actual Linux x86_64 and ARM full compatibility/install jobs are configured in
[CI](../.github/workflows/ci.yml) and [release](../.github/workflows/release.yml).
Acceptance requires complete canonical CPython 3.12 reports and extracted
archive checks on both architectures, tied to the declared candidate source
and binaries. Cross-compilation is not a substitute for running the full suite
on that architecture. Skipped or xfail cases do not count as parity evidence.
Publication requires accepted reports and applicable green CI for the published
head; historical checkpoints cannot replace those results.

See [the roadmap](DBT_REPLACEMENT_ROADMAP.md) for candidate acceptance gates and
[release process](RELEASES.md) for archive/platform requirements.

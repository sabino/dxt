# dbt Core Compatibility Planning Note

## Purpose

This note defines a concrete compatibility plan for `dxt` against dbt Core project behavior. The recommended strategy is to treat dbt compatibility as a layered target:

1. Parse dbt projects and reproduce graph/artifact semantics.
2. Compile dbt SQL/Jinja into adapter-aware SQL.
3. Execute a useful subset through one local adapter.
4. Expand toward full dbt Core command, selector, package, adapter, and artifact compatibility.

The target should be dbt Core's stable behavior rather than dbt Cloud-only or Fusion-only features. As of the referenced docs, dbt Core v1.8 through v1.11 use manifest schema v12, while older Core versions map to earlier manifest schemas. `dxt` should make artifact schema version support explicit instead of assuming one schema forever.

## Compatibility Definition

`dxt` is compatible with a dbt Core surface when it can ingest the same project files, accept the same relevant command flags, resolve the same graph dependencies, and emit artifacts that conform to the documented dbt JSON schemas for the target dbt version.

Compatibility levels:

- **Read compatibility**: parse `dbt_project.yml`, package metadata, resource files, SQL/Jinja, and YAML properties without executing warehouse operations.
- **Compile compatibility**: render refs, sources, macros, configs, vars, target/profile context, and adapter dispatch into executable SQL.
- **Artifact compatibility**: write `manifest.json`, `catalog.json`, `run_results.json`, and related files with stable dbt-compatible schemas.
- **Execution compatibility**: run materializations, tests, seeds, snapshots, and docs generation against supported adapters.
- **Workflow compatibility**: support selectors, state comparison, deferral, packages, and common CI behaviors.

## MVP Scope

The MVP should be narrow but real: it should parse and validate small-to-medium dbt Core projects, compile simple models, run them through DuckDB, and emit enough artifacts for downstream tooling to inspect the graph.

### MVP Commands

Implement these command shapes first:

- `dxt parse`
  - Read project files and build an in-memory graph.
  - Emit `target/manifest.json`.
  - Support `--project-dir`, `--profiles-dir`, `--target`, `--vars`, `--target-path`, `--select`, and `--exclude` where relevant.
- `dxt ls`
  - List selected resources from the parsed graph.
  - Support `--resource-type`, `--select`, `--exclude`, and JSON output.
- `dxt compile`
  - Compile SQL models and tests without executing them.
  - Emit compiled SQL paths and update `manifest.json` fields for compiled nodes.
- `dxt build`
  - For MVP, run seeds, models, and data tests in DAG order for a single local adapter.
  - Emit `target/run_results.json`.
- `dxt docs generate`
  - For MVP, generate `manifest.json` plus a minimal `catalog.json` from adapter relation introspection.

Defer `dbt init`, `dbt debug`, `dbt clean`, `dbt retry`, `dbt clone`, `dbt source freshness`, `dbt run-operation`, and `dbt docs serve` until after the graph/compiler core is stable.

### MVP Project Structure

Support conventional dbt project layout:

- `dbt_project.yml`
- `models/**/*.sql`
- `models/**/*.yml` or `models/**/*.yaml`
- `macros/**/*.sql`
- `seeds/**/*.csv`
- `snapshots/**/*.sql` parsed but not executed initially
- `analyses/**/*.sql` parsed and compiled
- `tests/**/*.sql` for singular data tests
- `packages.yml` parsed but package installation can be skipped in the earliest MVP
- `selectors.yml` parsed for named selectors after inline selectors work

`dxt` should honor project config paths such as `model-paths`, `seed-paths`, `macro-paths`, `snapshot-paths`, `analysis-paths`, `test-paths`, `docs-paths`, `target-path`, `clean-targets`, `quoting`, `vars`, and per-resource config blocks under `models`, `seeds`, `snapshots`, and `tests`.

### MVP Parsing

Parsing must produce dbt-like node identity and graph relationships:

- `unique_id` format: `resource_type.package_name.resource_name`, with test IDs matching dbt's generated naming closely enough for selectors and artifacts.
- File path fields: `path`, `original_file_path`, and package-relative metadata without host-specific absolute paths in portable outputs where dbt schema permits relative data.
- Resource types: model, seed, source, test, macro, snapshot, analysis, exposure, metric/semantic-model placeholders if encountered.
- Dependency extraction:
  - `ref("name")`
  - `ref("package", "name")`
  - `source("source_name", "table_name")`
  - `config(...)`
  - `doc("block_name")`
  - macro calls that affect parse-time config or dependencies
- YAML properties:
  - model/source/seed/snapshot columns
  - descriptions
  - tags
  - meta
  - groups/access where present
  - generic tests on models, columns, sources, seeds, and snapshots
  - exposures and owner metadata

The first parser can use dbt Core itself as an oracle in tests, but product code should avoid depending on dbt internals unless `dxt` is explicitly a wrapper. If `dxt` is intended to be a dbt-compatible engine, implement a separate compatibility layer and compare outputs against dbt-generated artifacts.

### MVP Artifacts

Emit these files:

- `manifest.json`
  - Required first because it is the central representation for docs, state selection, lineage, dependencies, resource properties, macros, docs blocks, selectors, disabled resources, parent maps, and child maps.
  - Use the correct schema URL for the target dbt Core version.
- `run_results.json`
  - Required for build/test outcomes, node timing, statuses, failures, adapter responses, and result selectors.
- `catalog.json`
  - Required for docs metadata after execution or introspection.

Do not invent artifact field names when a dbt schema field exists. Extra `dxt` metadata should live in a clearly namespaced object only if the dbt schema permits it; otherwise write a separate `dxt_metadata.json`.

### MVP Materializations

Support only these materializations first:

- `view`
- `table`
- `incremental` in append/delete-insert form only after table/view are stable
- `ephemeral` compile-time CTE injection
- `seed` loading for CSV files
- generic data test materialization

Skip custom materializations in the first MVP, but parse their config and fail with a clear unsupported-feature diagnostic.

### MVP refs, sources, macros

Support:

- `ref`
- `source`
- `config`
- `var`
- `env_var`
- `target`
- `this`
- `adapter.dispatch` enough for built-in macros and one adapter
- `is_incremental`
- built-in generic tests: `unique`, `not_null`, `accepted_values`, `relationships`

The macro engine is the highest-risk MVP component. It should preserve dbt's two-phase parse/execute distinction: macros often need enough context at parse time to declare dependencies and configs, then richer context at compile/run time.

### MVP Adapter

Use DuckDB as the MVP execution adapter because it is local, fast, and works well with public fixture projects. The adapter layer should still be shaped around dbt concepts:

- relation representation: database, schema, identifier, quote policy, include policy
- connection management
- SQL execution and transactions
- relation existence and column introspection
- create/drop/rename relation primitives
- schema creation
- adapter response normalization for `run_results.json`
- catalog introspection for docs generation

Avoid hard-coding DuckDB behavior into the compiler. Adapter-specific SQL must go behind relation, quoting, dispatch, and materialization boundaries.

## Full Compatibility Scope

Full compatibility means users can point `dxt` at a dbt Core project and expect routine local/CI workflows to behave the same for supported adapters.

### CLI Commands

Support the dbt Core command family by priority:

- Parse/inspect:
  - `parse`
  - `ls` / `list`
  - `compile`
  - `show`
- Build/execute:
  - `run`
  - `test`
  - `seed`
  - `snapshot`
  - `build`
  - `source freshness`
  - `run-operation`
- Docs/artifacts:
  - `docs generate`
  - `docs serve`
- Dependency/project operations:
  - `deps`
  - `clean`
  - `debug`
  - `init`
- Recovery/advanced:
  - `retry`
  - `clone`

Global flags and behavior to model:

- `--project-dir`
- `--profiles-dir`
- `--profile`
- `--target`
- `--target-path`
- `--vars`
- `--threads`
- `--select`
- `--exclude`
- `--selector`
- `--state`
- `--defer`
- `--defer-state`
- `--favor-state`
- `--full-refresh`
- `--fail-fast`
- `--warn-error`
- `--warn-error-options`
- `--empty` where dbt supports empty builds
- `--log-format` and machine-readable events eventually

### Project Structure

Full support should include:

- multiple packages in `dbt_packages`
- package namespacing and cross-package `ref`
- `dbt_project.yml` dispatch config
- model contracts
- versions and latest-version refs
- access modifiers
- groups
- semantic layer resources as parse/artifact entities even if `dxt` does not execute metric queries
- docs blocks
- analyses
- hooks: `on-run-start`, `on-run-end`, pre-hooks, post-hooks
- operations
- disabled resources
- nested configs and config precedence
- YAML anchors and merged mappings
- profile and target rendering with `env_var`

### Parsing and Compilation

Full parsing/compilation needs:

- static parser fast path for simple SQL where possible
- fallback Jinja rendering parser for dynamic cases
- partial parsing cache equivalent or compatible enough to avoid slow large-project workflows
- stable diagnostics with dbt-like error classes and locations
- correct parse-time vs execute-time Jinja context
- macro namespace resolution across root project, installed packages, and adapter packages
- dispatch search order
- dependency graph cycle detection
- disabled-node handling
- unrendered config preservation where dbt artifacts expose it
- compiled SQL and injected CTE handling for ephemeral models
- Python model parsing and execution only in a later phase

### Artifacts

Full artifact support:

- `manifest.json`
  - nodes, sources, macros, docs, exposures, metrics, groups, selectors, disabled, parent/child maps
  - schema-version mapping by dbt Core version
  - selected/compiled/executed node fields matching dbt behavior
- `run_results.json`
  - statuses, timing, adapter responses, failures, compiled flag/code, relation name, args, elapsed time
  - produced by build/run/test/seed/snapshot/compile/docs generate/show/retry/run-operation where applicable
- `catalog.json`
  - nodes/sources table metadata, columns, stats, unique IDs, and errors
- `sources.json`
  - freshness results for sources
- `semantic_manifest.json`
  - parse output for semantic resources, if semantic layer compatibility becomes a goal
- `partial_parse.msgpack`
  - optional for performance; do not promise compatibility until dbt's cache invalidation behavior is understood

Artifact validation must use dbt's published JSON schemas, not hand-maintained approximations.

### Materializations

Full materialization support:

- built-ins:
  - view
  - table
  - incremental
  - ephemeral
  - materialized_view where adapter supports it
  - snapshot
  - seed
  - data test
  - unit test
- incremental strategies:
  - append
  - merge
  - delete+insert
  - insert_overwrite where adapter supports it
  - microbatch if targeting adapters/projects that use it
- custom materializations:
  - materialization blocks in project/package macros
  - adapter-specific implementations
  - relation cache updates
  - transaction behavior
  - pre/post-hook ordering
  - grants, persist docs, indexes, cluster/partition configs where adapter supports them

### refs, sources, macros

Full support:

- `ref` with package and version arguments
- `source`
- `config`
- `var`
- `env_var`
- `doc`
- `log`
- `exceptions`
- `return`
- `run_query`
- `statement` blocks
- `adapter` object APIs commonly used by packages
- `graph`
- `model`
- `flags`
- `target`
- `this`
- `selected_resources`
- `invocation_id`
- macro dispatch and package override rules
- built-in macros from dbt/adapters for each supported adapter

Any macro API that can execute SQL (`run_query`, `statement`) should be explicitly blocked during parse and enabled only during compile/run phases with correct `execute` semantics.

### Adapters

The adapter API is a compatibility boundary, not an implementation detail. Full scope should include:

- Base adapter contract:
  - connection lifecycle
  - credentials/profile parsing
  - relation class
  - column class
  - quoting
  - relation cache
  - execute/fetch
  - schema/relation introspection
  - create/drop/truncate/rename
  - transactions
  - adapter response
- Adapter packages:
  - DuckDB for local fixture execution
  - Postgres as first server adapter
  - BigQuery/Snowflake/Redshift later because they expose warehouse-specific configs and auth complexity
- Adapter tests:
  - use dbt adapter integration test concepts as inspiration
  - maintain a `dxt` adapter contract suite before adding many adapters

### Tests

Support:

- generic data tests on models, columns, sources, seeds, and snapshots
- singular SQL tests
- unit tests for SQL models
- test selection by resource, parent model, source, package, tag, path, and test type
- severity, `warn_if`, `error_if`, `store_failures`, `limit`, and `where`
- relationships tests across refs/sources
- test result artifact fields and statuses

### Docs

Support:

- `docs generate`
- manifest/catalog integration
- docs blocks
- descriptions from YAML and markdown
- exposures in docs graph
- source freshness artifacts
- column types and stats from adapter catalog
- `docs serve` as a low-priority static file server wrapper

### Seeds

Support:

- CSV parsing compatible with dbt expectations
- configurable delimiter, quote handling, column types, and schema
- seed hashing for state comparison, including dbt's behavior differences for small and large seed files
- full-refresh semantics

### Snapshots

Support:

- timestamp strategy
- check strategy
- hard deletes configuration
- snapshot meta columns
- snapshot target schema/database
- `dbt snapshot` command and `dbt build` integration

Snapshots require careful adapter-specific SQL and should come after table/view/incremental materializations are well-tested.

### Exposures

Support parsing, manifest output, docs output, and selectors for exposures:

- exposure name, type, URL, maturity, owner, description, tags, meta
- dependencies via `ref`, `source`, and metrics where present
- `+exposure:name` downstream/upstream selection behavior

### Packages

Support:

- `packages.yml`
- `dependencies.yml` if targeting newer project conventions
- dbt Hub packages
- Git packages
- local packages
- package lock files
- version constraints
- namespace isolation
- cross-package refs/macros/docs
- dispatch configuration

For MVP, package installation can be delegated to `dbt deps` or documented as a precondition. Full compatibility needs native or delegated package resolution with reproducible locks.

### Selectors, State, and Defer

Selectors are essential for CI compatibility and must be implemented as graph operations, not string filters.

Support selector syntax:

- direct resource names
- `+` graph expansion
- `@` graph operator
- comma intersection
- multiple arguments as union
- `--exclude`
- methods:
  - `tag:`
  - `path:`
  - `file:`
  - `package:`
  - `config:`
  - `resource_type:`
  - `source:`
  - `exposure:`
  - `state:`
  - `result:`
  - `source_status:`
  - `test_type:`
- YAML selectors in `selectors.yml`

State/defer support:

- compare current manifest to `--state` manifest
- implement `state:new`, `state:modified`, and subselectors for body/config/relation/contract where possible
- support `result:` selectors from previous `run_results.json`
- require `--state` with `--defer`
- resolve unselected upstream refs to deferred relations
- support `--defer-state` separately from comparison state
- support `--favor-state`

State comparison is artifact-sensitive. It should be introduced only after `manifest.json` fidelity is high.

## Validation Fixtures

Create fixture tiers so compatibility can progress without needing every dbt feature at once.

### Tier 0: Minimal Synthetic Projects

Small fixtures committed in `dxt`:

- one model with no refs
- two models with `ref`
- one source and one model with `source`
- YAML model properties with descriptions, tags, columns, tests, and meta
- one macro used by a model
- one docs block and `doc()` reference
- one exposure depending on a model
- disabled model
- custom path config in `dbt_project.yml`

Validation:

- run `dbt parse` and `dxt parse`
- compare graph node identities, parent/child maps, resource types, configs, and selected manifest fields
- validate `dxt` artifacts against dbt JSON schemas

### Tier 1: Local Execution Fixtures

DuckDB-backed fixtures:

- seeds loaded into tables
- table and view models
- ephemeral model feeding a table model
- generic tests: unique, not_null, accepted_values, relationships
- singular test
- docs generation with catalog introspection
- simple incremental model with full refresh and incremental rerun

Validation:

- compare row counts and selected query results
- compare `run_results.json` statuses and relation names
- compare generated catalog columns and types where adapter differences allow

### Tier 2: Packages and Macro Fixtures

Fixtures that stress macro/package behavior:

- local package with cross-package `ref`
- local package overriding a macro
- adapter dispatch macro
- package-provided generic test
- selector YAML using tags and graph expansion

Validation:

- compare macro resolution and compiled SQL
- compare selector output from `dbt ls` and `dxt ls`

### Tier 3: State and Defer Fixtures

Fixture sequence:

- baseline project build
- saved baseline `manifest.json` and `run_results.json`
- modified model body
- modified config only
- modified seed file
- new downstream model
- CI schema where upstream relation is absent locally but present in state

Validation:

- compare `state:new`, `state:modified`, `result:error`, and deferred relation resolution
- verify that `--defer`, `--defer-state`, and `--favor-state` differ only where dbt differs

### Tier 4: Multi-Adapter Fixtures

After DuckDB:

- Postgres container fixture
- one cloud adapter fixture with mocked credentials for parse/compile only
- optional live warehouse smoke tests gated by environment variables

Validation:

- parse/compile should be deterministic without live credentials unless the command inherently requires a connection
- execution tests should be isolated and opt-in

## Public Projects to Test

Use public projects as black-box compatibility targets. Pin commits in fixture metadata so test failures are attributable.

- `dbt-labs/jaffle_shop_duckdb`
  - Best first public fixture.
  - Local DuckDB execution.
  - Covers seeds, models, tests, docs, and fast `dbt build` / `dbt docs generate`.
- `dbt-labs/jaffle-shop`
  - Canonical Jaffle Shop sample.
  - Useful for checking common model/test/docs patterns, but its current README points local users toward the DuckDB version for easiest local execution.
- `dbt-labs/jaffle-shop-classic`
  - Useful as an older/classic sample to catch compatibility drift in project conventions.
- `dbt-labs/dbt-learn-demo`
  - Better for realistic beginner/best-practice project layout than minimal Jaffle fixtures.
- `gmyrianthous/dbt-dummy`
  - Postgres/Docker-oriented sample with seeds, models, snapshots, and tests.
- GitLab's public/internal analytics dbt project, if accessible at test time
  - Good large-project parse/selector/artifact stress test.
  - Treat execution as out of scope unless credentials and warehouse dependencies are explicitly available.
- A project from `InfuseAI/awesome-public-dbt-projects`
  - Use only pinned, actively maintained examples.
  - Prefer parse/compile first because many public projects require private warehouses or credentials.

## Risk List

- **Jinja semantic drift**: dbt's context is not plain Jinja. Parse-time and execute-time behavior differ, and packages rely on subtle context APIs.
- **Macro dispatch complexity**: adapter/package dispatch controls materializations, tests, SQL generation, and package overrides.
- **Artifact schema fidelity**: many downstream tools consume `manifest.json`; small field differences can break docs, lineage, or state selection.
- **State/defer correctness**: state comparison depends on stable manifest fields, checksums, config rendering, and relation naming.
- **Adapter leakage**: hard-coding DuckDB/Postgres SQL into the compiler would block future adapters.
- **Incremental models**: strategies and merge semantics vary heavily by adapter.
- **Snapshots**: SCD2 logic is adapter-specific and sensitive to timestamp/check semantics.
- **Packages and dependency resolution**: dbt Hub, Git, local packages, locks, and namespace rules are enough complexity to derail the MVP if attempted too early.
- **Profiles and credentials**: `profiles.yml` rendering, env vars, target selection, and adapter plugin config need careful error messages and secret handling.
- **Partial parsing**: performance matters on real projects, but matching dbt's cache invalidation too early is risky.
- **Version drift**: dbt Core, adapters, artifact schemas, and docs are evolving. Pin a target dbt Core version per compatibility release.
- **Cloud/Fusion ambiguity**: current docs include Fusion-era features. Keep `dxt` scope explicit: dbt Core-compatible first, Fusion-only features later or unsupported.
- **Test naming and selection**: generated test IDs and selector behavior are easy to get subtly wrong.
- **Catalog differences**: relation/column introspection differs by adapter and warehouse permissions.

## Recommended Sequencing

### Phase 1: Artifact-first Parser

Goal: `dxt parse` and `dxt ls` work on synthetic fixtures and Jaffle Shop.

Deliverables:

- project loader
- YAML config/property parser
- SQL/Jinja dependency extractor
- graph builder
- selector engine for simple names, tags, paths, resource types, `+`, and `--exclude`
- `manifest.json` writer validated against dbt schema
- oracle tests comparing against `dbt parse` and `dbt ls`

Exit criteria:

- Tier 0 fixtures pass.
- `dbt-labs/jaffle_shop_duckdb` parses.
- Manifest top-level keys and key node fields validate.

### Phase 2: Compiler and Macro Core

Goal: `dxt compile` produces comparable compiled SQL for common projects.

Deliverables:

- Jinja environment
- dbt context functions for refs, sources, vars, env vars, configs, docs, target, this
- macro registry and namespace resolution
- basic adapter dispatch
- ephemeral model CTE injection
- compiled SQL output and manifest compiled fields

Exit criteria:

- Tier 0 and Tier 1 compile-only cases pass.
- Compiled SQL matches dbt for stable whitespace-insensitive comparisons on supported fixtures.

### Phase 3: DuckDB Execution MVP

Goal: `dxt build` can run a small project locally.

Deliverables:

- DuckDB adapter
- seed loading
- table/view materializations
- generic data tests
- DAG scheduler
- `run_results.json`
- minimal catalog introspection and `docs generate`

Exit criteria:

- `dbt-labs/jaffle_shop_duckdb` runs through `build` and `docs generate`.
- Row counts, test statuses, and artifacts match expected fixture baselines.

### Phase 4: Packages and Custom Macros

Goal: common dbt packages and local package patterns compile.

Deliverables:

- package loader
- local and Git/dbt Hub dependency resolution or a documented delegation path
- package lock handling
- dispatch config
- package-provided tests and macros
- macro override tests

Exit criteria:

- Tier 2 fixtures pass.
- At least one public package-heavy project parses and compiles.

### Phase 5: Selectors, State, and Defer

Goal: CI-oriented workflows behave like dbt.

Deliverables:

- complete selector methods
- YAML selectors
- state manifest comparison
- result selectors from `run_results.json`
- deferral relation resolution
- `--defer-state` and `--favor-state`

Exit criteria:

- Tier 3 fixtures pass against dbt oracle output.
- CI-style command examples produce matching selected resource sets.

### Phase 6: More Resource Types and Adapters

Goal: expand beyond the MVP without destabilizing parser/artifact compatibility.

Deliverables:

- snapshots
- incremental strategy matrix
- source freshness and `sources.json`
- unit tests
- docs serve
- Postgres adapter
- parse/compile support for BigQuery/Snowflake/Redshift profiles and adapter macros

Exit criteria:

- Tier 4 fixtures pass.
- Adapter contract suite exists before adding more execution adapters.

## Validation Harness

Build a repeatable compatibility harness:

- Create a matrix of `dbt-core` versions and adapter versions.
- For each fixture, run dbt Core and `dxt` commands into separate target directories.
- Normalize non-deterministic fields:
  - generated timestamps
  - invocation IDs
  - elapsed times
  - absolute paths where dbt emits them
  - adapter response fields known to differ
- Validate artifacts against published schemas.
- Compare semantic slices rather than whole JSON blobs at first:
  - resource count by type
  - unique IDs
  - parent/child maps
  - selected resource sets
  - compiled SQL normalized by whitespace/comments
  - run statuses
  - relation names
  - column metadata where available
- Store expected outputs as pinned fixtures, not as mutable snapshots from a developer machine.

Recommended command oracle examples:

```sh
dbt parse --target-path target-dbt
dxt parse --target-path target-dxt

dbt ls --select tag:nightly+ --output json
dxt ls --select tag:nightly+ --output json

dbt compile --target-path target-dbt
dxt compile --target-path target-dxt

dbt build --target-path target-dbt
dxt build --target-path target-dxt

dbt docs generate --target-path target-dbt
dxt docs generate --target-path target-dxt
```

## Initial Non-Goals

- Full dbt Cloud behavior.
- Fusion-only behavior.
- Interactive IDE features.
- Semantic Layer query serving.
- Python model execution.
- All cloud adapters in MVP.
- Full partial-parse cache compatibility in MVP.
- Exact byte-for-byte artifact equality before semantic compatibility is proven.

## Sources

- dbt command reference: https://docs.getdbt.com/reference/dbt-commands
- `dbt build`: https://docs.getdbt.com/reference/commands/build
- `dbt run`: https://docs.getdbt.com/reference/commands/run
- `dbt test`: https://docs.getdbt.com/reference/commands/test
- `dbt seed`: https://docs.getdbt.com/reference/commands/seed
- `dbt snapshot`: https://docs.getdbt.com/reference/commands/snapshot
- `dbt compile`: https://docs.getdbt.com/reference/commands/compile
- `dbt parse`: https://docs.getdbt.com/reference/commands/parse
- dbt projects: https://docs.getdbt.com/docs/build/projects
- materializations: https://docs.getdbt.com/docs/build/materializations
- sources: https://docs.getdbt.com/docs/build/sources
- Jinja and macros: https://docs.getdbt.com/docs/build/jinja-macros
- data tests: https://docs.getdbt.com/docs/build/data-tests
- documentation: https://docs.getdbt.com/docs/build/documentation
- seeds: https://docs.getdbt.com/docs/build/seeds
- snapshots: https://docs.getdbt.com/docs/build/snapshots
- exposures: https://docs.getdbt.com/docs/build/exposures
- packages: https://docs.getdbt.com/docs/build/packages
- node selection syntax: https://docs.getdbt.com/reference/node-selection/syntax
- selector methods: https://docs.getdbt.com/reference/node-selection/methods
- YAML selectors: https://docs.getdbt.com/reference/node-selection/yaml-selectors
- state selection: https://docs.getdbt.com/reference/node-selection/state-selection
- defer: https://docs.getdbt.com/reference/node-selection/defer
- dbt artifacts overview: https://docs.getdbt.com/reference/artifacts/dbt-artifacts
- manifest artifact: https://docs.getdbt.com/reference/artifacts/manifest-json
- run results artifact: https://docs.getdbt.com/reference/artifacts/run-results-json
- catalog artifact: https://docs.getdbt.com/reference/artifacts/catalog-json
- sources artifact: https://docs.getdbt.com/reference/artifacts/sources-json
- dbt JSON schemas: https://schemas.getdbt.com/
- adapter creation guide: https://docs.getdbt.com/guides/adapter-creation
- connect to adapters: https://docs.getdbt.com/docs/connect-adapters
- Jaffle Shop DuckDB: https://github.com/dbt-labs/jaffle_shop_duckdb
- Jaffle Shop: https://github.com/dbt-labs/jaffle-shop
- Jaffle Shop Classic: https://github.com/dbt-labs/jaffle-shop-classic
- dbt dummy Postgres project: https://github.com/gmyrianthous/dbt-dummy
- public dbt project index: https://github.com/InfuseAI/awesome-public-dbt-projects

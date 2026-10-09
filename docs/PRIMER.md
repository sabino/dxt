# dxt Primer

`dxt` means **Data eXecution & Transformation**. It runs dbt projects through a
native Zig binary, with DuckDB and PostgreSQL as the initial adapter targets.
Compatibility is checked against pinned upstream behavior and complete artifact
schemas. Consult [Compatibility](COMPATIBILITY.md) for supported combinations;
the implementation campaign and final release gates remain tracked in
[PLAN.md](../PLAN.md).

## Start With A Local Project

Install a release binary as described in [Releases](RELEASES.md), or build from
the repository with Zig **0.16.0**:

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/dxt version
```

Make the binary available as `dxt` on PATH. Install DuckDB's native library;
library discovery can find `libduckdb.so`, or `DXT_DUCKDB_LIBRARY` can select the
library you installed. These examples require native execution:

```sh
export DXT_DUCKDB_BACKEND=native
dxt init demo
dxt debug --project-dir demo --profiles-dir demo
dxt build --project-dir demo --profiles-dir demo --threads 2
dxt docs generate --project-dir demo --profiles-dir demo --static
dxt docs serve --project-dir demo --profiles-dir demo --port 8080 --no-browser
```

`init` writes a usable DuckDB profile, a seed, a model and data tests inside the
new directory. `debug` performs a real connection query. `build` executes the
seed/model/test graph; generated artifacts go into `demo/target`. The docs
command writes the documentation application, catalog and an offline
`static_index.html`. Stop the server with Ctrl+C.

An existing project can keep its dbt files and profile layout. Pass
`--project-dir`, `--profiles-dir`, `--profile` and `--target` when needed. For
PostgreSQL, use a dbt `type: postgres` output and install libpq; the native driver
loads `libpq.so.5`, or an explicit `DXT_POSTGRES_LIBRARY`. Credentials can remain
in the profile's `env_var()` expressions. Neither adapter needs an installed
Python/dbt runtime to execute through dxt.

## Command Families

| Commands | Purpose |
| --- | --- |
| `parse`, `ls` / `list`, `compile` | Load resources, select graph nodes and compile SQL/macros. |
| `deps`, `clean` | Install package dependencies and remove configured generated paths. |
| `run`, `seed`, `snapshot`, `test`, `build` | Execute resource lifecycles, data tests and unit tests. |
| `debug`, `init`, `run-operation` | Check connections, scaffold a project and invoke a native macro context. |
| `retry`, `clone` | Resume unsuccessful resources from prior results and clone state-defined relations. |
| `source freshness`, `docs generate`, `docs serve` | Check source age and generate/serve documentation artifacts. |
| `analyze`, `explain` | Produce dialect-aware SQL diagnostics, types, logical operators and lineage. |
| `metric query`, `metric explain`, `metric export` | Plan/execute semantic metrics and saved queries. |
| `cross-database plan/run/recover/cleanup/debug/catalog` | Inspect and execute explicit governed movement across named connections. |
| `plan`, `apply`, `environment`, `intervals`, `audit`, `promote`, `rollback` | Operate dxt versioned environments and processed intervals. |

Use `dxt --help` and command-specific help for accepted options. The semantic,
cross-database and environment commands are dxt extensions with separate plan
and state artifacts. In the current integrated implementation, snapshot
execution and clone view copies use DuckDB; PostgreSQL support for these two
lifecycles is tracked separately in the active plan.

## Selection, Failures And State

Graph selectors, named YAML selectors and indirect test-selection modes control
the executable resource set. For example, in the scaffolded project:

```sh
dxt ls --project-dir demo --profiles-dir demo --select +customers --output json
dxt compile --project-dir demo --profiles-dir demo --select customers
dxt run --project-dir demo --profiles-dir demo --select customers --threads 2
```

Workers wait for selected prerequisites. A failing unit test blocks its target;
failed/error resources block dependent build resources while independent work
continues. Completed rows remain in `run_results.json`, with statuses, timings
and adapter responses. `--fail-fast` also requests cancellation of active work.

After an unsuccessful command, `dxt retry` reads prior results and reconstructs
the original command's arguments, then runs exact failed/skipped IDs. Preserve
the prior target directory if it is also needed for comparison:

```sh
dxt retry --project-dir demo --profiles-dir demo --state demo/target
```

`--state` selectors consume prior manifest/results/freshness artifacts.
`--defer` and `--defer-state` resolve eligible unselected references to prior
relations. `clone` requires a state manifest. Dxt's `plan`/`apply` workflow has
its own immutable model versions, environment views and UTC intervals; it uses
separate namespaced state.

Incremental models support adapter-specific strategies and schema policies.
Microbatch models add calendar intervals, lookback, event-time filtering and
failed-batch retry. Explicit `--event-time-start` and `--event-time-end` are
paired run/build options. `--empty` and `--sample` affect input relation SQL.
The pinned DuckDB adapter's stock microbatch limitation and dxt's extension are
documented in [Compatibility](COMPATIBILITY.md).

## SQL And Semantic Plans

Native analysis uses PostgreSQL's grammar or DuckDB's AST and binds against
project/warehouse columns. It writes `dxt_sql_analysis.json` with diagnostics,
types and lineage, and invalidates cached analysis when dependencies change:

```sh
dxt analyze --project-dir demo --profiles-dir demo --select customers --output json
```

Projects with semantic models and metric definitions can inspect a metric plan
before executing it. For a project defining `revenue` and a `daily_revenue`
saved query:

```sh
dxt metric explain --metrics revenue --group-by metric_time__day
dxt metric query --saved-query daily_revenue
dxt metric export --saved-query daily_revenue
```

The planner checks joins, entity grain, time-spine needs, windows and filters.
Saved exports hold target locks and use transactional replacement. Named
connections in `dxt_connections.yml` let metric and cross-database plans
preserve source/destination identities and enforce explicit movement policy.
Inspect `dxt cross-database --help` for plan hashes, trust controls and bounded
extraction/execution budgets.

## Artifacts And Validation

Default JSON output includes Manifest **v12**, Run Results **v6**, Catalog
**v1**, Sources **v3** and `semantic_manifest.json` for semantic definitions.
Each command writes the artifacts appropriate to its task. Invocation metadata
comes from the native clock. SQL compilation failures can retain durable dxt
compile/docs result artifacts in cases where Core exits before producing
results.

The developer oracle contract pins dbt Core **1.10.5**, dbt-duckdb **1.9.6**,
dbt-postgres **1.9.1**, DuckDB **1.4.2**, MetricFlow **0.208.1** and semantic
interfaces **0.9.0**. Python dependencies in `requirements-dev.txt` and
`requirements-oracle.txt` serve developer checks; they are not runtime
installation requirements.

| Check | Command or gate |
| --- | --- |
| Native build/helpers | `zig build`, `zig build test` |
| Focused native CLI/Core evidence | `pytest -q tests/test_usability_<area>.py` |
| Complete integrated fixtures | `pytest -q` with pinned developer dependencies and native database/browser fixtures |
| Complete artifact schemas | `python scripts/validate_dbt_artifacts.py <artifact.json>` |
| Product/runtime boundary | `python scripts/check_runtime_boundary.py` |
| Public-safe repository | `python scripts/check_public_safety.py` |
| Extracted release installation | `python scripts/check_install.py --archive <archive.tar.gz> --require-postgres` |
| Public projects and performance | CI public-project/package gates and `scripts/check_performance.py` |

PostgreSQL developer fixtures use `scripts/postgres_fixture.py`; installed
native tools can be selected with `DXT_POSTGRES_BIN`. The helper preserves the
test fixture API across x86_64 and ARM. CI installs architecture-specific native
DuckDB libraries from checksum-verified archives and checks actual warehouse
rows and full artifacts. Final release claims require the integrated gates to
pass on the release candidate.

Read [Architecture](ARCHITECTURE.md) for module ownership and native dependency
boundaries, [Releases](RELEASES.md) for distribution, and
[Performance](PERFORMANCE.md) for the measured developer budget.

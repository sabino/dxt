# Initial Acceptance Snapshot

The initial SQL execution scope passed its integrated acceptance gates on the
source identified below. This is a **prerelease, not production ready**.
Acceptance establishes evidence for the pinned contract and tested projects;
production adoption requires project-specific and operational validation.

## Accepted Source And Public Evidence

| Record | Identity or result |
| --- | --- |
| Accepted source commit | [`2b761f2c11419ce9316e5dd1226b1c24aee77ac3`](https://github.com/sabino/dxt/commit/2b761f2c11419ce9316e5dd1226b1c24aee77ac3) |
| Accepted source tree | `abb47b1d72c9d66bb90ed8752a03f8d789b3c9a2` |
| Official CI | [Integrated acceptance run](https://github.com/sabino/dxt/actions/runs/38082038493) — all ten CI jobs passed |
| Independent evidence audit | [Acceptance audit run](https://github.com/sabino/dxt/actions/runs/38094876370) |
| Execution scope | SQL models, seeds, snapshots and supported tests on native DuckDB and PostgreSQL |
| Platforms | Actual Linux x86_64 and ARM runners |

The commit and tree identify the historical accepted candidate. Changes to
documentation, packaging, developer tools or runtime after that source need
their own applicable validation on the changed head. This snapshot does not
claim that its runs tested later changes.

## Completed Gates

| Gate | Accepted result |
| --- | --- |
| Native tests | 817 passed on each actual architecture. |
| Canonical compatibility | All 5,819 cases passed on each actual architecture under CPython 3.12, with zero failures, errors, skips or xfail cases. |
| Python 3.11 developer checks | 326 passed; these supplement the canonical suite. |
| Public DuckDB project | All six unchanged Jaffle Shop steps passed: parse, list, compile, build, run and docs. |
| Public PostgreSQL package project | The unchanged dbt-utils ladder passed all seven Native/Core command pairs, covering 14 commands. |
| Archive installation | Actual extracted archives passed both-adapter installation checks with PATH empty on each architecture, including rows, static docs and complete artifacts. |
| Reproducible distribution | Deterministic archive bytes, checksums, architecture and license/provenance checks passed. |
| Wide seed regression | The unchanged 70,000-binding fixture passed with its typed rows and SQL/artifact assertions. |
| Performance | Correctness-aware cold/warm compilation budgets passed, with exact compiled SQL and complete artifacts checked for each phase. |

The declared versions are dbt Core **1.10.5**, dbt-duckdb **1.9.6**,
dbt-postgres **1.9.1**, DuckDB **1.4.2**, MetricFlow **0.208.1**, semantic
interfaces **0.9.0** and Zig **0.16.0**. Native helper semantics use CPython
**3.12** as their canonical comparison contract.

## Scope And Future Validation

The [compatibility matrix](COMPATIBILITY.md) records supported behavior and
intentional differences. Python model discovery and compilation are static;
authored Python execution is outside the initial scope. Cloud adapters, remote
providers and additional platforms require separate implementation and evidence.

For a later candidate, retain complete canonical reports, run the unchanged
public-project gates and validate the exact archives on each published
architecture. Follow [Releases](RELEASES.md) for publication gates and
[Performance](PERFORMANCE.md) for the measured budgets. The
[roadmap](DBT_REPLACEMENT_ROADMAP.md) separates remaining implementation from
production rollout work.

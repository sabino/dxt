# dxt ExecPlan

## Product Contract

dxt means **Data eXecution & Transformation**. It is an independent,
dbt-project-compatible transformation engine with a native Zig product runtime.
Compatibility is an observed contract against pinned upstream behavior and
complete applicable artifact schemas. Public wording must not imply dbt Labs
affiliation or universal dbt certification.

The initial execution contract is **SQL models on DuckDB and PostgreSQL,
Linux x86_64 and ARM64**. Python resources may be discovered, parsed, selected
and compiled; execution rejects authored Python before warehouse writes.
End users do not need a Python interpreter, dbt or MetricFlow.

The product CLI, parser, compiler, artifacts, planner, adapters and execution
remain Zig. Python is limited to developer scripts, tests, fixtures,
compatibility oracles and release/safety tooling. The toolchain is Zig
**0.16.0**. See [AGENTS.md](AGENTS.md) for engineering and ownership rules.

## Current State

The initial eight Core and four native feature tracks are implemented and
merged. Their scope is recorded in the
[compatibility matrix](docs/COMPATIBILITY.md) and
[replacement roadmap](docs/DBT_REPLACEMENT_ROADMAP.md).

The accepted initial candidate was source commit
`2b761f2c11419ce9316e5dd1226b1c24aee77ac3`, tree
`abb47b1d72c9d66bb90ed8752a03f8d789b3c9a2`. Its acceptance included:

- 817 native tests on each actual Linux architecture.
- 5,819 canonical compatibility cases on each architecture, with zero
  failures, errors, skips or xfail cases.
- All six unchanged Jaffle steps and seven unchanged Native/Core command
  pairs for the PostgreSQL dbt-utils project.
- Deterministic archives, actual both-adapter installation with PATH empty,
  the original wide PostgreSQL seed and correctness-aware performance checks.
- All applicable CI, safety and runtime-boundary gates.

The [original CI run](https://github.com/sabino/dxt/actions/runs/38082038493)
and [sealed-report audit](https://github.com/sabino/dxt/actions/runs/38094876370)
retain this historical evidence. Counts overlap and must not be added into
a distinct-test total. These results describe that source; later candidates
need their applicable checks.

**dxt is not production ready.** Initial compatibility acceptance does not
establish broad real-project operational readiness. Additional adapters,
remote provider integrations, platforms and newer upstream contracts need
separate implementation and certification.

## Active Work

Prepare the native test optimization queue in
[Native test optimization](docs/TEST_OPTIMIZATION_PLAN.md).
Implementation is deferred to a later Agent OS session.
The queue preserves the supported contract while replacing repeated project
compilation with native Zig coverage where the behavior is pure.

Project agent definitions select `gpt-6.1-sol` with medium reasoning by default.
Semantic, architecture, convergence and reflection specialists use high reasoning.
The Agent OS model default matches those definitions.
Python remains developer tooling for independent Core evidence and boundaries.
Real dxt-versus-dbt CLI comparisons remain compatibility acceptance gates.
The queue also prepares an upstream upgrade process and a separate Fusion assessment.

### Sequencing And Ownership

| Phase | Owner | Scope | Status |
| --- | --- | --- | --- |
| Planning and agent settings | Supervisor, `perf/native-test-suite` | This plan, task queue, testing policy and project agent configuration | Prepared; no test migration started |
| Inventory and native foundations | Mapper, supervisor and one scoped worker | Assertion mapping, matched baseline and reusable native fixtures | Task 1 first; foundations depend on its output |
| Native migrations | Separate workers | Regex, itertools, datetime, timezone and remaining mapped module families | Planned; disjoint ownership required |
| Oracle consolidation and distribution | One integration worker | Core boundaries, verified builds, process isolation and CI reports | Planned after relevant migrations |
| Final acceptance | One validation owner and supervisor | Both actual architectures, coverage ledger and measured results | Planned after integration |
| Upstream upgrade process | One scoped tooling worker | Accepted/candidate CLI comparisons, fixture provenance and bounded release-change issues | Task 12; no pin changes authorized by test optimization |
| Fusion assessment | Researcher and supervisor | Versioned engine scope, evidence gaps and later certification tasks | Task 13; no Fusion support claim |

Tasks 3, 4 and 5 can proceed concurrently after shared fixtures are ready.
Task 6 follows task 5 where timezone files depend on datetime owners.
Task 7 produces bounded child issues, not a whole-suite implementation claim.
Shared fixture, compiler and workflow files have one writer at a time.
The supervisor owns the durable coverage inventory and this plan.

GitHub Issues and Projects carry execution state after the next session
creates or reuses the scoped issues. No implementation workers are launched
by this planning change.

### Scope And Acceptance

Always prefer native Zig tests for product behavior, near their owner modules.
Use independent expected values and retain Core checks for observable upstream
behavior. Every removed assertion needs an executable replacement or a retained
boundary check in the coverage inventory.

Preserve actual CLI, artifact schema, adapter lifecycle, public-project,
installation, safety and correctness-aware performance evidence.
Execute real binaries on unchanged inputs at compatibility acceptance.
Revalidate recorded expected fixtures through upstream CLI behavior.
Do not change product semantics, upstream pins, supported platforms or CI
frequency to meet a test runtime target.

Native and Python case counts may change during migration. Coverage is the
mapped behavior; a lower count alone proves neither improvement nor loss.
A distributed run must prove complete collection and execution, with no gaps,
duplicates, failures, errors, skips or xfail cases.

### Validation

For this planning/configuration change:

- Parse all project agent TOML and Agent OS JSON settings.
- Validate project and agent configuration against the official OpenAI schema.
- Run focused Agent OS developer tests and public-safety/runtime-boundary scans.
- Check the diff, references and working tree without running product acceptance.

This planning/configuration PR may merge after fast CI checks pass.
Complete Core comparisons may finish afterward under its merge exception.
Implementation PRs retain their declared compatibility acceptance gates.

Implementation workers use focused native checks first.
One validation owner measures expensive baselines and final full runs.
Actual Linux x86_64 and ARM64 gates remain required for applicable acceptance.
Trial targets are a native developer gate under five minutes and full CI under
thirty minutes. Task 1 sets the measurement conditions; the targets are unproven.

### Risks And Stop Conditions

Stop before deleting an assertion without independent replacement evidence.
Split work when owner modules or shared fixtures overlap.
Keep stateful errors, transactions and identity checks separate when batching
would alter their behavior.
Use isolated processes for Core globals and measure runner CPU/memory limits.
Reject cached binaries from another source, target or toolchain.
Record a missed runtime target instead of weakening coverage to pass it.

### Evidence And Open Choices

The dated task-plan baseline records 5,846 passing Python cases per architecture
from a completed CI run. Five helper families account for about 27% of x86 pytest
time. These observations guide priorities, not a claim that every case is redundant.

Exact native groups, retained cases and worker/shard counts depend on the inventory
and measured trials. Runtime targets have low confidence before those trials.
Candidate upstream versions and Fusion certification targets remain unspecified.
Core parity does not certify Fusion; the assessment must define separate evidence.
The test suite, product runtime and CI scheduling remain unmodified by this plan.

## Next Roadmap Work

The initial functional ladder has no known unimplemented track. The next
developer work reduces validation cost through native tests and scoped integration
execution. Repeatable candidate verification, real-project rollout evidence and
operational hardening remain release priorities. Record observed failures as
bounded slices with owners, source grounding and relevant tests.

Later scope includes additional native adapters, remote DuckDB integrations,
non-Linux portability and updated upstream version contracts. Each needs a
separate scope, driver/runtime ownership map, deterministic fixtures and actual
warehouse/platform evidence. Authored Python execution is outside the initial
SQL contract; it is not an implied requirement for this cleanup.

## Durable References

- [Primer](docs/PRIMER.md): product interface and development loop.
- [Compatibility](docs/COMPATIBILITY.md): supported behavior and differences.
- [Roadmap](docs/DBT_REPLACEMENT_ROADMAP.md): delivered and later scope.
- [Architecture](docs/ARCHITECTURE.md): native module ownership and data flow.
- [Release process](docs/RELEASES.md): archives, versions and publication gates.
- [Native test optimization](docs/TEST_OPTIMIZATION_PLAN.md): native coverage, CLI acceptance, upgrade process and Fusion assessment tasks.
- [Agent OS](docs/AGENT_OS.md): supervisor, workers and public coordination.
- [Multi-agent workflow](docs/MULTI_AGENT_WORKFLOW.md): isolated branches,
  validation and convergence.
- [Research](.agent/research/): historical source maps and design context;
  earlier slice limitations do not override the current compatibility matrix.

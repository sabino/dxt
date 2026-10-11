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

The current change makes documentation usable independently of development
tickets and fixes a release documentation defect. Public Markdown packaged
unchanged currently links to source, tests, scripts and planning files that
are absent from the archive.

| Slice | Owner and branch | Files | Status |
| --- | --- | --- | --- |
| Public documentation | Docs curator, `docs/public-docs-curation` | README, docs, CHANGELOG and citations in existing research notes | In progress |
| Release documentation links | Release worker, `fix/release-documentation-links` | Package/archive validation scripts and focused archive tests | In progress |
| Planning and integration | Supervisor, `docs/production-readiness-cleanup` | PLAN and commit integration | In progress |

Each writer has a separate worktree from `origin/main`. File scopes are
disjoint. The docs curator owns release process prose; the release worker
supplies its interface and behavior for that prose after implementation.
The supervisor integrates commits through Git, without copying files between
worktrees, rebases on current main and owns final validation and publication.

GitHub Issues and PRs carry coordination state using
[Agent Protocols](docs/AGENT_PROTOCOLS.md). This plan carries the active
sequencing contract, not a transcript or a duplicate ticket ledger.

### Scope And Acceptance

1. Keep README concise and product-focused with an explicit prerelease and
   production-readiness disclaimer.
2. Remove specific numbered PR/issue citations from durable documentation.
   Retain generic Agent OS coordination templates and dependency syntax.
3. Store initial acceptance facts in a durable validation page with exact
   source identity and scope. Replace obsolete pending-candidate wording.
4. Separate implemented initial scope, production rollout work and later
   implementation/certification in the roadmap.
5. Keep bundled document links local in release archives. Rewrite links to
   omitted repository files to immutable source URLs during packaging.
6. Reject unresolved relative archive links and retain deterministic archive
   generation, binary/safety checks and upstream notices.
7. Open one non-draft integration PR after local verification and follow
   applicable CI to a mergeable result. Do not merge, tag or publish a release.

### Validation

During implementation, run focused checks only for the changed surfaces.
At the integration boundary:

- `git diff --check` and shell syntax checks.
- `scripts/worktree_finish.sh` for runtime-boundary and public-safety scans.
- Focused archive validation and public-safety tests.
- Deterministic packaging and validation of the transformed archive.
- Review changed files for generated noise, credentials and local paths.
- Rebase on `origin/main`, then verify the final source and applicable CI.

Native product behavior is unchanged. Full canonical platform, public-project,
installation and performance jobs remain applicable where configured; local
tooling checks do not replace their results. No skipped or xfail case counts
as positive compatibility evidence.

### Risks And Stop Conditions

- Do not equate the historical initial acceptance with production readiness
  or certification of the changed candidate.
- Do not alter source document evidence links merely to match archive layout;
  the packaging transformation belongs to developer release tooling.
- Preserve Markdown targets, fragments and escaping while preventing links
  from escaping the repository/archive boundary.
- Do not weaken release safety, checksums, artifact assertions or native
  runtime ownership to make a check pass.
- Stop before unrelated dirty work, overlapping writes, unsupported claims,
  private data publication or unbounded new adapter/platform work.

## Next Roadmap Work

The initial functional ladder has no known unimplemented track. The next
release work is documentation integrity and repeatable verification of each
published candidate, followed by real-project rollout evidence and operational
hardening. The roadmap must record observed failures as bounded slices with
owners, source grounding and relevant tests.

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
- [Agent OS](docs/AGENT_OS.md): supervisor, workers and public coordination.
- [Multi-agent workflow](docs/MULTI_AGENT_WORKFLOW.md): isolated branches,
  validation and convergence.
- [Research](.agent/research/): historical source maps and design context;
  earlier slice limitations do not override the current compatibility matrix.

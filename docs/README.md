# dxt Documentation

These docs describe the native SQL DuckDB/PostgreSQL prerelease, its validated
initial scope and its operational boundaries.

> **Prerelease — not production ready.** Initial Linux x86_64 and ARM acceptance
> is complete for the source recorded in [Validation](VALIDATION.md). Production
> adoption still requires validation of your workloads and operating procedures.

## Start Here

| Page | Use it for |
| --- | --- |
| [Primer](PRIMER.md) | Product goals, runtime rules, development loop, and high-level flow. |
| [Compatibility Matrix](COMPATIBILITY.md) | Implemented behavior, pinned references and explicit differences. |
| [Replacement Roadmap](DBT_REPLACEMENT_ROADMAP.md) | Delivered scope, production rollout work and later implementation. |
| [Validation Snapshot](VALIDATION.md) | Accepted source, platform results and public CI evidence. |
| [Architecture](ARCHITECTURE.md) | Zig module ownership, artifact flow, and Mermaid diagrams. |
| [Agent OS](AGENT_OS.md) | Multidisciplinary agent-team operating model plus local autonomous Codex worker loop across GitHub Issues, Projects, PRs, and worktrees. |
| [Agent Protocols](AGENT_PROTOCOLS.md) | Public-safe issue/PR comment formats, role nudges, handoffs, and reflection protocol. |
| [GitHub Projects Setup](GITHUB_PROJECTS.md) | Desired Project fields, views, label syncing, seed issue bootstrap, and worker-loop commands. |
| [Multi-Agent Workflow](MULTI_AGENT_WORKFLOW.md) | Concurrent Codex/worktree workflow, project agent roles, autonomous orchestration, validation, and PR convergence. |
| [Release Process](RELEASES.md) | Release tags, binary artifacts, checksums, and safety gates. |
| [Performance](PERFORMANCE.md) | Correctness checks, cold/warm measurements and regression budgets. |
| [Changelog](../CHANGELOG.md) | What has changed so far. |
| [ExecPlan](../PLAN.md) | Active milestone plan and implementation sequencing. |
| [Native test optimization](TEST_OPTIMIZATION_PLAN.md) | Planned Agent OS tasks for native coverage, actual CLI checks, parallel integration, upstream upgrades and Fusion assessment. |

## Documentation Rules

- Keep the Zig product runtime requirement explicit.
- Separate supported behavior from planned behavior.
- Prefer tables for compatibility status.
- Keep volatile implementation sequencing in `PLAN.md`.
- Promote stable conclusions from `.agent/research/` into docs when they become
  part of the public product contract.
- Do not include local absolute paths, secrets, private hostnames, logs, caches,
  or session transcripts.

## Status Labels

| Label | Meaning |
| --- | --- |
| Supported | Covered by current product behavior and validation. |
| Partial | A documented subset works; important dbt behavior remains out of scope. |
| Planned | Not implemented yet, but part of the roadmap. |
| Deferred | Known dbt surface intentionally outside the current milestone. |
| Not planned | Outside current product direction. |

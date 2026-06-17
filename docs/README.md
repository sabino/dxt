# dxt Documentation

These docs describe the supported `dxt` pre-alpha behavior. They do not claim
full dbt compatibility unless a page explicitly says that a surface is covered.

## Start Here

| Page | Use it for |
| --- | --- |
| [Primer](PRIMER.md) | Product goals, runtime rules, development loop, and high-level flow. |
| [Compatibility Matrix](COMPATIBILITY.md) | Current support levels and planned dbt surfaces. |
| [Architecture](ARCHITECTURE.md) | Zig module ownership, artifact flow, and Mermaid diagrams. |
| [Release Process](RELEASES.md) | Release tags, binary artifacts, checksums, and safety gates. |
| [Changelog](../CHANGELOG.md) | What has changed so far. |
| [ExecPlan](../PLAN.md) | Active milestone plan and implementation sequencing. |

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

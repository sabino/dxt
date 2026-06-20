# Agent Protocols

Agent communication should be sparse, structured, and public-safe. GitHub Issues
and PRs should contain summaries and decisions, not raw Codex transcripts.

## Issue Comment Blocks

Use these headings when a comment changes coordination state.

### Agent Claim

```md
### Agent Claim
- role:
- branch:
- issue:
- scope:
- files expected:
- validation planned:
- overlap checked:
- stop condition:
<!-- dxt-agent-event:v1 status=claimed role= branch= -->
```

Use `depends_on=#123` in the hidden event comment when the issue or PR must
wait for another issue. Plain text forms `depends on: #123` and `blocked by:
#123` are also recognized for Project dependency summaries and launch blocking.

### Reference Map

```md
### Reference Map
- dbt Core v1:
- Fusion / v2:
- artifact schemas:
- dxt owner modules:
- unsupported boundaries:
<!-- dxt-agent-event:v1 status=reference-map role= -->
```

### Slice Plan

```md
### Slice Plan
- in scope:
- out of scope:
- native Zig tests:
- Python/dbt oracle checks:
- public fixture gates:
- PLAN.md impact:
- stop conditions:
<!-- dxt-agent-event:v1 status=slice-plan role= -->
```

### Routing Decision

Use this when a PM, triager, or supervisor changes stage, splits a broad issue,
or decides that an implementation worker may start.

```md
### Routing Decision
- current stage:
- next stage:
- assigned role labels:
- child issues:
- worker gate:
- reason:
<!-- dxt-agent-event:v1 status=routing role= -->
```

### Validation Evidence

```md
### Validation Evidence
- commands:
- result:
- artifacts checked:
- runtime-boundary result:
- public-safety result:
- residual risk:
<!-- dxt-agent-event:v1 status=validated role= -->
```

### Handoff

```md
### Handoff
- done:
- not done:
- branch:
- PR:
- next owner:
- blocker:
<!-- dxt-agent-event:v1 status=handoff role= -->
```

## Multi-Stage Pipeline

Complex compatibility work should move through explicit stages before a worker
claims a write-capable branch. The orchestrator can launch the role named by
labels, but the issue comments are the durable stage contract.

| Stage | Trigger | Role labels | Required block |
| --- | --- | --- | --- |
| Intake and routing | New or broad issue, stale issue, or unclear ownership. | `role:pm` or `role:supervisor`; the issue triager agent may update the same issue state. | `Routing Decision`; use `Slice Plan` if the issue is already narrow enough. |
| Reference research | dbt/Fusion behavior, artifact schema, or compatibility oracle is unclear; issue has `needs-reference-map`. | `role:researcher`, with area labels as needed. | `Reference Map`. |
| Ownership mapping | dxt modules, fixture owners, validation gates, or overlap risk are unclear. | `role:mapper`, `role:supervisor`, or an area specialist. | `Reference Map` with `dxt owner modules`; add `Routing Decision` if ownership changes the stage. |
| Slice planning | Scope still spans multiple modules, commands, fixtures, or validation gates; issue has `needs-slice-plan`. | `role:supervisor`, `role:mapper`, `role:worker`, or the relevant specialist. | `Slice Plan`. |
| Implementation | Latest comments provide the worker gate below and no blocking dependency or overlap remains. | `role:worker` or one implementation specialist label. | `Agent Claim`, then `Validation Evidence`, then `Handoff`. |
| PR review and audit | PR is open or issue/PR asks for artifact, QA fixture, convergence, runtime-boundary, or public-safety review. | `role:parity`, `role:auditor`, `role:convergence`, `role:reflection`, or a supervisor-requested QA fixture pass. | `Validation Evidence` or `Handoff`, on the PR when reviewing a PR-boundary diff. |

Implementation workers must not start until the latest issue state names:

- Scope and non-goals.
- Upstream dbt Core v1 and Fusion references, or `not applicable`.
- Owning dxt Zig modules, fixtures, artifacts, and docs/scripts surfaces.
- Native Zig tests or why none are needed for docs/scripts-only work.
- Python/dbt oracle, fixture, config, public-safety, or runtime-boundary checks.
- Stop conditions and unsupported boundaries.
- Branch/worktree scope and overlap check.

If any item is missing, leave a `Routing Decision` or `Slice Plan` and stop
before implementation.

## Split Rules

Split a broad issue into child issues before implementation when any of these
are true:

- More than one implementation worker would need to edit the same Zig module,
  fixture family, artifact writer, or docs/CI surface.
- The work mixes source research, module extraction, product behavior, artifact
  parity, and release/safety automation in one PR.
- Validation needs different gates that should fail independently, such as
  native Zig tests, dbt oracle comparison, public fixture execution, and release
  scans.
- The current issue can only name a milestone outcome, not the next coherent
  branch diff.

The supervisor should use the `Routing Decision` block, create or plan child
issues with non-overlapping file scopes, and add a `PLAN.md` sequencing note
when child issues must touch the same owner module in order.

## Dry-Run Routing Examples

- Broad Jinja milestone with no upstream source map: route to
  `role:researcher`; require `Reference Map`; do not launch `role:worker`.
- Selector issue with upstream references but no owner or gate map: route to
  `role:mapper`; require `Reference Map` plus a `Slice Plan`.
- Broad execution issue spanning seeds, models, and tests: route to
  `role:supervisor` with `pattern:hierarchical`; plan child issues before any
  worker claim.
- Published PR that changes manifest fields: route optional `role:parity` or
  `role:auditor` review after PR publication; review is advisory unless the
  issue or PR explicitly declares it a merge gate.

## PR Description Contract

Every PR should include:

- Linked issue.
- Scope and non-goals.
- Upstream dbt/Fusion references when relevant.
- dxt Zig modules changed.
- Artifacts affected.
- Validation commands and results.
- Runtime-boundary and public-safety results.
- Unsupported boundaries.
- Residual risk.

Use [`.github/PULL_REQUEST_TEMPLATE.md`](../.github/PULL_REQUEST_TEMPLATE.md).

## Nudge Protocol

Use role names and issue labels instead of pretending custom agents are GitHub
users.

- `role:supervisor`: needs triage, branch allocation, conflict resolution, or merge decision.
- `role:researcher`: needs upstream dbt/Fusion references.
- `role:mapper`: needs code ownership and validation map.
- `role:worker`: ready for one implementation slice.
- `role:parity`: needs artifact/schema review.
- `role:auditor`: needs runtime-boundary or public-safety review.
- `role:reflection`: assumptions need re-checking after failure or drift.

If GitHub-hosted Codex delegation is available, a maintainer may additionally
tag the service in a GitHub comment. The repo protocol must still be complete
without that hosted service.

## Public-Safety Rules

Do not paste:

- Local absolute paths.
- Private hostnames or mounts.
- Shell history.
- Raw session transcripts.
- Tokens or credentials.
- Long raw test logs.
- Generated target paths unless relative and needed.

Summarize the evidence and keep raw output in ignored `.agent/runs/`.

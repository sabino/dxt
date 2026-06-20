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

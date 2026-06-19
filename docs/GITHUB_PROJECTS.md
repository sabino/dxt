# GitHub Projects Setup

The desired project is named **dxt Compatibility Execution**. It tracks issues,
PRs, agent roles, validation, branch state, and blockers.

The repository stores the desired project schema in
[`.github/agent-team/project.json`](../.github/agent-team/project.json). Use the
bootstrap script in dry-run mode first:

```sh
python scripts/github_agent_os.py project --dry-run --owner sabino --repo sabino/dxt
```

Applying the project requires GitHub CLI auth with project scopes:

```sh
gh auth refresh -s read:project -s project
python scripts/github_agent_os.py project --apply --owner sabino --repo sabino/dxt
```

## Fields

| Field | Type | Purpose |
| --- | --- | --- |
| Status | single select | Intake through merged lifecycle. |
| Agent Role | single select | Current role expected to act. |
| Track | single select | Product or operational track. |
| Pattern | single select | Supervisor, hierarchical, network, or reflection. |
| Validation | single select | Strongest currently required evidence. |
| PLAN Update | single select | Whether `PLAN.md` must change. |
| Source Grounding | single select | Whether upstream references are linked. |
| Branch | text | Branch name only, never local path. |

## Views

Recommended Project views:

- **Supervisor Queue:** grouped by Status.
- **Active Worktrees:** filtered to Claimed/In Worktree/PR Open and grouped by Branch.
- **Milestone Roadmap:** grouped by Track and sorted by priority.
- **Artifact Parity:** filtered to artifact labels.
- **Blocked / Reflection:** filtered to Blocked or `role:reflection`.
- **Release Readiness:** filtered to release, CI, docs, and safety labels.

## Automation

Use built-in Project automation for low-risk transitions:

- New item -> Intake.
- Closed issue -> Merged or Deferred, depending on outcome.
- Reopened issue -> Intake.
- PR merged -> Merged.

Use scripts for explicit bootstrap and issue seeding:

```sh
python scripts/github_agent_os.py labels --dry-run
python scripts/github_agent_os.py labels --apply
python scripts/github_agent_os.py seed-issues --dry-run
python scripts/github_agent_os.py seed-issues --apply
```

Seed issues are starter backlog entries only. They exist so the autonomous
local orchestrator has durable GitHub work items to claim after setup. Edit,
close, or replace them as the plan evolves.

The scripts are developer tooling. They must not be called from product runtime.

## Autonomous Worker Loop

The Project board is the shared state; the local process that does the work is
[`scripts/agent_os_orchestrator.py`](../scripts/agent_os_orchestrator.py).
Restarting Codex in this trusted repo loads `.codex/config.toml`, which raises
the dxt-local subagent thread cap and registers the project agent roles.

Preview the queue without launching workers:

```sh
python scripts/agent_os_orchestrator.py run --repo sabino/dxt --dry-run --max-workers 3
```

Launch workers in separate git worktrees:

```sh
python scripts/agent_os_orchestrator.py run \
  --repo sabino/dxt \
  --profile azure \
  --model gpt-5.5 \
  --max-workers 3
```

Run continuously and let the supervisor merge non-draft PRs only after checks
are green:

```sh
python scripts/agent_os_orchestrator.py run \
  --repo sabino/dxt \
  --profile azure \
  --model gpt-5.5 \
  --max-workers 3 \
  --loop \
  --merge-ready
```

Watch or nudge active work:

```sh
python scripts/agent_os_orchestrator.py status
python scripts/agent_os_orchestrator.py nudge 123 "Please split this before implementation."
```

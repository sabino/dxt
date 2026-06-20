# GitHub Projects Setup

The desired project is named **dxt Compatibility Execution**. It tracks issues,
PRs, agent roles, validation, branch state, and blockers.

The repository stores the desired project schema in
[`.github/agent-team/project.json`](../.github/agent-team/project.json). Use the
bootstrap script in dry-run mode first:

```sh
python scripts/github_agent_os.py project --dry-run --owner sabino --repo sabino/dxt
```

Applying the project requires GitHub CLI auth with project scopes. The
`read:project` scope lets the script inspect Projects; the `project` scope is
needed to create/update the board and fields.

```sh
gh auth refresh -s read:project -s project
python scripts/github_agent_os.py project --apply --owner sabino --repo sabino/dxt
python scripts/github_agent_os.py project-items --apply --owner sabino --repo sabino/dxt
```

The scripts are repo-scoped: `--owner` must match the owner in `--repo` for
Project item sync. `project --apply` reconciles missing single-select options on
existing fields, including the custom `Agent Status` field used instead of
GitHub's built-in `Status` field. `project-items --dry-run` compares current
Project item values with values derived from public-safe labels and
`dxt-agent-event` issue comments before any write.

## Fields

| Field | Type | Purpose |
| --- | --- | --- |
| Agent Status | single select | Intake through merged lifecycle. |
| Agent Role | single select | Current role expected to act. |
| Track | single select | Product or operational track. |
| Pattern | single select | Supervisor, hierarchical, network, or reflection. |
| Validation | single select | Strongest currently required evidence. |
| PLAN Update | single select | Whether `PLAN.md` must change. |
| Source Grounding | single select | Whether upstream references are linked. |
| Readiness | single select | Queue readiness derived from readiness/status labels and event comments. |
| Branch | text | Branch name only, never local path. |
| Dependencies | text | Issue dependencies as `depends_on=#123` tokens from issue bodies or comments. |

## Field Reconciliation

`project-items --apply` updates only fields with unambiguous public sources:

| Field | Source |
| --- | --- |
| Agent Status | `status:*`, readiness labels, or known `dxt-agent-event` statuses. |
| Agent Role | Latest `dxt-agent-event` role, or exactly one role label. Multiple role labels are skipped unless an event resolves them. |
| Track | Area/type labels with a single mapped track. |
| Pattern | `pattern:*` labels. |
| Validation | `gate:*`, `type:safety`, `risk:runtime-boundary`, or `type:ci` labels. |
| Source Grounding | `needs-reference-map`, `type:research`, or `type:compat` labels. |
| PLAN Update | `needs-slice-plan` or `type:research` labels. |
| Readiness | Blocked/review/claimed/ready labels plus known event statuses. |
| Branch | Latest public-safe `branch=` value in a `dxt-agent-event` comment. |
| Dependencies | `depends_on=#123`, `depends on: #123`, or `blocked by: #123` in the issue body or comments. |

If a value cannot be derived without ambiguity, the script reports the skipped
field and leaves it unchanged. Text fields are restricted to public-safe inline
values; local paths are not written.

## Views

Recommended Project views:

- **Supervisor Queue:** grouped by Agent Status.
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
python scripts/github_agent_os.py project-items --dry-run --owner sabino --repo sabino/dxt
python scripts/agent_os_orchestrator.py setup --repo sabino/dxt --apply-project --sync-project-items --dry-run
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

# Agent Instructions

This repository is building `dxt`, Data eXecution & Transformation: a dbt-project-compatible transformation engine with an artifact-first compatibility strategy and later cross-database execution.

Hard requirement: the `dxt` product runtime is Zig. Python may remain only for developer scripts, tests, fixture tooling, compatibility harnesses, and safety scans. Do not implement product CLI, parser, compiler, artifact writer, planner, adapter, or runtime behavior in Python.

## Planning Contract

- Treat `PLAN.md` as the active ExecPlan for multi-hour work.
- Read `PLAN.md` before large changes, architecture changes, compatibility work, release work, or any task that spans more than one command/file.
- Update `PLAN.md` when scope, sequencing, validation gates, risks, or current status change.
- Keep planning notes public-safe: no local absolute paths, private hostnames, secrets, tokens, shell history, or session transcripts.
- Store disposable agent run logs under `.agent/runs/`; that directory is ignored.
- Store useful research notes under `.agent/research/` only after scanning for local paths and secrets.

## Multi-Agent Worktree Rules

- Use a separate git worktree for each concurrent Codex instance doing edits.
- One editing agent owns one branch; do not share dirty worktrees.
- Before editing, check `git status --short --branch` and confirm the branch scope.
- Keep dxt-specific Codex subagent configuration in project-local `.codex/config.toml` and `.codex/agents/*.toml`; do not move this repo's workflow rules into global Codex config.
- Keep branch scopes disjoint by module, fixture, docs area, or compatibility slice.
- If two agents must touch the same files, document sequencing and ownership in `PLAN.md` before edits.
- Use project-scoped `.codex/agents/` roles as helpers, not as merge gates.
- If interactive subagent spawning is unavailable or at the thread cap, use `codex exec` in a separate worktree and keep prompts scoped.
- Use GitHub Issues and Projects for public coordination state when work spans multiple agents, branches, or review specialties.
- Use `scripts/agent_os_orchestrator.py` when work should proceed autonomously from GitHub issues into local worktrees and Codex worker subprocesses.
- Use `scripts/codex_pull_plug.py` only for detached/noninteractive restart handoffs after project-scoped `.codex/` changes. It writes ignored handoff state and lets a guardian launch a fresh `codex exec`; it does not kill the current process or reuse the visible terminal.
- Use `scripts/codex_tmux_supervisor.py` for exact-terminal restarts. The session must have been launched inside its tmux pane first; restart requests are two-phase and the watcher may send `/goal pause` and `/exit` only after the current agent marks the request `ready_to_exit`.
- `scripts/hermes_codex_watchdog.py` is a Hermes-friendly tick for the tmux supervisor. It may observe and notify, but it should only act on `ready_to_exit` requests from this repository.
- Before requesting any pull-plug restart, write a concise reason and resume prompt. Do not use it to create competing workers for the same issue or dirty branch.
- Keep raw local agent output in ignored `.agent/runs/`; put only concise public-safe summaries in issues, PRs, docs, or `.agent/research/`.
- Converge through PRs into `main`; do not merge by copying files between worktrees.
- Rebase each branch on `origin/main` before final validation.
- Delete merged or stale worktrees only after confirming no uncommitted work.
- See `docs/AGENT_OS.md`, `docs/AGENT_PROTOCOLS.md`, and `docs/GITHUB_PROJECTS.md` for the GitHub-backed agent operating model.
- See `docs/MULTI_AGENT_WORKFLOW.md` for the durable workflow.

## Engineering Rules

- Preserve dbt compatibility as an observed contract: compare against dbt Core outputs and published artifact schemas.
- Keep user-facing product behavior in Zig and validate it through the native binary.
- `src/project.zig` is a public/orchestration facade in transition, not the permanent home for all product logic. New shared data model, selector, parser, graph, manifest, loader, and utility code should move toward focused `src/project/*.zig` modules.
- Keep behavior-preserving moves separate from feature behavior changes. Mechanical extraction commits should avoid selector/parser/runtime semantic changes beyond import visibility needed for the move.
- Keep implementation slices small and auditable.
- During implementation, prefer local tests and focused self-checks. Second-agent/Codex reviews are optional and should be used only when explicitly requested or when a specific blocker needs independent analysis.
- Prefer deterministic fixtures and local adapters before live warehouses.
- Do not add broad dependencies or generated artifacts without a validation reason.
- Run the fastest relevant verification before finishing a change.
- Review `git status --short` and the diff before committing.
- Python tests are allowed for black-box CLI integration, dbt compatibility oracles, fixture-heavy artifact checks, schema validation, public-safety scans, and runtime-boundary checks only. Product CLI, parser, compiler, selector, graph, manifest, adapter, and runner behavior must remain Zig.
- Core parser, selector, graph, manifest, and Jinja/helper behavior should have fast native Zig tests close to the implementation. Add Python coverage as integration or dbt-parity evidence when behavior crosses the CLI, filesystem, artifacts, or dbt fixtures.

## Compatibility Priorities

1. Parse dbt project structure and emit dbt-shaped artifacts.
2. Compile common Jinja, refs, sources, configs, vars, and macros.
3. Execute seeds, models, and tests through DuckDB.
4. Validate public projects such as Jaffle Shop.
5. Expand selectors, packages, state/defer, adapters, semantic resources, and cross-database planning.

## Release Rules

- `main` should stay green.
- Use feature branches and PRs for publication once the GitHub repository exists.
- Require green CI checks before merge. Second-agent or human review is not a mandatory merge gate while the active workflow allows self-merge after green checks.
- Do not publish artifacts containing local paths, secrets, caches, logs, or private environment details.

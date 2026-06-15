# Agent Instructions

This repository is building `dxt`, the Data Transformation eXecutor: a dbt-project-compatible transformation engine with an artifact-first compatibility strategy and later cross-database execution.

## Planning Contract

- Treat `PLAN.md` as the active ExecPlan for multi-hour work.
- Read `PLAN.md` before large changes, architecture changes, compatibility work, release work, or any task that spans more than one command/file.
- Update `PLAN.md` when scope, sequencing, validation gates, risks, or current status change.
- Keep planning notes public-safe: no local absolute paths, private hostnames, secrets, tokens, shell history, or session transcripts.
- Store disposable agent run logs under `.agent/runs/`; that directory is ignored.
- Store useful research notes under `.agent/research/` only after scanning for local paths and secrets.

## Engineering Rules

- Preserve dbt compatibility as an observed contract: compare against dbt Core outputs and published artifact schemas.
- Keep implementation slices small and reviewable.
- Prefer deterministic fixtures and local adapters before live warehouses.
- Do not add broad dependencies or generated artifacts without a validation reason.
- Run the fastest relevant verification before finishing a change.
- Review `git status --short` and the diff before committing.

## Compatibility Priorities

1. Parse dbt project structure and emit dbt-shaped artifacts.
2. Compile common Jinja, refs, sources, configs, vars, and macros.
3. Execute seeds, models, and tests through DuckDB.
4. Validate public projects such as Jaffle Shop.
5. Expand selectors, packages, state/defer, adapters, semantic resources, and cross-database planning.

## Release Rules

- `main` should stay green.
- Use feature branches and PRs for publication once the GitHub repository exists.
- Require tests and a second-agent or human review before merge.
- Do not publish artifacts containing local paths, secrets, caches, logs, or private environment details.

# dxt Governance, Execution Loop, and Release Plan

## Purpose

This note defines the operating rules for building and publishing `dxt` as a public repository under `sabino/dxt`. It is intended to keep agent-driven development auditable, reproducible, and safe for public release without leaking workstation-specific paths, credentials, environment details, or private workflow assumptions.

## Repository Governance

### Ownership and Decision Rules

- Treat `main` as the protected integration branch.
- Develop all changes on short-lived feature branches with focused scope.
- Keep decisions in repo-local documents, issues, pull requests, or commit messages. Do not encode local machine paths, private hostnames, private mount names, shell history, or personal environment details in committed files.
- Keep `PLAN.md` protected from incidental edits. Change it only when a task explicitly requests that file.
- Prefer small, reviewable increments over large mixed changes.
- Avoid unrelated formatting churn. Formatting-only changes should be isolated when needed.
- If generated artifacts are required, document how to regenerate them and keep only deterministic, useful outputs in version control.

### Branch and Commit Policy

- Branch naming should be descriptive and impersonal, for example `feat/pack-dxt`, `fix/manifest-validation`, or `docs/release-process`.
- Commit messages should describe behavior and intent, not local debugging context.
- Do not commit temporary logs, local transcripts, shell dumps, `.env` files, editor state, caches, package-manager stores, or build output unless the repository explicitly defines them as fixtures.
- Before committing, run `git status --short` and review every changed file.

## Agent Execution Loop Rules

Agent work should follow a tight loop:

1. Read the current repo state and task boundaries.
2. Identify the smallest coherent change.
3. Make scoped edits.
4. Run the fastest relevant verification.
5. Inspect the diff.
6. Either continue with the next small change or stop with a clear status.

Rules for each loop:

- Never assume a clean worktree. Check for existing user changes before editing.
- Do not overwrite or revert changes that were not made by the current task unless the user explicitly asks.
- Keep edits inside the requested scope.
- Do not modify `PLAN.md` unless explicitly authorized.
- Use deterministic commands where possible.
- Prefer repo-local scripts over ad hoc one-off command sequences once workflows stabilize.
- Record durable project knowledge in repo docs, not in local-only shell aliases or hidden machine state.
- When blocked, capture the exact blocker, the command that exposed it, and the next required decision.

## Responsible Codex Exec and Subprocess Use

Codex or any other agent may use shell execution to inspect, build, test, and package the project, but execution must stay bounded and observable.

### Command Discipline

- Start with read-only inspection commands such as `git status`, `rg --files`, `rg`, `ls`, and package-manager metadata commands.
- Prefer `rg` for repository search.
- Run commands from the repository root unless a script documents a different working directory.
- Avoid command chains that obscure failures. When a sequence matters, encode it in a script or run steps separately.
- Set timeouts or monitor long-running commands.
- Stop background processes that were started for verification.
- Do not run destructive filesystem, Git, Docker, or package-manager cleanup commands unless they are explicitly required and scoped.
- Do not use shell commands to write source files when normal patch-based editing is sufficient.

### Subprocess Loop Safety

- Keep subprocess loops finite: define an exit condition, maximum retries, and a maximum runtime.
- Capture logs to ignored temporary locations or CI artifacts, not committed files.
- Surface repeated failures early instead of retrying indefinitely.
- On failure, preserve the first meaningful error and the final command output.
- Do not spawn nested agents or recursive build loops without a clear budget and termination condition.
- If a command can consume significant disk, network, CPU, or memory, run the smallest useful variant first.

## Pull Request, Review, and Merge Gates

Every PR should include:

- Purpose and scope.
- User-facing behavior changes.
- Validation performed.
- Risks, limitations, or follow-up work.
- Screenshots or terminal excerpts only when they are necessary and scrubbed of local paths or secrets.

Required gates before merge:

- Worktree diff reviewed by the author.
- CI green for all required jobs.
- Tests added or updated for changed behavior, unless the PR is documentation-only.
- No committed secrets, tokens, local paths, private hostnames, or personal machine identifiers.
- No unrelated file churn.
- Public documentation checked for path-neutral language.
- Release-impacting changes include changelog or release-note updates once those files exist.

Merge policy:

- Prefer squash merge for focused PRs to keep `main` readable.
- Use merge commits only when preserving branch structure has value.
- Do not merge with failing required checks.
- Do not bypass review gates for release branches.

## GitHub Publication Plan

The public repository target is `sabino/dxt`.

Before first push:

- Ensure repository files contain no local absolute paths.
- Add a conservative `.gitignore` before introducing toolchains.
- Add a `README.md` that describes the project without workstation-specific context.
- Add a license or explicitly document that licensing is pending.
- Add `SECURITY.md` with vulnerability reporting guidance before broader distribution.
- Add GitHub Actions workflows only after they can run without private services or machine-specific assumptions.

Publication rules:

- Do not push private environment files, credentials, API keys, shell history, local logs, generated secrets, session transcripts, or path-bearing debug output.
- Use GitHub repository settings to require PR review and passing checks on `main`.
- Use branch protection for `main`.
- Prefer repository variables and encrypted GitHub secrets for release automation.
- Keep release credentials out of the repository and out of CI logs.

## CI Matrix

The initial CI should be small, fast, and representative. Expand it as the implementation language and packaging strategy become concrete.

Recommended baseline:

| Job | Platforms | Purpose |
| --- | --- | --- |
| `lint` | Ubuntu latest | Formatting, static checks, and repository hygiene. |
| `test` | Ubuntu latest, macOS latest, Windows latest | Cross-platform unit and integration tests. |
| `package` | Ubuntu latest | Build distributable artifacts and validate package contents. |
| `security` | Ubuntu latest | Dependency audit, secret scan, and permission checks. |

Matrix guidance:

- Test the lowest supported runtime version and the current stable runtime.
- Keep slow end-to-end jobs separate from required fast checks until they are stable.
- Make package-content checks fail on absolute local paths.
- Upload build artifacts only from release or packaging jobs.
- Use pinned action versions.
- Avoid CI steps that depend on local mounts, private paths, or interactive credentials.

## Test Strategy

Testing should prove both behavior and release safety.

### Test Layers

- Unit tests for pure parsing, validation, packaging, and manifest logic.
- Integration tests for filesystem layout, archive generation, command-line behavior, and error handling.
- Golden fixture tests for generated package metadata and archive contents.
- Cross-platform tests for path handling, executable discovery, line endings, and shell quoting.
- Release smoke tests that install or unpack the produced artifact and run basic commands.

### Required Assertions

- Generated artifacts do not contain local absolute paths.
- Error messages are useful but do not disclose private environment details.
- Temporary files are created under safe temporary directories and cleaned up.
- CLI commands return stable exit codes.
- Invalid input fails closed with clear diagnostics.
- Packaging is reproducible enough that unexpected diffs are reviewable.

### Test Data

- Keep fixtures small.
- Use synthetic examples rather than copied private project data.
- Scrub path-like strings from expected outputs unless the path is intentionally relative.
- Do not commit credentials, tokens, cookies, or real service payloads.

## Disk-Space Discipline

Development and CI must avoid uncontrolled disk growth.

- Keep generated packages, caches, and logs out of Git.
- Prefer build directories that can be safely deleted.
- Add cleanup targets for large generated outputs once build tooling exists.
- Keep fixtures minimal and compressed only when compression itself is under test.
- Avoid committing vendor directories unless the project explicitly chooses vendoring.
- In CI, separate dependency caches from build artifacts and give caches clear keys.
- Do not run broad system cleanup as part of project scripts.
- For release packaging, report artifact sizes and fail if unexpectedly large once thresholds are defined.

## Security and Secrets

Security defaults:

- No secrets in source, tests, docs, examples, logs, generated packages, or issue templates.
- No real user data in fixtures.
- No command examples that embed tokens or private endpoints.
- No dependency install scripts that execute remote code beyond standard package-manager behavior.
- No release job with write credentials on pull requests from forks.
- Use least-privilege GitHub token permissions in workflows.
- Pin or constrain third-party actions and dependencies.
- Add automated secret scanning before public release.

Reviewers should check:

- Whether new logs can expose environment variables.
- Whether archives include unintended files.
- Whether subprocess execution handles untrusted input safely.
- Whether temporary files have predictable names or unsafe permissions.
- Whether documentation encourages unsafe copy-paste commands.

## Release Plan

### Versioning

- Use semantic versioning once the public CLI or package API is defined.
- Before `1.0.0`, allow breaking changes but document them clearly.
- Tag releases as `vMAJOR.MINOR.PATCH`.
- Keep release notes focused on user-visible changes, migration notes, and known issues.

### Release Checklist

1. Confirm `main` is green.
2. Confirm working tree is clean.
3. Run the full local verification suite.
4. Run package generation.
5. Inspect package contents for local paths, secrets, caches, logs, and unintended files.
6. Run install or unpack smoke tests from the generated artifact.
7. Update changelog or release notes.
8. Create a signed or annotated tag if project policy requires it.
9. Publish through CI using scoped credentials.
10. Verify the GitHub release page and downloadable artifacts.

### Artifact Rules

- Artifacts must be generated from committed source.
- Artifacts must not include local absolute paths.
- Artifacts must not include secrets or private configuration.
- Artifacts should include license and readme files when applicable.
- Checksums should be published for downloadable binaries or archives.

## Initial Implementation Priorities

1. Add baseline project metadata, `.gitignore`, `README.md`, license decision, and security policy.
2. Define the implementation language and supported runtime versions.
3. Add a minimal test runner and one passing test.
4. Add GitHub Actions for lint and test.
5. Add package generation and package-content validation.
6. Add release automation only after packaging is deterministic and secret handling is clear.

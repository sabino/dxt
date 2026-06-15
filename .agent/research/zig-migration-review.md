# Zig Migration Review

## Scope

This note reviews the intended migration from the current Python scaffold to a Zig CLI skeleton. It is not an implementation plan for the parser, compiler, adapter layer, or artifact writer. The first Zig PR should preserve the current scaffold contract while making the implementation language and validation path explicit.

Current repo facts:

- The product goal is a dbt-project-compatible transformation engine with artifact-first compatibility.
- The current CLI is a Python placeholder exposed by `python -m dxt` and the `dxt` console script.
- Existing placeholder commands are `version`, `parse`, `ls`, `compile`, `build`, and `docs generate`.
- Planned commands return exit code `2` with a clear "planned but not implemented" message.
- CI currently runs Python 3.11 and 3.12, whitespace checks, the public-safety scan, and pytest.
- The public-safety scan is Python-based and scans committed text files, including research notes.
- Zig is available in the local development environment as version `0.16.0`, but the repo does not yet pin a Zig version for contributors or CI.

## Migration Thesis

The lowest-risk first PR is a Zig CLI skeleton that replaces the Python product entrypoint while keeping behavior boring and measurable:

- `dxt --help` works.
- `dxt --version` works.
- `dxt version` prints the same project version.
- Placeholder commands accept the documented flags.
- Placeholder commands continue to fail with a stable nonzero exit code until implemented.
- No parser, dbt project loading, artifact writing, or warehouse execution is introduced in the same PR.

This keeps the first PR review focused on toolchain, packaging, CI, and command-surface continuity. A mixed PR that changes language, command behavior, artifact semantics, and parsing logic at the same time would be hard to review and would weaken the compatibility baseline.

## Key Risks

### Toolchain Drift

Zig syntax, build APIs, package manager behavior, and standard library details can change across Zig versions. The first PR needs a pinned version in docs and CI. Without that, contributors can produce different builds or fail before reaching project code.

Acceptance criteria:

- CI installs one explicit Zig version.
- README names the supported Zig version or points to the CI-pinned version.
- `zig version` is printed in CI logs.
- The branch does not rely on an unpinned system Zig in CI.

### CLI Contract Regression

The Python scaffold already creates a command contract, even though implementation is placeholder-only. Replacing it with Zig must not remove command names, required command nesting, supported flags, help output, or expected exit-code shape without an explicit compatibility decision.

Acceptance criteria:

- Black-box tests cover `dxt --help`, `dxt --version`, `dxt version`, `dxt parse`, `dxt ls`, `dxt compile`, `dxt build`, and `dxt docs generate`.
- Tests cover at least one representative shared flag such as `--project-dir`, `--target-path`, and `--select`.
- `docs generate` remains a nested command.
- Placeholder commands return `2`, or the PR explicitly documents and tests a different stable code.
- Unknown commands and malformed flags fail with stable diagnostics.

### Packaging Ambiguity

The repo currently looks like a Python package. A Zig CLI shifts the distribution model toward a native binary, and ambiguous mixed packaging will confuse users and CI.

Acceptance criteria:

- The PR clearly chooses one of these states:
  - Python package remains only for development/test utilities, not as the product CLI.
  - Python package remains as a temporary shim that execs the Zig binary, with a removal plan.
  - Python package metadata is removed or reduced after the Zig binary is the only supported CLI.
- README command examples match the chosen state.
- CI builds the same executable that tests invoke.
- Generated binaries and build directories stay ignored.

### Public-Safety Coverage Gaps

The public-safety script currently knows common text suffixes and skip directories. A Zig migration adds `.zig`, `.zon`, build outputs, and possible generated files. The scanner must continue to catch local paths and secrets in source and docs while skipping build output.

Acceptance criteria:

- Public-safety scanning includes Zig source and Zig package files.
- Build output directories are ignored.
- CI still runs the public-safety scan before tests.
- Release/package checks fail if archives or distributable contents include local paths, secrets, caches, logs, or private environment details.

### CI Coverage Drop

The first Zig PR must not replace Python CI with weaker Zig-only smoke checks. The existing public-safety and test discipline should be preserved while adding Zig build and CLI verification.

Acceptance criteria:

- CI runs `zig build`.
- CI runs `zig build test`.
- CI runs black-box CLI tests against the built binary.
- CI runs the public-safety scan.
- CI keeps `git show --check --format=short --no-renames HEAD`.
- If pytest remains for utility tests, CI still runs pytest on supported Python versions or a consciously smaller Python matrix.

### Premature Parser Design Lock-In

It is tempting to create parser, YAML, Jinja, or artifact abstractions during the skeleton migration. That would front-load architecture before the compatibility harness is ready.

Acceptance criteria:

- The first PR contains no dbt parser implementation beyond placeholder command wiring.
- No broad parsing dependencies are added.
- No generated dbt artifacts are committed.
- Any build helper or module layout is justified by immediate CLI skeleton needs.

### Cross-Platform Assumptions

A native binary should eventually be cross-platform. Even if first CI only runs Ubuntu, the skeleton should avoid Unix-only assumptions in path handling, process tests, and packaging.

Acceptance criteria:

- CLI tests invoke the built executable without shell-specific assumptions.
- Paths in tests are relative and synthetic.
- Help and version output do not include host paths.
- Follow-up CI expansion to macOS and Windows is documented before release work.

## Required Documentation Changes

The first implementation PR should update documentation in the same branch as the Zig skeleton.

README changes:

- Replace `python -m dxt --help` and `python -m dxt version` examples with the supported Zig/binary commands.
- Add a minimal development section for `zig build`, `zig build test`, and running the built CLI.
- State that the CLI is still pre-alpha and placeholder-only.
- Clarify whether Python is still needed for public-safety or compatibility-test utilities.

PLAN changes:

- Because the active plan currently describes a Python scaffold under M0, the implementation PR should update the plan only when that PR is authorized to touch `PLAN.md`.
- The plan should record Zig as the product implementation language, the pinned toolchain policy, and the new validation commands.
- M0 exit criteria should include the Zig build and CLI smoke tests once the migration lands.

CI/workflow docs:

- Document which CI checks are required for PR merge.
- Name the supported Zig version source of truth.
- Document whether Python remains a dev dependency and why.

Release/security docs:

- Before release packaging, document native binary artifact inspection, archive contents, checksums, and path/secret scanning.
- Keep public wording clear that the project is not affiliated with dbt Labs.

## Required CI Changes

Minimum CI for the first Zig PR:

- Checkout.
- Set up the pinned Zig version.
- Print `zig version`.
- Run whitespace check.
- Run public-safety scan.
- Run `zig build`.
- Run `zig build test`.
- Run black-box CLI smoke tests against the built `dxt` executable.
- Run pytest if Python utility tests remain.

Recommended CI shape after the first PR:

- `hygiene`: whitespace, public-safety scan, docs path/secret checks.
- `zig`: build, unit tests, CLI smoke tests on Ubuntu.
- `python-utilities`: pytest for public-safety and future dbt-oracle harness utilities, if retained.
- `package`: build release-shaped artifacts and inspect contents, initially optional until release work begins.

CI should not depend on private paths, private mounts, local shell aliases, interactive credentials, or locally installed Zig.

## Required Test Changes

Current `tests/test_cli.py` is Python-level and calls `dxt.cli.main()` directly. A Zig CLI needs black-box tests that execute the built binary, because the product surface becomes the executable rather than a Python function.

Minimum CLI tests:

- `--help` exits `0` and includes the product description or command list.
- `--version` exits `0` and includes the project version.
- `version` exits `0` and prints the plain version.
- `parse --project-dir fixture --select tag:nightly` exits `2` and says the command is planned.
- `ls --resource-type model --output json` accepts the flags and exits with the placeholder code.
- `build --full-refresh --threads 2` accepts the flags and exits with the placeholder code.
- `docs generate --target-path target-dxt` exits `2` and names `dxt docs generate`.
- Unknown commands fail nonzero.

Public-safety tests:

- Keep tests for token and local-path patterns.
- Add coverage that `.zig` and `.zon` files are text candidates.
- Add coverage that build output is skipped.

Future compatibility harness tests:

- Python may remain useful for invoking dbt Core as an oracle, normalizing JSON artifacts, validating schemas, and comparing fixture outputs.
- These tests should live clearly as development harness tests, not as the product implementation.

## What Python May Remain For

Python does not have to disappear immediately. It can remain where it improves validation without becoming the product runtime:

- Public-safety scanning.
- dbt Core oracle invocation in compatibility tests.
- JSON schema validation for dbt artifacts.
- Fixture generation and normalization helpers.
- Release/package inspection scripts.
- One temporary CLI shim only if needed for transition, with a documented removal plan.

Python should not remain as:

- A second product CLI with behavior that can drift from Zig.
- Hidden implementation for parser/compiler behavior after Zig is declared the product core.
- A packaging path that users are told to install while the tested binary is different.

## Branch And PR Validation Gates

The Zig migration branch should pass these gates before review:

- Worktree contains only intended migration files and documentation updates.
- No generated binaries, caches, logs, or local run transcripts are staged.
- `zig build` passes.
- `zig build test` passes.
- CLI smoke tests pass against the built binary.
- Public-safety scan passes.
- Pytest passes if Python utility tests remain.
- Diff is reviewed for local absolute paths, private hostnames, secrets, and machine-specific assumptions.
- README examples match actual commands.
- CI workflow uses pinned toolchain setup and does not rely on local system state.

The first PR description should include:

- Why Zig is being introduced now.
- What behavior is intentionally preserved from the Python scaffold.
- Which Python files remain and why.
- Exact local validation commands run.
- Known follow-up work, especially cross-platform CI and release packaging.

## Blocking Issues For The First PR

Any of these should block the first Zig migration PR:

- The built CLI cannot run `--help`, `--version`, `version`, and all planned placeholder commands.
- Placeholder commands silently return success before they are implemented.
- Existing documented flags are dropped without an explicit compatibility decision.
- `docs generate` is flattened or renamed without a documented command-surface decision.
- CI does not build and test the Zig executable.
- CI relies on an unpinned or locally preinstalled Zig toolchain.
- Public-safety scanning is removed, weakened, or stops scanning new Zig source files.
- Committed docs, tests, or generated files contain local absolute paths, private hostnames, secrets, logs, caches, or machine-specific state.
- The PR mixes skeleton migration with parser/compiler/artifact implementation.
- The repo ends with two user-facing CLIs whose behavior differs.
- README commands do not work against the branch.
- Build outputs or binaries are committed accidentally.
- The branch changes `PLAN.md` without explicitly including that in the PR scope.

## Recommended First-PR Acceptance Criteria

The first PR is acceptable if it delivers this exact level of behavior:

- `dxt` is implemented as a Zig-built binary.
- The version remains `0.0.0` unless the PR also introduces a versioning policy.
- All existing placeholder command shapes still parse.
- Placeholder commands return the documented nonzero code.
- Help/version output is stable enough for tests.
- CI proves the binary builds, tests, and runs.
- Python remains only for named utility tasks, or is removed cleanly.
- README, tests, and CI agree on how to build and run the CLI.
- Public-safety checks still run and include the new source formats.
- No source-level implementation of dbt parsing, artifact emission, Jinja, selectors, or adapters is included.

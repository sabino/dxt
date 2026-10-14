# Native test optimization plan

Replace repeated project-level helper checks with native Zig coverage.
Distribute the integration checks that still need real command boundaries.
Preserve the supported behavior in [Compatibility](COMPATIBILITY.md).

Status: isolated CI distribution is being implemented on
`ci/parallel-compatibility-tests`, with one local editor and no Agent OS run.
Native test migrations, build consolidation and the later research queue remain
deferred. Distribution preserves the existing assertions and does not require
those migrations first.
Agent configuration uses `gpt-6.1-sol` with medium reasoning by default.
Use each role file's declared effort for specialist work.
Upstream upgrade tooling and Fusion assessment are also deferred.

## Measured baseline

The [completed CI run](https://github.com/sabino/dxt/actions/runs/38145917585)
tested source `370e1a3c53eee564d658a971a4ab5c84571c5f42` on 2026-10-11.
Its JUnit reports contain 5,846 passing Python cases per architecture.

| Measurement | Linux x86_64 | Linux ARM64 |
| --- | ---: | ---: |
| Full pytest time | 15,657 seconds | 11,898 seconds |
| Five costly helper families | 4,177 seconds | 3,099 seconds |
| Cases in those families | 935 | 935 |

The five families are datetime, datetime public APIs, itertools, pytz and regex.
They consume about 27% of x86 pytest time.
Dependency setup takes under a minute. Zig and package caches already restore.
The compatibility jobs run pytest without test distribution.

These counts are historical, not fixed acceptance thresholds.
Native, integration and oracle counts overlap; do not add them into a behavior total.
Refresh the baseline against the implementation source before measuring improvements.

## Isolated CI distribution

The [more recent baseline](https://github.com/sabino/dxt/actions/runs/38219109929)
tested source `3b238e4972840178a8162f85a422cfe9a43bc38e` on 2026-10-12.
Both JUnit reports contain 5,916 passing cases. Summed case durations are
12,735 seconds on x86_64 and 12,335 seconds on ARM64. The slowest complete
module takes about twelve minutes; no single module dominates the full run.

CI collects the complete canonical suite once and balances whole modules
across **eight independent runners per architecture**. Each runner retains
its own checkout, native builds, Core process globals, PostgreSQL fixtures,
DuckDB files, temporary projects and browser state. Module case order stays
unchanged. No test assertions, adapters or upstream comparisons are removed.
There is no new Python dependency; these scripts are developer tooling only.

`tests/compatibility_timings.json` retains the maximum measured module cost
from the two baseline reports and separately identifies local scheduling
samples for new regression modules. Local samples are scheduling estimates,
not sealed source/platform acceptance evidence; the contract sample combines
successful receipts with the latest correction preferred for duplicate cases.
Unknown modules receive a case-count estimate and always run. Timing weights
affect placement only, never coverage. Reusing the historical baseline alone
gave a maximum shard estimate of **27.4 minutes**, before runner
setup and queue time. This is a projection, not a measured new CI result.
More runners consume additional setup/build minutes; concurrency is bounded
at sixteen canonical runners across both architectures.

The `test py3.12` and `test py3.12 aarch64` aggregate checks require successful
collection and every shard. Their evidence audit also requires:

- The same complete collection and source content fingerprint on every runner.
- Exactly one assignment and one passing JUnit case per collected node ID.
- All shard manifests and reports, with no missing or unexpected files.
- Successful setup, call and teardown, with zero failures, errors, skips or xfails.
- The actual expected Linux architecture and CPython 3.12 on every shard.

Native, installation, public-project, performance and safety gates remain
separate. Release validation retains its complete suite and strict report
check; this change accelerates pull-request/main CI scheduling.

For a local trial in an otherwise prepared CPython 3.12 developer environment:

```sh
PYTHONPATH=scripts python -m pytest -q --collect-only -p pytest_shard \
  --dxt-shard-count=8 --dxt-shard-timings=tests/compatibility_timings.json \
  --dxt-shard-output=.agent/runs/canonical-plan.json
PYTHONPATH=scripts python -m pytest -q -p pytest_shard \
  --dxt-shard-plan=.agent/runs/canonical-plan.json --dxt-shard-index=0 \
  --dxt-shard-output=.agent/runs/shards/shard-0.json \
  --junitxml=.agent/runs/shards/shard-0.xml
```

Run indices 0–7 in separate checkouts when launching them concurrently.
Copy the same plan to each checkout and gather their uniquely named reports:

```sh
python scripts/check_compatibility_shards.py \
  --plan .agent/runs/canonical-plan.json --reports-dir .agent/runs/shards
```

One shard is focused developer feedback, not full acceptance. Ordinary
`pytest -q` remains available. Recollect the plan after any source change;
stale source fingerprints fail visibly. Focused developer plans may name test
modules, but canonical CI always collects the complete suite.

### Local measured trial

A fixed 67-case selection from primitive identity, conditional expressions,
filter rendering and JSON rendering ran through the real native binary and
pinned Core 1.10.5 comparisons. Each mode used separate source snapshots,
CPython 3.12.15, Zig 0.16.0 and DuckDB 1.4.2 on Apple Silicon. Debug binaries
were built before timing; measurements include pytest startup and fixtures,
but exclude plan collection and the initial build.

| Isolated processes | Elapsed time | Passing cases |
| --- | ---: | ---: |
| 1 | 39.70 seconds | 67 |
| 2 | 25.71 seconds | 67 |
| 4 | 18.01 seconds | 67 |

All three unions pass the complete case-identity audit with zero skips or
xfails. Four processes give a measured 2.20x improvement for this selection;
its largest module limits further splitting. This local trial does not certify
the full Linux suite or establish the projected CI duration.

## Required testing policy

- Always prefer native Zig tests for product behavior, near the owning module.
- Exercise pure helpers in-process using independent expected values.
- Keep Core comparisons for upstream behavior and integration boundaries.
- Keep real CLI, artifact, database, installation and public-project evidence where relevant.
- Delete replaced tests in the migration diff after their assertions have mapped replacements.
- Reject skips, xfail, missing cases and duplicate shard assignments as positive acceptance evidence.

A native test must call the product implementation.
Do not introduce a test-only evaluator or reproduce expected values with the implementation under test.
Python remains developer tooling for Core oracles, fixtures, report validation and boundary checks.

## Actual CLI compatibility

Native Zig tests provide the fast development loop.
Compatibility acceptance also executes the real `dxt` and pinned `dbt` binaries.
Use unchanged project inputs, equivalent command arguments and isolated warehouse state.
Compare selected resources, dependencies, configuration, compiled SQL, artifact fields,
database schemas/rows, exit codes, warnings and failure outcomes.
Preserve intentional differences recorded in [Compatibility](COMPATIBILITY.md).
Normalize only documented volatile metadata, such as invocation IDs and timings.

Recorded expected values require exact upstream versions, fixture identity and a regeneration procedure.
Obtain them from upstream behavior, never from dxt output.
Revalidate those expectations through the upstream CLI at certification and when considering an upgrade.
Batch pure positive fixtures only when each assertion remains identifiable.
Keep stateful, negative and command-placement checks separate when batching changes behavior.

In-process `dbtRunner` calls may reduce developer test cost.
Retain subprocess checks for flags, environment, logs, failure publication and command isolation.
An in-process result alone does not prove those CLI boundaries.
Reuse `scripts/check_dbt_utils.py`, `scripts/jaffle_core_oracle.py` and
`scripts/check_performance.py` before creating another comparison harness.

## Upstream version and Fusion boundaries

The accepted comparison contract is Core 1.10.5 with the pinned adapters and CPython 3.12.
Candidate versions remain separate until applicable certification passes.
Task 12 defines the repeatable upgrade process; it does not nominate a release or change pins.

Fusion is a source and architecture reference, not an executable oracle in the existing suite.
dxt's typed SQL analysis and lineage have native evidence for their own contracts.
They do not certify Fusion CLI behavior, editor integrations or platform features.
Task 13 scopes a separate assessment before any Fusion replacement claim.

## Future native migration execution contract

For a later explicitly requested Agent OS migration run, create or update one
parent issue and the task issues below.
Reuse matching issues instead of appending duplicates.
Use [Agent Protocols](AGENT_PROTOCOLS.md) for claims, plans, validation and handoffs.

Issue bodies inherit this scope, policy and source map.
Each issue must also name its branch, exact files, risk, validation and stop condition.
Use an explicit `files expected:` field so the orchestrator can check overlaps.
Translate task dependencies into `depends_on=#<issue>` after issue creation.
Mark only dependency-clear, scoped issues `ready-for-agent`.
Use `status:blocked` for tasks waiting on dependencies.

Use at most four concurrent workers, each with its own branch and worktree.
Workers must not spawn child agents.
Ensure worker bases contain this plan, testing policy and updated agent settings before launch.
Integrate the planning branch through the normal repository publication policy when execution is requested.
Use `gpt-6.1-sol` with medium reasoning by default.
Higher effort follows the project cost rules for bounded difficult work.
Assign one validation owner for expensive baselines and final full runs.
Reuse their evidence; workers run focused checks for their slices.

The supervisor owns `PLAN.md`, the shared coverage inventory and final documentation.
Workers return coverage rows rather than editing that inventory concurrently.
Rebase each implementation branch on `origin/main` before final validation.
Converge through PRs with green applicable checks.
Verify per-task conventional branch selection before launching a batch.
If the orchestrator cannot honor it, scope an orchestration fix before implementation.

## Source map

Core 1.10.5 and CPython 3.12 define the existing helper comparison contract.
Record the installed versions and full upstream commit identities in migration evidence.

| Surface | Reference |
| --- | --- |
| Python module providers | [Core context exports](https://github.com/dbt-labs/dbt-core/blob/v1.10.5/core/dbt/context/base.py) |
| Parse/runtime context wiring | [Core providers](https://github.com/dbt-labs/dbt-core/blob/v1.10.5/core/dbt/context/providers.py) |
| Project and macro parsing | [Core manifest loader](https://github.com/dbt-labs/dbt-core/blob/v1.10.5/core/dbt/parser/manifest.py) |
| Upstream functional distribution | [Core CI](https://github.com/dbt-labs/dbt-core/blob/v1.10.5/.github/workflows/main.yml) |
| Native testing reference | [dbt native contribution guide](https://github.com/dbt-labs/dbt/blob/main/CONTRIBUTING.md) |
| Candidate engine requirements | [dbt v2 supported features](https://docs.getdbt.com/docs/dbt/supported-features) |
| Candidate migration differences | [dbt v2 upgrade preparation](https://docs.getdbt.com/guides/prepare-v2-upgrade?step=1) |

Fusion is a testing/architecture reference, not the oracle for these migrations.
Keep complete published artifact schemas and the declared Core contract.

## Task queue

| Task | Result | Route | Priority | Depends on | Suggested branch |
| --- | --- | --- | --- | --- | --- |
| 1 | Assertion inventory and matched baseline | `role:mapper` | p1 | None | `perf/test-coverage-inventory` |
| 2 | Reusable native fixtures and focused execution | `role:worker` | p1 | 1 | `test/native-helper-fixtures` |
| 3 | Native regex case coverage | `role:worker` | p1 | 2 | `test/native-regex-contracts` |
| 4 | Native itertools case coverage | `role:worker` | p1 | 2 | `test/native-itertools-contracts` |
| 5 | Native datetime case coverage | `role:worker` | p1 | 2 | `test/native-datetime-contracts` |
| 6 | Native pytz and timezone case coverage | `role:worker` | p1 | 5 | `test/native-timezone-contracts` |
| 7 | Bounded tasks for remaining pure helper cases | `role:mapper` | p2 | 1, 2 | `perf/map-remaining-helper-tests` |
| 8 | Smaller, explicit Core integration suite | `role:worker` | p1 | 3, 4, 5, 6; scoped children of 7 | `test/focused-core-oracles` |
| 9 | One verified native build per test job | `role:worker` | p2 | 8 | `perf/reuse-test-binaries` |
| 10 | Isolated parallel integration execution | `role:worker` | p1 | 9 | `ci/parallel-compatibility-tests` |
| 11 | Coverage and performance acceptance | `role:supervisor` | p1 | 10 | `docs/test-optimization-results` |
| 12 | Repeatable upstream version upgrade process | `role:worker` | p2 | 8 | `test/versioned-dbt-upgrade-checks` |
| 13 | Fusion compatibility assessment | `role:researcher` | p2 | 1 | `docs/fusion-compatibility-assessment` |

Use `type:research` for mapping tasks and `type:ci` for build/distribution tasks.
Migration tasks use `type:compat`, `area:compiler-jinja` and `gate:zig-test`.
Keep `gate:dbt-oracle` on migrations that replace upstream comparisons.
Mapper tasks return evidence; the supervisor records their durable output.

### 1. Inventory assertions and establish the baseline

Scope: `tests/`, owning `src/project/*.zig` modules, workflows and JUnit reports.
Output: supervisor-owned `docs/TEST_COVERAGE_INVENTORY.md` and ignored timing data.

Classify every collected case as native migration, retained integration, oracle or tooling coverage.
Record its assertions, adapter dependence, upstream evidence and proposed replacement.
Identify actual CLI checks separately from `dbtRunner` calls and recorded expectations.
Distinguish an unneeded adapter dimension from a genuinely different adapter contract.
Measure build, setup, native execution, Core invocation and artifact validation separately.
Reuse historical reports before scheduling another full baseline.

Acceptance: every collected case has a disposition and owner.
Record exact source, tool versions, runner resources, counts and repeated representative timings.
Stop before test deletion or claims that native and Python counts must match.

### 2. Reuse native fixtures and enable focused execution

Scope: `build.zig`, native test roots and shared test fixtures identified by task 1.
Freeze the exact shared file ownership before launching migration workers.

Reuse existing inline Zig fixtures and `zig build test` first.
Add test-only fixture support only where it removes repeated setup.
Add focused test groups or filtering only if the existing build cannot isolate relevant tests.
Document the actual Zig 0.16.0 commands after implementation.

Acceptance: focused and full native runs exercise the same product code and cases.
Include deterministic failure messages with fixture identities.
Validate Debug and ReleaseSafe behavior where optimization affects the contract.
Stop before product refactors, broad dependencies or a second expression implementation.

### 3. Migrate regex contracts to native Zig

Scope: `src/project/regex_context.zig`, `regex_pattern.zig`, `regex_engine.zig`,
`regex_enum_cache.zig` and `tests/test_usability_regex.py`.

Port table-driven success and failure cases using pinned Core expected behavior.
Cover flags, Unicode, capture groups, methods, callbacks and invalid patterns.
Retain integration cases that prove macro callbacks and context wiring.

Acceptance: the inventory maps every removed assertion to executable native coverage.
Run focused Zig tests and the retained Core comparisons before deletion.
Record actual Core CLI provenance for expected fixtures and preserve the retained command boundary checks.
Stop if a case requires another worker's shared compiler or expression files.

### 4. Migrate itertools contracts to native Zig

Scope: `src/project/itertools_context.zig` and `tests/test_usability_itertools.py`.

Cover constructors, aliases, consumption, exhaustion, tee sharing, growth and errors.
Preserve CPython 3.12 identity behavior and independently sourced expected values.
Retain compiler integration for authored callbacks and macro bindings.

Acceptance: old iterator assertions map to native cases or retained boundary checks.
Run focused Zig tests and the selected Core callback checks.
Stop before editing shared expression or compiler helpers without a sequenced child task.

### 5. Migrate datetime contracts to native Zig

Scope: datetime owner modules and datetime, public API, strptime and temporal Python test families.
Exclude timezone provider files owned by task 6.

Map exact files from task 1 before claiming this task.
Split into non-overlapping child issues when constructors, parsing and protocol methods need separate diffs.
Cover extrema, rounding, overflow, descriptors, named tuples and invalid arguments.
Use explicit clocks and timezone inputs where supported.
Retain command/context tests for observable host clock and timezone behavior.

Acceptance: native cases preserve values, types, identity and error behavior.
Restore any process-global clock or timezone state modified by tests.
Stop before changing product semantics to simplify fixture setup.

### 6. Migrate pytz and timezone contracts to native Zig

Scope: `src/project/timezone_context.zig`, `timezone_builtin.zig`, related timezone owners
and `tests/test_usability_pytz.py`.

Cover pinned exports, historical offsets, gaps, folds, localization and normalization.
Keep pinned IANA/pytz provenance and timezone integration representatives.
Sequence shared datetime file changes after task 5; do not overlap ownership.

Acceptance: native replacements preserve historical and typed timezone assertions.
Run selected Core comparisons under the declared canonical Python runtime.
Stop before updating timezone data or dependency versions.

### 7. Split the remaining pure helper migrations

Scope: inventory entries outside tasks 3 through 6.
Output: child issue scopes and supervisor-owned inventory updates.

Prioritize expressions, filters, mapping/sequence identity, YAML and deterministic context helpers.
Choose one owner module or one tightly coupled module family per child issue.
Reuse existing native coverage before adding cases.

Acceptance: each child names exact files, removed assertions and retained integration boundaries.
Children follow tasks 3 through 6's native-first acceptance rules.
Stop before launching a worker for an unbounded whole-suite rewrite.

### 8. Consolidate the retained Core oracles

Scope: shared Core fixtures, `tests/conftest.py`, integration modules and oracle tooling.
Assign exact shared files after migration workers finish using them.

Keep actual CLI placement, warning isolation, parse/runtime phases, artifact schemas and adapter lifecycles.
Retain real dxt-versus-dbt subprocess execution for every claimed command family and relevant lifecycle boundary.
Remove adapter multiplication only for cases proven adapter-independent by the inventory.
Batch independent positive comparisons when each result remains identifiable.
Keep failure, transaction, identity and stateful sequences separate where batching changes behavior.
Capture expected fixtures through pinned Core, never through dxt.

Acceptance: retained boundary coverage plus native replacements cover every inventory assertion.
Fixture provenance includes exact versions, source identity and a regeneration procedure.
Revalidate the recorded upstream expectations through real CLI execution before certifying the migrated source.
Run focused real Core checks, including warning/deprecation isolation.
Stop before replacing warehouse or artifact evidence with constants.

### 9. Reuse verified native builds across integration modules

Scope: build fixtures in `tests/test_cli.py`, adapter/helper fixtures and CI build setup.

Replace repeated module builds with verified job-scoped binaries where the profile shows a benefit.
Keep clean-build certification in its dedicated gate.
Verify source, Zig version, target and optimization mode before reusing a binary.

Acceptance: unchanged input reuses binaries; changed or missing input triggers the required build.
Measure the setup delta and retain native test, packaging and runtime-boundary gates.
Stop if caching hides a build failure or accepts a binary from another source.

### 10. Distribute integration cases across isolated processes

Scope: `.github/workflows/ci.yml`, pytest distribution, fixture isolation and report validation.

The current distribution slice above implements this independently of test
migration and shared-build changes. Whole-module isolation preserves existing
fixtures; task 9's build consolidation remains later work.

Use process isolation for Core globals; size concurrency to measured CPU and memory resources.
Use CI shards where one runner remains the bottleneck.
Isolate database directories, schemas, ports, binary installs, logs and target paths.
Keep resource-sensitive tests serialized within their required group.
Do not assume the default Zig test runner executes individual native tests concurrently.

Acceptance: collection equals the union of executed shard cases, with no gaps or duplicates.
Fail the aggregate gate on missing reports, failed workers, errors, skips or xfail cases.
Preserve `test py3.12` and other required check names through aggregate jobs where needed.
Keep complete applicable evidence on actual Linux x86_64 and ARM64.
Measure 1, 2 and 4 local workers before increasing concurrency further.
Stop if a faster run changes results or exceeds runner resources.

### 11. Prove coverage and runtime improvements

Scope: final inventory, `PLAN.md`, validation/development docs and performance results.
The designated validation owner runs the full applicable gates once on the integrated source.

Verify the combined native, integration and oracle coverage against the inventory.
Compare matched runner measurements, separating setup, build and execution time.
Retain unchanged Jaffle, dbt-utils, archive installation, safety and product performance gates.
Document measured results and reproducible local commands.
Keep historical acceptance counts in `VALIDATION.md` unchanged.

Acceptance: no supported behavior loses coverage, and both actual architectures pass applicable checks.
Trial targets: a native developer gate under five minutes and full CI under thirty minutes.
These are targets, not promised results; task 1 sets matched measurement conditions.
Record any missed target and its remaining bottleneck rather than dropping tests to pass.

### 12. Prepare repeatable upstream release upgrades

Scope: developer oracle tooling, version pins, embedded upstream macros, schemas and upgrade documentation.
Sequence shared fixture edits after task 8.
Create bounded child issues when version metadata and differential execution need separate ownership.

Reuse existing version checks and CLI certificates before introducing shared contract metadata.
Record engine/version, full source identity, adapters, Python runtime, schema versions and fixture provenance.
Keep accepted and candidate environments isolated, with explicit CLI executable paths.
Reject missing or mismatched upstream executables rather than silently skipping comparisons.

Evaluate a nominated release through this sequence:

1. Inspect upstream release notes, source changes, adapter support, schemas and bundled macros.
2. Run accepted upstream, candidate upstream and dxt against the same applicable fixtures.
3. Classify differences as an upstream change, a dxt regression, an intentional difference or unsupported scope.
4. Create bounded Agent OS issues for observed changes, with native Zig regressions and retained CLI checks.
5. Regenerate expected fixtures from the candidate CLI and retain their source/version provenance.
6. Run applicable CLI, artifact, adapter, public-project, archive and actual-platform acceptance.
7. Update accepted pins, embedded assets and public support claims only after candidate certification passes.

Candidate detection may propose an upgrade issue; it must not silently replace accepted pins.
Preserve the declared baseline during candidate evaluation.
Supporting multiple conflicting behavior contracts requires an explicit version-selection design.

Acceptance: the procedure identifies baseline-versus-candidate differences and reproduces upstream fixture provenance.
Expected changes become scoped issues; a failed or incomplete candidate cannot be recorded as supported.
Document the actual commands after tooling exists.
Stop before a blanket dependency bump or implementation of an unscoped new engine contract.

### 13. Assess the Fusion replacement boundary

Scope: published engine features, pinned source/binary identities, dxt ownership and compatibility evidence.
This is research and planning; product changes and Fusion certification are separate child scopes.

Record the exact engine distribution and release being assessed, including any dbt v2 naming changes.
Map overlapping CLI commands, project/Jinja semantics, adapters, artifacts, SQL analysis and lineage.
Separate editor/LSP and platform features from CLI engine behavior.
Classify each surface as Core-certified overlap, dxt-only evidence, unverified Fusion behavior or unsupported scope.

Propose real Fusion CLI comparisons for mutually supported adapters and unchanged fixtures.
Keep Core and Fusion results separate when their behavior differs.
Require a declared target-version policy before implementing incompatible behavior.
Use native Zig regressions for any later product changes.

Acceptance: a public-safe matrix names evidence, gaps and bounded certification tasks.
Source resemblance or shared feature names cannot count as binary parity.
Stop before claiming a complete Fusion replacement or silently replacing the Core oracle.

## Deferred decisions

Worker/shard counts need measured CPU, memory and isolation evidence.
The exact deletions and native groups depend on task 1's inventory.
The runtime targets have low confidence until representative trials run.
Changing CI frequency or platform coverage requires a separate scope decision.
Candidate upstream versions and a Fusion support target remain open choices.
Task 12 prepares an upgrade process; task 13 defines the evidence needed for a separate Fusion contract.

## Resume prompt

```text
Read AGENTS.md, PLAN.md and docs/TEST_OPTIMIZATION_PLAN.md on perf/native-test-suite.
Make the planning branch's policy and agent settings available on worker bases before launch.
Use Agent OS to create or reuse the scoped task issues and execute their dependency order.
Always prefer native Zig tests. Preserve mapped assertions and required integration evidence.
Retain actual dbt CLI acceptance and versioned fixture provenance.
Use gpt-6.1-sol and each role's declared reasoning effort, at most four workers and isolated worktrees.
Assign one owner for expensive validation. Start with task 1; do not launch blocked migrations.
Prepare the upgrade process without changing certified pins. Keep Fusion assessment separate from Core certification.
Follow the repository's publication policy when creating implementation PRs.
```

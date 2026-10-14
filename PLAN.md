# dxt ExecPlan

## Product Contract

dxt means **Data eXecution & Transformation**. It is an independent,
dbt-project-compatible transformation engine with a native Zig product runtime.
Compatibility is an observed contract against pinned upstream behavior and
complete applicable artifact schemas. Public wording must not imply dbt Labs
affiliation or universal dbt certification.

The initial execution contract is **SQL models on DuckDB and PostgreSQL,
Linux x86_64 and ARM64**. Python resources may be discovered, parsed, selected
and compiled; execution rejects authored Python before warehouse writes.
End users do not need a Python interpreter, dbt or MetricFlow.

The product CLI, parser, compiler, artifacts, planner, adapters and execution
remain Zig. Python is limited to developer scripts, tests, fixtures,
compatibility oracles and release/safety tooling. The toolchain is Zig
**0.16.0**. See [AGENTS.md](AGENTS.md) for engineering and ownership rules.

## Current State

The initial eight Core and four native feature tracks are implemented and
merged. Their scope is recorded in the
[compatibility matrix](docs/COMPATIBILITY.md) and
[replacement roadmap](docs/DBT_REPLACEMENT_ROADMAP.md).

The accepted initial candidate was source commit
`2b761f2c11419ce9316e5dd1226b1c24aee77ac3`, tree
`abb47b1d72c9d66bb90ed8752a03f8d789b3c9a2`. Its acceptance included:

- 817 native tests on each actual Linux architecture.
- 5,819 canonical compatibility cases on each architecture, with zero
  failures, errors, skips or xfail cases.
- All six unchanged Jaffle steps and seven unchanged Native/Core command
  pairs for the PostgreSQL dbt-utils project.
- Deterministic archives, actual both-adapter installation with PATH empty,
  the original wide PostgreSQL seed and correctness-aware performance checks.
- All applicable CI, safety and runtime-boundary gates.

The [original CI run](https://github.com/sabino/dxt/actions/runs/38082038493)
and [sealed-report audit](https://github.com/sabino/dxt/actions/runs/38094876370)
retain this historical evidence. Counts overlap and must not be added into
a distinct-test total. These results describe that source; later candidates
need their applicable checks.

**dxt is not production ready.** Initial compatibility acceptance does not
establish broad real-project operational readiness. Additional adapters,
remote provider integrations, platforms and newer upstream contracts need
separate implementation and certification.

## Active Work

### Automatic Release Downloads

The user requested automatic GitHub Release downloads and PR-only full testing.
One editing owner uses `ci/automatic-release-assets` in an isolated worktree.
Scope: release/CI workflows, developer-only release qualification and archive
checks, Linux/macOS packaging, focused tooling regressions and startup/release
documentation. The user also requested a curl-based installer: verify SHA256
before extraction, select the native target/version, stage before replacing an
existing executable and document Linux's driver requirements. Product runtime
behavior and upstream pins remain unchanged.

Full CI runs on pull requests, not again after merging into main. A final CI
certificate records the tested source tree only after every applicable job
passes. Release tags and published releases must match that tree and version;
failed, missing, expired or mismatched evidence blocks publication. Release jobs
build and certify the actual archives without repeating the full Core suite.
Manual release runs remain dry by default. Publish Linux x86_64/ARM64 and
experimental standalone macOS Apple Silicon/Intel archives only after their
actual native runner and both-adapter installation gates pass. Windows is
excluded: the current cross-build fails in the vendored SQL parser on Unix
headers. Linux archives retain their documented external driver requirements.

Validation: source-qualification failure cases, Mach-O architecture/dependency
checks, checksum-before-extraction and deterministic archive regressions;
Actionlint, runtime-boundary/public-safety scans and actual bundled macOS
archive installation with both adapters and empty executable PATH. Preserve
the complete sharded PR acceptance and native/Linux installation gates. Final
PR validation must exercise the new macOS runners before support claims are
promoted. Tags and release publication require separate authorization.

PR #243's Intel gate exposed a Zig 0.16 LLVM crash when embedding compiler
support routines in the Debug native test object. A trial using Zig's x86
backend compiled and ran all 866 tests but decoded a half-precision float
incorrectly (865 passed, one failed). Keep LLVM and compile the same pinned
compiler support source as a separate ReleaseSafe static library only for
Intel Mac Debug objects. The complete test binary links locally without the
LLVM crash. Preserve numeric ABI, Debug runtime checks, all assertions and
the release build path; introduce no runtime dependency or compiler upgrade.
Scope includes this narrow build/link setting. Cancel superseded CI; require
every actual-platform PR gate on the corrected source. Final status/evidence
is tracked on PR #243, keeping the validated source frozen through merge.

Status: locally implemented; PR CI remains pending. Actionlint, shell syntax, runtime-boundary and
public-safety checks pass. All 140 combined release/safety/installer tooling
cases pass without skips. Both Mac architectures build and package; the
extracted Apple Silicon archive passes both live
adapters with PATH empty using only declared release-validation dependencies;
invalid external driver overrides are cleared. A native Mac installer trial
preserves the exact archive binary bytes and runs with PATH empty. Its GitHub
downloads are supplied by a local transport fixture until a release exists.
The Intel Mac ReleaseSafe
cross-build passes; actual Intel execution and final Linux/Mac runner acceptance
remain PR gates. No tag or GitHub Release has been created.

Review of the current main source passed
866 native tests and 183 new Core/native integration cases on Apple Silicon;
the identical merged source passed all Linux CI gates, including 6,137 cases
on each actual architecture. Those results describe the reviewed source, not
this release-workflow change. A numeric date-token rejection mismatch found
during review is a separate product compatibility issue.

### Delivered Issue Campaign

The user authorized implementation of every currently open repository issue,
one at a time, followed by one integration PR. The supervisor owns
`fix/remaining-issue-backlog`, this plan, support documentation, public issue
coordination and final validation. The starting inventory contains four issues: contract-breaking
state diagnostics, PostgreSQL connection retries, cross-database catalog
retention and free-form model deprecation dates. No open PR overlaps this batch.

Read-only specialists first map exact upstream references, owner modules,
fixtures and stop conditions. An implementation claim follows the recorded
mapping; research-only issue restrictions are satisfied through that gate.
Each editing worker then uses its own branch and worktree. Workers do not
spawn child agents. Only the supervisor runs expensive integrated validation.
The state owner also owns the narrow `compile_diagnostics.zig` phase mapping
for Core's versioned contract error; other diagnostic phases are unchanged.

| Order | Worker branch | Exclusive ownership | Current status |
| --- | --- | --- | --- |
| 1 | `fix/state-contract-diagnostics` | State/selector diagnostic owners and new contract-state CLI fixtures | Integrated with reviewed inline artifact correction; local evidence on the issue |
| 2 | `fix/postgres-connection-retries` | PostgreSQL profile/session retry owners and new connection-retry fixtures | Integrated; 9 focused native and 33 actual Core/native cases passed |
| 3 | `fix/cross-catalog-retention` | Cross-database catalog retention and new catalog CLI fixtures | Integrated; native cap/expiry and bidirectional actual warehouse checks passed |
| 4 | `fix/textual-deprecation-dates` | Properties/date normalization and new authored-date oracle fixtures | Integrated; 4 focused native and 54 Core/native date/context cases passed |
| 5 | `fix/nested-contract-state-diagnostics` | State-leaf detection in selector.zig and nested YAML cases in the contract-state fixture | Integrated; 2 native additions and 26 focused CLI cases passed; targeted review clear |

The supervisor integrates each clean, validated worker commit through Git
before launching the next implementation. Existing shared fixtures and the
project facade have one writer at a time; exact ownership is recorded in the
issue claim before edits. Support documentation belongs to the supervisor.
Native test optimization remains deferred; sharding distributes unchanged
acceptance assertions and does not authorize deleting them. The supervisor
also maintains the four new module scheduling weights after reviewing focused
JUnit case durations, keeping local sample provenance separate from historical
both-architecture CI measurements. Scheduling weights never establish acceptance.

Acceptance requires native positive/negative cases near each Zig owner, real
pinned Core/native CLI comparisons for upstream behavior, deterministic actual
PostgreSQL connection fault fixtures, and actual cross-database catalog
publication/estimate checks. Preserve artifacts on state preflight failure;
retry connection establishment only, never SQL or uncertain commits. Bound
catalog statistics without weakening binding, expiry or unknown-estimate
safeguards. Define textual date grammar and defaults before implementation;
do not claim general dateutil compatibility from a few examples.

Final validation runs on a frozen integrated source: Debug/ReleaseSafe builds,
native tests, affected CLI/oracle suites, runtime-boundary/public-safety and
diff checks, plus all applicable CI gates including eight canonical shards per
actual Linux architecture and their complete evidence aggregate. Rebase on
current main before final validation. No skip, xfail, assertion removal,
upstream pin change or unsupported-platform certification is authorized.

Stop and remap an overlapping owner, unsupported adapter, broader recovery
redesign, ambiguous upstream/default-date policy or unrelated behavior change.
Resolve routine implementation choices within the user's authorization.

The unchanged CLI build fixture certifies a clean Debug build and complete
native test run; reuse that frozen-source evidence within the integrated
validation session. A draft integration PR may run the CI matrix concurrently
with the supervisor's affected CLI suites. Keep the same source frozen and
mark the PR ready only after both local and CI gates pass. The
end state is one non-draft, green integration PR with issue evidence and
handoffs; merging, tags and release publication remain separate actions.

Status: merged as PR #242; all four issues are closed. Its final source passed
all 29 CI checks, 866 native tests and 6,137 canonical cases on each actual
Linux architecture. The checkpoints below retain the implementation evidence.
The first issue has a published reference map, slice plan and claim;
its isolated worker passed 33 focused native and 78 real Core/native cases.
The state commits are integrated after root review corrected inline authored
manifest publication. Additional targeted and unchanged inline/show checks
passed; those counts overlap the original module and are not additive.
PostgreSQL retries are integrated through both native entry points, including
Core's separate profile-shape/open-limit validation. The final real-server
module passed 33 cases without skips/xfails; 9 distinct focused native cases
also passed. Connection policy leaves physical identity and SQL/task retries
unchanged. Catalog retention is integrated after reproducing the exhausted
catalog failure following successful warehouse commits. Six focused native
cases and bidirectional actual warehouse cap/expiry/replacement/unknown-budget
checks passed; existing catalog/concurrent-writer/movement cases are retained.
The date helper is integrated after review preserved existing low ISO years.
Its bounded complete-date grammar excludes dateutil's clock-dependent partial
defaults. The final worker source passed 4 focused native cases and 54 real
Core/native cases: 40 new authored-date fixtures and 14 retained context/state
cases, with zero skips/xfails. Scheduling weights use successful local JUnit
case durations with explicit unsealed/mixed-snapshot provenance where applicable.
All four implementations are integrated. Independent PR review found that
nested named YAML exclusions lower to negated state leaves that bypass state
loading and contract preflight. The final sequential worker reproduced actual
native artifact/warehouse changes where Core rejected the contract break,
then corrected state/contract dependency detection. Two native additions and
26 focused CLI cases passed, including 14 new nested YAML regressions; targeted
read-only review is clear. Existing 90 contract cases and selector lowering
remain unchanged. The complete contract module now contains 104 cases.
The initial candidate's CI is superseded; final acceptance uses the corrected
head and preserves all assertions. Complete frozen integrated/platform
acceptance passed for PR #242. Its results and final
handoff belong on the integration PR and linked issues; local slice evidence
does not itself establish source or release acceptance.

### Delivered Parallel Compatibility Validation

The requested test acceleration is merged into main. Its original owner used
`ci/parallel-compatibility-tests` in an isolated worktree. The current issue
campaign uses the delivered distribution and evidence audit without changing
their required assertions or acceptance policy.

Distribute the unchanged canonical suite across eight independent GitHub
runners per actual Linux architecture, balancing complete test modules using
historical JUnit timings. Keep module fixtures and case order intact, and avoid
sharing Core globals, warehouse state or binary installations across runners.
Preserve the required `test py3.12` check name through aggregate acceptance.
The Python 3.11 developer gate and native, installation, public-project,
performance and safety gates remain applicable.

Scope: CI scheduling, developer-only pytest shard selection and report
validation, timing weights, tooling regressions and test documentation.
Every runner collects the full suite before assigning modules; acceptance
requires matching collections and source identities, a disjoint complete
assignment, all expected reports and an individually passing JUnit case for
each collected node ID. Missing, duplicate, skipped, xfailed or failed evidence
must fail the aggregate. Do not delete assertions or change product behavior,
upstream pins or supported-platform claims.

Recent baseline run `38219109929` has 5,916 passing cases per architecture.
Summed case times are 12,735 seconds on x86_64 and 12,335 seconds on ARM64.
Its largest complete module costs about twelve minutes, so balancing modules
can reduce elapsed time without splitting their shared fixtures. Timings guide
scheduling only; they never determine which cases are required.

Validation: adversarial report/assignment tests, real pytest subprocesses with
1/2/4 isolated processes, full collection and predicted balance against both
historical reports, and representative real native/Core comparisons. Preserve
the complete both-architecture CI gate for final acceptance. Document measured
local results separately from projected CI time and increased runner-minute
cost. Native helper migrations remain separate later work; distribution of
unchanged assertions does not depend on those migrations.

Status: distribution and evidence audit merged. Recorded local validation:
Actionlint passes;
full collection contains 5,954 cases, including 38 new distribution-tooling
regressions. A fixed 67-case native/Core trial passes with 1/2/4 isolated
processes in 39.70/25.71/18.01 seconds, with complete disjoint JUnit evidence and
zero skips or xfails. Timing excludes initial builds and plan collection.
The eight-shard historical estimate is 27.4 minutes before CI setup/queues;
the full both-architecture CI trial remains required before merge.

### Delivered macOS Native Runtime And Getting Started

The experimental source-build slice is merged into main. Its original local
editing owner used `fix/macos-native-runtime`. The initial Linux acceptance
contract stays intact; macOS source builds remain an experimental development
target until their complete platform gates are certified.

The observed Apple Silicon build can run version/help/init, but project
discovery terminates with SIGSYS because it invokes Linux directory syscalls.
The slice adds a native platform boundary for directory discovery and process
identity, uses platform-specific database library discovery, and documents a
checksum-verified, Python-free local macOS setup. Keep the existing Linux
directory backend and resource/ignore/symlink behavior. Preserve explicit
library override precedence and adapter error handling. The user's clarified
distribution goal permits build-time C/C++ dependencies while the executable
should run without separately installed database client libraries.

Scope: `src/project/fs.zig`, focused native platform/library helpers,
`parse_cache.zig`, `workflow.zig`, native adapter library loading and the shared
cross-database symbol lookup boundary, build options
and pinned native dependencies, setup tooling, notices, README and relevant
architecture/platform/startup docs. Windows library names
may be described or factored without claiming Windows execution support.
Assess and implement static DuckDB/client linking where the pinned native
sources and TLS dependencies can be built and verified. PostgreSQL servers
remain user-provided; only the libpq client belongs in the executable.
Replacing the PostgreSQL wire protocol, package transport rewrites and new
adapter/upstream contracts are deferred. Keep the existing dynamic-driver
build available for compatibility gates and isolate any unverified bundling
limitation rather than silently disabling encryption or authentication.

Validation: native positive/negative discovery and library policy tests;
Debug/ReleaseSafe builds and native tests on the actual Apple Silicon host;
real scaffold parse/list/compile/build/repeated-build/tests/static-docs and
cache reuse with native DuckDB and no executable PATH; supported Linux cross
builds; formatting, runtime-boundary and public-safety scans. Exercise native
PostgreSQL if a disposable local fixture is available, and state any missing
platform/adapter evidence explicitly. Do not open a browser or install global
packages/services. Keep downloaded tools, fixtures and logs ignored.

Status: merged and locally validated on Apple Silicon. The setup helper
builds `zig-out/bin/dxt` with the bundled drivers; ordinary installation emits
one executable. No published macOS archive or full macOS Core certification
is claimed. Published release archives and complete platform certification
remain separate gates.

Local evidence for this slice:

- 842 native tests pass in each dynamic and bundled Debug configuration, with
  no skips. The CSV fixture uses an in-memory database so bundling does not
  leave a warehouse file in the checkout.
- The checksum-verified setup helper completes a ReleaseSafe standalone build.
  Its executable is 50.69 MiB, or 17.25 MiB gzip, and links only macOS
  `libSystem` and `libc++`. A binary scan finds no local user path.
- With PATH empty and driver overrides absent, scaffold init, parse, list,
  debug, compile, build, repeated build, tests and static docs all succeed.
  Same-version DuckDB overrides work; a 1.5.6 override fails with a clear
  version-conflict diagnostic before execution.
  A copied executable also builds a scaffold outside the source checkout with
  PATH empty; installed workflows do not read the native build packages.
- The bundled client executes PostgreSQL debug/compile/run against a disposable
  PostgreSQL 16.2 fixture with SCRAM authentication; independent native psql
  verifies the result. A developer TLS terminator forwards to that real server:
  the embedded client negotiates TLS 1.3 with `verify-full`, and rejects a wrong
  hostname and wrong password. This is client/TLS evidence, not server packaging
  or enterprise authentication certification.
- Actual typed movement succeeds in both PostgreSQL-to-DuckDB and
  DuckDB-to-PostgreSQL directions, preserving bigint, decimal, date, binary and
  quoted text values. Product processes run with PATH empty.
- Linux x86_64/ARM64 ReleaseSafe cross builds and the Intel macOS 13.0 bundled
  cross build succeed. Intel execution and actual Linux runtime retesting have
  not occurred on this Mac.
- Runtime-boundary, public-safety, formatting and diff checks pass. Existing
  Core CLI oracles remain intact; no new macOS Core acceptance claim is made.

Build investigation: Zig 0.16's Mach-O linker rejects relocations in the
official DuckDB static archives and crashes on a ReleaseSafe adapter driver.
macOS builds compile product and C sources with Zig, then use Apple's SDK
linker. Their archive bridge preserves
every C object, including duplicate member names, while restoring the alignment
required by Apple's linker. This tooling is excluded from product installation.

Candidate versions checked separately: Zig 0.17.0 was released on October 1,
2026; a trial fails at changed build APIs before product compilation. Its
removal of `@cImport` also requires a C binding migration. DuckDB 1.5.6 is an
upgrade candidate, not the accepted database contract. Spatial issue #794 was
resolved by refreshing development sources with generated geometry helpers;
it does not require adding spatial to dxt. Keep both accepted pins while
collecting candidate evidence and record migration scope before an upgrade.
In a separate dynamic-only adapter driver, DuckDB 1.4.2 and 1.5.6 each pass
eight identical exercises: conformance, result ownership, pooling, relation
cache, parallel cache, binding, read-only binding and cancellation. Actual
library-version queries confirm the candidates. This focused evidence does
not replace the complete dbt/extension/storage upgrade gates.

Static-provider checks found two independent collision boundaries. The SQL
grammar is based on PostgreSQL 17.7 and the client package uses 18.4. Their
overlapping private helper and keyword symbols must be namespaced; matching
version strings alone would not reconcile frontend/backend build settings.
The grammar's observed behavior stays pinned. The available Zig-compatible
libpq build package pins 18.4; aligning it to 17.7 would require maintaining a
different native build package, while changing the grammar requires its own
artifact/SQL compatibility slice. Loading a second DuckDB version
alongside the embedded C++ library also causes Mach-O weak-symbol mixing;
bundled overrides now require the exact embedded version and fail before
opening a database otherwise. Upgrade trials use a separate dynamic-driver
build. These constraints and pins must be explicit in startup documentation.

### SQL Compatibility And Native Publication Hardening

The completed implementation batch is tracked by
[#225](https://github.com/sabino/dxt/issues/225). Read-only inspection found
concrete gaps in delivered behavior despite the completed initial track ladder.
The batch preserves the pinned Core/platform contract and all existing gates.

| Owner branch | Issues | Exclusive scope | Sequencing |
| --- | --- | --- | --- |
| `fix/state-resource-comparisons` | #226 | State, properties, model versions, manifest, macro context and state CLI fixtures | Model reference metadata and semantic resource comparisons; one writer |
| `fix/postgres-profile-compatibility` | #227, #228 | Profile/native PostgreSQL/adapter session policy, incremental strategy owners, new focused fixture files | Profile/session changes first, custom strategies second; one writer |
| `fix/native-publication-recovery` | #229, #230 | `workflow.zig`, workflow fixtures, `cross_database.zig` native publication tests | Committed apply reconciliation first, unique publication files second; one writer |
| `fix/workflow-postgres-identity` | #238 | `workflow.zig`, workflow fixtures | Follows the completed publication branch; preserves actual legacy default-prefix identity and binds effective roles |
| `fix/dbt-state-compatibility` | #225 | This plan, support evidence and PR convergence | Supervisor integrates scoped worker PRs; owns expensive final validation |

Every editing owner uses an isolated worktree. State, execution and publication
owners have disjoint product modules and fixture files. The actual authored-date
oracle revealed that dxt omitted this field before comparison, requiring the
narrow parser/artifact extension. Existing node properties and generic cache
encoding carry the field without changing shared types or cache codecs.
Preserve Core's separate unversioned/versioned date scopes, normalization,
validation and warm-cache invalidation. Execution alone changes the facade
`src/project.zig`, removing the two eager strategy validations in concurrent
preflight and compilation for #228. No mechanical extraction is part of these
behavior changes.
Workers do not spawn child agents. Issues carry the reference and slice plans;
Project synchronization is unavailable through the current GitHub CLI access,
so issues and PRs retain coordination state without claiming a board update.

Execution and metadata regression suites run against frozen snapshots so
their source cannot change during collection or native fixture builds. A
read-only metadata validation helper reports to the integration owner.

Acceptance requires native positive/negative regressions, actual pinned Core
CLI comparisons for compatibility changes, and real DuckDB/PostgreSQL fault
fixtures for workflow recovery. The integration owner runs the native suite,
focused state/semantic/profile/incremental/workflow/cross-database checks,
runtime-boundary/public-safety scans and applicable CI. Scoped implementation
PRs converge into one user-facing integration PR targeting `main`.

Stop for unsupported adapters, authored Python execution, upstream upgrades,
Fusion certification, unrelated compiler changes or an owner overlap. Preserve
Core's intentionally ignored metric/query fields and new-resource state rules.
Retries after committed workflow publication failures must not replay database
writes, audits or events. Temporary publication cleanup must remove only the
current writer's file. Contract-breaking state diagnostics, connection retries
and catalog retention remain separate observed follow-ups.

Workflow recovery stores an optional successful `committed_apply` result in
the environment and its revision history within the original transaction.
Rollback restores that evidence; promotion clears source-environment apply
identity. Older payloads default to no embedded evidence and may recover from
one matching validated event. Ambiguous historical events fail visibly rather
than selecting an arbitrary run. This is an additive native metadata field,
with no dbt artifact schema or warehouse table migration.

Integration reproduced a PostgreSQL workflow upgrade blocker: changing the
implicit application attribution default stranded old gateway/model hashes,
while an effective role change was absent from those hashes. #238 canonicalizes
only the exact native default prefix for workflow identity and binds nonempty
effective role separately. Preserve all other conninfo bytes and explicit
policy changes; cross-database profile identities remain unchanged. The
publication owner switches to a new isolated branch after its prior clean PR.

Status: all six fixes merged into `main` through #240. The final
runtime candidate passed 836 native tests, Debug/ReleaseSafe builds and all
24 workflow cases. Frozen integration snapshots passed 276 execution cases
and 336 metadata/state cases; the final workflow recheck overlaps 22 of those
execution cases. All reported local cases passed without skips or xfails.
Formatting, runtime-boundary and public-safety gates passed. The complete
CI/platform matrix remains candidate acceptance evidence.
No release or production-readiness claim changes.

The observed follow-ups tracked as
[#231](https://github.com/sabino/dxt/issues/231),
[#232](https://github.com/sabino/dxt/issues/232) and
[#233](https://github.com/sabino/dxt/issues/233) and
[#237](https://github.com/sabino/dxt/issues/237) are implemented in the
remaining open issue campaign above; its final combined acceptance is separate.
The native test optimization queue below remains deferred and is not part of
this product-correctness batch.

### Deferred Native Test Optimization

Prepare the native test optimization queue in
[Native test optimization](docs/TEST_OPTIMIZATION_PLAN.md).
Implementation is deferred to a later Agent OS session.
The queue preserves the supported contract while replacing repeated project
compilation with native Zig coverage where the behavior is pure.

Project agent definitions select `gpt-6.1-sol` with medium reasoning by default.
Semantic, architecture, convergence and reflection specialists use high reasoning.
The Agent OS model default matches those definitions.
Python remains developer tooling for independent Core evidence and boundaries.
Real dxt-versus-dbt CLI comparisons remain compatibility acceptance gates.
The queue also prepares an upstream upgrade process and a separate Fusion assessment.

### Sequencing And Ownership

| Phase | Owner | Scope | Status |
| --- | --- | --- | --- |
| Planning and agent settings | Supervisor, `perf/native-test-suite` | This plan, task queue, testing policy and project agent configuration | Prepared; no test migration started |
| Inventory and native foundations | Mapper, supervisor and one scoped worker | Assertion mapping, matched baseline and reusable native fixtures | Task 1 first; foundations depend on its output |
| Native migrations | Separate workers | Regex, itertools, datetime, timezone and remaining mapped module families | Planned; disjoint ownership required |
| Oracle consolidation and distribution | One integration worker | Core boundaries, verified builds, process isolation and CI reports | Planned after relevant migrations |
| Final acceptance | One validation owner and supervisor | Both actual architectures, coverage ledger and measured results | Planned after integration |
| Upstream upgrade process | One scoped tooling worker | Accepted/candidate CLI comparisons, fixture provenance and bounded release-change issues | Task 12; no pin changes authorized by test optimization |
| Fusion assessment | Researcher and supervisor | Versioned engine scope, evidence gaps and later certification tasks | Task 13; no Fusion support claim |

Tasks 3, 4 and 5 can proceed concurrently after shared fixtures are ready.
Task 6 follows task 5 where timezone files depend on datetime owners.
Task 7 produces bounded child issues, not a whole-suite implementation claim.
Shared fixture, compiler and workflow files have one writer at a time.
The supervisor owns the durable coverage inventory and this plan.

GitHub Issues and Projects carry execution state after the next session
creates or reuses the scoped issues. No implementation workers are launched
by this planning change.

### Scope And Acceptance

Always prefer native Zig tests for product behavior, near their owner modules.
Use independent expected values and retain Core checks for observable upstream
behavior. Every removed assertion needs an executable replacement or a retained
boundary check in the coverage inventory.

Preserve actual CLI, artifact schema, adapter lifecycle, public-project,
installation, safety and correctness-aware performance evidence.
Execute real binaries on unchanged inputs at compatibility acceptance.
Revalidate recorded expected fixtures through upstream CLI behavior.
Do not change product semantics, upstream pins, supported platforms or CI
frequency to meet a test runtime target.

Native and Python case counts may change during migration. Coverage is the
mapped behavior; a lower count alone proves neither improvement nor loss.
A distributed run must prove complete collection and execution, with no gaps,
duplicates, failures, errors, skips or xfail cases.

### Validation

For this planning/configuration change:

- Parse all project agent TOML and Agent OS JSON settings.
- Validate project and agent configuration against the official OpenAI schema.
- Run focused Agent OS developer tests and public-safety/runtime-boundary scans.
- Check the diff, references and working tree without running product acceptance.

This planning/configuration PR may merge after fast CI checks pass.
Complete Core comparisons may finish afterward under its merge exception.
Implementation PRs retain their declared compatibility acceptance gates.

Implementation workers use focused native checks first.
One validation owner measures expensive baselines and final full runs.
Actual Linux x86_64 and ARM64 gates remain required for applicable acceptance.
Trial targets are a native developer gate under five minutes and full CI under
thirty minutes. Task 1 sets the measurement conditions; the targets are unproven.

### Risks And Stop Conditions

Stop before deleting an assertion without independent replacement evidence.
Split work when owner modules or shared fixtures overlap.
Keep stateful errors, transactions and identity checks separate when batching
would alter their behavior.
Use isolated processes for Core globals and measure runner CPU/memory limits.
Reject cached binaries from another source, target or toolchain.
Record a missed runtime target instead of weakening coverage to pass it.

### Evidence And Open Choices

The dated task-plan baseline records 5,846 passing Python cases per architecture
from a completed CI run. Five helper families account for about 27% of x86 pytest
time. These observations guide priorities, not a claim that every case is redundant.

Exact native groups, retained cases and worker/shard counts depend on the inventory
and measured trials. Runtime targets have low confidence before those trials.
Candidate upstream versions and Fusion certification targets remain unspecified.
Core parity does not certify Fusion; the assessment must define separate evidence.
Native helper migrations remain deferred. The active distribution slice above
changes CI scheduling and adds developer-tooling tests; existing product and
compatibility assertions remain unchanged.

## Next Roadmap Work

The initial functional ladder has no known unimplemented track. Individual
behaviors still need source-grounded gap checks: the active hardening batch and
its follow-ups above address observed omissions within delivered tracks.
The deferred developer queue reduces validation cost through native tests and
scoped integration execution. Repeatable candidate verification, real-project
rollout evidence and operational hardening remain release priorities. Record
observed failures as bounded slices with owners, source grounding and relevant
tests.

Later scope includes additional native adapters, remote DuckDB integrations,
non-Linux portability and updated upstream version contracts. Each needs a
separate scope, driver/runtime ownership map, deterministic fixtures and actual
warehouse/platform evidence. Authored Python execution is outside the initial
SQL contract; it is not an implied requirement for this cleanup.

## Durable References

- [Primer](docs/PRIMER.md): product interface and development loop.
- [Compatibility](docs/COMPATIBILITY.md): supported behavior and differences.
- [Roadmap](docs/DBT_REPLACEMENT_ROADMAP.md): delivered and later scope.
- [Architecture](docs/ARCHITECTURE.md): native module ownership and data flow.
- [Release process](docs/RELEASES.md): archives, versions and publication gates.
- [Native test optimization](docs/TEST_OPTIMIZATION_PLAN.md): native coverage, CLI acceptance, upgrade process and Fusion assessment tasks.
- [Agent OS](docs/AGENT_OS.md): supervisor, workers and public coordination.
- [Multi-agent workflow](docs/MULTI_AGENT_WORKFLOW.md): isolated branches,
  validation and convergence.
- [Research](.agent/research/): historical source maps and design context;
  earlier slice limitations do not override the current compatibility matrix.

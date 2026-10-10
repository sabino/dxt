# dxt ExecPlan

## Name And Product Contract

`dxt` means **Data eXecution & Transformation**.

The product goal is a dbt-project-compatible transformation engine written in Zig. The first promise is compatibility with dbt Core project semantics and artifacts, not a private or unofficial dbt fork. Fusion-era capabilities, semantic resources, metrics, static analysis, and cross-database planning shape the architecture, but dbt Core compatibility is the required base.

Public wording must avoid implying dbt Labs affiliation.

## Hard Runtime Requirement

`dxt` must be implemented as a native Zig product runtime. The pinned initial toolchain is Zig `0.16.0`.

Python may remain only for developer-side scripts, tests, fixture generation, dbt Core oracle harnesses, artifact comparison, schema validation helpers, and public-safety scans. Python must not implement the product CLI, parser, compiler, artifact writer, runner, planner, adapter layer, or user-facing runtime behavior.

Every user-facing command must run through the Zig binary. CI and local safety checks must reject new Python product-runtime code.

## Objective

Build `dxt` into a practical dbt alternative that can eventually run real public dbt projects, starting with Jaffle Shop variants. It must:

- Build and ship as a fast native Zig binary.
- Parse dbt projects and reproduce graph semantics.
- Compile common dbt SQL/Jinja behavior.
- Execute models, seeds, tests, snapshots, and docs workflows for supported adapters.
- Emit dbt-compatible artifacts such as `manifest.json`, `run_results.json`, `catalog.json`, `sources.json`, and `semantic_manifest.json`.
- Support semantic models and metrics as first-class graph resources.
- Add efficient cross-database transformation through explicit multi-connection planning, pushdown, staging, and cost controls.
- Maintain public-safe repo hygiene and a PR/green-check release workflow.

## Operating Loop

### Full Usability Implementation Campaign

The fresh unfiltered 5,808-case run on the published sorting candidate has
exposed eight failures across initialization, a colored-output expectation and
durable compile/docs error artifacts. The original whole run continues without
source changes to collect integrated evidence; its failed scratch and reports
are retained and cannot count as acceptance. Read-only triage is disjoint:
the oracle worker grounds generated DuckDB profile paths and invalid-init
logging, the source worker grounds the statement-output color expectation, and
the expression worker traces compile/docs error publication. Fresh pinned Core
CLI witnesses confirm the initialization and color expectations are stale:
relative database paths use invocation CWD, invalid init still writes its
diagnostic log, and default output includes ANSI reset sequences. The oracle
worker owns only those command-fixture corrections, including explicit color
flags, in its isolated worktree. The expression worker restores only the two
facade catches that lost existing durable error artifacts and execution exit
codes. A ninth failure confirms an authored PostgreSQL catalog fixture indexes
Core's set-valued relation collection. The source worker owns the bounded
native catalog set constructor and that fixture's explicit list conversion,
with actual Core container/metadata evidence; the command test file remains
owned by the oracle worker to prevent overlapping edits. Any correction
must retain the original database effects, diagnostics, retry and full-schema
assertions. The supervisor records planning in a separate worktree during the
original run and integrates reviewed bounded corrections in that separate
checkout. After focused certification, it can push the draft branch and start
corrected actual-platform CI while the original local checkout remains frozen
on its failing candidate. Once that original run closes, the local checkout
receives the reviewed corrections and restarts the complete unfiltered suite
and applicable final gates. Reports always identify their actual candidate;
the older full run cannot certify the corrected branch.

The new catalog negative case exposes a second grounded publication gap:
an authored catalog exception makes Core write a Catalog v1 errors array and
docs index with execution exit code 1; the native candidate exits 2 before
publishing either, despite retaining successful compiled artifacts. The source
worker owns only the additive catalog error-array writer, its native escaping
and allocation check, and the existing catalog failure fixture's direct-index
and authored-error cases. The expression worker owns only the docs facade's
collection catch/publication hunk. Preserve successful catalog bytes, complete
artifact schemas, authored diagnostics, static index output, existing effective
write policy and OOM propagation. Both corrections join the same single native
build and focused certificate before isolated draft publication. No unrelated
catalog transport, provider or feature surface is expanded.

Focused certification now restores the compile/docs error artifacts, but the
original actual Core retry check exposes its one-way docs flag bug: Core itself
records false static/empty-catalog values and then rejects their generated
negative CLI options when retrying its own artifact. The source worker owns
only omission of default-false one-way docs flags in the native results writer
and a native argument regression; enabled flags and the dual compile flag keep
their effective behavior. This is an intentional artifact argument difference
for Core retry interoperability, recorded by the supervisor in compatibility
documentation. The expression worker extends the original failure/retry fixture
with default docs generation while retaining its existing static case and all
artifact/SQL/retry assertions. Core and its assertions are never patched. A
fresh combined native build and every focused case remain mandatory. The
older whole run's additional external-reader diagnostic failure is being
grounded read-only by the oracle worker before any correction is authorized.

Actual Core and native external-reader witnesses confirm the plain authored
invalid-boolean literal is part of the database diagnostic. Native rollback
retains the original file bytes, relation rows and absence of staging files;
those assertions stay intact. The oracle worker owns only correction of that
literal expectation and an actual Core/native declared-secret regression in
the same external-file fixture module. The separate declared DBT_ENV_SECRET_
control proves a real native publication gap: Core masks the value in console,
file log and result messages, while both engines retain authored raw SQL. The
source worker owns a bounded native secret-value projection and its console,
file-log and durable result-message seams, with allocation/overlap/empty-value
checks. It must first trace the current publication owners, preserve authored
SQL/config artifacts, retain useful non-secret diagnostics and propagate OOM.
Any additional facade seam needs a grounded handoff before editing. The
expression worker integrates these disjoint commits and certifies the combined
native CLI; no independent heavy build starts without disk headroom.

The older known-failing 5,808-case run is intentionally interrupted with SIGINT
after preserving its current progress, failures and source/binary receipts.
It cannot reach acceptance, and continued fixture growth threatens the space
needed for corrected clean builds. Allow its normal finalizers and JUnit
publication to close before changing that checkout. This is partial negative
evidence only. All corrections still require a fresh complete unfiltered run,
original build fixtures, both actual CI architectures and final public/release
gates. Closed database scratch may be retired only by exact approved scope with
two independently verified complete physical restores and durable recovery
indexes; failed fixture scratch and unknown/live consumers remain protected.

The final unfiltered 5,626-case candidate run was intentionally interrupted
after its first failure was grounded: a fixture rendered a dictionary created
from a salted Python set, whose iteration order changes with PYTHONHASHSEED.
The source worker owns only the deterministic fixture correction and retains
both original Core orders. Using the standard dictsort filter then exposed a
confirmed missing native filter. The expression worker owns a focused filter
helper, one dispatcher branch, native allocation/ordering tests and a disjoint
actual Core fixture module; it reuses existing argument binding, genuine items
dispatch, Unicode lower and value ordering. The supervisor owns integration and
will restart the entire unfiltered canonical suite after focused certification.
No test selection, assertion or schema check is weakened. The interrupted run
and its failure remain recoverable and cannot count as final acceptance.

The same interrupted run retains a second fixture failure: Core emits runtime
errors on stdout under quiet logging. The corrected test keeps the return code,
native stderr wrapper, exact database diagnostic and file-log assertions. Both
test-only corrections are integrated. The filter's original focused pass also
exposed genuine readonly Mapping dispatch and large unordered-float ordering
differences. These remain product blockers until the native helper matches the
pinned Core behavior on both adapters; no alternate fixture bypass is accepted.
The bounded native adaptive-sort helper records its pinned upstream source and
reuses the shipped PSF notices. Complete focused certification precedes a fresh
unfiltered run, final public/release checks and both architecture CI suites.
The reviewed filter and adaptive-sort implementation are integrated, and the
fresh unfiltered collection contains 5,760 tests. Product-source edits are now
held while the worker certifies all 134 actual Core filter comparisons and the
corrected base-context and quiet-log fixtures on its frozen native CLI.

All 782 native tests, 134 actual Core filter pairs and three original fixture
checks pass. Both unchanged public ladders and eight shorter Actions jobs pass
on that candidate. A bounded two-case follow-up then confirms the existing
standard sort filter shares the same ascending/reverse unordered-float bug.
The complete 5,760-case run is intentionally stopped with its partial evidence
retained. The expression worker owns only standard sort routing to the already
certified adaptive helper, original reverse/tie behavior and disjoint regression
fixtures; the supervisor owns integration and restarts the whole suite. The
earlier native/public/install receipts remain candidate-specific. No other
provider or feature family is broadened by this correction.

The reviewed standard-sort correction is committed and integrated. It changes
only ascending adaptive sorting and Python's input/output reversal, retaining
stable ties, original typed payloads and comparison errors. Forty-eight actual
Core regression cases cover both initial adapters, including all five required
large unordered-float sizes; all 134 dictionary-sort cases remain mandatory.
The complete unfiltered collection now contains 5,808 tests. All 784 native
tests, the CLI build, all 182 paired sorting comparisons and the three original
fixture regressions pass on one frozen CLI. Product source is held during this
candidate's certification; the fresh whole-suite run, final public ladders,
ReleaseSafe packaging/performance and both actual-platform suites remain gates.
The local whole-suite run uses standard pytest failed-only temporary retention
to bound scratch storage, without changing test selection, assertions or build,
adapter and browser fixtures. Durable logs/JUnit reports remain outside the
temporary root. Pytest retains call-failure scratch; setup/teardown-only failures
can still lose their function scratch under its documented cleanup behavior.
The former observation/archival tooling stays outside this fresh test process.

The preceding candidate passes both unchanged public-project ladders and the
original autocommit check. Its actual x86_64 and ARM native/install CI jobs,
all 776 native tests, 326 Python 3.11 cases, snapshots and performance pass.
Its independent ReleaseSafe archive is deterministic, both extracted adapters
work with PATH empty, the unchanged 70,000-binding seed passes and every
250-model cold/warm comparison meets its budget. These receipts remain scoped
to that candidate; the dictsort integration requires final recertification.

The integrated typed cursor/range candidate passes 776 native tests and 463
strict Core comparisons. Final unchanged PostgreSQL dbt-utils and Jaffle
acceptance exposed one shared consumer regression: stock test materializations
still require list column names after Agate correctly publishes a tuple.
The supervisor owns the bounded test-result consumer correction; independent
workers audit related consumers before the complete canonical run and repeat
both unchanged public-project ladders on the corrected frozen CLI. Earlier
passing public/release receipts remain historical evidence, not certification
of this candidate. Native release installation, performance and both actual
architecture CI runs remain mandatory.

Two independent consumer audits find no further production list-only mismatch.
The empty-table constructor also publishes tuple column names, matching the
pinned Core empty Agate witness; fetched and seed tables already do so. Existing
real build/test/public-project checks validate these bounded integration fixes.
The same audit confirms Core result matrices contain tuple rows inside the
outer list. Native fetched matrices now preserve that shape, and the test
runner validates tuple/list rows without relaxing row count, arity or types.
Four new actual Core comparisons cover fetched and empty stored results on
both initial adapters before the final canonical freeze.

An earlier published checkpoint passes all three reported Actions jobs: the
unchanged public PostgreSQL package, all six public Jaffle commands and the
native Zig/safety checks. Exact cold/warm performance, snapshots and extracted
installation on both architectures also pass. The developer-only clock fixture
handles interrupted and partial diagnostic writes under fortified runner
headers; five regressions, including both actual database engines, pass.
The broader Python 3.11 developer job exposed four historical expectations:
two pre-COPY seed diagnostics and two alphabetically ordered macro arrays.
Fresh Core CLI witnesses confirm the exact CSV diagnostic fields and authored
macro dependency order. All four bounded corrections are integrated and pass
on the unchanged verified product candidate. The fresh Actions developer job
passes all 326 tests at the published checkpoint. All three reported jobs pass
again there, including the complete unchanged PostgreSQL package ladder.
Product semantics and the strict public comparison remain intact.
The full Python 3.12 compatibility jobs are still running on both architectures.

The combined callable/ownership candidate passes 704 native tests and 70
developer acceptance checks. The Relation Mapping closure is integrated after
48 actual Core comparisons; earlier callable certificates include 18
both-adapter list-growth cases, 44 inline cases and the complete 213-case
saved-method/base/receiver suite. The lazy iterator capacity repair initializes
spare tagged cells before alias publication and passes eight actual Core cases
for live and completed saved loop contexts. The fresh strict public PostgreSQL
ladder passes on this combined candidate in 156 seconds. Failed earlier public
and small seed fixtures remain regression evidence. These results are
candidate-specific and do not establish merge readiness.

The primary seed implementation, genuine sequence markers and borrowed
transaction cleanup are integrated with actual Core fixtures for bundled
DuckDB COPY and native PostgreSQL bindings. The integrated CSV certification
and append-only loop-prefix repairs pass all 63 primary seed cases, including
the new Column cases and unchanged 10,000-row, 70,000-binding PostgreSQL workload.
They also pass 708 native tests and all 18 actual Core alias/provider comparisons,
with pre-mutation invalidation intact. The integrated completed-batch-only
capacity certificate also passes all 708 native tests and all 81 actual Core
seed/alias cases. Its native budget retains the genuine 16,384-cell capacity
buffer, while active buffers still traverse future mutable aliases. The same
unchanged wide-seed execution improves from 321 seconds through 145 seconds to
31.5 seconds, against Core's 8.4 seconds, in Debug. The same unchanged fixture
also passes on the immutable ReleaseSafe CLI: 6.15 seconds native and 15.41
seconds Core in that shared-machine invocation, including exact SQL/artifact
parity, 70,000 placeholders, 10,000 rows and both sums of 49,995,000. This closes
the observed minutes-long alias traversal with production-build evidence;
it is not a universal speed claim. The original slow fixture remains intact.
The final combined query transport must retain this complete workload.
The oracle worker also owns native result transport, embedded-NUL/composite
parameters and the authored cursor contract, with the cache worker owning a
separate PostgreSQL typed-cell/description module. The release worker's ELF
architecture and checksum-before-extraction checks are integrated and pass
their developer regressions; genuine ReleaseSafe and ARM acceptance remain
required. The supervisor owns integration, publication and the final release
gates; workers retain source and test evidence in separate clean worktrees.

The supervisor's collection audit found 60 separate session registrations of
the identical imported CLI-build fixture across 5,213 collected cases. A shared
cached developer helper now performs that fixture's clean CLI build and native
test run once per pytest process; every registration still checks the binary
exists, and native driver/browser fixtures remain mandatory. This removes
redundant compilation without reducing test selection or oracle assertions.
An actual clean-build check across two existing modules passes, with a receipt
showing one completed build/test helper invocation and one cache reuse.

Active final closure ownership is disjoint and sequenced by reviewed commits:
the expression worker owns compiler alias publication and immutable CSV backing
certificates, including the unchanged wide-seed scaling gate; the oracle worker
owns typed native result transport, original cursor/Agate separation and parameter
execution; the source worker owns exact Decimal/Range and narrowly grounded
DuckDB type/PostgreSQL Column expression/mapping hooks, followed by the finite
cursor UUID equality/key protocol if actual Core confirms the review gap;
the oracle worker owns query-cursor constructor wiring for those helpers.
The cache worker owns the isolated Column value helper, native bytea cast/order
and release API closure and actual Core cursor descriptor witnesses. After the
bytea helper lands, the source worker owns its narrow expression call/slice
hooks and compiler local-callable routing immediately before callable-name
resolution; these hunks are separate from the expression worker's alias
publication and seed-performance changes. Constructor wiring stays with the
oracle worker. Independent bridge review found two filter truthiness paths
that bypass checked released/zero-dimensional buffer behavior. The cache worker
owns their narrow `expression_filter_iterator.zig` correction and native
regressions; the source worker owns the finite actual Core negative witnesses.
The oracle worker integrates this companion before the final combined build.
The cache worker also owns the bounded saved-memoryview-method string/repr
formatter: methods must render their real method/class/receiver identity rather
than expose private native callable metadata. Actual Core witnesses use authored
stable shape/identity comparisons; comparison SQL is never normalized.
The immutable final typed-query worker candidate passes 772 native tests and
the CLI build, including the checked filter and saved-method companions.
Actual Core grounding covers Unicode/numeric parameter slots, token boundaries,
nonfinite numeric bindings, finite date/timestamp string fallbacks, buffer
lifetimes and method representation. Its strict 274 query plus ten UUID pairs,
and all 62 Decimal pairs pass on the same immutable CLI, with zero failures,
errors, skips or deselections: 346 complete API comparisons. The supervisor
integrated all 33 reviewed helper commits and the certified transport commit;
every native source file matches the certified worker tree byte for byte.
The unchanged 63 seed/18 alias comparisons also pass on that same CLI in 217
seconds, including all 70,000 PostgreSQL bindings, 10,000 rows and both sums of
49,995,000. This checkpoint therefore passes 427 actual Core comparisons and
772 native tests. Final unfiltered campaign gates remain required. No product
edits occur during an immutable candidate's comparisons.

A final actual Core witness confirms that all six returned PostgreSQL range
types can be rebound as parameters, including finite, empty and unbounded
values. The native conversion currently rejects these genuine carriers. The
oracle worker owns the bounded companion's genuine range kind/class metadata,
recursive parameter endpoints, conversion, adapter wiring and paired fixtures;
the source worker has released only those range-helper hunks. The cache worker
owns PostgreSQL literal adaptation in its separate helper, sequenced after the
oracle's parameter definition. NumericRange keeps unknown scalar/text-array
inference; temporal ranges use the stock typed constructors and arrays. This
adds no arbitrary provider or new authored constructor. Original passing
candidate receipts stay intact; the combined companion must pass before the
final canonical and release acceptance run.

The bounded range companion is now integrated after all 776 native tests,
the CLI build, 36 strict returned-range comparisons and 62 Decimal comparisons
pass on its immutable candidate. Independent review confirms arena lifetime,
genuine class recognition and stock numeric/temporal inference; every integrated
native source byte matches that candidate. The combined 365 query/UUID/seed/alias
rerun passes in 636.68 seconds on the same CLI, bringing the complete focused
certificate to 463 comparisons with zero failures, errors or skips. Fresh main
is unchanged and the branch is
rebased before final validation. The final unfiltered canonical collection has
5,626 cases including the four Agate result-shape comparisons; its real
driver/browser fixtures, zero-skip report and clean shared
CLI/native-test build remain mandatory. The supervisor owns this whole-tree
run, the expression worker owns final unchanged public-project comparisons and
the release worker owns genuine ReleaseSafe packaging/installation/performance.
Developer evidence stays recoverable in verified lossless archives; current
build caches, original slow baselines and unfinished fixtures stay protected.

The source worker's 62 Decimal comparisons pass on the first, corrected and
expanded typed CLIs. The expanded query gate retains 182 passing and seven
failing cases: type subscription, keyword field names, infinite timestamps and
parameter adaptation exposed concrete native differences, plus a fixture's
process-specific memory address. Corrections use actual Core witnesses; only
the address output changes to deterministic bytes/format/type evidence. UUID
safety and bytea lifecycle/method companions now pass the final combined native
build and unchanged actual Core comparisons. Its independent transport review
found cursor consumption, eager Agate serialization and duplicate-name
mismatches; the certified transport corrects all three. The supervisor owns final integration, docs and
publication. The release worker preserves completed ignored proof data through
verified lossless archives to make room for the complete final suite.

An earlier CI repair checkpoint had all 263 historical CLI tests passing with
zero skips after Core-grounded expectation migrations and the profileless audit
relation fix. The published candidate passes the native/safety job and all six
public Jaffle gates, the retained autocommit query contract and both native
installation targets on Linux x86_64 and ARM. Held-session commands
require the native library. Vendored upstream whitespace remains byte-preserved
through narrowly scoped Git attributes. Public dbt-utils now executes every
command under both engines on PostgreSQL; the strict artifact comparison exposed
missing test columns and runtime model macro ordering, whose certified native
fixes are integrated for a fresh unchanged-project rerun on both adapters.

Canonical full Core compatibility uses CPython 3.12 on Linux x86_64 and ARM.
The Python 3.11 job covers developer/native CLI checks rather than asserting a
different Python runtime's expression semantics. The expanded full oracle suite
needs a longer bounded CI timeout. No test skips count as parity evidence.

Current shared-file ownership is sequenced by reviewed cherry-picks: the root
owns mapping-proxy recognition and tuple JSON companions; the filter worker
owns numeric identity and consuming comparisons; the expression worker owns
datetime providers and class protocols; the compiler worker owns literal pools,
model provenance, macro-error dependencies and deprecation effects; the test
worker owns context nulls and compiled-path provenance; the oracle worker owns
temporal format specifications and final public docs. A separate adapter worker
owns QueryResult allocator lifetime. Certified focused gates include 110
datetime, 181 pytz, 96 strptime, 204 itertools, 44 temporal-format and 18
macro-error comparisons. New class, identity, null/provenance and allocator
closures and the complete final candidate gates remain pending; this checkpoint
does not establish full replacement or merge readiness.

The strict public package rerun exposed a further schema-test distinction:
Core seeds generic-test macro dependencies with its unqualified resolver even
when raw code calls a package namespace, and it retains tests declared on an
unmatched YAML target as non-executable manifest nodes after missing-reference
resolution. The root owns this generic parse/artifact closure and its both-adapter
oracles, including column tags and transitive parse-time macro visibility.
Static macro dependencies now resolve before schema-test configuration. The
compiler worker separately owns reached singular and generic runtime calls,
including selection of the explicitly authored package macro during execution.
The focused parser/config regressions pass and runtime collectors are integrated.
The unchanged PostgreSQL project now passes the complete resource/config/dependency
comparison; its build outcomes exposed a remaining passing-test failure count
distinction. Core reports zero unless a threshold fires, even with nonzero
aggregates. The supervisor owns that correction and a fresh both-adapter gate.
Project source files and strict gate comparisons remain unchanged.

Passing-test outcomes now have 40 mandatory Core comparisons on both adapters,
including signed aggregates, stored rows, test/build and warning escalation.
The fresh public rerun caught a seed schema regression in the new compiled-path
writer; seed nodes now omit the forbidden field. The combined native class and
artifact integration passes 647 tests. A final unchanged-package rerun is
still required before calling the public package gate repaired.

The next unchanged public PostgreSQL rerun passes command execution, complete
artifact schemas, resource/config/dependency identities and build outcomes. Its
remaining strict compiled-SQL difference is a physical CRLF macro in dbt-utils:
Jinja normalizes template source newlines before lexing. The filter worker owns
that rendering-source correction and its both-adapter oracle; authored bytes,
checksums and the strict public comparison must remain intact.

The integrated limited generic-test namespace has 50 mandatory Core cases and
preserves authored discovery and dependency traversal order. Per-function
literal pools and RegexFlag class identity are integrated with their focused
certificates. Stock execution now writes its actual dispatched main SQL at the
execution boundary, with 86 focused materialization/contract cases. Test
materialization write paths have 60 mandatory both-adapter Core cases and use
their resource's own completed-write record. Actual DuckDB COPY and PostgreSQL
bound seed loading remain open. Native snapshot main SQL deliberately records
the SQL actually executed; optimized execution must retain Core-compatible
rows, types, lifecycle, paths and artifact schemas, rather than publish a second
unexecuted SQL reconstruction.

The filter worker's harness-only Core lifecycle closure reproduces and resets
both upstream module-global deprecation registries for each in-process oracle
invocation. Fresh CLI comparisons and current-command strict-warning failures
remain required. This prevents an unrelated earlier warning or failed command
from contaminating the complete suite; it changes no product runtime behavior.

The remaining shared compiler sequence is rendering-source newline normalization,
inline macro closures and saved callable container methods. Resource provenance,
test compilation writes, console errors, expression/class protocols, the limited
generic-test namespace and literal/primitive identity pools are integrated. The dedicated
namespace worker owns discovery-order resolver hooks and the limited parse
namespace, including recursive overwrite order and argument rendering; runtime
provider lookup remains separate. Every slice needs actual Core comparisons.
The expression worker owns callable container method aliases after its complete
temporal API certificate. The oracle worker owns stock execution SQL artifacts
and actual DuckDB COPY/PostgreSQL parameterized seed loading. These known gaps
and full final candidate gates remain open; focused green results do not make
the branch merge-ready.

The rendering-source closure now passes 14 mandatory Core projects while
preserving authored bytes. The fresh unchanged PostgreSQL package passes all
seven commands, schemas, graph/config/dependency identities, build outcomes and
every compiled SQL resource. Its time-dependent views expose the developer
gate's separate-query clock mismatch; deterministic comparison must retain
every relation and typed value. The namespace worker owns the combined static
dependency and saved-dispatch certificate. The compiler worker's inline macro
closure has 44 mandatory passing Core cases and now owns receiver forwarding
and memoized public context cloning. The expression worker owns saved builtin
method activation and its native receiver API. The supervisor owns genuine
mapping/iterable and JSON/config classification; shared edits integrate in this
order. The filter worker owns amortized native list mutation to close the
authentic wide seed's quadratic binding accumulation. These slices and their
combined final candidate gates remain required before merge readiness.

PR #219 is merged. The user has authorized completing the replacement roadmap,
including its proposed features, from fresh main on `feat/full-usability`.
The previous snapshot slice's stop boundary is historical and does not constrain
this campaign. Implement and verify the roadmap in dependency order; never
label a planned or unverified feature complete.

Wave one uses isolated worktrees: scheduler/ephemeral ancestry and mixed unit
builds; durable test error rows; incremental materializations; snapshot
materializations; state/freshness selectors; package dependency installation.
The supervisor owns CLI integration, Jinja/compiler improvements and this plan.
Shared `project.zig`, types, root/main, compiler and integration-test edits are
sequenced by cherry-pick: scheduler, errors, incremental, snapshots, selectors,
dependencies, then supervisor integration. Workers keep new logic in focused
modules, add native/CLI and pinned Core evidence, and do not edit docs or PLAN.
Later waves cover remaining configuration/macros, adapter certification,
commands/artifacts, semantic/static-analysis/stateful/cross-database features.

Wave three assigns configuration/property parsing, bundled macros and PostgreSQL
resource execution to the configuration worker; threaded scheduling, cancellation
and structured logs to the adapter worker; semantic resources and MetricFlow
planning to the command worker; shared-YAML snapshots followed by SQL analysis to
the snapshot worker; durable environment/interval planning to the state worker;
and dependency transports followed by cross-database movement to the YAML worker.
The supervisor owns complete artifact validation, CI/release packaging, public
project gates, docs browsing and performance verification. Shared types, loader,
compiler, options and root command routing are integrated sequentially by
cherry-pick. Worker modules remain isolated and must bring native, CLI and
source-grounded oracle evidence before integration.

Integration now sequences compile/docs durable results and Core-readable retry
arguments, threaded native jobs and lazy database-backed compilation, semantic
resources/query planning, shared-YAML snapshots, stateful environments,
cross-database movement, then the remaining property/materialization surface.
The SQL-analysis worker owns focused native dialect parsing, typed logical IR,
lineage, source diagnostics and dependency-aware caches, with narrow hooks for
namespaced `analyze`/`explain` commands after the other command-routing commits.
The supervisor owns the developer cold/warm performance budget and public
package-heavy project validation. These additions retain dbt artifact schemas.

The environment worker has integrated versioned environments/intervals and now
owns the remaining CLI discovery/alias/global-option/environment compatibility
in a fresh worktree. Profile defaults, quiet/write-json/logging effects and
Core-defined environment precedence require actual oracle fixtures. This
command-routing slice follows workflow/threaded hooks; it preserves namespaced
semantic, environment and cross-database commands. The supervisor owns the
catalog writer's optional warehouse comments/owner fields; the configuration
worker supplies PostgreSQL introspection and materialization persistence.

Current integrated work includes native DuckDB/PostgreSQL drivers and bounded
threaded commands; Core CLI option/profile discovery behavior and JSON-line
listing; full artifact schemas and docs application; versions and source
freshness; native expression filters and slices; semantic planning/exports;
typed dialect SQL analysis with lineage; and durable environment and
cross-database plans. Focused reference gates include 28 expression comparisons,
107 semantic cases (with three corrected diagnostic expectations rerun), 23
SQL-analysis cases and the earlier snapshot/environment gates. These worker and
focused results are integration evidence, not the final release claim.

The remaining active integration wave owns unchanged public package execution,
typed Relation/Column and bundled macros; complete unit fixtures and overrides;
configuration/access/contracts/hooks/custom materializations; native microbatch
execution; effective remaining command flags and parser/relation caches; and
retained cross-database stages/catalog observations/adaptive scheduling. The
supervisor owns legacy test reconciliation, public projects, release licenses,
platform builds, complete integrated validation, support docs and publication.
Native/static parser and macro third-party notices must ship in binary archives.
Release packaging now uses one deterministic developer archive builder. Native
installation certification extracts that exact, safety-validated archive with all
upstream notices and runs both adapters with PATH empty on each actual target.
The developer PostgreSQL fixture now selects installed native tools where the
pinned pgserver wheel is unavailable; the full compatibility CI/release matrix
includes an actual Linux ARM runner. Local forced-native fixtures pass all 14
PostgreSQL adapter checks; ARM verification remains pending remote execution.
The supervisor now owns native group definitions, model access validation and
selection in focused group_access.zig plus narrow graph/parser/artifact hooks.
The configuration worker retains adapter contexts, catalog, contracts and hooks;
the CLI and adapter workers coordinate parser-cache persistence and controls.
The supervisor also owns the complete resource config projection shared by the
manifest and macro context. Model, seed, snapshot and test defaults, typed extra
fields and normalized hooks are compared in full against pinned Core; shared
configuration merge/execution changes remain with the configuration worker.

The supervisor owns project hook operation discovery, compile artifacts and the
on-run-start/on-run-end lifecycle in a focused native module. Narrow Node index,
loader, compiler, OperationHost context and run-results hooks integrate after the
typed expression/compiler helpers. The configuration worker owns resource hooks
and their held-session body wrapper; these are separate execution lifecycles.
Actual Core failure, ordering, context and transaction behavior is the oracle.

The developer performance harness compares complete artifacts and every compiled
model before enforcing cold/warm budgets. Its first 250-model, three-repetition
ReleaseSafe measurement passed both budgets. Clean-install checks also passed
with PATH empty and no Python/CLI product fallback. Both gates, the native test
suite, mandatory Core/public project suite and safety scans must run again on the
final integrated tree before publishing the PR and marking milestones complete.

The user confirmed SQL model execution only for the initial release. Native
Python syntax discovery and parse/compile artifacts remain visible; selecting
Python models for execution must fail before warehouse mutations.
The initial adapter certification scope is DuckDB and PostgreSQL, as confirmed
by the user. Remaining dbt adapters are a subsequent certification scope, with
their own drivers and live warehouse targets; they must not be advertised as
working merely because profiles parse. Compatibility checks use dbt Core 1.10.5,
dbt-duckdb 1.9.6, dbt-postgres 1.9.1 and MetricFlow 0.208.1. Full artifact schema
checks use the pinned upstream schema classes, which produce the published
schemas, and run in mandatory CI alongside native driver fixtures.

The current closure wave uses six isolated editing worktrees. The expression
worker owns native regular expressions and ordinary/parse-time undefined
semantics; the configuration worker owns contracts, constraints, authored
materializations and lifecycle result metadata, plus the sequenced compiler
and JSON companion for new expression values. The command worker owns inline
show/compile operations, diagnostic exit codes, effective remaining flags and
general SQL snapshot Jinja. The docs worker owns deferred description rendering
and typed doc providers. The naming worker owns custom identity finalization,
saved-query exports and generic-test compile dispatch. Its adapter child owns
native DuckDB profile initialization and retry behavior. Shared compiler,
context, facade and artifact changes integrate by reviewed cherry-picks.
The supervisor retains project-hook session lifetimes, regression migrations,
unchanged public project execution, archive notices and final release gates.

Integrated project-hook comparisons now cover root-before-dependency ordering,
global model indices, ephemeral end contexts, persisted-test audit schemas and
start/end compilation failure artifacts. Parsed JSON rejects duplicate keys
and non-finite numbers in the developer validator. The first full historical
CLI run stopped after 20 failures and 220 passes; Core-grounded migrations and
compiler error-code corrections precede a complete rerun. Seed view rejection,
unquoted identifiers/types and retained passing audit tables receive fresh
both-adapter Core comparisons. These partial runs do not establish release
acceptance. Regular-expression runtime/provenance notices must accompany the
existing grammar, adapter-macro and Unicode notices in actual archives.

The integrated closure includes typed dictionary keys and JSON errors,
ephemeral generic/singular data-test CTEs, custom relation naming, enforced
contracts/constraints, typed documentation providers and native DuckDB profile
settings, retries and transaction policies. Its earlier 501-test native gate
passed. The supervisor's typed JSON slice passed 30 actual Core comparisons;
the exact integrated profile candidate passed all 24 actual Core profile cases.
The frozen historical CLI/project-hook/ephemeral run completed with all 40
hook/ephemeral Core comparisons passing and 175 historical CLI failures.
Most historical failures share a subsequently fixed profileless naming
regression; remaining expectations are being reconciled with fresh Core
parse/compile probes before the complete rerun. This run is not release evidence.
The unchanged PostgreSQL dbt-utils parse advanced beyond Relation-keyed maps
and stopped on a missing required macro argument: Core binds an Undefined value
where the native binder rejects the call. The expression/configuration workers
own the sequenced Undefined and macro-binding closure. This public workflow
failure remains an acceptance blocker; no project files or gate scope are changed.

Ordinary and parse-time Undefined values now retain identity through typed
expressions. The supervisor owns dictionary-key and JSON switch companions
and historical native/CLI assertion migrations; the configuration worker owns
value cloning, package-render constant probing and compiler host overrides;
the adapter child owns macro argument and callback binding. The expression
worker owns a complete phase matrix. Actual Core confirms missing macro
parameters use ordinary Undefined even in model parse, while model callback
parameters use capture values. Two historical loop-error expectations are
replaced with Core's empty SQL result. The combined native gate awaits the
package-render companion; no weaker gate replaces it.

The docs worker owns native SafeLoader/SafeDumper-compatible runtime YAML and
JSON loading, including immutable bytes/date key protocols. The supervisor
will route those protocols through the shared mapping-key module after the
worker's narrow helper API lands. The command worker owns deprecated profile
behavior-flag fallback and executed generic-test materialization helpers,
including complete compiled SQL/CTE/file publication. The naming worker owns
the paired final identity fixtures and public support docs; final acceptance
counts and publication remain with the supervisor. The unchanged pinned
Jaffle project requires an explicit Core version-check override and an external
profile flag for nested generic-test arguments under Core 1.10.5. The shared
developer harness provides the same external profile to both engines without
editing authored project/profile files; this is not a Core 1.11 claim.

The current native integration gate passes 544 cases. A complete historical
CLI run reported 235 passes and 28 failures; Core-grounded assertion migrations
have passing focused reruns, with the complete historical rerun and the
configured test-limit regression still pending. Neither run is release
acceptance. The supervisor now owns Core selector grammar closure and final
historical reruns. The expression worker owns native datetime/pytz/itertools
module providers and timestamp constructor protocols after delivering scalar
operators. The byte worker owns codec/API certificates; the formatter worker
owns string format/format_map and final public documentation. Shared compiler
module hooks remain sequenced with the configuration worker's reference
dependency guards, parse warnings and materialization result lifecycle.

Draft PR #221 publishes the committed implementation on `feat/full-usability`.
The branch uses the repository owner's GitHub noreply commit identity. The
supervisor additionally owns source tag inheritance and selector config
projection, followed by complete native parse-cache code/data fingerprinting.
All 75 mandatory selector comparisons now pass against Core, including the
complete source/table and legacy/config tag inheritance matrix. Full combined gates and platform CI
remain required before marking this PR ready to merge.

The published draft's first CI run exposed three blockers. The supervisor owns
their closure: replace the public Jaffle harness's historical null invocation
expectation with pinned Core UUID/version/timestamp and complete resource checks;
preserve upstream C/header whitespace through scoped Git attributes; and discover
generic test macros below each configured test path in both root and dependency
projects. The unchanged dbt-utils PostgreSQL project fails because its authored
tests/generic definition is absent from the graph, not because the gate needs
filtering. Native discovery and both-adapter Core execution regressions precede
the unchanged project's full command ladder.

Generic-directory discovery now passes eight mandatory Core comparisons for
root/package definitions, default/custom test paths and DuckDB/PostgreSQL
execution. The unchanged public PostgreSQL project passes parse, seed and run;
compile exposes eager map(None) behavior and an Agate column/mapping update
callback, owned by the filter and compiler workers respectively. Keep the
complete public command ladder blocked until those behaviors and all artifact,
SQL and row comparisons pass. The test-context worker additionally owns missing
inherited context fields and lifecycle provenance, with both-adapter Core probes.

The integrated lazy loop/cache/options/provider checkpoint passes all 45 cases.
Authored test-helper execution has 52 distinct passing Core comparisons across
DuckDB/PostgreSQL, including four retained audit regressions, and the helper
candidate passes all six unchanged public Jaffle command gates. Those focused
certificates do not replace the final combined suite. The first published CI
candidate also passes actual Linux x86_64 and ARM native installation, both
adapters from extracted archives with PATH empty, the snapshot oracle and the
performance job; all required checks must pass again on the final candidate.

After its scheduling commit, the scheduler worker owns the focused native
DuckDB/Postgres adapter contract in a second isolated worktree. Shared backend
integration follows test-error, incremental and snapshot commits. Threaded
execution requires shared native connections rather than concurrent DuckDB CLI
writers; coordinate the scheduler on that contract. Dependencies use the same
Runtime.environment interface as Jinja. Registry live verification currently
receives an actual proxy denial for dbt Hub; deterministic HTTP fixtures cover
the API while native code remains available for allowed deployments.
The completed test-error worker next owns native debug/init/run-operation,
retry/clone and command/flag integration in its own worktree. It coordinates
macro invocation with the supervisor and live connection checks with the
adapter worker; command commits integrate after state/defer and dependencies.
Parallel pytest runs use separate ignored basetemp directories to prevent
pytest's shared temporary-retention cleanup from removing active fixtures.
After dependency installation, that worker owns a general native YAML reader
and completes remaining dependency syntax/transports using it. The reader
returns std.json.Value with source diagnostics and supports block/flow maps and
sequences, multiline scalars, anchors/aliases/merge, tags and quoted escapes.
Configuration/profile and semantic workers will consume this shared reader
after its commit, preserving scope and configuration precedence during migration.
The completed incremental worker next owns full project/profile/resource
configuration, model versions/groups/access and contract/hook/grant execution.
It stacks on its incremental slice and consumes the shared YAML reader when
ready; narrow compiler/test-macro interfaces coordinate with the supervisor.
Configuration commits follow the YAML/dependency and snapshot parser commits.

Validation uses the current pinned Core/adapter contract, repeated-run and
failure fixtures, full applicable schemas, public projects, native tests,
runtime/safety scans and release builds. Inspect every failed gate before
continuing; never replace implementation with accepted-but-ignored arguments,
empty artifacts, canned results or Python product code. Cloud adapter
certification requires declared targets and usable warehouse connections;
continue independent native work while those requirements are clarified.

### Active Snapshot Foundation Slice

Issue #213 is the next read-only dbt compatibility slice: discover legacy SQL
snapshot blocks, add Snapshot nodes to Manifest v12 and the shared selector
graph, and reject execution until snapshot materialization exists. The parser
worker owns snapshot parsing, loader/config/type/graph integration, manifest
fields, command preflight, native tests, and focused CLI fixtures in an isolated
branch. The supervisor owns this plan, the compatibility roadmap, README,
CHANGELOG, and compatibility matrix; these documentation changes integrate
after the worker commit. No other runtime slice runs concurrently.

Final full-suite verification exposed pre-existing stale expectations and dbt
oracle harness incompatibilities on main. A separate harness worker owns
test-only fixes in `tests/test_cli.py` after the snapshot worker commits;
snapshot runtime ownership is complete. Ground changed expectations in the
pinned Core oracle, preserve assertions, and do not weaken checks to hide
product incompatibilities. Integrate the harness commit before final gates.
The supervisor also owns a dedicated pinned snapshot-oracle CI gate and
developer-only oracle requirements so the new full Snapshot schema comparison
cannot silently skip in normal CI.
The harness oracle confirmed two source generic-test ID failures are real
pre-existing artifact gaps, not stale expectations. A second isolated worker
owns the `project.zig` source generic-test metadata call and `parse.zig` native
hash regressions: synthesized source node names must hash the original test
metadata, retaining all arguments and the original built-in/custom name.
Preserve the CLI oracle expectations, integrate after the
completed snapshot runtime commits, and rerun the full native/CLI gates.

Implementation, source grounding, and the replacement audit are complete on
`compat/snapshot-foundation`. The integrated tree passes 315 native tests,
279 Python integration/oracle tests (three existing selector-oracle skips),
the pinned Snapshot schema/Core oracle, Debug and ReleaseSafe builds, all six
public Jaffle gates (parse/list/compile/build/run/docs), and runtime-boundary
and public-safety scans. The skips cover pre-existing selector fixtures that
Core rejects; they do not count as parity evidence. Publish this verified
slice through a PR; the roadmap remains the contract for full replacement.

Ground the supported literal snapshot configs and block/path semantics in dbt
Core sources and compare a synthetic fixture with dbt Core. Validate native
tests, parse/list/graph selection, disabled snapshots, explicit unsupported
execution errors, Manifest v12 snapshot schema fields, the public Jaffle
parse/list/compile ladder, and runtime-boundary/public-safety scans. Stop before
snapshot execution, broad Jinja, YAML snapshot definitions, custom strategies,
or adapter-specific materializations. Full dbt replacement and the proposed
semantic/cross-database features remain subsequent milestones, enumerated in
the compatibility roadmap.

Each development loop must:

1. Read this plan and current repo state.
2. Choose the smallest coherent milestone slice.
3. Use subagents or `codex exec` for planning, focused research, or blocker investigation when they add clear value. Do not run mandatory second-agent reviews unless explicitly requested.
4. Make scoped edits.
5. Run the fastest relevant verification.
6. Inspect changed files for secrets, local paths, and generated noise.
7. Commit only when the diff is coherent and verified.
8. Open a PR after the remote repository is configured; merge after green required checks.

Use local tests and targeted self-checks during implementation. Use subagents or
`codex exec` for planning or specific blockers when they add value, but do not
make second-agent/Codex review a required PR gate unless the active workflow
explicitly asks for it.

Concurrent implementation must use isolated git worktrees. Each active editing
Codex instance owns one branch and one worktree, records disposable local notes
under `.agent/runs/`, keeps durable sequencing changes in `PLAN.md`, and
converges by opening a focused PR. Branches should start from `origin/main`
unless explicitly stacked. Overlapping file ownership must be planned before
implementation. The canonical workflow is `docs/MULTI_AGENT_WORKFLOW.md`.
When work spans several roles, branches, issues, or review specialties, use the
GitHub-backed Agent OS in `docs/AGENT_OS.md`, `docs/AGENT_PROTOCOLS.md`, and
`docs/GITHUB_PROJECTS.md`. GitHub Issues/Projects hold public coordination
state; `PLAN.md` remains the sequencing and risk source of truth.
For unattended local execution, use `scripts/agent_os_orchestrator.py` to claim
ready GitHub issues, create isolated worktrees, launch `codex exec` workers with
the configured profile/model, record ignored run state, and optionally merge
green PRs. Issues are the durable queue; the orchestrator is the local engine.
Project-scoped Codex subagent configuration lives in `.codex/config.toml` and
`.codex/agents/*.toml`; keep these repo-specific settings out of global Codex
configuration.
When project-scoped Codex settings change and a fresh process is required, use
`scripts/codex_pull_plug.py` for detached/noninteractive handoffs, or
`scripts/codex_tmux_supervisor.py` when Codex must be restarted in the same
visible terminal pane. The tmux path is two-phase: request first, then mark the
request ready only after the current agent finishes the coherent slice and is
safe to exit. Neither path may create competing workers for the same dirty
branch or issue.

Local validation should stay focused while CI carries the broader matrix:
native Zig tests for touched core logic, targeted pytest for changed
CLI/artifact behavior, runtime-boundary and public-safety scans before PR, then
GitHub CI for the full Python integration matrix and public fixture gates.

Long-running loops must have explicit stop conditions and logs under ignored paths such as `.agent/runs/`.

## Documentation And Release Automation

Durable public documentation now has a dedicated home under `docs/`:

- `docs/PRIMER.md` explains the product contract, runtime boundary, source-grounded compatibility loop, and validation layers.
- `docs/COMPATIBILITY.md` is the current support matrix for commands, flags, resources, Jinja, selectors, artifacts, adapters, and validation.
- `docs/ARCHITECTURE.md` records the Zig module ownership map and Mermaid diagrams for runtime, parse/artifact, execution, and future cross-database planning.
- `docs/AGENT_OS.md`, `docs/AGENT_PROTOCOLS.md`, and `docs/GITHUB_PROJECTS.md` record the GitHub-backed multidisciplinary agent operating model, issue/PR communication protocol, and project bootstrap rules.
- `docs/MULTI_AGENT_WORKFLOW.md` records the concurrent Codex/worktree workflow, project-scoped agent roles, autonomous local orchestration, validation expectations, and PR convergence rules.
- `docs/RELEASES.md` documents the GitHub release process and native binary artifact policy.
- `CHANGELOG.md` tracks shipped pre-alpha slices and should be updated for every coherent PR that changes user-visible behavior, compatibility scope, docs, release automation, or safety rules.

Keep `README.md` as a concise front door. Keep active sequencing, risks, stop
conditions, and milestone status in this ExecPlan. Promote stable conclusions
from `.agent/research/` into docs when they become durable public behavior.

GitHub release automation lives in `.github/workflows/release.yml`. Tagged
`v*.*.*` releases build `ReleaseSafe` native Zig binaries for the initial Linux
target matrix, package public docs, generate checksums, and create a draft
GitHub Release. Release jobs must keep running public-safety and runtime-boundary
checks before upload, block tag/version mismatches, validate packaged archive
shape and binary/doc string safety with `scripts/check_release_archive.py`, and
avoid macOS or Windows artifacts until the Linux-specific filesystem discovery
code is portable.

## Public Safety Rules

- Do not commit local absolute paths, private hostnames, shell history, credentials, API keys, tokens, session transcripts, or private data.
- Keep fixtures synthetic or public and pinned.
- Keep generated targets, caches, logs, package directories, and virtualenvs out of Git.
- Prefer relative paths in docs, tests, and artifacts.
- Before publication, scan package contents for secrets and path leakage.

## Compatibility Definition

`dxt` is compatible with a dbt surface when it can ingest the same relevant project files, accept equivalent command flags, resolve the same graph dependencies, execute equivalent behavior for supported adapters, and emit artifacts that validate against the intended dbt artifact schemas.

Compatibility levels:

- **Read compatibility:** parse project files and resource definitions.
- **Compile compatibility:** render SQL/Jinja with refs, sources, macros, configs, vars, target/profile context, and dispatch.
- **Artifact compatibility:** emit dbt-shaped JSON artifacts.
- **Execution compatibility:** run materializations, tests, seeds, snapshots, docs, and source freshness for supported adapters.
- **Workflow compatibility:** support selectors, packages, state comparison, deferral, retries, and CI patterns.

Version targets must be explicit per release. The initial planning target is the current dbt Core artifact family used by modern Jaffle Shop projects, with schema validation pinned in tests.

## MVP Scope

The first useful version should run local public fixtures through DuckDB and produce inspectable artifacts.

Required MVP commands:

- `dxt parse`
- `dxt ls`
- `dxt clean`
- `dxt compile`
- `dxt run`
- `dxt seed`
- `dxt test`
- `dxt build`
- `dxt docs generate`
- `dxt docs serve`
- `dxt source freshness`

Initial flags:

- `--project-dir`
- `--profiles-dir`
- `--profile`
- `--target`
- `--target-path`
- `--vars`
- `--select`
- `--exclude`
- `--threads`
- `--full-refresh`
- `--output json` for listing and machine-readable inspection

Commands implemented after the original MVP, with final campaign acceptance
still required:

- `debug`
- `deps`
- `init`
- `run-operation`
- `snapshot`
- `retry`
- `clone`

## dbt Core Surface Area

The implementation must account for:

- `dbt_project.yml`, `profiles.yml`, `packages.yml`, `dependencies.yml`, `selectors.yml`.
- `models`, `macros`, `seeds`, `snapshots`, `analyses`, `tests`, `docs`, and package directories.
- `ref`, `source`, `config`, `var`, `env_var`, `doc`, `log`, `exceptions`, `return`, `run_query`, `statement`, `target`, `this`, `graph`, `model`, `flags`, and `selected_resources`.
- Parse-time versus execute-time Jinja behavior.
- Macro namespace resolution, package overrides, and adapter dispatch.
- Resource configs, column properties, tests, tags, meta, groups, access, versions, contracts, disabled nodes, docs blocks, exposures, metrics, and semantic models.
- Materializations: view, table, incremental, ephemeral, seed, test, snapshot, materialized view where supported, and custom materializations.
- Selectors: names, `+`, `@`, comma intersection, `--exclude`, tags, paths, files, packages, configs, resource types, sources, exposures, states, results, source status, test types, and YAML selectors.
- State/defer: `--state`, `--defer`, `--defer-state`, `--favor-state`, `state:new`, `state:modified`, and result selectors.

## Artifact Requirements

Artifacts are compatibility contracts, not incidental output.

Required:

- `manifest.json`
- `run_results.json`
- `catalog.json`
- `sources.json`
- `semantic_manifest.json`
- `dxt_parse_cache.json` for native parse caching

Namespaced extensions:

- `dxt_metadata.json` for namespaced data that does not belong in dbt schemas

Rules:

- Validate generated JSON against published schemas where available.
- Normalize nondeterministic fields in parity tests.
- Do not invent dbt field names.
- Keep dxt-specific metadata separate unless the schema explicitly permits it.

## Architecture

Core components:

1. **Project Loader:** reads project, profile, package, selector, and resource files.
2. **Parser:** extracts resources, configs, refs, sources, macros, docs, tests, exposures, and semantic objects.
3. **Manifest Graph:** stores nodes, dependencies, parent/child maps, disabled resources, and selector indexes.
4. **Jinja/Macro Engine:** models dbt parse/compile/run contexts and adapter dispatch.
5. **Compiler:** renders SQL and builds a logical relational plan when possible.
6. **Selector Engine:** evaluates dbt selector syntax against the manifest graph.
7. **Adapter ABI:** handles relation naming, quoting, SQL execution, introspection, transactions, materialization primitives, and capability declarations.
8. **Runner:** schedules DAG tasks, materializations, tests, docs generation, and artifact writes.
9. **State Store:** records runs, task state, watermarks, catalog snapshots, stage artifacts, and lineage.
10. **Cross-Database Planner:** chooses pushdown, staging, embedded execution, destination-hosted joins, and policy outcomes.

All core components above are Zig product-runtime components.

## Cross-Database Execution

Cross-database execution must separate logical transformation intent from physical execution.

Connection resources should be first-class and secret-free in project files. Runtime credentials come from profiles, environment, secret stores, or future providers.

Physical strategies:

- Full pushdown to one engine when federation or shared context supports it.
- Push down filters/projections/aggregates, stage reduced results, and join in the destination engine.
- Stream reduced results into an embedded execution backend for bounded local joins.
- Extract/stage raw inputs only as an explicit fallback with cost approval.

Planner requirements:

- Preserve source relation identity after `ref` and `source` resolution.
- Track adapter capabilities as data.
- Estimate scan bytes, moved bytes, load bytes, local spill, row counts, confidence, and query cost when available.
- Enforce movement policies before execution.
- Enforce runtime byte, row, spill, and object-count guards.
- Carry sensitivity tags through planning and deny unsafe movement.
- Record rejected strategies and plan explanations.

MVP cross-database behavior:

- Single-engine pushdown first.
- Destination-hosted staged joins for reduced subplans.
- Local embedded joins only for explicitly bounded small data.
- No distributed transactions; rely on idempotent tasks and destination-local atomic commit where available.

## Semantic Layer And Metrics

Semantic resources should enter the same graph and planner, not a separate execution path.

Required resource concepts:

- Semantic models
- Entities
- Dimensions
- Measures
- Metrics
- Join paths
- Time grains
- Freshness and cache policy

Initial milestones:

- Parse semantic YAML without losing metadata.
- Emit `semantic_manifest.json` when schema support is added.
- Validate grain and join-path constraints before execution.
- Compile metric queries into logical plans.
- Reuse cross-database pushdown, staging, and movement policy for metric execution.

Semantic query serving and external APIs are later than artifact and local CLI compatibility.

Current semantic layer source note:
`.agent/research/semantic-layer-metricflow-compatibility-map.md` maps dbt Core
v1, Fusion, dbt Semantic Interfaces, and MetricFlow references to dxt's future
semantic slices. The recommended sequence is first-class manifest resource maps,
model-attached semantic models plus simple metrics, metric dependency
resolution, saved-query parsing, `semantic_manifest.json` emission, selector
support, and only then metric query planning/execution through Zig-owned planner
modules.

## Adapter Roadmap

1. DuckDB for local public fixtures and deterministic tests.
2. Postgres for server-database semantics, transactions, schemas, and relation introspection.
3. Snowflake, BigQuery, and Redshift after adapter ABI and conformance tests stabilize.
4. Object storage/stage adapter for Parquet/Arrow staging.
5. Optional embedded execution backend for bounded cross-source joins.

Adapter certification must include capability probes and contract tests.

## Validation Harness

Build a compatibility harness that runs dbt Core and `dxt` against the same pinned fixtures into separate target directories.

Compare:

- Parse success and diagnostics.
- Resource counts by type.
- Unique IDs.
- Parent and child maps.
- Selected resource sets.
- Manifest slices.
- Compiled SQL after normalization.
- Run statuses and relation names.
- Row counts and query results for supported adapters.
- Catalog columns and types where adapter differences permit.
- JSON schema validity.

Normalize:

- Invocation IDs.
- Generated timestamps.
- Elapsed times.
- Absolute paths where dbt emits them.
- Adapter response fields known to differ.

## Source-Grounded Compatibility Method

dbt execution remains the artifact and behavior oracle, but future compatibility
slices must also name the upstream source files that define the behavior being
implemented. The public source map lives in
`.agent/research/dbt-upstream-reference-map.md`.

Every compatibility slice must record:

- dbt Core v1 source references and, when relevant, dbt Core v2 / Fusion source
  references.
- The owning dxt Zig module or planned module.
- The dbt artifact maps and pinned schemas affected.
- Native Zig tests for parser, selector, graph, manifest, Jinja, or adapter core
  logic.
- Python/dbt oracle tests for CLI, filesystem fixtures, artifact parity, schema
  validation, and public-safety boundaries.
- Stop conditions that keep mechanical extractions separate from behavior
  changes and prevent Python from crossing into product runtime behavior.

Immediate source-grounded queue, refreshed on 2026-10-09 after the public
Jaffle command gates, state:new, custom generic execution, and dict-fixture
unit-test execution slices shipped:

1. Finish issue #213's snapshot parse/list/Manifest foundation, keeping
   snapshot execution explicitly unsupported.
2. Fix physical dependency readiness and failure propagation through ephemeral
   chains before widening the current run/build support claim.
3. Preserve Run Results error rows and independent continuation for built-in
   generic and singular test SQL execution failures.
4. Schedule selected unit tests before their models in mixed seed/model/test
   builds, with deterministic blocking and rollback.
5. Implement accepted thread/full-refresh options or reject unsupported
   semantics; then ground incremental first-run/rerun/schema-change behavior.
6. Expand the native Jinja/macro context, configuration, package and state/defer
   contracts through scoped oracle-backed slices.

The complete dependency ladder and acceptance gates for Core replacement,
semantic resources, Fusion-style analysis, SQLMesh-inspired stateful planning,
and cross-database execution are in
`docs/DBT_REPLACEMENT_ROADMAP.md`. Historical research maps remain source
references, not stronger claims about the current implementation.

Each item must remain a Zig product-runtime slice with native tests first and
Python/dbt oracle coverage only for CLI, filesystem, fixture, or artifact
parity.

## Future SQLMesh Reference Track

After the dbt Core M1/M2/M3 baseline is materially stronger, evaluate SQLMesh
as an architecture reference for dxt's state store, environment model,
plan/apply explanations, interval-aware incremental execution, audits,
multi-engine gateways, adapter capability matrix, and cross-database planner.
The public planning note lives in
`.agent/research/sqlmesh-future-reference-map.md`.

This is not an active compatibility target and must not replace dbt Core/Fusion
source-grounded work. SQLMesh is useful as a design reference once dxt needs
stateful planning and multi-engine efficiency, but any adopted behavior must be
reimplemented in Zig, validated through dxt-owned tests, and namespaced unless
it is part of dbt compatibility. Avoid using SQLMesh-style "snapshot"
terminology for dxt model-version state in a way that can be confused with dbt
snapshot resources.

Future SQLMesh-inspired slices must record:

- SQLMesh upstream source/doc references and inspected commit.
- The owning dxt Zig module or planned module.
- Whether the behavior affects dbt artifacts, dxt namespaced artifacts, or only
  planner internals.
- Native Zig tests for state, planner, adapter capability, interval, audit, or
  graph logic.
- Python integration/oracle tests only for CLI, filesystem, fixture, artifact,
  or safety validation.
- Stop conditions that prevent SQLMesh-style planning from changing current dbt
  command semantics prematurely.

Current vars-backed dependency slice source note:
`.agent/research/m2-vars-ref-source-slice.md` maps upstream dbt Core v1 and
Fusion var/ref/source behavior to the narrow dxt implementation. This slice is
only scalar `var('name')` / `var('name', 'default')` dependency-argument
support for `ref()` and `source()`, not general dbt `var()` compatibility.

Current source config/freshness inheritance source note:
`.agent/research/m2-source-config-freshness-inheritance.md` maps upstream dbt
Core v1 source parser/load behavior and Fusion source resolution helpers to
dxt's source/table YAML `config:` inheritance slice. This slice resolves
literal and narrow `{{ target.schema }}` source schemas, source/table
`loaded_at_field`, `loaded_at_query`, dbt-shaped freshness inheritance,
`freshness: null`, root-project `dbt_project.yml` project-level `sources:`
configs for the same supported relation/freshness subset, and expanded
Manifest v12-shaped source fields. Source table `identifier` support is
documented separately in
`.agent/research/m2-source-table-identifier.md`. It does not implement general
Jinja in source properties, metadata freshness, source-status selectors,
installed-package project source config application, or non-DuckDB source
freshness execution.

Current source table identifier source note:
`.agent/research/m2-source-table-identifier.md` maps dbt Core v1 source
parsing and Fusion source resolution behavior to dxt's table-level
`identifier` slice. Logical source `name` remains the unique-id, selector,
FQN, and dependency key, while optional `identifier` controls physical
relation rendering for `source()` compilation, Manifest source `identifier`
and `relation_name`, DuckDB source catalog lookup, source freshness SQL, and
source generic-test SQL. Source/table database and database/schema/identifier
quoting are now covered by the source relation identity slice. It does not
implement metadata freshness or general Jinja rendering in source properties.

Current file selector source note:
`.agent/research/m2-file-selector-parity.md` maps dbt Core v1
`FileSelectorMethod` and Fusion path/selector references to dxt's first
`file:` selector slice. This slice matches selectable resource
`original_file_path` basenames and stems for `ls` and all commands that reuse
the common selector engine, including the supported Python `fnmatch` bracket
escape subset for literal `[`, `]`, `*`, and `?` filename characters.
Remaining selector gaps include YAML selectors, state/result/source-status
selectors, path normalization, richer `ls` output formats, and broader selector
dialect choices.

Current depth-limited plus selector source note:
`.agent/research/m2-depth-limited-plus-selectors.md` maps dbt Core v1
selector regex and graph-neighbor depth handling plus Fusion selector depth
serialization to dxt's first bounded parent/child selector expansion slice.
This slice supports CLI validation and selector matching for `1+model`,
`model+1`, and `1+model+1` while preserving existing unlimited `+model`,
`model+`, and `+model+` behavior. It does not implement YAML selectors,
state/result/source-status selectors, indirect-selection flags, or richer `ls`
output formats.

Current `@` selector source note:
`.agent/research/m2-at-graph-selector.md` maps dbt Core v1
`select_childrens_parents` and Fusion `childrens_parents` selector references
to dxt's first `@` graph expansion slice. This slice supports CLI validation
and selector matching for `@model`-style terms, selecting descendants plus the
parents needed for those descendants in the supported graph subset. It does not
implement YAML selectors, state/result/source-status selectors, indirect
selection flags, or richer `ls` output formats.

Current YAML selector and state/defer roadmap source note:
`.agent/research/m2-yaml-selectors-state-defer-roadmap.md` maps dbt Core v1
`selectors.yml`, `--selector`, `--state`, result/source-status selectors, and
defer flags plus Fusion selector/state references to dxt ownership boundaries
and a staged implementation sequence. The current implemented selector slices
support root-project `selectors.yml` entries whose `definition` is a scalar
string or a narrow composition of supported selector leaves through `union`,
`intersection`, and `exclude`, then lower `--selector <name>` to the existing
Zig selector and exclude expressions for commands sharing the selector engine.
They also support artifact-backed `result:*`, `source_status:*`, and first-slice
`state:new` matching through the common Zig selector engine. They do not
implement method: selector references, default selectors, indirect-selection
overrides, package/config YAML method broadening, broader state comparison, or
deferral semantics.

Current `ls` output formats source note:
`.agent/research/m2-ls-output-formats.md` maps dbt Core v1 `ListTask` output
generators and CLI `--output` choices to dxt's first richer listing output
slice. This slice supports dbt-style `name`, `path`, and `selector` outputs
alongside the existing legacy `text` unique-id output and existing JSON shape.
That slice did not implement `--output-keys`, metrics, semantic models, saved
queries, unit tests, or full dbt JSON object parity.

Current `ls --output-keys` source note:
`.agent/research/m2-ls-output-keys.md` maps dbt Core v1 `ListTask.generate_json`
and CLI `output_keys` behavior to dxt's narrow compact JSON field filter. This
slice supports `unique_id`, `resource_type`, and `name` keys for existing
selected-resource JSON output. It does not implement full dbt node JSON parity,
nested keys, metrics, semantic models, saved queries, unit tests, or additional
selected-resource JSON fields.

Current `ls --output-keys` resource-field source note:
`.agent/research/m2-ls-output-keys-resource-fields.md` maps dbt Core v1
`ListTask.generate_json`, path/name/selector generators, CLI `output_keys`
docs, and unit coverage to dxt's compact selected-resource field expansion.
This slice adds dbt-grounded `package_name`, source-only `source_name`, `path`,
and `original_file_path` keys plus `selector` as a dxt compact selected-resource
extension based on the existing selector output mode, while keeping unknown-key
skipping, repeated-key de-duplication, and requested key order. It does not
implement full dbt node JSON parity, nested keys such as
`config.materialized`, relation/config fields, metrics, semantic models, saved
queries, state/result/source-status selectors, or additional resource types.
Local dbt Core 1.10.15 still filters `output_keys` as top-level node fields;
upstream `1.latest` source has nested-key traversal here, so nested key support
became a separately scoped pinned-version compatibility slice for compact
config keys.

Current `ls --output-keys` compact config-field source note:
`.agent/research/m2-ls-output-keys-config-fields.md` maps upstream dbt Core
v1 `ListTask._get_nested_value`, `ListTask.generate_json`, CLI
`--output-keys` documentation, and nested-key unit coverage to dxt's narrow
compact selected-resource support for flat output keys `config.materialized`
and `config.tags`. This slice carries existing Zig-parsed materialization and
tag config from selected graph resources into compact JSON output while
preserving unknown-key skipping, duplicate-key de-duplication, and requested
key order. It does not implement full dbt node JSON parity, arbitrary nested
key traversal, `config.meta`, relation fields, metrics, semantic models, saved
queries, state/result/source-status selectors, or additional resource types.

Current `ls --output-keys` identity-field source note:
`.agent/research/m2-ls-output-keys-identity-fields.md` maps upstream dbt Core
v1 `ListTask.generate_json`, selected-node serialization, and CLI
`--output-keys` documentation to dxt's compact support for `alias` on
model/seed/test resources and source-only `identifier`. This slice exposes
already-parsed default and inline model aliases plus source physical
identifiers in selected-resource JSON while preserving missing-key omission for
resource types that do not carry those fields. It does not implement full dbt
node JSON parity, `fqn`, relation fields, database/schema fields, arbitrary
nested traversal, metrics, semantic models, saved queries, or state/result
selectors.

Current `ls --output-keys` dependency/config-key source note:
`.agent/research/m2-ls-output-keys-depends-config.md` maps upstream dbt Core
v1 `ListTask.ALLOWED_KEYS`, `_get_nested_value`, `generate_json`, and nested-key
unit coverage to dxt's compact support for `tags`, `config.enabled`,
`config.docs.show`, `depends_on.nodes`, and `depends_on.macros`. This slice
exposes already-resolved Zig graph tags and dependency arrays without changing
dxt's compact JSON array shape. It does not implement full dbt node JSON
parity, arbitrary nested traversal, `config.meta`, whole-object `config` or
`depends_on`, relation fields, metrics, semantic models, saved queries, or
state/result selectors.

Current analysis resource source note:
`.agent/research/m2-analysis-parse-compile.md` maps dbt Core v1
`AnalysisParser`, `analysis_paths` file routing, and listable resource values
plus Fusion `resolve_analyses.rs` / manifest path normalization to dxt's
first-class analysis resources. This slice defaults `analysis-paths` to
`analyses`, discovers root and package analysis SQL/YAML/docs, emits
`analysis.<package>.<name>` Manifest nodes with `materialized: analysis`,
supports `resource_type:analysis` and `--resource-type analysis`, applies the
current narrow YAML description/tag/column patch subset, resolves refs/sources
and known macro dependencies, and compiles selected analyses under
`target/compiled/<package>/analysis/...`. It does not implement multi-statement
analysis splitting, tests on analyses, full config precedence, custom Jinja or
macro execution, dbt docs UI parity, or DuckDB execution semantics for analyses.

Current static `{% if %}` render boundary source note:
`.agent/research/m2-static-if-render-boundary.md` maps dbt Core v1 parse/runtime
`execute` context and Fusion static source recovery to dxt's narrow render-only
compiler branch selection. This slice renders literal `true`/`false`,
`execute`, `not execute`, `is_incremental()`, `not is_incremental()`, static
`elif` chains, and simple `==` / `!=` comparisons over supported bool/string
compile-context values with `execute=true` for compile/run-style rendering and
`is_incremental()=false` until incremental materialization state exists, while
preserving raw scanner dependency recovery inside branches that may render
false. It does not implement database-backed `run_query`, adapter
introspection, filters, complex boolean expressions, or incremental
materialization semantics.

Current parse-time Jinja context boundary source note:
issue #150 adds an explicit Zig parse context in `src/project/jinja.zig` where
`execute=false`, supported parse-time `config()` returns empty text while
mutating parser-owned node config, and literal `ref()` / `source()` calls
return deterministic placeholders while preserving dependency records. It keeps
the existing raw scanner's static dependency recovery inside branches that may
render false. It does not implement general Jinja evaluation, database-backed
`run_query`, `statement`, adapter introspection, macro execution, hook hidden
dependencies, dispatch execution, or materialization lookup.

Current static loop ref/source compile source note:
`.agent/research/m2-static-loop-ref-source-compile.md` maps upstream dbt Core
v1 and Fusion compile-time `ref()` / `source()` resolution to dxt's narrow
render-only static loop-variable argument support. This slice renders
`ref(loop_var)`, `ref('package', loop_var)`, and `source('raw', loop_var)` in
the existing static string-list loop subset for `compile`, `docs generate`,
`run`, and `build`. It does not add general Jinja evaluation, dynamic lists,
inline list loops, tuple unpacking, loop metadata, filters, mutation, macro
execution, adapter dispatch execution, selector semantics, or graph dependency
changes.

Current macro argument validation source note:
`.agent/research/m1-macro-arg-validation-slice.md` maps upstream dbt Core v1
`MacroParser` and `MacroPatchParser` behavior plus Fusion macro patch references
to the narrow dxt implementation. This slice is only
`flags.validate_macro_args` macro signature argument extraction and YAML patch
argument validation/replacement for manifest artifacts, not macro execution,
namespace precedence, adapter dispatch, or Fusion-only default/type behavior.

Current macro namespace search-order source note:
`.agent/research/m1-macro-namespace-search-order-slice.md` maps upstream dbt
Core v1 `MacroNamespace`, dependency-oriented `MacroResolver`, and Fusion macro
namespace registries to dxt's static dependency lookup. This slice is only
current-package, root-project, other-package macro-body fallback, and
graph-present internal `dbt` macro lookup for `depends_on.macros`; macro
execution, adapter dispatch, bundled dbt macros, and materialization lookup
remain separate M2 work.

Current static adapter dispatch dependency source note:
`.agent/research/m2-static-adapter-dispatch-deps.md` maps upstream dbt Core v1
`BaseDatabaseWrapper.dispatch` and Fusion `DispatchObject` behavior to dxt's
static `depends_on.macros` extraction for literal `adapter.dispatch(...)` calls.
This slice records dispatch macro dependencies only. It does not execute
dispatched macros, implement project `dispatch:` config, or run adapters.

Current profile-derived adapter identity source note:
`.agent/research/m2-profile-adapter-dispatch-identity.md` maps upstream dbt Core
v1 profile/target selection, manifest `adapter_type`, and dispatch prefix
behavior plus Fusion `AdapterType` and `get_adapter_prefixes` behavior to dxt's
narrow scalar `profiles.yml` parser. This slice lets parse-time static
`adapter.dispatch(...)` dependency extraction use the selected profile output
`type`, including `redshift -> postgres -> default` and
`databricks -> spark -> default` parent fallbacks. It does not render Jinja in
profiles, validate credentials, read host-global profile locations, implement
project `dispatch:` config, execute macros, or open adapter connections.

Current DuckDB seed build source note:
`.agent/research/m3-duckdb-build-seeds.md` maps upstream dbt Core v1
`SeedParser`, `SeedRunner`, `BuildTask`, `load_agate_table`, and run-results
serialization plus Fusion seed resolution and DuckDB CSV materialization
references to dxt's first seed execution slice. This slice is only root-project
CSV seed-only `dxt build` execution through the Zig DuckDB CLI backend. It does
not add `dxt seed`, `dxt run` seed execution, package seed execution, seed
configs, mixed build DAG scheduling, tests, hooks, grants, docs persistence,
full-refresh semantics, or adapter materialization macro execution.

Current DuckDB seed config source note:
Issue #179 extends the seed execution references above for dbt Core v1
`SeedConfig`, `SeedRunner`, and DuckDB-backed CSV loading to dxt's first
supported seed config slice. This slice parses seed YAML `quote_columns` and
`column_types` for root-project and installed-package CSV seeds, emits those
dbt-shaped config fields in `manifest.json`, and applies them through DuckDB
`read_csv_auto` column-name normalization and type maps for `dxt seed` and
seed paths inside `dxt build`. It does not implement delimiter config, hooks,
grants, full-refresh behavior, full materialization macro execution, adapter
portable type coercion, or embedded `libduckdb`.

Current DuckDB generic test execution source note:
`.agent/research/m3-duckdb-generic-tests.md` maps upstream dbt Core v1
`BuildTask`, `TestRunner`, `GenericTest`, and run-result serialization plus
Fusion built-in generic-test macros and test materialization helpers to dxt's
first executable generic-test slice. This slice lets test-only `dxt build`
selections execute selected DuckDB column-level `not_null` and `unique` generic
tests against already-existing attached relations, write `pass`/`fail`
Run Results v6-shaped artifacts, and return exit code `1` on test failure. It
does not add mixed build DAG scheduling, generic macro execution,
`accepted_values`, `relationships`, singular tests, unit tests, source tests,
custom configs, `store_failures`, or package/runtime macro behavior.

Current DuckDB accepted-values generic test execution source note:
`.agent/research/m3-duckdb-accepted-values-generic-tests.md` maps upstream dbt
Core v1 schema generic-test parsing, build/test runner behavior, and
run-results serialization plus Fusion's built-in `accepted_values` SQL macro
and test materialization helpers to dxt's first executable
`accepted_values` slice. This slice lets test-only, model+test, and
seed+model+test `dxt build` selections execute selected DuckDB column-level
`accepted_values` tests with non-empty parsed values, using the dbt built-in
grouped failure-row SQL shape and existing Run Results v6-shaped artifact
behavior. The follow-up note
`.agent/research/m3-duckdb-accepted-values-quote-false.md` covers explicit
`quote: false` parser, Manifest metadata, identity, and DuckDB execution
behavior. These slices do not add generic macro execution, adapter-dispatched
test overrides, singular tests, unit tests, custom configs, typed scalar value
artifact parity, `store_failures`, or package/runtime macro behavior.

Current DuckDB relationships generic test execution source note:
`.agent/research/m3-duckdb-relationships-generic-tests.md` maps upstream dbt
Core v1 schema generic-test parsing, build/test runner behavior, and
run-results serialization plus Fusion's built-in `relationships` SQL macro and
test materialization helpers to dxt's first executable `relationships` slice.
This slice lets test-only, model+test, and seed+model+test `dxt build`
selections execute selected DuckDB column-level ref-backed and literal
source-target `relationships` tests when `to` and `field` arguments are
present, using the dbt built-in non-null child left-join failure-row SQL shape
and existing Run Results v6-shaped artifact behavior. It does not add generic
macro execution, adapter-dispatched test overrides, dynamic relationship
targets, source tests, singular tests, unit tests, custom configs,
`store_failures`, or package/runtime macro behavior. Literal source-target
relationship behavior is documented in
`.agent/research/m3-duckdb-source-target-relationships.md`.

Current DuckDB source column generic-test source note:
`.agent/research/m3-duckdb-source-column-generic-tests.md` maps upstream dbt
Core v1 source patching, source generic-test parsing, source-style test naming,
and build/test runner behavior plus Fusion `TestableTable` persistence and
source-test `attached_node` handling to dxt's first executable source column
generic-test slice. This slice parses source table columns and column-level
`tests` / `data_tests`, materializes source-style generic test nodes, and lets
selected source+test DuckDB builds execute source column `not_null`, `unique`,
default-quoted or explicit `quote: false` `accepted_values`, and ref-backed
`relationships` tests against already-existing source and target relations,
including literal `source('source', 'table')` relationship targets. The
follow-up notes `.agent/research/m3-duckdb-source-relationships-generic-tests.md`
and `.agent/research/m3-duckdb-source-target-relationships.md` cover the source
`relationships` extensions. These slices do not add generic macro execution,
adapter-dispatched test overrides, singular tests, unit tests, custom test
configs, `where`, `limit`, `severity`, `warn_if`, `error_if`,
`store_failures`, or native typed accepted-value manifest scalars.

Current DuckDB table-level generic-test source note:
`.agent/research/m3-duckdb-table-level-generic-tests.md` maps upstream dbt
Core v1 generic-test builder `column_name` argument handling, schema patch
generic-test parsing, build/test runner behavior, and Fusion data-test schemas
to dxt's first table-level built-in generic-test slice. This slice parses
explicit `arguments.column_name` on model, seed, and source table-level
`tests` / `data_tests`, materializes supported built-in generic test nodes only
when an effective column name exists, and lets selected DuckDB builds execute
table-level model, seed, and source tests through the existing direct SQL
renderer while keeping top-level test-node `column_name` null for table-level
dbt artifact parity. Literal source-target `relationships` now reuse this
effective-column path. It does not add arbitrary generic-test macro execution,
adapter-dispatched test overrides, dynamic relationship targets, custom test
configs, singular tests, unit-test execution, typed scalar accepted-value
manifest parity, `store_failures`, or package/runtime macro behavior.

Current DuckDB seed column generic-test source note:
`.agent/research/m3-duckdb-seed-column-generic-tests.md` maps upstream dbt Core
v1 seed property parsing, schema generic-test construction, build/test runner
behavior, and run-results serialization plus Fusion seed resolution and generic
data-test persistence to dxt's first executable seed column generic-test slice.
This slice parses `seeds:` YAML properties found under model and seed paths,
patches root-project CSV seed columns, materializes seed-attached generic test
nodes, emits seed columns/patch metadata in the Manifest v12-shaped slice, and
lets selected seed+test DuckDB builds execute seed column `not_null`, `unique`,
default-quoted or explicit `quote: false` `accepted_values`, and ref-backed
`relationships` tests. It does not add package seed execution, seed configs,
table-level seed tests, generic macro execution, adapter-dispatched test
overrides, singular tests, unit tests, custom test configs, `where`, `limit`,
`severity`, `warn_if`, `error_if`, `store_failures`, full dbt queue
interleaving, or native typed accepted-value manifest scalars.

Current DuckDB model and generic-test build source note:
`.agent/research/m3-duckdb-build-model-tests.md` maps upstream dbt Core v1
build runner queue/model/test behavior plus Fusion DAG and run-results
references to dxt's first mixed model+test `build` branch. This slice lets
selected DuckDB `table`/`view` SQL models execute before selected supported
column-level `not_null`/`unique`/`accepted_values`/`relationships` generic
tests, writes one Run Results v6-shaped artifact, and returns exit code `1` on
test failure. It does
not add seed+model or seed+model+test DAG scheduling, wider tests, selector
semantic changes, materialization macro execution, hooks, grants, docs
persistence, catalog introspection, threaded scheduling, or partial/failed model
run-results.

Current DuckDB seed/model/test build DAG source note:
`.agent/research/m3-duckdb-build-seed-model-dag.md` maps upstream dbt Core v1
build queue/seed/model/test behavior plus Fusion DAG and run-results references
to dxt's first selected seed/model dependency-order `build` branch. This slice
lets selected root-project DuckDB CSV seeds execute before selected dependent
DuckDB `table`/`view` SQL models, then executes selected supported column-level
`not_null`/`unique`/`accepted_values`/`relationships` generic tests, writes one
Run Results v6-shaped artifact, and returns exit code `1` on test failure. It
does not add package seeds, wider tests, full dbt queue interleaving,
skip/fail-fast
semantics, materialization macro execution, hooks, grants, docs persistence,
catalog introspection, threaded scheduling, or partial/failed model run-results.

Current project dispatch config source note:
`.agent/research/m2-project-dispatch-config.md` maps upstream dbt Core v1
project `dispatch:` validation, `get_macro_search_order`, and
`BaseDatabaseWrapper.dispatch` package/prefix search order plus Fusion
`DISPATCH_CONFIG` and `MACRO_DISPATCH_ORDER` behavior to dxt's narrow
root-project dispatch config parser. This slice lets static
`adapter.dispatch(...)` dependency extraction honor configured package
`search_order` for a literal namespace. It does not execute dispatched macros,
parse installed-package dispatch as root config, render Jinja in project config,
or run adapters.

Current target schema and `this` compile context source note:
`.agent/research/m2-target-schema-this-compile.md` maps upstream dbt Core v1
profile target context, model `this`, relation-name assignment, and compile
context behavior plus Fusion target-context and compile-context references to
dxt's narrow render-only implementation. This slice lets `compile`, `docs
generate`, and run/build preflight compile selected models with profile-derived
target schema, `target.name`, `target.target_name`, `target.schema`,
`target.type`, `target.profile_name`, `this`, `this.schema`, `this.name`,
`this.table`, and `this.identifier`. It does not implement arbitrary Jinja,
adapter-specific target fields, custom schema/alias/database generation, live
adapter connections, materialization execution, catalog introspection, or
run-results artifacts.

Current inline schema and alias relation source note:
`.agent/research/m2-inline-schema-alias-relations.md` maps upstream dbt Core v1
inline config capture, relation-name assignment, `this`, and runtime `ref`
relation behavior plus Fusion default `generate_schema_name`,
`generate_alias_name`, and relation-component resolution to dxt's narrow
render-only implementation. This slice lets `compile`, `docs generate`, and
run/build preflight render quoted literal inline `config(schema=..., alias=...)`
through dbt's default no-custom-macro relation behavior for `this`, refs to
model nodes, and compiled manifest `relation_name`. It does not implement
project/YAML `schema` or `alias` precedence, custom schema/alias macros,
database/include policy, arbitrary Jinja, live adapter connections,
materialization execution, catalog introspection, or run-results artifacts.

Current inline enabled config source note:
`.agent/research/m2-inline-enabled-config.md` maps dbt Core v1 parse-time
`config()` capture, disabled-node cleanup, and Manifest disabled maps plus
Fusion renderer/resolver disabled-map behavior to dxt's narrow literal model
`config(enabled=true|false)` parser slice. Inline-disabled SQL models reuse the
existing disabled manifest path and are excluded from active graph maps,
selectors, compile, run, and build. This slice does not implement dynamic
enabled expressions, disabled seeds/sources/tests, or full config precedence.

Current inline disabled singular SQL test source note:
`.agent/research/m2-inline-disabled-singular-tests.md` maps dbt Core v1
singular test parsing, parse-time `config()` capture, disabled-node cleanup,
and Manifest disabled maps plus Fusion renderer/resolver disabled-map behavior
to dxt's narrow literal singular SQL test `config(enabled=false)` parser
slice. Inline-disabled singular tests are emitted under `manifest.disabled` and
excluded from active graph maps, dependency resolution, selectors, compile,
test, and build. This slice does not implement YAML singular test
patches/configs, generic-test `enabled`, dynamic enabled expressions, severity
or threshold configs, `where`, `limit`, `store_failures`, or full
indirect-selection parity.

Current DuckDB SQL model run source note:
`.agent/research/m3-duckdb-run-sql-models.md` maps dbt Core v1 Run Results v6
schema and run-result processing plus Fusion run-results structs, task stats,
DuckDB profile `path`, DuckDB table/view SQL primitives, and dbt/Fusion DAG
queue ordering to dxt's first execution slice. This slice lets `dxt run`
execute selected enabled DuckDB SQL models with `table` and `view`
materializations through a Zig-owned external DuckDB CLI backend, write compiled
SQL, `manifest.json`, and a minimal success `run_results.json`, and reject
non-model selections, non-DuckDB adapters, and unsupported materializations
explicitly. It does not implement `build` execution, seeds, tests, snapshots,
incremental, ephemeral, hooks, grants, docs persistence, catalog introspection,
relation staging/backup rename parity, threaded scheduling, or embedded
`libduckdb`.

Current DuckDB run/build failure artifact source note:
`.agent/research/m3-duckdb-run-build-failure-results.md` maps dbt Core v1
Run Results v6 `error` rows, run-result processing, runnable exception/result
handling, and build runner reuse plus Fusion run-results artifact assembly to
dxt's first partial failure artifact slice. This slice lets `dxt run` and
supported DuckDB model/seed branches of `dxt build` catch model or seed
`DuckDbExecutionFailed`, append a sanitized `status: "error"` run-result row
for the failed resource after completed prior rows, write `run_results.json`,
and return exit code `1`. It does not add generic-test runtime-error rows, dbt
skip propagation, fail-fast/retry/threaded queue semantics, raw DuckDB stderr in
artifacts, relation staging/backup rename parity, incremental, ephemeral,
snapshots, hooks, grants, docs persistence, selector changes, or Python product
runtime behavior.

Current DuckDB run/build skipped-result source note:
`.agent/research/m3-run-build-skipped-results.md` maps dbt Core v1
`mark_node_as_skipped`, dependent-error marking, build runner skip handling,
Run Results v6 `skipped` status, and Fusion run-result/schedule references to
dxt's first selected blocked-resource skipped-result slice. This slice lets
`dxt run` append `status: "skipped"` rows for selected blocked model
descendants after a selected model DuckDB execution error, and lets supported
DuckDB model/seed branches of `dxt build` append skipped rows for selected
blocked seed/model descendants and selected blocked generic tests after a
model/seed DuckDB execution error. It preserves the post-`--exclude` selected
set and then writes `run_results.json` before returning exit code `1`. It does
not add full dbt queue semantics, independent-resource continuation after a
failure, test-failure-driven downstream skipping, fail-fast/retry/threaded
scheduling, generic-test runtime-error rows, selector changes, or Python
product runtime behavior.

Current DuckDB run independent failure continuation source note:
`.agent/research/m3-run-independent-continuation.md` maps dbt Core v1 runnable
task result handling, graph queue continuation, and Run Results v6 status rows
plus Fusion scheduler/run-results references to dxt's first `dxt run`
independent-resource continuation slice. This slice lets selected DuckDB SQL
models with no dependency on a failed selected model continue executing, while
selected descendants of the failed model are recorded as `skipped` rows when
encountered in dependency order. It does not add `dxt build` independent
continuation, seed command continuation, test-failure continuation, threaded
queue parity, retries/fail-fast flags, raw DuckDB stderr in artifacts, relation
staging, non-DuckDB adapters, or Python product runtime behavior.

Current DuckDB build independent failure continuation source note:
Issue #193 extends the same dbt Core v1 runnable task result handling, graph
queue continuation, and Run Results v6 status-row references to the supported
`dxt build` DuckDB subset. Selected independent seed/model/data-test resources
now continue after supported seed/model execution errors or data-test failures,
while selected blocked descendants and data tests are recorded as `skipped`
rows when their blocked dependency is encountered. This does not add threaded
queue parity, retries/fail-fast flags, unsupported resource execution, raw
adapter errors in artifacts, snapshots, incremental models, hooks, grants,
full materialization macro execution, or Python product runtime behavior.
Issue #197 adds focused pytest coverage for a selected seed execution error
that skips the blocked model/test branch while a later independent selected
seed/model/test branch still writes success/pass run-result rows.

Current DuckDB docs catalog source note:
`.agent/research/m3-duckdb-docs-catalog.md` maps dbt Core v1 docs catalog
generation and Fusion legacy catalog schemas to dxt's first DuckDB-backed
`catalog.json` introspection slice. This slice lets `dxt docs generate` keep
the existing empty catalog when no local DuckDB database exists, and emit
selected model/seed catalog node entries and selected source catalog entries
with relation metadata and ordered columns when the selected relations already
exist in the target DuckDB file. It does not execute resources during docs
generation, implement source relation config overrides, source freshness,
comments, owners, stats beyond `has_stats`, non-DuckDB adapters, browser/UI
assets, or embedded `libduckdb`.

Current static docs serve source note:
`.agent/research/m3-docs-serve-static.md` maps dbt Core v1 `docs serve` and
Fusion docs serve references to dxt's first static target-directory server. The
slice adds `dxt docs serve` in Zig, resolves the project target directory,
writes a small dxt-owned `index.html`, serves existing generated docs artifacts
over localhost HTTP, parses dbt Core-style `--host`, `--port`,
`--browser`/`--no-browser` and Fusion-style `--no-open`, rejects traversal
paths, and keeps `manifest.json` and `catalog.json` unchanged. Browser opening,
dbt's bundled docs SPA, Fusion docs v2/index API endpoints, live reload,
directory listings, TLS, and docs artifact generation inside `docs serve`
remain out of scope.

Current clean command source note:
`.agent/research/m1-clean-command.md` maps dbt Core v1 `clean` and Fusion clean
safety references to dxt's first destructive filesystem command slice. The
slice adds `dxt clean` in Zig, parses `clean-targets`, defaults to the
effective target path when `clean-targets` is omitted, accepts
`--project-dir`, `--profiles-dir`, `--target-path`, `--vars`, and
`--clean-project-files-only`, rejects `--no-clean-project-files-only`, absolute
or parent-traversing targets, project-root targets, and protected source
directories, skips missing paths and plain files, and does not require a
profile. Fusion positional file args, outside-project deletion, symlink/canonical
path parity, richer event output, graph loading, adapters, and artifact writes
remain out of scope.

Current DuckDB source freshness source note:
`.agent/research/m3-duckdb-source-freshness.md` maps dbt Core v1
`FreshnessRunner`, `FreshnessSelector`, and Sources v3 artifact behavior plus
Fusion freshness artifact structs and source-status selector inputs to dxt's
first `sources.json` execution slice. This slice lets `dxt source freshness`
select source nodes with table-level freshness criteria, query selected DuckDB
source tables through table-level `loaded_at_field` SQL text and optional raw
`freshness.filter` SQL or through table-level raw `loaded_at_query` SQL,
classify `pass` / `warn` / `error`, write dbt-shaped success and runtime-error
rows to `sources.json`, treat empty or all-null loaded-at results as stale
freshness results, and return failure when freshness status is `error` or a
runtime-error row is produced. It does not implement source-level inheritance,
Jinja rendering inside `loaded_at_query`, metadata freshness, `config:`
overrides, hooks, concurrency, non-DuckDB adapters, or embedded `libduckdb`.

Current source-status selector source note:
Issue #192 adds the first read-only Sources v3 state input for selectors. When
a resolved selector expression contains `source_status:pass`,
`source_status:warn`, or `source_status:error`, commands that reuse the shared
Zig selector engine can read `--state/sources.json`, validate the dbt Sources
v3 schema URL, index result `unique_id` / `status` rows, and match source
nodes plus graph expansions such as `source_status:warn+`. This slice does not
implement `state:`, `result:`, `source_status:fresher`, manifest comparison,
deferral, source freshness execution changes, metadata freshness, or
non-DuckDB adapter behavior.

Current result selector source note:
Issue #198 adds the first read-only Run Results v6 state input for selectors.
When a resolved selector expression contains `result:error`, `result:fail`,
`result:success`, or `result:skipped`, commands that reuse the shared Zig
selector engine can read `--state/run_results.json`, validate the dbt Run
Results v6 schema URL, index result `unique_id` / `status` rows, and match
graph resources plus expansions such as `result:error+`. This slice does not
implement broader `result:` statuses, `state:`, manifest comparison, deferral,
retry selection, partial-parse cache behavior, or run-result writing changes.

Current DuckDB test command source note:
`.agent/research/m3-duckdb-test-command.md` maps dbt Core v1 `TestTask`,
`TestRunner`, build/test runner reuse, and selector test-type behavior plus
Fusion command/data-test/run-results references to dxt's first `dxt test`
command slice. The follow-up `.agent/research/m3-duckdb-singular-tests.md`
extends that command path to singular SQL data tests. Together these slices
execute selected supported DuckDB generic test nodes and singular SQL test nodes
against already-existing target relations, write `manifest.json`, write Run
Results v6-shaped pass/fail rows, and return exit code `1` on test failures.
They do not build parent models or seeds, execute unit tests, run custom generic
test macros, honor singular YAML patches or test configs such as
`where`/`limit`/`severity`/`warn_if`/`error_if`, store failures, change
indirect-selection semantics, or add Python product runtime behavior.

Current DuckDB generic-test config/severity source note:
`.agent/research/m3-duckdb-generic-test-configs.md` maps upstream dbt Core v1
generic-test config parsing, test materialization threshold handling, and
Manifest/Run Results fields plus Fusion built-in generic-test helper references
to dxt's first config slice for supported built-in DuckDB generic tests. This
slice parses `where`, `limit`, `severity`, `warn_if`, `error_if`, and
`store_failures` for model, seed, and source generic tests, emits the supported
Manifest config fields, applies `where` and `limit` to supported built-in
failure-row SQL, classifies pass/warn/fail statuses from simple integer
failure-count threshold comparisons, and optionally persists DuckDB audit
failure tables. It does not implement `store_failures_as`, custom generic-test
macro execution, adapter-dispatched generic-test overrides, unit-test execution,
full indirect-selection parity, or a general expression evaluator.

Current compile singular-test source note:
`.agent/research/m2-compile-singular-tests.md` maps dbt Core v1
`CompileTask`, `Compiler.compile_node`, singular test parser/path behavior, and
CompiledNode artifact fields plus Fusion Manifest v12 compiled SQL maps to
dxt's narrow compile artifact slice for singular SQL data tests. This slice lets
`dxt compile` select supported singular SQL tests, render them through the
existing Zig compile context, write compiled SQL under
`target/compiled/<package>/tests/...`, and emit compiled Manifest fields only
for selected compiled singular test nodes. It does not compile generic tests,
honor singular YAML patches/configs, execute DuckDB, write run-results, change
indirect-selection semantics, or expand the general Jinja/macro runtime.

Current compile generic-test source note:
`.agent/research/m2-compile-generic-tests.md` maps dbt Core v1 compile/test
node behavior, generic test compiled-node artifact fields, Fusion Manifest v12
compiled SQL maps, and Fusion bundled built-in generic-test SQL to dxt's narrow
compile artifact slice for already-supported built-in generic data tests. This
slice lets `dxt compile` select supported `not_null`, `unique`,
`accepted_values`, and `relationships` generic tests, write compiled failure-row
SQL under `target/compiled/<package>/<test_alias>.sql`, and emit compiled
Manifest fields without opening DuckDB or writing `run_results.json`. It does
not add custom generic macro execution, generic test configs, `store_failures`,
new test types, or adapter dispatch execution.

Current package custom generic-test compile source note:
`.agent/research/m2-package-custom-generic-tests.md` maps dbt Core v1
namespaced generic-test parsing and compile artifact behavior to dxt's narrow
installed-package custom generic-test compile slice. This slice lets root
project model-column YAML tests call installed-package `{% test %}` or
`{% data_test %}` blocks through `package_name.test_name`, emits dbt-shaped
`raw_code`, `test_metadata.namespace`, macro dependencies including the package
test macro and `macro.dbt.get_where_subquery`, and writes selected compiled SQL
for static bodies that use only `{{ model }}` and `{{ column_name }}`. Issue
#199 extends the same compile-only custom generic-test boundary to source and
seed column YAML tests, including dbt-shaped source synthetic names,
`attached_node: null` for source tests, seed `attached_node`, dependency
fields, and compiled manifest fields. It does not execute custom generic tests
in `dxt test` or `dxt build`, support table-level or non-column custom tests,
execute adapter dispatch, or add general Jinja/macro behavior.

Current DuckDB custom generic-test execution source note:
Issue #212 moves that same already-compiled static custom generic-test subset
into `dxt test` and `dxt build` execution for model, seed, and source column
tests against DuckDB. Supported root-project and installed-package custom test
macros still must be `{% test %}` or `{% data_test %}` blocks with exactly
`model` and `column_name` parameters and bodies containing only static SQL plus
`{{ model }}` and `{{ column_name }}`. They reuse the Zig failure-row SQL
wrapper, simple severity/threshold classification, `where`/`limit`, optional
`store_failures`, and Run Results v6-shaped pass/fail/warn rows; custom-test
DuckDB execution errors write deterministic `status: "error"` rows with
compiled SQL. It does not implement table-level or non-column custom tests,
adapter-dispatched overrides, broader Jinja/macro execution, `store_failures_as`,
SQL headers, custom materializations, bundled dbt internal macro execution, or
Python product runtime behavior.

The next source-grounded M1/M2 slices after macro block variant support are:

1. Extend the render-only artifact boundary to adapter-free docs generation:
   route `dxt docs generate` through the Zig parser graph, apply `--select` and
   `--exclude` to compiled SQL model output, render supported `config`, literal
   `ref`, scalar `var()`-backed `ref`, literal `source`, and scalar
   `var()`-backed `source` calls without executing SQL, write compiled SQL
   under `target/compiled/<package>/...`, emit compile fields only for compiled
   model nodes, write `manifest.json`, and write an empty dbt-shaped
   `catalog.json` until adapter introspection exists. Stop before macro
   execution, materializations, tests, DuckDB connections, non-empty catalog
   introspection, `run_results.json`, or docs serving.
2. Continue M3 execution from the narrow `dxt run` DuckDB SQL-model slice:
   replace the external CLI backend with an embedded adapter ABI or keep the CLI
   isolated behind that ABI, add proper task timing/adapter responses, and then
   extend execution to `build` DAG ordering only after seeds/tests have their own
   source-grounded slices. Stop before mixing adapter packaging, seed loading,
   generic test execution, and DAG scheduling into one PR.
3. Finish macro patch and namespace parity beyond the current macro artifact
   surface: parser-controlled macro argument extraction when the dbt
   `validate_macro_args` behavior is exposed, macro patch validation, macro
   `docs`/`meta` patch fields, duplicate patch diagnostics, and namespace
   precedence, using v1 `MacroParser`, `MacroPatchParser`, and
   `MacroNamespaceBuilder` plus v2 macro resolution and dependency listener
   behavior.
4. Start the M2 parse-time Jinja context boundary with explicit `execute=false`
   semantics, using v1 providers and v2 renderer/dbt namespace interception as
   references.
5. Grow artifact schema coverage only alongside emitted fields, using v1 JSON
   schemas and v2 manifest builder behavior while keeping dxt-specific metadata
   out of dbt schemas.
6. Continue adapter relation identity beyond the current two-part
   profile-schema relation rendering and literal inline schema/alias defaults:
   project/YAML config precedence, database include policy, quoting config,
   adapter-specific target fields, custom schema/alias/database macro
   execution, versioned alias defaults, and source/model relation parity, using
   v1 compile runner/compiler behavior plus v2 adapter core/SQL identity
   references.

## Fixture Ladder

Tier 0 synthetic fixtures:

- One standalone model.
- Two models with `ref`.
- One source and model with `source`.
- YAML properties with columns, descriptions, tags, meta, and tests.
- One macro.
- One docs block and `doc`.
- One exposure.
- One disabled model.
- Custom path config.

Tier 1 DuckDB execution:

- Seeds.
- Table and view models.
- Ephemeral model.
- Generic tests: model column and explicit table-level `column_name` `unique`,
  `not_null`, default-quoted and explicit `quote: false` `accepted_values`,
  and ref-backed `relationships` are started; source column and explicit
  table-level `column_name` `not_null`, `unique`, and default-quoted or
  explicit `quote: false` `accepted_values`, and ref-backed `relationships`
  are started; root-project CSV seed column and explicit table-level
  `column_name` `not_null`, `unique`, default-quoted or explicit
  `quote: false` `accepted_values`, and ref-backed `relationships` are
  started; wider generic-test config parity remains.
- Singular test.
- Simple incremental model.
- Docs generation and catalog introspection.

Tier 2 packages and macros:

- Local package with cross-package `ref`.
- Macro override.
- Adapter dispatch.
- Package-provided generic test.
- Selector YAML.

Tier 3 state/defer:

- Baseline manifest and run results.
- Modified model body.
- Modified config.
- Modified seed.
- New downstream model.
- Deferred upstream relation.

Tier 4 multi-adapter:

- Postgres container fixture.
- Parse/compile-only cloud profile fixtures.
- Optional live warehouse smoke tests gated by environment variables.

Public fixtures:

- `dbt-labs/jaffle_shop_duckdb`
- `dbt-labs/jaffle-shop`
- `dbt-labs/jaffle-shop-classic`
- `dbt-labs/dbt-learn-demo`
- `gmyrianthous/dbt-dummy`
- Pinned projects from public dbt project indexes after review.

## Milestones

### M0: Repository Baseline

Deliverables:

- Public-safe README, plan, agent rules, security policy, and ignore rules.
- Minimal Zig package skeleton and native CLI entrypoint.
- Minimal tests and local verification command.
- Initial commit and remote setup.

Exit criteria:

- `zig build` passes.
- `zig build test` passes.
- Native CLI smoke tests pass.
- Developer-side `pytest` passes while Python utility tests remain.
- No committed local paths or secrets.
- `PLAN.md` exists and is current.

### M1: Artifact-First Parser

Deliverables:

- Project loader.
- YAML config/property parser.
- SQL/Jinja dependency extractor.
- Graph builder.
- Basic selector engine for names, tags, paths, resource types, `+`, and `--exclude`.
- `manifest.json` writer.
- dbt oracle tests for Tier 0.

Exit criteria:

- Tier 0 fixtures pass.
- Jaffle Shop DuckDB parses.
- Manifest validates against pinned schema slices.

### M1A: Architecture And Test Structure Hardening

Purpose:

- Shrink `src/project.zig` from a mega-file into a thin public/orchestration facade while preserving dbt Core behavior.
- Keep runtime behavior Zig-first and keep Python as integration, compatibility, schema, fixture, and safety tooling only.
- Build a clearer testing pyramid so core parser/selector/graph/manifest logic has fast native Zig coverage and fixture-heavy/dbt-oracle behavior stays in pytest.

Target module layout:

```text
src/
  main.zig
  root.zig
  project.zig
  project/
    types.zig
    util.zig
    config.zig
    fs.zig
    loader.zig
    parse.zig
    jinja.zig
    resolve.zig
    selector.zig
    json.zig
    manifest.zig
```

Staged extraction order:

1. Extract `src/project/types.zig` for `Runtime`, `Options`, graph/resource/config structs, and data-model deinit helpers.
2. Extract selector parsing, wildcard matching, resource matching, and graph expansion into `src/project/selector.zig`, carrying selector Zig tests with the module.
3. Extract selected-resource JSON and `manifest.json` writers into `src/project/manifest.zig`, carrying JSON escaping and deterministic ordering tests with the module.
3a. Centralize artifact/string JSON emission helpers in `src/project/json.zig` before broadening artifact schemas, so manifest, run-results, catalog, and sources writers share Zig `std.json` escaping and native tests instead of per-module ad hoc helpers.
4. Extract shared path/string/YAML scalar/sort/hash helpers into `src/project/util.zig` only when at least two modules need them.
5. Extract config, filesystem discovery, loader orchestration, resource parsing, Jinja scanning, and dependency resolution in that order, keeping imports acyclic: `types`/`util` first, then `jinja`/`parse`/`selector`/`manifest`, then `loader` and the `project.zig` facade.

Validation gates:

- After each mechanical extraction: `zig fmt --check` on touched Zig files and `zig build test`.
- When CLI, artifact shape, fixtures, selectors, or manifests are touched: `pytest -q tests/test_cli.py`.
- Before merging an architecture slice: `zig build`, `zig build test`, `pytest -q`, `python scripts/check_runtime_boundary.py`, `python scripts/check_public_safety.py`, and `git diff --check`.

Risk and rollback notes:

- Zig file-level privacy can force temporary `pub` exposure across internal modules. Prefer internal module imports over re-exporting from `root.zig`; only public API should be exposed by `root.zig`.
- Keep extraction commits behavior-preserving. If a move requires semantic changes, stop and split the behavior change into a separate feature slice with dbt oracle evidence.
- Avoid import cycles by moving shared helpers downward into `types` or `util`, never upward into `loader` or `project.zig`.
- Roll back a failed extraction by reverting the extraction commit rather than editing unrelated parser or selector behavior.

Stop conditions:

- Stop after any extraction if `zig build test` fails for a reason that is not a direct import/privacy fix.
- Stop before further extraction if the diff mixes mechanical moves with behavior changes that need dbt Core oracle review.
- Stop before pushing if the worktree contains generated targets, logs, caches, local paths, secrets, or unrelated changes.

### M2: Compiler And Macro Core

Deliverables:

- Jinja environment.
- dbt context functions.
- Macro registry and namespace resolution.
- Basic adapter dispatch.
- Ephemeral CTE injection.
- Compiled SQL outputs.
- Narrow source-grounded compile-time Jinja slices may land before the full
  engine when they unblock public fixtures, but each must name the dbt Core v1
  and Fusion source references, stay in Zig, and reject unsupported Jinja
  shapes loudly.

Exit criteria:

- Tier 0 and Tier 1 compile-only cases pass.
- Compiled SQL matches dbt on supported fixtures after normalization.

### M3: DuckDB Execution MVP

Deliverables:

- DuckDB adapter.
- Seed loading.
- Table/view materializations.
- Generic tests.
- DAG scheduler.
- `run_results.json`.
- Minimal `catalog.json` and `docs generate`.

Exit criteria:

- Jaffle Shop DuckDB runs through `build` and `docs generate`.
- Row counts, tests, and core artifacts match expected baselines.

### M4: Packages And Custom Macros

Deliverables:

- Package loader.
- Local/Git/dbt Hub dependency strategy.
- Lock handling.
- Dispatch config.
- Package-provided tests and macros.

Exit criteria:

- Tier 2 fixtures pass.
- At least one package-heavy public project parses and compiles.

### M5: Selectors, State, And Defer

Deliverables:

- Full selector methods.
- YAML selectors.
- State manifest comparison.
- Result selectors.
- Deferred relation resolution.
- `--defer-state` and `--favor-state`.

Exit criteria:

- Tier 3 fixtures pass against dbt oracle output.
- CI-style selection commands match dbt selected sets.

### M6: Snapshots, Incremental Matrix, And Postgres

Deliverables:

- Snapshot strategies.
- Incremental strategy matrix.
- Broader source freshness and `sources.json` parity.
- Unit tests.
- Postgres adapter.
- Adapter contract suite.

Exit criteria:

- Tier 4 Postgres fixture passes.
- Adapter certification suite is required for new adapters.

### M7: Cross-Database Planner

Deliverables:

- Multiple named connections.
- Adapter capability matrix.
- Logical plan splitting.
- Rule-based physical strategy selection.
- Staging metadata.
- Destination-hosted staged joins.
- Cost report and movement policies.
- SQLMesh-inspired gateway and virtual-layer design review, after dbt-compatible
  adapter ABI and manifest/run artifact behavior are stable enough to avoid
  changing the active dbt contract.

Exit criteria:

- Same-engine plans produce no dxt-managed movement.
- Small dimension broadcast scenario passes.
- Movement policy rejection fails before source execution.

### M8: Semantic Artifacts And Metric Planning

Deliverables:

- Semantic YAML parser.
- Semantic manifest emitter.
- Grain and join-path validation.
- Metric query logical plans.
- Metric materialization through the runner.

Exit criteria:

- Semantic fixtures validate.
- Metric fanout errors fail before execution.
- Simple metrics execute through DuckDB and cross-database planner where supported.

### M9: Fusion-Style Static Analysis

Deliverables:

- SQL parser-backed logical IR for supported dialects.
- Static diagnostics.
- Plan explanation.
- Incremental parse cache.
- Performance budgets.

Exit criteria:

- Parse/compile performance is measured against dbt Core on medium fixtures.
- Diagnostics are stable and location-aware.

### M10: Public Release Discipline

Deliverables:

- GitHub repository under `sabino/dxt`.
- Branch protection and required checks.
- CI for lint, tests, package, and secret/path scans.
- Release packaging.
- Changelog and versioning policy.

Exit criteria:

- PRs merge after green required checks; second-agent or human review is optional unless explicitly requested for that PR.
- Release artifacts install and run smoke tests.
- Package scans show no secrets or local paths.

## Risks

- Jinja semantic drift.
- Macro dispatch complexity.
- Artifact schema fidelity.
- State/defer correctness.
- Adapter-specific behavior leaking into the compiler.
- Incremental and snapshot correctness.
- Package resolution and locks.
- Profile rendering and credential safety.
- Partial parsing invalidation.
- dbt version drift.
- Fusion feature ambiguity.
- Premature SQLMesh-style planning that changes dbt command semantics before
  dbt Core parity is strong enough.
- Test ID and selector edge cases.
- Catalog differences by adapter and permissions.
- Cross-engine semantic differences for nulls, timestamps, collations, decimals, JSON, and nondeterministic functions.
- Data movement cost estimate drift.
- Partial failures leaving stage artifacts or temp relations.
- Sensitive data movement across trust boundaries.
- Concurrent agents editing the same Zig module or fixture can create semantic
  conflicts even when Git merges cleanly.
- Dirty worktrees can make validation results ambiguous.
- Local run notes, absolute paths, shell history, session transcripts, and raw
  Codex output can leak if copied from `.agent/runs/` into tracked docs without
  scanning.
- Stacked worktree branches can pass locally but fail after upstream PRs merge
  unless rebased and revalidated.
- GitHub Projects can drift from repo-local manifests if labels, project fields,
  or seed issues are edited manually without re-running the Agent OS bootstrap
  checks.
- Autonomous local workers can make progress without a human in the loop, but
  they must still use one issue, one branch, and one worktree per slice, and
  merge only after green checks.

## Historical Implementation Notes

These notes record earlier slices and their original boundaries. The active
Full Usability Implementation Campaign above and the replacement roadmap govern
current scope, known gaps, validation evidence and release status.

- Issue #213 adds the read-only SQL snapshot foundation: default/configured
  root and installed-package discovery, named blocks, literal configs, disabled
  nodes, static dependencies, Manifest v12 fields and shared selectors. The
  source map and pinned Core oracle contract are documented in
  `.agent/research/m1-snapshot-parse-list.md`. Snapshot compilation/execution,
  YAML snapshot definitions/properties and project snapshot config inheritance
  remain explicit follow-up boundaries.

- The Manifest node identity/checksum (#187), store-failures (#180), source
  config (#181), public Jaffle command ladder, state:new and supported custom
  generic/unit execution slices are shipped. Their earlier ownership notes
  are historical; issue #213 is the active snapshot foundation described
  above. Broader replacement gates are tracked in
  `docs/DBT_REPLACEMENT_ROADMAP.md`.
- M0 is complete as the Zig `0.16.0` runtime scaffold.
- GitHub-backed agent coordination now has repo-local issue forms, label/project
  manifests, seed issue definitions, project-scoped specialist roles,
  including a product-manager board monitor role, developer-side
  bootstrap/validation scripts, and a local autonomous
  orchestrator that can claim ready issues, spawn Codex worker subprocesses in
  isolated worktrees, record ignored state/logs, accept issue-comment nudges,
  and merge green PRs when explicitly run with merge enabled. The supervisor
  loop now builds a principal snapshot of ready issues, active worker state,
  git worktrees, open PRs, dependency comments, changed PR files, merge state,
  and CI checks before launches or merges, and the merge-ready queue skips draft,
  red, conflicting, overlapping, or dependency-blocked PRs while posting fan-in
  summaries back to linked issues after applied merges. The local
  supervision layer includes a detached `codex exec` pull-plug handoff and a
  two-phase tmux/Hermes watchdog path for exact-terminal Codex restarts after
  project-scoped `.codex/` changes. The product-manager prompt and docs now
  require roadmap-gap issue creation when the queue is empty or stale, define
  the PM-created issue contract, and expose board/roadmap context in dry-run
  output. Project item sync can dry-run or apply unambiguous field
  reconciliation from labels and public `dxt-agent-event` comments for role,
  status, validation, source grounding, readiness, branch, and dependency
  fields. Agent OS cleanup now has a dry-run-first command that reports exited
  stale runs, clean merged agent worktree removal candidates, and stale
  `status:claimed` labels before any `--apply` action. Creating/updating the
  live GitHub Project requires GitHub CLI project scopes.
- Multi-agent development now has a dedicated worktree workflow under
  `docs/MULTI_AGENT_WORKFLOW.md`, with project-scoped Codex agent roles under
  `.codex/agents/` and helper scripts for starting, finishing, and pruning
  worktrees.
- CI now separates native Zig/safety gates, Python integration matrix gates, and
  a public Jaffle parse/ls/compile/build/run/docs compatibility gate with a pinned,
  checksum-verified DuckDB CLI.
  Pytest jobs emit JUnit reports for review, and local development guidance now
  favors focused pytest runs plus native/safety gates instead of full local
  pytest after every small slice. The main CI workflow cancels superseded branch
  and PR runs, uses bounded job timeouts, and a separate GitHub `Coverage`
  workflow collects native Zig test coverage map artifacts for Zig source or
  build-file PRs, pushes to `main`, and manual coverage runs. This first
  coverage artifact reports native test declarations by source module rather
  than line coverage, avoiding misleading Python coverage claims for the Zig
  runtime. The public Jaffle job fetches the pinned fixture checkout once per
  run and passes it to all six public harnesses to avoid repeated public
  network clones. Release packaging now has a reusable developer-side archive
  safety validator that checks tarball shape, version/target naming, allowed
  members, binary/doc string leaks, executable metadata, and checksum coverage
  before upload.
- M1 has started on stacked branches with native Zig artifact-first parser slices.
- M1A has started with behavior-preserving `src/project/types.zig`, `src/project/selector.zig`, `src/project/manifest.zig`, `src/project/util.zig`, `src/project/config.zig`, `src/project/fs.zig`, `src/project/jinja.zig`, `src/project/resolve.zig`, `src/project/parse.zig`, `src/project/loader.zig`, and `src/project/json.zig` extractions. `src/project/json.zig` centralizes shared JSON string, nullable-string, boolean, object string-field, and string-array emission on top of Zig `std.json` with native tests, and is used by the manifest, run-results, catalog, and sources artifact writers. `src/project/manifest.zig` owns selected-resource JSON and partial `manifest.json` writing with native tests for selected JSON shape, JSON escaping, exposure dependency ordering, disabled-resource filtering, graph-map output, and macro `supported_languages` emission. `src/project/util.zig` owns shared display, membership, append-dedup, string sorting, and narrow YAML scalar/list helpers. `src/project/config.zig` owns `dbt_project.yml` loading, project path/docs config parsing, narrow scalar top-level `vars` parsing, CLI `--vars` scalar map parsing, and applying parsed project path/docs configs to graph nodes. `src/project/fs.zig` owns deterministic resource file discovery, Linux directory traversal helpers, and resource path/name helpers. `src/project/jinja.zig` owns lexical Jinja call, parenthesis, quoted string, literal and var-backed argument helpers, supported model SQL scanning, inline config/tag parsing, and known macro-call scanning with native tests. `src/project/resolve.zig` owns graph lookup/count helpers, canonical graph resource ordering, duplicate resource validation, macro unique-id package extraction, low-level ref/source resolution helpers, and dependency-map mutation for refs, sources, and known macro dependencies. `src/project/parse.zig` owns narrow parser scalar helpers for YAML booleans, JSON-compatible scalar classification, source YAML table parsing, exposure YAML resource parsing, current top-level `{% macro %}`, `{% test %}`, `{% data_test %}`, and `{% materialization %}` block parsing, materialization `supported_languages` parsing, macro property YAML parsing, generic-test YAML item names, generic-test definition construction/cloning, generic-test relationship target ref parsing, exposure dependency parsing, exposure meta parsing, macro-property application, and generic-test identity/name/hash helpers with native tests. `src/project/loader.zig` owns graph loading order, target-path lookup, project/package resource traversal, root project and CLI vars application, macro/property application sequencing, duplicate checks, and graph sorting while using explicit callbacks into parser helpers that still live in the facade. `src/project.zig` remains the public parser/list facade and still owns docs block parsing, YAML model property parsing, model/seed parsing, generic-test materialization, warnings, and some resolver orchestration until follow-up extractions move those pieces behind focused internal modules.
- CI format validation now covers every tracked Zig source file under `src/`, including extracted `src/project/*.zig` modules, so M1A module splits remain under the same formatting gate as the root CLI files.
- `dxt parse` now targets the supported Tier 0 subset: project name/model paths/analysis paths/seed paths/macro paths/test paths, target path, narrow top-level scalar project `vars`, CLI `--vars` scalar overrides including strict JSON object input with stringified scalar values parsed through Zig `std.json` plus the existing loose inline YAML-style scalar maps, project and package model path configs for literal `+materialized`, `+tags`, and model/seed `+docs.node_color`, root-project model config overrides for installed packages, SQL model discovery, SQL analysis discovery from configured `analysis-paths` / default `analyses`, CSV seed discovery, installed package SQL model, SQL analysis, and CSV seed discovery from `dbt_packages`, source discovery, installed package source discovery, exposure discovery, installed package exposure discovery, singular SQL test discovery under configured `test-paths` while skipping `generic/` and `fixtures/`, root-project unit-test discovery for dict-style YAML `given`/`expect` row fixtures, project macro discovery, dbt-shaped generic test macro and materialization macro block discovery, installed package macro discovery from `dbt_packages`, macro property YAML for project macro descriptions, arguments, `docs`, and scalar JSON-compatible `meta`, project and package docs block discovery, literal, narrow scalar `var('name')` / `var('name', 'default')`-backed, and static string-list loop-var `ref` to models or seeds, two-argument package refs, package-local refs in installed package models, analyses, and exposures, unique installed-package fallback for unqualified refs, literal, narrow scalar `var('name')` / `var('name', 'default')`-backed, and static string-list loop-var `source`, package-local sources in installed package models and analyses, unique installed-package fallback for unqualified sources, literal `doc` in project and package descriptions, inline model/analysis `config(tags=..., enabled=...)`, inline model `config(materialized=...)`, inline singular SQL test `config(enabled=false)`, known project/package-qualified/package-local macro call dependencies, narrow project and package YAML model/analysis properties for scalar descriptions, simple columns, tags, materialization for models, disabled SQL models/analyses, dbt-shaped `unique`, `not_null`, `accepted_values`, and `relationships` generic test nodes including literal source-target relationship dependencies, active singular SQL test nodes with supported top-level `tests:` / `data_tests:` YAML patches for description, config tags, enabled, severity, warn/error thresholds, `where`, and `limit` without generic-only fields, disabled singular SQL tests from inline or YAML config under `manifest.disabled`, model/analysis/test `refs` and `sources` artifact fields, dependency maps including enabled singular tests and unit tests depending on their tested model, and deterministic partial `manifest.json`. The manifest includes the v12 top-level maps needed by the M1 artifact shape, including non-empty `unit_tests`, and is covered by a pinned local dbt Manifest v12 schema slice. YAML generic test arguments are currently supported for scalar values plus inline and block lists required by public Jaffle Shop DuckDB-style tests. Multi-statement analysis splitting, tests on analyses, dynamic singular-test `enabled`, generic-test `enabled`, CSV/SQL unit-test fixtures, unit-test overrides, version expansion, disabled-unit-test placement changes, and broader unit-test SQL comparison parity remain explicitly deferred. Full dbt `var()` semantics remain explicitly deferred until the parse/compile Jinja context work covers package scoping, `vars.yml`, non-string values, rendered var values, `has_var`, missing-var parse/runtime behavior, project/profile rendering, and partial-parse invalidation.
- `dxt ls` now lists dbt-selectable resources from the same parser graph, including scalar project/CLI var-resolved and static string-list loop-resolved dependency edges, with stable legacy text, compact JSON with narrow resource/config/identity/dependency `--output-keys` including `unique_id`, `resource_type`, `name`, `package_name`, source-only `source_name`, `alias`, source-only `identifier`, `path`, `original_file_path`, `tags`, `config.materialized`, `config.tags`, `config.enabled`, `config.docs.show`, `depends_on.nodes`, `depends_on.macros`, and `selector`, dbt-style name, path, and selector output, and basic name/FQN wildcards, tag wildcards, slash-aware `path:` wildcards, `file:` basename/stem selectors, fnmatch-style bracket character classes for selector wildcards, exact `package:`/`package:this`, `source:` wildcards including package-qualified source selectors, `source_status:pass` / `source_status:warn` / `source_status:error` from a dbt Sources v3 `--state/sources.json` input, `exposure:` wildcards, `unit_test:` selectors for unit-test resources, `resource_type:` including analyses, `test_type:generic`, `test_type:singular`, `test_type:data`, `test_type:unit`, config materialization, comma intersection, whitespace union, multi-argument selector lists, repeated selector flags, root `selectors.yml` scalar aliases plus narrow YAML `union`/`intersection`/`exclude` composition over supported selector leaves, leading/trailing and depth-limited `+` graph expansion, `@` graph expansion, and exact exclude filters; macros are emitted in artifacts but not exposed as `ls` resources.
- `dxt clean` has started as a source-grounded filesystem command. It parses project `clean-targets`, defaults omitted `clean-targets` to the effective target path, deletes only project-relative directories, protects model/seed/macro and common dbt source directories, rejects outside-project deletion including `--no-clean-project-files-only`, skips missing paths and plain files, and does not require profile configuration. It does not load the graph, write artifacts, execute adapters, support selectors, delete outside the project, or support Fusion positional file args.
- `dxt compile` has started as a render-only M2 boundary for the current graph subset. It loads and resolves the same Zig parser graph, applies `--select` and `--exclude`, compiles selected enabled SQL model nodes, selected enabled analysis nodes, selected supported built-in generic test nodes, selected supported column-level custom generic test nodes, and selected enabled singular SQL test nodes, writes compiled SQL under `target/compiled/<package>/...`, and emits `compiled`, `compiled_code`, `compiled_path`, `extra_ctes`, and `extra_ctes_injected` for compiled model, analysis, and data-test nodes while model nodes also emit `relation_name` and analysis nodes emit `relation_name: null`. The current compiler renders `config` to empty text, literal, narrow scalar var-backed, and static string-list loop-var `ref`/`source` calls to deterministic quoted relation names, profile-derived `target.*`, current-model `this`, quoted literal inline `config(schema=..., alias=...)` as default dbt relation schema/identifier components, and a narrow source-grounded compile-time Jinja subset for unescaped `{% set name = ['string', ...] %}` string lists plus `{% for item in name %}` body expansion, and static `{% if %}` / `{% elif %}` branches for literal `true`/`false`, `execute`, `not execute`, `is_incremental()`, `not is_incremental()`, and simple `==` / `!=` comparisons over supported bool/string compile-context values without opening a database connection. It also renders a narrow Jaffle-style macro dispatch subset for literal model and analysis macro calls such as `{{ cents_to_dollars('subtotal') }}`, wrapper bodies shaped as `return(adapter.dispatch(...)(column_name))`, selected adapter/default implementation bodies with positional parameter interpolation, and root-project or installed-package column-level custom generic test bodies that use only `{{ model }}` and `{{ column_name }}`. The analysis parse/list/compile slice is documented in `.agent/research/m2-analysis-parse-compile.md`; the static list-loop slice is documented in `.agent/research/m2-static-jinja-set-for-loops.md`; the static loop dependency slice is documented in `.agent/research/m2-static-loop-dependencies.md`; the static loop ref/source compile slice is documented in `.agent/research/m2-static-loop-ref-source-compile.md`; the static conditional slice is documented in `.agent/research/m2-static-if-render-boundary.md`; the minimal macro dispatch slice is documented in `.agent/research/m2-minimal-macro-dispatch-rendering.md`; the singular test compile slice is documented in `.agent/research/m2-compile-singular-tests.md`; the generic test compile slice is documented in `.agent/research/m2-compile-generic-tests.md`. The compiler intentionally rejects scalar set values, unquoted or escaped list entries, filters, complex conditionals such as `and` / `or`, loop metadata, dynamic lists, general expression evaluation, statement tags inside macro bodies, table-level or non-column custom generic tests, materialization macro execution, and arbitrary macro runtime behavior.
- `ephemeral` model support has started as a narrow compiler and DuckDB
  execution slice grounded in dbt Core compile CTE injection references
  (`Compiler._recursively_prepend_ctes`, `inject_ctes_into_sql`,
  `compile_node`) and the current Fusion compile context direction named in
  `.agent/research/dbt-upstream-reference-map.md`. Supported downstream SQL
  models now compile literal/ref-resolved ephemeral parents into deterministic
  `__dbt__cte__<identifier>` CTEs, including simple chained ephemeral parents,
  emit model Manifest `extra_ctes`, `extra_ctes_injected`, `compiled_code`, and
  `compiled_path`, and execute selected downstream DuckDB `run` / `build`
  models without materializing standalone ephemeral relations. This slice
  remains bounded to the existing narrow compiler/Jinja subset and still
  rejects cycles, unsupported Jinja in ephemeral parents, selected standalone
  ephemeral execution, non-table/view downstream execution, custom
  materialization macros, adapter-specific relation staging, incremental,
  snapshots, and broader scheduler semantics.
- `dxt docs generate` has started as a docs artifact boundary. It loads and resolves the same Zig parser graph, applies `--select` and `--exclude` to compiled model output, writes compiled SQL, writes `manifest.json`, and writes dbt-shaped `catalog.json`. The catalog remains empty when no local DuckDB database exists or when selected relations are absent, and includes selected model/seed node relation metadata plus selected source relation metadata and ordered columns when an existing target DuckDB file can be introspected through the Zig-owned DuckDB CLI backend, including configured source database matching through DuckDB `table_catalog` for the current source relation identity contract and supported project-level/YAML source config inheritance. `dxt docs serve` has started as a static target-directory HTTP server for existing generated artifacts. Macro execution, docs-time materialization, tests, source freshness inside docs, comments, owners, richer stats, non-DuckDB adapters, `run_results.json`, dbt's bundled docs SPA, browser opening, and Fusion docs v2 endpoints remain out of scope.
- `dxt source freshness` has started the M3 DuckDB `sources.json` execution path. It loads and resolves the same Zig parser graph, applies supported source selectors/excludes including `source_status:pass` / `source_status:warn` / `source_status:error` from a prior dbt Sources v3 `--state/sources.json`, filters to source nodes with resolved source/table freshness criteria, queries selected DuckDB source tables through resolved relation identity plus resolved `loaded_at_field` SQL text and optional raw `freshness.filter` SQL or through resolved raw `loaded_at_query` SQL, classifies `pass` / `warn` / `error` from `warn_after` and `error_after`, writes `manifest.json`, writes dbt-shaped `sources.json` v3 success rows including stale empty/all-null loaded-at results, writes dbt-shaped runtime-error rows for unsupported per-source execution gaps including DuckDB sources with freshness thresholds but no `loaded_at_field` or `loaded_at_query`, and returns exit code `1` when any freshness status is `error` or runtime error. Root-project `dbt_project.yml` `sources:` configs for supported relation/freshness fields, source/table `config:` inheritance for `loaded_at_field`, `loaded_at_query`, and `freshness`, dbt-shaped threshold inheritance, final `freshness: null`, narrow `schema: "{{ target.schema }}"` rendering, source table `identifier` physical-name overrides, source/table database and database/schema/identifier quoting relation identity, resolved source database/schema/identifier use in compile/catalog/freshness/test paths, and expanded source manifest fields are implemented. General Jinja inside `loaded_at_query`, metadata freshness execution, hooks, threaded scheduling, installed-package project source config application, non-DuckDB adapters, `state:`, `result:`, defer, and embedded `libduckdb` remain future source-grounded slices.
- `dxt run` has started the M3 DuckDB execution path for selected enabled SQL models. It loads and resolves the same Zig parser graph, applies supported selectors/excludes, compiles selected SQL models, validates that selected models use only `table` or `view` materializations before opening DuckDB, executes selected models in dependency order through a Zig-owned external DuckDB CLI backend, writes compiled SQL, writes `manifest.json`, and writes a minimal dbt-shaped `run_results.json` v6 slice after completed runs. When a selected model fails with a DuckDB execution error, it writes completed prior rows plus a sanitized `status: "error"` row for the failed model, records `status: "skipped"` rows for selected blocked model descendants that survived `--exclude`, continues executing later selected models that do not depend on the failed node, writes `run_results.json`, and returns exit code `1`. It supports default `target/dxt.duckdb` output plus scalar DuckDB profile `path` resolved relative to the loaded `profiles.yml` directory as a deterministic dxt-local path-base choice for this first CLI-backed slice. It does not execute seeds, tests, snapshots, incremental, ephemeral, hooks, grants, docs persistence, catalog introspection, seed independent-resource continuation after failure, relation staging/backup rename parity, threaded scheduling, `:memory:`, MotherDuck, or embedded `libduckdb`.
- `dxt seed` has started the M3 DuckDB seed command path for selected root-project and installed-package CSV seeds. It loads and resolves the same Zig parser graph, applies supported selectors/excludes, filters mixed selections to seed resources in the dbt `SeedTask` / `ResourceTypeSelector` shape, rejects selections that match no seeds before opening DuckDB, writes `manifest.json`, loads selected seeds through the existing Zig-owned DuckDB CLI backend from the loaded root or package project root, writes seed-shaped Run Results v6 rows with null compiled fields, and prints a seed-specific success summary. Package seed execution supports name, package, and dependency selector paths when the final runnable set is seed resources. Supported seed YAML `quote_columns` and `column_types` configs are parsed for root-project and installed-package CSV seeds, emitted in dbt-shaped Manifest seed configs, and applied through DuckDB CSV name-normalization and type-map options. Hooks, grants, docs persistence, full-refresh semantics, full materialization macro execution, threaded scheduling, broader seed config parity, and embedded `libduckdb` remain future source-grounded slices.
- `dxt test` has started the M3 DuckDB data-test command path. It loads and resolves the same Zig parser graph, filters selection to test and unit-test resources, executes selected supported DuckDB generic tests and enabled singular SQL tests against already-existing target relations through the existing Zig-owned DuckDB CLI backend, executes selected supported unit tests by materializing parsed dict row fixtures for literal `ref` and local default-quoted `source` inputs inside a rollback-only DuckDB transaction, writes `manifest.json`, writes Run Results v6-shaped pass/fail/warn rows, and returns exit code `1` when any selected test fails while warning tests do not fail the command. It supports the built-in `not_null`, `unique`, `accepted_values`, and `relationships` generic-test subset already implemented for `build`, plus the static custom model/seed/source column generic-test subset, including model/seed/source generic-test `where`, `limit`, `severity`, `warn_if`, `error_if`, and `store_failures` configs for simple failure-count threshold comparisons and deterministic DuckDB audit-table persistence. Supported custom generic-test DuckDB execution errors write deterministic `status: "error"` Run Results rows with compiled SQL. Singular SQL test files are discovered from configured `test-paths` while skipping `generic/` and `fixtures/` subdirectories. Supported singular YAML patches can set description, config tags, enabled, `where`, `limit`, severity, warn/error thresholds, and `store_failures`; `where` and `limit` are applied to failure-row SQL, and threshold classification matches the existing supported generic-test model. Literal inline or YAML `config(enabled=false)` singular SQL tests are preserved under `manifest.disabled` and omitted from active selectors and execution, with inline enabled config taking precedence over YAML patch enabled config; literal inline singular `config(store_failures=true|false)` is also supported. Singular manifest nodes intentionally omit generic-only fields such as `test_metadata`, `column_name`, and `attached_node`, and selectors now cover `test_type:singular`, `test_type:data`, and patched singular tags. It does not build parent models or seeds, execute CSV/SQL unit-test fixtures, run custom generic-test macros beyond the supported static column-test body subset, support dynamic singular `enabled`, support `store_failures_as`, broaden singular config parity, change indirect-selection semantics, or use Python product runtime behavior.
- `dxt build` has started the M3 DuckDB execution path for root-project and installed-package CSV seed-only selections with supported seed YAML `quote_columns` and `column_types` configs, selected DuckDB SQL models with `table` and `view` materializations, selected seed+model builds in the supported DAG subset, selected seed+model+supported-generic-test builds, selected seed+test builds for CSV seed column or explicit table-level `column_name` generic tests, selected model+generic-test builds without seeds, selected model+singular-test builds when singular dependencies are selected, test-only selected DuckDB model column or explicit table-level `column_name` `not_null`/`unique`/default-quoted or explicit `quote: false` `accepted_values`/ref-backed or literal source-target `relationships` generic tests, test-only selected supported unit tests with parsed dict row fixtures, source+test selected DuckDB source column or explicit table-level `column_name` `not_null`/`unique`/default-quoted or explicit `quote: false` `accepted_values`/ref-backed or literal source-target `relationships` generic tests, selected seed+test DuckDB seed column or explicit table-level `column_name` `not_null`/`unique`/default-quoted or explicit `quote: false` `accepted_values`/ref-backed or literal source-target `relationships` generic tests, and the static custom model/seed/source column generic-test subset. It loads and resolves the same Zig parser graph, applies supported selectors/excludes, writes `manifest.json`, loads seeds through the Zig-owned DuckDB CLI backend from the loaded root or package project root, executes selected seed/model nodes in dependency order for selected seed/model dependencies, executes supported generic and singular SQL tests against built or already-existing attached/source/target relations, executes supported unit tests by materializing parsed dict row fixtures inside a rollback-only DuckDB transaction and comparing projected actual rows to expected rows, applies supported model/seed/source generic-test and singular-test `where`, `limit`, `severity`, `warn_if`, `error_if`, and `store_failures` configs, writes a minimal dbt-shaped `run_results.json` v6 slice, returns exit code `1` when any selected test fails while warning tests do not fail the command, writes completed prior rows plus a sanitized `status: "error"` row when supported model, seed, or custom generic-test DuckDB execution fails, appends `status: "skipped"` rows for selected blocked seed/model descendants and selected blocked data tests that survived `--exclude`, and continues selected independent supported seed/model/test resources after execution or data-test failures. For selected model-only, seed-only, and seed+model build paths, ready selected data tests now run as soon as their selected seed/model dependencies have completed; a failing selected data test writes its `fail` or `error` row, appends `skipped` rows for selected downstream seed/model descendants and unexecuted selected downstream data tests, avoids creating blocked downstream relations, writes `run_results.json`, and exits with code `1` after later selected independent supported resources finish. Wider generic tests, broader singular-test configs, CSV/SQL unit-test fixtures, unit-test overrides, mixed model/seed plus unit-test build scheduling, typed scalar accepted-value artifact parity, unsupported custom generic-test bodies/configs, hooks, grants, docs persistence, full-refresh semantics, broader seed config parity, `store_failures_as`, full dbt queue interleaving, full indirect-selection modes, built-in/singular generic-test runtime-error rows, and adapter materialization macro execution remain explicit boundaries. The seed config slice is documented above in the issue #179 source note; the data-test failure blocking slice is documented in `.agent/research/m3-build-test-failure-skip.md`; the generic-test config/severity slice is documented in `.agent/research/m3-duckdb-generic-test-configs.md`; the independent continuation slice is documented in issue #193.
- Synthetic fixtures cover one model, model refs, seed refs, source refs, narrow scalar var-backed model/source refs with CLI overrides and positional string defaults, exposure refs to models and sources, combined source/model YAML, inline config/tag/model-enabled parsing, inline-disabled singular SQL tests, singular SQL test YAML patches/configs and execution, config materialization selection, comma-intersection selection, YAML model properties and columns, emitted `unique`, `not_null`, `accepted_values`, and `relationships` generic test nodes, singular SQL test nodes and execution, project macro artifacts, macro block variants, macro materialization `supported_languages`, and macro properties including patched `docs` and `meta`, configured `macro-paths` replacing the default macro directory, installed package macros with package-qualified calls and package-local macro calls, installed package models, seeds, sources, docs, exposures, package YAML model properties, root package config overrides, and package-qualified/package-local refs/sources, macro calls recorded in model and macro `depends_on.macros`, docs blocks with literal `doc` descriptions, disabled models, disabled singular tests, disabled ref diagnostics, unmatched model-property warnings, duplicate model and docs diagnostics, unsupported dynamic doc diagnostics, unresolved var diagnostics for var-backed refs without scalar/default values, missing doc diagnostics, malformed docs block diagnostics, unresolved package macro diagnostics, and unsupported unknown macro-call diagnostics.
- The committed M1 public Jaffle parse gate lives in `scripts/check_jaffle_shop_duckdb_parse.py`. It clones a pinned public Jaffle Shop DuckDB ref into a temporary directory by default, runs the Zig `dxt` binary, validates the current M1 manifest schema slice, asserts the supported partial manifest shape with five SQL models, three CSV seeds, two docs blocks, twenty supported generic test nodes, model/test `refs` artifact fields, dependency maps, materialization/docs config, and keeps representative selector helpers for resource types, materialization config, wildcards, path selectors, and graph expansion. `scripts/check_jaffle_shop_duckdb_ls.py` now runs those selector checks as an explicit public `dxt ls` gate, and `scripts/check_jaffle_shop_duckdb_compile.py` runs the same pinned public fixture through `dxt compile`, validates compiled Manifest fields, confirms model/test compiled SQL files match artifact `compiled_code`, and asserts compile does not write execution artifacts. These are developer-side Python compatibility harnesses only; product parse/list/compile behavior remains implemented in Zig. The M3 public Jaffle build gate lives in `scripts/check_jaffle_shop_duckdb_build.py` and runs the same pinned public fixture through `dxt build`, then validates manifest shape, selector behavior, `run_results.json` resource/status counts, and representative DuckDB relation contents. The M3 public Jaffle run gate lives in `scripts/check_jaffle_shop_duckdb_run.py`; it prepares only seed relations, runs `dxt run`, and validates model-only Run Results v6 shape, dependency order, compiled model results, and representative DuckDB relation contents. The public Jaffle docs gate lives in `scripts/check_jaffle_shop_duckdb_docs.py`; it builds the fixture, runs `dxt docs generate`, and validates compiled docs manifest fields plus a populated Catalog v1-shaped model/seed catalog. GitHub CI runs the explicit public Jaffle parse, ls, compile, build, run, and docs gates in the existing public-fixture context, installing a pinned and checksum-verified DuckDB CLI for execution/docs gates and reusing the already-built Zig binary. Remaining M1/M2/M3 work includes package-provided tests/macros beyond the current narrow macro call surface, deeper artifact parity, full Jinja/macro behavior, and broader execution semantics beyond the supported public Jaffle DuckDB subset.
- Selector wildcard behavior is currently pinned to observed dbt Core 1.10 behavior. dbt Fusion preview currently differs for resource-type-prefixed wildcard selectors such as `model.<package>.*` and filename-suffix path selectors such as `path:*orders.sql`; a future Fusion-compatibility slice must decide whether to support a selector dialect switch or a compatible superset.
- Compatibility planning now uses a source-grounded reference map under `.agent/research/dbt-upstream-reference-map.md`; future feature slices should name upstream dbt v1/v2 source references, dxt Zig owners, affected artifact fields, validation gates, and stop conditions before implementation.
- The committed dbt Core M1 oracle harness lives in `scripts/check_dbt_core_m1_oracle.py`. It is optional developer-side Python tooling that requires `dbt-core` and `dbt-duckdb`, invokes dbt Core through its Python runner, runs `dxt parse` through the Zig binary, and compares stable manifest slices for the supported synthetic M1 fixture ladder. It ignores dbt internal package docs/macros that are outside the current dxt artifact scope, records a known allowed gap for installed-package exposure refs that dbt Core resolves to a root same-name model while dxt currently resolves package-local, and leaves full source-map parity, full artifact schemas, and execution parity for later slices.
- Before broadening M2 product implementation, close or explicitly re-scope the remaining M1 macro-compatibility behavior gaps. Macro `docs`/`meta` patch fields are covered for the current scalar artifact subset. Macro argument extraction under dbt Core v1 `flags.validate_macro_args` semantics and YAML patch argument validation/replacement are implemented for the manifest artifact surface. Static macro dependency lookup now uses the supported dbt order of current package, root project, other-package fallback for macro bodies, graph-present internal `dbt` macros, literal `adapter.dispatch(...)` dependency extraction, and return-wrapper dispatch dependency extraction. Parse-time dispatch prefixes now come from a narrow source-grounded `profiles.yml` adapter identity parser and emit manifest `metadata.adapter_type`, with default DuckDB behavior preserved when no profile file is loaded. Root-project `dispatch:` config search order is now honored for static `adapter.dispatch(...)` dependency extraction. Compile/runtime macro rendering is limited to the Jaffle-style dispatch wrapper subset documented in `.agent/research/m2-minimal-macro-dispatch-rendering.md`; bundled dbt internal macros, full target context inside macros, credential validation, general macro execution, and materialization runtime lookup remain planned. `{% data_test %}` has native source-grounded parser coverage, but the local dbt Core 1.10 oracle rejects that tag before writing artifacts, so dbt-oracle coverage currently pins `{% test %}` and `{% materialization %}` block parity.

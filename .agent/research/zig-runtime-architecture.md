# Zig Runtime Architecture Note

## Purpose

`dxt` should become a high-performance native binary with Zig as the product runtime. Python may remain in the repository for developer automation, tests, compatibility harnesses, fixture generation, and parity comparison against dbt Core, but it must not be required to run `dxt` as a product.

The architectural rule is simple: every user-facing command must be implemented in Zig and must be able to run without importing Python, spawning Python, or depending on Python packages at runtime.

## Runtime Boundary

### Product Runtime

The product runtime includes:

- The `dxt` executable.
- CLI parsing and command dispatch.
- dbt project loading.
- YAML, SQL, and Jinja parsing required by supported dbt surfaces.
- Manifest graph construction.
- Compilation and execution planning.
- Artifact generation.
- Adapter interfaces and native adapter implementations.
- Runtime logging, diagnostics, concurrency, and cache handling.

All of the above should be Zig-first and compiled into native release artifacts.

### Developer-Only Python

Python remains acceptable for:

- Compatibility tests that run dbt Core and compare outputs.
- Schema validation helpers when the schema tooling is Python-based.
- Fixture generation.
- Repository maintenance scripts.
- Public-safety scans.
- CI orchestration glue that does not ship with the product.

Python code should live under clearly developer-only paths such as `scripts/`, `tests/`, or future `tools/compat/`. It should not be imported from product code, referenced by the product CLI, or required by release archives.

## Proposed Project Layout

The future Zig layout should make the runtime boundary visible:

```text
build.zig
build.zig.zon
src/
  main.zig
  cli/
    args.zig
    commands.zig
    diagnostics.zig
  core/
    ids.zig
    intern.zig
    graph.zig
    manifest.zig
    resource.zig
  dbt/
    project.zig
    profiles.zig
    selectors.zig
    artifacts.zig
    relation.zig
  parse/
    scanner.zig
    yaml.zig
    jinja_lexer.zig
    jinja_eval.zig
    sql_refs.zig
    macros.zig
  compile/
    context.zig
    renderer.zig
    materialization.zig
  run/
    scheduler.zig
    task.zig
    results.zig
  adapter/
    abi.zig
    duckdb.zig
    capabilities.zig
tests/
  unit/
  fixtures/
  compat/
scripts/
  check_public_safety.py
  compat_compare.py
```

Suggested ownership rules:

- `src/main.zig` should only initialize allocators, parse top-level CLI input, dispatch commands, and map errors to exit codes.
- `src/cli/` should know command syntax, help text, output mode, and diagnostics, but should not own dbt semantics.
- `src/dbt/` should model dbt-compatible resource and artifact concepts.
- `src/parse/` should produce typed intermediate records without deciding execution behavior.
- `src/core/` should contain generic runtime infrastructure that is independent of dbt file formats.
- `src/adapter/` should expose a stable native ABI so database support can grow without leaking adapter details through parser and graph code.

## CLI Design

The CLI should preserve the planned dbt-like command surface while remaining explicit about unsupported behavior.

Initial commands:

- `dxt version`
- `dxt parse`
- `dxt ls`
- `dxt compile`
- `dxt build`
- `dxt docs generate`

Initial shared flags:

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
- `--output json`

CLI behavior rules:

- Parse flags natively in Zig.
- Keep default paths relative to the current working directory.
- Emit machine-readable diagnostics when `--output json` is selected.
- Return stable nonzero exit codes for usage errors, unsupported surfaces, compilation failures, execution failures, and internal errors.
- Treat unsupported dbt features as structured compatibility gaps, not silent skips.
- Keep help text and command names stable enough for shell completion and CI scripts.

The command path should be:

```text
argv -> cli args -> command options -> project loader -> manifest/compile/run pipeline -> artifacts -> exit code
```

No command should route through Python as an implementation shortcut.

## Allocator Strategy

Zig should make ownership and lifetime explicit. The runtime should use allocator scopes that match dbt workflow phases.

Recommended allocators:

- A top-level general-purpose allocator in debug and test builds to expose leaks and invalid frees.
- A page or c allocator option for release builds when profiling shows better behavior for large workloads.
- Arena allocators for parse-phase and compile-phase temporary data.
- A long-lived manifest allocator for graph objects that survive through command execution.
- Per-worker arenas for parallel parsing and execution tasks.
- Fixed buffers or small stack allocations for hot lexer/tokenizer paths where sizes are bounded.

Lifetime model:

- CLI options live for the process.
- Project file bytes live until parse completes unless diagnostics require source snippets.
- Interned strings and manifest nodes live until artifact generation completes.
- Parser scratch memory is freed after graph construction.
- Compile scratch memory is freed after each selected node or batch.
- Execution task memory is scoped to each task and retained only in `run_results` summaries.

Rules:

- Do not hide allocations behind global state.
- Do not store pointers into temporary file buffers unless the owning lifetime is obvious.
- Intern package names, resource names, paths, relation names, config keys, and dependency IDs.
- Make OOM a first-class error path with deterministic cleanup.
- Add stress tests for repeated parse/compile cycles to catch accidental lifetime extension.

## Fast Parser Architecture

The parser should be designed around streaming scans and typed intermediate records rather than building large generic trees for every file.

### File Discovery

Project loading should:

- Read `dbt_project.yml` first.
- Build a package and resource search plan.
- Walk only configured resource directories.
- Preserve normalized relative paths for artifact identity.
- Track file metadata needed for future partial parsing.

### YAML Parsing

YAML is required for project config, profiles, selectors, source definitions, schema properties, semantic resources, exposures, and tests.

Strategy:

- Parse YAML into a typed event stream or compact node tree.
- Convert immediately into dbt-specific structs with precise diagnostics.
- Preserve unknown fields where dbt artifact compatibility requires metadata retention.
- Reject unsupported constructs with file, line, column, and resource context.
- Avoid a dynamic "map of anything" as the long-term internal representation.

Because dbt projects often use common YAML rather than the full YAML surface, the first implementation can support the subset needed by pinned public fixtures. Expansion should be test-driven against real dbt projects and schema examples.

### SQL And Jinja Scanning

The first parse pass should not fully render every SQL file. It should cheaply extract:

- `ref(...)`
- `source(...)`
- `config(...)`
- `var(...)`
- `doc(...)`
- macro definitions
- materialization definitions
- tests and docs blocks where applicable

Architecture:

- A byte-oriented scanner finds Jinja delimiters and SQL text spans.
- A Jinja lexer tokenizes expressions and statements inside delimiters.
- A small dbt-aware expression parser handles the constructs needed for parse-time discovery.
- A later renderer evaluates compile-time Jinja with a richer context.

This keeps parse fast and lets `dxt parse` produce a graph even before full Jinja compatibility is complete.

### Graph Construction

Graph building should be deterministic:

- Use stable unique IDs that match dbt naming rules where possible.
- Store parent and child maps explicitly.
- Sort artifact maps and arrays before writing JSON where the schema allows order variation.
- Track disabled resources and parse errors instead of dropping them silently.
- Keep selector indexes close to the graph, not in command-specific code.

## Jinja Handling Strategy

Jinja compatibility is the largest semantic risk. The product should not embed Python or call Jinja2 at runtime.

Suggested phases:

1. Implement a native lexer and parser for the dbt Jinja subset needed for parse-time discovery.
2. Add a native evaluator for common expressions, calls, filters, tests, assignments, loops, conditionals, and macro calls.
3. Model dbt parse-time and execute-time contexts separately.
4. Add adapter dispatch and package namespace resolution.
5. Expand compatibility through parity tests against dbt Core.

Important behaviors to model:

- `execute` is false during parse and true during execution contexts.
- `ref`, `source`, and `config` have parse-time side effects.
- macros can return non-string values in dbt contexts.
- adapter dispatch can change macro selection by package and adapter type.
- `env_var` must be controlled so secrets do not leak into artifacts or diagnostics.

Unsupported Jinja features should fail with structured diagnostics. Silent partial rendering would be more dangerous than a clear compatibility error.

## Artifact JSON Generation

Artifacts are a compatibility contract. Zig should generate dbt-shaped JSON directly from typed structs rather than serializing ad hoc maps.

Required artifacts:

- `manifest.json`
- `run_results.json`
- `catalog.json`
- `sources.json`

Later artifacts:

- `semantic_manifest.json`
- a parse cache or partial-parse equivalent
- `dxt_metadata.json` for namespaced metadata that does not belong in dbt schemas

Design rules:

- Define artifact structs by target dbt artifact schema version.
- Keep schema version explicit in tests and release notes.
- Do not invent dbt fields for `dxt` metadata.
- Use a streaming JSON writer for large artifacts.
- Normalize nondeterministic fields in compatibility tests.
- Preserve enough source location data for useful diagnostics without writing private absolute paths.
- Ensure target paths and artifact metadata use relative or configured project-safe paths.

The compatibility harness may use Python to validate generated JSON against published schemas, but artifact generation itself must stay in Zig.

## Dependency Choices

Dependency policy should favor predictable native builds, security review, and binary portability.

Recommended default:

- Use Zig standard library for filesystem traversal, path handling, JSON writing, hashing, threading primitives, and process-level I/O where sufficient.
- Keep CLI parsing in-repo until requirements justify an external package.
- Keep the initial parser code in-repo so dbt-specific diagnostics and compatibility behavior stay under direct control.

Potential native dependencies:

- A small YAML library only if it can be audited, pinned, built by `zig build`, and tested against dbt fixtures.
- DuckDB through its C ABI for the first local execution adapter.
- Optional compression or archive libraries later for package management, only when `deps` support enters scope.

Avoid:

- Python runtime dependencies in product code.
- Shelling out to `dbt`, `python`, `jinja2`, or database CLIs from the product path.
- Broad framework dependencies that obscure allocator ownership or error handling.
- Generated bindings without checked-in generation instructions and CI validation.

Every dependency should have:

- A reason tied to a validation or product requirement.
- A pinned version or reproducible source.
- A license review before public release.
- A minimal wrapper layer so replacement remains possible.

## Build, Test, And CI Strategy

### Local Build Commands

The Zig product path should converge on:

```sh
zig build
zig build test
zig build run -- parse --project-dir fixtures/jaffle_shop
zig build run -- compile --project-dir fixtures/jaffle_shop --target-path target-dxt
```

Developer compatibility checks can remain Python-based:

```sh
pytest -q
python scripts/check_public_safety.py
python scripts/compat_compare.py fixtures/jaffle_shop
```

### Test Layers

Use separate test layers so product correctness and harness correctness do not blur:

- Zig unit tests for allocators, parsers, graph IDs, selector evaluation, and JSON writers.
- Zig integration tests for command execution against small fixtures.
- Python compatibility tests that run dbt Core and compare normalized artifacts.
- Public-safety tests that scan committed text for local paths and secrets.
- Release packaging tests that inspect archives for unwanted files and runtime Python dependencies.

### CI Gates

Required CI should eventually include:

- `zig fmt --check` or the repository's chosen Zig formatting gate.
- `zig build test`.
- Product CLI smoke tests on Linux.
- Python test harness checks.
- Public-safety scan.
- Artifact schema validation for pinned fixtures.
- Release archive inspection proving the product binary does not include developer-only files.

The first CI matrix can be narrow. It should expand after the native CLI and artifact generation stabilize.

## Preventing Python Product Runtime Drift

The repository should make the hard boundary enforceable.

Recommended controls:

- Keep Python under `scripts/`, `tests/`, and developer-only tooling paths.
- Do not expose Python modules as the canonical product CLI once the Zig CLI exists.
- Add a CI check that release archives contain the Zig binary, licenses, and docs only.
- Add a CI check that product source does not invoke `python`, `pip`, `pytest`, `dbt`, or `jinja2`.
- Document that Python harnesses are oracle and validation tools, not runtime fallbacks.
- Remove or clearly deprecate placeholder Python CLI entry points once the Zig CLI reaches command parity for the placeholder surface.
- Make compatibility gaps explicit in Zig diagnostics instead of routing unsupported behavior through Python.
- Keep dbt Core parity tests one-way: dbt Core provides expected outputs, `dxt` does not depend on dbt Core to produce outputs.

Good drift checks:

```text
release artifact contains no .py files
release artifact runs on a clean machine with no Python installed
product commands never spawn Python
compatibility harness can be skipped without disabling product tests
all artifact JSON is written by Zig code
```

## Migration Path From Current Scaffold

The current repository is a Python planning scaffold. A safe migration can be incremental:

1. Add `build.zig`, `build.zig.zon`, and a minimal Zig `dxt version`.
2. Add a native `dxt parse` placeholder with the same planned-command behavior as the current scaffold.
3. Move product command ownership to Zig while retaining Python tests as a harness.
4. Add native project loading for `dbt_project.yml`.
5. Add native graph and artifact skeletons.
6. Add compatibility tests that compare Zig outputs to dbt Core outputs.
7. Remove Python packaging as a product distribution path.

At each step, the product entry point should move toward Zig ownership, while Python remains useful only around the product for validation and development.

## Open Decisions

- Whether to implement an in-repo YAML parser first or adopt a small native YAML dependency.
- Which dbt artifact schema version is the first explicit target.
- How much Jinja compatibility is needed before the first artifact-emitting release.
- Whether DuckDB should be statically linked, dynamically linked, or optional at build time.
- Which platforms are release targets for the first native binary.
- How strict the first release should be about unsupported dbt macros and custom materializations.

These decisions should be tied to fixture-driven validation rather than made abstractly.

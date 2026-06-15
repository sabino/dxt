# M1 Parser Risk Review

## Scope

This note reviews the first M1 parser slice only: a native Zig `dxt parse`
implementation that loads a small dbt-style project, discovers Tier 0 resources,
builds a partial graph, and writes an intentionally partial but dbt-shaped
`manifest.json`.

The slice should not claim compile compatibility, macro execution, adapter
behavior, selector parity, or full artifact-schema coverage. Its value is a
reviewable native parser path plus enough manifest structure for dbt-oracle
comparison to start.

## Dangerous Overclaims

The highest risk is marketing or test language that says `dxt parse` is
"dbt-compatible" before the parser can handle normal dbt project behavior. For
M1, compatibility should be described as narrow and fixture-backed:

- Safe claim: parses the supported Tier 0 fixture subset and emits a
  schema-shaped partial manifest.
- Unsafe claim: parses dbt projects generally.
- Safe claim: extracts simple literal `ref`, `source`, `config`, and `doc`
  calls from SQL/Jinja spans.
- Unsafe claim: supports Jinja, macros, dispatch, or dbt parse-time semantics.
- Safe claim: supports a documented subset of YAML used by the M1 fixtures.
- Unsafe claim: supports YAML generally, including anchors, merges, custom tags,
  complex scalars, or every property file shape.
- Safe claim: `ls` or selectors use the M1 graph for basic names, tags, paths,
  resource types, `+`, and `--exclude` only if tests prove those cases.
- Unsafe claim: selector parity with dbt Core.
- Safe claim: Jaffle Shop DuckDB is an exploratory parse target once Tier 0
  passes.
- Unsafe claim: Jaffle Shop support until dbt-oracle counts, IDs, dependency
  maps, and diagnostics are compared and pinned.

Unsupported features should fail loudly with structured diagnostics. Silent
skips are more dangerous than incomplete support because they produce artifacts
that look authoritative while losing graph semantics.

## Partial Manifest Strategy

The M1 manifest should be partial by design but useful enough for downstream
comparison. The practical rule is: emit dbt field names only when `dxt` can
populate them with the intended meaning, and keep unknown `dxt` metadata out of
the dbt object unless the target schema permits it.

Minimum useful manifest content:

- `metadata` with explicit `dxt` identity and the target dbt artifact schema
  family under test.
- `nodes` for supported models, seeds, singular tests, and generated generic
  tests when M1 actually creates them.
- `sources` for YAML-declared sources and tables.
- `macros` only for parsed macro definitions, not executed macro behavior.
- `docs` only for parsed docs blocks.
- `exposures`, `metrics`, `groups`, and semantic resources as empty maps unless
  the parser has fixture-backed support for them.
- `disabled` entries when disabled resources are discovered, not dropped.
- `parent_map` and `child_map` derived from resolved refs and sources.
- Stable `unique_id` values for all emitted resources.
- Relative `path` and `original_file_path` values, with no host-specific paths.

Fields that are easy to overstate should stay absent, null, or explicitly
unsupported until implemented. Examples include compiled SQL, relation names,
injected CTEs, macro dependency side effects, adapter-specific configs, catalog
metadata, execution status, checksums if not calculated the dbt way, and
unrendered config if the parser does not preserve it correctly.

The manifest writer should be deterministic. Sort object keys and arrays where
ordering is not semantically meaningful, normalize path separators, and avoid
timestamps or invocation IDs in M1 unless tests normalize them. This keeps
parity diffs focused on parser behavior instead of noise.

## Python Runtime Boundary

Python can remain a strong validation tool for M1, but not a product shortcut.
The product path must be:

```text
dxt parse -> Zig CLI -> Zig project loader -> Zig parser -> Zig graph -> Zig artifact writer
```

Acceptable Python:

- invoking dbt Core as an oracle in tests,
- generating synthetic fixtures,
- normalizing and comparing JSON artifacts,
- validating public artifact schemas,
- scanning for local paths and secrets,
- checking that Python product-runtime files were not introduced.

Blocking Python uses:

- product CLI command dispatch,
- YAML parsing used by the `dxt` binary,
- SQL/Jinja dependency extraction used by the `dxt` binary,
- manifest writing used by the `dxt` binary,
- selector evaluation used by the `dxt` binary,
- spawning Python from `dxt parse`.

The runtime-boundary check should grow with M1. It should fail on Python under
product source paths and should also catch product command implementations that
invoke `python`, `python3`, `dbt`, or developer harness scripts as the parser
implementation.

## No-Dependency Zig Scanner

The first scanner should be byte-oriented, allocation-light, and deliberately
smaller than a renderer. Its job is discovery, not full Jinja execution.

Recommended shape:

- Read each file once and scan bytes for Jinja delimiters: `{{`, `{%`, and
  `{#`.
- Treat SQL text as opaque except for entering and leaving Jinja spans.
- Inside expression or statement spans, tokenize only the subset needed for M1:
  identifiers, dots, string literals, commas, parentheses, equals, brackets,
  whitespace, comments, and simple number/bool/null literals if configs need
  them.
- Recognize call forms by token sequence, not substring matching. This avoids
  false positives in comments, strings, similarly named functions, or words
  such as `reference`.
- Support single-quoted and double-quoted strings with escapes before claiming
  literal `ref` or `source` extraction.
- Skip Jinja comments entirely.
- Record file offset, line, and column while scanning so diagnostics do not need
  a second full pass.
- Use arenas for per-file tokens and discard them after producing compact
  dependency/config records.
- Intern repeated package, resource, path, and config key strings in the graph
  allocator.
- Avoid building a generic AST for every file in M1; keep the output as typed
  discovery records.
- Bound recursion and token sizes. A malformed Jinja span should return a
  location-aware unsupported-syntax error, not allocate until OOM.
- Make scanner behavior deterministic under parallel file walking by sorting
  discovered paths before parsing or sorting records before graph construction.

Performance should be measured with simple budgets even in M1. A useful first
gate is "parse each fixture file once, no quadratic rescans, no per-token heap
allocation, no dependency on regex engines or external parser packages." Later
benchmarks can compare against dbt Core, but M1 should at least include a
repeat-parse stress test to catch leaks and accidental global state.

## PR-Blocking Tests

The first M1 parser PR should not merge unless these gates pass:

- `zig build`
- `zig build test`
- black-box `dxt parse` tests against the built native binary
- `pytest -q` for developer harness and safety tests
- public-safety scan for local paths, secrets, logs, caches, and generated noise
- runtime-boundary scan proving the product parser/artifact path is not Python
- diff review confirming no generated artifacts, caches, or fixture outputs are
  committed accidentally

Parser behavior tests that should block the PR:

- Missing `dbt_project.yml` fails with a stable diagnostic and nonzero exit.
- A minimal one-model project emits `target/manifest.json`.
- Two models with a literal `ref` produce correct `unique_id`, `depends_on`,
  `parent_map`, and `child_map` entries.
- A YAML source plus `source(...)` call produces a source entry and dependency.
- YAML model properties populate descriptions, columns, tags, meta, and basic
  tests only for the supported subset.
- A disabled model is represented as disabled and is not silently promoted to an
  active node.
- Unsupported YAML or Jinja returns a structured unsupported-feature diagnostic.
- Paths in artifacts are relative and portable.
- Manifest output is deterministic across two consecutive parses.
- `--project-dir` and `--target-path` are honored without leaking host paths.
- Unknown or malformed parser flags still fail through the native CLI.

Compatibility tests that should block the PR:

- A dbt Core oracle run over Tier 0 fixtures is captured in developer-side tests.
- Resource counts by type match the oracle for the supported fixture subset.
- Stable IDs and dependency maps match the oracle where M1 claims support.
- The emitted manifest validates against the pinned schema slice or documented
  partial schema harness used for M1.
- Any expected mismatch is listed in a test fixture allowlist with a reason, not
  hidden in broad JSON normalization.

Scanner-specific tests that should block the PR:

- `ref` and `source` are not extracted from SQL comments, string literals, Jinja
  comments, or similarly named identifiers.
- Single and double quoted literal calls work.
- Package-qualified `ref("pkg", "model")` is either supported and tested or
  rejected with a clear diagnostic.
- Malformed Jinja delimiters and unterminated strings fail predictably.
- Large files with many non-Jinja bytes scan in linear time.
- Repeated parse runs do not leak under Zig test allocator coverage.

The PR is ready for review only when its description states exactly which dbt
surfaces are supported, which are intentionally unsupported, which oracle
version/schema slice was used, and the exact validation commands that passed.

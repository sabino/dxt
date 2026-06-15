# M1 Parser Slice Planning Note

## Purpose

This note scopes the first M1 implementation slice after the Zig runtime scaffold. The goal is a minimal but real native `dxt parse` and `dxt ls` path that proves the product can read a tiny dbt-compatible project, discover SQL models, extract simple graph dependencies, and write a dbt-shaped `target/manifest.json`.

This is not the full M1 parser. It should deliberately support only the Tier 0 fixture surface needed to exercise the first artifact and listing contract. Unsupported dbt surfaces should fail with clear diagnostics or be recorded as explicit gaps, not silently treated as supported.

Product behavior in this slice must be implemented in Zig. Python may be used only for developer-side tests, dbt oracle comparison, fixture generation, schema checks, and safety scans.

## Recommended Slice

Implement one narrow pipeline:

```text
CLI options
  -> project loader
  -> no-dependency YAML subset parser
  -> model file discovery
  -> SQL/Jinja call scanner
  -> manifest graph builder
  -> partial manifest writer
  -> ls output formatter
```

Supported commands for the slice:

- `dxt parse`
- `dxt ls`

Supported flags for this slice:

- `--project-dir <path>` with default `.`
- `--target-path <path>` with default from `dbt_project.yml` when present, otherwise `target`
- `--select <selector>` for exact resource name or unique ID only
- `--exclude <selector>` for exact resource name or unique ID only
- `--resource-type <type>` for `dxt ls`
- `--output <text|json>` for `dxt ls`

The existing accepted-but-unused flags can stay accepted by the CLI, but this slice should not pretend to honor profiles, target rendering, vars, threads, adapters, execution, compilation, or full selector syntax.

## Project Loading

Read `dbt_project.yml` from the project directory first. For this slice, require a small subset:

- `name`
- `version` if present
- `profile` if present
- `model-paths` if present
- `target-path` if present
- top-level `models:` config tree only enough to inherit simple tags and materialized config later

Defaults:

- package name defaults to the `name` field.
- model paths default to `["models"]`.
- target path defaults to `target`.

Diagnostics:

- missing `dbt_project.yml`: usage/parse error.
- missing or invalid `name`: parse error.
- unsupported YAML constructs in required fields: parse error with file, line, and column when available.
- unsupported optional fields: retain no behavior for now, but avoid failing unless they prevent reading the required subset.

Keep all artifact paths project-relative. The emitted manifest should not contain host-specific absolute paths.

## No-Dependency YAML Subset

Do not add a YAML dependency for the first slice. Implement a small parser in Zig that is intentionally constrained and test-driven.

Required subset:

- UTF-8 text input.
- comments beginning with `#` outside quoted scalars.
- indentation-based maps.
- block sequences using `- value`.
- plain scalars for simple strings, booleans, integers, and null.
- single-quoted and double-quoted scalars without needing full YAML tag support.
- inline lists of scalar strings such as `["models", "marts"]`.
- simple nested maps for `models:` package/resource config.

Explicitly unsupported for now:

- anchors and aliases.
- merge keys.
- custom tags.
- multi-document streams.
- folded and literal block scalars.
- complex flow maps.
- non-scalar sequence items outside cases the fixtures need.

Unsupported constructs should produce a clear compatibility diagnostic. This keeps the parser honest and avoids accidental divergence from dbt behavior.

Suggested Zig layout:

- `src/parse/yaml.zig`: tokenizer and compact node/event representation.
- `src/dbt/project.zig`: conversion from YAML nodes to typed project config.
- `src/cli/diagnostics.zig`: shared source-location diagnostic formatting.

If the current source tree is still flat when this lands, it is acceptable to keep the first implementation smaller, but the code should not embed dbt project semantics directly into `main.zig`.

## Model Discovery

Discover SQL models under configured model paths:

- recursively walk each model path.
- include files ending in `.sql`.
- ignore hidden directories, `target`, `dbt_packages`, and build/cache directories.
- normalize path separators to `/` for artifact fields.
- sort paths lexicographically before parsing for deterministic output.

For this slice, model names can be the SQL file stem. Defer dbt's full resource path and package collision behavior, but add tests for duplicate model names so the first behavior is explicit.

Each discovered model produces one manifest node:

```text
unique_id = "model.<package>.<model_name>"
resource_type = "model"
package_name = <dbt_project.yml name>
name = <model_name>
path = <path relative to the model path>
original_file_path = <path relative to project root>
raw_code = <SQL file contents>
language = "sql"
```

Prefer retaining `raw_code` in memory only until artifact writing. Do not introduce compilation fields except where the dbt manifest schema requires a placeholder or null.

## SQL/Jinja Call Extraction

Implement a byte scanner for the minimum dbt/Jinja calls needed by Tier 0:

- `ref("model_name")`
- `ref('model_name')`
- `ref("package_name", "model_name")`
- `source("source_name", "table_name")`
- `config(key="value", tags=["tag"])`
- `config(materialized="view")`
- `config(materialized='table')`

Scanner rules:

- inspect Jinja expression and statement blocks: `{{ ... }}` and `{% ... %}`.
- skip Jinja comments: `{# ... #}`.
- allow whitespace around names, parentheses, commas, and equals.
- support single and double quoted string literals.
- do not evaluate variables, macros, concatenation, conditionals, or loops.
- do not render SQL.

Extraction output:

- refs become dependency references and later `depends_on.nodes` entries if resolved.
- sources become dependency references and later `depends_on.nodes` entries if the source exists in supported YAML properties.
- config fields set only explicitly supported node config keys.
- unsupported dynamic calls should be reported as unsupported when they look dependency-bearing, for example `ref(var("x"))`.

This scanner should be structured as a small lexer plus call parser, not ad hoc substring replacement. It can still be incomplete, but it should have deterministic token boundaries and source locations.

## Tier 0 Fixture Design

Add small synthetic fixtures under the test fixture tree when implementation begins. Keep them public-safe and path-neutral.

Recommended fixture set:

1. `single_model`
   - `dbt_project.yml`
   - `models/customers.sql`
   - proves project loading, model discovery, one manifest node, and `dxt ls`.

2. `model_ref`
   - `models/stg_customers.sql`
   - `models/customers.sql` using `{{ ref("stg_customers") }}`
   - proves dependency extraction, parent map, and child map.

3. `source_ref`
   - `models/schema.yml` defining source `raw.customers`
   - `models/stg_customers.sql` using `{{ source("raw", "customers") }}`
   - proves minimal source YAML and source dependency IDs.

4. `inline_config`
   - model with `{{ config(materialized="table", tags=["nightly"]) }}`
   - proves config parsing and `ls --select tag:nightly` only if tag selectors are added in the same slice. If tag selectors are deferred, keep the tag in the artifact but test exact-name selection only.

5. `duplicate_model_name`
   - two SQL files with the same stem in different subdirectories.
   - proves deterministic diagnostic behavior before full dbt resource collision handling exists.

6. `unsupported_dynamic_ref`
   - model using `{{ ref(var("model_name")) }}`
   - proves explicit unsupported-feature diagnostics.

Defer macros, docs blocks, exposures, generic tests, disabled resources, packages, and custom path config unless the first implementation has already stabilized. They belong to later M1 slices even though Tier 0 eventually includes them.

## Partial Manifest Strategy

Write `manifest.json` to `<target-path>/manifest.json` for `dxt parse`. It should be dbt-shaped, deterministic, and explicit about being partial.

Priority fields:

- `metadata`
  - `dbt_schema_version`: pin to the intended dbt manifest schema URL for the compatibility target.
  - `dbt_version`: use a compatibility target string only if intentionally chosen; otherwise keep a documented placeholder compatible with tests.
  - `project_name`
  - `project_id`: deterministic placeholder or null if schema permits.
  - `adapter_type`: null or omitted if schema permits, because this slice does not load profiles.
  - `invocation_id`: deterministic in tests or normalizable in parity checks.
  - `generated_at`: deterministic in tests or normalizable.
- `nodes`
  - one entry per discovered model.
  - stable `unique_id`, `resource_type`, `package_name`, `name`, `path`, `original_file_path`, `raw_code`, `config`, `depends_on`.
- `sources`
  - include only sources declared by the minimal YAML property parser.
- `macros`
  - empty object in this slice.
- `docs`
  - empty object in this slice.
- `exposures`
  - empty object in this slice.
- `metrics`
  - empty object in this slice.
- `groups`
  - empty object in this slice if required by the schema target.
- `selectors`
  - empty object in this slice.
- `disabled`
  - empty object or empty array according to the pinned schema target.
- `parent_map`
  - derived from resolved refs and sources.
- `child_map`
  - inverse of `parent_map`.

Artifact rules:

- Do not invent dbt field names.
- Prefer `null`, empty arrays, or empty objects only where the pinned schema permits them.
- Put any `dxt`-specific disclosure in a permitted metadata area only if schema-safe; otherwise rely on the command output and documentation to call the artifact partial.
- Stable key ordering is required so fixture tests can compare output.
- Do not include absolute paths, local usernames, cache directories, command transcripts, or environment variables.

The manifest does not need to validate against the full published schema in the first commit if required fields are still being identified, but the implementation should include a schema-slice test for the fields this slice claims to emit.

## `dxt ls`

`dxt ls` should reuse the parse pipeline and list resources from the in-memory manifest graph. It does not need to write `manifest.json` unless the command contract intentionally chooses to mirror dbt side effects later.

Text output:

```text
model.<package>.<name>
```

JSON output:

```json
[
  {
    "unique_id": "model.pkg.customers",
    "name": "customers",
    "resource_type": "model",
    "package_name": "pkg",
    "original_file_path": "models/customers.sql"
  }
]
```

Initial filtering:

- `--resource-type model`
- `--resource-type source` if source YAML is implemented in the same slice.
- exact unique ID selector.
- exact resource name selector.
- exact exclude by unique ID or name.

Do not implement graph operators, tag selectors, path selectors, package selectors, or comma/intersection selectors in this slice unless tests compare them against dbt. If unsupported selector syntax is supplied, fail explicitly.

## Tests

Fastest required verification for the implementation PR:

- `zig build`
- `zig build test`
- black-box CLI tests for `dxt parse` and `dxt ls`
- public-safety scan
- runtime-boundary scan

Zig unit tests:

- YAML subset parser: project names, model paths, target path, inline scalar lists, comments, invalid indentation, unsupported anchors.
- project loader: defaults and required fields.
- model discovery: recursive sorted discovery and duplicate-name diagnostics.
- SQL/Jinja scanner: static `ref`, package `ref`, `source`, supported `config`, skipped comments, unsupported dynamic calls.
- graph builder: node IDs, dependency resolution, parent map, child map.
- JSON writer: stable key ordering and escaping.

Black-box tests:

- `dxt parse --project-dir fixtures/single_model --target-path target-dxt` writes a manifest.
- `dxt ls --project-dir fixtures/model_ref` lists deterministic unique IDs.
- `dxt ls --output json` emits parseable JSON with expected fields.
- `dxt ls --resource-type model --select customers --exclude stg_customers` applies the supported exact filters.
- invalid project and unsupported dynamic ref fail nonzero with useful stderr.

Developer-side compatibility tests:

- Use dbt Core as an oracle only from tests or scripts.
- Compare node unique IDs, resource counts, source IDs, and parent/child maps for the Tier 0 fixtures.
- Normalize generated timestamps and invocation IDs.
- Do not require live warehouses.

## Acceptance Criteria

The first M1 slice is complete when:

- `dxt parse` is implemented in Zig and no longer returns the planned placeholder for supported Tier 0 projects.
- `dxt parse` reads `dbt_project.yml`, discovers `models/**/*.sql`, extracts static `ref`, `source`, and supported `config` calls, builds a graph, and writes `target/manifest.json`.
- `dxt ls` is implemented in Zig and lists parsed resources in stable text and JSON formats.
- The emitted manifest is dbt-shaped, deterministic, and explicitly limited to the supported partial surface.
- All emitted paths are relative to the project and public-safe.
- Unsupported dependency-bearing Jinja patterns fail with clear diagnostics instead of being ignored.
- Tier 0 synthetic fixtures cover standalone models, refs, sources, inline config, duplicate names, and unsupported dynamic refs.
- Unit tests and black-box CLI tests pass through the native binary.
- Public-safety and runtime-boundary checks pass.
- The final diff contains no generated `target`, cache, log, local path, secret, or private environment content.

## Deferred From This Slice

- full YAML support.
- profiles and adapter loading.
- macro parsing and execution.
- Jinja rendering.
- compilation and compiled SQL fields.
- materializations.
- seeds, snapshots, analyses, tests, docs blocks, exposures, metrics, semantic models.
- full dbt selector syntax.
- packages and cross-package dependency installation.
- schema validation against the complete manifest schema.
- Jaffle Shop parsing.

These are still M1 or later requirements, but bundling them into the first parser commit would make the review too broad and weaken the artifact baseline.

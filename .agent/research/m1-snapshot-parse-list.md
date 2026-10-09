# SQL Snapshot Parse And List Foundation

This is the source map for issue #213. The product boundary is read-only
snapshot ingestion, Manifest v12 nodes and selectors. Snapshot compilation,
execution and materialization remain separate work.

## Pinned Contract

The fixture oracle uses dbt Core **1.10.5**, dbt-duckdb **1.9.6**, and Manifest
**v12**. This defines the claimed SQL snapshot subset; it does not establish
complete compatibility with these releases or current dbt versions.

| Upstream source | Behavior to match |
| --- | --- |
| [Snapshot parser](https://github.com/dbt-labs/dbt-core/blob/v1.10.5/core/dbt/parser/snapshots.py) | Snapshot search paths, named SQL block extraction and file/block FQN identity. |
| [Snapshot resource config](https://github.com/dbt-labs/dbt-core/blob/v1.10.5/core/dbt/artifacts/resources/v1/snapshot.py) | Literal timestamp/check strategy validation, unique keys, check columns and target overrides. |
| [Configured parser](https://github.com/dbt-labs/dbt-core/blob/v1.10.5/core/dbt/parser/base.py) | Node construction, parse-time config and resolved relation identity. |
| [File reader](https://github.com/dbt-labs/dbt-core/blob/v1.10.5/core/dbt/parser/read_files.py) | SHA-256 of the stripped complete source file, shared by blocks in that file. |
| [Manifest loader](https://github.com/dbt-labs/dbt-core/blob/v1.10.5/core/dbt/parser/manifest.py) | Ref/source resolution, disabled placement and final enabled-node validation. |
| [List task](https://github.com/dbt-labs/dbt-core/blob/v1.10.5/core/dbt/task/list.py) | Snapshot selector output includes the full FQN. |
| [Manifest v12 schema](https://github.com/dbt-labs/dbt-core/blob/v1.10.5/schemas/dbt/manifest/v12.json) | Snapshot node/config field shapes. |

Fusion's typed snapshot/parser architecture is a future reference. This slice
uses observable Core output as the behavioral contract and does not adopt
Fusion-specific runtime semantics.

## Oracle Findings

- `snapshot-paths` defaults to `snapshots`; explicitly configuring `[]` disables
  discovery. Root and installed package search paths belong to their project.
- One SQL file may contain multiple named snapshot blocks. Each becomes a
  `snapshot.<package>.<block_name>` node with resource type `snapshot`.
- `raw_code` is the inner body with dbt's snapshot block whitespace-control
  behavior. Plain tags preserve the body exactly; an opening `-%}` strips
  leading body whitespace and a closing `{%-` strips trailing body whitespace.
  Snapshot opening/closing tags are excluded. The checksum remains SHA-256 of
  the whole file after stripping surrounding whitespace, rather than a
  checksum of that body.
- `path` is relative to its snapshot search root; `original_file_path` retains
  the root. FQN includes package, nested path components, filename stem and
  block name. A different filename and block name must remain distinguishable.
- `target_schema` and `target_database` directly override snapshot identity;
  ordinary schema/alias fields use the supported relation naming boundary.
- Enabled timestamp snapshots require strategy, unique key and `updated_at`;
  check snapshots require strategy, unique key and `check_cols` as `all` or a
  nonempty list. Disabled nodes can omit strategy settings.
- Composite unique keys are string lists. `invalidate_hard_deletes` is absent
  from default config and Boolean when explicitly supplied.
- Snapshot refs are graph dependencies and snapshot resources are referenceable
  by downstream models. Read/list support must preserve both directions in
  parent/child maps even while execution is unavailable.

## Ownership And Validation

`snapshot.zig` owns block parsing and the supported literal config grammar.
`types.zig`, `config.zig` and `loader.zig` own storage and discovery;
`resolve.zig` and `selector.zig` own references and selection;
`manifest.zig` owns dbt fields. `project.zig`/CLI preflight reject unsupported
compilation/execution before warehouse access. All product behavior stays Zig.

Native tests cover parsing, invalid config, defaults, duplicate identity,
reference resolution and selection. CLI fixtures exercise multi-block files,
configured paths, installed packages, disabled snapshots, schema fields,
graph expansion and deterministic unsupported-command diagnostics. A pinned
Core oracle compares supported identity/config/dependency/checksum fields and
listing output. Public Jaffle gates guard existing projects.

Unsupported YAML snapshot definitions, dynamic snapshot config/Jinja, custom
strategies and snapshot execution must fail clearly. Do not silently omit
these resources or substitute table/view execution. Stop before adapter SQL,
SCD history, hard-delete execution, broader property precedence or general
macro interpretation; these belong in subsequent source-grounded slices.

Same-package enabled model/snapshot and seed/snapshot names may coexist in
Core when their physical identities differ. Core's ref lookup follows parser
insertion order (seed over snapshot over model); identical physical relations
are rejected separately. This slice explicitly rejects same-name refs involving
a snapshot instead of claiming that lookup precedence. Full physical relation
uniqueness remains part of the broader relation/configuration parity gate.

Commands with a default resource filter can still process unrelated supported
models, seeds and tests. Explicit snapshot selections and selected consumers
with snapshot ancestry, including singular/unit tests and unselected ephemeral
ancestors, fail before artifact writes or warehouse access. Compile/build/docs
selections containing snapshots also fail at that boundary.

# M2 Inline Enabled Config

## Scope

This slice adds literal inline SQL model `{{ config(enabled=false) }}` and
`{{ config(enabled=true) }}` parsing in the Zig product runtime. Inline-disabled
models reuse the existing disabled-node manifest path: they are omitted from
active `nodes`, `parent_map`, `child_map`, selectors, compile, run, and build,
and are emitted under `manifest.disabled`.

The slice is intentionally limited to literal booleans on SQL models. It does
not add dynamic `enabled=var(...)`, rendered project/profile config values,
disabled seeds/sources/tests, full config precedence, or parse-time Jinja
context execution.

## Upstream References

- dbt Core v1:
  - `core/dbt/parser/base.py::ConfiguredParser.render_update`
  - `core/dbt/parser/base.py::ConfiguredParser.update_parsed_node_config`
  - `core/dbt/parser/base.py::ConfiguredParser.add_result_node`
  - `core/dbt/context/providers.py::ParseConfigObject.__call__`
  - `core/dbt/parser/manifest.py::ManifestLoader.cleanup_disabled`
  - `core/dbt/contracts/graph/manifest.py::Manifest`
- dbt Core v2 / Fusion:
  - `crates/dbt-parser/src/renderer.rs`
  - `crates/dbt-parser/src/resolver.rs`
  - `crates/dbt-schemas/src/schemas/manifest/manifest.rs::build_disabled_map`
  - `crates/dbt-schemas/src/schemas/manifest/manifest.rs::build_parent_and_child_maps`

## dxt Ownership

- `src/project/jinja.zig` scans literal inline `enabled` config.
- `src/project/types.zig` tracks whether `enabled` came from inline SQL config.
- `src/project.zig` preserves inline `enabled` over YAML property patches for
  the current narrow model-config precedence rule.
- `src/project/manifest.zig` already owns disabled-node serialization and
  active graph-map filtering.

## Artifact Impact

- `manifest.json.nodes` omits inline-disabled model nodes.
- `manifest.json.disabled` includes the disabled model node with
  `config.enabled: false`.
- `manifest.json.parent_map` and `manifest.json.child_map` omit disabled model
  unique IDs.
- `run_results.json`, `catalog.json`, and `sources.json` are unchanged.

## Validation

- Native Zig scanner tests cover literal `enabled=true`, `enabled=false`, and
  rejection of dynamic or malformed enabled values.
- Python CLI tests cover `dxt parse`, `manifest.disabled`, `dxt ls`, and refs
  to inline-disabled models.

## Stop Conditions

- Stop before adding dynamic enabled expressions or general parse-time Jinja.
- Stop before changing package/project/YAML config precedence beyond preserving
  inline model config for this one key.
- Stop before touching execution scheduler behavior.

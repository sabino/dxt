# M2 Inline Disabled Singular SQL Tests

## Scope

This slice adds literal inline singular SQL test `{{ config(enabled=false) }}`
parsing in the Zig product runtime. Disabled singular tests are omitted from
active `nodes`, `parent_map`, `child_map`, selector results, `compile`, `test`,
and `build`, and are emitted under `manifest.disabled`.

The slice is intentionally limited to literal booleans in singular SQL test
files. It does not add YAML singular test patches/configs, generic-test
`enabled`, dynamic `enabled=var(...)`, severity/threshold config, `where`,
`limit`, `store_failures`, or full indirect-selection parity.

## Upstream References

- dbt Core v1:
  - `core/dbt/parser/singular_test.py::SingularTestParser`
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

- `src/project/jinja.zig` already scans literal inline `enabled` config.
- `src/project/types.zig` tracks enabled state on `SingularTestNode`.
- `src/project.zig` transfers scanner enabled state into singular test nodes
  and skips disabled singular tests in compile/test/build execution helpers.
- `src/project/resolve.zig` skips disabled singular tests during dependency
  resolution, matching existing disabled model behavior.
- `src/project/selector.zig` excludes disabled singular tests from selectors
  and graph expansion.
- `src/project/manifest.zig` serializes disabled singular tests under
  `manifest.disabled` and filters them out of active graph maps.

## Artifact Impact

- `manifest.json.nodes` omits inline-disabled singular test nodes.
- `manifest.json.disabled` includes the disabled singular test node with
  `config.enabled: false`.
- `manifest.json.parent_map` and `manifest.json.child_map` omit disabled
  singular test unique IDs.
- `run_results.json`, `catalog.json`, and `sources.json` are unchanged unless
  the disabled test would previously have been selected and executed.

## Validation

- Native Zig manifest/selector tests cover disabled singular test filtering.
- Python CLI tests cover `dxt parse`, `manifest.disabled`, `dxt ls`,
  compile-time exclusion, and skipping dependency resolution for refs inside
  disabled singular SQL tests.

## Stop Conditions

- Stop before implementing YAML singular test patches/configs.
- Stop before adding dynamic enabled expressions or general parse-time Jinja.
- Stop before changing generic-test config semantics.
- Stop before changing test severity, thresholds, `where`, `limit`, or
  store-failures runtime behavior.

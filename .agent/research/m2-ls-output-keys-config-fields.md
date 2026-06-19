# M2 `ls --output-keys` Config Field Slice

This note maps the narrow compact selected-resource JSON expansion for dbt-style
`--output-keys` values `config.materialized` and `config.tags`.

## Upstream References

dbt Core v1 reference files:

- `core/dbt/task/list.py`: `ListTask._get_nested_value` traverses dot-delimited
  keys for JSON listing output.
- `core/dbt/task/list.py`: `ListTask.generate_json` preserves requested key
  order, skips missing nested values, and writes the original requested key
  name such as `config.materialized`.
- `core/dbt/cli/params.py`: `--output-keys` documentation names nested key
  support for JSON output.
- `tests/unit/task/test_list.py`: unit coverage includes regular, nested,
  mixed, and nonexistent output-key behavior.

Fusion/dbt Core v2 reference files:

- `crates/dbt-clap-core/src/commands.rs`: Fusion keeps `ls` in the command
  surface while the Rust implementation continues to evolve.

## dxt Scope

The implementation remains Zig-only and compact selected-resource only:

- `src/project/selector.zig` carries already-parsed config data from selected
  resources through `SelectedResource.config_materialized` and
  `SelectedResource.config_tags`.
- `src/project/manifest.zig` accepts exact compact JSON `output_keys`
  `config.materialized` and `config.tags`, emitting flat JSON keys with those
  names when the selected resource carries a value.
- `src/project/json.zig` provides the shared JSON string-array field helper so
  compact selected-resource output uses the same `std.json`-backed escaping as
  artifact writers.
- Unknown keys continue to be skipped, repeated keys remain de-duplicated, and
  the requested key order is preserved.

## Boundaries

This slice does not add full dbt node JSON parity, arbitrary nested-key
traversal, `config.meta`, relation fields, metrics, semantic models, saved
queries, state/result/source-status selectors, or YAML selectors.

It intentionally follows upstream `1.latest` nested-key behavior for these two
compact keys. Older dbt Core versions may differ for `--output-keys`; dxt keeps
the intended behavior source-grounded in the current upstream files above.

## Validation

- Native Zig selected-resource JSON tests cover `config.materialized`,
  non-empty and empty `config.tags`, requested order, unknown-key skipping,
  duplicate-key suppression, and resources without those config values.
- Python CLI tests cover `dxt ls --output json --output-keys package_name
  config.materialized config.tags non_existent_key` against the inline-config
  fixture through the native Zig binary.

# M2 `ls --output-keys` Resource Field Slice

This note maps a narrow expansion of selected-resource JSON fields for
`dxt ls --output json --output-keys`.

## Upstream References

dbt Core v1 reference files:

- `core/dbt/task/list.py`: `ListTask.generate_json` serializes selected nodes
  to dictionaries, filters requested `output_keys`, preserves requested key
  order, and skips unknown keys.
- `core/dbt/task/list.py`: `generate_paths`, `generate_names`, and
  `generate_selectors` show the path/name/selector output surfaces that users
  commonly combine with JSON output.
- `core/dbt/cli/params.py`: `--output-keys` is documented as a space-delimited
  list of node properties for JSON output, including nested keys in dbt Core.
- `tests/unit/task/test_list.py`: unit coverage confirms regular, nested,
  mixed, and nonexistent output-key behavior.

Fusion/dbt Core v2 reference files:

- `crates/dbt-clap-core/src/commands.rs`: Fusion keeps `ls` in the command
  surface while the Rust command implementation continues to evolve.

## dxt Scope

The implementation remains Zig-only and selected-resource only:

- `src/project/selector.zig` carries the selected resource `package_name`,
  source-only `source_name`, and `path` alongside `unique_id`, `name`,
  `resource_type`, `search_name`, `original_file_path`, and selector output.
- `src/project/manifest.zig` accepts additional compact JSON `output_keys`:
  `package_name`, source-only `source_name`, `path`, `original_file_path`,
  and `selector`.
- `selector` is a deliberate dxt compact selected-resource extension based on
  the existing `--output selector` surface; dbt Core exposes selector strings
  as a separate output mode rather than as a serialized node JSON property.
- Unknown keys continue to be skipped, repeated keys remain de-duplicated, and
  the requested key order is preserved.

## Boundaries

This slice does not add full dbt node JSON parity, nested keys such as
`config.materialized`, relation/config fields, metrics, semantic models, saved
queries, or state/result/source-status selectors. Local dbt Core 1.10.15 filters
`output_keys` as top-level node fields only; upstream `1.latest` source has
nested-key traversal in this area, so nested keys remain a pinned-version
compatibility decision for a future slice.

## Validation

- Native Zig selected-resource JSON tests cover the new keys, requested order,
  unknown-key skipping, and duplicate-key suppression.
- Python CLI tests cover `dxt ls --output json --output-keys name path
  original_file_path selector unique_id`, `package_name`, and source-only
  `source_name`.

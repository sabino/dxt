# M2 `ls --output-keys`

## Scope

This slice adds a narrow dbt-style `dxt ls --output json --output-keys ...`
filter for the existing compact selected-resource JSON output.

Supported keys:

- `unique_id`
- `resource_type`
- `name`

Unknown keys are omitted, matching dbt Core's behavior when a requested key is
not present on the serialized node dictionary.

Out of scope:

- Full dbt node JSON output.
- Nested keys such as `config.materialized`.
- Adding new selected-resource JSON fields.
- Changing default `json`, `text`, `name`, `path`, or `selector` output.

## Upstream References

dbt Core v1:

- `core/dbt/task/list.py::ListTask.generate_json`
- `core/dbt/task/list.py::ListTask._get_nested_value`
- `core/dbt/cli/params.py::output_keys`

dbt Core v2 / Fusion:

- `crates/dbt-clap-core/src/commands.rs`

## dxt Ownership

- `src/root.zig` parses `--output-keys` as a list-mode multi-value option.
- `src/project/types.zig` stores the selected output-key list.
- `src/project.zig` passes output keys to the listing JSON writer.
- `src/project/manifest.zig` filters compact selected-resource JSON fields.
- `tests/test_cli.py` covers black-box CLI behavior.

## Validation

- Native Zig tests cover selected-resource JSON key ordering, duplicate-key
  handling, and unknown-key omission.
- Python CLI tests cover `--output json --output-keys ...` and missing-value
  diagnostics.

## Stop Conditions

Stop before implementing full dbt JSON object parity, nested output-key lookup,
or additional resource fields. Those require a separate artifact/schema-backed
slice.

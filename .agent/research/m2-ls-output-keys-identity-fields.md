# M2 `ls --output-keys` Identity Field Slice

This note maps the narrow compact selected-resource JSON expansion for dbt-style
`--output-keys` values `alias` and `identifier`.

## Upstream References

dbt Core v1 reference files:

- `core/dbt/task/list.py`: `ListTask.generate_json` serializes selected nodes
  with `node.to_dict(omit_none=False)`, preserves requested key order, and skips
  missing keys.
- `core/dbt/task/list.py`: `generate_selectors`, `generate_names`, and
  `generate_paths` show adjacent listing surfaces that derive selectors and
  names from the selected node.
- `core/dbt/cli/params.py`: `--output-keys` is documented as a space-delimited
  list of node properties for JSON output.
- `tests/unit/task/test_list.py`: unit coverage includes regular, nested,
  mixed, and nonexistent output-key behavior.

Fusion/dbt Core v2 reference files:

- `crates/dbt-clap-core/src/commands.rs`: Fusion keeps `ls` in the command
  surface while command internals evolve.

## dxt Scope

The implementation remains Zig-only and compact selected-resource only:

- `src/project/selector.zig` carries selected-resource `alias` for models,
  seeds, generic tests, and singular tests, using inline model aliases when
  parsed and defaulting model/seed aliases to the resource name.
- `src/project/selector.zig` carries source-only `identifier`, using the parsed
  source table identifier when present and defaulting to the logical table name.
- `src/project/manifest.zig` accepts exact compact JSON `output_keys` `alias`
  and `identifier`, skipping those keys for resource types that do not carry
  them.
- Unknown keys continue to be skipped, repeated keys remain de-duplicated, and
  requested key order is preserved.

## Boundaries

This slice does not add full dbt node JSON parity, `fqn`, relation fields,
database/schema fields, arbitrary nested-key traversal, metrics, semantic
models, saved queries, state/result/source-status selectors, or YAML selectors.

## Validation

- Native Zig selected-resource JSON tests cover `alias`, source-only
  `identifier`, requested order, missing-key skipping, unknown-key skipping, and
  duplicate-key suppression.
- Python CLI tests cover default model aliases, inline model aliases, and
  source identifiers through the native Zig binary.

# M2 `ls` Output Formats

## Scope

This slice adds dbt-style newline-delimited `dxt ls --output` modes for the
supported graph resources.

Supported formats:

- `text`: existing dxt legacy unique-id output.
- `json`: existing compact selected-resource JSON output.
- `name`: selected resource names.
- `path`: selected resource `original_file_path` values.
- `selector`: dbt-style selector strings for supported resources.

Out of scope:

- `--output-keys`.
- Full dbt JSON object parity.
- Metrics, semantic models, saved queries, functions, and unit tests.
- Changing dxt's legacy default text output.

## Upstream References

dbt Core v1:

- `core/dbt/task/list.py::ListTask.generate_names`
- `core/dbt/task/list.py::ListTask.generate_paths`
- `core/dbt/task/list.py::ListTask.generate_selectors`
- `core/dbt/task/list.py::ListTask.generate_json`
- `core/dbt/cli/params.py::output`

dbt Core v2 / Fusion:

- `crates/dbt-clap-core/src/commands.rs`

## dxt Ownership

- `src/root.zig` validates and maps supported `--output` values.
- `src/project/types.zig` owns the `Output` enum.
- `src/project/selector.zig` carries selected-resource metadata needed by
  list output.
- `src/project.zig` writes command output for `dxt ls`.
- `tests/test_cli.py` covers black-box output behavior.

## Validation

- Native Zig build/test coverage checks enum and selected-resource compile
  integration.
- Python CLI tests cover model, source, exposure, and generic-test
  `name`/`path`/`selector` output, legacy default text output, existing compact
  JSON output, and invalid `--output` diagnostics.

## Stop Conditions

Stop before changing default output behavior, selector semantics, JSON object
shape, or artifact writers. This is only a listing output format slice.

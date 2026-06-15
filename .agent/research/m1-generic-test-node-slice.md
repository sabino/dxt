# M1 Generic Test Node Slice

## Scope

This slice emits dbt-shaped manifest nodes for the simple generic tests already parsed from YAML:

- model-level `unique`
- column-level `unique`
- column-level `not_null`
- `tests:` and `data_tests:` aliases
- test entries in `manifest.nodes`
- parent/child map edges from tests to their attached model
- `ls --resource-type test`

Argument-rich tests such as `accepted_values` and `relationships` remain deferred until the YAML argument parser can preserve nested `arguments:` and relation references.

## Compatibility Evidence

dbt Core 1.10 with the DuckDB adapter was run against the model-properties fixture. The process wrote `manifest.json` before a local event-reporting dependency crash. The observed generic test IDs were:

- `test.model_properties.not_null_customers_customer_id.5c9bf9911d`
- `test.model_properties.unique_customers_.ccc5343706`
- `test.model_properties.unique_customers_customer_id.c5af1ff4b1`

The suffix is the last 10 characters of the md5 hash that dbt computes from the synthesized full test name plus hashable test metadata. The product implementation reproduces that in Zig for this supported subset.

## Validation

Required before merging this slice:

- `zig fmt --check src/project.zig src/root.zig build.zig`
- `zig build`
- `zig build test`
- `pytest -q`
- `zig build -Doptimize=ReleaseSafe`
- `python scripts/check_public_safety.py`
- `python scripts/check_runtime_boundary.py`
- `git diff --check`
- public Jaffle Shop DuckDB parse smoke, if the fixture checkout is available

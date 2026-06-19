# M2 `ls --output-keys` Dependency And Config Keys

## Scope

Add a narrow dbt-grounded expansion to `dxt ls --output json --output-keys`
for dotted keys already backed by dxt's Zig graph:

- `tags`
- `config.enabled`
- `config.docs.show`
- `depends_on.nodes`
- `depends_on.macros`

This remains dxt's compact JSON array surface. It does not switch `ls` to
dbt's newline-delimited JSON row output, serialize full dbt node objects, or add
arbitrary nested traversal.

## Upstream References

- dbt Core v1 `core/dbt/task/list.py::ListTask.ALLOWED_KEYS`
- dbt Core v1 `core/dbt/task/list.py::ListTask._get_nested_value`
- dbt Core v1 `core/dbt/task/list.py::ListTask.generate_json`
- dbt Core v1 `tests/unit/task/test_list.py::TestGetNestedValue`

The upstream behavior serializes node dictionaries, filters default JSON output
through `ALLOWED_KEYS`, and supports dot-path output keys such as
`config.materialized`, `config.meta.owner`, and `depends_on.nodes` when present.

## dxt Ownership

- `src/project/selector.zig` owns selected-resource projection from graph data.
- `src/project/manifest.zig` owns compact selected-resource JSON rendering.
- `tests/test_cli.py` covers CLI output against the Zig binary.

## Artifact Surface

No dbt artifacts change. This affects only `dxt ls --output json` stdout.

## Validation

- Native Zig test for selected-resource JSON writer key filtering.
- Python CLI test for `tags`, `config.enabled`, `config.docs.show`,
  `depends_on.nodes`, and `depends_on.macros`.
- Runtime-boundary and public-safety scans before PR publication.

## Stop Conditions

- Do not introduce Python product runtime behavior.
- Do not implement full dbt node serialization in this slice.
- Do not change the existing compact JSON array shape.
- Do not add broad arbitrary JSON path traversal until selected-resource JSON
  is backed by a richer node serialization model.

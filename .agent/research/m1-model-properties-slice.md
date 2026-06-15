# M1 Model Properties Slice

## Scope

This slice extends the native Zig M1 parser to read SQL-backed model properties from YAML files under configured model paths. It remains a deliberately small artifact-first subset, not a general YAML or Jinja implementation.

Implemented surface:

- Scalar model descriptions and dbt-shaped `patch_path`.
- Simple column names and scalar descriptions.
- Simple model and column test names parsed internally for later dbt-shaped test-node work.
- Block-form `config.materialized`.
- Block-form `config.tags` plus top-level inline `tags`.
- `config.enabled: false` for SQL models.
- Disabled SQL model representation under manifest `disabled`.
- Loud failure when an active model `ref`s a disabled model.
- dbt-compatible warnings, not fatal errors, for YAML model properties that do not match a discovered SQL model.

## Compatibility Notes

Active nodes exclude disabled models from `nodes`, `parent_map`, `child_map`, and `dxt ls`. Disabled SQL models are retained in `disabled` as a list under their model unique id, matching the dbt artifact shape more closely than silently dropping them.

The YAML parser is intentionally subset-based. Unsupported richer property forms should fail or remain outside the advertised supported surface until a real YAML layer is introduced.

Parsed generic tests are intentionally not written into model or column objects because dbt manifests represent them as separate `test.*` nodes. Emitting those nodes is a follow-up M1 compatibility slice.

## Validation

Focused fixtures cover model properties, columns, combined source/model YAML, disabled model representation, disabled ref diagnostics, and unmatched model-property warnings.

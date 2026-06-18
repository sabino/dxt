# M1 Unit Test Artifact Slice

## Upstream References

- dbt Core v1:
  - `core/dbt/parser/schemas.py` dispatches top-level `unit_tests:` YAML to the unit-test parser.
  - `core/dbt/parser/unit_tests.py` builds `UnitTestDefinition` resources, unique IDs shaped as `unit_test.<package>.<model>.<name>`, FQNs, config, and tested-model resolution.
  - `core/dbt/artifacts/resources/v1/unit_test_definition.py` defines `UnitTestInputFixture`, `UnitTestOutputFixture`, `UnitTestConfig`, overrides, versions, and artifact defaults.
  - `core/dbt/graph/selector_methods.py` registers `unit_test:` selector behavior.
  - `schemas/dbt/manifest/v12.json` defines the Manifest v12 `unit_tests` map and required object fields.
- dbt Fusion:
  - `crates/dbt-parser/src/resolve/resolve_tests/resolve_unit_tests.rs` is the source-grounded resolver for typed YAML, unique IDs, FQNs, fixture paths, tested-model dependencies, disabled handling, and version expansion.
  - `crates/dbt-schemas/src/schemas/nodes.rs` and `crates/dbt-schemas/src/schemas/manifest/v12.rs` define unit-test nodes and Manifest v12 serialization.

## Implemented Boundary

- Product runtime remains Zig.
- `src/project/types.zig` stores read-only unit-test definitions and dict-style fixture rows.
- `src/project/parse.zig` parses top-level `unit_tests:` entries with `name`, `model`, optional `description`, optional inline `config.tags`, `given` fixtures with `input`, and dict-style `rows` for `given` and `expect`.
- `src/project/resolve.zig` rejects duplicate unit-test unique IDs and resolves each enabled unit test to its tested model.
- `src/project/manifest.zig` writes Manifest v12-shaped `unit_tests` entries and includes them in `parent_map` and `child_map`.
- `src/project/selector.zig` includes read-only unit tests in `ls` for `--resource-type unit_test`, `resource_type:unit_test`, `unit_test:`, `test_type:unit`, and graph expansion from the tested model.
- `src/root.zig` accepts the unit-test selector surface and reports unsupported build execution after writing a manifest.

## Deferred

- Unit-test execution, SQL comparison, fixture materialization, CSV/SQL fixture files, overrides, version expansion, disabled-unit-test placement in `disabled`, full config inheritance, and run-results emission.
- General YAML/Jinja evaluation inside unit-test properties.
- Installed-package unit-test parity and dbt oracle comparison against a pinned public fixture.

## Validation

- Native parser, resolver, manifest, selector, root, and `zig build test` coverage.
- Python CLI coverage in `tests/test_cli.py` for parse, schema validation, `ls`, selector output, and unsupported `build` behavior.

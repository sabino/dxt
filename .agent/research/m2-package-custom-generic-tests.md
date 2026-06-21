# M2 Package Custom Generic Test Compile Slice

## Scope

This slice extends the existing compile-only custom generic-test support from
root-project model-column tests to root-project model columns that reference an
installed-package generic test macro with `package_name.test_name`.

In scope:

- model column `tests` / `data_tests` entries whose test name is
  `package_name.test_name`;
- installed-package `{% test test_name(model, column_name) %}` and
  `{% data_test test_name(model, column_name) %}` blocks;
- static SQL test bodies that render only `{{ model }}` and
  `{{ column_name }}`;
- Manifest fields for `raw_code`, `test_metadata.namespace`,
  `test_metadata.name`, `test_metadata.kwargs`, `depends_on.nodes`,
  `depends_on.macros`, and selected compile fields.

Out of scope:

- runtime execution through `dxt test` or `dxt build`;
- source, seed, or table-level custom generic tests;
- adapter dispatch execution or general macro execution;
- bundled dbt internal macro execution;
- arbitrary Jinja expressions, filters, control flow, or additional kwargs.

## dbt Core References

- `dbt.parser.generic_test_builders.TestBuilder` parses namespaced generic test
  names with the `package.test` pattern, stores `namespace`, strips `name` to
  the unqualified test name, prefixes the synthesized node name with the
  namespace, and builds raw code as
  `{{ package.test_<name>(**_dbt_generic_test_kwargs) }}`.
- `dbt.parser.schema_generic_tests.SchemaGenericTestParser.parse_generic_test`
  emits `test_metadata.namespace`, `test_metadata.name`, and
  `test_metadata.kwargs`, while keeping the test node package as the project
  that owns the YAML property file.
- `SchemaGenericTestParser.render_test_update` records the implementing test
  macro dependency and, for non-`not_null` / non-`unique` generic tests,
  rendering of generic kwargs records the `get_where_subquery` macro dependency.

## dxt Owners

- `src/project.zig` owns materializing model-column generic test nodes from
  parsed YAML properties and resolving the package-qualified macro dependency.
- `src/project/parse.zig` owns synthesized generic-test names and unique-id hash
  metadata, including the dbt-shaped `namespace` value.
- `src/project/compiler.zig` owns render-only custom generic-test body
  compilation.
- `src/project/manifest.zig` owns `test_metadata.namespace` serialization.

## Validation

- Native Zig tests cover package custom generic-test materialization, macro
  dependency identity, missing package macro rejection, supported body
  rendering, and unsupported body rejection.
- Focused pytest uses a synthetic root project with an installed `util_pkg`
  package that provides one `{% test %}` and one `{% data_test %}` custom
  generic test.
- The pytest compares dxt's selected manifest fields against dbt Core when the
  optional local `dbt-core` and `dbt-duckdb` oracle dependencies are available.

## Stop Conditions

Stop before adding general Jinja execution, adapter dispatch execution,
runtime custom generic-test execution, non-column custom generic tests,
source/seed custom generic tests, or Python product behavior.

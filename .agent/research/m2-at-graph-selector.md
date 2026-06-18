# M2 `@` Graph Selector

## Scope

This slice adds dbt-style `@` graph expansion to the existing Zig selector
engine. The selector includes the explicitly matched resource, its descendants,
and the parents required for those descendants.

Supported form:

- `@model` and equivalent supported selector terms such as `@tag:nightly`.

Out of scope:

- YAML selectors.
- State, result, source-status, access, group, and version selectors.
- Indirect-selection flags.
- Richer `ls` output formats.

## Upstream References

dbt Core v1:

- `core/dbt/graph/selector_spec.py::RAW_SELECTOR_PATTERN`
- `core/dbt/graph/selector_spec.py::SelectionCriteria.childrens_parents`
- `core/dbt/graph/selector.py::collect_specified_neighbors`
- `core/dbt/graph/graph.py::select_childrens_parents`
- `core/dbt/graph/graph.py::select_children`
- `core/dbt/graph/graph.py::select_parents`

dbt Core v2 / Fusion:

- `crates/dbt-selector-parser/src/parser.rs`
- `crates/dbt-parser/src/resolve/resolve_selectors.rs`

## dxt Ownership

- `src/root.zig` validates supported CLI selector syntax.
- `src/project/selector.zig` parses selector terms and applies graph expansion.
- `tests/test_cli.py` pins black-box `dxt ls` behavior against the selector
  graph fixture.

## Validation

- Native Zig tests cover selector-term parsing for standalone `@` and malformed
  combinations with `+` graph operators.
- Python CLI tests cover `dxt ls --select @...` output and malformed `@`
  selector rejection.

## Stop Conditions

Stop before changing selector method coverage, indirect-selection behavior,
resource matching semantics, CLI output formats, or artifact writers.

# M2 Depth-Limited Plus Selectors

## Scope

This slice adds dbt-style depth limits to the existing Zig selector graph
expansion behavior.

Supported forms:

- `1+model` for direct parents only.
- `model+1` for direct children only.
- `1+model+1` for bounded parent and child expansion.
- Existing unlimited `+model`, `model+`, and `+model+` remain supported.

Out of scope:

- `@` childrens-parents selection.
- YAML selectors.
- State, result, source-status, access, group, and version selectors.
- Indirect-selection flags.
- Richer `ls` output formats.

## Upstream References

dbt Core v1:

- `core/dbt/graph/selector_spec.py::RAW_SELECTOR_PATTERN`
- `core/dbt/graph/selector_spec.py::SelectionCriteria`
- `core/dbt/graph/selector.py::collect_specified_neighbors`
- `core/dbt/graph/graph.py::select_parents`
- `core/dbt/graph/graph.py::select_children`

dbt Core v2 / Fusion:

- `crates/dbt-selector-parser/src/parser.rs`
- `crates/dbt-parser/src/resolve/resolve_selectors.rs`

## dxt Ownership

- `src/root.zig` validates supported CLI selector syntax.
- `src/project/selector.zig` parses selector terms and applies graph expansion.
- `tests/test_cli.py` pins black-box `dxt ls` behavior against the fixture
  graph used by selector integration tests.

## Validation

- Native Zig tests cover selector-term parsing for unlimited and depth-limited
  parent/child operators.
- Python CLI tests cover `dxt ls --select` output for bounded parent and child
  traversal, combined parent/child traversal, and invalid plus combinations.

## Stop Conditions

Stop before changing selector method coverage, resource matching semantics, CLI
output formats, or artifact writers. This is only a bounded graph-neighbor
selector slice.

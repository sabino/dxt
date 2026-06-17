# M2 File Selector Parity

## Upstream References

- dbt Core v1 `core/dbt/graph/selector_methods.py::FileSelectorMethod`:
  matches each selectable node's `original_file_path` basename and stem using
  `fnmatch`.
- dbt Core v1 `core/dbt/graph/selector_spec.py`: selector method parsing and
  selector expression shape shared by `--select` and `--exclude`.
- dbt Core v1 `core/dbt/task/list.py::ListTask`: `dbt ls` consumes the common
  selector engine and has no artifact output.
- dbt Core v2 / Fusion `crates/dbt-clap-core/src/lib.rs`: CLI selector parsing
  still routes command `--select` and `--exclude` through common selection
  criteria.
- dbt Core v2 / Fusion `crates/dbt-scheduler/src/node_selector.rs`: selector
  matching is centralized for scheduler/list command reuse; current path
  matching behavior is documented separately from this file-selector slice.

## dxt Ownership

- `src/root.zig` validates that `file:` is a supported selector method before
  command dispatch.
- `src/project/selector.zig` owns basename/stem matching for models, seeds,
  generic tests, sources, and exposures.
- Commands that use the shared selected-resource list (`ls`, `compile`, `run`,
  `build`, `docs generate`, and `source freshness`) inherit this selector
  method without command-specific parsing.

## Implemented Slice

- `file:<name>` matches the final path component of `original_file_path`, for
  example `file:orders.sql`.
- `file:<stem>` matches the filename without its final extension, for example
  `file:orders`.
- `*` and `?` wildcards reuse dxt's existing selector wildcard semantics against
  the basename or stem, for example `file:*orders.sql`.
- Path-bearing values such as `file:models/orders.sql` do not match, preserving
  the distinction between dbt's `file:` and `path:` methods.

## Stop Conditions

- No `@` selector expansion.
- No depth-limited `+` syntax.
- No YAML selectors.
- No state/result/source-status selectors.
- No richer `ls` output formats.
- No path normalization, patch-path matching, or bracket-character `fnmatch`
  classes in this slice.
- No Python product runtime.

## Validation

- Native selector tests cover basename, stem, wildcard, and non-path matching.
- CLI coverage exercises `dxt ls --select file:...` for model SQL files, seed
  CSV files, generic-test schema YAML, source schema YAML, and exposure schema
  YAML, plus `dxt docs generate` selector reuse through the common Zig selector
  engine.

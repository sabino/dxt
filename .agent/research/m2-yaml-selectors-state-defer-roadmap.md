# M2 YAML Selectors And State/Defer Roadmap

## Scope

This is a source-grounded roadmap for issue #134. It maps dbt Core v1 selector
configuration, state/result/source-status selectors, and deferral behavior to
dxt ownership boundaries before any broad implementation work.

This slice does not change product runtime behavior. The next implementation
slice should start with a small Zig-owned YAML selector surface and stop before
state comparison or deferral semantics.

## Upstream References

dbt Core v1:

- `core/dbt/config/selectors.py::SelectorConfig.from_path`,
  `render_from_dict`, and `selectors_from_dict` load `selectors.yml`, render it
  with the project renderer, validate it as a `SelectorFile`, enforce one
  default selector, and parse selector definitions into graph selection specs.
- `core/dbt/graph/cli.py::parse_from_selectors_definition`,
  `parse_from_definition`, `parse_dict_definition`, `parse_union_definition`,
  `parse_intersection_definition`, and `_parse_include_exclude_subdefs` define
  YAML selector semantics for string definitions, method/value dictionaries,
  selector references through `method: selector`, union, intersection, exclude,
  and default metadata.
- `core/dbt/graph/selector_spec.py::RAW_SELECTOR_PATTERN`,
  `SelectionCriteria`, `SelectionUnion`, `SelectionIntersection`,
  `SelectionDifference`, and `IndirectSelection` define the shared CLI/YAML
  selector grammar, graph modifiers, method arguments such as
  `config.materialized`, and per-selector indirect selection override.
- `core/dbt/graph/selector.py::NodeSelector.get_nodes_from_criteria`,
  `collect_specified_neighbors`, `select_nodes_recursively`, and
  `expand_selection` apply method matching, `+` and `@` graph expansion,
  union/intersection/difference composition, and indirect test selection.
- `core/dbt/graph/selector_methods.py::MethodName`,
  `StateSelectorMethod`, `ResultSelectorMethod`, and
  `SourceStatusSelectorMethod` define the state selector method names and the
  artifact-backed matching behavior for `state:*`, `result:*`, and
  `source_status:fresher`.
- `core/dbt/contracts/state.py::PreviousState` loads comparison
  `manifest.json`, `run_results.json`, previous `sources.json`, and current
  target `sources.json` for stateful selectors.
- `core/dbt/cli/params.py` defines `--selector`, `--state`, `--defer`,
  `--defer-state`, and `--favor-state`. `--selector` names entries from
  `selectors.yml`; `--state` is the default comparison and deferral artifact
  directory; `--defer-state` overrides only deferral state; `--favor-state`
  changes defer resolution preference.
- `core/dbt/contracts/graph/manifest.py::Manifest.resolve_ref`,
  `resolve_source`, and related deferral helpers show where deferred manifest
  nodes enter runtime relation resolution after selection has already chosen
  the current invocation's resources.

dbt Core v2 / Fusion references:

- `crates/dbt-parser/src/resolve/resolve_selectors.rs` is the Fusion-era
  selector YAML resolution reference.
- `crates/dbt-parser/src/resolver.rs` is the wider project resolve phase that
  wires selector resolution into manifest construction.
- `crates/dbt-clap-core/src/commands.rs` carries command flag surfaces for
  selection and stateful command options.
- `crates/dbt-scheduler/src/node_selector.rs` is the scheduler-side selector
  matching reference, including source-status matching.
- `crates/dbt-schemas/src/schemas/manifest/*`,
  `crates/dbt-schemas/src/schemas/run_results.rs`, and
  `crates/dbt-schemas/src/schemas/sources.rs` are the artifact shape references
  for state, result, and source-status inputs.

## dxt Ownership

- `src/root.zig` owns CLI option parsing and should add `--selector`, `--state`,
  `--defer`, `--defer-state`, and `--favor-state` only when each option has a
  Zig-owned behavior boundary. It currently validates supported `--select` and
  `--exclude` selector syntax before command dispatch.
- `src/project/selector.zig` owns selector term parsing, method matching, graph
  expansion, exclude handling, deterministic selected-resource ordering, and
  selected-resource output fields. It should remain the common selector engine
  for `ls`, `compile`, `run`, `seed`, `test`, `build`, `docs generate`, and
  `source freshness`.
- A new `src/project/selector_config.zig` should own `selectors.yml` loading and
  YAML selector definition normalization. It should produce the same internal
  selector expression shape consumed by `src/project/selector.zig` instead of
  adding command-specific selection behavior.
- A future `src/project/state.zig` should own artifact input loading for
  comparison manifests, run results, and sources freshness artifacts. It should
  expose a small state view to `src/project/selector.zig` rather than letting
  selector matching read files directly.
- Deferral should stay separate from selection. A future resolver/runtime slice
  should consume defer state after current-project parsing and selection, at the
  point where `ref()` / `source()` runtime relations are resolved for unselected
  dependencies.

## Proposed Implementation Slices

### 1. YAML Selector String Alias

Implement `--selector <name>` for root-project `selectors.yml` entries whose
`definition` is a scalar string that already passes dxt's current CLI selector
validation.

In scope:

- Parse a top-level `selectors:` list from `selectors.yml`.
- Support entries with scalar `name:` and scalar `definition:`.
- Support quoted or unquoted scalar selector strings.
- Resolve `--selector name` into the same selection string used by `--select`.
- Apply the resolved selector through existing `src/project/selector.zig`
  behavior for all commands that already accept `--select`.
- Reject missing selector files, missing names, duplicate selector names, and
  non-string definitions with the existing unsupported-selector style error.

Out of scope:

- Default selectors.
- YAML union, intersection, exclude, `method`/`value` dictionaries,
  `method: selector` references, YAML anchors, or Jinja-rendered selector data.
- State/result/source-status selector methods.
- Deferral or state artifact loading.
- Indirect selection flags.

Validation:

- Native Zig tests for the `selectors.yml` scalar parser and duplicate/missing
  selector handling.
- Focused CLI tests using `dxt ls --selector <name>` on a synthetic fixture and
  checking it matches the equivalent `--select` output.
- `zig fmt --check` for touched Zig files and `zig build test`.

### 2. YAML Method Dictionaries And Composition

After the string alias works, add YAML dictionaries that normalize to existing
selector terms:

- `{method: tag, value: nightly}` and single-key shorthand such as
  `{tag: nightly}` for methods already supported by dxt.
- Per-definition `exclude` by mapping to the existing exclude engine.
- `union` and `intersection` composition for supported child definitions.
- `method: selector` references to earlier entries only, matching dbt Core's
  forward-reference rejection.

Stop before adding stateful methods, default selectors, indirect-selection
override, or Jinja rendering in selector definitions.

### 3. State Artifact Input Loader

Add a Zig-only state artifact loader with no selector behavior change first:

- Parse `--state` and `--defer-state` as project-relative or absolute artifact
  directories.
- Load comparison `manifest.json`, `run_results.json`, and `sources.json` into
  narrow dxt structs for the fields stateful selectors need.
- Validate schema family or metadata version enough to reject unsupported
  artifacts deterministically.
- Keep paths and loaded artifact data out of `manifest.json` and
  `run_results.json` outputs unless dbt schemas require them.

Stop before matching `state:*`, `result:*`, `source_status:*`, or changing
runtime relation resolution.

### 4. `state:new` Then Narrow `state:modified`

Start state selectors with the lowest-risk comparison:

- `state:new` compares current selected graph unique IDs against previous
  manifest nodes, sources, exposures, unit tests, and later semantic resources.
- A later `state:modified.body` or narrow model/source content comparison can
  follow after dxt has enough manifest fields to make dbt-compatible decisions.

Do not implement broad `state:modified` until model/source/exposure/test
`same_*` equivalents are explicitly mapped to fields dxt currently emits.

### 5. Result And Source-Status Selectors

Implement artifact-backed methods independently:

- `result:<status>` reads previous `run_results.json` and matches current graph
  unique IDs with matching result status.
- `source_status:fresher` reads previous state `sources.json` and current
  target `sources.json`, then matches source unique IDs whose current
  `max_loaded_at` is newer.

Stop before inventing source-status values beyond dbt's observed
`source_status:fresher` behavior.

### 6. Deferral

Only after selector state inputs are stable, add deferral as runtime relation
resolution:

- `--defer` permits unselected dependency `ref()` / `source()` resolutions to
  use previous/defer-state manifest relations.
- `--defer-state` supplies a deferral-only manifest directory and must not
  replace `--state` selector comparison inputs.
- `--favor-state` changes preference when both current and deferred relation
  candidates exist.

Deferral must not change selected-resource sets by itself. It changes relation
resolution for dependencies that selection chose not to execute.

## Stop Conditions

- Do not implement product selector, state, artifact, resolver, or runtime
  behavior in Python.
- Do not add state/defer behavior before a Zig state artifact input boundary
  exists.
- Do not treat dbt Core v2 / Fusion alpha behavior as overriding dbt Core v1
  observable outputs.
- Do not mix selector YAML parsing with manifest parser refactors or artifact
  writer changes.
- Do not implement `state:modified` broadly until the field-level comparison
  matrix is recorded for dxt's current Manifest v12 subset.
- Do not make deferral alter `ls` selected-resource output; selection and
  relation resolution remain separate phases.

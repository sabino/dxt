# M2 Vars-Backed Ref/Source Slice

This note grounds the current dxt slice in upstream dbt source. It is not a
claim of full dbt `var()` compatibility. The implemented surface is a narrow
dependency-argument subset: scalar project vars and CLI `--vars` values may
resolve `var('name')` or `var('name', 'default')` when that expression is used
as an argument to `ref()` or `source()`.

## Upstream Source References

dbt Core v1 Python, branch `1.latest`, commit `566b75d`:

- `core/dbt/parser/manifest.py::ManifestLoader.load` reads files, parses
  macros/tests before SQL-like resources, rebuilds lookups, parses schema YAML,
  patches sources, sets selectors, builds maps, and then processes sources,
  refs, unit tests, docs, metrics, saved queries, and functions.
- `core/dbt/parser/base.py::ConfiguredParser.render_with_context`,
  `render_update`, `update_parsed_node_config`, and `parse_node` create
  parse-time nodes, render SQL with parser context, capture config/macro
  calls, update parsed configs, and add enabled or disabled nodes.
- `core/dbt/parser/models.py::ModelParser.render_update` and static-parser
  fallback show that non-static dependency cases work through parser-context
  rendering rather than through a literal-only extractor.
- `core/dbt/context/providers.py::ParseProvider`,
  `ParseRefResolver.resolve`, and `ParseSourceResolver.resolve` define
  parse-time `execute = False`, append rendered ref/source arguments to
  `model.refs` and `model.sources`, and return the current model relation.
- `core/dbt/context/providers.py::RuntimeProvider`,
  `RuntimeRefResolver.resolve`, and `RuntimeSourceResolver.resolve` define the
  stricter runtime behavior that resolves against the manifest and validates
  dependency context.
- `core/dbt/context/base.py::Var.__call__` and
  `core/dbt/context/providers.py::ModelConfiguredVar` / `ParseVar` define
  broad dbt `var()` behavior: CLI vars, package/project vars, defaults,
  non-string values, string re-rendering, and parse-time missing-var behavior.
- `core/dbt/config/runtime.py::load_project`,
  `core/dbt/config/project.py::VarProvider.vars_for`, and
  `core/dbt/config/utils.py::parse_cli_vars` define project/vars.yml/CLI var
  loading and precedence.
- `core/dbt/cli/main.py` applies `@p.vars` to `build`, `docs generate`,
  `compile`, `list`/`ls`, `parse`, and `run`; `core/dbt/cli/params.py::vars`
  defines `--vars` as a YAML mapping CLI option.

dbt Core v2 / Fusion foundation, branch `main`, commit `0529e06`:

- `crates/dbt-clap-core/src/lib.rs::CommonArgs` defines global `--vars` as a
  YAML mapping and threads it into `EvalArgs`; `CoreCommand` includes parse,
  list/ls, compile, run, build, and docs.
- `crates/dbt-loader/src/args.rs::LoadArgs` and
  `crates/dbt-loader/src/loader.rs::load`, `vars_data_from_root`, and
  `merge_vars` load `vars.yml`, preserve original CLI vars for state, and pass
  merged vars downstream with CLI precedence.
- `crates/dbt-parser/src/args.rs::ResolveArgs` carries vars into resolution.
- `crates/dbt-jinja-vars/src/var.rs` and
  `crates/dbt-jinja-vars/src/configured_var.rs` implement positional and
  keyword defaults, CLI precedence, package vars, parse-time missing-var `none`
  behavior when `execute=false`, and strict compile/config missing-var errors.
- `crates/dbt-parser/src/renderer.rs::render_sql_file` renders SQL with a
  parse Jinja environment and records rendered resources; `augment_sql_resources_with_static_sources`
  recovers literal `source()` calls in false branches without treating
  non-literal static calls as resolved.
- `crates/dbt-parser/src/dbt_namespace.rs::DbtNamespace` intercepts parse-mode
  adapter calls such as `get_relation` and `get_columns_in_relation`.

## dxt Owner Map

- `src/project/config.zig`: narrow top-level scalar `vars:` parsing and scalar
  CLI `--vars` map parsing.
- `src/project/loader.zig`: applies root project vars and CLI overrides before
  parsing SQL models so dependency extraction sees the same graph context as
  compile/docs/run/build preflight.
- `src/project/jinja.zig`: resolves only literal strings and
  `var('name')` / `var('name', 'default')` string arguments when scanning
  `ref()` and `source()` calls.
- `src/project/compiler.zig`: uses the same argument resolver while rendering
  `ref()` and `source()` to deterministic relation strings.
- `src/root.zig`: accepts `--vars` on parse, ls, compile, docs generate, run,
  and build, matching the dbt command surface for this option.

## Mirror Now

- Accept `--vars` for parse, ls, compile, docs generate, run, and build.
- Parse scalar top-level root project `vars:` from `dbt_project.yml`.
- Parse scalar CLI `--vars` maps and let CLI values override project values.
- Resolve `var('name')` and `var('name', 'default')` only when they are direct
  `ref()` or `source()` arguments.
- Use the resolved graph consistently for parsing, listing selectors, compile,
  docs artifacts, and run/build preflight compiled SQL.

## Explicitly Deferred

- General dbt `var()` compatibility outside `ref()` and `source()`.
- `var.has_var`, keyword default syntax, non-string defaults, non-string YAML
  values, Jinja-rendered var values, and missing-var parse/runtime parity.
- `vars.yml` and recursive merge with CLI vars.
- Package-scoped and nested project vars.
- Vars in profile rendering, target rendering, and project config rendering.
- Dynamic expressions, concatenation, macro calls, `env_var`, `target`, `this`,
  `graph`, or adapter calls inside dependency arguments.
- Parse-time `execute=false` Jinja context, dead-branch static source recovery,
  adapter introspection interception, and partial-parse var hashing.

## Validation

- Native Zig tests cover scalar var parsing, CLI override replacement,
  `var()` argument resolution including a simple positional default, SQL
  scanner dependency extraction, and compile rendering.
- Pytest integration covers parse manifest edges, `ls` graph expansion through
  var-resolved dependencies, compile output, docs generate output, and run/build
  preflight compiled SQL.
- This slice must continue to validate against the manifest schema slice and
  public-safety/runtime-boundary scripts before PR merge.

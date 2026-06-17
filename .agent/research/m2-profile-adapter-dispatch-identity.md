# M2 Profile-Derived Adapter Dispatch Identity Slice

This slice replaces dxt's temporary static adapter dispatch prefix list with a
profile-derived adapter type for parse-time `adapter.dispatch(...)` dependency
recording. It still records `depends_on.macros` only. It does not validate
credentials, render secrets, open adapter connections, execute macros, implement
project `dispatch:` config, compile `target.*`, or run materializations.

## Upstream References

dbt Core v1, branch `1.latest`, commit `566b75d`:

- `core/dbt/config/runtime.py::load_profile` selects the project profile and
  passes CLI profile, target, and threads overrides into profile loading.
- `core/dbt/config/profile.py::Profile.pick_profile_name`,
  `render_profile`, `from_raw_profile_info`, `_get_profile_data`, and
  `_credentials_from_profile` define profile-name selection, target selection,
  selected-output lookup, required `type`, and adapter plugin identity.
- `core/dbt/config/profile.py::Profile.to_target_dict` and
  `core/dbt/context/target.py::TargetContext.target` define the common target
  context fields, including `type`, `name`, `target_name`, `profile_name`, and
  `threads`.
- `core/dbt/config/runtime.py::RuntimeConfig.get_metadata` emits manifest
  metadata `adapter_type` from credentials.
- `core/dbt/context/providers.py::BaseDatabaseWrapper._get_adapter_macro_prefixes`
  defines dispatch prefixes as adapter type hierarchy plus `default`.
- `core/dbt/context/providers.py::BaseDatabaseWrapper.dispatch` rejects dotted
  macro names and deprecated `packages`, then searches
  `{adapter_prefix}__{macro_name}` candidates.
- `core/dbt/clients/jinja_static.py::statically_parse_adapter_dispatch` uses the
  adapter wrapper to statically resolve literal dispatch calls into macro
  dependencies.

dbt Core v2 / Fusion foundation, branch `main`, commit `0529e06`:

- `crates/dbt-loader/src/load_profiles.rs::load_profiles` locates
  `profiles.yml`, selects profile and target, resolves profile data, and stores
  the adapter type in `DbtProfile`.
- `crates/dbt-profile/src/resolve.rs` resolves profile name, target override,
  selected output, and adapter type as data.
- `crates/dbt-schemas/src/schemas/profiles.rs::DbConfig::adapter_type` maps
  typed profile configuration into `AdapterType`.
- `crates/dbt-adapter-core/src/lib.rs::AdapterType` defines adapter identity and
  accepts the Postgres naming forms.
- `crates/dbt-jinja/minijinja/src/dispatch_object.rs::get_adapter_prefixes`
  defines Fusion's current parent-prefix fallback: `redshift -> postgres`,
  `databricks -> spark`, then `default`.
- `crates/dbt-jinja/minijinja/src/dispatch_object.rs::DispatchObject::call`
  applies adapter prefixes during dispatch resolution.

## dxt Ownership

- `src/project/profile.zig` owns the narrow scalar profile/target adapter-type
  parser.
- `src/project/config.zig` owns `dbt_project.yml` `profile:` discovery.
- `src/project/loader.zig` resolves profile identity before loading macros and
  resources, so parse-time Jinja scanning sees the selected adapter type.
- `src/project/jinja.zig` derives static dispatch prefixes from
  `Graph.adapter_type`.
- `src/project/manifest.zig` emits manifest `metadata.adapter_type`.

## Supported Surface

- Select profile from CLI `--profile`, falling back to `dbt_project.yml`
  `profile:`.
- Select target from CLI `--target`, falling back to profile `target:`, then
  `default`.
- Read selected output scalar `type` from `profiles.yml`.
- Normalize `postgresql` to dispatch adapter type `postgres`.
- Use dispatch prefix order:
  - `redshift`, `postgres`, `default`
  - `databricks`, `spark`, `default`
  - selected adapter, `default`
- Preserve the current `duckdb` default only when no profile file is found and
  no profile-related CLI flag requested profile loading.

## Validation

- Native Zig tests cover profile/target selection, missing profile/target/type
  errors, Postgres alias normalization, profile-derived dispatch prefix choice,
  and parent prefix fallback.
- Pytest fixture `profile_adapter_dispatch` validates parse-time manifest
  `depends_on.macros` and `metadata.adapter_type` for default Postgres, explicit
  DuckDB, and Redshift parent fallback targets through the Zig binary.
- Existing no-profile fixtures remain covered by the default DuckDB identity.

## Stop Conditions

- Do not render Jinja in `profiles.yml` in this slice.
- Do not read host-global profile locations beyond the project or explicit
  `--profiles-dir` path.
- Do not validate or emit credentials.
- Do not implement project `dispatch:` config.
- Do not execute dispatched macros, materializations, tests, or adapter SQL.
- Do not add relation identity, quoting, `target.*`, `this`, catalog
  introspection, or `run_results.json`.

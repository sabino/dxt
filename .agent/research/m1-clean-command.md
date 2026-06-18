# M1 Clean Command Slice

This note maps the first `dxt clean` implementation to upstream dbt behavior.

## Upstream References

dbt Core v1 reference files:

- `core/dbt/cli/main.py`: `clean` is a top-level command with
  `--clean-project-files-only`, `--profiles-dir`, `--project-dir`,
  `--target-path`, and `--vars`; it requires a project but unsets profile
  requirements.
- `core/dbt/cli/params.py`: `--clean-project-files-only` defaults to true and
  `--no-clean-project-files-only` is the unsafe escape hatch.
- `core/dbt/config/project.py`: omitted `clean-targets` defaults to the
  effective target path, where target path is CLI `--target-path`, project
  `target-path`, or `target`.
- `core/dbt/task/clean.py`: `CleanTask.run()` rejects source/test paths,
  rejects outside-project paths while the project-files-only guard is enabled,
  ignores missing targets, and removes clean targets.

Fusion/dbt Core v2 reference files:

- `crates/dbt-clap-core/src/lib.rs`: Fusion clean accepts positional files.
- `crates/dbt-loader/src/clean.rs`: Fusion rejects absolute paths, protects
  project source directories, and removes configured paths plus the output
  directory.

Fusion behavior is a safety reference only for this slice. dbt Core v1 command
shape is the active compatibility target.

## dxt Scope

The first dxt implementation is intentionally conservative because `clean` is a
recursive deletion command:

- `dxt clean` is implemented in Zig.
- It parses `clean-targets` from `dbt_project.yml` as inline or block lists.
- If `clean-targets` is omitted, it defaults to the effective target path,
  honoring CLI `--target-path`.
- It accepts `--project-dir`, `--profiles-dir`, `--target-path`, `--vars`, and
  `--clean-project-files-only`.
- It rejects `--no-clean-project-files-only`, absolute targets,
  parent-directory traversal, empty targets, project-root targets, and protected
  source directories.
- It skips missing paths and plain files, and deletes only project-relative
  directories.

The command does not require a profile, load the graph, write artifacts, execute
adapters, support selectors, or support Fusion positional file arguments.

## Validation

- Native Zig tests cover command recognition, command help, config parsing,
  clean-target path validation, and source-directory protection.
- Python CLI tests cover configured clean targets, default effective
  `--target-path`, missing target success, unsafe target rejection without
  deletion, no profile requirement, and plain-file skipping.

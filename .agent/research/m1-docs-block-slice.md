# M1 Docs Block Slice

## Scope

This slice extends the native Zig parser and partial manifest writer with a dbt Core-compatible docs block subset:

- discover `.md` files under configured model paths
- parse `{% docs name %}` / `{% enddocs %}` blocks
- emit `docs` manifest entries keyed as `doc.<package>.<name>`
- resolve whole-description literal `{{ doc("name") }}` and `{{ doc('name') }}`
- attach resolved doc block IDs to model and column `doc_blocks`
- fail loudly for malformed docs blocks, duplicate docs names, missing docs, and dynamic `doc` calls

The product runtime remains Zig. Python changes are limited to tests.

## Compatibility Evidence

The fixture was checked against dbt Core 1.10 with the DuckDB adapter. The written Core manifest showed:

- docs entries include `unique_id`, `resource_type`, `package_name`, `name`, `path`, `original_file_path`, and `block_contents`
- docs `path` is relative to the model path, while `original_file_path` includes the model path
- docs block contents are trimmed before manifest emission
- literal `doc` descriptions are rendered into model and column descriptions
- model and column `doc_blocks` list referenced doc unique IDs
- docs entries do not appear as lineage keys in `child_map`

Fusion preview was also checked as a secondary signal, but Core remains the contract for this M1 slice.

## Validation

Required before merging this slice:

- `zig fmt --check src/project.zig src/root.zig build.zig`
- `zig build`
- `zig build test`
- `pytest -q`
- `git diff --check`
- public-safety and runtime-boundary scans
- public Jaffle Shop DuckDB parse smoke, if the fixture checkout is available

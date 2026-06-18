# M3 Docs Serve Static Slice

This note maps the first `dxt docs serve` slice to upstream dbt behavior.

## Upstream References

dbt Core v1 reference files:

- `core/dbt/cli/main.py`: `docs serve` is wired with `--browser`,
  `--host`, `--port`, `--profiles-dir`, `--project-dir`, `--target-path`,
  and `--vars`.
- `core/dbt/task/docs/serve.py`: `ServeTask.run()` changes into the project
  target directory, copies dbt's bundled `index.html`, optionally opens a
  browser, then starts a simple static HTTP server forever.
- `core/dbt/cli/params.py`: dbt Core defaults are `host=127.0.0.1`,
  `port=8080`, and `browser=True`.

Fusion/dbt Core v2 reference files:

- `crates/dbt-clap-core/src/lib.rs`: Fusion exposes docs serve arguments for
  target path, host, port, and `--no-open`.
- `crates/dbt-docs-server/src/lib.rs` and `src/server.rs`: Fusion docs serve is
  a richer API server for docs v2/index artifacts, not the right first target
  for dxt's current legacy JSON docs artifacts.

## dxt Scope

The first dxt implementation is intentionally close to dbt Core v1's static
server boundary:

- `dxt docs serve` is implemented in Zig.
- It resolves `--target-path` using the existing project target-path logic.
- It writes a small dxt-owned `index.html` into the target directory so `/`
  has a useful response.
- It serves existing files from the target directory over HTTP with path
  traversal protection and basic content types.
- It supports `--host`, `--port`, `--no-browser`, `--browser`, and Fusion-style
  `--no-open` parsing. Browser opening remains intentionally unsupported for
  now; use `--no-browser`.

The command does not load the project graph, generate docs artifacts, compile
SQL, introspect DuckDB, mutate `manifest.json` or `catalog.json`, implement the
dbt docs SPA, or implement Fusion docs v2 API/index endpoints.

## Validation

- Native Zig tests cover command recognition, option parsing, request path
  normalization, traversal rejection, and content-type mapping.
- Python CLI integration starts the native `dxt docs serve` process on
  localhost, fetches `/`, `/manifest.json`, and `/catalog.json`, checks
  traversal rejection, and verifies `manifest.json` and `catalog.json` are not
  mutated.

# Optional Bundled Native Drivers

These notices accompany the optional standalone macOS build. The default Linux
release contract still uses separately installed native database libraries.
Retain these notices when distributing a driver-bundled executable.

## Pinned Build Inputs

| Component | Input |
| --- | --- |
| DuckDB 1.4.2 | Official macOS [static release archives](https://github.com/duckdb/duckdb/releases/tag/v1.4.2), including the supplied static extensions and third-party libraries. Both architecture archives have content hashes in `build.zig.zon`. |
| libpq 18.4 | PostgreSQL client source `REL_18_4`, commit `f5cc81719e6da4cbdb1f797c48b693e91018153a`, through the [Zig build package](https://github.com/allyourcodebase/libpq/tree/ad2f65b2d91311f6d85c329e7551d902f67c31b5). No PostgreSQL server is linked. |
| LibreSSL 4.0.0 | [Pinned build package](https://github.com/allyourcodebase/libressl/tree/8c63fadf71925d74942a847b9a6b3a28930792a3) and its pinned portable source. TLS remains enabled. |
| libcquery 0.1.1 | [Build-time target configuration](https://github.com/agagniere/libc-query/tree/dff18c3b381dfdcd45178fc510f488991263aca7). |

DuckDB static archive SHA-256:

- `static-libs-osx-arm64.zip`: `2fd0e5b4d10b299b5bfd6413a4b7549e824b6446d78d32207006d4d48b5a2872`
- `static-libs-osx-amd64.zip`: `29960731276b0ce85d0d148b7c4caaeb45bb3ef447ec14978c636e56493f110e`

`DUCKDB-LICENSE.txt` and `DUCKDB-THIRD-PARTY-NOTICES.txt` retain the upstream
DuckDB release's main license and third-party notices, including the core,
JSON, Parquet, ICU and other supplied extensions. The PostgreSQL/LibreSSL
source notices and native build-package licenses are retained alongside them.

These pins describe the current experimental build; bundling makes client/TLS
security updates a dxt distribution responsibility. Upgrade and validate the
exact inputs before claiming a production-ready distribution. System libraries
supplied by macOS remain OS dependencies rather than separately packaged drivers.

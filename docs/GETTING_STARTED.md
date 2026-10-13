# Getting Started

dxt is a native Zig executable. End users do not need Python, dbt or MetricFlow.
Build requirements and optional package transports are separate from database
runtime requirements.

## Platforms

| Platform | Current status |
| --- | --- |
| Linux x86_64 and ARM64 | Initial SQL acceptance platforms. Release archives currently use external native DuckDB/libpq libraries. |
| macOS Apple Silicon | Experimental source build, including a standalone driver-bundled build. Local validation is recorded in the active plan. |
| macOS Intel | Pinned Zig/DuckDB build inputs exist; actual Intel execution is not certified. |
| Windows | Future portability/certification work. Library-name support alone is not Windows support. |

## macOS Standalone Build

Install Apple's Command Line Tools if you do not already have them:

```sh
xcode-select --install
```

From a checkout, build:

```sh
./scripts/build_macos.sh
./zig-out/bin/dxt version
```

The helper downloads and verifies Zig **0.16.0** into an ignored tool directory.
Zig's package manager fetches hash-pinned native build inputs. The executable
bundles DuckDB **1.4.2** and its supplied static extensions, plus the libpq
**18.4** client and LibreSSL **4.0.0** TLS libraries. No PostgreSQL server is
included or installed. This build uses macOS's supplied system and C++ runtimes.
The SDK and Zig are build-time requirements; copying `dxt` to a compatible Mac
does not require those build tools.

Homebrew and a Python environment are not required. With full Xcode instead of
Command Line Tools, set `SDKROOT` to your macOS SDK. If Zig 0.16.0 is already
available, the equivalent command is:

```sh
zig build -Doptimize=ReleaseSafe -Dbundle-drivers=true
```

Use `-Dmacos-sdk=<SDK directory>` when needed. Bundled DuckDB currently supports
macOS x86_64/aarch64 only. `-Dbundle-duckdb` and `-Dbundle-postgres` can be
selected independently; ordinary `zig build` preserves the existing dynamic
driver build. These source builds do not create a certified macOS release.

The SQL grammar library retains its accepted PostgreSQL **17.7** source;
libpq **18.4** is the separately pinned connection client. Their private C
helpers are isolated because their frontend/backend build settings differ.
The client version does not require your server to be the same version.

## First DuckDB Project

For a bundled build, clear any old explicit driver override. An override is
authoritative and still selects that external library. A DuckDB override must
match the embedded **1.4.2** version exactly; mixing two DuckDB C++ versions in
one process is unsafe and is rejected before opening a database. Use the dynamic
driver build to evaluate another DuckDB version.

```sh
unset DXT_DUCKDB_LIBRARY DXT_POSTGRES_LIBRARY
export PATH="$PWD/zig-out/bin:$PATH"
export DXT_DUCKDB_BACKEND=native
dxt init demo
dxt debug --project-dir demo --profiles-dir demo
dxt build --project-dir demo --profiles-dir demo --threads 2
dxt test --project-dir demo --profiles-dir demo
dxt docs generate --project-dir demo --profiles-dir demo --static
dxt docs serve --project-dir demo --profiles-dir demo --port 8080 --no-browser
```

`init` takes a project name, such as `demo`, rather than an absolute directory.
Run it in the directory where the project should be created. The scaffold
contains a profile, seed, model and data tests. Results and offline
`static_index.html` are in `demo/target`. Stop the server with Ctrl+C.

## Existing PostgreSQL Projects

The server is supplied by you. A bundled build includes the client and does not
require `psql`, a local PostgreSQL server or a separately installed libpq.
Use your existing `type: postgres` profile and normal connection/TLS settings:

```sh
dxt debug --project-dir my_project --profiles-dir my_profiles --target dev
dxt build --project-dir my_project --profiles-dir my_profiles --target dev
```

Certificates, credentials, network access and the remote server remain deployment
inputs. Static linking does not remove those inputs. Bundled client/TLS behavior
needs its own deployment validation, including your authentication method;
it does not certify every libpq build feature or enterprise authentication provider.

## Dynamic Driver Builds

An ordinary build is smaller and loads database libraries separately:

```sh
zig build -Doptimize=ReleaseSafe
```

Set `DXT_DUCKDB_LIBRARY` or `DXT_POSTGRES_LIBRARY` to an installed native library
when automatic discovery cannot find it. macOS uses `libduckdb.dylib` and
`libpq.5.dylib`/`libpq.dylib`; Linux uses `libduckdb.so` and `libpq.so.5`.
The DuckDB CLI alone does not replace the library for transformation commands.

For PostgreSQL on a Mac with Homebrew:

```sh
brew install libpq
export DXT_POSTGRES_LIBRARY="$(brew --prefix libpq)/lib/libpq.5.dylib"
```

For the pinned DuckDB library, use the official [1.4.2 native archives](https://github.com/duckdb/duckdb/releases/tag/v1.4.2)
and select the extracted library explicitly. A package manager may install a
newer DuckDB version, which requires separate compatibility validation.

## What Still Uses External Tools?

| Workflow | Executable/tool requirement |
| --- | --- |
| Parse/list; bundled DuckDB/PostgreSQL SQL workflows | dxt plus OS-provided libraries. No Python or driver installation. |
| Already installed project packages | No package transport executables during ordinary build/run. |
| Local dependency declarations | Native dxt installation/resolution; no Git or HTTP transport. |
| Git dependencies | `git`, including any requested SSH/auth facilities. |
| Registry/HTTP archives | `curl` for fetching and `tar` for extraction as applicable. |
| Optional DuckDB extensions/services | Their explicitly requested installation, credentials and service requirements. |

macOS supplies curl/tar; Apple's developer tools supply Git. Linux installations
and Windows distributions need their own transport setup. A truly self-contained
online package manager would require embedded HTTP/TLS, archive and Git/SSH
implementations. That is a separate engineering slice; the current package
resolver and runtime are already Zig.

## Upgrade Candidates

Zig [0.17.0](https://ziglang.org/download/) was released on October 1, 2026.
It needs a separate migration: build APIs changed and `@cImport` was removed,
requiring translated C binding modules. A local trial fails in the build script
before product compilation. Keep **0.16.0** for this setup until native and
upstream comparison gates pass with the candidate compiler and dependencies.

DuckDB [1.5.6](https://github.com/duckdb/duckdb/releases/tag/v1.5.6) is a database
upgrade candidate. Evaluate it through a dynamic-driver build, including typed
results, transactions, cancellation, extensions and dbt CLI comparisons before
changing the **1.4.2** contract. Eight native adapter exercises pass against both
versions in a local dynamic-driver trial; full upgrade acceptance is pending.
[Spatial issue #794](https://github.com/duckdb/duckdb-spatial/issues/794)
was resolved by refreshing development sources with generated geometry helpers;
it does not require adding the spatial extension to this project.

See [Architecture](ARCHITECTURE.md), [Compatibility](COMPATIBILITY.md) and
[Releases](RELEASES.md) for the exact runtime and acceptance boundaries.

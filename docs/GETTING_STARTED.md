# Getting Started

dxt is a native Zig executable. End users do not need Python, dbt or MetricFlow.
Build requirements and optional package transports are separate from database
runtime requirements.

## Platforms

| Platform | Current status |
| --- | --- |
| Linux x86_64 and ARM64 | Initial SQL acceptance platforms. Release archives currently use external native DuckDB/libpq libraries. |
| macOS Apple Silicon and Intel | Experimental standalone builds/downloads. Archive publication requires native tests and both-adapter installation on actual macOS runners; complete Core compatibility certification remains pending. |
| Windows | No release binary yet. The vendored SQL parser currently fails to compile on missing Unix headers; portability and native execution gates are required. |

## Release Downloads

[GitHub Releases](https://github.com/sabino/dxt/releases) lists published archives
and SHA256 files. Downloads appear after the automatic workflow succeeds;
use the source-build instructions below until the first release exists.

### Install With Curl

Run this on macOS or GNU/Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/sabino/dxt/main/scripts/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
dxt version
```

The [installer](../scripts/install.sh) selects your machine's native archive,
verifies its SHA256 before extraction and installs `dxt` into `~/.local/bin`.
It includes published prereleases when selecting the newest release, requires
no sudo, and preserves an existing binary if download, checksum or native
version verification fails. It uses OS command-line tools: sh, curl, tar and
sha256sum or shasum. macOS provides these; minimal Linux installations may need
curl and coreutils. No Python, dbt or Zig is required.

To choose a version or installation directory:

```sh
curl -fsSL https://raw.githubusercontent.com/sabino/dxt/main/scripts/install.sh \
  | sh -s -- --version v0.0.0 --bin-dir "$HOME/.local/bin"
```

Replace `v0.0.0` with the tag listed on the release page. To inspect the script
before running it, download it first:

```sh
curl -fsSL -o dxt-install.sh https://raw.githubusercontent.com/sabino/dxt/main/scripts/install.sh
less dxt-install.sh
sh dxt-install.sh --version v0.0.0
```

The installer leaves shell startup files alone. Add
`export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` for zsh or `~/.bashrc` for
bash to retain it in future terminals. Rerun the installer to upgrade or use
`--version` to select an older published release. Remove `~/.local/bin/dxt` to
uninstall; project files and warehouses are preserved.

### Manual Download

| Machine | Archive target |
| --- | --- |
| Linux Intel/AMD 64-bit | `x86_64-linux-gnu` |
| Linux ARM64 | `aarch64-linux-gnu` |
| Mac Apple Silicon | `aarch64-macos` |
| Mac Intel | `x86_64-macos` |

Download the archive and its target-specific `SHA256SUMS.txt` from the same
release. For example, on Apple Silicon, using the version you downloaded:

```sh
shasum -a 256 -c dxt-v0.0.0-aarch64-macos-SHA256SUMS.txt
tar -xzf dxt-v0.0.0-aarch64-macos.tar.gz
mkdir -p "$HOME/.local/bin"
cp dxt-v0.0.0-aarch64-macos/dxt "$HOME/.local/bin/dxt"
export PATH="$HOME/.local/bin:$PATH"
dxt version
```

Use `sha256sum -c` on Linux and replace the archive target/version as needed.
macOS downloads need no Zig, SDK, Homebrew, Python or separate database driver
installation. Linux still requires the native libraries described under
[Dynamic driver builds](#dynamic-driver-builds). PostgreSQL servers and
credentials are always supplied by you.

Mac archives are not Apple Developer ID signed or notarized. Downloaded binaries
may require approval in System Settings → Privacy & Security. Verify the
release checksum before approving the executable; follow
[Apple's approval instructions](https://support.apple.com/en-us/102445) if needed.
The current macOS CI runners
use macOS 15; older macOS versions have not been separately certified.

## macOS Standalone Build

Install Apple's Command Line Tools if you do not already have them:

```sh
xcode-select --install
```

From a checkout, build:

```sh
./scripts/build_macos.sh
./zig-out/bin/dxt version
export PATH="$PWD/zig-out/bin:$PATH"
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
driver build. Release downloads additionally pass the archive and native
installation gates; this does not establish complete macOS Core parity.

The SQL grammar library retains its accepted PostgreSQL **17.7** source;
libpq **18.4** is the separately pinned connection client. Their private C
helpers are isolated because their frontend/backend build settings differ.
The client version does not require your server to be the same version.

## First DuckDB Project

For a bundled Mac build, clear any old explicit driver override. An override is
authoritative and still selects that external library. A DuckDB override must
match the embedded **1.4.2** version exactly; mixing two DuckDB C++ versions in
one process is unsafe and is rejected before opening a database. Use the dynamic
driver build to evaluate another DuckDB version. On a bundled Mac build:

```sh
unset DXT_DUCKDB_LIBRARY DXT_POSTGRES_LIBRARY
```

On Linux, keep the library path from [Linux driver setup](#linux-release-driver-setup).
With `dxt` on PATH, create and run a project on either platform:

```sh
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
export PATH="$PWD/zig-out/bin:$PATH"
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

### Linux Release Driver Setup

Linux release downloads use external database libraries. On Debian/Ubuntu,
install download tools and the PostgreSQL **client** library:

```sh
sudo apt-get update
sudo apt-get install curl unzip libpq5
```

`libpq5` does not install or start a PostgreSQL server. For DuckDB, download the
checksum-pinned native library into your user directory:

```sh
case "$(uname -m)" in
  x86_64)
    dxt_duckdb_arch=amd64
    dxt_duckdb_sha=0a68e623cbdcfa06e10e1b5d6a3092d3fd3679f616008fb1a39b92e4a10d8f43
    ;;
  aarch64|arm64)
    dxt_duckdb_arch=arm64
    dxt_duckdb_sha=095194f4a16aa507afcb4c2e83aa682162a87dd8e779c00bc1bd9c0ebb2ec970
    ;;
  *) echo "Unsupported Linux architecture" >&2; exit 1 ;;
esac
mkdir -p "$HOME/.local/lib/dxt"
curl -fL -o "$HOME/.local/lib/dxt/libduckdb.zip" \
  "https://github.com/duckdb/duckdb/releases/download/v1.4.2/libduckdb-linux-${dxt_duckdb_arch}.zip"
printf '%s  %s\n' "$dxt_duckdb_sha" "$HOME/.local/lib/dxt/libduckdb.zip" | sha256sum -c - &&
  unzip -o "$HOME/.local/lib/dxt/libduckdb.zip" -d "$HOME/.local/lib/dxt"
export DXT_DUCKDB_LIBRARY="$HOME/.local/lib/dxt/libduckdb.so"
export DXT_DUCKDB_BACKEND=native
```

Retain the two exports in your shell configuration. Then run the commands in
[First DuckDB project](#first-duckdb-project); keep `DXT_DUCKDB_LIBRARY` set on Linux.
Other Linux distributions need their equivalent libpq client package. These
archives target GNU libc; musl/Alpine is not a certified target.

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

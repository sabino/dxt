# Release Process

Releases package a native Zig executable, public documentation and upstream
license/provenance notices. Python scripts build and verify release artifacts
in developer/CI environments; they are not part of product execution. The
initial SQL execution adapter scope is DuckDB and PostgreSQL. This is a
**prerelease, not production ready**. [Validation](VALIDATION.md) records the
accepted initial source; each later release needs its own applicable gates on
every published platform.

## Versions And Targets

Use tags with a leading `v`, such as `v0.0.0` or `v0.1.0-alpha.1`. The tag's
version must match `dxt version` and `.version` in `build.zig.zon`. The current
source version is **0.0.0**; update the native CLI version and package metadata
in the same release-preparation commit before using another version.
Packaging reads the native version automatically; update version-specific
test expectations in that preparation PR as needed.

| Target | Native runner | Archive |
| --- | --- | --- |
| `x86_64-linux-gnu` | `ubuntu-24.04` | `dxt-v<version>-x86_64-linux-gnu.tar.gz` |
| `aarch64-linux-gnu` | `ubuntu-24.04-arm` | `dxt-v<version>-aarch64-linux-gnu.tar.gz` |
| `aarch64-macos` (experimental) | `macos-15` | `dxt-v<version>-aarch64-macos.tar.gz` |
| `x86_64-macos` (experimental) | `macos-15-intel` | `dxt-v<version>-x86_64-macos.tar.gz` |

Each target runs on its actual architecture. Linux binaries use GNU/libc;
macOS binaries bundle their database clients and use only OS system/C++ libraries.
Mac archive gates cover native tests, both live adapters and artifacts, while
complete macOS Core compatibility certification remains pending. They remain
experimental. Windows is excluded until its vendored SQL parser and runtime
build and pass native platform gates. See [Getting started](GETTING_STARTED.md)
for download and source-build requirements.

## Runtime Dependencies

Install DuckDB's native library for DuckDB execution, and libpq for PostgreSQL.
The libraries are external to the existing Linux dxt archive. Native CI pins DuckDB **1.4.2**
and downloads architecture-specific CLI/library archives with SHA-256 checks.
The CLI is used by developer fixtures and the retained autocommit query helper.
Warehouse execution through held sessions requires the native library.

DuckDB discovery can load `libduckdb.so`; `DXT_DUCKDB_LIBRARY` selects a specific
installed file. Set `DXT_DUCKDB_BACKEND=native` to require that driver and fail
clearly when its library is unavailable. PostgreSQL loads `libpq.so.5` by
default; `DXT_POSTGRES_LIBRARY` selects an explicit library. Database/profile
credentials are supplied by the project or environment and never bundled.
Dependency transports use external `git`, `curl` and `tar` when fetching and
extracting packages; install those tools for the corresponding `deps` workflows.

The macOS releases use `-Dbundle-drivers=true` and include the DuckDB static
libraries and the libpq client/LibreSSL TLS implementation. It does not require
external driver libraries at runtime; macOS supplies its system/C++ runtimes.
The PostgreSQL server, profile credentials and trust certificates are provided
by the user. Build inputs are hash-pinned in `build.zig.zon` and remain build-time
dependencies. Bundled distributions must retain the additional notices under
`docs/licenses/native-drivers/` and certify their exact client/TLS/extension
behavior before publication. Mach-O archive checks reject separately installed
runtime libraries and require the bundled driver notices. Mac downloads are
not Developer ID signed or notarized; see the startup instructions for approval.

The YAML parser, PostgreSQL SQL grammar, static Python model syntax frontend,
Unicode tables/names, PCRE2 regular-expression engine, pytz/IANA timezone data,
default SQL macro sources and docs application are embedded in the executable.
The regex engine is statically linked without JIT or an external runtime library.
Python model discovery and compilation preserve resources; model execution in
the initial release is SQL only. End users do not install dbt, MetricFlow, a
Python interpreter or developer requirements to run dxt.

## Workflow Gates

[Release](../.github/workflows/release.yml) triggers when a `v*.*.*` tag is pushed,
when a GitHub Release is published, or by manual dispatch with an existing tag.
After all archive gates succeed, it creates a public release or attaches
downloads to the existing release. Prerelease version suffixes and `v0.0.0`
are marked as prereleases on automatic creation. Manual dispatch defaults to
`dry_run: true`: build and validate without uploading. Reruns update the assets
without creating another release. A moved tag is rejected before publication.

[CI](../.github/workflows/ci.yml) runs the full checks on **pull requests only**;
merging into main does not start another test run. After every required job
passes, `validated-source.json` records the tested source tree, PR head, run ID
and target set. A release must match that tree exactly and come from a merged
PR with successful CI. Squash merges are accepted by tree equality; untested
changes, partial/failed runs, missing or expired records and version mismatches
block release packaging. CI records are retained for 90 days; rerun a matching
PR's CI if its record has expired. Older PRs without a record need a new
validated release-preparation PR.

This reuses all applicable PR checks, including whitespace/formatting, safety,
runtime-boundary, Debug/ReleaseSafe builds, native tests, eight canonical shards
on each actual Linux architecture and their strict evidence audits, public
projects, installation and performance. Release jobs do not repeat the full
Core suite. The compatibility contract pins dbt Core **1.10.5**, dbt-duckdb
**1.9.6**, dbt-postgres **1.9.1**, MetricFlow **0.208.1** and semantic interfaces
**0.9.0**. Those are developer-only oracle dependencies.

Each release package job then:

1. Builds and smoke-tests the native ReleaseSafe target with Zig **0.16.0**.
2. Installs the pinned developer-only artifact and database fixtures.
3. Creates the real archive with `scripts/package_release.py`, generates its
   SHA256 file, and validates contents, ELF64/Mach-O class and target machine,
   executable metadata, notices and public-safe bytes.
4. Verifies that checksum before opening or extracting the archive and checks
   `debug`, `build`, static docs, actual rows and complete artifacts against
   both live adapters with PATH empty.
5. Uploads the exact validated archive for publication. Missing any of the four
   target archives blocks all uploads to the release.

The extracted-installation gate uses `scripts/check_install.py --archive` with
`--checksum-file` and `--require-postgres`; its disposable PostgreSQL service
is a CI fixture. macOS uses `--bundled-drivers --postgres-fixture` with the pinned
developer server; no server is distributed. Both external driver overrides and
library-search overrides are cleared when testing the bundled binary. This
checks the static docs output; browser behavior is
covered by the separate compatibility fixtures. Full
compatibility fixtures use `scripts/postgres_fixture.py` for isolated native
clusters. Linux ARM selects installed PostgreSQL tools through
`DXT_POSTGRES_BIN`, because the pinned `pgserver` wheel is available only on
Linux x86_64. No emulated database or skipped adapter gate replaces these tests.

[CI](../.github/workflows/ci.yml) also configures native tests/safety,
developer integration, canonical CPython **3.12** Core comparisons, public
Jaffle/package projects, performance and actual
Linux x86_64/ARM installation gates, plus both experimental Mac archive gates.
The release source certificate depends on every CI job succeeding.
See [Performance](PERFORMANCE.md) for artifact/compiled-SQL
comparisons and cold/warm budgets.

Python 3.11 CI jobs run developer/native CLI checks; both architectures run the
complete canonical Core compatibility suite under Python 3.12. Mac archive
installation checks do not claim the separate full Core platform certification.

## Archive Contents And Licenses

`scripts/package_release.py` creates sorted tar entries with fixed timestamps,
ownership and modes, and a gzip header with a fixed timestamp. Identical input
binary/docs produce identical archive bytes. Non-Debug builds strip debug
symbols; C build flags map source-directory paths before compilation.

Each archive has one `dxt-v<version>-<target>/` root containing `dxt`, README,
CHANGELOG, SECURITY, the public `docs/` tree and a project LICENSE if present.

Links between bundled documents stay relative for offline use. Links to tracked
files or directories omitted from the archive become GitHub `blob` or `tree`
links pinned to the exact source commit. Packaging defaults to `HEAD`;
`--source-revision <commit>` selects an explicit revision. Referenced omitted
files must exist and match their committed bytes at that revision. Archive
validation rejects unresolved relative links and links escaping the archive.

The separate [curl installer](../scripts/install.sh) fetches a matching archive
and target-specific SHA256 file from the release. It selects the newest
published release (including prereleases) unless `--version` is supplied and
atomically replaces a user-local binary only after checksum and native version
verification. See [installation and usage](GETTING_STARTED.md#install-with-curl).

`docs/licenses/` contains:

- libyaml **0.2.5** MIT license and upstream reference.
- libpg_query **6.2.5** license, PostgreSQL/other third-party notices and
  provenance for its PostgreSQL **17.7** grammar sources.
- Tree-sitter **0.25.10** and tree-sitter-python **0.23.6** MIT licenses and
  checksum provenance, plus the runtime's retained Unicode/ICU notice.
- Unicode **15.0** table license, upstream generation reference and
  named-character data checksum provenance.
- PCRE2 **10.44** BSD license, pinned upstream reference and source checksums.
- pytz **2026.5** MIT license and IANA **2026e** public-domain timezone data
  provenance, including the exact embedded table checksum.
- The embedded dbt docs application's Apache-2.0 license/upstream reference;
  its original third-party notices remain embedded.
- dbt Core/DuckDB/PostgreSQL macro-source licenses and checksum provenance for
  the exact pinned source bundles.

The archive checker requires those notices and rejects unexpected roots,
unsafe paths, links, generated/private files, invalid binaries and uncovered
checksums. Archives exclude credentials, local profiles, caches, logs, virtual
environments, developer scripts, Python dependencies and generated project
artifacts. Upstream dependencies must retain their notices when a release
changes the embedded sources.

The publish job downloads the validated archives, generates
`dxt-v<version>-SHA256SUMS.txt` from their exact bytes, checks every archive and
checksum entry again, and attaches them to the public release, along with the
PR/source validation record and per-target checksum files.

## Local Release Check

Install the pinned developer requirements and native database/browser fixtures
for complete oracle checks. From the repository, run:

```sh
zig build
zig build test
pytest -q
python scripts/check_runtime_boundary.py
python scripts/check_public_safety.py
zig build -Doptimize=ReleaseSafe
python scripts/check_performance.py
python scripts/package_release.py --version 0.0.0 --target x86_64-linux-gnu
(cd dist && sha256sum dxt-v0.0.0-x86_64-linux-gnu.tar.gz > dxt-v0.0.0-x86_64-linux-gnu-SHA256SUMS.txt)
python scripts/check_release_archive.py dist/dxt-v0.0.0-x86_64-linux-gnu.tar.gz --version 0.0.0 --target x86_64-linux-gnu --checksum-file dist/dxt-v0.0.0-x86_64-linux-gnu-SHA256SUMS.txt
python scripts/check_install.py --archive dist/dxt-v0.0.0-x86_64-linux-gnu.tar.gz --checksum-file dist/dxt-v0.0.0-x86_64-linux-gnu-SHA256SUMS.txt --version 0.0.0 --require-postgres
```

Set `DXT_DUCKDB_LIBRARY` to the installed native DuckDB library and
`DXT_INSTALL_POSTGRES_URI` to a disposable PostgreSQL fixture URI before the
installation check. Choose the target matching the host for actual execution;
a cross-compiled binary alone cannot satisfy the other platform's test gates.
Native coverage maps are optional artifacts from the separate Coverage
workflow, rather than a substitute for compatibility or installation checks.

After all candidate gates pass, create and push the matching version tag. To
verify downloaded artifacts, keep the checksum file beside its archives:

```sh
sha256sum -c dxt-v0.0.0-SHA256SUMS.txt
tar -xzf dxt-v0.0.0-x86_64-linux-gnu.tar.gz
./dxt-v0.0.0-x86_64-linux-gnu/dxt version
```

After merging the release-preparation PR with all CI gates green, push the
matching tag or publish that tag through GitHub's release UI. Actions attaches
downloads automatically; no separate binary upload or draft-publishing step is
required. Do not push a tag from uncommitted or untested version changes.
Announce the tested platform/adapter contract and any remaining
compatibility limits; do not infer universal dbt support from the initial
DuckDB/PostgreSQL certification scope.

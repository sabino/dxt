# Release Process

Releases package a native Zig executable, public documentation and upstream
license/provenance notices. Python scripts build and verify release artifacts
in developer/CI environments; they are not part of product execution. The
initial SQL execution adapter scope is DuckDB and PostgreSQL. A tag or successful binary build
alone does not establish full dbt compatibility: the integrated release gates
must pass for each published platform.

## Versions And Targets

Use tags with a leading `v`, such as `v0.0.0` or `v0.1.0-alpha.1`. The tag's
version must match `dxt version` and `.version` in `build.zig.zon`. The current
source version is **0.0.0**; update the native CLI version and package metadata
in the same release-preparation commit before using another version.

| Target | Native runner | Archive |
| --- | --- | --- |
| `x86_64-linux-gnu` | `ubuntu-24.04` | `dxt-v<version>-x86_64-linux-gnu.tar.gz` |
| `aarch64-linux-gnu` | `ubuntu-24.04-arm` | `dxt-v<version>-aarch64-linux-gnu.tar.gz` |

Each target runs on its actual architecture. These are Linux GNU/libc binaries.
macOS, Windows and other database adapters need separate portability and
warehouse certification before publication as supported targets.

## Runtime Dependencies

Install DuckDB's native library for DuckDB execution, and libpq for PostgreSQL.
The libraries are external to the dxt archive. Native CI pins DuckDB **1.4.2**
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

The YAML parser, PostgreSQL SQL grammar, static Python model syntax frontend,
Unicode tables/names, PCRE2 regular-expression engine, pytz/IANA timezone data,
default SQL macro sources and docs application are embedded in the executable.
The regex engine is statically linked without JIT or an external runtime library. Python model
discovery and compilation preserve resources; model execution in the initial
release is SQL only. End users do not install dbt,
MetricFlow, a Python interpreter or developer requirements to run dxt.

## Workflow Gates

[Release](../.github/workflows/release.yml) triggers for `v*.*.*` tags and manual
dispatch with an existing tag. Manual runs default to a dry run that builds and
packages without creating/updating a GitHub Release. Publication creates or
updates a **draft** release only after verification and both package jobs.

The candidate verification job checks whitespace/formatting, repository safety,
the native runtime boundary, Debug/ReleaseSafe builds, native tests, complete
Python/Core fixtures, clean installation, performance budgets and version
consistency. The compatibility contract pins dbt Core **1.10.5**, dbt-duckdb
**1.9.6**, dbt-postgres **1.9.1**, MetricFlow **0.208.1** and semantic interfaces
**0.9.0**. Those are developer-only oracle dependencies.

Each architecture's package job then:

1. Builds and smoke-tests the native ReleaseSafe target with Zig **0.16.0**.
2. Installs the complete pinned compatibility/native fixtures for that runner.
3. Runs native tests and the full compatibility suite on the actual target.
4. Rebuilds ReleaseSafe after integration tests, which may build a Debug binary.
5. Creates the real archive with `scripts/package_release.py`, generates its
   SHA256 file, and validates contents, ELF64 class and target machine,
   executable metadata, notices and public-safe bytes.
6. Verifies that checksum before opening or extracting the archive and checks
   `debug`, `build`, static docs, actual rows and complete artifacts against
   both live adapters with PATH empty.
7. Uploads the exact validated archive for the draft-release job.

The extracted-installation gate uses `scripts/check_install.py --archive` with
`--checksum-file` and `--require-postgres`; its disposable PostgreSQL service
is a CI fixture. This checks the static docs output; browser behavior is
covered by the separate compatibility fixtures. Full
compatibility fixtures use `scripts/postgres_fixture.py` for isolated native
clusters. Linux ARM selects installed PostgreSQL tools through
`DXT_POSTGRES_BIN`, because the pinned `pgserver` wheel is available only on
Linux x86_64. No emulated database or skipped adapter gate replaces these tests.

[CI](../.github/workflows/ci.yml) also configures native tests/safety,
developer integration, canonical CPython **3.12** Core comparisons, public
Jaffle/package projects, performance and actual
Linux x86_64/ARM installation gates. Its full platform compatibility jobs and
the release jobs are configured gates; their results must be checked on the
release candidate. See [Performance](PERFORMANCE.md) for artifact/compiled-SQL
comparisons and cold/warm budgets.

Python 3.11 CI jobs run developer/native CLI checks; both architectures run the
complete canonical Core compatibility suite under Python 3.12. Oracle routing
does not remove that suite from a published platform's acceptance requirements.

## Archive Contents And Licenses

`scripts/package_release.py` creates sorted tar entries with fixed timestamps,
ownership and modes, and a gzip header with a fixed timestamp. Identical input
binary/docs produce identical archive bytes. Non-Debug builds strip debug
symbols; C build flags map source-directory paths before compilation.

Each archive has one `dxt-v<version>-<target>/` root containing `dxt`, README,
CHANGELOG, SECURITY, the public `docs/` tree and a project LICENSE if present.
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
checksum entry again, and attaches them to the draft release.

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

Review draft assets, checksums and candidate gate results before making a
release public. Announce the tested platform/adapter contract and any remaining
compatibility limits; do not infer universal dbt support from the initial
DuckDB/PostgreSQL certification scope.

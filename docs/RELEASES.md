# Release Process

Releases publish native `dxt` binaries from GitHub Actions. The product runtime
remains Zig; release packaging must not introduce Python product behavior.

## Versioning

dxt is pre-alpha. Use semantic-version-like tags with a leading `v`, for
example:

```sh
git tag v0.0.0
git push origin v0.0.0
```

The tag must match both `dxt version` and `.version` in `build.zig.zon`. Today
that means `v0.0.0`; before tagging `v0.1.0` or a suffix such as
`v0.1.0-alpha.1`, bump `src/root.zig` and `build.zig.zon` in the same release
prep commit.

## GitHub Actions Workflow

The release workflow is `.github/workflows/release.yml`.

Triggers:

- `push` tags matching `v*.*.*`
- manual `workflow_dispatch` with an existing tag and dry-run option

Each release job:

1. Checks out the repository.
2. Installs Zig `0.16.0`.
3. Runs `zig fmt --check`, `zig build test`, runtime-boundary checks, and
   public-safety checks.
4. Blocks if the tag version does not match `dxt version` and `build.zig.zon`.
5. Builds `dxt` in `ReleaseSafe` mode for supported targets.
6. Packages each binary with `README.md`, `LICENSE` if present, and release
   notes pointers.
7. Validates release archive contents, expected filenames, executable binary
   metadata, binary/doc string safety, and checksum coverage.
8. Writes `SHA256SUMS.txt`.
9. Uploads artifacts to a draft GitHub Release.

## Initial Targets

| Target | Artifact |
| --- | --- |
| `x86_64-linux-gnu` | `dxt-<version>-x86_64-linux-gnu.tar.gz` |
| `aarch64-linux-gnu` | `dxt-<version>-aarch64-linux-gnu.tar.gz` |

Linux is the only honest initial platform family because current deterministic
file discovery uses Linux syscalls. macOS and Windows packaging are planned
after discovery and CLI path behavior are made portable and validated.

## Safety Rules

- Do not include `target/`, `zig-out/`, caches, logs, `.agent/runs/`,
  `dbt_packages/`, virtualenvs, or local profiles in release archives.
- Run `python scripts/check_public_safety.py` before upload.
- Run `python scripts/check_runtime_boundary.py` before upload.
- Release archives should contain only the binary and public documentation.
- Run `python scripts/check_release_archive.py <archive.tar.gz> --version
  <version>` before upload when validating a local package.
- Checksums must be generated from the exact uploaded archive files.
- Until version injection is implemented, release tags must match both
  `dxt version` and `.version` in `build.zig.zon`.

## Local Dry Run

Before tagging, run:

```sh
zig build
zig build test
zig build -Doptimize=ReleaseSafe
pytest -q tests/test_cli.py::test_name_for_the_changed_behavior
python scripts/check_runtime_boundary.py
python scripts/check_public_safety.py
```

When validating a locally built package, run:

```sh
python scripts/check_release_archive.py dist/dxt-v0.0.0-x86_64-linux-gnu.tar.gz --version 0.0.0 --target x86_64-linux-gnu
```

Use full `pytest -q` locally before broad runner/artifact release changes. The
GitHub CI workflow repeats the native and safety gates, runs the full pytest
matrix with JUnit reports, and runs the public Jaffle parse/build/run/docs gate
with a pinned, checksum-verified DuckDB CLI. Release jobs focus on portable
binary build validation, repository safety, release archive safety, and
checksum coverage. Native Zig test coverage maps are collected by the separate
GitHub `Coverage` workflow on Zig source/build PRs, pushes to `main`, and
manual dispatch, so release prep can inspect coverage artifacts without making
local release validation heavier.

Verify downloaded artifacts with:

```sh
sha256sum -c dxt-v0.0.0-SHA256SUMS.txt
tar -xzf dxt-v0.0.0-x86_64-linux-gnu.tar.gz
./dxt-v0.0.0-x86_64-linux-gnu/dxt version
```

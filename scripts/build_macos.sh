#!/bin/sh
# Build a standalone native dxt using an ignored, checksum-verified toolchain.
set -eu

if [ "$(uname -s)" != Darwin ]; then
    echo "This helper builds the experimental macOS target; use zig build on Linux." >&2
    exit 1
fi

case "$(uname -m)" in
    arm64)
        architecture=aarch64
        zig_sha=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489
        ;;
    x86_64)
        architecture=x86_64
        zig_sha=0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7
        ;;
    *) echo "No pinned Zig toolchain for this Mac architecture." >&2; exit 1 ;;
esac

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tool_root="$project_root/.agent/runs/native-toolchain"
toolchain="$tool_root/zig-$architecture-macos-0.16.0"
archive="$tool_root/zig-$architecture-macos-0.16.0.tar.xz"

if [ ! -x "$toolchain/zig" ]; then
    mkdir -p "$tool_root"
    if [ ! -f "$archive" ]; then
        temporary="$archive.download.$$"
        trap 'rm -f "$temporary"' EXIT HUP INT TERM
        curl --fail --location --silent --show-error --output "$temporary" \
            "https://ziglang.org/download/0.16.0/zig-$architecture-macos-0.16.0.tar.xz"
        mv "$temporary" "$archive"
        trap - EXIT HUP INT TERM
    fi
    printf '%s  %s\n' "$zig_sha" "$archive" | shasum -a 256 --check -
    tar -xf "$archive" -C "$tool_root"
fi

if [ "$("$toolchain/zig" version)" != 0.16.0 ]; then
    echo "The local toolchain must be Zig 0.16.0." >&2
    exit 1
fi

sdk=${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}
if [ ! -f "$sdk/usr/lib/libc++.1.tbd" ]; then
    echo "Install Apple Command Line Tools (xcode-select --install), or set SDKROOT to your Xcode macOS SDK." >&2
    exit 1
fi

cd "$project_root"
"$toolchain/zig" build -Doptimize=ReleaseSafe -Dbundle-drivers=true -Dmacos-sdk="$sdk" "$@"
printf '\nBuilt %s/zig-out/bin/dxt\n' "$project_root"
printf 'DuckDB and the PostgreSQL client/TLS libraries are inside this executable.\n'
printf 'No Homebrew packages, Python interpreter, or separate driver installation is needed to run it.\n'

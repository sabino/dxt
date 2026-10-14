#!/bin/sh
# Install a checksum-verified release. No Python, dbt, Zig or root access needed.
set -eu

install_repository=sabino/dxt
install_version=
install_bin_dir=${HOME:?HOME must be set}/.local/bin
install_tmp=
install_stage=

usage() {
    printf '%s\n' 'Usage: install.sh [--version v0.0.0] [--bin-dir directory]' \
        'Defaults to the newest published release, including prereleases, and ~/.local/bin.'
}
die() {
    printf 'dxt install: %s\n' "$*" >&2
    exit 1
}
cleanup() {
    [ -z "$install_stage" ] || rm -f "$install_stage"
    [ -z "$install_tmp" ] || rm -rf "$install_tmp"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            [ "$#" -ge 2 ] || die '--version requires a release version'
            install_version=$2
            shift 2
            ;;
        --bin-dir)
            [ "$#" -ge 2 ] && [ -n "$2" ] || die '--bin-dir requires a directory'
            install_bin_dir=$2
            shift 2
            ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

case "$install_bin_dir" in
    -*) install_bin_dir=./$install_bin_dir ;;
esac

case "$(uname -s)" in
    Darwin) install_os=macos ;;
    Linux) install_os=linux-gnu ;;
    *) die 'Only macOS and GNU/Linux releases are available; Windows is not supported yet.' ;;
esac
case "$(uname -m)" in
    arm64|aarch64) install_arch=aarch64 ;;
    x86_64|amd64) install_arch=x86_64 ;;
    *) die 'Only 64-bit Intel/AMD and ARM releases are available.' ;;
esac
for install_tool in curl tar mktemp awk sed; do
    command -v "$install_tool" >/dev/null 2>&1 || die "required installation tool missing: $install_tool"
done
if command -v sha256sum >/dev/null 2>&1; then
    install_sha=sha256sum
elif command -v shasum >/dev/null 2>&1; then
    install_sha=shasum
else
    die 'Install sha256sum (Linux coreutils) or shasum (provided by macOS) to verify downloads.'
fi

install_tmp=$(mktemp -d "${TMPDIR:-/tmp}/dxt-install.XXXXXX")
download() {
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --output "$2" "$1" \
        || die 'Download failed. Check the release version, network access and GitHub rate limit.'
}
if [ -z "$install_version" ]; then
    download "https://api.github.com/repos/$install_repository/releases?per_page=1" "$install_tmp/releases.json"
    install_version=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$install_tmp/releases.json" | sed -n '1p')
    [ -n "$install_version" ] || die 'No published releases exist yet. Source builds: https://github.com/sabino/dxt/blob/main/docs/GETTING_STARTED.md'
fi
case "$install_version" in
    v*) ;;
    *) install_version=v$install_version ;;
esac
printf '%s\n' "$install_version" | LC_ALL=C awk '
    NR == 1 && /^[v][0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$/ { valid=1 }
    END { exit !(valid && NR == 1) }
' || die 'Invalid release version; use a tag such as v0.0.0 or v0.1.0-alpha.1.'

install_root=dxt-$install_version-$install_arch-$install_os
install_archive=$install_root.tar.gz
install_url=https://github.com/$install_repository/releases/download/$install_version
download "$install_url/$install_archive" "$install_tmp/$install_archive"
download "$install_url/$install_root-SHA256SUMS.txt" "$install_tmp/SHA256SUMS.txt"
install_expected=$(awk -v name="$install_archive" '
    NR == 1 && NF == 2 && length($1) == 64 && $1 ~ /^[0-9a-f]+$/ && $2 == name { digest=$1 }
    END { if (NR != 1 || digest == "") exit 1; print digest }
' "$install_tmp/SHA256SUMS.txt") || die 'Invalid checksum file for the selected archive.'
if [ "$install_sha" = sha256sum ]; then
    install_actual=$(sha256sum "$install_tmp/$install_archive" | awk '{print $1}')
else
    install_actual=$(shasum -a 256 "$install_tmp/$install_archive" | awk '{print $1}')
fi
[ "$install_actual" = "$install_expected" ] || die 'SHA256 mismatch; archive was not extracted or installed.'

# Extract only the expected binary after verifying the complete archive.
tar -xzf "$install_tmp/$install_archive" -C "$install_tmp" "$install_root/dxt"
install_binary=$install_tmp/$install_root/dxt
[ -f "$install_binary" ] && [ ! -L "$install_binary" ] || die 'Archive does not contain a regular dxt executable.'
mkdir -p "$install_bin_dir"
[ ! -d "$install_bin_dir/dxt" ] || die 'The destination dxt path is a directory; no existing installation was changed.'
install_stage=$(mktemp "$install_bin_dir/.dxt-install.XXXXXX")
cp "$install_binary" "$install_stage"
chmod 755 "$install_stage"
# Check the staged binary on the destination filesystem before replacing an old
# installation. The installer does not need an executable temporary directory.
install_reported=$("$install_stage" version) || die 'Downloaded binary could not run on this machine; the existing installation was preserved.'
[ "$install_reported" = "${install_version#v}" ] || die 'Binary version differs from the release tag; the existing installation was preserved.'
mv -f "$install_stage" "$install_bin_dir/dxt"
install_stage=
printf 'Installed dxt %s to %s/dxt\n' "$install_reported" "$install_bin_dir"
printf 'Add %s to PATH, then run: dxt init demo\n' "$install_bin_dir"
if [ "$install_os" = linux-gnu ]; then
    printf '%s\n' 'Linux SQL driver setup: https://github.com/sabino/dxt/blob/main/docs/GETTING_STARTED.md#linux-release-driver-setup'
fi

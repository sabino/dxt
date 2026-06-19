#!/usr/bin/env sh
set -eu

usage() {
    echo "usage: scripts/worktree_finish.sh [--full]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi

full=0
if [ "${1:-}" = "--full" ]; then
    full=1
elif [ -n "${1:-}" ]; then
    usage
    exit 2
fi

git status --short --branch
git diff --check
git diff --cached --check

zig_files=$(git diff --name-only --diff-filter=ACMR HEAD -- "*.zig" | tr '\n' ' ')
if [ -n "$zig_files" ]; then
    # dxt file paths do not contain shell whitespace.
    zig fmt --check $zig_files
fi

python scripts/check_runtime_boundary.py
python scripts/check_public_safety.py

if [ "$full" -eq 1 ]; then
    zig build
    zig build test
    pytest -q
fi

git diff --stat

#!/usr/bin/env sh
set -eu

usage() {
    echo "usage: scripts/worktree_cleanup.sh [--prune]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi

git worktree list

if [ "${1:-}" = "--prune" ]; then
    git worktree prune
else
    git worktree prune --dry-run
    echo
    echo "dry run only. Use --prune after checking stale worktrees."
    echo "before removing a worktree manually, run: git -C <path> status --short"
fi

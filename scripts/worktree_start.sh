#!/usr/bin/env sh
set -eu

usage() {
    echo "usage: scripts/worktree_start.sh <branch> [base]" >&2
    echo "env: DXT_WORKTREE_ROOT=../dxt-worktrees DXT_WORKTREE_DRY_RUN=1 DXT_ALLOW_DIRTY_WORKTREE=1 DXT_CODEX_PROFILE=<profile>" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi

branch="${1:-}"
base="${2:-origin/main}"

if [ -z "$branch" ]; then
    usage
    exit 2
fi

case "$branch" in
    /*|*..*|*" "*|*"	"*)
        echo "invalid branch name: $branch" >&2
        exit 2
        ;;
esac

if [ "${DXT_ALLOW_DIRTY_WORKTREE:-0}" != "1" ]; then
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "current worktree has uncommitted changes; set DXT_ALLOW_DIRTY_WORKTREE=1 to override" >&2
        exit 1
    fi
fi

worktree_root="${DXT_WORKTREE_ROOT:-../dxt-worktrees}"
worktree_dir="$worktree_root/$branch"
safe_name=$(printf "%s" "$branch" | sed 's#[^A-Za-z0-9._-]#_#g')

if [ "${DXT_WORKTREE_DRY_RUN:-0}" = "1" ]; then
    echo "would fetch origin"
    echo "would create worktree: $worktree_dir"
    echo "would create branch: $branch from $base"
    echo "would write ignored run card: .agent/runs/$safe_name.md"
    exit 0
fi

git fetch origin
mkdir -p "$(dirname "$worktree_dir")"
git worktree add "$worktree_dir" -b "$branch" "$base"

mkdir -p "$worktree_dir/.agent/runs"
{
    echo "# Agent Run"
    echo
    echo "- branch: $branch"
    echo "- base: $base"
    echo "- scope:"
    echo "- expected files:"
    echo "- validation:"
    echo "- stop condition:"
    echo "- handoff:"
} > "$worktree_dir/.agent/runs/$safe_name.md"

echo "created worktree: $worktree_dir"
git -C "$worktree_dir" status --short --branch
echo
echo "next:"
echo "  cd $worktree_dir"
if [ -n "${DXT_CODEX_PROFILE:-}" ]; then
    echo "  codex -p \"$DXT_CODEX_PROFILE\" -m gpt-5.5 -C \"\$PWD\" --ask-for-approval never --sandbox workspace-write exec \"Read AGENTS.md and PLAN.md. Work only on this slice.\""
else
    echo "  codex -m gpt-5.5 -C \"\$PWD\" --ask-for-approval never --sandbox workspace-write exec \"Read AGENTS.md and PLAN.md. Work only on this slice.\""
fi

#!/usr/bin/env bash
# Scaffold Markdown and Cursor rules must not generate trailing whitespace.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"

# git grep reads working-tree contents of tracked files, including hidden
# directories and paths with spaces. Match spaces/tabs before LF or CRLF.
status=0
git grep --line-number --color=never --extended-regexp $'[ \t]+\r?$' -- \
  ':(glob)scaffold/**/*.md' ':(glob)scaffold/**/*.mdc' || status=$?
case "$status" in
  0)
    echo "Scaffold Markdown has trailing spaces or tabs. Use a backslash for intentional Markdown hard breaks." >&2
    exit 1
    ;;
  1) echo "Scaffold Markdown whitespace check passed." ;;
  *)
    echo "Could not check tracked scaffold Markdown (Git exit $status)." >&2
    exit "$status"
    ;;
esac

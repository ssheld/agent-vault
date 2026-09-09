#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
checker="$repo_root/scripts/check-scaffold-markdown-whitespace.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/scaffold-whitespace-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash "$checker"
fixture="$tmp_root/repo"
mkdir -p "$fixture/scripts"
cp "$checker" "$fixture/scripts/"
git -C "$fixture" init -q
paths=(
  'scaffold/agent-vault/Templates/Daily Note.md'
  'scaffold/agent-vault/README.md'
  'scaffold/root/docs/design.md'
  'scaffold/root/.github/pull_request_template.md'
  'scaffold/root/.cursor/rules/agent-vault.mdc'
)
for path in "${paths[@]}"; do
  mkdir -p "$fixture/$(dirname "$path")"
  printf '# Clean scaffold\n\n- Item\n  - Indented item\nHard break\\\nNext line\n' >"$fixture/$path"
done
printf 'Outside scaffold:  \n' >"$fixture/README.md"
git -C "$fixture" add .
printf 'Untracked scaffold fixture: \t\n' >"$fixture/scaffold/untracked.md"
# Running from elsewhere still checks the script's repository. Untracked
# files and project-owned notes outside scaffold are outside this source guard.
bash "$fixture/scripts/check-scaffold-markdown-whitespace.sh" >/dev/null
for path in "${paths[@]}"; do
  cp "$fixture/$path" "$tmp_root/clean.md"
  for whitespace in ' ' '  ' $'\t' $' \t\r'; do
    printf 'Bad line%s\n' "$whitespace" >>"$fixture/$path"
    cp "$fixture/$path" "$tmp_root/before.md"
    status=0
    output="$(bash "$fixture/scripts/check-scaffold-markdown-whitespace.sh" 2>&1)" || status=$?
    [[ "$status" -eq 1 && "$output" == *"$path:"* ]] || fail "guard missed trailing whitespace in $path: $output"
    [[ "$output" == *'Use a backslash'* ]] || fail "guard omitted hard-break guidance"
    cmp -s "$tmp_root/before.md" "$fixture/$path" || fail "guard changed source contents"
    cp "$tmp_root/clean.md" "$fixture/$path"
  done
done
bash "$fixture/scripts/check-scaffold-markdown-whitespace.sh" >/dev/null

# A Git error must not masquerade as a clean scan.
mkdir "$tmp_root/bin"
printf '#!/bin/sh\nexit 128\n' >"$tmp_root/bin/git"
chmod +x "$tmp_root/bin/git"
status=0
output="$(PATH="$tmp_root/bin:$PATH" bash "$fixture/scripts/check-scaffold-markdown-whitespace.sh" 2>&1)" || status=$?
[[ "$status" -eq 128 && "$output" == *'Could not check tracked scaffold Markdown'* ]] || fail "guard swallowed a Git failure"

echo "scaffold Markdown whitespace regression checks passed."

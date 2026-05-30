#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
checker="$repo_root/scripts/check-memory-budget.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-budget-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp_root"
}

trap cleanup EXIT

# expect_result <expected_exit> <must_contain|""> <checker args...>
expect_result() {
  local expected_rc="$1"
  local must_contain="$2"
  shift 2
  local output rc

  set +e
  output="$("$checker" "$@" 2>&1)"
  rc=$?
  set -e

  if [[ "$rc" -ne "$expected_rc" ]]; then
    echo "FAIL: expected exit $expected_rc, got $rc for: $*" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if [[ -n "$must_contain" && "$output" != *"$must_contain"* ]]; then
    echo "FAIL: output missing '$must_contain' for: $*" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

project="$tmp_root/project"
mkdir -p "$project"
git -C "$project" init -q
"$repo_root/scripts/new-project.sh" "budget-test" "$project" >/dev/null

# A fresh project is within budget, and the @-chain is auto-discovered (not a
# hard-coded list): the report must include a transitively-imported file.
expect_result 0 "Within budget" --repo "$project"
expect_result 0 "agent-vault/shared-rules.md" --repo "$project" --format tsv

# Inflate exactly one always-on file past the default per-file budget (40000).
# No other canonical file is that large, so it is the only overage.
head -c 45000 /dev/zero | tr '\0' 'x' >>"$project/agent-vault/project-context.md"

# Non-strict reports + warns but never blocks (exit 0); strict fails.
expect_result 0 "over file budget" --repo "$project"
expect_result 1 "project-context.md" --repo "$project" --strict

# A documented exception clears the strict violation (and prints the reason).
printf 'agent-vault/project-context.md\tdocumented >budget exception; preserves live invariants\n' \
  >"$tmp_root/exceptions.tsv"
expect_result 0 "Within budget" --repo "$project" --strict --exceptions "$tmp_root/exceptions.tsv"
expect_result 0 "documented: documented >budget exception" \
  --repo "$project" --exceptions "$tmp_root/exceptions.tsv"

# Missing optional files are reported, never fatal.
rm -f "$project/agent-vault/open-questions.md"
expect_result 0 "MISSING" --repo "$project"

# A chain-budget overage is a strict violation.
expect_result 1 "@-chain total" --repo "$project" --chain-budget 1000 --strict

# Usage / IO errors.
expect_result 2 "must be text or tsv" --repo "$project" --format bogus
expect_result 2 "repo path not found" --repo "$tmp_root/no-such-dir"

echo "memory budget checker regression checks passed."

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

assert_in_set() {
  local needle="$1"
  shift
  if ! printf '%s\n' "$@" | grep -qxF "$needle"; then
    echo "FAIL: expected '$needle' in set:" >&2
    printf '  %s\n' "$@" >&2
    exit 1
  fi
}

bucket_paths() {
  local bucket="$1"
  "$checker" --repo "$project" --format tsv | awk -F'\t' -v b="$bucket" '$1 == b { print $2 }'
}

project="$tmp_root/project"
mkdir -p "$project"
git -C "$project" init -q
"$repo_root/scripts/new-project.sh" "budget-test" "$project" >/dev/null

# Fresh project is within budget; the @-chain is auto-discovered (not hard-coded).
expect_result 0 "Within budget" --repo "$project"
mapfile -t chain_paths < <(bucket_paths chain)
assert_in_set "agent-vault/shared-rules.md" "${chain_paths[@]}"

# Bucket 3 default must match the session-start contract's protocol-read set,
# including project-context.md / project-commands.md / lessons.md.
mapfile -t protocol_paths < <(bucket_paths protocol)
assert_in_set "agent-vault/project-context.md" "${protocol_paths[@]}"
assert_in_set "agent-vault/project-commands.md" "${protocol_paths[@]}"
assert_in_set "agent-vault/lessons.md" "${protocol_paths[@]}"
while IFS= read -r contract_file; do
  [[ -n "$contract_file" ]] || continue
  assert_in_set "agent-vault/$contract_file" "${protocol_paths[@]}"
done < <(grep -i 'Session-start protocol reads' \
  "$repo_root/docs/session-start-load-contract.md" |
  grep -oE '[A-Za-z0-9_-]+\.md' | sort -u)

# Bucket 2 discovers every AGENTS.md, including nested non-agent-vault ones.
mkdir -p "$project/subpkg"
printf 'nested codex rules\n' >"$project/subpkg/AGENTS.md"
mapfile -t agents_paths < <(bucket_paths agents)
assert_in_set "AGENTS.md" "${agents_paths[@]}"
assert_in_set "agent-vault/AGENTS.md" "${agents_paths[@]}"
assert_in_set "subpkg/AGENTS.md" "${agents_paths[@]}"

# A chain-only overage (no per-file overage) is a strict violation, and a
# documented @chain exception clears it.
expect_result 1 "@-chain total" --repo "$project" --chain-budget 1000 --strict
printf '@chain\tintentional total during a migration\n' >"$tmp_root/exc-chain.tsv"
expect_result 0 "Within budget" --repo "$project" --chain-budget 1000 --strict \
  --exceptions "$tmp_root/exc-chain.tsv"

# Inflate one always-on file past the default per-file budget (40000).
head -c 45000 /dev/zero | tr '\0' 'x' >>"$project/agent-vault/project-context.md"

# Non-strict reports + warns but never blocks (exit 0); strict fails.
expect_result 0 "over file budget" --repo "$project"
expect_result 1 "project-context.md" --repo "$project" --strict

# A per-file exception clears the per-file violation but NOT the chain total
# (the file still loads into context); only an @chain exception clears the chain.
printf 'agent-vault/project-context.md\tdocumented per-file overage\n' >"$tmp_root/exc-file.tsv"
expect_result 0 "Within budget" --repo "$project" --strict --exceptions "$tmp_root/exc-file.tsv"
expect_result 1 "@-chain total" --repo "$project" --chain-budget 1000 --strict \
  --exceptions "$tmp_root/exc-file.tsv"
printf '@chain\tdocumented chain overage\n' >>"$tmp_root/exc-file.tsv"
expect_result 0 "Within budget" --repo "$project" --chain-budget 1000 --strict \
  --exceptions "$tmp_root/exc-file.tsv"

# A committed per-repo config sets budgets; CLI flags override the config.
printf 'file_budget=200000\nchain_budget=200000\n' >"$project/agent-vault/memory-budget.config"
expect_result 0 "Config:" --repo "$project"
expect_result 0 "Within budget" --repo "$project" --strict
expect_result 1 "over file budget" --repo "$project" --file-budget 500 --strict

# A chain_exception in the config (not only @chain in the exceptions file)
# clears a strict @-chain overage.
printf 'file_budget=200000\nchain_budget=1000\nchain_exception=intentional during a migration\n' \
  >"$project/agent-vault/memory-budget.config"
expect_result 0 "Within budget" --repo "$project" --strict

# The documented config shape (full-line comments only) parses cleanly, and
# agents=discover still triggers discovery rather than a literal "discover" path.
printf 'agent-vault/project-context.md\tdocumented per-file overage\n' \
  >"$project/agent-vault/budget.exceptions.tsv"
cat >"$project/agent-vault/memory-budget.config" <<'CFG'
# all keys optional; full-line comments only
file_budget=200000
chain_budget=200000
# protocol_read overrides bucket 3:
protocol_read=agent-vault/context-log.md agent-vault/plan.md
# agents discovery (the default):
agents=discover
# per-file exceptions file:
exceptions=agent-vault/budget.exceptions.tsv
# chain exception note:
chain_exception=intentional total overage during migration X
CFG
expect_result 0 "Within budget" --repo "$project" --strict
mapfile -t cfg_agents < <(bucket_paths agents)
assert_in_set "subpkg/AGENTS.md" "${cfg_agents[@]}"
rm -f "$project/agent-vault/budget.exceptions.tsv"

printf 'bogus_key=1\n' >"$project/agent-vault/memory-budget.config"
expect_result 2 "unknown config key" --repo "$project"
rm -f "$project/agent-vault/memory-budget.config"

# Missing optional files are reported, never fatal.
rm -f "$project/agent-vault/open-questions.md"
expect_result 0 "MISSING" --repo "$project"

# Usage / IO errors.
expect_result 2 "must be text or tsv" --repo "$project" --format bogus
expect_result 2 "repo path not found" --repo "$tmp_root/no-such-dir"

echo "memory budget checker regression checks passed."

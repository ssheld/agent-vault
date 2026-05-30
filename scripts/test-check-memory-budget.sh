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

assert_not_in_set() {
  local needle="$1"
  shift
  if printf '%s\n' "$@" | grep -qxF "$needle"; then
    echo "FAIL: did not expect '$needle' in set" >&2
    exit 1
  fi
}

# tsv_bucket <repo> <bucket>  -> the per-file paths in a bucket
tsv_bucket() {
  "$checker" --repo "$1" --format tsv | awk -F'\t' -v b="$2" '$1 == b { print $2 }'
}
# tsv_total <repo> <bucket>  -> "status<TAB>bytes" of a TOTAL row
tsv_total() {
  "$checker" --repo "$1" --format tsv | awk -F'\t' -v b="$2" '$1 == "TOTAL" && $2 == b { print $3 "\t" $4 }'
}

project="$tmp_root/project"
mkdir -p "$project"
git -C "$project" init -q
"$repo_root/scripts/new-project.sh" "budget-test" "$project" >/dev/null

# Fresh project is within budget (non-strict and strict), and the @-chain is
# auto-discovered (not hard-coded).
expect_result 0 "Within budget" --repo "$project"
expect_result 0 "Within budget" --repo "$project" --strict

# The Claude and Gemini @-chains are reported SEPARATELY (a session loads one).
mapfile -t claude_paths < <(tsv_bucket "$project" claude)
mapfile -t gemini_paths < <(tsv_bucket "$project" gemini)
assert_in_set "CLAUDE.md" "${claude_paths[@]}"
assert_in_set "agent-vault/CLAUDE.md" "${claude_paths[@]}"
assert_in_set "agent-vault/shared-rules.md" "${claude_paths[@]}"
assert_in_set "GEMINI.md" "${gemini_paths[@]}"
assert_in_set "agent-vault/GEMINI.md" "${gemini_paths[@]}"
assert_not_in_set "GEMINI.md" "${claude_paths[@]}"

# tsv shape: a TOTAL row per bucket, AGENTS + protocol are informational.
[[ "$(tsv_total "$project" claude_chain | cut -f1)" == "ok" ]] || {
  echo "FAIL: claude_chain total status" >&2
  exit 1
}
[[ "$(tsv_total "$project" gemini_chain | cut -f1)" == "ok" ]] || {
  echo "FAIL: gemini_chain total status" >&2
  exit 1
}
[[ "$(tsv_total "$project" agents | cut -f1)" == "info" ]] || {
  echo "FAIL: agents total should be informational" >&2
  exit 1
}
[[ "$(tsv_total "$project" protocol | cut -f1)" == "info" ]] || {
  echo "FAIL: protocol total should be informational" >&2
  exit 1
}
# Every data/total row has exactly 5 tab-separated fields.
if "$checker" --repo "$project" --format tsv | awk -F'\t' 'NF != 5 { print; bad=1 } END { exit bad+0 }'; then :; else
  echo "FAIL: a tsv row does not have 5 fields" >&2
  exit 1
fi

# Bucket 3 default matches the session-start contract (with a guard so doc-row
# drift fails loudly rather than skipping the cross-check).
mapfile -t protocol_paths < <(tsv_bucket "$project" protocol)
assert_in_set "agent-vault/project-context.md" "${protocol_paths[@]}"
assert_in_set "agent-vault/lessons.md" "${protocol_paths[@]}"
mapfile -t contract_files < <(grep -i 'Session-start protocol reads' \
  "$repo_root/docs/session-start-load-contract.md" | grep -oE '[A-Za-z0-9_-]+\.md' | sort -u)
[[ "${#contract_files[@]}" -ge 9 ]] || {
  echo "FAIL: contract protocol-read row parsed ${#contract_files[@]} files (<9)" >&2
  exit 1
}
for contract_file in "${contract_files[@]}"; do
  assert_in_set "agent-vault/$contract_file" "${protocol_paths[@]}"
done

# Bucket 2 discovers every AGENTS.md, including nested and non-ASCII paths.
mkdir -p "$project/subpkg" "$project/café"
printf 'nested\n' >"$project/subpkg/AGENTS.md"
printf 'accent\n' >"$project/café/AGENTS.md"
mapfile -t agents_paths < <(tsv_bucket "$project" agents)
assert_in_set "subpkg/AGENTS.md" "${agents_paths[@]}"
assert_in_set "café/AGENTS.md" "${agents_paths[@]}"

# CLI overrides for the bucket-2 and bucket-3 file sets.
mapfile -t pinned_agents < <("$checker" --repo "$project" --format tsv --agents "AGENTS.md" | awk -F'\t' '$1 == "agents" { print $2 }')
assert_in_set "AGENTS.md" "${pinned_agents[@]}"
assert_not_in_set "subpkg/AGENTS.md" "${pinned_agents[@]}"
mapfile -t pinned_proto < <("$checker" --repo "$project" --format tsv --protocol-read "agent-vault/plan.md" | awk -F'\t' '$1 == "protocol" { print $2 }')
assert_in_set "agent-vault/plan.md" "${pinned_proto[@]}"
assert_not_in_set "agent-vault/lessons.md" "${pinned_proto[@]}"

# Inflate one always-on file (a member of both a chain and protocol-read) past
# the default per-file budget (40000 bytes).
head -c 45000 /dev/zero | tr '\0' 'x' >>"$project/agent-vault/project-context.md"
expect_result 0 "over file budget" --repo "$project"
expect_result 1 "project-context.md" --repo "$project" --strict
# Deduplicated: the same over-budget file appears in claude + gemini + protocol
# buckets but counts as ONE violation.
expect_result 1 "1 non-excepted overage" --repo "$project" --strict
# A per-file exception clears it.
printf 'agent-vault/project-context.md\tdocumented per-file overage\n' >"$tmp_root/exc-file.tsv"
expect_result 0 "Within budget" --repo "$project" --strict --exceptions "$tmp_root/exc-file.tsv"

# A chain-only overage (no per-file overage) is a strict violation; an @chain
# exception clears it, but a per-file exception does not.
printf '@chain\tintentional total during a migration\n' >"$tmp_root/exc-chain.tsv"
expect_result 1 "@-chain total" --repo "$project" --chain-budget 1000 --file-budget 200000 --strict
expect_result 0 "Within budget" --repo "$project" --chain-budget 1000 --file-budget 200000 --strict --exceptions "$tmp_root/exc-chain.tsv"
expect_result 1 "@-chain total" --repo "$project" --chain-budget 1000 --file-budget 200000 --strict --exceptions "$tmp_root/exc-file.tsv"

# CRLF exceptions file is tolerated (no-reason @chain line still parses).
printf 'agent-vault/project-context.md\tr\r\n@chain\r\n' >"$tmp_root/exc-crlf.tsv"
expect_result 0 "Within budget" --repo "$project" --chain-budget 1000 --strict --exceptions "$tmp_root/exc-crlf.tsv"

# Committed config: budgets, chain_exception, and the override lists all parse.
printf 'file_budget=200000\nchain_budget=1000\nchain_exception=intentional during a migration\n' \
  >"$project/agent-vault/memory-budget.config"
expect_result 0 "Within budget" --repo "$project" --strict
expect_result 0 "Config:" --repo "$project"
expect_result 1 "over file budget" --repo "$project" --file-budget 500 --strict
printf 'agent-vault/project-context.md\tdoc\n' >"$project/agent-vault/budget.exceptions.tsv"
printf 'file_budget=200000\nexceptions=agent-vault/budget.exceptions.tsv\nprotocol_read=agent-vault/plan.md\nagents=AGENTS.md\n' \
  >"$project/agent-vault/memory-budget.config"
mapfile -t cfg_proto < <(tsv_bucket "$project" protocol)
assert_in_set "agent-vault/plan.md" "${cfg_proto[@]}"
assert_not_in_set "agent-vault/lessons.md" "${cfg_proto[@]}"
mapfile -t cfg_agents < <(tsv_bucket "$project" agents)
assert_not_in_set "subpkg/AGENTS.md" "${cfg_agents[@]}"
printf 'bogus_key=1\n' >"$project/agent-vault/memory-budget.config"
expect_result 2 "unknown config key" --repo "$project"
rm -f "$project/agent-vault/memory-budget.config" "$project/agent-vault/budget.exceptions.tsv"

# The PRIMARY docs config sample runs as-is in a fresh project with nothing
# pre-created (it must not enable a missing exceptions file). Extract it.
sample_project="$tmp_root/sample-project"
mkdir -p "$sample_project"
git -C "$sample_project" init -q
"$repo_root/scripts/new-project.sh" "sample" "$sample_project" >/dev/null
awk '
  /^```/ {
    if (infence) {
      if (grab) exit
      infence = 0
    } else {
      infence = 1
    }
    next
  }
  infence && /agent-vault\/memory-budget\.config/ { grab = 1 }
  infence && grab { print }
' "$repo_root/docs/memory-budgets.md" >"$sample_project/agent-vault/memory-budget.config"
[[ -s "$sample_project/agent-vault/memory-budget.config" ]] ||
  {
    echo "FAIL: could not extract the docs config sample" >&2
    exit 1
  }
# Every uncommentable override line must yield a valid value (no trailing prose
# after the value), so "uncomment as needed" cannot produce broken config.
uncommented="$sample_project/agent-vault/uncommented.config"
sed 's/^# \([a-z_]*=\)/\1/' "$sample_project/agent-vault/memory-budget.config" >"$uncommented"
touch "$sample_project/agent-vault/memory-budget.exceptions.tsv"
set +e
sample_out="$("$checker" --repo "$sample_project" --config "$sample_project/agent-vault/memory-budget.config" --strict 2>&1)"
sample_rc=$?
uncomment_out="$("$checker" --repo "$sample_project" --config "$uncommented" --strict 2>&1)"
uncomment_rc=$?
set -e
[[ "$sample_rc" -eq 0 ]] || {
  echo "FAIL: docs config sample not runnable (exit $sample_rc)" >&2
  printf '%s\n' "$sample_out" >&2
  exit 1
}
[[ "$uncomment_rc" -ne 2 ]] || {
  echo "FAIL: uncommenting a docs override line produced invalid config" >&2
  printf '%s\n' "$uncomment_out" >&2
  exit 1
}

# Missing optional files are reported, never fatal.
rm -f "$project/agent-vault/open-questions.md"
expect_result 0 "MISSING" --repo "$project"

# Non-git directory: AGENTS discovery uses the filesystem-walk fallback.
nongit="$tmp_root/nongit"
mkdir -p "$nongit/sub"
printf '@./agent-vault/CLAUDE.md\n' >"$nongit/CLAUDE.md"
printf 'root\n' >"$nongit/AGENTS.md"
printf 'nested\n' >"$nongit/sub/AGENTS.md"
mapfile -t nongit_agents < <(tsv_bucket "$nongit" agents)
assert_in_set "sub/AGENTS.md" "${nongit_agents[@]}"

# A .gitignore'd AGENTS.md is excluded in a git repo.
printf 'ignored/\n' >"$project/.gitignore"
mkdir -p "$project/ignored"
printf 'hidden\n' >"$project/ignored/AGENTS.md"
mapfile -t git_agents < <(tsv_bucket "$project" agents)
assert_not_in_set "ignored/AGENTS.md" "${git_agents[@]}"

# A cyclic @-import terminates and does not double-count.
cyc="$tmp_root/cyc"
mkdir -p "$cyc"
git -C "$cyc" init -q
printf '@a.md\n' >"$cyc/CLAUDE.md"
printf '@b.md\n' >"$cyc/a.md"
printf '@a.md\n' >"$cyc/b.md"
cyc_a=$("$checker" --repo "$cyc" --format tsv | awk -F'\t' '$1 == "claude" && $2 == "a.md"' | wc -l)
[[ "$cyc_a" -eq 1 ]] || {
  echo "FAIL: cyclic import double-counted a.md ($cyc_a times)" >&2
  exit 1
}

# Sizes are reported in bytes (a multibyte file's byte count, label says bytes).
python3 -c "import sys; sys.stdout.write('é' * 100)" >"$project/agent-vault/lessons.md" 2>/dev/null ||
  printf 'plain\n' >"$project/agent-vault/lessons.md"
expect_result 0 "bytes" --repo "$project"

# Usage / IO errors.
expect_result 2 "must be text or tsv" --repo "$project" --format bogus
expect_result 2 "repo path not found" --repo "$tmp_root/no-such-dir"

echo "memory budget checker regression checks passed."

#!/usr/bin/env bash
# Regression tests for generated-project worktree helper seeding and sync.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/worktree-helper-sync-test.XXXXXX")"
tmp_root="$(cd "$tmp_root" && pwd -P)"

cleanup() {
  rm -rf "$tmp_root"
}

trap cleanup EXIT

passed=0
failed=0

assert_exit_code() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  if [[ "$actual" -eq "$expected" ]]; then
    echo "PASS: $label"
    passed=$((passed + 1))
  else
    echo "FAIL: $label (expected exit $expected, got $actual)" >&2
    failed=$((failed + 1))
  fi
}

assert_output_contains() {
  local output="$1"
  local expected_text="$2"
  local label="$3"

  if [[ "$output" == *"$expected_text"* ]]; then
    echo "PASS: $label"
    passed=$((passed + 1))
  else
    echo "FAIL: $label - expected text not found: $expected_text" >&2
    echo "  Actual output: $output" >&2
    failed=$((failed + 1))
  fi
}

assert_file_contains() {
  local path="$1"
  local expected_text="$2"
  local label="$3"

  if [[ -f "$path" ]] && grep -Fq "$expected_text" "$path"; then
    echo "PASS: $label"
    passed=$((passed + 1))
  else
    echo "FAIL: $label - expected text not found in $path: $expected_text" >&2
    failed=$((failed + 1))
  fi
}

assert_path_exists() {
  local path="$1"
  local label="$2"

  if [[ -e "$path" ]]; then
    echo "PASS: $label"
    passed=$((passed + 1))
  else
    echo "FAIL: $label - missing path: $path" >&2
    failed=$((failed + 1))
  fi
}

assert_executable() {
  local path="$1"
  local label="$2"

  if [[ -x "$path" ]]; then
    echo "PASS: $label"
    passed=$((passed + 1))
  else
    echo "FAIL: $label - not executable: $path" >&2
    failed=$((failed + 1))
  fi
}

setup_empty_repo() {
  local label="$1"
  local repo="$tmp_root/$label"

  mkdir -p "$repo"
  git -C "$repo" init -b main >/dev/null
  git -C "$repo" config user.name "Test User"
  git -C "$repo" config user.email "test@example.com"
  printf '%s\n' "$repo"
}

run_new_project() {
  local target="$1"

  bash "$repo_root/scripts/new-project.sh" "Example App" "$target"
}

run_update_project() {
  local target="$1"
  shift

  bash "$repo_root/scripts/update-project.sh" "$target" "$@"
}

# --- Test 1: new-project seeds executable managed helpers and the runbook ---
target="$(setup_empty_repo new-project-target)"
rc=0
output="$(run_new_project "$target" 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "new-project exits 0"
assert_path_exists "$target/scripts/new-worktree.sh" "new-project creates new-worktree helper"
assert_path_exists "$target/scripts/remove-worktree.sh" "new-project creates remove-worktree helper"
assert_path_exists "$target/docs/runbooks/parallel-agent-worktrees.md" "new-project creates worktree runbook"
assert_executable "$target/scripts/new-worktree.sh" "new-project makes new-worktree executable"
assert_executable "$target/scripts/remove-worktree.sh" "new-project makes remove-worktree executable"
assert_file_contains "$target/scripts/new-worktree.sh" "# agent-vault-managed: helper-script; file=new-worktree.sh" "new-project seeds new-worktree marker"
assert_file_contains "$target/scripts/remove-worktree.sh" "# agent-vault-managed: helper-script; file=remove-worktree.sh" "new-project seeds remove-worktree marker"
assert_file_contains "$target/scripts/new-worktree.sh" 'DEFAULT_ROOT="${PROJECT_DIR}/.worktrees"' "new-project seeds repo-local worktree default"
assert_file_contains "$target/scripts/new-worktree.sh" "AGENT_VAULT_WORKTREE_ROOT" "new-project seeds env worktree override"
assert_file_contains "$target/scripts/remove-worktree.sh" "Use only after verifying the PR is merged" "new-project seeds guarded remove-worktree guidance"
assert_file_contains "$target/docs/runbooks/parallel-agent-worktrees.md" "Cleanup After Merge Or Completion" "new-project seeds cleanup runbook"
assert_path_exists "$target/scripts/check-memory-budget.sh" "new-project creates memory-budget checker"
assert_path_exists "$target/scripts/check-context-log-rollover.sh" "new-project creates rollover checker"
assert_executable "$target/scripts/check-memory-budget.sh" "new-project makes memory-budget checker executable"
assert_executable "$target/scripts/check-context-log-rollover.sh" "new-project makes rollover checker executable"
assert_file_contains "$target/scripts/check-memory-budget.sh" "# agent-vault-managed: helper-script; file=check-memory-budget.sh" "new-project seeds memory-budget checker marker"
assert_file_contains "$target/scripts/check-context-log-rollover.sh" "# agent-vault-managed: helper-script; file=check-context-log-rollover.sh" "new-project seeds rollover checker marker"
assert_path_exists "$target/scripts/compact-context-log.sh" "new-project creates rollover compactor"
assert_executable "$target/scripts/compact-context-log.sh" "new-project makes rollover compactor executable"
assert_file_contains "$target/scripts/compact-context-log.sh" "# agent-vault-managed: helper-script; file=compact-context-log.sh" "new-project seeds rollover compactor marker"
assert_path_exists "$target/scripts/check-lessons-archive.sh" "new-project creates lessons-archive checker"
assert_executable "$target/scripts/check-lessons-archive.sh" "new-project makes lessons-archive checker executable"
assert_file_contains "$target/scripts/check-lessons-archive.sh" "# agent-vault-managed: helper-script; file=check-lessons-archive.sh" "new-project seeds lessons-archive checker marker"

# --- Test 2: update-project creates missing helpers in existing vaults ---
target="$(setup_empty_repo update-missing-target)"
run_new_project "$target" >/dev/null
rm "$target/scripts/new-worktree.sh" "$target/scripts/remove-worktree.sh" \
  "$target/scripts/check-memory-budget.sh" "$target/scripts/check-context-log-rollover.sh" \
  "$target/scripts/compact-context-log.sh" "$target/scripts/check-lessons-archive.sh"
rc=0
output="$(run_update_project "$target" 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "update-project missing-helper exits 0"
assert_output_contains "$output" "Created: scripts/new-worktree.sh" "update-project reports new-worktree creation"
assert_output_contains "$output" "Created: scripts/remove-worktree.sh" "update-project reports remove-worktree creation"
assert_executable "$target/scripts/new-worktree.sh" "update-project makes new-worktree executable"
assert_executable "$target/scripts/remove-worktree.sh" "update-project makes remove-worktree executable"
assert_file_contains "$target/scripts/new-worktree.sh" 'DEFAULT_ROOT="${PROJECT_DIR}/.worktrees"' "update-project creates new helper with repo-local default"
assert_file_contains "$target/scripts/remove-worktree.sh" "Use only after verifying the PR is merged" "update-project creates remove helper with guarded guidance"
assert_output_contains "$output" "Created: scripts/check-memory-budget.sh" "update-project reports memory-budget checker creation"
assert_output_contains "$output" "Created: scripts/check-context-log-rollover.sh" "update-project reports rollover checker creation"
assert_output_contains "$output" "Created: scripts/compact-context-log.sh" "update-project reports rollover compactor creation"
assert_output_contains "$output" "Created: scripts/check-lessons-archive.sh" "update-project reports lessons-archive checker creation"
assert_executable "$target/scripts/check-memory-budget.sh" "update-project restores memory-budget checker executable"
assert_executable "$target/scripts/check-context-log-rollover.sh" "update-project restores rollover checker executable"
assert_executable "$target/scripts/compact-context-log.sh" "update-project restores rollover compactor executable"
assert_executable "$target/scripts/check-lessons-archive.sh" "update-project restores lessons-archive checker executable"

# --- Test 3: update-project skips unmanaged helper scripts by default ---
target="$(setup_empty_repo unmanaged-skip-target)"
run_new_project "$target" >/dev/null
printf '%s\n' '#!/usr/bin/env bash' 'echo custom helper' >"$target/scripts/new-worktree.sh"
chmod +x "$target/scripts/new-worktree.sh"
rc=0
output="$(run_update_project "$target" 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "update-project unmanaged-helper exits 0"
assert_output_contains "$output" "Skip: scripts/new-worktree.sh (unmanaged root helper script; use --migrate-root-scripts to replace)" "update-project reports unmanaged helper skip"
assert_file_contains "$target/scripts/new-worktree.sh" "echo custom helper" "update-project preserves unmanaged helper"

# --- Test 4: --migrate-root-scripts backs up and replaces unmanaged helpers ---
target="$(setup_empty_repo unmanaged-migrate-target)"
run_new_project "$target" >/dev/null
printf '%s\n' '#!/usr/bin/env bash' 'echo custom helper' >"$target/scripts/new-worktree.sh"
chmod +x "$target/scripts/new-worktree.sh"
rc=0
output="$(run_update_project "$target" --migrate-root-scripts 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "update-project migrate-helper exits 0"
assert_output_contains "$output" "Migrating: scripts/new-worktree.sh (unmanaged -> managed helper script)" "update-project reports helper migration"
assert_file_contains "$target/scripts/new-worktree.sh" "# agent-vault-managed: helper-script; file=new-worktree.sh" "update-project replaces unmanaged helper with managed helper"
assert_executable "$target/scripts/new-worktree.sh" "update-project migrated helper executable"
backup_count="$(find "$target/agent-vault/context/updates" -path '*/scripts/new-worktree.sh' -type f | wc -l | tr -d ' ')"
if [[ "$backup_count" -ge 1 ]]; then
  echo "PASS: update-project backs up migrated helper"
  passed=$((passed + 1))
else
  echo "FAIL: update-project backs up migrated helper" >&2
  failed=$((failed + 1))
fi

# --- Test 5: update-project refreshes managed helpers and fixes executable bit ---
target="$(setup_empty_repo managed-refresh-target)"
run_new_project "$target" >/dev/null
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' '# agent-vault-managed: helper-script; file=new-worktree.sh'
  printf '%s\n' 'echo stale managed helper'
} >"$target/scripts/new-worktree.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' '# agent-vault-managed: helper-script; file=remove-worktree.sh'
  printf '%s\n' 'echo stale managed remove helper'
} >"$target/scripts/remove-worktree.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' '# agent-vault-managed: helper-script; file=check-memory-budget.sh'
  printf '%s\n' 'echo stale managed budget checker'
} >"$target/scripts/check-memory-budget.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' '# agent-vault-managed: helper-script; file=check-context-log-rollover.sh'
  printf '%s\n' 'echo stale managed rollover checker'
} >"$target/scripts/check-context-log-rollover.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' '# agent-vault-managed: helper-script; file=compact-context-log.sh'
  printf '%s\n' 'echo stale managed rollover compactor'
} >"$target/scripts/compact-context-log.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' '# agent-vault-managed: helper-script; file=check-lessons-archive.sh'
  printf '%s\n' 'echo stale managed lessons-archive checker'
} >"$target/scripts/check-lessons-archive.sh"
chmod -x "$target/scripts/new-worktree.sh"
chmod -x "$target/scripts/remove-worktree.sh"
chmod -x "$target/scripts/check-memory-budget.sh"
chmod -x "$target/scripts/check-context-log-rollover.sh"
chmod -x "$target/scripts/compact-context-log.sh"
chmod -x "$target/scripts/check-lessons-archive.sh"
rc=0
output="$(run_update_project "$target" 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "update-project managed-refresh exits 0"
assert_output_contains "$output" "Updated: scripts/new-worktree.sh" "update-project reports managed helper update"
assert_output_contains "$output" "Updated: scripts/remove-worktree.sh" "update-project reports managed remove helper update"
assert_output_contains "$output" "Updated: scripts/check-memory-budget.sh" "update-project reports memory-budget checker update"
assert_output_contains "$output" "Updated: scripts/check-context-log-rollover.sh" "update-project reports rollover checker update"
assert_output_contains "$output" "Updated: scripts/compact-context-log.sh" "update-project reports rollover compactor update"
assert_output_contains "$output" "Updated: scripts/check-lessons-archive.sh" "update-project reports lessons-archive checker update"
assert_file_contains "$target/scripts/new-worktree.sh" "Create or reuse one issue-scoped worktree" "update-project refreshes managed helper content"
assert_file_contains "$target/scripts/new-worktree.sh" 'DEFAULT_ROOT="${PROJECT_DIR}/.worktrees"' "update-project refreshes new helper default"
assert_file_contains "$target/scripts/remove-worktree.sh" "Use only after verifying the PR is merged" "update-project refreshes remove helper guidance"
assert_file_contains "$target/scripts/check-memory-budget.sh" "Keys: file_budget, chain_budget" "update-project refreshes stale memory-budget checker content"
assert_file_contains "$target/scripts/check-context-log-rollover.sh" "stale duplicate \"## Current Snapshot\"" "update-project refreshes stale rollover checker content"
assert_file_contains "$target/scripts/compact-context-log.sh" "Keeps the Current Snapshot plus the newest" "update-project refreshes stale rollover compactor content"
assert_file_contains "$target/scripts/check-lessons-archive.sh" "Validates per-lesson classifications" "update-project refreshes stale lessons-archive checker content"
assert_executable "$target/scripts/new-worktree.sh" "update-project fixes managed helper executable bit"
assert_executable "$target/scripts/remove-worktree.sh" "update-project fixes managed remove helper executable bit"
assert_executable "$target/scripts/check-memory-budget.sh" "update-project fixes memory-budget checker executable bit"
assert_executable "$target/scripts/check-context-log-rollover.sh" "update-project fixes rollover checker executable bit"
assert_executable "$target/scripts/compact-context-log.sh" "update-project fixes rollover compactor executable bit"
assert_executable "$target/scripts/check-lessons-archive.sh" "update-project fixes lessons-archive checker executable bit"

# --- Test 6: runbook is seed-only after creation ---
target="$(setup_empty_repo runbook-seed-target)"
run_new_project "$target" >/dev/null
printf '%s\n' '# Local Worktree Runbook' >"$target/docs/runbooks/parallel-agent-worktrees.md"
rc=0
output="$(run_update_project "$target" 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "update-project runbook-seed exits 0"
assert_file_contains "$target/docs/runbooks/parallel-agent-worktrees.md" "# Local Worktree Runbook" "update-project preserves existing runbook"

echo ""
echo "Results: $passed passed, $failed failed"
if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
echo "worktree helper sync regression checks passed."

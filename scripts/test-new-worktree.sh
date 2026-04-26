#!/usr/bin/env bash
# Regression tests for scaffold/root/scripts/new-worktree.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
helper_source="$repo_root/scaffold/root/scripts/new-worktree.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/new-worktree-test.XXXXXX")"
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

assert_path_missing() {
  local path="$1"
  local label="$2"

  if [[ ! -e "$path" ]]; then
    echo "PASS: $label"
    passed=$((passed + 1))
  else
    echo "FAIL: $label - unexpected path still exists: $path" >&2
    failed=$((failed + 1))
  fi
}

assert_path_under_tmp() {
  local path="$1"
  local label="$2"

  case "$(cd "$(dirname "$path")" && pwd -P)/$(basename "$path")/" in
    "$tmp_root/"*)
      echo "PASS: $label"
      passed=$((passed + 1))
      ;;
    *)
      echo "FAIL: $label - path escaped temp root: $path" >&2
      failed=$((failed + 1))
      ;;
  esac
}

setup_repo() {
  local label="$1"
  local origin="$tmp_root/${label}-origin.git"
  local seed="$tmp_root/${label}-seed"
  local working="$tmp_root/${label}-working"

  git init --bare "$origin" >/dev/null
  git -C "$origin" symbolic-ref HEAD refs/heads/main

  git init -b main "$seed" >/dev/null
  git -C "$seed" config user.name "Test User"
  git -C "$seed" config user.email "test@example.com"
  mkdir -p "$seed/scripts"
  cp "$helper_source" "$seed/scripts/new-worktree.sh"
  chmod +x "$seed/scripts/new-worktree.sh"
  echo "seed" >"$seed/README.md"
  git -C "$seed" add README.md scripts/new-worktree.sh
  git -C "$seed" commit -m "seed" >/dev/null
  git -C "$seed" remote add origin "$origin"
  git -C "$seed" push -u origin main >/dev/null

  git clone "$origin" "$working" >/dev/null
  printf '%s\n' "$working"
}

run_new_worktree() {
  local working="$1"
  shift

  bash "$working/scripts/new-worktree.sh" --root "$tmp_root/wt" "$@"
}

run_new_worktree_default() {
  local working="$1"
  shift

  bash "$working/scripts/new-worktree.sh" "$@"
}

run_new_worktree_with_env_root() {
  local working="$1"
  local root="$2"
  shift 2

  AGENT_VAULT_WORKTREE_ROOT="$root" bash "$working/scripts/new-worktree.sh" "$@"
}

# --- Test 1: Default root is repo-local .worktrees and remains idempotent ---
working="$(setup_repo repo-default-root)"
rc=0
output="$(run_new_worktree_default "$working" --agent codex --issue 130 --slug default-root 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "default-root exits 0"
expected_path="$working/.worktrees/codex-130-default-root"
assert_path_exists "$expected_path" "default-root created target path"
assert_path_under_tmp "$expected_path" "default-root stays inside temp root"
assert_output_contains "$output" "cd $expected_path" "default-root prints cd hint"
rc=0
output="$(run_new_worktree_default "$working" --agent codex --issue 130 --slug default-root 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "default-root rerun exits 0"
assert_output_contains "$output" "Worktree already exists:" "default-root rerun reports existing path"
assert_output_contains "$output" "$expected_path" "default-root rerun prints existing path"

# --- Test 2: Environment root is honored and relative paths resolve from repo root ---
working="$(setup_repo repo-env-root)"
rc=0
output="$(run_new_worktree_with_env_root "$working" "env-wt" --agent codex --issue 131 --slug env-root 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "env-root exits 0"
expected_path="$working/env-wt/codex-131-env-root"
assert_path_exists "$expected_path" "env-root created target path"
assert_path_under_tmp "$expected_path" "env-root stays inside temp root"
assert_output_contains "$output" "cd $expected_path" "env-root prints cd hint"

# --- Test 3: --root wins over AGENT_VAULT_WORKTREE_ROOT ---
working="$(setup_repo repo-root-precedence)"
override_root="$tmp_root/root-override"
rc=0
output="$(run_new_worktree_with_env_root "$working" "env-wt" --root "$override_root" --agent codex --issue 132 --slug root-wins 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "root-precedence exits 0"
expected_path="$override_root/codex-132-root-wins"
assert_path_exists "$expected_path" "root-precedence created target path"
assert_path_under_tmp "$expected_path" "root-precedence stays inside temp root"
assert_output_contains "$output" "cd $expected_path" "root-precedence prints cd hint"
assert_path_missing "$working/env-wt/codex-132-root-wins" "root-precedence does not use env root"

# --- Test 4: Invoking from a subdirectory still resolves defaults from repo root ---
working="$(setup_repo repo-subdir-invoke)"
mkdir -p "$working/nested"
rc=0
output="$(cd "$working/nested" && bash ../scripts/new-worktree.sh --agent codex --issue 133 --slug subdir-invoke 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "subdir-invoke exits 0"
expected_path="$working/.worktrees/codex-133-subdir-invoke"
assert_path_exists "$expected_path" "subdir-invoke created target path"
assert_path_under_tmp "$expected_path" "subdir-invoke stays inside temp root"
assert_output_contains "$output" "cd $expected_path" "subdir-invoke prints cd hint"

# --- Test 5: Create a new worktree with explicit slug ---
working="$(setup_repo repo1)"
rc=0
output="$(run_new_worktree "$working" --agent codex --issue 123 --slug feature-slice 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "create-worktree exits 0"
expected_path="$tmp_root/wt/codex-123-feature-slice"
assert_path_exists "$expected_path" "create-worktree created target path"
assert_path_under_tmp "$expected_path" "create-worktree stays inside temp root"
branch_name="$(git -C "$expected_path" branch --show-current)"
if [[ "$branch_name" == "codex/123-feature-slice" ]]; then
  echo "PASS: create-worktree branch name"
  passed=$((passed + 1))
else
  echo "FAIL: create-worktree branch name (got $branch_name)" >&2
  failed=$((failed + 1))
fi
assert_output_contains "$output" "Created worktree:" "create-worktree reports creation"
assert_output_contains "$output" "cd $expected_path" "create-worktree prints cd hint"
assert_output_contains "$output" "codex" "create-worktree prints codex hint"

# --- Test 6: Re-running the same command is idempotent ---
rc=0
output="$(run_new_worktree "$working" --agent codex --issue 123 --slug feature-slice 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "recreate-worktree exits 0"
assert_output_contains "$output" "Worktree already exists:" "recreate-worktree reports existing path"
assert_output_contains "$output" "$expected_path" "recreate-worktree prints existing path"

# --- Test 7: Agent and slug values are normalized ---
working="$(setup_repo repo2)"
rc=0
output="$(run_new_worktree "$working" --agent "Claude Code" --issue 124 --slug "Review Cleanup" 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "normalized-worktree exits 0"
expected_path="$tmp_root/wt/claude-code-124-review-cleanup"
assert_path_exists "$expected_path" "normalized-worktree created normalized path"
assert_path_under_tmp "$expected_path" "normalized-worktree stays inside temp root"
branch_name="$(git -C "$expected_path" branch --show-current)"
if [[ "$branch_name" == "claude-code/124-review-cleanup" ]]; then
  echo "PASS: normalized-worktree branch name"
  passed=$((passed + 1))
else
  echo "FAIL: normalized-worktree branch name (got $branch_name)" >&2
  failed=$((failed + 1))
fi
assert_output_contains "$output" "claude" "normalized-worktree prints claude hint"

# --- Test 8: Gemini launch hint is supported ---
working="$(setup_repo repo3)"
rc=0
output="$(run_new_worktree "$working" --agent gemini --issue 125 --slug docs-followup 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "gemini-worktree exits 0"
assert_output_contains "$output" "gemini" "gemini-worktree prints gemini hint"

# --- Test 9: Stale worktree metadata is pruned and recreated ---
working="$(setup_repo repo4)"
rc=0
output="$(run_new_worktree "$working" --agent codex --issue 126 --slug stale-recreate 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "stale-worktree initial create exits 0"
expected_path="$tmp_root/wt/codex-126-stale-recreate"
assert_path_exists "$expected_path" "stale-worktree initial path exists"
rm -rf "$expected_path"
rc=0
output="$(run_new_worktree "$working" --agent codex --issue 126 --slug stale-recreate 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "stale-worktree recreate exits 0"
assert_output_contains "$output" "Created worktree:" "stale-worktree rerun recreates path"
assert_path_exists "$expected_path" "stale-worktree recreated target path"

# --- Test 10: Missing required args fail clearly ---
working="$(setup_repo repo5)"
rc=0
output="$(run_new_worktree "$working" --agent codex 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "missing-issue exits 1"
assert_output_contains "$output" "--issue is required" "missing-issue shows error"

# --- Test 11: Invalid issue values fail clearly ---
rc=0
output="$(run_new_worktree "$working" --agent codex --issue abc 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "non-numeric-issue exits 1"
assert_output_contains "$output" "--issue must be numeric" "non-numeric-issue shows error"

# --- Test 12: Agent values that normalize to empty fail clearly ---
rc=0
output="$(run_new_worktree "$working" --agent "!!!" --issue 127 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "empty-normalized-agent exits 1"
assert_output_contains "$output" "--agent must contain letters or numbers" "empty-normalized-agent shows error"

# --- Test 13: Bad base refs fail before creating the worktree root ---
working="$(setup_repo repo6)"
bad_base_root="$tmp_root/bad-base-root"
rc=0
output="$(bash "$working/scripts/new-worktree.sh" --root "$bad_base_root" --agent codex --issue 128 --slug bad-base --base does-not-exist 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "bad-base exits 1"
assert_output_contains "$output" "Base ref not found: does-not-exist" "bad-base shows error"
assert_path_missing "$bad_base_root" "bad-base does not create root"

echo ""
echo "Results: $passed passed, $failed failed"
if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
echo "new-worktree.sh regression checks passed."

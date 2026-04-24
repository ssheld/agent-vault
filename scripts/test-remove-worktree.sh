#!/usr/bin/env bash
# Regression tests for scaffold/root/scripts/remove-worktree.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
helper_source="$repo_root/scaffold/root/scripts/remove-worktree.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/remove-worktree-test.XXXXXX")"
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
  cp "$helper_source" "$seed/scripts/remove-worktree.sh"
  chmod +x "$seed/scripts/remove-worktree.sh"
  echo "seed" > "$seed/README.md"
  git -C "$seed" add README.md scripts/remove-worktree.sh
  git -C "$seed" commit -m "seed" >/dev/null
  git -C "$seed" remote add origin "$origin"
  git -C "$seed" push -u origin main >/dev/null

  git clone "$origin" "$working" >/dev/null
  printf '%s\n' "$working"
}

create_worktree() {
  local working="$1"
  local branch_name="$2"
  local worktree_name="$3"
  local worktree_path="$tmp_root/wt/$worktree_name"

  mkdir -p "$(dirname "$worktree_path")"
  git -C "$working" worktree add -b "$branch_name" "$worktree_path" main >/dev/null
  printf '%s\n' "$worktree_path"
}

create_detached_worktree() {
  local working="$1"
  local worktree_name="$2"
  local worktree_path="$tmp_root/wt/$worktree_name"

  mkdir -p "$(dirname "$worktree_path")"
  git -C "$working" worktree add --detach "$worktree_path" main >/dev/null
  printf '%s\n' "$worktree_path"
}

# --- Test 1: Refuse removal when shared .venv still points into the worktree ---
working="$(setup_repo repo1)"
worktree_path="$(create_worktree "$working" "codex/123-feature-slice" "codex-123-feature-slice")"
mkdir -p "$working/.venv/lib/python3.10/site-packages" "$worktree_path/src"
printf '%s\n' "$worktree_path/src" > "$working/.venv/lib/python3.10/site-packages/editable_project.pth"
rc=0
output="$(cd "$working" && bash scripts/remove-worktree.sh --branch codex/123-feature-slice 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "remove-bound-worktree exits 1"
assert_output_contains "$output" "Refusing to remove worktree while the shared .venv editable install points inside it" "remove-bound-worktree shows binding error"
assert_output_contains "$output" "Reinstall the editable package from the main checkout first" "remove-bound-worktree shows generic remediation"
assert_path_exists "$worktree_path" "remove-bound-worktree preserves worktree"

# --- Test 2: Remove a branch-backed worktree from a safe cwd without .venv ---
working="$(setup_repo repo2)"
worktree_path="$(create_worktree "$working" "codex/124-review-cleanup" "codex-124-review-cleanup")"
rc=0
output="$(cd "$working" && bash scripts/remove-worktree.sh --branch codex/124-review-cleanup --delete-branch 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "remove-worktree exits 0"
assert_path_missing "$worktree_path" "remove-worktree deleted target path"
if git -C "$working" show-ref --verify --quiet refs/heads/codex/124-review-cleanup; then
  echo "FAIL: remove-worktree deleted branch" >&2
  failed=$((failed + 1))
else
  echo "PASS: remove-worktree deleted branch"
  passed=$((passed + 1))
fi
assert_output_contains "$output" "Removed worktree:" "remove-worktree reports removal"

# --- Test 3: Refuse to remove the active cwd ---
working="$(setup_repo repo3)"
worktree_path="$(create_worktree "$working" "codex/125-active-cwd" "codex-125-active-cwd")"
rc=0
output="$(cd "$worktree_path" && bash "$working/scripts/remove-worktree.sh" --branch codex/125-active-cwd 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "remove-active-cwd exits 1"
assert_output_contains "$output" "Refusing to remove worktree containing current working directory" "remove-active-cwd shows safety error"
assert_path_exists "$worktree_path" "remove-active-cwd preserves worktree"

# --- Test 4: Refuse to remove the primary checkout ---
working="$(setup_repo repo4)"
rc=0
output="$(cd "$working" && bash scripts/remove-worktree.sh --branch main 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "remove-primary exits 1"
assert_output_contains "$output" "Refusing to remove primary checkout" "remove-primary shows safety error"
assert_path_exists "$working" "remove-primary preserves main checkout"

# --- Test 5: Refuse --delete-branch before removing a detached-HEAD worktree ---
working="$(setup_repo repo5)"
worktree_path="$(create_detached_worktree "$working" "detached-cleanup-check")"
rc=0
output="$(cd "$working" && bash scripts/remove-worktree.sh --path "$worktree_path" --delete-branch 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "remove-detached-delete-branch exits 1"
assert_output_contains "$output" "--delete-branch requires a branch-backed worktree" "remove-detached-delete-branch shows precondition error"
assert_path_exists "$worktree_path" "remove-detached-delete-branch preserves worktree"

# --- Test 6: Remove a detached-HEAD worktree by path without deleting a branch ---
working="$(setup_repo repo6)"
worktree_path="$(create_detached_worktree "$working" "detached-cleanup-success")"
rc=0
output="$(cd "$working" && bash scripts/remove-worktree.sh --path "$worktree_path" 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "remove-detached-by-path exits 0"
assert_output_contains "$output" "Removed worktree:" "remove-detached-by-path reports removal"
assert_path_missing "$worktree_path" "remove-detached-by-path deleted target path"

# --- Test 7: Ignore shared .venv .pth files that point outside the target worktree ---
working="$(setup_repo repo7)"
worktree_path="$(create_worktree "$working" "codex/126-unrelated-venv" "codex-126-unrelated-venv")"
unrelated_path="$tmp_root/unrelated-editable/src"
mkdir -p "$working/.venv/lib/python3.10/site-packages" "$unrelated_path"
printf '%s\n' "$unrelated_path" > "$working/.venv/lib/python3.10/site-packages/editable_project.pth"
rc=0
output="$(cd "$working" && bash scripts/remove-worktree.sh --branch codex/126-unrelated-venv 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "remove-unrelated-venv exits 0"
assert_path_missing "$worktree_path" "remove-unrelated-venv deleted target path"

# --- Test 8: Force removal succeeds for a dirty disposable worktree ---
working="$(setup_repo repo8)"
worktree_path="$(create_worktree "$working" "codex/127-force-dirty" "codex-127-force-dirty")"
echo "dirty" > "$worktree_path/untracked.txt"
rc=0
output="$(cd "$working" && bash scripts/remove-worktree.sh --branch codex/127-force-dirty --force 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "remove-force-dirty exits 0"
assert_output_contains "$output" "Removed worktree:" "remove-force-dirty reports removal"
assert_path_missing "$worktree_path" "remove-force-dirty deleted target path"

# --- Test 9: Refuse when --branch and --path refer to different worktrees ---
working="$(setup_repo repo9)"
worktree_a="$(create_worktree "$working" "codex/128-mismatch-a" "codex-128-mismatch-a")"
worktree_b="$(create_worktree "$working" "codex/128-mismatch-b" "codex-128-mismatch-b")"
rc=0
output="$(cd "$working" && bash scripts/remove-worktree.sh --branch codex/128-mismatch-a --path "$worktree_b" 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "remove-branch-path-mismatch exits 1"
assert_output_contains "$output" "--branch and --path refer to different worktrees" "remove-branch-path-mismatch shows error"
assert_path_exists "$worktree_a" "remove-branch-path-mismatch preserves branch worktree"
assert_path_exists "$worktree_b" "remove-branch-path-mismatch preserves path worktree"

# --- Test 10: Stale branch worktree records are pruned with a clear error ---
working="$(setup_repo repo10)"
worktree_path="$(create_worktree "$working" "codex/129-stale-record" "codex-129-stale-record")"
rm -rf "$worktree_path"
rc=0
output="$(cd "$working" && bash scripts/remove-worktree.sh --branch codex/129-stale-record 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "remove-stale-record exits 1"
assert_output_contains "$output" "Stale metadata was pruned" "remove-stale-record shows prune message"
if git -C "$working" show-ref --verify --quiet refs/heads/codex/129-stale-record; then
  echo "PASS: remove-stale-record preserves branch"
  passed=$((passed + 1))
else
  echo "FAIL: remove-stale-record preserves branch" >&2
  failed=$((failed + 1))
fi

rc=0
output="$(cd "$working" && bash scripts/remove-worktree.sh --branch codex/129-stale-record --delete-branch 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "remove-stale-record-delete-branch exits 0"
assert_output_contains "$output" "No worktree found for branch; deleting local branch only" "remove-stale-record-delete-branch reports branch-only cleanup"
if git -C "$working" show-ref --verify --quiet refs/heads/codex/129-stale-record; then
  echo "FAIL: remove-stale-record-delete-branch deleted branch" >&2
  failed=$((failed + 1))
else
  echo "PASS: remove-stale-record-delete-branch deleted branch"
  passed=$((passed + 1))
fi

# --- Test 11: Bad --path values fail before any safety checks use the cwd ---
working="$(setup_repo repo11)"
missing_path="$tmp_root/wt/missing-worktree"
rc=0
output="$(cd "$working" && bash scripts/remove-worktree.sh --path "$missing_path" 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "remove-missing-path exits 1"
assert_output_contains "$output" "Worktree path does not exist: $missing_path" "remove-missing-path shows error"
assert_path_exists "$working" "remove-missing-path preserves checkout"

echo ""
echo "Results: $passed passed, $failed failed"
if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
echo "remove-worktree.sh regression checks passed."

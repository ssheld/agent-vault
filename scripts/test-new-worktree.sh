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
# shellcheck source=scripts/lib/worktree-test.sh
source "$repo_root/scripts/lib/worktree-test.sh"

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

assert_output_excludes() {
  local output="$1" unexpected="$2" label="$3"
  if [[ "$output" != *"$unexpected"* ]]; then
    echo "PASS: $label"
    passed=$((passed + 1))
  else
    echo "FAIL: $label - unexpected text: $unexpected" >&2
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
  printf '/.worktrees/\n' >"$seed/.gitignore"
  git -C "$seed" add README.md .gitignore scripts/new-worktree.sh
  git -C "$seed" commit -m "seed" >/dev/null
  git -C "$seed" remote add origin "$origin"
  git -C "$seed" push -u origin main >/dev/null

  git clone "$origin" "$working" >/dev/null
  printf '%s\n' "$working"
}

run_new_worktree() {
  local working="$1"
  shift

  "$helper_bash" "$working/scripts/new-worktree.sh" --root "$tmp_root/wt" "$@"
}

run_new_worktree_default() {
  local working="$1"
  shift

  "$helper_bash" "$working/scripts/new-worktree.sh" "$@"
}

run_new_worktree_with_env_root() {
  local working="$1"
  local root="$2"
  shift 2

  AGENT_VAULT_WORKTREE_ROOT="$root" "$helper_bash" "$working/scripts/new-worktree.sh" "$@"
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
assert_output_contains "$output" "  Base: origin/main" "new branch reports default base"
assert_equal "$(git -C "$working" rev-parse origin/main)" "$(git -C "$expected_path" rev-parse HEAD)" "new branch uses default base"
rc=0
output="$(run_new_worktree_default "$working" --agent codex --issue 130 --slug default-root 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "default-root rerun exits 0"
assert_output_contains "$output" "Worktree already exists:" "default-root rerun reports existing path"
assert_output_contains "$output" "$expected_path" "default-root rerun prints existing path"
assert_output_contains "$output" "Reused branch at: $(git -C "$expected_path" rev-parse --short HEAD)" "live reuse reports tip"
assert_output_excludes "$output" "  Base:" "live reuse does not claim a base"

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
output="$(cd "$working/nested" && "$helper_bash" ../scripts/new-worktree.sh --agent codex --issue 133 --slug subdir-invoke 2>&1)" || rc=$?
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

# --- Test 9: Grok launch hint is supported ---
working="$(setup_repo repo-grok)"
rc=0
output="$(run_new_worktree "$working" --agent "Grok Build" --issue 126 --slug grok-build-support 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "grok-worktree exits 0"
expected_path="$tmp_root/wt/grok-build-126-grok-build-support"
assert_path_exists "$expected_path" "grok-worktree created normalized path"
assert_path_under_tmp "$expected_path" "grok-worktree stays inside temp root"
branch_name="$(git -C "$expected_path" branch --show-current)"
if [[ "$branch_name" == "grok-build/126-grok-build-support" ]]; then
  echo "PASS: grok-worktree branch name"
  passed=$((passed + 1))
else
  echo "FAIL: grok-worktree branch name (got $branch_name)" >&2
  failed=$((failed + 1))
fi
assert_output_contains "$output" $'\n  grok' "grok-worktree prints grok launch hint"

# --- Test 10: Lowercase Grok agent creates canonical grok branch and path ---
working="$(setup_repo repo-grok-lowercase)"
rc=0
output="$(run_new_worktree "$working" --agent grok --issue 127 --slug lowercase-grok 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "grok-lowercase exits 0"
expected_path="$tmp_root/wt/grok-127-lowercase-grok"
assert_path_exists "$expected_path" "grok-lowercase created canonical path"
assert_path_under_tmp "$expected_path" "grok-lowercase stays inside temp root"
branch_name="$(git -C "$expected_path" branch --show-current)"
if [[ "$branch_name" == "grok/127-lowercase-grok" ]]; then
  echo "PASS: grok-lowercase branch name"
  passed=$((passed + 1))
else
  echo "FAIL: grok-lowercase branch name (got $branch_name)" >&2
  failed=$((failed + 1))
fi
assert_output_contains "$output" $'\n  grok' "grok-lowercase prints grok launch hint"

# --- Test 11: Stale worktree metadata is pruned and recreated ---
working="$(setup_repo repo4)"
rc=0
output="$(run_new_worktree "$working" --agent codex --issue 126 --slug stale-recreate 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "stale-worktree initial create exits 0"
expected_path="$tmp_root/wt/codex-126-stale-recreate"
assert_path_exists "$expected_path" "stale-worktree initial path exists"
git -C "$expected_path" -c user.name=Test -c user.email=test@example.com commit --allow-empty -m 'branch tip' >/dev/null
stale_tip="$(git -C "$expected_path" rev-parse HEAD)"
stale_short_tip="$(git -C "$expected_path" rev-parse --short HEAD)"
rm -rf "$expected_path"
rc=0
output="$(run_new_worktree "$working" --agent codex --issue 126 --slug stale-recreate --base does-not-exist 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "stale-worktree recreate exits 0"
assert_output_contains "$output" "Created worktree:" "stale-worktree rerun recreates path"
assert_path_exists "$expected_path" "stale-worktree recreated target path"
assert_equal "$stale_tip" "$(git -C "$expected_path" rev-parse HEAD)" "stale reuse preserves divergent tip"
assert_output_contains "$output" "Reused branch at: $stale_short_tip" "stale reuse reports tip"
assert_output_contains "$output" "--base is unused" "stale reuse explains unused invalid base"
assert_output_excludes "$output" "  Base:" "stale reuse does not claim a base"

# --- Test 12: Missing required args fail clearly ---
working="$(setup_repo repo5)"
rc=0
output="$(run_new_worktree "$working" --agent codex 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "missing-issue exits 1"
assert_output_contains "$output" "--issue is required" "missing-issue shows error"

# --- Test 13: Invalid issue values fail clearly ---
rc=0
output="$(run_new_worktree "$working" --agent codex --issue abc 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "non-numeric-issue exits 1"
assert_output_contains "$output" "--issue must be numeric" "non-numeric-issue shows error"

# --- Test 14: Agent values that normalize to empty fail clearly ---
rc=0
output="$(run_new_worktree "$working" --agent "!!!" --issue 127 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "empty-normalized-agent exits 1"
assert_output_contains "$output" "--agent must contain letters or numbers" "empty-normalized-agent shows error"

# --- Test 15: Bad base refs fail before creating the worktree root ---
working="$(setup_repo repo6)"
bad_base_root="$tmp_root/bad-base-root"
snapshot_worktree_state "$working" "$tmp_root/bad-base-before"
rc=0
output="$("$helper_bash" "$working/scripts/new-worktree.sh" --root "$bad_base_root" --agent codex --issue 128 --slug bad-base --base does-not-exist 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "bad-base exits 1"
assert_output_contains "$output" "Base ref not found: does-not-exist" "bad-base shows error"
assert_path_missing "$bad_base_root" "bad-base does not create root"
assert_worktree_state_unchanged "$working" "$tmp_root/bad-base-before" "bad creation base"

# Explicit bases affect new branches, while branch reuse preserves its own tip.
working="$(setup_repo reuse-base)"
git -C "$working" checkout -b codex/143-reuse >/dev/null
git -C "$working" -c user.name=Test -c user.email=test@example.com commit --allow-empty -m 'branch tip' >/dev/null
reuse_tip="$(git -C "$working" rev-parse HEAD)"
reuse_short_tip="$(git -C "$working" rev-parse --short HEAD)"
git -C "$working" checkout main >/dev/null
rc=0
output="$(run_new_worktree_default "$working" --agent codex --issue 143 --slug explicit --base codex/143-reuse 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "explicit-base creates new branch"
assert_output_contains "$output" "  Base: codex/143-reuse" "explicit-base reports actual base"
assert_equal "$reuse_tip" "$(git -C "$working/.worktrees/codex-143-explicit" rev-parse HEAD)" "explicit-base sets new branch tip"
for base in origin/main does-not-exist; do
  rc=0
  output="$(run_new_worktree_default "$working" --agent codex --issue 143 --slug reuse --base "$base" 2>&1)" || rc=$?
  assert_exit_code 0 "$rc" "unattached branch reuse accepts unused $base"
  assert_output_contains "$output" "Reused branch at: $reuse_short_tip" "branch reuse reports preserved tip ($base)"
  assert_output_contains "$output" "--base is unused" "branch reuse explains unused base ($base)"
  assert_output_excludes "$output" "  Base:" "branch reuse does not claim base ($base)"
  assert_equal "$reuse_tip" "$(git -C "$working/.worktrees/codex-143-reuse" rev-parse HEAD)" "branch reuse preserves tip ($base)"
  git -C "$working" worktree remove "$working/.worktrees/codex-143-reuse"
done
run_new_worktree_default "$working" --agent codex --issue 143 --slug reuse >/dev/null
snapshot_worktree_state "$working" "$tmp_root/live-reuse-before"
rc=0
output="$(run_new_worktree_default "$working" --agent codex --issue 143 --slug reuse --base does-not-exist 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "live reuse accepts unused invalid base"
assert_output_contains "$output" "Reused branch at: $reuse_short_tip" "live reuse reports divergent tip"
assert_output_contains "$output" "--base is unused" "live reuse explains unused base"
assert_output_excludes "$output" "  Base:" "live divergent reuse does not claim base"
assert_worktree_state_unchanged "$working" "$tmp_root/live-reuse-before" "live reuse with unused base"
for base_args in missing empty; do
  rc=0
  if [[ "$base_args" == missing ]]; then
    output="$(run_new_worktree_default "$working" --agent codex --issue 143 --slug reuse --base 2>&1)" || rc=$?
    assert_output_contains "$output" "Missing value for --base" "reuse still requires base argument"
  else
    output="$(run_new_worktree_default "$working" --agent codex --issue 143 --slug reuse --base '' 2>&1)" || rc=$?
    assert_output_contains "$output" "--base must not be empty" "reuse rejects empty base argument"
  fi
  assert_exit_code 1 "$rc" "reuse validates $base_args base argument"
done

# Reuse needs no default base even when the primary checkout is detached.
working="$(setup_repo detached-reuse)"
git -C "$working" branch codex/143-detached
git -C "$working" checkout --detach >/dev/null
git -C "$working" branch -D main >/dev/null
git -C "$working" remote remove origin
rc=0
output="$(run_new_worktree_default "$working" --agent codex --issue 143 --slug detached 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "detached primary reuses branch without default base"
assert_output_contains "$output" "Reused branch at:" "detached reuse reports tip"
assert_output_excludes "$output" "  Base:" "detached reuse does not claim base"
snapshot_worktree_state "$working" "$tmp_root/no-default-before"
rc=0
output="$("$helper_bash" "$working/scripts/new-worktree.sh" --root "$tmp_root/no-default-root" --agent codex --issue 144 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "detached primary requires a base for a new branch"
assert_output_contains "$output" "Could not determine a base ref" "missing default base is actionable"
assert_path_missing "$tmp_root/no-default-root" "missing default base creates no root"
assert_worktree_state_unchanged "$working" "$tmp_root/no-default-before" "missing default base"

# --- Linked helper copies must create siblings, not children ---
working="$(setup_repo linked-copy)"
outer="$working/.worktrees/outer"
git -C "$working" worktree add -b codex/outer "$outer" main >/dev/null
rc=0
output="$(run_new_worktree_default "$outer" --agent codex --issue 137 --slug sibling 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "linked-copy creates sibling"
assert_path_exists "$working/.worktrees/codex-137-sibling" "linked-copy resolves primary root"
assert_path_missing "$outer/.worktrees" "linked-copy creates no nested directory"
assert_output_contains "$output" "Primary: $working" "linked-copy identifies primary checkout"

# Linked-copy subdirectories, custom relative roots, CLI precedence, and reuse.
mkdir -p "$outer/subdir"
rc=0
output="$(cd "$outer/subdir" && AGENT_VAULT_WORKTREE_ROOT="$outer/unsafe" "$helper_bash" ../scripts/new-worktree.sh --agent codex --issue 138 --root custom-root 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "linked-subdir creates with CLI root"
assert_path_exists "$working/custom-root/codex-138" "linked-subdir resolves relative root from primary"
assert_path_missing "$outer/unsafe" "linked-subdir CLI overrides unsafe environment root"
assert_equal "$(git -C "$working" rev-parse origin/main)" "$(git -C "$working/custom-root/codex-138" rev-parse HEAD)" "linked-subdir preserves default base"
snapshot_worktree_state "$working" "$tmp_root/reuse"
rc=0
output="$(run_new_worktree_default "$outer" --agent codex --issue 137 --slug sibling 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "linked-copy reuses safe sibling"
assert_worktree_state_unchanged "$working" "$tmp_root/reuse" "safe reuse"

# Reject unsafe CLI/env roots and symlink aliases without creating anything.
ln -s "$outer" "$tmp_root/outer-alias"
for unsafe_root in "$outer/not-created" "$tmp_root/outer-alias/not-created" "$outer/subdir/../not-created"; do
  snapshot_worktree_state "$working" "$tmp_root/unsafe"
  rc=0
  output="$(run_new_worktree_with_env_root "$working" "$unsafe_root" --agent codex --issue 139 2>&1)" || rc=$?
  assert_exit_code 1 "$rc" "unsafe root rejected"
  assert_output_contains "$output" "nested worktree" "unsafe root explains containment"
  assert_path_missing "$outer/not-created" "unsafe root creates no directory"
  assert_worktree_state_unchanged "$working" "$tmp_root/unsafe" "unsafe root"
done
rc=0
output="$(run_new_worktree "$working" --root "$outer/cli-not-created" --agent codex --issue 140 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "unsafe CLI root rejected"
assert_path_missing "$outer/cli-not-created" "unsafe CLI creates no directory"
assert_worktree_state_unchanged "$working" "$tmp_root/unsafe" "unsafe CLI root"

# Legacy nested reuse is independently guarded even though new creation is safe.
inner="$outer/.worktrees/inner"
git -C "$working" worktree add -b codex/141 "$inner" main >/dev/null
printf 'keep these bytes\n' >"$inner/sentinel"
snapshot_worktree_state "$working" "$tmp_root/nested-reuse"
rc=0
output="$(run_new_worktree_default "$working" --agent codex --issue 141 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "legacy nested reuse rejected"
assert_worktree_state_unchanged "$working" "$tmp_root/nested-reuse" "legacy nested reuse"
assert_equal 'keep these bytes' "$(cat "$inner/sentinel")" "legacy reuse preserves inner bytes"

# A new parent cannot wrap an existing registry entry, even if it is missing.
working="$(setup_repo wrap-stale)"
future="$tmp_root/future/codex-142"
git -C "$working" worktree add -b codex/child "$future/child" main >/dev/null
rm -rf "$future"
snapshot_worktree_state "$working" "$tmp_root/wrap-stale"
rc=0
output="$(run_new_worktree "$working" --root "$tmp_root/future" --agent codex --issue 142 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "creation cannot contain a missing registered worktree"
assert_path_missing "$future" "rejected parent creates no directory"
assert_worktree_state_unchanged "$working" "$tmp_root/wrap-stale" "rejected parent"

# NUL parsing and physical path resolution preserve unusual root bytes.
working="$(setup_repo unusual-path)"
mv "$working" "$working"$'\n'
working="$working"$'\n'
unusual_root="$tmp_root/"$'spaces\tand\nnewlines\n'
rc=0
output="$(run_new_worktree "$working" --root "$unusual_root" --agent codex --issue 143 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "unusual paths supported"
assert_path_exists "$unusual_root/codex-143/.git" "unusual root preserved exactly"
rc=0
output="$(run_new_worktree_default "$unusual_root/codex-143" --agent codex --issue 144 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "unusual linked-copy resolves primary"
assert_path_exists "$working/.worktrees/codex-144/.git" "primary trailing newline preserved"

# Existing symlinks must be resolved before '..'; missing suffixes cause no mkdir.
ln -s "$unusual_root" "$tmp_root/root-link"
rc=0
output="$(run_new_worktree "$working" --root "$tmp_root/root-link/../normal-root" --agent codex --issue 145 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "symlink-dotdot root works"
assert_path_exists "$tmp_root/normal-root/codex-145" "symlink-dotdot resolves physically"
ln -s "$tmp_root/does-not-exist" "$tmp_root/dangling-root"
snapshot_worktree_state "$working" "$tmp_root/dangling-root-state"
rc=0
output="$(run_new_worktree "$working" --root "$tmp_root/dangling-root/new" --agent codex --issue 146 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "dangling root rejected"
assert_worktree_state_unchanged "$working" "$tmp_root/dangling-root-state" "dangling root"
assert_path_missing "$tmp_root/does-not-exist" "dangling root creates no destination"

# A bare primary has no supported default root.
working="$(setup_repo bare-primary)"
bare="${working%-working}-origin.git"
git -C "$bare" worktree add -b codex/bare-linked "$tmp_root/bare-linked" main >/dev/null
snapshot_worktree_state "$working" "$tmp_root/bare-state"
rc=0
output="$(run_new_worktree_default "$tmp_root/bare-linked" --agent codex --issue 147 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "bare primary rejected"
assert_output_contains "$output" "non-bare primary checkout" "bare primary has actionable diagnostic"
assert_path_missing "$tmp_root/bare-linked/.worktrees" "bare primary creates no nested root"
assert_worktree_state_unchanged "$working" "$tmp_root/bare-state" "bare primary"

# A separate metadata directory is not a primary checkout. Do not guess a root
# when Git's first registry record cannot be verified as that checkout.
working="$(setup_repo inconsistent-primary)"
git -C "$working" init --separate-git-dir "$tmp_root/creation-metadata" >/dev/null
snapshot_worktree_state "$working" "$tmp_root/inconsistent-creation"
rc=0
output="$(run_new_worktree_default "$working" --agent codex --issue 147 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "inconsistent primary identity rejected"
assert_output_contains "$output" "repair repository/worktree metadata" "inconsistent identity explains repair"
assert_path_missing "$tmp_root/creation-metadata/.worktrees" "inconsistent identity creates no root"
assert_worktree_state_unchanged "$working" "$tmp_root/inconsistent-creation" "inconsistent identity"

# Reusing the primary's branch needs branch guidance, not checkout relocation.
working="$(setup_repo primary-branch-reuse)"
caller="$working/.worktrees/caller"
git -C "$working" worktree add -b codex/caller "$caller" main >/dev/null
git -C "$working" switch -c codex/151 >/dev/null
snapshot_worktree_state "$working" "$tmp_root/primary-reuse"
for source_checkout in "$working" "$caller"; do
  rc=0
  output="$(run_new_worktree_default "$source_checkout" --agent codex --issue 151 2>&1)" || rc=$?
  assert_exit_code 1 "$rc" "primary branch cannot be reused as a linked worktree"
  assert_output_contains "$output" "Branch codex/151 is attached to the primary checkout" "primary reuse identifies the branch"
  assert_output_contains "$output" "choose a different --agent/--issue/--slug" "primary reuse gives branch-specific remediation"
  assert_path_missing "$working/.worktrees/codex-151" "primary reuse creates no linked checkout"
  assert_worktree_state_unchanged "$working" "$tmp_root/primary-reuse" "primary branch reuse"
done

# Pruning one stale branch must not erase any other record's layout evidence.
for mode in missing detached locked prunable; do
  working="$(setup_repo "prune-create-$mode")"
  future_root="$tmp_root/prune-create-$mode-future"
  other="$future_root/codex-153/inner"
  if [[ "$mode" == detached ]]; then
    git -C "$working" worktree add --detach "$other" main >/dev/null
  else
    git -C "$working" worktree add -b codex/other "$other" main >/dev/null
  fi
  printf 'preserve unrelated bytes\n' >"$other/sentinel"
  if [[ "$mode" == locked ]]; then
    git -C "$working" worktree lock "$other"
  fi
  saved="$tmp_root/prune-create-$mode-saved"
  if [[ "$mode" == prunable ]]; then
    # Git may prune an existing directory whose .git file is missing.
    mv "$other/.git" "$saved.git"
    sentinel="$other/sentinel"
  else
    mv "$other" "$saved"
    rmdir "$future_root/codex-153"
    sentinel="$saved/sentinel"
  fi
  stale="$tmp_root/prune-create-$mode-requested"
  git -C "$working" worktree add -b codex/152 "$stale" main >/dev/null
  mv "$stale" "$stale-saved"
  snapshot_worktree_state "$working" "$tmp_root/prune-create-$mode"
  new_root="$tmp_root/prune-create-$mode-new-root"
  rc=0
  output="$(run_new_worktree "$working" --root "$new_root" --agent codex --issue 152 2>&1)" || rc=$?
  assert_exit_code 1 "$rc" "$mode record blocks unrelated creation prune"
  assert_output_contains "$output" "another registered worktree is missing or prunable: $other" "$mode creation prune identifies blocker"
  assert_output_contains "$output" "git worktree prune --dry-run --verbose" "$mode creation prune explains inspection"
  assert_path_missing "$new_root" "$mode creation prune creates no destination"
  assert_worktree_state_unchanged "$working" "$tmp_root/prune-create-$mode" "$mode unrelated creation prune"
  assert_equal 'preserve unrelated bytes' "$(cat "$sentinel")" "$mode creation prune preserves bytes"
  rc=0
  output="$(run_new_worktree "$working" --root "$future_root" --agent codex --issue 153 2>&1)" || rc=$?
  assert_exit_code 1 "$rc" "$mode wrapped worktree remains protected"
  assert_output_contains "$output" "containing registered worktree: $other" "$mode creation wrap evidence survives"
  assert_worktree_state_unchanged "$working" "$tmp_root/prune-create-$mode" "$mode subsequent wrap refusal"
done

# Version preflight handles numeric boundaries and vendor suffixes.
working="$(setup_repo version-guard)"
probe="$tmp_root/git-probe"
install_git_probe "$probe"
for version in 'git version 2.35.9' 'git version 2.9.9' 'git version 1.99.0' 'unrecognized'; do
  snapshot_worktree_state "$working" "$tmp_root/version-guard"
  rc=0
  output="$(PATH="$probe:$PATH" WORKTREE_TEST_GIT_VERSION="$version" run_new_worktree "$working" --root "$tmp_root/version-root" --agent codex --issue 148 2>&1)" || rc=$?
  assert_exit_code 1 "$rc" "unsupported Git rejected"
  assert_output_contains "$output" "Git 2.36+ is required" "unsupported Git explains minimum"
  assert_path_missing "$tmp_root/version-root" "unsupported Git creates no directories"
  assert_worktree_state_unchanged "$working" "$tmp_root/version-guard" "unsupported Git"
done
for version in 'git version 2.36.0' 'git version 2.39.3 (Apple Git-146)' 'git version 3.0.0'; do
  rc=0
  output="$(PATH="$probe:$PATH" WORKTREE_TEST_GIT_VERSION="$version" run_new_worktree "$working" --agent codex --issue 149 2>&1)" || rc=$?
  assert_exit_code 0 "$rc" "supported numeric/vendor Git version accepted"
done
snapshot_worktree_state "$working" "$tmp_root/registry-failure"
rc=0
output="$(PATH="$probe:$PATH" WORKTREE_TEST_FAIL_LIST=1 run_new_worktree "$working" --root "$tmp_root/failure-root" --agent codex --issue 150 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "registry failure rejects creation"
assert_output_contains "$output" "Could not read Git worktree registry" "registry failure is observable"
assert_path_missing "$tmp_root/failure-root" "registry failure creates no directory"
assert_worktree_state_unchanged "$working" "$tmp_root/registry-failure" "registry failure"

snapshot_worktree_state "$working" "$tmp_root/branch-probe-failure"
rc=0
output="$(PATH="$probe:$PATH" WORKTREE_TEST_FAIL_BRANCH_PROBE=1 run_new_worktree "$working" --root "$tmp_root/probe-failure-root" --agent codex --issue 151 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "branch probe failure rejects creation"
assert_output_contains "$output" "Could not inspect branch codex/151 (Git exit 128)" "branch probe error is not treated as an absent branch"
assert_path_missing "$tmp_root/probe-failure-root" "branch probe failure creates no directory"
assert_worktree_state_unchanged "$working" "$tmp_root/branch-probe-failure" "branch probe failure"

echo ""
echo "Results: $passed passed, $failed failed"
if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
echo "new-worktree.sh regression checks passed."

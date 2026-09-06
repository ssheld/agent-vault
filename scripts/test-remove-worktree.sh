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
  echo "seed" >"$seed/README.md"
  printf '/.worktrees/\n' >"$seed/.gitignore"
  git -C "$seed" add README.md .gitignore scripts/remove-worktree.sh
  git -C "$seed" commit -m "seed" >/dev/null
  git -C "$seed" remote add origin "$origin"
  git -C "$seed" push -u origin main >/dev/null

  git clone "$origin" "$working" >/dev/null
  # Clone does not inherit the seed's local identity; descendant fixtures commit.
  git -C "$working" config user.name "Test User"
  git -C "$working" config user.email "test@example.com"
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
printf '%s\n' "$worktree_path/src" >"$working/.venv/lib/python3.10/site-packages/editable_project.pth"
rc=0
output="$(cd "$working" && "$helper_bash" scripts/remove-worktree.sh --branch codex/123-feature-slice 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "remove-bound-worktree exits 1"
assert_output_contains "$output" "Refusing to remove worktree while the shared .venv editable install points inside it" "remove-bound-worktree shows binding error"
assert_output_contains "$output" "Reinstall the editable package from the main checkout first" "remove-bound-worktree shows generic remediation"
assert_path_exists "$worktree_path" "remove-bound-worktree preserves worktree"

# --- Test 2: Remove a branch-backed worktree from a safe cwd without .venv ---
working="$(setup_repo repo2)"
worktree_path="$(create_worktree "$working" "codex/124-review-cleanup" "codex-124-review-cleanup")"
rc=0
output="$(cd "$working" && "$helper_bash" scripts/remove-worktree.sh --branch codex/124-review-cleanup --delete-branch 2>&1)" || rc=$?
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
output="$(cd "$worktree_path" && "$helper_bash" "$working/scripts/remove-worktree.sh" --branch codex/125-active-cwd 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "remove-active-cwd exits 1"
assert_output_contains "$output" "Refusing to remove worktree containing current working directory" "remove-active-cwd shows safety error"
assert_path_exists "$worktree_path" "remove-active-cwd preserves worktree"

# --- Test 4: Refuse to remove the primary checkout ---
working="$(setup_repo repo4)"
rc=0
output="$(cd "$working" && "$helper_bash" scripts/remove-worktree.sh --branch main 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "remove-primary exits 1"
assert_output_contains "$output" "Refusing to remove primary checkout" "remove-primary shows safety error"
assert_path_exists "$working" "remove-primary preserves main checkout"

# --- Test 5: Refuse --delete-branch before removing a detached-HEAD worktree ---
working="$(setup_repo repo5)"
worktree_path="$(create_detached_worktree "$working" "detached-cleanup-check")"
rc=0
output="$(cd "$working" && "$helper_bash" scripts/remove-worktree.sh --path "$worktree_path" --delete-branch 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "remove-detached-delete-branch exits 1"
assert_output_contains "$output" "--delete-branch requires a branch-backed worktree" "remove-detached-delete-branch shows precondition error"
assert_path_exists "$worktree_path" "remove-detached-delete-branch preserves worktree"

# --- Test 6: Remove a detached-HEAD worktree by path without deleting a branch ---
working="$(setup_repo repo6)"
worktree_path="$(create_detached_worktree "$working" "detached-cleanup-success")"
rc=0
output="$(cd "$working" && "$helper_bash" scripts/remove-worktree.sh --path "$worktree_path" 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "remove-detached-by-path exits 0"
assert_output_contains "$output" "Removed worktree:" "remove-detached-by-path reports removal"
assert_path_missing "$worktree_path" "remove-detached-by-path deleted target path"

# --- Test 7: Ignore shared .venv .pth files that point outside the target worktree ---
working="$(setup_repo repo7)"
worktree_path="$(create_worktree "$working" "codex/126-unrelated-venv" "codex-126-unrelated-venv")"
unrelated_path="$tmp_root/unrelated-editable/src"
mkdir -p "$working/.venv/lib/python3.10/site-packages" "$unrelated_path"
printf '%s\n' "$unrelated_path" >"$working/.venv/lib/python3.10/site-packages/editable_project.pth"
rc=0
output="$(cd "$working" && "$helper_bash" scripts/remove-worktree.sh --branch codex/126-unrelated-venv 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "remove-unrelated-venv exits 0"
assert_path_missing "$worktree_path" "remove-unrelated-venv deleted target path"

# --- Test 8: Force removal succeeds for a dirty disposable worktree ---
working="$(setup_repo repo8)"
worktree_path="$(create_worktree "$working" "codex/127-force-dirty" "codex-127-force-dirty")"
echo "dirty" >"$worktree_path/untracked.txt"
rc=0
output="$(cd "$working" && "$helper_bash" scripts/remove-worktree.sh --branch codex/127-force-dirty --force 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "remove-force-dirty exits 0"
assert_output_contains "$output" "Removed worktree:" "remove-force-dirty reports removal"
assert_path_missing "$worktree_path" "remove-force-dirty deleted target path"

# --- Test 9: Refuse when --branch and --path refer to different worktrees ---
working="$(setup_repo repo9)"
worktree_a="$(create_worktree "$working" "codex/128-mismatch-a" "codex-128-mismatch-a")"
worktree_b="$(create_worktree "$working" "codex/128-mismatch-b" "codex-128-mismatch-b")"
rc=0
output="$(cd "$working" && "$helper_bash" scripts/remove-worktree.sh --branch codex/128-mismatch-a --path "$worktree_b" 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "remove-branch-path-mismatch exits 1"
assert_output_contains "$output" "--branch and --path refer to different worktrees" "remove-branch-path-mismatch shows error"
assert_path_exists "$worktree_a" "remove-branch-path-mismatch preserves branch worktree"
assert_path_exists "$worktree_b" "remove-branch-path-mismatch preserves path worktree"

# --- Test 10: Stale branch worktree records are pruned with a clear error ---
working="$(setup_repo repo10)"
worktree_path="$(create_worktree "$working" "codex/129-stale-record" "codex-129-stale-record")"
rm -rf "$worktree_path"
rc=0
output="$(cd "$working" && "$helper_bash" scripts/remove-worktree.sh --branch codex/129-stale-record 2>&1)" || rc=$?
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
output="$(cd "$working" && "$helper_bash" scripts/remove-worktree.sh --branch codex/129-stale-record --delete-branch 2>&1)" || rc=$?
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
output="$(cd "$working" && "$helper_bash" scripts/remove-worktree.sh --path "$missing_path" 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "remove-missing-path exits 1"
assert_output_contains "$output" "Worktree path does not exist: $missing_path" "remove-missing-path shows error"
assert_path_exists "$working" "remove-missing-path preserves checkout"

# --- An ignored dirty descendant must survive ordinary outer cleanup ---
working="$(setup_repo nested-data)"
outer="$working/.worktrees/outer"
inner="$outer/.worktrees/inner"
git -C "$working" worktree add -b codex/outer "$outer" main >/dev/null
git -C "$working" worktree add -b codex/inner "$inner" main >/dev/null
printf 'uncommitted work\n' >"$inner/sentinel"
registry_before="$(git -C "$working" worktree list --porcelain)"
rc=0
output="$("$helper_bash" "$working/scripts/remove-worktree.sh" --branch codex/outer 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "nested-data refuses outer removal"
assert_path_exists "$inner/sentinel" "nested-data preserves uncommitted file"
assert_output_contains "$output" "descendant worktree" "nested-data names structural refusal"
if [[ "$(git -C "$working" worktree list --porcelain)" != "$registry_before" ]]; then
  echo "FAIL: nested-data changed registry" >&2
  failed=$((failed + 1))
fi

# --- main remains protected when it is no longer checked out ---
working="$(setup_repo protected-main)"
git -C "$working" switch -c codex/current >/dev/null
rc=0
output="$("$helper_bash" "$working/scripts/remove-worktree.sh" --branch main --delete-branch 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "protected-main refuses branch-only deletion"
if ! git -C "$working" show-ref --verify --quiet refs/heads/main; then
  echo "FAIL: protected-main deleted main" >&2
  failed=$((failed + 1))
fi
assert_output_contains "$output" "protected branch" "protected-main explains refusal"

# Structural refusal is independent of descendant state, selector, and --force.
for mode in clean dirty locked detached missing; do
  working="$(setup_repo "nested-$mode")"
  outer="$tmp_root/custom $mode/outer"
  inner="$outer/.worktrees/"$'inner\nbranch refs/heads/not-a-field\n'
  git -C "$working" worktree add -b codex/outer "$outer" main >/dev/null
  if [[ "$mode" == detached ]]; then
    git -C "$working" worktree add --detach "$inner" main >/dev/null
  else
    git -C "$working" worktree add -b codex/inner "$inner" main >/dev/null
  fi
  printf 'preserve inner bytes\n' >"$inner/sentinel"
  if [[ "$mode" == clean ]]; then
    git -C "$inner" add sentinel
    git -C "$inner" commit -m "tracked sentinel" >/dev/null
  fi
  if [[ "$mode" == locked ]]; then
    git -C "$working" worktree lock --reason $'keep\nthis work' "$inner"
  fi
  sentinel="$inner/sentinel"
  if [[ "$mode" == missing ]]; then
    mv "$inner" "$tmp_root/moved-inner"
    sentinel="$tmp_root/moved-inner/sentinel"
  fi
  ln -s "$outer" "$tmp_root/$mode-alias"
  snapshot_worktree_state "$working" "$tmp_root/$mode-before"
  for selector in branch path; do
    if [[ "$selector" == branch ]]; then
      target_args=(--branch codex/outer)
    else
      target_args=(--path "$tmp_root/$mode-alias/.")
    fi
    for force in false true; do
      force_args=()
      [[ "$force" == false ]] || force_args=(--force)
      rc=0
      output="$("$helper_bash" "$working/scripts/remove-worktree.sh" "${target_args[@]}" "${force_args[@]}" 2>&1)" || rc=$?
      assert_exit_code 1 "$rc" "$mode descendant refuses $selector force=$force"
      assert_output_contains "$output" "descendant worktree" "$mode descendant diagnostic"
      assert_worktree_state_unchanged "$working" "$tmp_root/$mode-before" "$mode descendant"
      assert_equal 'preserve inner bytes' "$(cat "$sentinel")" "$mode descendant preserves bytes"
      assert_path_exists "$outer/.git" "$mode descendant preserves outer checkout"
      if [[ "$mode" == missing ]]; then
        assert_output_contains "$output" "deleted, moved, or is temporarily unavailable" "missing descendant explains investigation"
        assert_output_contains "$output" "git worktree prune --dry-run --verbose" "missing descendant explains preview"
      fi
    done
  done
done

# An unresolved symlink in a registered path fails before removal or pruning.
working="$(setup_repo unresolved-descendant)"
outer="$(create_worktree "$working" codex/outer unresolved-outer)"
inner="$outer/.worktrees/inner"
git -C "$working" worktree add -b codex/inner "$inner" main >/dev/null
mv "$inner" "$tmp_root/unresolved-saved"
ln -s "$tmp_root/not-mounted" "$inner"
snapshot_worktree_state "$working" "$tmp_root/unresolved-before"
rc=0
output="$("$helper_bash" "$working/scripts/remove-worktree.sh" --branch codex/outer --force 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "unresolvable registry path rejected"
assert_output_contains "$output" "Cannot safely resolve" "unresolvable path diagnostic"
assert_worktree_state_unchanged "$working" "$tmp_root/unresolved-before" "unresolvable path"

# Similar prefixes are siblings; detached removal and custom roots remain valid.
working="$(setup_repo prefix-siblings)"
outer="$(create_worktree "$working" codex/outer prefix-outer)"
sibling="$(create_worktree "$working" codex/sibling prefix-outer-other)"
rc=0
output="$("$helper_bash" "$working/scripts/remove-worktree.sh" --path "$outer" 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "similarly prefixed sibling permits removal"
assert_path_exists "$sibling/.git" "similarly prefixed sibling survives"

# Primary identity and its shared environment must survive linked-copy invocation.
working="$(setup_repo linked-removal)"
target="$(create_worktree "$working" codex/target linked-target)"
caller="$(create_worktree "$working" codex/caller linked-caller)"
mkdir -p "$working/.venv/lib/python3.10/site-packages" "$target/src"
printf '%s\n' "$target/src" >"$working/.venv/lib/python3.10/site-packages/editable.pth"
rc=0
output="$("$helper_bash" "$caller/scripts/remove-worktree.sh" --branch codex/target 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "linked helper checks primary venv"
assert_output_contains "$output" "shared .venv" "linked helper reports primary venv"
assert_path_exists "$target/.git" "linked helper preserves bound target"
rc=0
output="$("$helper_bash" "$caller/scripts/remove-worktree.sh" --path "$working" 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "linked helper protects actual primary"
assert_output_contains "$output" "Refusing to remove primary checkout" "linked helper identifies primary"

# Each protection source is checked in branch-only, live, and direct stale paths.
for kind in main master remote configured; do
  working="$(setup_repo "protect-$kind")"
  case "$kind" in
    main | master) protected="$kind" ;;
    remote) protected="release/stable" ;;
    configured) protected="integration/custom" ;;
  esac
  [[ "$protected" == main ]] || git -C "$working" branch "$protected" main
  git -C "$working" switch -c codex/current >/dev/null
  if [[ "$kind" == remote ]]; then
    git -C "$working" remote add upstream "${working%-working}-origin.git"
    git -C "$working" update-ref refs/remotes/upstream/release/stable HEAD
    git -C "$working" symbolic-ref refs/remotes/upstream/HEAD refs/remotes/upstream/release/stable
  elif [[ "$kind" == configured ]]; then
    git -C "$working" remote remove origin
    git -C "$working" config --local --add agentVault.protectedBranch unrelated
    git -C "$working" config --local --add agentVault.protectedBranch "$protected"
    git -C "$working" checkout --detach >/dev/null
  fi
  for location in branch-only live stale; do
    target="$tmp_root/protected-$kind"
    if [[ "$location" == live ]]; then
      git -C "$working" worktree add "$target" "$protected" >/dev/null
    elif [[ "$location" == stale ]]; then
      mv "$target" "$tmp_root/protected-$kind-saved"
    fi
    snapshot_worktree_state "$working" "$tmp_root/protected-before"
    rc=0
    output="$("$helper_bash" "$working/scripts/remove-worktree.sh" --branch "$protected" --delete-branch --force 2>&1)" || rc=$?
    assert_exit_code 1 "$rc" "$kind protection on $location"
    assert_output_contains "$output" "protected branch" "$kind protection explains refusal"
    assert_output_contains "$output" "owner confirmation" "$kind retirement guidance is self-contained"
    assert_output_contains "$output" "commits are retained before deletion" "$kind refusal explains commit preservation"
    assert_worktree_state_unchanged "$working" "$tmp_root/protected-before" "$kind $location protection"
    if [[ "$location" == live ]]; then
      rc=0
      output="$("$helper_bash" "$working/scripts/remove-worktree.sh" --path "$target" --delete-branch 2>&1)" || rc=$?
      assert_exit_code 1 "$rc" "$kind protection selected by path"
      assert_path_exists "$target/.git" "$kind preflight preserves live worktree"
      assert_worktree_state_unchanged "$working" "$tmp_root/protected-before" "$kind path protection"
    fi
  done
done

# Empty/multiline configuration is invalid, not a list of extra accepted names.
working="$(setup_repo invalid-protection)"
git -C "$working" branch codex/disposable main
for invalid in '' 'invalid branch' $'first\nsecond'; do
  git -C "$working" config --local --replace-all agentVault.protectedBranch "$invalid"
  snapshot_worktree_state "$working" "$tmp_root/invalid-config"
  rc=0
  output="$("$helper_bash" "$working/scripts/remove-worktree.sh" --branch codex/disposable --delete-branch 2>&1)" || rc=$?
  assert_exit_code 1 "$rc" "invalid protected branch configuration rejected"
  assert_output_contains "$output" "Invalid literal branch name" "invalid configuration diagnostic"
  assert_worktree_state_unchanged "$working" "$tmp_root/invalid-config" "invalid configuration"
done

# Ordinary branch-only and direct stale-record deletion remain supported.
working="$(setup_repo ordinary-branch-cleanup)"
git -C "$working" remote remove origin
git -C "$working" branch codex/disposable main
rc=0
output="$("$helper_bash" "$working/scripts/remove-worktree.sh" --branch codex/disposable --delete-branch 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "ordinary branch-only cleanup without remote HEAD"
target="$(create_worktree "$working" codex/stale direct-stale)"
mv "$target" "$tmp_root/direct-stale-saved"
rc=0
output="$("$helper_bash" "$working/scripts/remove-worktree.sh" --branch codex/stale --delete-branch 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "ordinary direct stale-record deletion"
assert_output_contains "$output" "Pruned stale worktree record" "direct stale path exercised"
assert_equal '' "$(git -C "$working" for-each-ref --format='%(refname)' refs/heads/codex/stale)" "direct stale deletes branch"
git -C "$working" switch -c integration/attached >/dev/null
rc=0
output="$("$helper_bash" "$working/scripts/remove-worktree.sh" --branch integration/attached --delete-branch 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "primary attached custom branch protected"
assert_output_contains "$output" "attached to the primary checkout" "primary protection explains reason"

# An unverifiable primary identity must not turn a metadata directory into the
# cleanup authority, even when the linked worktree itself remains accessible.
working="$(setup_repo inconsistent-primary)"
git -C "$working" init --separate-git-dir "$tmp_root/removal-metadata" >/dev/null
target="$(create_worktree "$working" codex/disposable inconsistent-target)"
snapshot_worktree_state "$working" "$tmp_root/inconsistent-removal"
rc=0
output="$("$helper_bash" "$target/scripts/remove-worktree.sh" --branch codex/disposable --delete-branch 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "inconsistent primary rejects cleanup through linked copy"
assert_output_contains "$output" "repair repository/worktree metadata" "cleanup identity error explains repair"
assert_worktree_state_unchanged "$working" "$tmp_root/inconsistent-removal" "inconsistent cleanup identity"
assert_path_exists "$target/.git" "inconsistent identity preserves checkout"

# Preflight failures must not remove, prune, or delete branches.
working="$(setup_repo removal-preflight)"
target="$(create_worktree "$working" codex/disposable preflight-target)"
probe="$tmp_root/git-probe"
install_git_probe "$probe"
snapshot_worktree_state "$working" "$tmp_root/preflight-before"
for version in 'git version 2.35.9' 'git version 2.9.0' 'git version 1.99.0' 'unrecognized'; do
  rc=0
  output="$(PATH="$probe:$PATH" WORKTREE_TEST_GIT_VERSION="$version" "$helper_bash" "$working/scripts/remove-worktree.sh" --branch codex/disposable --delete-branch 2>&1)" || rc=$?
  assert_exit_code 1 "$rc" "unsupported Git rejects removal"
  assert_output_contains "$output" "Git 2.36+ is required" "removal reports Git minimum"
  assert_worktree_state_unchanged "$working" "$tmp_root/preflight-before" "unsupported Git removal"
  assert_path_exists "$target/.git" "unsupported Git preserves checkout"
done
for fault in WORKTREE_TEST_FAIL_LIST WORKTREE_TEST_FAIL_SYMBOLIC; do
  rc=0
  output="$(env PATH="$probe:$PATH" "$fault=1" "$helper_bash" "$working/scripts/remove-worktree.sh" --branch codex/disposable --delete-branch 2>&1)" || rc=$?
  assert_exit_code 1 "$rc" "Git inspection error rejects cleanup"
  assert_worktree_state_unchanged "$working" "$tmp_root/preflight-before" "Git inspection error"
  assert_path_exists "$target/.git" "Git inspection error preserves checkout"
done
rc=0
output="$(PATH="$probe:$PATH" WORKTREE_TEST_GIT_VERSION='git version 2.39.3 (Apple Git-146)' "$helper_bash" "$working/scripts/remove-worktree.sh" --branch codex/disposable --delete-branch 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "vendor-suffixed Git permits safe removal"

echo ""
echo "Results: $passed passed, $failed failed"
if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
echo "remove-worktree.sh regression checks passed."

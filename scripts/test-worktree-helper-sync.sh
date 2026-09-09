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

assert_file_contains() {
  local path="$1"
  local expected_text="$2"
  local label="$3"

  if [[ -f "$path" ]] && grep -Fq -- "$expected_text" "$path"; then
    echo "PASS: $label"
    passed=$((passed + 1))
  else
    echo "FAIL: $label - expected text not found in $path: $expected_text" >&2
    failed=$((failed + 1))
  fi
}

assert_files_equal() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  if cmp -s "$expected" "$actual"; then
    echo "PASS: $label"
    passed=$((passed + 1))
  else
    echo "FAIL: $label - file differs from scaffold: $actual" >&2
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

assert_generated_import_discovery() {
  local target="$1" label="$2" fixture="$tmp_root/generated-imports-$2" output rc=0
  mkdir -p "$fixture"
  printf 'See @large.md for instructions.\n' >"$fixture/CLAUDE.md"
  head -c 45000 /dev/zero | tr '\0' x >"$fixture/large.md"
  output="$("$target/scripts/check-memory-budget.sh" --repo "$fixture" --strict --format tsv 2>&1)" || rc=$?
  assert_exit_code 1 "$rc" "$label installed checker rejects oversized inline import"
  assert_output_contains "$output" $'claude\tlarge.md\tOVER\t45000' "$label installed scanner discovers inline import"
  assert_files_equal "$repo_root/scaffold/root/scripts/check-memory-budget.sh" "$target/scripts/check-memory-budget.sh" "$label installs complete standalone checker"
}

assert_generated_rule_eligibility() {
  local target="$1" label="$2" fixture="$tmp_root/generated-lessons-$2"
  local manifest archive rules output rc needle
  mkdir -p "$fixture/context/archive"
  manifest="$fixture/context/archive/lessons-manifest.md"
  archive="$fixture/context/archive/lessons-archive.md"
  rules="$fixture/lessons.md"
  needle='Preserve literal \n and "quotes" [.*]'
  printf '%s\n' '### covered lesson' '### retained lesson' >"$archive"
  printf '%s\n' '## lesson: covered lesson' '- classification: covered-by-a-named-always-on-rule' \
    "- covered_by: $needle" '## lesson: retained lesson' '- classification: retained-as-quick-rule' \
    "- quick_rule: $needle" >"$manifest"
  printf '%s\n' 'Notes <!--' "$needle" '-->' '> ```md' "> $needle" '> ```' >"$rules"
  rc=0
  output="$("$target/scripts/check-lessons-archive.sh" "$manifest" --strict 2>&1)" || rc=$?
  assert_exit_code 1 "$rc" "$label copied checker rejects inactive-only references"
  assert_output_contains "$output" 'was not found in any live rules source' "$label copied checker reports missing live rules"
  printf '%s\n' "$needle" >>"$rules"
  rc=0
  output="$("$target/scripts/check-lessons-archive.sh" "$manifest" --strict 2>&1)" || rc=$?
  assert_exit_code 0 "$rc" "$label copied checker preserves literal reference data"
  assert_output_contains "$output" '(2 classified)' "$label copied checker resolves both reference types"
}

assert_setext_boundaries() {
  local installed_checker="$1" label="$2" fixture="$tmp_root/setext-$2" output rc
  mkdir -p "$fixture"
  printf '%s\n' '### real lesson' '### another lesson' >"$fixture/archive.md"
  printf '%s\n' '## lesson: real lesson' '- classification: archival-only' '' \
    'Other Section' '---' '- classification: outside' '## lesson: another lesson' \
    '- classification: archival-only' >"$fixture/manifest.md"
  cp "$fixture/manifest.md" "$fixture/before.md"
  rc=0
  output="$(cd "$fixture" && "$installed_checker" manifest.md --archive archive.md --strict 2>&1)" || rc=$?
  assert_exit_code 0 "$rc" "$label accepts setext and resumes at the next record"
  assert_output_contains "$output" '(2 classified)' "$label preserves both records"
  assert_files_equal "$fixture/before.md" "$fixture/manifest.md" "$label checker does not edit the manifest"

  printf '%s\n' '## lesson: real lesson' '- classification: archival-only' '' \
    '> quoted paragraph' '_*_' 'Lazy continuation' '===' '- classification: archival-only' \
    '## lesson: another lesson' '- classification: archival-only' >"$fixture/manifest.md"
  rc=0
  output="$(cd "$fixture" && "$installed_checker" manifest.md --archive archive.md --strict 2>&1)" || rc=$?
  assert_exit_code 1 "$rc" "$label rejects false setext boundaries in quote content"
  assert_output_contains "$output" 'repeats "classification" field' "$label preserves duplicate-field findings"

  printf '%s\n' '## lesson: real lesson' '- classification: archival-only' '  <pre>' '' \
    'Other Section' '---' '  </pre>' '## lesson: another lesson' '- classification: archival-only' >"$fixture/manifest.md"
  rc=0
  output="$(cd "$fixture" && "$installed_checker" manifest.md --archive archive.md --strict 2>&1)" || rc=$?
  assert_exit_code 1 "$rc" "$label reports unsupported indented HTML"
  assert_output_contains "$output" 'unsupported HTML-like content in manifest: manifest.md:3' "$label preserves source line diagnostics"
}

assert_generated_safety() {
  local target="$1" label="$2" outer inner stale helper output rc=0
  # Commit only the synthetic helper fixture; runtime metadata hooks are tested
  # by their own suites and do not apply to this fixture bootstrap commit.
  git -C "$target" add .gitignore scripts/new-worktree.sh scripts/remove-worktree.sh
  git -C "$target" -c core.hooksPath=/dev/null commit -m "helper fixture" >/dev/null
  outer="$target/.worktrees/outer"
  git -C "$target" worktree add -b codex/outer "$outer" main >/dev/null
  output="$("$helper_bash" "$outer/scripts/new-worktree.sh" --agent codex --issue 137 2>&1)" || rc=$?
  assert_exit_code 0 "$rc" "$label linked-copy creation"
  assert_path_exists "$target/.worktrees/codex-137/.git" "$label creates primary sibling"
  assert_output_contains "$output" "Primary: $target" "$label identifies primary"
  git -C "$target" branch codex/143 main
  rc=0
  output="$("$helper_bash" "$target/scripts/new-worktree.sh" --agent codex --issue 143 --base unavailable-base 2>&1)" || rc=$?
  assert_exit_code 0 "$rc" "$label installed helper reuses branch with invalid unused base"
  assert_output_contains "$output" "Reused branch at: $(git -C "$target" rev-parse --short main)" "$label installed helper reports reused tip"
  assert_output_contains "$output" "--base is unused" "$label installed helper explains unused base"
  git -C "$target" worktree remove "$target/.worktrees/codex-143"
  inner="$outer/.worktrees/inner"
  git -C "$target" worktree add -b codex/inner "$inner" main >/dev/null
  printf 'fixture data\n' >"$inner/sentinel"
  snapshot_worktree_state "$target" "$tmp_root/$label"
  rc=0
  output="$("$helper_bash" "$target/scripts/remove-worktree.sh" --branch codex/outer --force 2>&1)" || rc=$?
  assert_exit_code 1 "$rc" "$label refuses nested removal"
  assert_worktree_state_unchanged "$target" "$tmp_root/$label" "$label nested refusal"
  assert_equal 'fixture data' "$(cat "$inner/sentinel")" "$label preserves inner data"
  git -C "$target" switch -c codex/current >/dev/null
  snapshot_worktree_state "$target" "$tmp_root/$label-protected"
  rc=0
  output="$("$helper_bash" "$target/scripts/remove-worktree.sh" --branch main --delete-branch 2>&1)" || rc=$?
  assert_exit_code 1 "$rc" "$label protects unchecked-out main"
  assert_output_contains "$output" "owner confirmation" "$label refusal contains owner requirement"
  assert_output_contains "$output" "commits are retained before deletion" "$label refusal contains preservation requirement"
  assert_worktree_state_unchanged "$target" "$tmp_root/$label-protected" "$label branch refusal"

  # Synced helpers must not erase a missing descendant while recovering an
  # unrelated stale record, even when the project's runbook is absent or old.
  mv "$inner" "$tmp_root/$label-inner-saved"
  stale="$target/.worktrees/stale"
  git -C "$target" worktree add -b codex/138 "$stale" main >/dev/null
  mv "$stale" "$tmp_root/$label-stale-saved"
  snapshot_worktree_state "$target" "$tmp_root/$label-prune"
  for helper in new remove; do
    rc=0
    if [[ "$helper" == new ]]; then
      output="$("$helper_bash" "$target/scripts/new-worktree.sh" --agent codex --issue 138 2>&1)" || rc=$?
    else
      output="$("$helper_bash" "$target/scripts/remove-worktree.sh" --branch codex/138 --delete-branch 2>&1)" || rc=$?
    fi
    assert_exit_code 1 "$rc" "$label $helper refuses unrelated prune"
    assert_output_contains "$output" "another registered worktree is missing or prunable" "$label $helper explains prune refusal"
    assert_output_contains "$output" "git worktree prune --dry-run --verbose" "$label $helper gives self-contained prune guidance"
    assert_worktree_state_unchanged "$target" "$tmp_root/$label-prune" "$label $helper prune refusal"
    assert_equal 'fixture data' "$(cat "$tmp_root/$label-inner-saved/sentinel")" "$label $helper preserves moved data"
  done
}

assert_generated_rollover_recovery() {
  local target="$1" label="$2" fixture rc=0 ignore_rc=0 output actual_mv standalone helper
  target="$(cd "$target" && pwd -P)"
  fixture="$target/rollover-fixture"
  mkdir -p "$fixture/bin" "$fixture/history" "$fixture/metadata"
  cp "$target/agent-vault/context-log.md" "$fixture/project-log-before.md"
  # Exercise only the installed copies from an unrelated directory, with no
  # support library or template files beside them.
  standalone="$fixture/standalone"
  mkdir "$standalone"
  for helper in compact-context-log check-context-log-rollover check-lessons-archive; do
    cp "$target/scripts/$helper.sh" "$standalone/$helper.sh"
  done
  cat >"$fixture/log.md" <<'EOF'
# Context Log

## Usage Rules
- Newest first.

## Current Snapshot
- Branch: main
- Context-log rollover: `manual-history` — boundary: through prior manual entry

## Entries

### 2026-06-01 09:00 local - codex - rollover session
- Keep this newest entry.
````md
```
## Example section inside a longer fence
~~~
````

### 2026-05-31 09:00 local - codex - fix `foo` in **setup**
- Preserve this body exactly once.

## Appendix
- Keep this section live.
EOF
  cat >"$fixture/history/archive.md" <<'EOF'
# Context Log Archive

### 2026-05-01 09:00 local - codex - prior manual entry
- Preserve this manually archived history.
EOF
  actual_mv="$(command -v mv)"
  cat >"$fixture/bin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "${@: -1}" == "$ROLLOVER_FIXTURE_LOG" ]]; then exit 73; fi
exec "$ROLLOVER_FIXTURE_MV" "$@"
EOF
  chmod +x "$fixture/bin/mv"
  output="$(cd "$fixture" && PATH="$fixture/bin:$PATH" ROLLOVER_FIXTURE_LOG="$fixture/log.md" ROLLOVER_FIXTURE_MV="$actual_mv" \
    "$standalone/compact-context-log.sh" "$fixture/log.md" --keep 1 --archive "$fixture/history/archive.md" \
    --manifest "$fixture/metadata/manifest.md" --rollover-id installed-helper --require-top-entry 'rollover session' --adopt-manual-rollover 2>&1)" || rc=$?
  assert_exit_code 3 "$rc" "$label installed helper preserves pending operation"
  assert_output_contains "$output" '--recover' "$label installed recovery guidance"
  git -C "$target" check-ignore -q rollover-fixture/.agent-vault-rollover-log.md/record ||
    ignore_rc=$?
  assert_exit_code 0 "$ignore_rc" "$label installed recovery ignore rule"
  rc=0
  output="$(cd "$fixture" && "$standalone/compact-context-log.sh" "$fixture/log.md" --recover 2>&1)" || rc=$?
  assert_exit_code 0 "$rc" "$label installed recovery succeeds"
  assert_file_contains "$fixture/log.md" installed-helper "$label recovery preserves ID"
  assert_equal 2 "$(grep -c '^### ' "$fixture/history/archive.md")" "$label recovery archives once"
  assert_file_contains "$fixture/history/archive.md" 'Preserve this manually archived history.' "$label adoption preserves manual history"
  assert_file_contains "$fixture/history/archive.md" 'fix `foo` in **setup**' "$label formatted archived topic"
  assert_file_contains "$fixture/log.md" '## Appendix' "$label suffix stays live"
  assert_file_contains "$fixture/metadata/manifest.md" '- archive_path_base: manifest' "$label marked new record"
  assert_file_contains "$fixture/metadata/manifest.md" '- archive_file: ../history/archive.md' "$label final-relative archive path"
  (cd "$fixture" && "$standalone/check-context-log-rollover.sh" "$fixture/log.md" --manifest "$fixture/metadata/manifest.md" --quiet)
  printf '\n~~~md\nHistorical example through EOF.\n' >>"$fixture/history/archive.md"
  rc=0
  output="$(cd "$fixture" && "$standalone/check-context-log-rollover.sh" "$fixture/log.md" --manifest "$fixture/metadata/manifest.md" --quiet 2>&1)" || rc=$?
  assert_exit_code 0 "$rc" "$label historical EOF is advisory"
  assert_output_contains "$output" 'Warning: unterminated fence in archive' "$label installed checker warns under quiet"
  rc=0
  output="$(cd "$fixture" && "$standalone/compact-context-log.sh" "$fixture/log.md" --keep 99 --archive "$fixture/history/archive.md" --manifest "$fixture/metadata/manifest.md" --quiet 2>&1)" || rc=$?
  assert_exit_code 0 "$rc" "$label installed no-op tolerates historical tail"
  assert_output_contains "$output" 'Warning: unterminated fence in archive' "$label installed compactor does not swallow warnings"
  printf '\n~~~md\nUnclosed live suffix.\n' >>"$fixture/log.md"
  rc=0
  output="$(cd "$fixture" && "$standalone/check-context-log-rollover.sh" "$fixture/log.md" --quiet 2>&1)" || rc=$?
  assert_exit_code 1 "$rc" "$label installed checker requires live closure"
  assert_output_contains "$output" '- unterminated fence in live' "$label closure is a finding"
  rc=0
  output="$(cd "$fixture" && "$standalone/compact-context-log.sh" "$fixture/log.md" --keep 99 --archive "$fixture/history/archive.md" --manifest "$fixture/metadata/manifest.md" --dry-run --quiet 2>&1)" || rc=$?
  assert_exit_code 1 "$rc" "$label installed no-op preview requires live closure"
  assert_output_contains "$output" 'unterminated fence in live' "$label installed strict diagnostic"
  cat >"$fixture/lessons-archive.md" <<'EOF'
# Lessons Archive
````md
```
### Quoted lesson
<!-- Not an HTML block inside a fence
````
<!--
~~~ Not a fence inside a comment
### Commented lesson
-->
### Historical lesson
- Historical body.
EOF
  cat >"$fixture/lessons-manifest.md" <<'EOF'
# Lessons Manifest
## lesson: Historical lesson
- classification: archival-only
EOF
  rc=0
  output="$(cd "$fixture" && "$standalone/check-lessons-archive.sh" "$fixture/lessons-manifest.md" --archive "$fixture/lessons-archive.md" --strict 2>&1)" || rc=$?
  assert_exit_code 0 "$rc" "$label standalone lessons parser preserves fence/comment precedence"
  assert_setext_boundaries "$standalone/check-lessons-archive.sh" "$label-standalone"
  assert_files_equal "$fixture/project-log-before.md" "$target/agent-vault/context-log.md" "$label leaves project-owned log unchanged"
}

assert_generated_context_budget() {
  local target="$1" label="$2" fixture output rc=0 i
  fixture="$tmp_root/context-budget-$label"
  mkdir -p "$fixture/agent-vault"
  head -c 50000 /dev/zero | tr '\0' x >"$fixture/agent-vault/context-log.md"
  printf 'context_log_budget=60000\ncontext_log_target=30000\n' >"$fixture/agent-vault/memory-budget.config"
  output="$(cd "$fixture" && "$target/scripts/check-memory-budget.sh" --repo "$fixture" --strict --format tsv 2>&1)" || rc=$?
  assert_exit_code 0 "$rc" "$label installed checker accepts both context keys"
  assert_output_contains "$output" "$(printf 'protocol\tagent-vault/context-log.md\tok\t50000\t')" "$label installed checker applies protocol-only limit"
  printf '@agent-vault/context-log.md\n' >"$fixture/CLAUDE.md"
  rc=0
  output="$("$target/scripts/check-memory-budget.sh" --repo "$fixture" --strict --format tsv 2>&1)" || rc=$?
  assert_exit_code 1 "$rc" "$label installed checker retains imported-log limit"
  assert_output_contains "$output" "$(printf 'claude\tagent-vault/context-log.md\tOVER\t50000\t')" "$label imported log remains over general limit"
  printf '# Context Log\n\n## Usage Rules\n- Newest first.\n\n## Current Snapshot\n- Active: byte fixture\n\n## Entries\n\n' >"$fixture/agent-vault/context-log.md"
  for i in 3 2 1; do
    printf '### 2026-09-06 12:0%s local - codex - byte-entry %s\n' "$i" "$i" >>"$fixture/agent-vault/context-log.md"
    head -c 25000 /dev/zero | tr '\0' x >>"$fixture/agent-vault/context-log.md"
    printf '\n\n' >>"$fixture/agent-vault/context-log.md"
  done
  rc=0
  output="$("$target/scripts/compact-context-log.sh" "$fixture/agent-vault/context-log.md" --to-budget --archive "$fixture/archive.md" --manifest "$fixture/manifest.md" --require-top-entry byte-entry 2>&1)" || rc=$?
  assert_exit_code 0 "$rc" "$label installed compactor supports byte mode"
  assert_output_contains "$output" 'kept 1, archived 2' "$label installed compactor retains complete entries"
  assert_output_contains "$output" 'target=30000' "$label installed compactor shares target config"
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
assert_generated_rollover_recovery "$target" fresh-bootstrap
assert_path_exists "$target/scripts/check-lessons-archive.sh" "new-project creates lessons-archive checker"
assert_executable "$target/scripts/check-lessons-archive.sh" "new-project makes lessons-archive checker executable"
assert_file_contains "$target/scripts/check-lessons-archive.sh" "# agent-vault-managed: helper-script; file=check-lessons-archive.sh" "new-project seeds lessons-archive checker marker"
assert_files_equal "$repo_root/scaffold/root/scripts/check-lessons-archive.sh" "$target/scripts/check-lessons-archive.sh" "new-project seeds complete lessons-archive checker"
assert_generated_rule_eligibility "$target" fresh-bootstrap
assert_setext_boundaries "$target/scripts/check-lessons-archive.sh" fresh-bootstrap
assert_generated_import_discovery "$target" fresh-bootstrap
assert_generated_context_budget "$target" fresh-bootstrap
assert_generated_safety "$target" fresh-bootstrap

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
assert_generated_import_discovery "$target" restored-helper
assert_generated_context_budget "$target" restored-helper
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
printf '%s\n' '#!/usr/bin/env bash' 'echo custom budget checker' >"$target/scripts/check-memory-budget.sh"
rc=0
output="$(run_update_project "$target" 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "update-project unmanaged-helper exits 0"
assert_output_contains "$output" "Skip: scripts/new-worktree.sh (unmanaged root helper script; use --migrate-root-scripts to replace)" "update-project reports unmanaged helper skip"
assert_file_contains "$target/scripts/new-worktree.sh" "echo custom helper" "update-project preserves unmanaged helper"
assert_output_contains "$output" "Skip: scripts/check-memory-budget.sh (unmanaged root helper script; use --migrate-root-scripts to replace)" "update-project reports unmanaged budget checker skip"
assert_file_contains "$target/scripts/check-memory-budget.sh" "echo custom budget checker" "update-project preserves unmanaged budget checker"

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
cp "$target/scripts/check-memory-budget.sh" "$tmp_root/budget-before-dry-run"
# Budget upgrades never rewrite project-owned memory or budget configuration.
printf 'context_log_budget=72000\ncontext_log_target=35000\n# project choice\n' >"$target/agent-vault/memory-budget.config"
printf 'agent-vault/context-log.md\tproject exception\n' >"$target/agent-vault/memory-budget.exceptions.tsv"
for name in context-log.md memory-budget.config memory-budget.exceptions.tsv; do
  cp "$target/agent-vault/$name" "$tmp_root/budget-preserve-$name"
done
rc=0
output="$(run_update_project "$target" --dry-run 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "update-project managed budget checker dry-run exits 0"
assert_files_equal "$tmp_root/budget-before-dry-run" "$target/scripts/check-memory-budget.sh" "dry-run preserves managed budget checker contents"
for name in context-log.md memory-budget.config memory-budget.exceptions.tsv; do
  assert_files_equal "$tmp_root/budget-preserve-$name" "$target/agent-vault/$name" "dry-run preserves project-owned $name"
done
if [[ ! -x "$target/scripts/check-memory-budget.sh" ]]; then
  passed=$((passed + 1))
else
  echo "FAIL: dry-run changed budget checker executable bit" >&2
  failed=$((failed + 1))
fi
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
assert_files_equal "$repo_root/scaffold/root/scripts/check-lessons-archive.sh" "$target/scripts/check-lessons-archive.sh" "update-project refreshes complete lessons-archive checker"
assert_generated_rule_eligibility "$target" managed-update
assert_setext_boundaries "$target/scripts/check-lessons-archive.sh" managed-update
assert_generated_import_discovery "$target" managed-update
assert_generated_context_budget "$target" managed-update
for name in context-log.md memory-budget.config memory-budget.exceptions.tsv; do
  assert_files_equal "$tmp_root/budget-preserve-$name" "$target/agent-vault/$name" "refresh preserves project-owned $name"
done
assert_executable "$target/scripts/new-worktree.sh" "update-project fixes managed helper executable bit"
assert_executable "$target/scripts/remove-worktree.sh" "update-project fixes managed remove helper executable bit"
assert_executable "$target/scripts/check-memory-budget.sh" "update-project fixes memory-budget checker executable bit"
assert_executable "$target/scripts/check-context-log-rollover.sh" "update-project fixes rollover checker executable bit"
assert_executable "$target/scripts/compact-context-log.sh" "update-project fixes rollover compactor executable bit"
assert_generated_rollover_recovery "$target" managed-update
assert_executable "$target/scripts/check-lessons-archive.sh" "update-project fixes lessons-archive checker executable bit"
assert_generated_safety "$target" managed-update

# --- Test 6: runbook is seed-only after creation ---
target="$(setup_empty_repo runbook-seed-target)"
run_new_project "$target" >/dev/null
printf '%s\n' '# Local Worktree Runbook' >"$target/docs/runbooks/parallel-agent-worktrees.md"
rc=0
output="$(run_update_project "$target" 2>&1)" || rc=$?
assert_exit_code 0 "$rc" "update-project runbook-seed exits 0"
assert_file_contains "$target/docs/runbooks/parallel-agent-worktrees.md" "# Local Worktree Runbook" "update-project preserves existing runbook"
assert_generated_safety "$target" old-runbook
rm "$target/docs/runbooks/parallel-agent-worktrees.md"
rc=0
output="$("$helper_bash" "$target/scripts/remove-worktree.sh" --branch main --delete-branch 2>&1)" || rc=$?
assert_exit_code 1 "$rc" "missing runbook still protects branch"
assert_output_contains "$output" "owner confirmation" "missing runbook refusal contains owner requirement"
assert_output_contains "$output" "commits are retained before deletion" "missing runbook refusal contains preservation requirement"
output="$("$helper_bash" "$target/scripts/remove-worktree.sh" --help)"
assert_output_contains "$output" "obtain owner confirmation" "help contains owner requirement"
assert_output_contains "$output" "commits are retained before deletion" "help contains preservation requirement"
assert_output_contains "$output" "Git 2.36+" "help documents Git minimum"

# Existing symlinked helpers are not overwritten even with migration requested.
target="$(setup_empty_repo symlink-helper-target)"
run_new_project "$target" >/dev/null
printf '%s\n' '#!/usr/bin/env bash' 'echo external custom helper' >"$tmp_root/external-helper"
rm "$target/scripts/new-worktree.sh"
ln -s "$tmp_root/external-helper" "$target/scripts/new-worktree.sh"
output="$(run_update_project "$target" --migrate-root-scripts 2>&1)"
assert_output_contains "$output" "symlink files are not auto-managed" "update preserves symlinked helper"
assert_file_contains "$tmp_root/external-helper" "echo external custom helper" "update preserves external symlink destination"

# Keep standalone copies aligned without shipping another runtime file.
sed -n '/^# BEGIN worktree discovery$/,/^# END worktree discovery$/p' "$repo_root/scaffold/root/scripts/new-worktree.sh" >"$tmp_root/new-discovery"
sed -n '/^# BEGIN worktree discovery$/,/^# END worktree discovery$/p' "$repo_root/scaffold/root/scripts/remove-worktree.sh" >"$tmp_root/remove-discovery"
if [[ -s "$tmp_root/new-discovery" ]] && cmp -s "$tmp_root/new-discovery" "$tmp_root/remove-discovery"; then
  echo "PASS: standalone discovery copies match"
  passed=$((passed + 1))
else
  echo "FAIL: standalone discovery copies differ or are missing" >&2
  failed=$((failed + 1))
fi

echo ""
echo "Results: $passed passed, $failed failed"
if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
echo "worktree helper sync regression checks passed."

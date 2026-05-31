#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-budget-hook-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp_root"
}

trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  [[ -z "${2:-}" ]] || printf '%s\n' "$2" >&2
  exit 1
}

# Create a generated project with the managed hooks enabled and a clean initial
# commit. Prints the project path.
fresh_project() {
  local p="$tmp_root/$1"
  mkdir -p "$p"
  git -C "$p" init -q
  "$repo_root/scripts/new-project.sh" hooktest "$p" >/dev/null
  git -C "$p" config core.hooksPath agent-vault/_assets/hooks
  git -C "$p" config user.email tester@example.com
  git -C "$p" config user.name tester
  (cd "$p" && git add -A &&
    AGENT_VAULT_SKIP_MEMORY_BUDGET=1 AGENT_VAULT_SKIP_METADATA_GATE=1 git commit -qm init)
  printf '%s' "$p"
}

# commit_capture <project> <git args...>  -> sets HOOK_RC and HOOK_STDERR.
# Caller may prefix env (AGENT_VAULT_SKIP_*) which propagates to the hook.
commit_capture() {
  local p="$1"
  shift
  set +e
  HOOK_STDERR="$(cd "$p" && "$@" 2>&1 1>/dev/null)"
  HOOK_RC=$?
  set -e
}

oversize() {
  head -c 45000 /dev/zero | tr '\0' 'x'
}

# Case 1: an over-budget staged memory file prints a non-blocking warning and the
# commit still succeeds; the over-budget file is reported once (deduplicated).
p="$(fresh_project case1)"
oversize >>"$p/agent-vault/project-context.md"
git -C "$p" add agent-vault/project-context.md
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm c1
[[ "$HOOK_RC" -eq 0 ]] || fail "over-budget commit was blocked (rc=$HOOK_RC)" "$HOOK_STDERR"
[[ "$HOOK_STDERR" == *"memory-budget warning"* ]] || fail "no budget warning on over-budget staged file" "$HOOK_STDERR"
over_count="$(printf '%s\n' "$HOOK_STDERR" | grep -c 'project-context.md')"
[[ "$over_count" -eq 1 ]] || fail "over-budget file not deduplicated (appeared $over_count times)" "$HOOK_STDERR"

# Case 2: AGENT_VAULT_SKIP_MEMORY_BUDGET=1 silences the warning (commit succeeds).
p="$(fresh_project case2)"
oversize >>"$p/agent-vault/project-context.md"
git -C "$p" add agent-vault/project-context.md
AGENT_VAULT_SKIP_METADATA_GATE=1 AGENT_VAULT_SKIP_MEMORY_BUDGET=1 commit_capture "$p" git commit -qm c2
[[ "$HOOK_RC" -eq 0 ]] || fail "silenced commit was blocked (rc=$HOOK_RC)" "$HOOK_STDERR"
[[ "$HOOK_STDERR" != *"memory-budget warning"* ]] || fail "AGENT_VAULT_SKIP_MEMORY_BUDGET did not silence the warning" "$HOOK_STDERR"

# Case 3: a within-budget staged memory change prints no warning.
p="$(fresh_project case3)"
printf 'small change\n' >>"$p/agent-vault/project-context.md"
git -C "$p" add agent-vault/project-context.md
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm c3
[[ "$HOOK_RC" -eq 0 ]] || fail "within-budget commit was blocked (rc=$HOOK_RC)" "$HOOK_STDERR"
[[ "$HOOK_STDERR" != *"memory-budget warning"* ]] || fail "warning printed for a within-budget change" "$HOOK_STDERR"

# Case 4a: STAGED over-budget but working tree reverted small -> warns on STAGED.
p="$(fresh_project case4a)"
oversize >>"$p/agent-vault/project-context.md"
git -C "$p" add agent-vault/project-context.md
printf 'small\n' >"$p/agent-vault/project-context.md"
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm c4a
[[ "$HOOK_STDERR" == *"memory-budget warning"* ]] || fail "did not warn on staged over-budget content (working tree small)" "$HOOK_STDERR"

# Case 4b: STAGED small but working tree over-budget (unstaged) -> no warning.
p="$(fresh_project case4b)"
printf 'small change\n' >>"$p/agent-vault/project-context.md"
git -C "$p" add agent-vault/project-context.md
oversize >>"$p/agent-vault/project-context.md"
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm c4b
[[ "$HOOK_STDERR" != *"memory-budget warning"* ]] || fail "warned on unstaged working-tree content" "$HOOK_STDERR"

# --- context-log rollover warning (D2) -----------------------------------

# Stage agent-vault/context-log.md with a stale duplicate "## Current Snapshot".
stage_dup_snapshot() {
  printf '\n## Current Snapshot\n- Active branch: `old-stale-branch`\n' >>"$1/agent-vault/context-log.md"
  git -C "$1" add agent-vault/context-log.md
}

# Case 5: a staged context-log with a duplicate snapshot prints a non-blocking
# rollover warning naming the finding; the commit still succeeds.
p="$(fresh_project case5)"
stage_dup_snapshot "$p"
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm c5
[[ "$HOOK_RC" -eq 0 ]] || fail "rollover-warning commit was blocked (rc=$HOOK_RC)" "$HOOK_STDERR"
[[ "$HOOK_STDERR" == *"context-log rollover warning"* ]] || fail "no rollover warning on duplicate snapshot" "$HOOK_STDERR"
[[ "$HOOK_STDERR" == *'duplicate "## Current Snapshot"'* ]] || fail "rollover warning omitted the finding" "$HOOK_STDERR"

# Case 6: AGENT_VAULT_SKIP_ROLLOVER_CHECK=1 silences the rollover warning.
p="$(fresh_project case6)"
stage_dup_snapshot "$p"
AGENT_VAULT_SKIP_METADATA_GATE=1 AGENT_VAULT_SKIP_ROLLOVER_CHECK=1 commit_capture "$p" git commit -qm c6
[[ "$HOOK_RC" -eq 0 ]] || fail "silenced rollover commit was blocked (rc=$HOOK_RC)" "$HOOK_STDERR"
[[ "$HOOK_STDERR" != *"context-log rollover warning"* ]] || fail "AGENT_VAULT_SKIP_ROLLOVER_CHECK did not silence" "$HOOK_STDERR"

# Case 7: a clean staged context-log change prints no rollover warning.
p="$(fresh_project case7)"
printf -- '- extra clean note\n' >>"$p/agent-vault/context-log.md"
git -C "$p" add agent-vault/context-log.md
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm c7
[[ "$HOOK_RC" -eq 0 ]] || fail "clean context-log commit was blocked (rc=$HOOK_RC)" "$HOOK_STDERR"
[[ "$HOOK_STDERR" != *"context-log rollover warning"* ]] || fail "rollover warning on a clean context-log" "$HOOK_STDERR"

# Case 8a: STAGED duplicate snapshot but working tree reverted clean -> warns on
# STAGED, and the follow-up guidance points at the staged content (not the clean
# working-tree file, which would falsely report no issue here).
p="$(fresh_project case8a)"
stage_dup_snapshot "$p"
git -C "$p" show HEAD:agent-vault/context-log.md >"$p/agent-vault/context-log.md"
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm c8a
[[ "$HOOK_STDERR" == *"context-log rollover warning"* ]] || fail "did not warn on staged duplicate (working tree clean)" "$HOOK_STDERR"
[[ "$HOOK_STDERR" == *"STAGED content"* ]] || fail "8a: guidance does not clarify the warning is about staged content" "$HOOK_STDERR"
[[ "$HOOK_STDERR" == *"git show :agent-vault/context-log.md"* ]] || fail "8a: guidance offers no staged-content inspection path" "$HOOK_STDERR"
[[ "$HOOK_STDERR" != *"check-context-log-rollover.sh agent-vault/context-log.md for the full report"* ]] || fail "8a: guidance points at the working-tree file for the full report" "$HOOK_STDERR"

# Case 8b: STAGED clean but working tree has a duplicate (unstaged) -> no warning.
p="$(fresh_project case8b)"
printf -- '- extra clean note\n' >>"$p/agent-vault/context-log.md"
git -C "$p" add agent-vault/context-log.md
printf '\n## Current Snapshot\n- Active branch: `old-stale-branch`\n' >>"$p/agent-vault/context-log.md"
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm c8b
[[ "$HOOK_STDERR" != *"context-log rollover warning"* ]] || fail "warned on unstaged working-tree duplicate snapshot" "$HOOK_STDERR"

# Case 9: context-log.md staged for deletion -> no staged blob -> silent no-op
# (the warning never fires and never blocks the commit).
p="$(fresh_project case9)"
git -C "$p" rm -q agent-vault/context-log.md
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm c9
[[ "$HOOK_RC" -eq 0 ]] || fail "staged deletion was blocked by the rollover warning (rc=$HOOK_RC)" "$HOOK_STDERR"
[[ "$HOOK_STDERR" != *"context-log rollover warning"* ]] || fail "warned on a staged deletion (no staged blob)" "$HOOK_STDERR"

echo "memory budget + context-log rollover pre-commit hook regression checks passed."

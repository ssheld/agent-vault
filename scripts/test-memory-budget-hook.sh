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

# Closure must be a checker finding, not a bare warning that grep '^- ' drops.
# Also prove it reads the staged blob, and never changes the non-blocking policy.
p="$(fresh_project eof-staged)"
printf '\n## Appendix\n~~~md\nUnclosed staged example.\n' >>"$p/agent-vault/context-log.md"
git -C "$p" add agent-vault/context-log.md
printf '~~~\n' >>"$p/agent-vault/context-log.md"
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm eof-staged
[[ "$HOOK_RC" -eq 0 ]] || fail "staged EOF finding blocked commit" "$HOOK_STDERR"
[[ "$HOOK_STDERR" == *"- unterminated fence in live "* ]] || fail "hook filtered out closure finding" "$HOOK_STDERR"
[[ "$HOOK_STDERR" == *"opening line"* ]] || fail "closure finding lost opening line" "$HOOK_STDERR"

p="$(fresh_project eof-unstaged)"
printf '\n## Appendix\n~~~md\nClosed staged example.\n~~~\n' >>"$p/agent-vault/context-log.md"
git -C "$p" add agent-vault/context-log.md
printf '\n~~~\nUnstaged example.\n' >>"$p/agent-vault/context-log.md"
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm eof-unstaged
[[ "$HOOK_RC" -eq 0 ]] || fail "unstaged EOF example blocked commit" "$HOOK_STDERR"
[[ "$HOOK_STDERR" != *"context-log rollover warning"* ]] || fail "hook warned on unstaged EOF" "$HOOK_STDERR"

# Inline imports are checked in staged content, not the working tree.
p="$(fresh_project inline-import)"
mkdir -p "$p/docs"
printf '\nSee @docs/large.md for instructions.\n' >>"$p/CLAUDE.md"
oversize >"$p/docs/large.md"
git -C "$p" add CLAUDE.md docs/large.md
printf 'unstaged small content\n' >"$p/docs/large.md"
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm inline-import
[[ "$HOOK_RC" -eq 0 ]] || fail "inline overage blocked commit" "$HOOK_STDERR"
[[ "$HOOK_STDERR" == *"OVER docs/large.md"* ]] || fail "staged inline overage was hidden" "$HOOK_STDERR"

p="$(fresh_project code-example)"
mkdir -p "$p/docs"
printf '\n~~~md\n@docs/large.md\n~~~\n' >>"$p/CLAUDE.md"
oversize >"$p/docs/large.md"
git -C "$p" add CLAUDE.md docs/large.md
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm code-example
[[ "$HOOK_RC" -eq 0 ]] || fail "code example blocked commit" "$HOOK_STDERR"
[[ "$HOOK_STDERR" != *"memory-budget warning"* ]] || fail "code example counted as import" "$HOOK_STDERR"

# Ordinary container content must not create a staged incomplete warning.
p="$(fresh_project container-negative)"
mkdir -p "$p/docs"
printf 'real import target\n' >"$p/docs/real.md"
printf '%s\n' '' '- Contacts' '    - Ask someone@example.com before deploying.' '' \
  '<details>' '<summary>Notes</summary>' '</details>' '' \
  '- ~~~' '  example@example.com' '  ~~~' '' \
  'Real import: @docs/real.md' >>"$p/CLAUDE.md"
git -C "$p" add CLAUDE.md docs/real.md
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm container-negative
[[ "$HOOK_RC" -eq 0 ]] || fail "ordinary containers blocked commit" "$HOOK_STDERR"
[[ "$HOOK_STDERR" != *"memory-budget warning"* ]] || fail "ordinary containers produced a false incomplete warning" "$HOOK_STDERR"

# Both an absolute import and an absolute symlink are outside the staged copy.
# Advisory exclusions must survive even though the checker itself exits zero.
p="$(fresh_project external-staged)"
mkdir -p "$p/docs"
oversize >"$p/docs/absolute.md"
printf '\n@%s/docs/absolute.md\n@absolute-link.md\n' "$p" >>"$p/CLAUDE.md"
ln -s "$p/docs/absolute.md" "$p/absolute-link.md"
git -C "$p" add CLAUDE.md docs/absolute.md absolute-link.md
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm external-staged
[[ "$HOOK_RC" -eq 0 ]] || fail "scope exclusion blocked commit" "$HOOK_STDERR"
[[ "$HOOK_STDERR" == *"EXTERNAL"* ]] || fail "successful checker hid exclusions" "$HOOK_STDERR"
[[ "$HOOK_STDERR" == *"absolute-link.md"* ]] || fail "symlink exclusion hidden" "$HOOK_STDERR"
[[ "$HOOK_STDERR" != *"INCOMPLETE"* ]] || fail "known outside target marked incomplete" "$HOOK_STDERR"
[[ "$HOOK_STDERR" != *"OVER docs/absolute.md"* ]] || fail "hook read unstaged absolute target" "$HOOK_STDERR"
# Direct measurement can include that same target; the difference is explicit.
direct_rc=0
direct_output="$("$p/scripts/check-memory-budget.sh" --repo "$p" --strict 2>&1)" || direct_rc=$?
[[ "$direct_rc" -eq 1 ]] || fail "direct worktree check missed absolute import" "$direct_output"
[[ "$direct_output" == *"docs/absolute.md"* ]] || fail "direct check omitted target" "$direct_output"
printf '\nSuppressed exclusion report.\n' >>"$p/CLAUDE.md"
git -C "$p" add CLAUDE.md
AGENT_VAULT_SKIP_METADATA_GATE=1 AGENT_VAULT_SKIP_MEMORY_BUDGET=1 commit_capture "$p" git commit -qm excluded-suppressed
[[ "$HOOK_RC" -eq 0 && "$HOOK_STDERR" != *"memory-budget warning"* ]] || fail "exclusion suppression failed" "$HOOK_STDERR"

p="$(fresh_project incomplete)"
printf '\nFixture change.\n' >>"$p/CLAUDE.md"
git -C "$p" add CLAUDE.md
AGENT_VAULT_SKIP_METADATA_GATE=1 AGENT_VAULT_IMPORT_MAX_EDGES=1 commit_capture "$p" git commit -qm incomplete
[[ "$HOOK_RC" -eq 0 ]] || fail "incomplete scan blocked commit" "$HOOK_STDERR"
[[ "$HOOK_STDERR" == *"INCOMPLETE"* ]] || fail "incomplete scan was filtered out" "$HOOK_STDERR"

p="$(fresh_project checker-error)"
printf '#!/usr/bin/env bash\nprintf "Error: injected read failure\\n" >&2\nexit 2\n' >"$p/scripts/check-memory-budget.sh"
printf '\nFixture change.\n' >>"$p/CLAUDE.md"
git -C "$p" add CLAUDE.md
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm checker-error
[[ "$HOOK_RC" -eq 0 ]] || fail "checker I/O error blocked commit" "$HOOK_STDERR"
[[ "$HOOK_STDERR" == *"injected read failure"* ]] || fail "I/O error reason filtered out" "$HOOK_STDERR"

# The new context-log allowance and configuration must both come from the index.
p="$(fresh_project context-log-budget)"
cp "$p/agent-vault/context-log.md" "$tmp_root/context-base"
context_size() {
  cp "$tmp_root/context-base" "$p/agent-vault/context-log.md"
  local base_bytes
  base_bytes="$(wc -c <"$tmp_root/context-base" | tr -d '[:space:]')"
  head -c "$(($1 - base_bytes))" /dev/zero | tr '\0' x >>"$p/agent-vault/context-log.md"
}
context_size 50000
# The migration note alone is not a recurring hook-warning trigger.
printf 'file_budget=100000\n' >"$p/agent-vault/memory-budget.config"
git -C "$p" add agent-vault/context-log.md agent-vault/memory-budget.config
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm context-within-budget
[[ "$HOOK_RC" -eq 0 && "$HOOK_STDERR" != *"memory-budget warning"* ]] || fail "50 KB protocol log or migration note triggered a warning" "$HOOK_STDERR"

context_size 60001
cp "$p/agent-vault/context-log.md" "$tmp_root/staged-context"
git -C "$p" add agent-vault/context-log.md
cp "$tmp_root/context-base" "$p/agent-vault/context-log.md"
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm context-staged-over
[[ "$HOOK_RC" -eq 0 && "$HOOK_STDERR" == *"over context-log budget (60000 bytes)"* ]] || fail "staged context overage was hidden or blocked" "$HOOK_STDERR"
cmp -s "$tmp_root/context-base" "$p/agent-vault/context-log.md" || fail "hook changed the working-tree context log"
git -C "$p" show HEAD:agent-vault/context-log.md >"$tmp_root/committed-context"
cmp -s "$tmp_root/staged-context" "$tmp_root/committed-context" || fail "hook compacted staged content"

context_size 50000
git -C "$p" add agent-vault/context-log.md
context_size 60001
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm context-staged-small
[[ "$HOOK_RC" -eq 0 && "$HOOK_STDERR" != *"memory-budget warning"* ]] || fail "unstaged context overage triggered a warning" "$HOOK_STDERR"

# Only the config is staged; the log remains the previous 50 KB index version.
printf 'context_log_budget=45000\ncontext_log_target=30000\n' >"$p/agent-vault/memory-budget.config"
git -C "$p" add agent-vault/memory-budget.config
printf 'context_log_budget=65000\ncontext_log_target=30000\n' >"$p/agent-vault/memory-budget.config"
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm config-staged-low
[[ "$HOOK_RC" -eq 0 && "$HOOK_STDERR" == *"over context-log budget (45000 bytes)"* ]] || fail "config-only staging ignored staged low limit" "$HOOK_STDERR"

git -C "$p" add agent-vault/memory-budget.config
printf 'context_log_budget=45000\ncontext_log_target=30000\n' >"$p/agent-vault/memory-budget.config"
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm config-staged-high
[[ "$HOOK_RC" -eq 0 && "$HOOK_STDERR" != *"memory-budget warning"* ]] || fail "hook read unstaged low config" "$HOOK_STDERR"

printf 'context_log_target=0\n' >"$p/agent-vault/memory-budget.config"
git -C "$p" add agent-vault/memory-budget.config
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm config-invalid
[[ "$HOOK_RC" -eq 0 && "$HOOK_STDERR" == *"context_log_target must be positive"* ]] || fail "invalid context config was hidden or blocked commit" "$HOOK_STDERR"

# A misconfigured explicit designation must reach the real hook error surface,
# not produce only an unrelated canonical-log overage. Both files are 50 KB.
context_size 50000
mkdir -p "$p/docs"
cp "$p/agent-vault/context-log.md" "$p/docs/log.md"
printf 'context_log_path=docs/log.md\n' >"$p/agent-vault/memory-budget.config"
git -C "$p" add agent-vault/context-log.md docs/log.md agent-vault/memory-budget.config
# A valid unstaged config must not conceal the staged configuration error.
printf 'context_log_path=docs/log.md\nprotocol_read=docs/log.md\n' >"$p/agent-vault/memory-budget.config"
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm context-path-uncovered
[[ "$HOOK_RC" -eq 0 && "$HOOK_STDERR" == *"context_log_path 'docs/log.md' is not in effective protocol_read"* ]] || fail "uncovered designation diagnostic was hidden or blocked commit" "$HOOK_STDERR"
[[ "$HOOK_STDERR" == *"include it in protocol_read"* && "$HOOK_STDERR" != *"over file budget"* ]] || fail "uncovered designation gave a misleading hook warning" "$HOOK_STDERR"

git -C "$p" add agent-vault/memory-budget.config
printf 'context_log_path=docs/log.md\n' >"$p/agent-vault/memory-budget.config"
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm context-path-covered
[[ "$HOOK_RC" -eq 0 && "$HOOK_STDERR" != *"memory-budget warning"* ]] || fail "hook rejected staged covered designation using unstaged config" "$HOOK_STDERR"

# Omitting the built-in default via a narrowed file set stays informational.
printf 'protocol_read=agent-vault/plan.md agent-vault/lessons.md\n' >"$p/agent-vault/memory-budget.config"
git -C "$p" add agent-vault/memory-budget.config
AGENT_VAULT_SKIP_METADATA_GATE=1 commit_capture "$p" git commit -qm context-default-excluded
[[ "$HOOK_RC" -eq 0 && "$HOOK_STDERR" != *"memory-budget warning"* ]] || fail "default designation exclusion triggered a hook warning" "$HOOK_STDERR"

echo "memory budget + context-log rollover pre-commit hook regression checks passed."

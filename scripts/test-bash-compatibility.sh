#!/usr/bin/env bash
# The harness needs Bash 4.4+; HOOK_TEST_BASH selects only the hooks under test.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-bash-test.XXXXXX")"
tmp_root="$(cd "$tmp_root" && pwd -P)"
trap 'rm -rf "$tmp_root"' EXIT
hook_bash="$(command -v "${HOOK_TEST_BASH:-$BASH}")"
unsupported_bash="${UNSUPPORTED_TEST_BASH:-}"
helpers=(check-memory-budget check-context-log-rollover compact-context-log check-lessons-archive)
pass=0
output=""
rc=0
fail() {
  printf 'FAIL: %s\n%s\n' "$*" "$output" >&2
  exit 1
}
check() {
  "$@" || fail "$*"
  pass=$((pass + 1))
}
run() {
  rc=0
  output="$("$@" 2>&1)" || rc=$?
}
expect_rc() { check test "$rc" -eq "$1"; }
contains() {
  [[ "$output" == *"$1"* ]] || fail "missing $1"
  pass=$((pass + 1))
}

# Only these files promise to execute on stock macOS Bash.
for file in scaffold/agent-vault/_assets/hooks/pre-commit \
  scaffold/agent-vault/_assets/hooks/pre-push \
  scaffold/agent-vault/_assets/hooks/lib/runtime-note.sh \
  scaffold/root/scripts/new-worktree.sh scaffold/root/scripts/remove-worktree.sh; do
  check "$hook_bash" -n "$repo_root/$file"
done
printf 'Hook test interpreter: %s\n' "$hook_bash"
"$hook_bash" -c 'echo "$BASH_VERSION"'

# Extract only trusted repository shell code, never project memory or user input.
# Fail closed on missing/duplicate/reversed markers or initialization lines.
extract_guard() {
  awk '
    /^# BEGIN bash compatibility$/ { begins++; active = 1 }
    active { print }
    /^# END bash compatibility$/ { ends++; if (!active) bad = 1; active = 0 }
    END { if (begins != 1 || ends != 1 || active || bad) exit 1 }
  ' "$1"
}
substitute_version() {
  awk -v major="$2" -v minor="$3" '
    $0 == "  agent_vault_bash_major=${BASH_VERSINFO[0]} agent_vault_bash_minor=${BASH_VERSINFO[1]}" {
      matches++
      print "  agent_vault_bash_major=" major " agent_vault_bash_minor=" minor
      next
    }
    { print }
    END { if (matches != 1) exit 1 }
  ' "$1"
}
for helper in "${helpers[@]}"; do
  extract_guard "$repo_root/scaffold/root/scripts/$helper.sh" >"$tmp_root/$helper.guard" ||
    fail "invalid guard markers: $helper"
  check cmp -s "$tmp_root/check-memory-budget.guard" "$tmp_root/$helper.guard"
  for pair in '3 2 2' '4 0 2' '4 3 2' '4 4 0' '4 10 0' '5 0 0' '5 3 0' '10 0 0'; do
    read -r major minor expected <<<"$pair"
    substitute_version "$tmp_root/$helper.guard" "$major" "$minor" >"$tmp_root/synthetic.sh" ||
      fail "invalid version initialization"
    run "$hook_bash" "$tmp_root/synthetic.sh"
    expect_rc "$expected"
  done
done
for damage in missing duplicate reversed; do
  case "$damage" in
    missing) sed '/^# END bash compatibility$/d' "$tmp_root/check-memory-budget.guard" >"$tmp_root/damaged" ;;
    duplicate) cat "$tmp_root/check-memory-budget.guard" "$tmp_root/check-memory-budget.guard" >"$tmp_root/damaged" ;;
    reversed) printf '# END bash compatibility\n# BEGIN bash compatibility\n' >"$tmp_root/damaged" ;;
  esac
  run extract_guard "$tmp_root/damaged"
  expect_rc 1
done
for damage in missing duplicate; do
  if [[ "$damage" == missing ]]; then
    sed '/^  agent_vault_bash_major=/d' "$tmp_root/check-memory-budget.guard" >"$tmp_root/damaged"
  else
    awk '{ print; if ($0 ~ /^  agent_vault_bash_major=/) print }' "$tmp_root/check-memory-budget.guard" >"$tmp_root/damaged"
  fi
  run substitute_version "$tmp_root/damaged" 4 3
  expect_rc 1
done

checker="$repo_root/scaffold/root/scripts/check-context-log-rollover.sh"
run "$BASH" -c 'source "$1"; declare -F rollover_check_main' source-test "$checker"
expect_rc 0
if [[ -n "$unsupported_bash" ]]; then
  unsupported_bash="$(command -v "$unsupported_bash")"
  "$unsupported_bash" -c '((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4)))' ||
    fail "UNSUPPORTED_TEST_BASH must select a real Bash below 4.4"
  mkdir -p "$tmp_root/refusal/.agent-vault-rollover-pending"
  printf 'unchanged input\n' >"$tmp_root/refusal/log.md"
  printf 'pending transaction\n' >"$tmp_root/refusal/.agent-vault-rollover-pending/record"
  cp -R "$tmp_root/refusal" "$tmp_root/refusal-before"
  for helper in "${helpers[@]}"; do
    for mode in normal help quiet dry-run recover count byte; do
      args=("$tmp_root/refusal/log.md")
      case "$mode" in
        help) args=(--help) ;;
        quiet) args+=(--quiet) ;;
        dry-run) args+=(--dry-run) ;;
        recover) args+=(--recover) ;;
        count) args+=(--keep 1 --archive "$tmp_root/refusal/new/archive.md" --manifest "$tmp_root/refusal/new/manifest.md") ;;
        byte) args+=(--to-budget --context-log-budget 1000 --context-log-target 500) ;;
      esac
      run "$unsupported_bash" "$repo_root/scaffold/root/scripts/$helper.sh" "${args[@]}"
      expect_rc 2
      contains "$helper.sh: Bash 4.4+ is required"
      contains 'PATH'
      check diff -r "$tmp_root/refusal-before" "$tmp_root/refusal"
    done
  done
  run "$unsupported_bash" -c '
    set -u
    before=$-
    source "$1"
    status=$?
    [[ $status == 2 && $- == "$before" ]] || exit 90
    if declare -F rollover_check_main; then exit 91; fi
    [[ ${agent_vault_bash_major-unset} == unset ]] || exit 92
    echo caller-survived
  ' source-test "$checker"
  expect_rc 0
  contains caller-survived
else
  echo 'Real unsupported-interpreter checks skipped (set UNSUPPORTED_TEST_BASH; required in macOS CI).'
fi

# Real generated project and real Git commit/shebang paths.
# shellcheck source=scripts/lib/fixed-test-clock.sh
source "$repo_root/scripts/lib/fixed-test-clock.sh"
install_fixed_test_clock "$tmp_root/clock"
project="$tmp_root/project"
git init -q "$project"
"$repo_root/scripts/new-project.sh" compatibility "$project" >/dev/null
git -C "$project" config user.name 'Compatibility Test'
git -C "$project" config user.email compatibility@example.com
printf 'source\n' >"$project/source.txt"
printf 'runtime\n' >"$project/agent-vault/daily/deletion.md"
git -C "$project" add -A
git -C "$project" -c core.hooksPath=/dev/null commit -qm bootstrap
mkdir -p "$tmp_root/hook-bin"
ln -s "$hook_bash" "$tmp_root/hook-bin/bash"
hook_path="$tmp_root/hook-bin:$PATH"
commit() { (cd "$project" && PATH="$hook_path" git commit -qm compatibility); }
direct_hook() { (cd "$project" && "$hook_bash" agent-vault/_assets/hooks/pre-commit); }

run direct_hook
expect_rc 0
git -C "$project" rm -q agent-vault/daily/deletion.md
run commit
expect_rc 0
git -C "$project" rm -q source.txt
run commit
expect_rc 1
contains 'stage agent-vault/context-log.md'
check test "${output#*unbound variable}" = "$output"
run env PATH="$hook_path" AGENT_VAULT_SKIP_METADATA_GATE=1 "$hook_bash" -c 'cd "$1"; agent-vault/_assets/hooks/pre-commit' bypass "$project"
expect_rc 0

# Valid metadata allows the substantive deletion, including an empty error list.
printf '\nCompatibility session.\n' >>"$project/agent-vault/context-log.md"
git -C "$project" add agent-vault/context-log.md
run env PATH="$hook_path" AGENT_VAULT_SKIP_MEMORY_BUDGET=1 AGENT_VAULT_SKIP_ROLLOVER_CHECK=1 \
  "$hook_bash" -c 'cd "$1"; agent-vault/_assets/hooks/pre-commit' enforcement "$project"
expect_rc 1
contains 'stage one note under agent-vault/daily/'
printf 'Daily\n' >"$project/agent-vault/daily/compatibility.md"
printf 'Design\n' >"$project/agent-vault/design-log/compatibility.md"
git -C "$project" add agent-vault
for suppression in neither memory rollover both; do
  skip_memory=0 skip_rollover=0
  [[ "$suppression" != memory && "$suppression" != both ]] || skip_memory=1
  [[ "$suppression" != rollover && "$suppression" != both ]] || skip_rollover=1
  run env PATH="$hook_path" AGENT_VAULT_SKIP_MEMORY_BUDGET="$skip_memory" \
    AGENT_VAULT_SKIP_ROLLOVER_CHECK="$skip_rollover" "$hook_bash" -c \
    'cd "$1"; agent-vault/_assets/hooks/pre-commit' advisory "$project"
  expect_rc 0
  if [[ -n "$unsupported_bash" && "$hook_bash" == "$unsupported_bash" ]]; then
    if [[ "$skip_memory" == 0 ]]; then contains 'check-memory-budget.sh: Bash 4.4+ is required'; fi
    if [[ "$skip_rollover" == 0 ]]; then contains 'check-context-log-rollover.sh: Bash 4.4+ is required'; fi
  fi
  if [[ "$skip_memory" == 1 ]]; then check test "${output#*memory-budget warning}" = "$output"; fi
  if [[ "$skip_rollover" == 1 ]]; then check test "${output#*rollover warning}" = "$output"; fi
done
# Explicit old hook with modern helper PATH runs the real checkers normally.
run direct_hook
expect_rc 0
check test "${output#*Bash 4.4+ is required}" = "$output"
run commit
expect_rc 0

# A context-log deletion is exempt runtime metadata and has no staged blob to
# warn about. Restore only this test-owned fixture after checking the hook.
git -C "$project" rm -q agent-vault/context-log.md
run env PATH="$hook_path" "$hook_bash" -c 'cd "$1"; agent-vault/_assets/hooks/pre-commit' deletion "$project"
expect_rc 0
check test "${output#*rollover warning}" = "$output"
git -C "$project" restore --source=HEAD --staged --worktree -- agent-vault/context-log.md

# Mixed old hook / modern helper: warnings must see the index, not the repaired
# working-tree file. Preserve metadata bypass independence as well.
cp "$project/agent-vault/context-log.md" "$tmp_root/context.saved"
printf '\n## Current Snapshot\n- stale duplicate\n' >>"$project/agent-vault/context-log.md"
git -C "$project" add agent-vault/context-log.md
cp "$tmp_root/context.saved" "$project/agent-vault/context-log.md"
run env AGENT_VAULT_SKIP_METADATA_GATE=1 "$hook_bash" -c \
  'cd "$1"; "$2" agent-vault/_assets/hooks/pre-commit' staged "$project" "$hook_bash"
expect_rc 0
contains 'context-log rollover warning'
contains 'expected exactly 1, found 2'
git -C "$project" add agent-vault/context-log.md

# Error status 2 does not identify an old Bash: check raw errors and fallback.
cp "$project/scripts/check-context-log-rollover.sh" "$tmp_root/checker.saved"
printf '\nDiagnostic test.\n' >>"$project/agent-vault/context-log.md"
git -C "$project" add agent-vault/context-log.md
for error in config silent; do
  if [[ "$error" == config ]]; then
    printf '#!/bin/sh\nprintf "Error: invalid context_log_budget\\n" >&2\nexit 2\n' >"$project/scripts/check-context-log-rollover.sh"
  else
    printf '#!/bin/sh\nexit 2\n' >"$project/scripts/check-context-log-rollover.sh"
  fi
  run env PATH="$hook_path" AGENT_VAULT_SKIP_MEMORY_BUDGET=1 "$hook_bash" -c \
    'cd "$1"; agent-vault/_assets/hooks/pre-commit' diagnostic "$project"
  expect_rc 0
  if [[ "$error" == config ]]; then contains 'invalid context_log_budget'; else contains 'Checker exited 2 without usable diagnostic output'; fi
  check test "${output#*Bash 4.4+ is required}" = "$output"
done
cp "$tmp_root/checker.saved" "$project/scripts/check-context-log-rollover.sh"

# Installed managed helpers: refresh, dry-run, missing restoration, permissions.
for helper in "${helpers[@]}"; do
  printf '# outdated managed copy\n' >>"$project/scripts/$helper.sh"
done
"$repo_root/scripts/update-project.sh" "$project" --dry-run >/dev/null
check grep -q 'outdated managed copy' "$project/scripts/compact-context-log.sh"
"$repo_root/scripts/update-project.sh" "$project" >/dev/null
for helper in "${helpers[@]}"; do
  check cmp -s "$repo_root/scaffold/root/scripts/$helper.sh" "$project/scripts/$helper.sh"
  check test -x "$project/scripts/$helper.sh"
  if [[ -n "$unsupported_bash" ]]; then
    run "$unsupported_bash" "$project/scripts/$helper.sh" --help
    expect_rc 2
    contains 'Bash 4.4+ is required'
  fi
done
rm "$project/scripts/check-memory-budget.sh"
printf '#!/bin/sh\n# project-owned helper\nexit 0\n' >"$project/scripts/check-lessons-archive.sh"
cp "$project/scripts/check-lessons-archive.sh" "$tmp_root/unmanaged"
git -C "$project" config core.hooksPath custom-hooks
"$repo_root/scripts/update-project.sh" "$project" >/dev/null
check cmp -s "$repo_root/scaffold/root/scripts/check-memory-budget.sh" "$project/scripts/check-memory-budget.sh"
check cmp -s "$tmp_root/unmanaged" "$project/scripts/check-lessons-archive.sh"
check test "$(git -C "$project" config core.hooksPath)" = custom-hooks

# Modern compactor, old PATH Bash, and an interrupted replacement/recovery.
mkdir -p "$tmp_root/old-bin" "$tmp_root/compact"
# The test clock itself uses an env-Bash shebang. Pin that fixture so the
# deliberately unusable PATH Bash below tests the checker launch, not date.
{
  printf '#!%s\n' "$BASH"
  sed '1d' "$tmp_root/clock/date"
} >"$tmp_root/old-bin/date"
chmod +x "$tmp_root/old-bin/date"
if [[ -n "$unsupported_bash" ]]; then
  ln -s "$unsupported_bash" "$tmp_root/old-bin/bash"
else
  printf '#!/bin/sh\nexit 91\n' >"$tmp_root/old-bin/bash"
  chmod +x "$tmp_root/old-bin/bash"
fi
cat >"$tmp_root/compact/log.md" <<'EOF'
# Context Log
## Usage Rules
- Newest first.
## Current Snapshot
- Last updated: 2026-05-30
## Entries
### 2026-05-30 09:00 local - test - rollover session
- Current.
### 2026-05-29 09:00 local - test - older
- Old.
### 2026-05-28 09:00 local - test - oldest
- Older.
EOF
compact_args=("$tmp_root/compact/log.md" --keep 1 --archive "$tmp_root/compact/archive.md"
  --manifest "$tmp_root/compact/manifest.md" --require-top-entry 'rollover session')
compactor="$repo_root/scaffold/root/scripts/compact-context-log.sh"
run env PATH="$tmp_root/old-bin:$PATH" "$BASH" "$compactor" "${compact_args[@]}" --dry-run
expect_rc 0
cat >"$tmp_root/old-bin/mv" <<'EOF'
#!/bin/sh
for arg do last=$arg; done
if [ "$last" = "$COMPAT_FAIL_DEST" ]; then exit 73; fi
exec "$COMPAT_REAL_MV" "$@"
EOF
chmod +x "$tmp_root/old-bin/mv"
run env PATH="$tmp_root/old-bin:$PATH" COMPAT_FAIL_DEST="$tmp_root/compact/archive.md" \
  COMPAT_REAL_MV="$(command -v mv)" "$BASH" "$compactor" "${compact_args[@]}"
expect_rc 3
rm "$tmp_root/old-bin/mv"
run env PATH="$tmp_root/old-bin:$PATH" "$BASH" "$compactor" "$tmp_root/compact/log.md" --recover
expect_rc 0
run "$BASH" "$checker" "$tmp_root/compact/log.md" --archive "$tmp_root/compact/archive.md" --manifest "$tmp_root/compact/manifest.md"
expect_rc 0

# Exercise the actual child wrapper with static shell fixtures, never documents.
awk '/^run_checker\(\) \{$/ { active = 1; starts++ } active { print } active && /^}$/ { active = 0 }
  END { if (starts != 1 || active) exit 1 }' "$compactor" >"$tmp_root/run-checker.sh"
for failure in missing returned; do
  source_file="$tmp_root/missing-checker.sh"
  expected=1
  if [[ "$failure" == returned ]]; then
    source_file="$tmp_root/returned-checker.sh"
    printf 'return 2\n' >"$source_file"
    expected=2
  fi
  run "$BASH" -c '
    source "$1"
    checker=$2
    destinations=(archive manifest log)
    run_checker strict input
  ' child-source "$tmp_root/run-checker.sh" "$source_file"
  expect_rc "$expected"
  check test "${output#*command not found}" = "$output"
done
printf 'Bash compatibility checks passed (%s assertions).\n' "$pass"

#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-load-contract-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp_root"
}

trap cleanup EXIT

assert_file_contains() {
  local file_path="$1"
  local expected_text="$2"

  if ! grep -Fqx "$expected_text" "$file_path"; then
    echo "Expected line not found in $file_path: $expected_text" >&2
    echo "File contents:" >&2
    sed -n '1,80p' "$file_path" >&2
    exit 1
  fi
}

assert_file_missing() {
  local file_path="$1"

  if [[ -e "$file_path" ]]; then
    echo "Expected file to be missing: $file_path" >&2
    exit 1
  fi
}

assert_output_contains() {
  local output="$1"
  local expected_text="$2"

  if [[ "$output" != *"$expected_text"* ]]; then
    echo "Expected output to contain: $expected_text" >&2
    echo "Output:" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

init_repo() {
  local repo_path="$1"

  mkdir -p "$repo_path"
  git -C "$repo_path" init >/dev/null
}

assert_file_contains "$repo_root/scaffold/agent-vault/CLAUDE.md" "@./lessons.md"
assert_file_contains "$repo_root/scaffold/agent-vault/GEMINI.md" "@./lessons.md"
assert_file_contains "$repo_root/scaffold/root/AGENTS.md" 'At session start, read `agent-vault/lessons.md` if it exists.'
assert_file_contains "$repo_root/scaffold/root/.cursor/rules/agent-vault.mdc" '<!-- agent-vault-managed: cursor-rule; file=.cursor/rules/agent-vault.mdc -->'
assert_file_contains "$repo_root/scaffold/root/.cursor/rules/agent-vault.mdc" 'alwaysApply: true'

generated_repo="$tmp_root/generated"
init_repo "$generated_repo"
"$repo_root/scripts/new-project.sh" "load-contract-test" "$generated_repo" >/dev/null

assert_file_contains "$generated_repo/agent-vault/CLAUDE.md" "@./lessons.md"
assert_file_contains "$generated_repo/agent-vault/GEMINI.md" "@./lessons.md"
assert_file_contains "$generated_repo/AGENTS.md" 'At session start, read `agent-vault/lessons.md` if it exists.'
assert_file_contains "$generated_repo/.cursor/rules/agent-vault.mdc" '<!-- agent-vault-managed: cursor-rule; file=.cursor/rules/agent-vault.mdc -->'
assert_file_contains "$generated_repo/.cursor/rules/agent-vault.mdc" 'alwaysApply: true'

perl -0pi -e 's/\Q@.\/lessons.md\E\n//' "$generated_repo/agent-vault/CLAUDE.md"
perl -0pi -e 's/\QAt session start, read `agent-vault\/lessons.md` if it exists.\E\n//' "$generated_repo/AGENTS.md"
printf '\nlocal cursor rule edit\n' >>"$generated_repo/.cursor/rules/agent-vault.mdc"
"$repo_root/scripts/update-project.sh" "$generated_repo" >/dev/null

assert_file_contains "$generated_repo/agent-vault/CLAUDE.md" "@./lessons.md"
assert_file_contains "$generated_repo/AGENTS.md" 'At session start, read `agent-vault/lessons.md` if it exists.'
assert_file_contains "$generated_repo/.cursor/rules/agent-vault.mdc" '<!-- agent-vault-managed: cursor-rule; file=.cursor/rules/agent-vault.mdc -->'

if grep -Fqx 'local cursor rule edit' "$generated_repo/.cursor/rules/agent-vault.mdc"; then
  echo "Expected update-project.sh to refresh managed Cursor rule." >&2
  exit 1
fi

dry_run_create_repo="$tmp_root/dry-run-create"
init_repo "$dry_run_create_repo"
"$repo_root/scripts/new-project.sh" "load-contract-test" "$dry_run_create_repo" >/dev/null
rm "$dry_run_create_repo/.cursor/rules/agent-vault.mdc"
dry_run_create_output="$("$repo_root/scripts/update-project.sh" "$dry_run_create_repo" --dry-run)"
assert_output_contains "$dry_run_create_output" "Create: .cursor/rules/agent-vault.mdc"
assert_file_missing "$dry_run_create_repo/.cursor/rules/agent-vault.mdc"

dry_run_update_repo="$tmp_root/dry-run-update"
init_repo "$dry_run_update_repo"
"$repo_root/scripts/new-project.sh" "load-contract-test" "$dry_run_update_repo" >/dev/null
printf '\nlocal cursor rule edit\n' >>"$dry_run_update_repo/.cursor/rules/agent-vault.mdc"
dry_run_update_output="$("$repo_root/scripts/update-project.sh" "$dry_run_update_repo" --dry-run)"
assert_output_contains "$dry_run_update_output" "Update: .cursor/rules/agent-vault.mdc"
assert_file_contains "$dry_run_update_repo/.cursor/rules/agent-vault.mdc" 'local cursor rule edit'

unmanaged_cursor_repo="$tmp_root/unmanaged-cursor"
init_repo "$unmanaged_cursor_repo"
mkdir -p "$unmanaged_cursor_repo/.cursor/rules"
printf '%s\n' 'custom cursor rule' >"$unmanaged_cursor_repo/.cursor/rules/agent-vault.mdc"
"$repo_root/scripts/new-project.sh" "load-contract-test" "$unmanaged_cursor_repo" >/dev/null
"$repo_root/scripts/update-project.sh" "$unmanaged_cursor_repo" >/dev/null
assert_file_contains "$unmanaged_cursor_repo/.cursor/rules/agent-vault.mdc" 'custom cursor rule'

"$repo_root/scripts/check-policy-mirrors.sh" >/dev/null

echo "session-start load contract regression checks passed."

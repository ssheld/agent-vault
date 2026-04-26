#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-coding-standards-test.XXXXXX")"
scaffold_coding_standards="$repo_root/scaffold/agent-vault/coding-standards.md"

cleanup() {
  rm -rf "$tmp_root"
}

trap cleanup EXIT

assert_output_contains() {
  local output="$1"
  local expected_text="$2"

  if [[ "$output" != *"$expected_text"* ]]; then
    echo "Expected text not found in command output: $expected_text" >&2
    echo "Actual output:" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

assert_file_exists() {
  local file_path="$1"

  if [[ ! -f "$file_path" ]]; then
    echo "Expected file not found: $file_path" >&2
    exit 1
  fi
}

assert_file_not_exists() {
  local file_path="$1"

  if [[ -e "$file_path" ]]; then
    echo "Expected path to be absent: $file_path" >&2
    exit 1
  fi
}

assert_file_contains() {
  local file_path="$1"
  local expected_text="$2"

  if [[ "$(cat "$file_path")" != *"$expected_text"* ]]; then
    echo "Expected text not found in file: $file_path" >&2
    echo "Missing text: $expected_text" >&2
    exit 1
  fi
}

assert_files_equal() {
  local left="$1"
  local right="$2"

  if ! cmp -s "$left" "$right"; then
    echo "Expected files to match:" >&2
    echo "  $left" >&2
    echo "  $right" >&2
    exit 1
  fi
}

init_repo() {
  local repo_path="$1"

  mkdir -p "$repo_path"
  git -C "$repo_path" init >/dev/null
}

find_coding_standards_backup() {
  local repo_path="$1"

  find "$repo_path/agent-vault/context/updates" -type f -path '*/agent-vault/coding-standards.md' | head -n1
}

project_owned_repo="$tmp_root/project-owned-by-default"
init_repo "$project_owned_repo"
"$repo_root/scripts/new-project.sh" "coding-standards-test" "$project_owned_repo" >/dev/null
cat <<'EOF' >"$project_owned_repo/agent-vault/coding-standards.md"
# Coding Standards

## Custom Rules
- Custom project-only rule.
- Keep existing runtime-specific guidance here.
EOF

default_output="$("$repo_root/scripts/update-project.sh" "$project_owned_repo" 2>&1)"
assert_output_contains "$default_output" "Skip: agent-vault/coding-standards.md (project-owned file differs from scaffold; review manually or use --sync-coding-standards to replace with backup)"
assert_output_contains "$default_output" "Warning: agent-vault/coding-standards.md differs from the scaffold and was left unchanged."
assert_output_contains "$default_output" "If you want the newer scaffold standards, merge them manually or rerun update-project.sh with --sync-coding-standards to replace the file with a backup."
assert_file_contains "$project_owned_repo/agent-vault/coding-standards.md" "Custom project-only rule."
assert_file_not_exists "$project_owned_repo/agent-vault/context/updates"

dry_run_output="$("$repo_root/scripts/update-project.sh" "$project_owned_repo" --dry-run --sync-coding-standards 2>&1)"
assert_output_contains "$dry_run_output" "Update: agent-vault/coding-standards.md (backup -> agent-vault/context/updates/"
assert_file_contains "$project_owned_repo/agent-vault/coding-standards.md" "Custom project-only rule."
assert_file_not_exists "$project_owned_repo/agent-vault/context/updates"

sync_output="$("$repo_root/scripts/update-project.sh" "$project_owned_repo" --sync-coding-standards 2>&1)"
assert_output_contains "$sync_output" "Updated: agent-vault/coding-standards.md"
assert_files_equal "$scaffold_coding_standards" "$project_owned_repo/agent-vault/coding-standards.md"
project_owned_backup="$(find_coding_standards_backup "$project_owned_repo")"
assert_file_exists "$project_owned_backup"
assert_file_contains "$project_owned_backup" "Custom project-only rule."

missing_repo="$tmp_root/missing-coding-standards"
init_repo "$missing_repo"
"$repo_root/scripts/new-project.sh" "coding-standards-test" "$missing_repo" >/dev/null
rm -f "$missing_repo/agent-vault/coding-standards.md"

missing_output="$("$repo_root/scripts/update-project.sh" "$missing_repo" 2>&1)"
assert_output_contains "$missing_output" "Skip: agent-vault/coding-standards.md (project-owned file missing; use --sync-coding-standards to seed from scaffold)"
assert_file_not_exists "$missing_repo/agent-vault/coding-standards.md"

missing_sync_output="$("$repo_root/scripts/update-project.sh" "$missing_repo" --sync-coding-standards 2>&1)"
assert_output_contains "$missing_sync_output" "Created: agent-vault/coding-standards.md"
assert_files_equal "$scaffold_coding_standards" "$missing_repo/agent-vault/coding-standards.md"

echo "coding standards sync regression checks passed."

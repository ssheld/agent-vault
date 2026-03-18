#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-decision-template-test.XXXXXX")"
scaffold_decision_template="$repo_root/scaffold/agent-vault/Templates/Decision Record.md"

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

assert_output_not_contains() {
  local output="$1"
  local unexpected_text="$2"

  if [[ "$output" == *"$unexpected_text"* ]]; then
    echo "Unexpected text found in command output: $unexpected_text" >&2
    echo "Actual output:" >&2
    printf '%s\n' "$output" >&2
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

assert_file_exists() {
  local file_path="$1"

  if [[ ! -f "$file_path" ]]; then
    echo "Expected file not found: $file_path" >&2
    exit 1
  fi
}

init_repo() {
  local repo_path="$1"

  mkdir -p "$repo_path"
  git -C "$repo_path" init >/dev/null
}

find_decision_template_backup() {
  local repo_path="$1"

  find "$repo_path/agent-vault/context/updates" -type f -path '*/agent-vault/Templates/Decision Record.md' | head -n1
}

repo_path="$tmp_root/policy-template-sync"
init_repo "$repo_path"
"$repo_root/scripts/new-project.sh" "template-sync-test" "$repo_path" >/dev/null

cat <<'EOF' > "$repo_path/agent-vault/Templates/Decision Record.md"
---
type: decision-record
id:
status: proposed
date:
updated:
project:
owners:
scope:
---

# Decision: <title>

## Context

## Decision

## Alternatives Considered
- Option A:
- Option B:

## Consequences
- Positive:
- Negative:

## Sources
-

## Follow-Up
- [ ] Task 1
- [ ] Update `agent-vault/decision-log.md`
EOF

cat <<'EOF' > "$repo_path/agent-vault/Templates/Daily Note.md"
# Custom Daily Template
EOF

dry_run_output="$("$repo_root/scripts/update-project.sh" "$repo_path" --dry-run 2>&1)"
assert_output_contains "$dry_run_output" "Update: agent-vault/Templates/Decision Record.md (backup -> agent-vault/context/updates/"
assert_output_not_contains "$dry_run_output" "agent-vault/Templates/Daily Note.md"
assert_file_contains "$repo_path/agent-vault/Templates/Decision Record.md" "## Alternatives Considered"
assert_file_contains "$repo_path/agent-vault/Templates/Daily Note.md" "# Custom Daily Template"

default_output="$("$repo_root/scripts/update-project.sh" "$repo_path" 2>&1)"
assert_output_contains "$default_output" "Updated: agent-vault/Templates/Decision Record.md"
assert_output_not_contains "$default_output" "agent-vault/Templates/Daily Note.md"
assert_files_equal "$scaffold_decision_template" "$repo_path/agent-vault/Templates/Decision Record.md"
assert_file_contains "$repo_path/agent-vault/Templates/Daily Note.md" "# Custom Daily Template"
decision_template_backup="$(find_decision_template_backup "$repo_path")"
assert_file_exists "$decision_template_backup"
assert_file_contains "$decision_template_backup" "## Alternatives Considered"

sync_templates_output="$("$repo_root/scripts/update-project.sh" "$repo_path" --dry-run --sync-templates 2>&1)"
assert_output_contains "$sync_templates_output" "Update: agent-vault/Templates/Daily Note.md (backup -> agent-vault/context/updates/"

echo "decision template sync regression checks passed."

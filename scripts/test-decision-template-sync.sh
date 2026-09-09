#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-decision-template-test.XXXXXX")"
scaffold_decision_template="$repo_root/scaffold/agent-vault/Templates/Decision Record.md"
note_templates=('Daily Note.md' 'Handoff Note.md' 'Plan.md')
canonical_paths=()
for template in "${note_templates[@]}"; do
  canonical_paths+=("agent-vault/Templates/$template")
done

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

stage_canonical_templates() {
  git -C "$repo_path" add -- "${canonical_paths[@]}"
  # Never include byte-exact historical backups in this whitespace assertion.
  git -C "$repo_path" -c core.whitespace=blank-at-eol diff --cached --check -- "${canonical_paths[@]}"
  local staged_path
  while IFS= read -r staged_path; do
    case "$staged_path" in
      'agent-vault/Templates/Daily Note.md' | 'agent-vault/Templates/Handoff Note.md' | 'agent-vault/Templates/Plan.md') ;;
      *)
        echo "Unexpected staged path: $staged_path" >&2
        exit 1
        ;;
    esac
  done < <(git -C "$repo_path" diff --cached --name-only)
}

repo_path="$tmp_root/policy-template-sync"
init_repo "$repo_path"
"$repo_root/scripts/new-project.sh" "template-sync-test" "$repo_path" >/dev/null
git -C "$repo_path" config user.name "Template Test"
git -C "$repo_path" config user.email "template-test@example.com"
for template in "${note_templates[@]}"; do
  assert_files_equal "$repo_root/scaffold/agent-vault/Templates/$template" "$repo_path/agent-vault/Templates/$template"
done
stage_canonical_templates
git -C "$repo_path" -c core.hooksPath=/dev/null commit -qm 'Fresh canonical templates'

cat <<'EOF' >"$repo_path/agent-vault/Templates/Decision Record.md"
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

cp "$repo_path/agent-vault/Templates/Decision Record.md" "$tmp_root/legacy-decision.md"
for template in "${note_templates[@]}"; do
  printf '# Custom %s\n\nHistorical whitespace must survive in backups. \t\n' "$template" >"$repo_path/agent-vault/Templates/$template"
  cp "$repo_path/agent-vault/Templates/$template" "$tmp_root/custom-$template"
done

dry_run_output="$("$repo_root/scripts/update-project.sh" "$repo_path" --dry-run 2>&1)"
assert_output_contains "$dry_run_output" "Update: agent-vault/Templates/Decision Record.md (backup -> agent-vault/context/updates/"
assert_files_equal "$tmp_root/legacy-decision.md" "$repo_path/agent-vault/Templates/Decision Record.md"
for template in "${note_templates[@]}"; do
  assert_output_not_contains "$dry_run_output" "agent-vault/Templates/$template"
  assert_files_equal "$tmp_root/custom-$template" "$repo_path/agent-vault/Templates/$template"
done

default_output="$("$repo_root/scripts/update-project.sh" "$repo_path" 2>&1)"
assert_output_contains "$default_output" "Updated: agent-vault/Templates/Decision Record.md"
assert_files_equal "$scaffold_decision_template" "$repo_path/agent-vault/Templates/Decision Record.md"
for template in "${note_templates[@]}"; do
  assert_output_not_contains "$default_output" "agent-vault/Templates/$template"
  assert_files_equal "$tmp_root/custom-$template" "$repo_path/agent-vault/Templates/$template"
done
decision_template_backup="$(find_decision_template_backup "$repo_path")"
assert_file_exists "$decision_template_backup"
assert_files_equal "$tmp_root/legacy-decision.md" "$decision_template_backup"

# Keep historical whitespace in the baseline so the final staged diff checks
# actual replacements, rather than matching the initial clean seed exactly.
git -C "$repo_path" add -- "${canonical_paths[@]}"
git -C "$repo_path" -c core.hooksPath=/dev/null commit -qm 'Project-owned template customizations'
backup_listing="$(find "$repo_path/agent-vault/context/updates" -type f | sort)"
sync_templates_output="$("$repo_root/scripts/update-project.sh" "$repo_path" --dry-run --sync-templates 2>&1)"
for template in "${note_templates[@]}"; do
  assert_output_contains "$sync_templates_output" "Update: agent-vault/Templates/$template (backup -> agent-vault/context/updates/"
  assert_files_equal "$tmp_root/custom-$template" "$repo_path/agent-vault/Templates/$template"
done
[[ "$backup_listing" == "$(find "$repo_path/agent-vault/context/updates" -type f | sort)" ]] || {
  echo "Template dry-run changed the backup listing." >&2
  exit 1
}

sync_templates_output="$("$repo_root/scripts/update-project.sh" "$repo_path" --sync-templates 2>&1)"
for template in "${note_templates[@]}"; do
  assert_output_contains "$sync_templates_output" "Updated: agent-vault/Templates/$template"
  assert_files_equal "$repo_root/scaffold/agent-vault/Templates/$template" "$repo_path/agent-vault/Templates/$template"
  backup="$(find "$repo_path/agent-vault/context/updates" -type f -path "*/agent-vault/Templates/$template" | head -n1)"
  assert_file_exists "$backup"
  assert_files_equal "$tmp_root/custom-$template" "$backup"
done
stage_canonical_templates
if git -C "$repo_path" diff --cached --quiet; then
  echo "Expected the synced canonical templates to change." >&2
  exit 1
fi

echo "decision and opt-in note template sync regression checks passed."

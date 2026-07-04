#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-context-log-policy-test.XXXXXX")"
scaffold_context_log="$repo_root/scaffold/agent-vault/context-log.md"
scaffold_context_log_template="$repo_root/scaffold/agent-vault/Templates/Context Log.md"
rule_marker="- Review-only / external-feedback exception:"

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

assert_rule_count() {
  local file_path="$1"
  local expected_count="$2"
  local actual_count

  actual_count="$(grep -cF -- "$rule_marker" "$file_path" || true)"
  if [[ "$actual_count" != "$expected_count" ]]; then
    echo "Expected $expected_count occurrence(s) of the review-only rule in $file_path; found $actual_count" >&2
    exit 1
  fi
}

assert_rule_inside_usage_rules() {
  local file_path="$1"
  local usage_line rule_line snapshot_line

  usage_line="$(grep -nE '^## Usage Rules$' "$file_path" | head -n1 | cut -d: -f1)"
  rule_line="$(grep -nF -- "$rule_marker" "$file_path" | head -n1 | cut -d: -f1)"
  snapshot_line="$(grep -nE '^## Current Snapshot$' "$file_path" | head -n1 | cut -d: -f1)"

  if [[ -z "$usage_line" || -z "$rule_line" || -z "$snapshot_line" ]]; then
    echo "Missing expected sections/rule in $file_path" >&2
    exit 1
  fi
  if [[ "$rule_line" -le "$usage_line" || "$rule_line" -ge "$snapshot_line" ]]; then
    echo "Review-only rule is not inside the Usage Rules section in $file_path (usage=$usage_line rule=$rule_line snapshot=$snapshot_line)" >&2
    exit 1
  fi
}

init_repo() {
  local repo_path="$1"

  mkdir -p "$repo_path"
  git -C "$repo_path" init >/dev/null
}

strip_rule_line() {
  local src="$1"
  local dest="$2"

  grep -vF -- "$rule_marker" "$src" >"$dest"
}

# Scaffold sources must carry the rule for the sync/migration to distribute.
assert_file_contains "$scaffold_context_log" "$rule_marker"
assert_file_contains "$scaffold_context_log_template" "$rule_marker"

# Case 1: a freshly generated project carries the rule in both the runtime
# context log and the template (install path needs no migration).
repo_path="$tmp_root/fresh-project"
init_repo "$repo_path"
"$repo_root/scripts/new-project.sh" "context-log-policy-test" "$repo_path" >/dev/null
assert_file_contains "$repo_path/agent-vault/context-log.md" "$rule_marker"
assert_file_contains "$repo_path/agent-vault/Templates/Context Log.md" "$rule_marker"
assert_rule_inside_usage_rules "$repo_path/agent-vault/context-log.md"

# Simulate a pre-existing project generated before the rule existed: strip the
# rule from the runtime log and the template, and add a project-owned template
# that normal updates must not touch.
strip_rule_line "$repo_path/agent-vault/context-log.md" "$repo_path/agent-vault/context-log.md.stripped"
mv "$repo_path/agent-vault/context-log.md.stripped" "$repo_path/agent-vault/context-log.md"
strip_rule_line "$repo_path/agent-vault/Templates/Context Log.md" "$repo_path/agent-vault/Templates/Context Log.md.stripped"
mv "$repo_path/agent-vault/Templates/Context Log.md.stripped" "$repo_path/agent-vault/Templates/Context Log.md"
cat <<'EOF' >"$repo_path/agent-vault/Templates/Daily Note.md"
# Custom Daily Template
EOF
cp "$repo_path/agent-vault/context-log.md" "$tmp_root/context-log-before-dry-run.md"

# Case 2: dry run reports both updates without writing anything.
dry_run_output="$("$repo_root/scripts/update-project.sh" "$repo_path" --dry-run 2>&1)"
assert_output_contains "$dry_run_output" "Update: agent-vault/context-log.md (backup -> agent-vault/context/updates/"
assert_output_contains "$dry_run_output" "Update: agent-vault/Templates/Context Log.md (backup -> agent-vault/context/updates/"
assert_output_not_contains "$dry_run_output" "agent-vault/Templates/Daily Note.md"
assert_files_equal "$repo_path/agent-vault/context-log.md" "$tmp_root/context-log-before-dry-run.md"
assert_rule_count "$repo_path/agent-vault/Templates/Context Log.md" 0

# Case 3: a normal update inserts the rule into the runtime Usage Rules,
# refreshes the policy template, and leaves project-owned templates alone.
default_output="$("$repo_root/scripts/update-project.sh" "$repo_path" 2>&1)"
assert_output_contains "$default_output" "Updated: agent-vault/context-log.md"
assert_output_contains "$default_output" "Updated: agent-vault/Templates/Context Log.md"
assert_output_not_contains "$default_output" "agent-vault/Templates/Daily Note.md"
assert_rule_count "$repo_path/agent-vault/context-log.md" 1
assert_rule_inside_usage_rules "$repo_path/agent-vault/context-log.md"
assert_files_equal "$scaffold_context_log_template" "$repo_path/agent-vault/Templates/Context Log.md"
assert_file_contains "$repo_path/agent-vault/Templates/Daily Note.md" "# Custom Daily Template"
context_log_backup="$(find "$repo_path/agent-vault/context/updates" -type f -path '*/agent-vault/context-log.md' | head -n1)"
assert_file_exists "$context_log_backup"
assert_rule_count "$context_log_backup" 0

# The surgical insert must not disturb the rest of the runtime log.
strip_rule_line "$repo_path/agent-vault/context-log.md" "$tmp_root/context-log-after-strip.md"
assert_files_equal "$tmp_root/context-log-after-strip.md" "$tmp_root/context-log-before-dry-run.md"

# Case 4: a second update is a no-op for the runtime log (idempotent).
second_output="$("$repo_root/scripts/update-project.sh" "$repo_path" 2>&1)"
assert_output_not_contains "$second_output" "Updated: agent-vault/context-log.md"
assert_rule_count "$repo_path/agent-vault/context-log.md" 1

# Case 5: a runtime log without a Usage Rules section is skipped with a notice
# and left unchanged.
no_rules_repo="$tmp_root/no-usage-rules-project"
init_repo "$no_rules_repo"
"$repo_root/scripts/new-project.sh" "context-log-no-rules-test" "$no_rules_repo" >/dev/null
cat <<'EOF' >"$no_rules_repo/agent-vault/context-log.md"
---
type: context-log
project: context-log-no-rules-test
last_updated: 2026-01-01
---

# Context Log

## Current Snapshot
- Project: context-log-no-rules-test
- Primary goal: Test fixture.
- Current status: Minimal layout without usage rules.
- Active branch: `main`
- Last updated: 2026-01-01

## Entries

### 2026-01-01 09:00 local - test - fixture entry
#### Goal
Fixture.
EOF
cp "$no_rules_repo/agent-vault/context-log.md" "$tmp_root/no-rules-before.md"
no_rules_output="$("$repo_root/scripts/update-project.sh" "$no_rules_repo" 2>&1)"
assert_output_contains "$no_rules_output" "Skip: agent-vault/context-log.md review-only usage rule"
assert_files_equal "$no_rules_repo/agent-vault/context-log.md" "$tmp_root/no-rules-before.md"

# Case 6: a legacy-layout log whose prefix carries `## Usage Rules` gets the
# layout migration but NOT the rule insert — the archived section below the new
# snapshot must stay untouched and the migration must skip with a notice.
legacy_repo="$tmp_root/legacy-usage-rules-project"
init_repo "$legacy_repo"
"$repo_root/scripts/new-project.sh" "context-log-legacy-test" "$legacy_repo" >/dev/null
cat <<'EOF' >"$legacy_repo/agent-vault/context-log.md"
---
type: context-log
project: context-log-legacy-test
last_updated: 2026-03-25
---

# Context Log

## Usage Rules
- Newest entry at top.
- Keep entries short and concrete.

### 2026-03-25 12:40 local — tightened PR #193 after review feedback
#### Goal
Preserve a real legacy entry shape with the older em-dash separator.

#### What Changed
- Stored current-session entries before the late snapshot block.

## Current Snapshot
- Project: context-log-legacy-test
- Primary goal: Preserve older generated context-log layout for migration testing.
- Current status: Legacy fixture with a usage-rules section in the prefix.
- Active branch: `main`
- Last updated: 2026-03-25

## Entries

### 2026-03-21 19:43 local - codex - older indexed entry
#### Goal
Preserve a historical indexed entry below the late `## Entries` heading.
EOF
legacy_output="$("$repo_root/scripts/update-project.sh" "$legacy_repo" 2>&1)"
assert_output_contains "$legacy_output" "Skip: agent-vault/context-log.md review-only usage rule"
assert_rule_count "$legacy_repo/agent-vault/context-log.md" 0
assert_file_contains "$legacy_repo/agent-vault/context-log.md" "## Legacy Unindexed Entries"

# Case 7: --sync-templates must not double-sync the policy-managed template.
strip_rule_line "$repo_path/agent-vault/Templates/Context Log.md" "$repo_path/agent-vault/Templates/Context Log.md.stripped"
mv "$repo_path/agent-vault/Templates/Context Log.md.stripped" "$repo_path/agent-vault/Templates/Context Log.md"
sync_templates_output="$("$repo_root/scripts/update-project.sh" "$repo_path" --sync-templates 2>&1)"
template_mention_count="$(printf '%s\n' "$sync_templates_output" | grep -cF "agent-vault/Templates/Context Log.md" || true)"
if [[ "$template_mention_count" != "1" ]]; then
  echo "Expected exactly 1 output line for agent-vault/Templates/Context Log.md under --sync-templates; found $template_mention_count" >&2
  printf '%s\n' "$sync_templates_output" >&2
  exit 1
fi
assert_output_contains "$sync_templates_output" "Updated: agent-vault/Templates/Context Log.md"
assert_files_equal "$scaffold_context_log_template" "$repo_path/agent-vault/Templates/Context Log.md"

# Case 8: a symlinked policy-managed template must fail the upfront preflight
# before any managed file or runtime migration is touched.
symlink_repo="$tmp_root/symlinked-template-project"
init_repo "$symlink_repo"
"$repo_root/scripts/new-project.sh" "context-log-symlink-test" "$symlink_repo" >/dev/null
strip_rule_line "$symlink_repo/agent-vault/context-log.md" "$symlink_repo/agent-vault/context-log.md.stripped"
mv "$symlink_repo/agent-vault/context-log.md.stripped" "$symlink_repo/agent-vault/context-log.md"
mv "$symlink_repo/agent-vault/Templates/Context Log.md" "$symlink_repo/agent-vault/context-log-template-target.md"
ln -s "../context-log-template-target.md" "$symlink_repo/agent-vault/Templates/Context Log.md"
symlink_rc=0
symlink_output="$("$repo_root/scripts/update-project.sh" "$symlink_repo" 2>&1)" || symlink_rc=$?
if [[ "$symlink_rc" -eq 0 ]]; then
  echo "Expected update-project.sh to fail on a symlinked Templates/Context Log.md" >&2
  printf '%s\n' "$symlink_output" >&2
  exit 1
fi
assert_output_contains "$symlink_output" "managed file is a symlink, refusing to update: agent-vault/Templates/Context Log.md"
assert_output_not_contains "$symlink_output" "Updated:"
assert_rule_count "$symlink_repo/agent-vault/context-log.md" 0
if [[ -d "$symlink_repo/agent-vault/context/updates" ]]; then
  echo "Expected no backup directory after a failed preflight" >&2
  exit 1
fi

echo "context-log policy sync regression checks passed."

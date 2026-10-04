#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-context-log-policy-test.XXXXXX")"
scaffold_context_log="$repo_root/scaffold/agent-vault/context-log.md"
scaffold_context_log_template="$repo_root/scaffold/agent-vault/Templates/Context Log.md"
rule_marker="- Review-only / external-feedback exception:"
heading_marker="- Entry headings must start with"
# Every wording of the entry-heading rule the scaffold shipped before the
# current one (issue #181), oldest first.
earlier_heading_rules=(
  '- Entry headings must start with `YYYY-MM-DD HH:MM local - <agent> - <topic>`.'
  '- Entry headings must start with `YYYY-MM-DD HH:MM local - <agent> - <topic>`. A timezone abbreviation such as `EDT` or `ChST`, or a numeric UTC offset such as `+0545`, may replace `local`.'
)

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

# Replace the entry-heading usage rule in a runtime log with another wording.
set_heading_rule() {
  local file_path="$1"

  HEADING_MARKER="$heading_marker" HEADING_RULE="$2" awk '
    index($0, ENVIRON["HEADING_MARKER"]) == 1 && !done { print ENVIRON["HEADING_RULE"]; done = 1; next }
    { print }
  ' "$file_path" >"$file_path.heading"
  mv "$file_path.heading" "$file_path"
}

assert_heading_rule_count() {
  local file_path="$1"
  local wording="$2"
  local expected_count="$3"
  local actual_count

  actual_count="$(grep -cFx -- "$wording" "$file_path" || true)"
  if [[ "$actual_count" != "$expected_count" ]]; then
    echo "Expected $expected_count line(s) reading [$wording] in $file_path; found $actual_count" >&2
    exit 1
  fi
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

# --- Entry-heading usage rule migration (issue #181) --------------------------
current_heading_rule="$(grep -m1 -F -- "$heading_marker" "$scaffold_context_log")"
if [[ "$current_heading_rule" != *"date '+%Y-%m-%d %H:%M %z'"* ]]; then
  echo "Expected the scaffold entry-heading rule to give the numeric-offset date command" >&2
  exit 1
fi
assert_heading_rule_count "$scaffold_context_log_template" "$current_heading_rule" 1
for earlier_rule in "${earlier_heading_rules[@]}"; do
  if [[ "$earlier_rule" == "$current_heading_rule" ]]; then
    echo "An earlier heading rule must differ from the current scaffold rule" >&2
    exit 1
  fi
done

# Case 9: each earlier scaffold wording is replaced, in a project that already
# carries the review-only rule (the state that used to end the migration early).
# The rest of the log is untouched, and a second run changes nothing.
earlier_index=0
for earlier_rule in "${earlier_heading_rules[@]}"; do
  earlier_index=$((earlier_index + 1))
  heading_repo="$tmp_root/heading-rule-$earlier_index"
  init_repo "$heading_repo"
  "$repo_root/scripts/new-project.sh" "heading-rule-test" "$heading_repo" >/dev/null
  cp "$heading_repo/agent-vault/context-log.md" "$tmp_root/heading-rule-fresh.md"
  set_heading_rule "$heading_repo/agent-vault/context-log.md" "$earlier_rule"
  assert_heading_rule_count "$heading_repo/agent-vault/context-log.md" "$earlier_rule" 1
  assert_rule_count "$heading_repo/agent-vault/context-log.md" 1
  cp "$heading_repo/agent-vault/context-log.md" "$tmp_root/heading-rule-before.md"

  heading_dry_run_output="$("$repo_root/scripts/update-project.sh" "$heading_repo" --dry-run 2>&1)"
  assert_output_contains "$heading_dry_run_output" "Update: agent-vault/context-log.md (backup -> agent-vault/context/updates/"
  assert_files_equal "$heading_repo/agent-vault/context-log.md" "$tmp_root/heading-rule-before.md"

  heading_output="$("$repo_root/scripts/update-project.sh" "$heading_repo" 2>&1)"
  assert_output_contains "$heading_output" "Updated: agent-vault/context-log.md"
  assert_files_equal "$heading_repo/agent-vault/context-log.md" "$tmp_root/heading-rule-fresh.md"
  assert_rule_count "$heading_repo/agent-vault/context-log.md" 1
  heading_backup="$(find "$heading_repo/agent-vault/context/updates" -type f -path '*/agent-vault/context-log.md' | head -n1)"
  assert_files_equal "$heading_backup" "$tmp_root/heading-rule-before.md"

  heading_second_output="$("$repo_root/scripts/update-project.sh" "$heading_repo" 2>&1)"
  assert_output_not_contains "$heading_second_output" "agent-vault/context-log.md"
  assert_files_equal "$heading_repo/agent-vault/context-log.md" "$tmp_root/heading-rule-fresh.md"
done

# Case 10: both edits land in one replacement, so the backup is the original
# file, not a half-migrated one.
both_repo="$tmp_root/heading-and-review-rules"
init_repo "$both_repo"
"$repo_root/scripts/new-project.sh" "heading-rule-test" "$both_repo" >/dev/null
cp "$both_repo/agent-vault/context-log.md" "$tmp_root/both-rules-fresh.md"
set_heading_rule "$both_repo/agent-vault/context-log.md" "${earlier_heading_rules[0]}"
strip_rule_line "$both_repo/agent-vault/context-log.md" "$both_repo/agent-vault/context-log.md.stripped"
mv "$both_repo/agent-vault/context-log.md.stripped" "$both_repo/agent-vault/context-log.md"
cp "$both_repo/agent-vault/context-log.md" "$tmp_root/both-rules-before.md"
both_output="$("$repo_root/scripts/update-project.sh" "$both_repo" 2>&1)"
both_update_count="$(printf '%s\n' "$both_output" | grep -cF "Updated: agent-vault/context-log.md" || true)"
if [[ "$both_update_count" != "1" ]]; then
  echo "Expected exactly 1 update of agent-vault/context-log.md; found $both_update_count" >&2
  printf '%s\n' "$both_output" >&2
  exit 1
fi
assert_files_equal "$both_repo/agent-vault/context-log.md" "$tmp_root/both-rules-fresh.md"
both_backup="$(find "$both_repo/agent-vault/context/updates" -type f -path '*/agent-vault/context-log.md' | head -n1)"
assert_files_equal "$both_backup" "$tmp_root/both-rules-before.md"

# Case 11: a customized heading rule is left alone and reported, on every run.
custom_repo="$tmp_root/heading-rule-custom"
init_repo "$custom_repo"
"$repo_root/scripts/new-project.sh" "heading-rule-test" "$custom_repo" >/dev/null
set_heading_rule "$custom_repo/agent-vault/context-log.md" \
  '- Entry headings must start with `YYYY-MM-DD HH:MM local - <agent> - <topic>`, and name the ticket.'
cp "$custom_repo/agent-vault/context-log.md" "$tmp_root/heading-rule-custom-before.md"
assert_custom_heading_rule_kept() {
  custom_output="$("$repo_root/scripts/update-project.sh" "$custom_repo" 2>&1)"
  assert_output_contains "$custom_output" "Skip: agent-vault/context-log.md entry-heading usage rule (customized wording left unchanged"
  assert_output_not_contains "$custom_output" "Updated: agent-vault/context-log.md"
  assert_files_equal "$custom_repo/agent-vault/context-log.md" "$tmp_root/heading-rule-custom-before.md"
}
assert_custom_heading_rule_kept
assert_custom_heading_rule_kept

# Case 12: a customized heading rule does not hold back the review-only rule.
strip_rule_line "$custom_repo/agent-vault/context-log.md" "$custom_repo/agent-vault/context-log.md.stripped"
mv "$custom_repo/agent-vault/context-log.md.stripped" "$custom_repo/agent-vault/context-log.md"
custom_review_output="$("$repo_root/scripts/update-project.sh" "$custom_repo" 2>&1)"
assert_output_contains "$custom_review_output" "Skip: agent-vault/context-log.md entry-heading usage rule (customized wording left unchanged"
assert_output_contains "$custom_review_output" "Updated: agent-vault/context-log.md"
assert_rule_count "$custom_repo/agent-vault/context-log.md" 1
assert_files_equal "$custom_repo/agent-vault/context-log.md" "$tmp_root/heading-rule-custom-before.md"

# Case 13: a log with no entry-heading rule is reported and left unchanged.
missing_rule_repo="$tmp_root/heading-rule-missing"
init_repo "$missing_rule_repo"
"$repo_root/scripts/new-project.sh" "heading-rule-test" "$missing_rule_repo" >/dev/null
grep -vF -- "$heading_marker" "$missing_rule_repo/agent-vault/context-log.md" >"$tmp_root/heading-rule-missing-before.md"
cp "$tmp_root/heading-rule-missing-before.md" "$missing_rule_repo/agent-vault/context-log.md"
missing_rule_output="$("$repo_root/scripts/update-project.sh" "$missing_rule_repo" 2>&1)"
assert_output_contains "$missing_rule_output" "Skip: agent-vault/context-log.md entry-heading usage rule (no entry-heading rule in the active"
assert_files_equal "$missing_rule_repo/agent-vault/context-log.md" "$tmp_root/heading-rule-missing-before.md"

# Case 14: only the ACTIVE usage rules are edited. An earlier wording quoted in
# an entry body, or sitting in a historical section below the snapshot, stays.
historical_repo="$tmp_root/heading-rule-historical"
init_repo "$historical_repo"
"$repo_root/scripts/new-project.sh" "heading-rule-test" "$historical_repo" >/dev/null
set_heading_rule "$historical_repo/agent-vault/context-log.md" "${earlier_heading_rules[1]}"
{
  printf '\n#### Notes\n%s\n' "${earlier_heading_rules[0]}"
  printf '\n## Historical Usage Rules\n%s\n' "${earlier_heading_rules[1]}"
} >>"$historical_repo/agent-vault/context-log.md"
"$repo_root/scripts/update-project.sh" "$historical_repo" >/dev/null 2>&1
assert_heading_rule_count "$historical_repo/agent-vault/context-log.md" "$current_heading_rule" 1
assert_heading_rule_count "$historical_repo/agent-vault/context-log.md" "${earlier_heading_rules[0]}" 1
assert_heading_rule_count "$historical_repo/agent-vault/context-log.md" "${earlier_heading_rules[1]}" 1

# Case 15: the legacy-layout log from case 6 has its only `## Usage Rules`
# below the new snapshot. Its heading-rule line, if any, is historical too.
assert_output_not_contains "$legacy_output" "entry-heading usage rule"

echo "context-log policy sync regression checks passed."

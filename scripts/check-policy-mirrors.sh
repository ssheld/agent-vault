#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"

extract_from_heading() {
  local file_path="$1"
  local heading="$2"

  awk -v heading="$heading" '
    {
      sub(/\r$/, "", $0)
    }
    $0 == heading {
      capture = 1
    }
    capture {
      print
    }
  ' "$file_path"
}

compare_mirrored_sections() {
  local check_label="$1"
  local left_rel_path="$2"
  local left_heading="$3"
  local right_rel_path="$4"
  local right_heading="$5"
  local left_file="$repo_root/$left_rel_path"
  local right_file="$repo_root/$right_rel_path"
  local left_block=""
  local right_block=""
  local diff_output=""

  if [[ ! -f "$left_file" ]]; then
    echo "Error: missing file for mirror check: $left_rel_path" >&2
    return 1
  fi

  if [[ ! -f "$right_file" ]]; then
    echo "Error: missing file for mirror check: $right_rel_path" >&2
    return 1
  fi

  left_block="$(extract_from_heading "$left_file" "$left_heading")"
  right_block="$(extract_from_heading "$right_file" "$right_heading")"

  if [[ -z "$left_block" ]]; then
    echo "Error: heading '$left_heading' not found in $left_rel_path" >&2
    return 1
  fi

  if [[ -z "$right_block" ]]; then
    echo "Error: heading '$right_heading' not found in $right_rel_path" >&2
    return 1
  fi

  if ! diff_output="$(diff -u <(printf '%s\n' "$left_block") <(printf '%s\n' "$right_block"))"; then
    echo "Drift detected: $check_label" >&2
    printf '%s\n' "$diff_output"
    return 1
  fi

  echo "OK: $check_label"
}

status=0

compare_mirrored_sections \
  "scaffold/root/AGENTS.md review policy block mirrors scaffold/agent-vault/review-policy.md" \
  "scaffold/root/AGENTS.md" \
  "## Review Guidelines (for automated code review agents)" \
  "scaffold/agent-vault/review-policy.md" \
  "## Review Guidelines (for automated code review agents)" || status=1

compare_mirrored_sections \
  "scaffold/agent-vault/AGENTS.md shared workflow block mirrors scaffold/agent-vault/shared-rules.md" \
  "scaffold/agent-vault/AGENTS.md" \
  "## PR Feedback Response" \
  "scaffold/agent-vault/shared-rules.md" \
  "## PR Feedback Response" || status=1

if [[ "$status" -ne 0 ]]; then
  echo "Policy mirror drift detected. Update mirrored files together." >&2
  exit 1
fi

echo "Policy mirror check passed."

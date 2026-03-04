#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"

extract_from_heading() {
  local file_path="$1"
  local heading="$2"
  local range_mode="${3:-section}"
  local heading_level=""

  if [[ "$range_mode" != "section" && "$range_mode" != "to_eof" ]]; then
    echo "Error: unknown heading extraction mode: $range_mode" >&2
    return 1
  fi

  if [[ "$range_mode" == "section" ]]; then
    heading_level="$(printf '%s\n' "$heading" | sed -E 's/^(#+).*/\1/' | awk '{ print length($0) }')"
    if [[ "$heading_level" -le 0 ]]; then
      echo "Error: heading must start with markdown # characters: $heading" >&2
      return 1
    fi
  fi

  awk -v heading="$heading" -v range_mode="$range_mode" -v heading_level="$heading_level" '
    {
      sub(/\r$/, "", $0)
    }
    !capture && $0 == heading {
      capture = 1
      print
      next
    }
    capture {
      if (range_mode == "section" && $0 ~ /^#+[[:space:]]/) {
        heading_marks = $0
        sub(/[[:space:]].*$/, "", heading_marks)
        if (length(heading_marks) <= heading_level) {
          exit
        }
      }
      print
    }
  ' "$file_path"
}

normalize_block() {
  local block="$1"
  local mode="${2:-none}"

  case "$mode" in
    none)
      printf '%s\n' "$block"
      ;;
    review_policy_path_alias)
      printf '%s\n' "$block" | sed 's#scaffold/agent-vault/review-policy\.md#agent-vault/review-policy.md#g'
      ;;
    *)
      echo "Error: unknown normalization mode: $mode" >&2
      return 1
      ;;
  esac
}

compare_mirrored_sections() {
  local check_label="$1"
  local left_rel_path="$2"
  local left_heading="$3"
  local right_rel_path="$4"
  local right_heading="$5"
  local extraction_mode="${6:-section}"
  local normalization_mode="${7:-none}"
  local left_file="$repo_root/$left_rel_path"
  local right_file="$repo_root/$right_rel_path"
  local left_block=""
  local right_block=""
  local normalized_left_block=""
  local normalized_right_block=""
  local diff_output=""

  if [[ ! -f "$left_file" ]]; then
    echo "Error: missing file for mirror check: $left_rel_path" >&2
    return 1
  fi

  if [[ ! -f "$right_file" ]]; then
    echo "Error: missing file for mirror check: $right_rel_path" >&2
    return 1
  fi

  left_block="$(extract_from_heading "$left_file" "$left_heading" "$extraction_mode")"
  right_block="$(extract_from_heading "$right_file" "$right_heading" "$extraction_mode")"

  if [[ -z "$left_block" ]]; then
    echo "Error: heading '$left_heading' not found in $left_rel_path" >&2
    return 1
  fi

  if [[ -z "$right_block" ]]; then
    echo "Error: heading '$right_heading' not found in $right_rel_path" >&2
    return 1
  fi

  normalized_left_block="$(normalize_block "$left_block" "$normalization_mode")"
  normalized_right_block="$(normalize_block "$right_block" "$normalization_mode")"

  if ! diff_output="$(diff -u <(printf '%s\n' "$normalized_left_block") <(printf '%s\n' "$normalized_right_block"))"; then
    echo "Drift detected: $check_label" >&2
    printf '%s\n' "$diff_output"
    return 1
  fi

  echo "OK: $check_label"
}

status=0

compare_mirrored_sections \
  "scaffold/root/AGENTS.md review policy block mirrors scaffold/agent-vault/review-policy.md (full mirrored range)" \
  "scaffold/root/AGENTS.md" \
  "## Review Guidelines (for automated code review agents)" \
  "scaffold/agent-vault/review-policy.md" \
  "## Review Guidelines (for automated code review agents)" \
  "to_eof" || status=1

compare_mirrored_sections \
  "scaffold/agent-vault/AGENTS.md shared workflow block mirrors scaffold/agent-vault/shared-rules.md (full mirrored range)" \
  "scaffold/agent-vault/AGENTS.md" \
  "## PR Feedback Response" \
  "scaffold/agent-vault/shared-rules.md" \
  "## PR Feedback Response" \
  "to_eof" || status=1

compare_mirrored_sections \
  "AGENTS.md review policy block mirrors scaffold/agent-vault/review-policy.md (full mirrored range; normalized for repo-local path alias)" \
  "AGENTS.md" \
  "## Review Guidelines (for automated code review agents)" \
  "scaffold/agent-vault/review-policy.md" \
  "## Review Guidelines (for automated code review agents)" \
  "to_eof" \
  "review_policy_path_alias" || status=1

if [[ "$status" -ne 0 ]]; then
  echo "Policy mirror drift detected. Update mirrored files together." >&2
  exit 1
fi

echo "Policy mirror check passed."

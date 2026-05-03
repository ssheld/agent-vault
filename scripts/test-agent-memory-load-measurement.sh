#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-memory-load-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp_root"
}

trap cleanup EXIT

assert_file_exists() {
  local file_path="$1"

  if [[ ! -f "$file_path" ]]; then
    echo "Expected file does not exist: $file_path" >&2
    exit 1
  fi
}

assert_file_contains() {
  local file_path="$1"
  local expected_text="$2"

  if ! grep -Fq "$expected_text" "$file_path"; then
    echo "Expected text not found in $file_path: $expected_text" >&2
    exit 1
  fi
}

assert_line_count() {
  local file_path="$1"
  local expected_count="$2"
  local actual_count

  actual_count="$(awk 'END { print NR }' "$file_path")"
  if [[ "$actual_count" != "$expected_count" ]]; then
    echo "Expected $expected_count lines in $file_path, found $actual_count." >&2
    exit 1
  fi
}

output_dir="$tmp_root/measurement"
"$repo_root/scripts/measure-agent-memory-load.sh" --output-dir "$output_dir" --skip-codex >/dev/null

manifest_path="$output_dir/sentinel-manifest.tsv"
codex_table_path="$output_dir/codex-startup-context.tsv"
protocol_prompt="$output_dir/prompts/protocol-following-prompt.md"
behavior_prompt="$output_dir/prompts/behavioral-recall-prompt.md"

assert_file_exists "$manifest_path"
assert_file_exists "$codex_table_path"
assert_file_exists "$protocol_prompt"
assert_file_exists "$behavior_prompt"
assert_file_exists "$output_dir/generated-repo/AGENTS.md"
assert_file_exists "$output_dir/generated-repo/agent-vault/lessons.md"

assert_line_count "$manifest_path" "10"
assert_line_count "$codex_table_path" "28"
assert_file_contains "$codex_table_path" $'codex\trepo-root'
assert_file_contains "$codex_table_path" "not_run"
assert_file_contains "$protocol_prompt" "Protocol-Following Probe"
assert_file_contains "$behavior_prompt" "measurement answer for each label"

{
  read -r _header
  while IFS=$'\t' read -r relative_path _label sentinel behavior_answer _bytes _lines; do
    [[ -n "$relative_path" ]] || continue
    assert_file_contains "$output_dir/generated-repo/$relative_path" "$sentinel"
    assert_file_contains "$output_dir/generated-repo/$relative_path" "$behavior_answer"
  done
} <"$manifest_path"

echo "agent memory-load measurement fixture checks passed."

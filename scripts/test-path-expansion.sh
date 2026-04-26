#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-path-expansion-test.XXXXXX")"

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

assert_path_not_exists() {
  local path="$1"

  if [[ -e "$path" ]]; then
    echo "Expected path to be absent: $path" >&2
    exit 1
  fi
}

init_repo() {
  local repo_path="$1"

  mkdir -p "$repo_path"
  git -C "$repo_path" init >/dev/null
}

fake_home="$tmp_root/home"
mkdir -p "$fake_home/workspaces"

new_project_tilde_repo="$fake_home/workspaces/new-project-tilde"
init_repo "$new_project_tilde_repo"
# shellcheck disable=SC2088 # Intentionally pass literal ~/ for expand_path coverage.
HOME="$fake_home" "$repo_root/scripts/new-project.sh" "path-expansion-test" "~/workspaces/new-project-tilde" >/dev/null
assert_file_exists "$new_project_tilde_repo/agent-vault/README.md"
assert_path_not_exists "$fake_home/~/workspaces/new-project-tilde"

new_project_home_repo="$tmp_root/home-repo"
init_repo "$new_project_home_repo"
HOME="$new_project_home_repo" "$repo_root/scripts/new-project.sh" "path-expansion-test" "~" >/dev/null
assert_file_exists "$new_project_home_repo/agent-vault/README.md"

new_project_typo_repo="$fake_home/workspaces/new-project-typo"
init_repo "$new_project_typo_repo"
typo_output="$(HOME="$fake_home" "$repo_root/scripts/new-project.sh" "path-expansion-test" "/~/workspaces/new-project-typo" 2>&1)"
assert_output_contains "$typo_output" "Warning: interpreted '/~/workspaces/new-project-typo' as '$new_project_typo_repo'."
assert_file_exists "$new_project_typo_repo/agent-vault/README.md"

update_project_absolute_repo="$fake_home/workspaces/update-absolute"
init_repo "$update_project_absolute_repo"
"$repo_root/scripts/new-project.sh" "path-expansion-test" "$update_project_absolute_repo" >/dev/null
"$repo_root/scripts/update-project.sh" "$update_project_absolute_repo" --dry-run >/dev/null
assert_file_exists "$update_project_absolute_repo/agent-vault/README.md"

update_project_tilde_repo="$fake_home/workspaces/update-tilde"
init_repo "$update_project_tilde_repo"
"$repo_root/scripts/new-project.sh" "path-expansion-test" "$update_project_tilde_repo" >/dev/null
# shellcheck disable=SC2088 # Intentionally pass literal ~/ for expand_path coverage.
HOME="$fake_home" "$repo_root/scripts/update-project.sh" "~/workspaces/update-tilde" --dry-run >/dev/null
assert_file_exists "$update_project_tilde_repo/agent-vault/README.md"
assert_path_not_exists "$fake_home/~/workspaces/update-tilde"

update_project_home_repo="$tmp_root/update-home-repo"
init_repo "$update_project_home_repo"
"$repo_root/scripts/new-project.sh" "path-expansion-test" "$update_project_home_repo" >/dev/null
HOME="$update_project_home_repo" "$repo_root/scripts/update-project.sh" "~" --dry-run >/dev/null
assert_file_exists "$update_project_home_repo/agent-vault/README.md"

update_project_typo_repo="$fake_home/workspaces/update-typo"
init_repo "$update_project_typo_repo"
"$repo_root/scripts/new-project.sh" "path-expansion-test" "$update_project_typo_repo" >/dev/null
update_typo_output="$(HOME="$fake_home" "$repo_root/scripts/update-project.sh" "/~/workspaces/update-typo" --dry-run 2>&1)"
assert_output_contains "$update_typo_output" "Warning: interpreted '/~/workspaces/update-typo' as '$update_project_typo_repo'."
assert_file_exists "$update_project_typo_repo/agent-vault/README.md"

echo "path expansion regression checks passed."

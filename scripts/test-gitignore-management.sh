#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-gitignore-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp_root"
}

trap cleanup EXIT

assert_has_line() {
  local file_path="$1"
  local expected_line="$2"

  if ! awk -v target="$expected_line" '
    {
      sub(/\r$/, "", $0)
      if ($0 == target) {
        found = 1
        exit
      }
    }
    END {
      exit found ? 0 : 1
    }
  ' "$file_path"; then
    echo "Expected line not found in $file_path: $expected_line" >&2
    exit 1
  fi
}

assert_not_has_line() {
  local file_path="$1"
  local unexpected_line="$2"

  if awk -v target="$unexpected_line" '
    {
      sub(/\r$/, "", $0)
      if ($0 == target) {
        found = 1
        exit
      }
    }
    END {
      exit found ? 0 : 1
    }
  ' "$file_path"; then
    echo "Unexpected line found in $file_path: $unexpected_line" >&2
    exit 1
  fi
}

assert_line_count() {
  local file_path="$1"
  local target_line="$2"
  local expected_count="$3"
  local actual_count

  actual_count="$(awk -v target="$target_line" '
    BEGIN { count = 0 }
    {
      sub(/\r$/, "", $0)
      if ($0 == target) {
        count++
      }
    }
    END { print count }
  ' "$file_path")"

  if [[ "$actual_count" != "$expected_count" ]]; then
    echo "Expected $expected_count copies of '$target_line' in $file_path, found $actual_count" >&2
    exit 1
  fi
}

init_repo() {
  local repo_path="$1"

  mkdir -p "$repo_path"
  git -C "$repo_path" init >/dev/null
}

write_legacy_gitignore() {
  local repo_path="$1"

  cat <<'EOF' > "$repo_path/.gitignore"
.obsidian/workspace.json
.obsidian/app.json
.obsidian/appearance.json
.obsidian/workspace-mobile.json
.obsidian/cache/
.obsidian/backup/
.obsidian/plugins/*/data.json
EOF
}

write_partial_obsidian_gitignore() {
  local repo_path="$1"

  cat <<'EOF' > "$repo_path/.gitignore"
.obsidian/workspace.json
.obsidian/app.json
EOF
}

assert_no_dangling_comment_append() {
  local file_path="$1"

  assert_not_has_line "$file_path" "# Obsidian -- machine-specific & volatile files (ignore these)"
  assert_not_has_line "$file_path" "# Plugin data (can contain API keys or large caches)"
  assert_has_line "$file_path" "# Agent Vault -- local sync and migration backups (ignore these)"
  assert_has_line "$file_path" "/agent-vault/context/updates/"
}

assert_grouped_partial_block_insert() {
  local file_path="$1"

  assert_has_line "$file_path" "# Obsidian -- machine-specific & volatile files (ignore these)"
  assert_has_line "$file_path" ".obsidian/appearance.json"
  assert_has_line "$file_path" ".obsidian/workspace-mobile.json"
  assert_has_line "$file_path" ".obsidian/cache/"
  assert_has_line "$file_path" ".obsidian/backup/"
  assert_line_count "$file_path" ".obsidian/workspace.json" 1
  assert_line_count "$file_path" ".obsidian/app.json" 1
}

new_project_repo="$tmp_root/new-project-existing-patterns"
init_repo "$new_project_repo"
write_legacy_gitignore "$new_project_repo"
"$repo_root/scripts/new-project.sh" "gitignore-test" "$new_project_repo" >/dev/null
assert_no_dangling_comment_append "$new_project_repo/.gitignore"

new_project_partial_repo="$tmp_root/new-project-partial-patterns"
init_repo "$new_project_partial_repo"
write_partial_obsidian_gitignore "$new_project_partial_repo"
"$repo_root/scripts/new-project.sh" "gitignore-test" "$new_project_partial_repo" >/dev/null
assert_grouped_partial_block_insert "$new_project_partial_repo/.gitignore"

update_project_repo="$tmp_root/update-project-existing-patterns"
init_repo "$update_project_repo"
"$repo_root/scripts/new-project.sh" "gitignore-test" "$update_project_repo" >/dev/null
write_legacy_gitignore "$update_project_repo"
"$repo_root/scripts/update-project.sh" "$update_project_repo" >/dev/null
assert_no_dangling_comment_append "$update_project_repo/.gitignore"

update_project_partial_repo="$tmp_root/update-project-partial-patterns"
init_repo "$update_project_partial_repo"
"$repo_root/scripts/new-project.sh" "gitignore-test" "$update_project_partial_repo" >/dev/null
write_partial_obsidian_gitignore "$update_project_partial_repo"
"$repo_root/scripts/update-project.sh" "$update_project_partial_repo" >/dev/null
assert_grouped_partial_block_insert "$update_project_partial_repo/.gitignore"

echo "gitignore management regression checks passed."

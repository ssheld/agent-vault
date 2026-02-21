#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 <project-name> <repo-path> [--migrate-existing-root-md]"
  echo "Example: $0 payments-api ~/workspaces/payments-api --migrate-existing-root-md"
}

expand_path() {
  local p="$1"
  case "$p" in
    "~")
      printf '%s\n' "$HOME"
      ;;
    "~/"*)
      printf '%s/%s\n' "$HOME" "${p#~/}"
      ;;
    "/~/"*)
      # Common typo: /~/path should usually be ~/path.
      printf '%s/%s\n' "$HOME" "${p#/~/}"
      ;;
    *)
      printf '%s\n' "$p"
      ;;
  esac
}

find_existing_root_file() {
  local repo_root="$1"
  local canonical_name="$2"
  local count=0
  local first_match=""
  local candidate

  while IFS= read -r candidate; do
    count=$((count + 1))
    if [[ "$count" -eq 1 ]]; then
      first_match="$candidate"
    fi
  done < <(find "$repo_root" -maxdepth 1 \( -type f -o -type l \) -iname "$canonical_name" -print | LC_ALL=C sort)

  if [[ "$count" -gt 1 ]]; then
    echo "Error: multiple root files match $canonical_name in $repo_root." >&2
    echo "Delete duplicates and rerun new-project.sh." >&2
    exit 1
  fi

  if [[ "$count" -eq 1 ]]; then
    printf '%s\n' "$first_match"
    return 0
  fi

  return 1
}

append_migrated_root_content() {
  local source_path="$1"
  local destination_path="$2"
  local canonical_name="$3"
  local source_rel="$4"
  local migrated_at="$5"

  {
    printf '\n\n## Migrated Legacy %s (%s)\n\n' "$canonical_name" "$migrated_at"
    printf 'Source file: `%s`\n\n' "$source_rel"
    printf '```md\n'
    cat "$source_path"
    printf '\n```\n'
  } >> "$destination_path"
}

OBSIDIAN_GITIGNORE_LINES=(
  "# Obsidian -- machine-specific & volatile files (ignore these)"
  ".obsidian/workspace.json"
  ".obsidian/app.json"
  ".obsidian/appearance.json"
  ".obsidian/workspace-mobile.json"
  ".obsidian/cache/"
  ".obsidian/backup/"
  "# Plugin data (can contain API keys or large caches)"
  ".obsidian/plugins/*/data.json"
)

ROOT_AGENTS_MARKER="<!-- agent-vault-managed: root-wrapper; file=AGENTS.md -->"
ROOT_CLAUDE_MARKER="<!-- agent-vault-managed: root-wrapper; file=CLAUDE.md -->"
ROOT_GEMINI_MARKER="<!-- agent-vault-managed: root-wrapper; file=GEMINI.md -->"

ensure_obsidian_gitignore() {
  local repo_root="$1"
  local gitignore_path="$repo_root/.gitignore"
  local added_count=0
  local line

  if [[ -L "$gitignore_path" ]]; then
    echo "Error: .gitignore is a symlink, refusing to update: .gitignore" >&2
    echo "Replace it with a regular file and rerun new-project.sh." >&2
    exit 1
  fi

  if [[ ! -e "$gitignore_path" ]]; then
    : > "$gitignore_path"
  fi

  gitignore_has_line() {
    local file_path="$1"
    local target_line="$2"

    awk -v target="$target_line" '
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
    ' "$file_path"
  }

  for line in "${OBSIDIAN_GITIGNORE_LINES[@]}"; do
    if gitignore_has_line "$gitignore_path" "$line"; then
      continue
    fi

    printf '%s\n' "$line" >> "$gitignore_path"
    added_count=$((added_count + 1))
  done

  if [[ "$added_count" -gt 0 ]]; then
    echo "Updated: .gitignore (added $added_count Obsidian ignore entries)"
  else
    echo "Unchanged: .gitignore (Obsidian ignore entries already present)"
  fi
}

project_name=""
repo_path_input=""
migrate_existing_root_md="false"

for arg in "$@"; do
  case "$arg" in
    --migrate-existing-root-md)
      migrate_existing_root_md="true"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "$project_name" ]]; then
        project_name="$arg"
      elif [[ -z "$repo_path_input" ]]; then
        repo_path_input="$arg"
      else
        echo "Error: unexpected argument: $arg"
        usage
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$project_name" || -z "$repo_path_input" ]]; then
  usage
  exit 1
fi

repo_path="$(expand_path "$repo_path_input")"
if [[ "$repo_path_input" == /~/* ]]; then
  echo "Warning: interpreted '$repo_path_input' as '$repo_path'." >&2
fi

if [[ ! -d "$repo_path" ]]; then
  echo "Error: repo path does not exist: $repo_path"
  exit 1
fi

canonical_repo_path="$(cd "$repo_path" && pwd -P)"
project_dir="$canonical_repo_path/agent-vault"

if [[ -e "$project_dir" ]]; then
  echo "Error: destination already exists: $project_dir"
  exit 1
fi

if [[ -L "$canonical_repo_path/.gitignore" ]]; then
  echo "Error: .gitignore is a symlink, refusing to update: $canonical_repo_path/.gitignore" >&2
  echo "Replace it with a regular file and rerun new-project.sh." >&2
  exit 1
fi

slug="$(echo "$project_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-_')"
if [[ -z "$slug" ]]; then
  echo "Error: project slug is empty after normalization."
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
template_root="$(cd "$script_dir/.." && pwd -P)"
scaffold_dir="$template_root/scaffold/agent-vault"
root_scaffold_dir="$template_root/scaffold/root"

if [[ ! -d "$scaffold_dir" ]]; then
  echo "Error: scaffold source not found: $scaffold_dir"
  exit 1
fi

if [[ ! -d "$root_scaffold_dir" ]]; then
  echo "Error: root scaffold source not found: $root_scaffold_dir"
  exit 1
fi

for root_file in AGENTS.md CLAUDE.md GEMINI.md; do
  if [[ ! -f "$root_scaffold_dir/$root_file" ]]; then
    echo "Error: missing root scaffold file: $root_scaffold_dir/$root_file"
    exit 1
  fi
done

cp -R "$scaffold_dir" "$project_dir"

today="$(date '+%Y-%m-%d')"
now="$(date '+%Y-%m-%d %H:%M')"
migration_timestamp="$(date '+%Y%m%d-%H%M%S')"
migration_backup_dir="$project_dir/context/updates/$migration_timestamp"

export PROJECT_NAME="$project_name"
export PROJECT_SLUG="$slug"
export REPO_PATH="$canonical_repo_path"
export TODAY="$today"
export NOW="$now"

while IFS= read -r -d '' file; do
  if [[ "$(basename "$file")" == ".gitkeep" ]]; then
    continue
  fi

  perl -0pi -e 's/__PROJECT_NAME__/$ENV{PROJECT_NAME}/g; s/__PROJECT_SLUG__/$ENV{PROJECT_SLUG}/g; s/__REPO_PATH__/$ENV{REPO_PATH}/g; s/__DATE__/$ENV{TODAY}/g; s/__DATETIME__/$ENV{NOW}/g;' "$file"
done < <(find "$project_dir" -type f -print0)

process_root_policy_file() {
  local canonical_name="$1"
  local vault_policy_file="$2"
  local marker="$3"
  local scaffold_source="$root_scaffold_dir/$canonical_name"
  local canonical_dest="$canonical_repo_path/$canonical_name"
  local existing_path=""

  if existing_path="$(find_existing_root_file "$canonical_repo_path" "$canonical_name")"; then
    if [[ "$migrate_existing_root_md" != "true" ]]; then
      echo "Notice: $existing_path already exists; left unchanged." >&2
      return
    fi

    if [[ -L "$existing_path" ]]; then
      echo "Error: existing root policy file is a symlink: $existing_path" >&2
      echo "Replace it with a regular file and rerun new-project.sh." >&2
      exit 1
    fi

    if grep -Fqx "$marker" "$existing_path"; then
      if [[ "$existing_path" != "$canonical_dest" ]]; then
        rm "$existing_path"
      fi
      cp "$scaffold_source" "$canonical_dest"
      echo "Updated managed root wrapper: $canonical_name"
      return
    fi

    mkdir -p "$migration_backup_dir"
    local existing_basename
    local source_rel

    existing_basename="$(basename "$existing_path")"
    source_rel="${existing_path#$canonical_repo_path/}"

    cp -p "$existing_path" "$migration_backup_dir/$existing_basename"
    append_migrated_root_content "$existing_path" "$vault_policy_file" "$canonical_name" "$source_rel" "$now"

    if [[ "$existing_path" != "$canonical_dest" ]]; then
      rm "$existing_path"
    fi

    cp "$scaffold_source" "$canonical_dest"
    echo "Migrated: $source_rel -> agent-vault/$canonical_name (backup -> agent-vault/context/updates/$migration_timestamp/$existing_basename)"
    return
  fi

  cp "$scaffold_source" "$canonical_dest"
}

process_root_policy_file "AGENTS.md" "$project_dir/AGENTS.md" "$ROOT_AGENTS_MARKER"
process_root_policy_file "CLAUDE.md" "$project_dir/CLAUDE.md" "$ROOT_CLAUDE_MARKER"
process_root_policy_file "GEMINI.md" "$project_dir/GEMINI.md" "$ROOT_GEMINI_MARKER"

ensure_obsidian_gitignore "$canonical_repo_path"

echo "Created project notes at: $project_dir"

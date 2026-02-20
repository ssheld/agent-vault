#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 <repo-path> [--dry-run]"
  echo "Example: $0 ~/workspaces/harrier --dry-run"
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

repo_path_input=""
dry_run="false"

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      dry_run="true"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -n "$repo_path_input" ]]; then
        echo "Error: unexpected argument: $arg"
        usage
        exit 1
      fi
      repo_path_input="$arg"
      ;;
  esac
done

if [[ -z "$repo_path_input" ]]; then
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

if [[ ! -d "$project_dir" ]]; then
  echo "Error: expected agent vault at: $project_dir"
  echo "Run ./scripts/new-project.sh first for new repositories."
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
template_root="$(cd "$script_dir/.." && pwd -P)"
vault_scaffold_dir="$template_root/scaffold/agent-vault"
root_scaffold_dir="$template_root/scaffold/root"

for required in \
  "$root_scaffold_dir/AGENTS.md" \
  "$root_scaffold_dir/CLAUDE.md" \
  "$root_scaffold_dir/GEMINI.md" \
  "$vault_scaffold_dir/AGENTS.md" \
  "$vault_scaffold_dir/CLAUDE.md" \
  "$vault_scaffold_dir/GEMINI.md"
do
  if [[ ! -f "$required" ]]; then
    echo "Error: missing scaffold file: $required"
    exit 1
  fi
done

timestamp="$(date '+%Y%m%d-%H%M%S')"
backup_dir="$project_dir/context/updates/$timestamp"

created=0
updated=0
unchanged=0
backed_up=0

assert_not_symlink() {
  local path="$1"
  local rel="$2"

  if [[ -L "$path" ]]; then
    echo "Error: managed file is a symlink, refusing to update: $rel" >&2
    echo "Resolve the symlink to a regular file and rerun update-project.sh." >&2
    exit 1
  fi
}

preflight_symlink_checks() {
  assert_not_symlink "$canonical_repo_path/AGENTS.md" "AGENTS.md"
  assert_not_symlink "$canonical_repo_path/CLAUDE.md" "CLAUDE.md"
  assert_not_symlink "$canonical_repo_path/GEMINI.md" "GEMINI.md"
  assert_not_symlink "$project_dir/AGENTS.md" "agent-vault/AGENTS.md"
  assert_not_symlink "$project_dir/CLAUDE.md" "agent-vault/CLAUDE.md"
  assert_not_symlink "$project_dir/GEMINI.md" "agent-vault/GEMINI.md"
  assert_not_symlink "$canonical_repo_path/.gitignore" ".gitignore"
}

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

sync_managed_file() {
  local src="$1"
  local dest="$2"
  local rel

  if [[ "$dest" == "$canonical_repo_path/"* ]]; then
    rel="${dest#$canonical_repo_path/}"
  else
    rel="$dest"
  fi

  assert_not_symlink "$dest" "$rel"

  if [[ ! -e "$dest" ]]; then
    if [[ "$dry_run" == "true" ]]; then
      echo "Create: $rel"
    else
      mkdir -p "$(dirname "$dest")"
      cp "$src" "$dest"
      echo "Created: $rel"
    fi
    created=$((created + 1))
    return
  fi

  if cmp -s "$src" "$dest"; then
    echo "Unchanged: $rel"
    unchanged=$((unchanged + 1))
    return
  fi

  if [[ "$dry_run" == "true" ]]; then
    echo "Update: $rel (backup -> agent-vault/context/updates/$timestamp/$rel)"
    backed_up=$((backed_up + 1))
  else
    local backup_path="$backup_dir/$rel"
    mkdir -p "$(dirname "$backup_path")"
    cp -p "$dest" "$backup_path"
    cp "$src" "$dest"
    echo "Updated: $rel"
    backed_up=$((backed_up + 1))
  fi

  updated=$((updated + 1))
}

ensure_obsidian_gitignore() {
  local repo_root="$1"
  local gitignore_path="$repo_root/.gitignore"
  local -a missing_lines=()
  local line
  local backup_path
  local existed="false"

  if [[ -e "$gitignore_path" ]]; then
    existed="true"
  fi

  for line in "${OBSIDIAN_GITIGNORE_LINES[@]}"; do
    if [[ -e "$gitignore_path" ]] && gitignore_has_line "$gitignore_path" "$line"; then
      continue
    fi

    missing_lines+=("$line")
  done

  if [[ ${#missing_lines[@]} -eq 0 ]]; then
    echo "Unchanged: .gitignore (Obsidian ignore entries present)"
    unchanged=$((unchanged + 1))
    return
  fi

  if [[ "$dry_run" == "true" ]]; then
    if [[ "$existed" == "true" ]]; then
      echo "Update: .gitignore (backup -> agent-vault/context/updates/$timestamp/.gitignore)"
      updated=$((updated + 1))
      backed_up=$((backed_up + 1))
    else
      echo "Create: .gitignore (add ${#missing_lines[@]} Obsidian ignore entries)"
      created=$((created + 1))
    fi
    return
  fi

  if [[ "$existed" == "true" ]]; then
    backup_path="$backup_dir/.gitignore"
    mkdir -p "$(dirname "$backup_path")"
    cp -p "$gitignore_path" "$backup_path"
    backed_up=$((backed_up + 1))
  else
    : > "$gitignore_path"
  fi

  for line in "${missing_lines[@]}"; do
    printf '%s\n' "$line" >> "$gitignore_path"
  done

  if [[ "$existed" == "true" ]]; then
    echo "Updated: .gitignore (added ${#missing_lines[@]} Obsidian ignore entries)"
    updated=$((updated + 1))
  else
    echo "Created: .gitignore (added ${#missing_lines[@]} Obsidian ignore entries)"
    created=$((created + 1))
  fi
}

preflight_symlink_checks

sync_managed_file "$root_scaffold_dir/AGENTS.md" "$canonical_repo_path/AGENTS.md"
sync_managed_file "$root_scaffold_dir/CLAUDE.md" "$canonical_repo_path/CLAUDE.md"
sync_managed_file "$root_scaffold_dir/GEMINI.md" "$canonical_repo_path/GEMINI.md"
sync_managed_file "$vault_scaffold_dir/AGENTS.md" "$project_dir/AGENTS.md"
sync_managed_file "$vault_scaffold_dir/CLAUDE.md" "$project_dir/CLAUDE.md"
sync_managed_file "$vault_scaffold_dir/GEMINI.md" "$project_dir/GEMINI.md"
ensure_obsidian_gitignore "$canonical_repo_path"

echo
echo "Summary:"
echo "- created: $created"
echo "- updated: $updated"
echo "- unchanged: $unchanged"
echo "- backups: $backed_up"

if [[ "$dry_run" == "true" ]]; then
  echo "Dry run complete. No files were written."
elif [[ "$backed_up" -gt 0 ]]; then
  echo "Backups saved under: $backup_dir"
fi

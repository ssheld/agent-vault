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

sync_managed_file() {
  local src="$1"
  local dest="$2"
  local rel

  if [[ "$dest" == "$canonical_repo_path/"* ]]; then
    rel="${dest#$canonical_repo_path/}"
  else
    rel="$dest"
  fi

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

sync_managed_file "$root_scaffold_dir/AGENTS.md" "$canonical_repo_path/AGENTS.md"
sync_managed_file "$root_scaffold_dir/CLAUDE.md" "$canonical_repo_path/CLAUDE.md"
sync_managed_file "$root_scaffold_dir/GEMINI.md" "$canonical_repo_path/GEMINI.md"
sync_managed_file "$vault_scaffold_dir/AGENTS.md" "$project_dir/AGENTS.md"
sync_managed_file "$vault_scaffold_dir/CLAUDE.md" "$project_dir/CLAUDE.md"
sync_managed_file "$vault_scaffold_dir/GEMINI.md" "$project_dir/GEMINI.md"

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

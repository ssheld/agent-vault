#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 <project-name> <repo-path>"
  echo "Example: $0 payments-api ~/workspaces/payments-api"
}

if [[ $# -ne 2 ]]; then
  usage
  exit 1
fi

project_name="$1"
repo_path_input="$2"

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

root_agents="$canonical_repo_path/AGENTS.md"
if [[ -e "$root_agents" ]]; then
  echo "Notice: $root_agents already exists; left unchanged." >&2
else
  cp "$root_scaffold_dir/AGENTS.md" "$root_agents"
fi

root_claude="$canonical_repo_path/CLAUDE.md"
if [[ -e "$root_claude" ]]; then
  echo "Notice: $root_claude already exists; left unchanged." >&2
else
  cp "$root_scaffold_dir/CLAUDE.md" "$root_claude"
fi

root_gemini="$canonical_repo_path/GEMINI.md"
if [[ -e "$root_gemini" ]]; then
  echo "Notice: $root_gemini already exists; left unchanged." >&2
else
  cp "$root_scaffold_dir/GEMINI.md" "$root_gemini"
fi

echo "Created project notes at: $project_dir"

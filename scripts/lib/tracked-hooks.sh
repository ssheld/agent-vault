#!/usr/bin/env bash

configure_tracked_hooks_path() {
  local repo_root="$1"
  local dry_run_mode="${2:-false}"
  local desired_hooks_path="agent-vault/_assets/hooks"
  local current_hooks_path=""

  if ! git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return
  fi

  current_hooks_path="$(git -C "$repo_root" config --get core.hooksPath 2>/dev/null || true)"

  if [[ -z "$current_hooks_path" ]]; then
    if [[ "$dry_run_mode" == "true" ]]; then
      echo "Dry run: would enable tracked metadata hook via core.hooksPath=$desired_hooks_path"
    else
      git -C "$repo_root" config --local core.hooksPath "$desired_hooks_path"
      echo "Enabled tracked metadata hook via core.hooksPath=$desired_hooks_path"
    fi
    return
  fi

  if [[ "$current_hooks_path" == "$desired_hooks_path" ]]; then
    echo "Tracked metadata hook already enabled via core.hooksPath=$desired_hooks_path"
    return
  fi

  echo "Notice: effective core.hooksPath already set to '$current_hooks_path'; left unchanged." >&2
  echo "To use the tracked agent-vault hook in this clone, run:" >&2
  echo "  git -C \"$repo_root\" config core.hooksPath $desired_hooks_path" >&2
}

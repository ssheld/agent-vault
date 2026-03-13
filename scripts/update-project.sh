#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 <repo-path> [--dry-run] [--migrate-root] [--sync-templates]"
  echo "Example: $0 ~/workspaces/harrier --dry-run --sync-templates"
  echo ""
  echo "Options:"
  echo "  --dry-run       Show what would change without writing files"
  echo "  --migrate-root  Replace unmanaged root wrappers with managed versions (backs up originals)"
  echo "  --sync-templates  Refresh agent-vault/Templates/ from scaffold (backs up existing files)"
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

# Contract: each block starts with a human-readable comment line followed by
# one or more ignore patterns. collect_missing_managed_gitignore_lines relies
# on that shape when deciding whether to add the block comment.
MANAGED_GITIGNORE_BLOCKS=(
  $'# Obsidian -- machine-specific & volatile files (ignore these)\n.obsidian/workspace.json\n.obsidian/app.json\n.obsidian/appearance.json\n.obsidian/workspace-mobile.json\n.obsidian/cache/\n.obsidian/backup/'
  $'# Plugin data (can contain API keys or large caches)\n.obsidian/plugins/*/data.json'
  $'# Agent Vault -- local sync and migration backups (ignore these)\n/agent-vault/context/updates/'
)

ROOT_AGENTS_MARKER="<!-- agent-vault-managed: root-wrapper; file=AGENTS.md -->"
ROOT_CLAUDE_MARKER="<!-- agent-vault-managed: root-wrapper; file=CLAUDE.md -->"
ROOT_GEMINI_MARKER="<!-- agent-vault-managed: root-wrapper; file=GEMINI.md -->"

repo_path_input=""
dry_run="false"
migrate_root="false"
sync_templates="false"

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      dry_run="true"
      ;;
    --migrate-root)
      migrate_root="true"
      ;;
    --sync-templates)
      sync_templates="true"
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
  "$root_scaffold_dir/.github/pull_request_template.md" \
  "$root_scaffold_dir/docs/design.md" \
  "$vault_scaffold_dir/AGENTS.md" \
  "$vault_scaffold_dir/CLAUDE.md" \
  "$vault_scaffold_dir/GEMINI.md" \
  "$vault_scaffold_dir/shared-rules.md" \
  "$vault_scaffold_dir/review-policy.md" \
  "$vault_scaffold_dir/handoff.md" \
  "$vault_scaffold_dir/project-context.md" \
  "$vault_scaffold_dir/project-commands.md" \
  "$vault_scaffold_dir/lessons.md" \
  "$vault_scaffold_dir/_assets/hooks/README.md" \
  "$vault_scaffold_dir/_assets/hooks/pre-commit" \
  "$vault_scaffold_dir/design-log/README.md" \
  "$vault_scaffold_dir/context/handoffs/README.md" \
  "$vault_scaffold_dir/decisions/README.md" \
  "$vault_scaffold_dir/daily/README.md"
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
skipped=0

repo_relative_path() {
  local path="$1"

  if [[ "$path" == "$canonical_repo_path/"* ]]; then
    printf '%s\n' "${path#$canonical_repo_path/}"
  else
    printf '%s\n' "$path"
  fi
}

validate_write_path() {
  local destination_path="$1"
  local current_path="$destination_path"

  case "$destination_path" in
    "$canonical_repo_path"|"$canonical_repo_path"/*) ;;
    *)
      return 2
      ;;
  esac

  while [[ "$current_path" != "$canonical_repo_path" ]]; do
    if [[ -L "$current_path" ]]; then
      return 1
    fi
    current_path="$(dirname "$current_path")"
  done

  return 0
}

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
  # agent-vault scaffold-owned files and .gitignore are always managed.
  assert_not_symlink "$project_dir/AGENTS.md" "agent-vault/AGENTS.md"
  assert_not_symlink "$project_dir/CLAUDE.md" "agent-vault/CLAUDE.md"
  assert_not_symlink "$project_dir/GEMINI.md" "agent-vault/GEMINI.md"
  assert_not_symlink "$project_dir/shared-rules.md" "agent-vault/shared-rules.md"
  assert_not_symlink "$project_dir/review-policy.md" "agent-vault/review-policy.md"
  assert_not_symlink "$project_dir/handoff.md" "agent-vault/handoff.md"
  assert_not_symlink "$project_dir/_assets/hooks/README.md" "agent-vault/_assets/hooks/README.md"
  assert_not_symlink "$project_dir/_assets/hooks/pre-commit" "agent-vault/_assets/hooks/pre-commit"
  assert_not_symlink "$project_dir/design-log/README.md" "agent-vault/design-log/README.md"
  assert_not_symlink "$project_dir/context/handoffs/README.md" "agent-vault/context/handoffs/README.md"
  assert_not_symlink "$project_dir/decisions/README.md" "agent-vault/decisions/README.md"
  assert_not_symlink "$project_dir/daily/README.md" "agent-vault/daily/README.md"
  assert_not_symlink "$canonical_repo_path/.gitignore" ".gitignore"
}

has_exact_line() {
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

gitignore_has_line() {
  local file_path="$1"
  local target_line="$2"

  has_exact_line "$file_path" "$target_line"
}

collect_missing_managed_gitignore_lines() {
  local file_path="$1"
  local block
  local line
  local comment_line
  local line_number
  local missing_pattern_count
  local -a missing_lines=()
  local -a missing_block_lines=()

  for block in "${MANAGED_GITIGNORE_BLOCKS[@]}"; do
    comment_line=""
    line_number=0
    missing_pattern_count=0
    missing_block_lines=()

    while IFS= read -r line; do
      line_number=$((line_number + 1))

      if [[ "$line_number" -eq 1 ]]; then
        comment_line="$line"
        continue
      fi

      if [[ -e "$file_path" ]] && gitignore_has_line "$file_path" "$line"; then
        continue
      fi

      missing_block_lines+=("$line")
      missing_pattern_count=$((missing_pattern_count + 1))
    done <<< "$block"

    # Skip orphaned comments when the ignore patterns already exist.
    if [[ "$missing_pattern_count" -eq 0 ]]; then
      continue
    fi

    if [[ ! -e "$file_path" ]] || ! gitignore_has_line "$file_path" "$comment_line"; then
      missing_lines+=("$comment_line")
    fi

    missing_lines+=("${missing_block_lines[@]}")
  done

  if [[ "${#missing_lines[@]}" -gt 0 ]]; then
    printf '%s\n' "${missing_lines[@]}"
  fi
}

is_managed_root_wrapper() {
  local file_path="$1"
  local marker="$2"

  [[ -f "$file_path" ]] || return 1
  has_exact_line "$file_path" "$marker"
}

sync_managed_file() {
  local src="$1"
  local dest="$2"
  local rel
  local path_status=0

  rel="$(repo_relative_path "$dest")"

  validate_write_path "$dest" || path_status=$?
  if [[ "$path_status" -eq 1 ]]; then
    echo "Error: refusing to update $rel because a path component is a symlink." >&2
    echo "Replace symlinked path components with regular directories/files and rerun update-project.sh." >&2
    exit 1
  fi
  if [[ "$path_status" -eq 2 ]]; then
    echo "Error: refusing to update path outside repository root: $rel" >&2
    exit 1
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

seed_if_missing() {
  local src="$1"
  local dest="$2"
  local rel
  local path_status=0

  rel="$(repo_relative_path "$dest")"

  validate_write_path "$dest" || path_status=$?
  if [[ "$path_status" -eq 1 ]]; then
    echo "Skip: $rel (path component symlink — not seeding)"
    skipped=$((skipped + 1))
    return
  fi
  if [[ "$path_status" -eq 2 ]]; then
    echo "Error: refusing to seed path outside repository root: $rel" >&2
    exit 1
  fi

  if [[ -e "$dest" ]]; then
    return
  fi

  if [[ "$dry_run" == "true" ]]; then
    echo "Seed: $rel (new template)"
  else
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    echo "Seeded: $rel (new template)"
  fi
  created=$((created + 1))
}

sync_template_files() {
  local src_root="$1"
  local dest_root="$2"
  local src_file=""
  local rel=""
  local dest=""

  if [[ "$sync_templates" != "true" ]]; then
    return
  fi

  while IFS= read -r -d '' src_file; do
    rel="${src_file#$src_root/}"
    dest="$dest_root/$rel"
    sync_managed_file "$src_file" "$dest"
  done < <(find "$src_root" -type f -print0)
}

sync_root_wrapper_if_managed() {
  local src="$1"
  local dest="$2"
  local marker="$3"
  local rel

  rel="$(repo_relative_path "$dest")"

  if [[ -L "$dest" ]]; then
    echo "Skip: $rel (symlink files are not auto-managed)"
    skipped=$((skipped + 1))
    return
  fi

  if [[ ! -e "$dest" ]]; then
    sync_managed_file "$src" "$dest"
    return
  fi

  if is_managed_root_wrapper "$dest" "$marker"; then
    sync_managed_file "$src" "$dest"
    return
  fi

  # File exists but lacks the managed marker
  if [[ "$migrate_root" == "true" ]]; then
    echo "Migrating: $rel (unmanaged → managed wrapper)"
    sync_managed_file "$src" "$dest"
    return
  fi

  echo "Skip: $rel (unmanaged root file; use --migrate-root to replace)"
  skipped=$((skipped + 1))
}

ensure_managed_gitignore_entries() {
  local repo_root="$1"
  local gitignore_path="$repo_root/.gitignore"
  local -a missing_lines=()
  local line
  local backup_path
  local existed="false"

  if [[ -e "$gitignore_path" ]]; then
    existed="true"
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    missing_lines+=("$line")
  done < <(collect_missing_managed_gitignore_lines "$gitignore_path")

  if [[ ${#missing_lines[@]} -eq 0 ]]; then
    echo "Unchanged: .gitignore (managed ignore entries present)"
    unchanged=$((unchanged + 1))
    return
  fi

  if [[ "$dry_run" == "true" ]]; then
    if [[ "$existed" == "true" ]]; then
      echo "Update: .gitignore (backup -> agent-vault/context/updates/$timestamp/.gitignore)"
      updated=$((updated + 1))
      backed_up=$((backed_up + 1))
    else
      echo "Create: .gitignore (add ${#missing_lines[@]} managed ignore entries)"
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
    echo "Updated: .gitignore (added ${#missing_lines[@]} managed ignore entries)"
    updated=$((updated + 1))
  else
    echo "Created: .gitignore (added ${#missing_lines[@]} managed ignore entries)"
    created=$((created + 1))
  fi
}

configure_tracked_hooks_path() {
  local repo_root="$1"
  local desired_hooks_path="agent-vault/_assets/hooks"
  local current_hooks_path=""

  if ! git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return
  fi

  current_hooks_path="$(git -C "$repo_root" config --local --get core.hooksPath 2>/dev/null || true)"

  if [[ -z "$current_hooks_path" ]]; then
    if [[ "$dry_run" == "true" ]]; then
      echo "Optional: enable the tracked metadata hook in this clone:"
      echo "  git -C \"$repo_root\" config core.hooksPath $desired_hooks_path"
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

  echo "Notice: core.hooksPath already set to '$current_hooks_path'; left unchanged." >&2
  echo "To use the tracked agent-vault hook in this clone, run:" >&2
  echo "  git -C \"$repo_root\" config core.hooksPath $desired_hooks_path" >&2
}

preflight_symlink_checks

sync_root_wrapper_if_managed "$root_scaffold_dir/AGENTS.md" "$canonical_repo_path/AGENTS.md" "$ROOT_AGENTS_MARKER"
sync_root_wrapper_if_managed "$root_scaffold_dir/CLAUDE.md" "$canonical_repo_path/CLAUDE.md" "$ROOT_CLAUDE_MARKER"
sync_root_wrapper_if_managed "$root_scaffold_dir/GEMINI.md" "$canonical_repo_path/GEMINI.md" "$ROOT_GEMINI_MARKER"
seed_if_missing "$root_scaffold_dir/.github/pull_request_template.md" "$canonical_repo_path/.github/pull_request_template.md"
seed_if_missing "$root_scaffold_dir/docs/design.md" "$canonical_repo_path/docs/design.md"
seed_if_missing "$vault_scaffold_dir/project-context.md" "$project_dir/project-context.md"
seed_if_missing "$vault_scaffold_dir/project-commands.md" "$project_dir/project-commands.md"

sync_managed_file "$vault_scaffold_dir/shared-rules.md" "$project_dir/shared-rules.md"
sync_managed_file "$vault_scaffold_dir/review-policy.md" "$project_dir/review-policy.md"
sync_managed_file "$vault_scaffold_dir/AGENTS.md" "$project_dir/AGENTS.md"
sync_managed_file "$vault_scaffold_dir/CLAUDE.md" "$project_dir/CLAUDE.md"
sync_managed_file "$vault_scaffold_dir/GEMINI.md" "$project_dir/GEMINI.md"
sync_managed_file "$vault_scaffold_dir/handoff.md" "$project_dir/handoff.md"
sync_managed_file "$vault_scaffold_dir/_assets/hooks/README.md" "$project_dir/_assets/hooks/README.md"
sync_managed_file "$vault_scaffold_dir/_assets/hooks/pre-commit" "$project_dir/_assets/hooks/pre-commit"
sync_managed_file "$vault_scaffold_dir/design-log/README.md" "$project_dir/design-log/README.md"
sync_managed_file "$vault_scaffold_dir/context/handoffs/README.md" "$project_dir/context/handoffs/README.md"
sync_managed_file "$vault_scaffold_dir/decisions/README.md" "$project_dir/decisions/README.md"
sync_managed_file "$vault_scaffold_dir/daily/README.md" "$project_dir/daily/README.md"

seed_if_missing "$vault_scaffold_dir/lessons.md" "$project_dir/lessons.md"
sync_template_files "$vault_scaffold_dir/Templates" "$project_dir/Templates"

ensure_managed_gitignore_entries "$canonical_repo_path"

echo
echo "Summary:"
echo "- created: $created"
echo "- updated: $updated"
echo "- unchanged: $unchanged"
echo "- skipped: $skipped"
echo "- backups: $backed_up"

if [[ "$dry_run" == "true" ]]; then
  echo "Dry run complete. No files were written."
elif [[ "$backed_up" -gt 0 ]]; then
  echo "Backups saved under: $backup_dir"
fi

configure_tracked_hooks_path "$canonical_repo_path"

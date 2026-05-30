#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./lib/tracked-hooks.sh
source "$script_dir/lib/tracked-hooks.sh"

usage() {
  echo "Usage: $0 <repo-path> [--dry-run] [--migrate-root] [--migrate-root-scripts] [--sync-templates] [--sync-coding-standards]"
  echo "Example: $0 ~/workspaces/harrier --dry-run --sync-templates --sync-coding-standards"
  echo ""
  echo "Options:"
  echo "  --dry-run       Show what would change without writing files"
  echo "  --migrate-root  Replace unmanaged root wrappers with managed versions (backs up originals)"
  echo "  --migrate-root-scripts  Replace unmanaged root helper scripts with managed versions (backs up originals)"
  echo "  --sync-templates  Refresh project-local agent-vault/Templates/ from scaffold (backs up existing files); policy-critical templates may sync on normal updates"
  echo "  --sync-coding-standards  Replace agent-vault/coding-standards.md from scaffold (backs up existing file)"
}

expand_path() {
  local p="$1"
  case "$p" in
    \~)
      printf '%s\n' "$HOME"
      ;;
    \~/*)
      printf '%s/%s\n' "$HOME" "${p#\~/}"
      ;;
    /\~/*)
      # Common typo: /~/path should usually be ~/path.
      printf '%s/%s\n' "$HOME" "${p#/\~/}"
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
  $'# Agent Vault -- local worktrees (ignore these)\n/.worktrees/'
)

ROOT_AGENTS_MARKER="<!-- agent-vault-managed: root-wrapper; file=AGENTS.md -->"
ROOT_CLAUDE_MARKER="<!-- agent-vault-managed: root-wrapper; file=CLAUDE.md -->"
ROOT_GEMINI_MARKER="<!-- agent-vault-managed: root-wrapper; file=GEMINI.md -->"
CURSOR_AGENT_VAULT_RULE_MARKER="<!-- agent-vault-managed: cursor-rule; file=.cursor/rules/agent-vault.mdc -->"
NEW_WORKTREE_HELPER_MARKER="# agent-vault-managed: helper-script; file=new-worktree.sh"
REMOVE_WORKTREE_HELPER_MARKER="# agent-vault-managed: helper-script; file=remove-worktree.sh"
CHECK_MEMORY_BUDGET_HELPER_MARKER="# agent-vault-managed: helper-script; file=check-memory-budget.sh"
CHECK_CONTEXT_LOG_ROLLOVER_HELPER_MARKER="# agent-vault-managed: helper-script; file=check-context-log-rollover.sh"
POLICY_TEMPLATE_REL_PATHS=(
  "Decision Record.md"
)

repo_path_input=""
dry_run="false"
migrate_root="false"
migrate_root_scripts="false"
sync_templates="false"
sync_coding_standards="false"

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      dry_run="true"
      ;;
    --migrate-root)
      migrate_root="true"
      ;;
    --migrate-root-scripts)
      migrate_root_scripts="true"
      ;;
    --sync-templates)
      sync_templates="true"
      ;;
    --sync-coding-standards)
      sync_coding_standards="true"
      ;;
    -h | --help)
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

template_root="$(cd "$script_dir/.." && pwd -P)"
vault_scaffold_dir="$template_root/scaffold/agent-vault"
root_scaffold_dir="$template_root/scaffold/root"

for required in \
  "$root_scaffold_dir/AGENTS.md" \
  "$root_scaffold_dir/CLAUDE.md" \
  "$root_scaffold_dir/GEMINI.md" \
  "$root_scaffold_dir/.cursor/rules/agent-vault.mdc" \
  "$root_scaffold_dir/.github/pull_request_template.md" \
  "$root_scaffold_dir/docs/design.md" \
  "$root_scaffold_dir/docs/runbooks/parallel-agent-worktrees.md" \
  "$root_scaffold_dir/scripts/new-worktree.sh" \
  "$root_scaffold_dir/scripts/remove-worktree.sh" \
  "$root_scaffold_dir/scripts/check-memory-budget.sh" \
  "$root_scaffold_dir/scripts/check-context-log-rollover.sh" \
  "$vault_scaffold_dir/AGENTS.md" \
  "$vault_scaffold_dir/CLAUDE.md" \
  "$vault_scaffold_dir/GEMINI.md" \
  "$vault_scaffold_dir/shared-rules.md" \
  "$vault_scaffold_dir/review-policy.md" \
  "$vault_scaffold_dir/handoff.md" \
  "$vault_scaffold_dir/coding-standards.md" \
  "$vault_scaffold_dir/project-context.md" \
  "$vault_scaffold_dir/project-commands.md" \
  "$vault_scaffold_dir/lessons.md" \
  "$vault_scaffold_dir/_assets/hooks/README.md" \
  "$vault_scaffold_dir/_assets/hooks/lib/runtime-note.sh" \
  "$vault_scaffold_dir/_assets/hooks/pre-commit" \
  "$vault_scaffold_dir/_assets/hooks/pre-push" \
  "$vault_scaffold_dir/design-log/README.md" \
  "$vault_scaffold_dir/context/handoffs/README.md" \
  "$vault_scaffold_dir/decisions/README.md" \
  "$vault_scaffold_dir/daily/README.md" \
  "$vault_scaffold_dir/Templates/Decision Record.md"; do
  if [[ ! -f "$required" ]]; then
    echo "Error: missing scaffold file: $required"
    exit 1
  fi
done

timestamp="$(date '+%Y%m%d-%H%M%S')"
today="$(date '+%Y-%m-%d')"
now_local="$(date '+%Y-%m-%d %H:%M')"
backup_dir="$project_dir/context/updates/$timestamp"

created=0
updated=0
unchanged=0
backed_up=0
skipped=0
coding_standards_manual_merge_warning="false"
context_log_manual_migration_warning="false"

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
    "$canonical_repo_path" | "$canonical_repo_path"/*) ;;
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
  assert_not_symlink "$project_dir/_assets/hooks/lib/runtime-note.sh" "agent-vault/_assets/hooks/lib/runtime-note.sh"
  assert_not_symlink "$project_dir/_assets/hooks/pre-commit" "agent-vault/_assets/hooks/pre-commit"
  assert_not_symlink "$project_dir/_assets/hooks/pre-push" "agent-vault/_assets/hooks/pre-push"
  assert_not_symlink "$project_dir/design-log/README.md" "agent-vault/design-log/README.md"
  assert_not_symlink "$project_dir/context/handoffs/README.md" "agent-vault/context/handoffs/README.md"
  assert_not_symlink "$project_dir/decisions/README.md" "agent-vault/decisions/README.md"
  assert_not_symlink "$project_dir/daily/README.md" "agent-vault/daily/README.md"
  assert_not_symlink "$project_dir/Templates/Decision Record.md" "agent-vault/Templates/Decision Record.md"
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

extract_frontmatter_value() {
  local file_path="$1"
  local field_name="$2"

  awk -v field_name="$field_name" '
    BEGIN {
      frontmatter_markers = 0
    }
    /^---$/ {
      frontmatter_markers += 1
      next
    }
    frontmatter_markers == 1 && index($0, field_name ":") == 1 {
      value = substr($0, length(field_name) + 2)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      print value
      exit
    }
    frontmatter_markers >= 2 {
      exit
    }
  ' "$file_path"
}

first_matching_line_number() {
  local file_path="$1"
  local pattern="$2"

  awk -v pattern="$pattern" '
    $0 ~ pattern {
      print NR
      exit
    }
  ' "$file_path"
}

extract_section_body() {
  local file_path="$1"
  local heading="$2"

  awk -v heading="$heading" '
    !capture && $0 == heading {
      capture = 1
      next
    }
    capture {
      if ($0 ~ /^## /) {
        exit
      }
      print
    }
  ' "$file_path"
}

infer_active_branch() {
  local repo_root="$1"
  local branch=""

  if git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  fi

  if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
    printf 'main\n'
    return
  fi

  printf '%s\n' "$branch"
}

replace_file_from_tmp() {
  local tmp_file="$1"
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

  if cmp -s "$tmp_file" "$dest"; then
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
    cp "$tmp_file" "$dest"
    echo "Updated: $rel"
    backed_up=$((backed_up + 1))
  fi

  updated=$((updated + 1))
}

classify_context_log_layout() {
  local file_path="$1"
  local snapshot_line=""
  local entries_line=""
  local entry_heading_line=""
  local legacy_entry_heading_line=""
  local has_historical_wrappers="false"

  if [[ ! -f "$file_path" ]]; then
    printf 'missing\n'
    return
  fi

  snapshot_line="$(first_matching_line_number "$file_path" '^## Current Snapshot$')"
  entries_line="$(first_matching_line_number "$file_path" '^## Entries$')"
  entry_heading_line="$(first_matching_line_number "$file_path" '^### [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} local')"
  legacy_entry_heading_line="$(first_matching_line_number "$file_path" '^### [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} local — ')"

  if grep -Eq '^## (Legacy Unindexed Entries|Historical Snapshot|Historical Indexed Entries)$' "$file_path"; then
    has_historical_wrappers="true"
  fi

  if [[ -n "$snapshot_line" && -n "$entries_line" && "$snapshot_line" -lt "$entries_line" ]]; then
    if [[ -z "$entry_heading_line" || "$entries_line" -lt "$entry_heading_line" || "$has_historical_wrappers" == "true" ]]; then
      printf 'current\n'
      return
    fi
  fi

  if [[ "$has_historical_wrappers" != "true" && -n "$snapshot_line" && -n "$entries_line" && -n "$entry_heading_line" && -n "$legacy_entry_heading_line" ]]; then
    if [[ "$entry_heading_line" -lt "$snapshot_line" && "$legacy_entry_heading_line" -lt "$snapshot_line" && "$snapshot_line" -lt "$entries_line" ]]; then
      printf 'legacy-known\n'
      return
    fi
  fi

  printf 'unknown\n'
}

migrate_legacy_context_log_if_needed() {
  local file_path="$project_dir/context-log.md"
  local rel="agent-vault/context-log.md"
  local layout=""
  local project_slug=""
  local display_project=""
  local active_branch=""
  local title_line=""
  local snapshot_line=""
  local entries_line=""
  local prefix_start_line=""
  local prefix_end_line=""
  local legacy_unindexed_body=""
  local historical_snapshot_body=""
  local historical_entries_body=""
  local tmp_file=""

  layout="$(classify_context_log_layout "$file_path")"

  case "$layout" in
    missing | current)
      return
      ;;
    unknown)
      echo "Skip: $rel (legacy or unrecognized layout; manual migration required)"
      skipped=$((skipped + 1))
      context_log_manual_migration_warning="true"
      return
      ;;
    legacy-known)
      ;;
    *)
      echo "Error: unknown context-log layout classification: $layout" >&2
      exit 1
      ;;
  esac

  project_slug="$(extract_frontmatter_value "$file_path" "project")"
  if [[ -z "$project_slug" ]]; then
    project_slug="$(basename "$canonical_repo_path")"
  fi

  display_project="$(extract_section_body "$file_path" "## Current Snapshot" | awk '
    index($0, "- Project:") == 1 {
      value = substr($0, length("- Project:") + 1)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      print value
      exit
    }
  ')"
  if [[ -z "$display_project" ]]; then
    display_project="$project_slug"
  fi

  active_branch="$(infer_active_branch "$canonical_repo_path")"
  title_line="$(first_matching_line_number "$file_path" '^# Context Log$')"
  snapshot_line="$(first_matching_line_number "$file_path" '^## Current Snapshot$')"
  entries_line="$(first_matching_line_number "$file_path" '^## Entries$')"

  prefix_start_line=1
  if [[ -n "$title_line" ]]; then
    prefix_start_line=$((title_line + 1))
  fi
  prefix_end_line=$((snapshot_line - 1))

  if [[ "$prefix_start_line" -le "$prefix_end_line" ]]; then
    legacy_unindexed_body="$(sed -n "${prefix_start_line},${prefix_end_line}p" "$file_path")"
  fi
  historical_snapshot_body="$(extract_section_body "$file_path" "## Current Snapshot")"
  historical_entries_body="$(sed -n "$((entries_line + 1)),\$p" "$file_path")"

  tmp_file="$(mktemp "${TMPDIR:-/tmp}/agent-vault-context-log-migration.XXXXXX")"
  trap 'rm -f "$tmp_file"; trap - RETURN' RETURN

  {
    printf -- '---\n'
    printf 'type: context-log\n'
    printf 'project: %s\n' "$project_slug"
    printf 'last_updated: %s\n' "$today"
    printf -- '---\n\n'
    printf '# Context Log\n\n'
    printf '## Current Snapshot\n'
    printf -- '- Project: %s\n' "$display_project"
    printf -- '- Primary goal: Preserve existing cross-session context while using this validator-compatible layout for future updates.\n'
    printf -- '- Current status: This context log was auto-migrated during `update-project.sh`. Historical content is preserved below, and future updates should use the top-level `## Entries` section.\n'
    printf -- '- Active branch: `%s`\n' "$active_branch"
    printf -- '- Last updated: %s\n\n' "$today"
    printf '## Entries\n\n'
    printf '### %s local - update-project - context-log-layout-migration\n' "$now_local"
    printf '#### Goal\n'
    printf 'Migrate this context log into the validator-compatible layout while preserving existing historical content.\n\n'
    printf '#### State\n'
    printf -- '- Added a top-level `## Current Snapshot` and `## Entries` block for future updates.\n'
    printf -- '- Preserved prior context-log content below under historical sections instead of rewriting old entries in place.\n'
    printf -- '- Future substantive sessions should add new entries to the top-level `## Entries` section.\n\n'
    printf '#### Decisions\n'
    printf -- '- Auto-migrate the recognized legacy generated layout during scaffold sync.\n'
    printf -- '- Preserve older sections below rather than normalizing all historical content in the same migration.\n\n'
    printf '#### Open Questions\n'
    printf -- '- None.\n\n'
    printf '#### Next Prompt\n'
    printf '"Continue working from the top-level `## Current Snapshot` and `## Entries` sections in `agent-vault/context-log.md`."\n\n'
    printf '#### References\n'
    printf -- '- `agent-vault/context-log.md`\n'
    printf -- '- `agent-vault/shared-rules.md`\n'
    printf -- '- `agent-vault/_assets/hooks/pre-commit`\n'
    printf -- '- `agent-vault/_assets/hooks/pre-push`\n'
  } >"$tmp_file"

  if [[ -n "$legacy_unindexed_body" ]]; then
    {
      printf '\n## Legacy Unindexed Entries\n'
      printf '%s\n' "$legacy_unindexed_body"
    } >>"$tmp_file"
  fi

  if [[ -n "$historical_snapshot_body" ]]; then
    {
      printf '\n## Historical Snapshot\n'
      printf '%s\n' "$historical_snapshot_body"
    } >>"$tmp_file"
  fi

  if [[ -n "$historical_entries_body" ]]; then
    {
      printf '\n## Historical Indexed Entries\n'
      printf '%s\n' "$historical_entries_body"
    } >>"$tmp_file"
  fi

  replace_file_from_tmp "$tmp_file" "$file_path"

  trap - RETURN
  rm -f "$tmp_file"
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
    done <<<"$block"

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

is_managed_helper_script() {
  local file_path="$1"
  local marker="$2"

  [[ -f "$file_path" ]] || return 1
  has_exact_line "$file_path" "$marker"
}

is_managed_cursor_rule() {
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

sync_managed_executable_file() {
  local src="$1"
  local dest="$2"

  sync_managed_file "$src" "$dest"

  if [[ "$dry_run" != "true" && -f "$dest" ]]; then
    chmod +x "$dest"
  fi
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
  local policy_rel=""
  local skip="false"

  if [[ "$sync_templates" != "true" ]]; then
    return
  fi

  while IFS= read -r -d '' src_file; do
    rel="${src_file#$src_root/}"
    skip="false"

    for policy_rel in "${POLICY_TEMPLATE_REL_PATHS[@]}"; do
      if [[ "$rel" == "$policy_rel" ]]; then
        skip="true"
        break
      fi
    done

    if [[ "$skip" == "true" ]]; then
      continue
    fi

    dest="$dest_root/$rel"
    sync_managed_file "$src_file" "$dest"
  done < <(find "$src_root" -type f -print0)
}

sync_project_owned_file_if_requested() {
  local src="$1"
  local dest="$2"
  local option_name="$3"
  local sync_enabled="$4"
  local rel

  rel="$(repo_relative_path "$dest")"

  if [[ "$sync_enabled" == "true" ]]; then
    sync_managed_file "$src" "$dest"
    return
  fi

  if [[ ! -e "$dest" ]]; then
    echo "Skip: $rel (project-owned file missing; use $option_name to seed from scaffold)"
    skipped=$((skipped + 1))
    return
  fi

  if cmp -s "$src" "$dest"; then
    echo "Unchanged: $rel (project-owned file matches scaffold)"
    unchanged=$((unchanged + 1))
    return
  fi

  echo "Skip: $rel (project-owned file differs from scaffold; review manually or use $option_name to replace with backup)"
  coding_standards_manual_merge_warning="true"
  skipped=$((skipped + 1))
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

sync_root_helper_script_if_managed() {
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
    sync_managed_executable_file "$src" "$dest"
    return
  fi

  if is_managed_helper_script "$dest" "$marker"; then
    sync_managed_executable_file "$src" "$dest"
    return
  fi

  if [[ "$migrate_root_scripts" == "true" ]]; then
    echo "Migrating: $rel (unmanaged -> managed helper script)"
    sync_managed_executable_file "$src" "$dest"
    return
  fi

  echo "Skip: $rel (unmanaged root helper script; use --migrate-root-scripts to replace)"
  skipped=$((skipped + 1))
}

sync_cursor_rule_if_managed() {
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

  if is_managed_cursor_rule "$dest" "$marker"; then
    sync_managed_file "$src" "$dest"
    return
  fi

  echo "Skip: $rel (unmanaged Cursor rule; move or rename it before re-running update-project.sh)"
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
    : >"$gitignore_path"
  fi

  for line in "${missing_lines[@]}"; do
    printf '%s\n' "$line" >>"$gitignore_path"
  done

  if [[ "$existed" == "true" ]]; then
    echo "Updated: .gitignore (added ${#missing_lines[@]} managed ignore entries)"
    updated=$((updated + 1))
  else
    echo "Created: .gitignore (added ${#missing_lines[@]} managed ignore entries)"
    created=$((created + 1))
  fi
}

preflight_symlink_checks

sync_root_wrapper_if_managed "$root_scaffold_dir/AGENTS.md" "$canonical_repo_path/AGENTS.md" "$ROOT_AGENTS_MARKER"
sync_root_wrapper_if_managed "$root_scaffold_dir/CLAUDE.md" "$canonical_repo_path/CLAUDE.md" "$ROOT_CLAUDE_MARKER"
sync_root_wrapper_if_managed "$root_scaffold_dir/GEMINI.md" "$canonical_repo_path/GEMINI.md" "$ROOT_GEMINI_MARKER"
sync_cursor_rule_if_managed "$root_scaffold_dir/.cursor/rules/agent-vault.mdc" "$canonical_repo_path/.cursor/rules/agent-vault.mdc" "$CURSOR_AGENT_VAULT_RULE_MARKER"
seed_if_missing "$root_scaffold_dir/.github/pull_request_template.md" "$canonical_repo_path/.github/pull_request_template.md"
seed_if_missing "$root_scaffold_dir/docs/design.md" "$canonical_repo_path/docs/design.md"
seed_if_missing "$root_scaffold_dir/docs/runbooks/parallel-agent-worktrees.md" "$canonical_repo_path/docs/runbooks/parallel-agent-worktrees.md"
sync_root_helper_script_if_managed "$root_scaffold_dir/scripts/new-worktree.sh" "$canonical_repo_path/scripts/new-worktree.sh" "$NEW_WORKTREE_HELPER_MARKER"
sync_root_helper_script_if_managed "$root_scaffold_dir/scripts/remove-worktree.sh" "$canonical_repo_path/scripts/remove-worktree.sh" "$REMOVE_WORKTREE_HELPER_MARKER"
sync_root_helper_script_if_managed "$root_scaffold_dir/scripts/check-memory-budget.sh" "$canonical_repo_path/scripts/check-memory-budget.sh" "$CHECK_MEMORY_BUDGET_HELPER_MARKER"
sync_root_helper_script_if_managed "$root_scaffold_dir/scripts/check-context-log-rollover.sh" "$canonical_repo_path/scripts/check-context-log-rollover.sh" "$CHECK_CONTEXT_LOG_ROLLOVER_HELPER_MARKER"
sync_project_owned_file_if_requested "$vault_scaffold_dir/coding-standards.md" "$project_dir/coding-standards.md" "--sync-coding-standards" "$sync_coding_standards"
seed_if_missing "$vault_scaffold_dir/project-context.md" "$project_dir/project-context.md"
seed_if_missing "$vault_scaffold_dir/project-commands.md" "$project_dir/project-commands.md"

sync_managed_file "$vault_scaffold_dir/shared-rules.md" "$project_dir/shared-rules.md"
sync_managed_file "$vault_scaffold_dir/review-policy.md" "$project_dir/review-policy.md"
sync_managed_file "$vault_scaffold_dir/AGENTS.md" "$project_dir/AGENTS.md"
sync_managed_file "$vault_scaffold_dir/CLAUDE.md" "$project_dir/CLAUDE.md"
sync_managed_file "$vault_scaffold_dir/GEMINI.md" "$project_dir/GEMINI.md"
sync_managed_file "$vault_scaffold_dir/handoff.md" "$project_dir/handoff.md"
migrate_legacy_context_log_if_needed
sync_managed_file "$vault_scaffold_dir/_assets/hooks/README.md" "$project_dir/_assets/hooks/README.md"
sync_managed_file "$vault_scaffold_dir/_assets/hooks/lib/runtime-note.sh" "$project_dir/_assets/hooks/lib/runtime-note.sh"
sync_managed_executable_file "$vault_scaffold_dir/_assets/hooks/pre-commit" "$project_dir/_assets/hooks/pre-commit"
sync_managed_executable_file "$vault_scaffold_dir/_assets/hooks/pre-push" "$project_dir/_assets/hooks/pre-push"
sync_managed_file "$vault_scaffold_dir/design-log/README.md" "$project_dir/design-log/README.md"
sync_managed_file "$vault_scaffold_dir/context/handoffs/README.md" "$project_dir/context/handoffs/README.md"
sync_managed_file "$vault_scaffold_dir/decisions/README.md" "$project_dir/decisions/README.md"
sync_managed_file "$vault_scaffold_dir/daily/README.md" "$project_dir/daily/README.md"
sync_managed_file "$vault_scaffold_dir/Templates/Decision Record.md" "$project_dir/Templates/Decision Record.md"

seed_if_missing "$vault_scaffold_dir/lessons.md" "$project_dir/lessons.md"
sync_template_files "$vault_scaffold_dir/Templates" "$project_dir/Templates"

ensure_managed_gitignore_entries "$canonical_repo_path"

hook_rc=0
configure_tracked_hooks_path "$canonical_repo_path" "$dry_run" || hook_rc=$?

echo
echo "Summary:"
echo "- created: $created"
echo "- updated: $updated"
echo "- unchanged: $unchanged"
echo "- skipped: $skipped"
echo "- backups: $backed_up"
actual_hooks_path="$(git -C "$canonical_repo_path" config --get core.hooksPath 2>/dev/null || true)"
if [[ "$actual_hooks_path" == "agent-vault/_assets/hooks" ]]; then
  echo "- hook: enabled"
elif [[ "$hook_rc" -eq 0 && "$dry_run" == "true" ]]; then
  echo "- hook: would enable"
else
  echo "- hook: NOT active (see warning below)"
fi

if [[ "$dry_run" == "true" ]]; then
  echo "Dry run complete. No files were written."
elif [[ "$backed_up" -gt 0 ]]; then
  echo "Backups saved under: $backup_dir"
fi

if [[ "$coding_standards_manual_merge_warning" == "true" ]]; then
  echo
  echo "Warning: agent-vault/coding-standards.md differs from the scaffold and was left unchanged." >&2
  echo "If you want the newer scaffold standards, merge them manually or rerun update-project.sh with --sync-coding-standards to replace the file with a backup." >&2
fi

if [[ "$context_log_manual_migration_warning" == "true" ]]; then
  echo
  echo "Warning: agent-vault/context-log.md uses a legacy or unrecognized layout and was left unchanged." >&2
  echo "The stricter tracked hook expects a top-level \`## Current Snapshot\` section followed by \`## Entries\`." >&2
  echo "Before the next substantive metadata-gated commit, add that top-level block and make sure frontmatter \`last_updated\` and snapshot \`Last updated\` match the top entry date." >&2
fi

if [[ "$hook_rc" -ne 0 ]]; then
  echo
  echo "Warning: tracked metadata hook could not be activated automatically." >&2
  echo "To enable it manually, run:" >&2
  echo "  git -C \"$canonical_repo_path\" config core.hooksPath agent-vault/_assets/hooks" >&2
fi

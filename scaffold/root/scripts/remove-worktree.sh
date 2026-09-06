#!/usr/bin/env bash
# agent-vault-managed: helper-script; file=remove-worktree.sh

# Safely remove one issue-scoped git worktree created for an agent session.
# Run from the main checkout or another directory outside the target worktree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="${SCRIPT_DIR%/*}"

usage() {
  cat <<EOF
Usage: $0 (--branch NAME | --path DIR) [--delete-branch] [--force]

Remove a non-primary git worktree from a safe working directory.
Requires Git 2.36+ and Bash 3.2+. Linked helper copies use the primary checkout.

Options:
  --branch NAME     Local branch name attached to the worktree to remove
  --path DIR        Worktree path to remove. Relative paths are resolved from
                    the primary checkout.
  --delete-branch   Delete the local branch with git branch -D after removal.
                    Use only after verifying the PR is merged or after owner
                    confirmation that the branch is disposable.
  --force           Pass --force to git worktree remove. Use only after owner
                    confirmation for an intentionally disposable dirty worktree.
  -h, --help        Show this help

Removal refuses any registered descendant worktree, even with --force.
For a missing descendant, verify whether it was deleted, moved, or is temporarily
unavailable. Restore/repair it when appropriate. For confirmed obsolete records,
preview git worktree prune --dry-run --verbose, inspect all proposed removals,
then prune and retry. This helper never prunes a descendant to bypass the guard.

Automatic stale-record pruning is refused if another registered worktree is
missing or prunable. Inspect those records before any repository-wide prune.

Protected branches: main, master, the primary checkout's attached branch,
locally recorded remote defaults, and additional literal names configured with:
  git config --local --add agentVault.protectedBranch develop
Remote defaults may be absent or stale. Without remotes, only the other sources
apply. Neither --force nor --delete-branch overrides branch protection.
To retire a protected branch manually, obtain owner confirmation and verify its
commits are retained before deletion. The worktree runbook has additional guidance.

Examples:
  $0 --branch codex/123-feature-slice
  $0 --branch codex/123-feature-slice --delete-branch
  $0 --path .worktrees/codex-123-feature-slice --force
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

# Keep this small standalone block identical in both worktree helpers.
# The sync suite checks the copies; generated scripts need no support library.
# BEGIN worktree discovery
require_git_version() {
  local version major minor
  version="$(git --version)" || die "Could not determine Git version; Git 2.36+ is required."
  if [[ "$version" =~ ^git\ version\ ([0-9]+)\.([0-9]+)(\.|$|[[:space:]]) ]]; then
    major=$((10#${BASH_REMATCH[1]}))
    minor=$((10#${BASH_REMATCH[2]}))
    if ((major > 2 || (major == 2 && minor >= 36))); then
      return
    fi
  fi
  die "Git 2.36+ is required; found: $version. Upgrade Git and ensure the supported executable is first on PATH."
}

# Return paths in a variable: command substitution would strip trailing newlines.
# Resolve each existing component physically before interpreting subsequent '..'.
# Missing suffixes are allowed, but dangling symlinks and inaccessible paths are not.
canonical_path() {
  local remaining="$1" component next physical="/"
  [[ "$remaining" == /* ]] || die "Expected an absolute path: $remaining"
  remaining="${remaining#/}"
  while [[ -n "$remaining" ]]; do
    component="${remaining%%/*}"
    if [[ "$remaining" == */* ]]; then
      remaining="${remaining#*/}"
    else
      remaining=""
    fi
    case "$component" in
      '' | '.') continue ;;
      '..')
        physical="${physical%/*}"
        physical="${physical:-/}"
        continue
        ;;
    esac
    if [[ -d "$physical" && ! -x "$physical" ]]; then
      die "Cannot safely resolve inaccessible path: $physical"
    fi
    next="${physical%/}/$component"
    if [[ -d "$next" ]]; then
      physical="$(cd -P -- "$next" && printf '%s/.' "$PWD")" ||
        die "Cannot safely resolve path: $next"
      physical="${physical%/.}"
    elif [[ -e "$next" || -L "$next" ]]; then
      die "Cannot safely resolve non-directory or dangling symlink: $next"
    else
      physical="$next"
    fi
  done
  CANONICAL_PATH="$physical"
}

read_git_path() {
  local checkout="$1"
  shift
  GIT_PATH="$(git -C "$checkout" rev-parse "$@" && printf '.')" ||
    die "Could not resolve repository identity: $checkout. Restore access or repair repository/worktree metadata before retrying."
  GIT_PATH="${GIT_PATH%$'\n.'}"
  canonical_path "$GIT_PATH"
  GIT_PATH="$CANONICAL_PATH"
}

load_worktrees() {
  local field="" path="" branch="" locked=false bare=false prunable=false
  git -C "$PROJECT_DIR" worktree list --porcelain -z >"$WORKTREE_SCRATCH/registry" ||
    die "Could not read Git worktree registry; refusing to change worktrees."
  WORKTREE_PATHS=()
  WORKTREE_BRANCHES=()
  WORKTREE_LOCKED=()
  WORKTREE_BARE=()
  WORKTREE_PRUNABLE=()
  while IFS= read -r -d '' field; do
    case "$field" in
      worktree\ *)
        [[ -z "$path" ]] || die "Malformed Git worktree registry."
        path="${field#worktree }"
        ;;
      branch\ refs/heads/*) branch="${field#branch refs/heads/}" ;;
      locked | locked\ *) locked=true ;;
      bare) bare=true ;;
      prunable | prunable\ *) prunable=true ;;
      HEAD\ * | detached) ;;
      '')
        [[ -n "$path" ]] || die "Malformed Git worktree registry."
        canonical_path "$path"
        WORKTREE_PATHS+=("$CANONICAL_PATH")
        WORKTREE_BRANCHES+=("$branch")
        WORKTREE_LOCKED+=("$locked")
        WORKTREE_BARE+=("$bare")
        WORKTREE_PRUNABLE+=("$prunable")
        path=""
        branch=""
        locked=false
        bare=false
        prunable=false
        ;;
      *) die "Unrecognized Git worktree registry field: $field" ;;
    esac
  done <"$WORKTREE_SCRATCH/registry"
  [[ -z "$path" && -z "$field" && ${#WORKTREE_PATHS[@]} -gt 0 ]] ||
    die "Incomplete Git worktree registry; refusing to change worktrees."
}

initialize_repository() {
  require_git_version
  read_git_path "$PROJECT_DIR" --show-toplevel
  SOURCE_CHECKOUT="$GIT_PATH"
  read_git_path "$SOURCE_CHECKOUT" --path-format=absolute --git-common-dir
  COMMON_DIR="$GIT_PATH"
  WORKTREE_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-worktree.XXXXXX")" ||
    die "Could not create worktree inspection scratch directory."
  trap 'rm -rf -- "$WORKTREE_SCRATCH"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  load_worktrees
  PROJECT_DIR="${WORKTREE_PATHS[0]}"
  [[ "${WORKTREE_BARE[0]}" == false && -d "$PROJECT_DIR" ]] ||
    die "The primary checkout is unavailable or bare. Restore a non-bare primary checkout before using this helper."
  read_git_path "$PROJECT_DIR" --show-toplevel
  [[ "$GIT_PATH" == "$PROJECT_DIR" ]] || die "Primary checkout identity is inconsistent: $PROJECT_DIR. Restore a conventional primary-checkout layout or repair repository/worktree metadata before retrying."
  read_git_path "$PROJECT_DIR" --path-format=absolute --git-common-dir
  [[ "$GIT_PATH" == "$COMMON_DIR" ]] || die "Primary checkout belongs to a different repository: $PROJECT_DIR. Repair repository/worktree metadata before retrying."
}

find_branch_index() {
  local name="$1" i
  WORKTREE_INDEX=-1
  for ((i = 0; i < ${#WORKTREE_PATHS[@]}; i++)); do
    if [[ "${WORKTREE_BRANCHES[$i]}" == "$name" ]]; then
      WORKTREE_INDEX="$i"
      break
    fi
  done
}

# Git pruning is repository-wide, not scoped to the branch being recovered.
# Preserve every other missing/prunable record until an operator inspects it.
ensure_safe_prune() {
  local requested="$1" i registered
  load_worktrees
  for ((i = 0; i < ${#WORKTREE_PATHS[@]}; i++)); do
    registered="${WORKTREE_PATHS[$i]}"
    if [[ "$registered" != "$requested" && (! -d "$registered" || "${WORKTREE_PRUNABLE[$i]}" == true) ]]; then
      die "Refusing automatic prune because another registered worktree is missing or prunable: $registered. Verify whether it was deleted, moved, is temporarily unavailable, or needs metadata repair; restore/repair as appropriate. For confirmed obsolete records, preview git worktree prune --dry-run --verbose, inspect all proposed removals, then prune and retry."
    fi
  done
}

path_contains() {
  [[ "$2" == "$1" || "$2" == "${1%/}/"* ]]
}
# END worktree discovery

delete_local_branch() {
  local branch_name="$1"

  load_worktrees
  ensure_deletable_branch "$branch_name"
  git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$branch_name" ||
    die "No local branch found: $branch_name"
  git -C "$PROJECT_DIR" branch -D -- "$branch_name"
}

ensure_deletable_branch() {
  local name="$1" reason="" configured remote ref status=0
  git check-ref-format "refs/heads/$name" >/dev/null ||
    die "Invalid literal branch name: $name"
  git -C "$PROJECT_DIR" config --local --null --get-all agentVault.protectedBranch >"$WORKTREE_SCRATCH/protected" || status=$?
  [[ "$status" -eq 0 || "$status" -eq 1 ]] ||
    die "Could not read agentVault.protectedBranch configuration."
  while IFS= read -r -d '' configured; do
    [[ -n "$configured" ]] && git check-ref-format "refs/heads/$configured" >/dev/null ||
      die "Invalid literal branch name in agentVault.protectedBranch configuration: $configured"
    [[ "$configured" != "$name" ]] || reason="configured in agentVault.protectedBranch"
  done <"$WORKTREE_SCRATCH/protected"

  if [[ "$name" == main || "$name" == master ]]; then
    reason="conventional integration branch"
  elif [[ "$name" == "${WORKTREE_BRANCHES[0]}" ]]; then
    reason="attached to the primary checkout"
  fi
  git -C "$PROJECT_DIR" remote >"$WORKTREE_SCRATCH/remotes" ||
    die "Could not list remotes for branch protection."
  while IFS= read -r remote; do
    [[ -n "$remote" ]] || continue
    status=0
    ref="$(git -C "$PROJECT_DIR" symbolic-ref -q "refs/remotes/$remote/HEAD")" || status=$?
    if [[ "$status" -eq 1 ]]; then
      continue
    fi
    [[ "$status" -eq 0 ]] || die "Could not read default branch for remote: $remote"
    [[ "$ref" == "refs/remotes/$remote/"* ]] ||
      die "Unexpected remote HEAD reference: $ref"
    [[ "${ref#"refs/remotes/$remote/"}" != "$name" ]] || reason="recorded default for remote $remote"
  done <"$WORKTREE_SCRATCH/remotes"
  if [[ -n "$reason" ]]; then
    die "Refusing to delete protected branch '$name': $reason. To retire it manually, obtain owner confirmation and verify its commits are retained before deletion. Neither --force nor --delete-branch bypasses this guard. See docs/runbooks/parallel-agent-worktrees.md for additional guidance."
  fi
}

find_shared_editable_binding() {
  local target_path="$1"
  local venv_dir="$PROJECT_DIR/.venv"
  local pth_file=""
  local bound_path=""
  local line=""

  BOUND_EDITABLE_PATH=""
  [[ -d "$venv_dir" ]] || return 0

  while IFS= read -r -d '' pth_file; do
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      [[ "$line" != \#* ]] || continue
      [[ -d "$line" ]] || continue
      [[ "$line" == /* ]] || line="$PWD/$line"
      canonical_path "$line"
      bound_path="$CANONICAL_PATH"
      if [[ "$bound_path" == "$target_path" || "$bound_path" == "$target_path/"* ]]; then
        BOUND_EDITABLE_PATH="$bound_path"
        return 0
      fi
    done <"$pth_file"
  done < <(find "$venv_dir" -type f -path '*/site-packages/*.pth' -print0 2>/dev/null)

  return 0
}

find_path_index() {
  local target="$1" i
  WORKTREE_INDEX=-1
  for ((i = 0; i < ${#WORKTREE_PATHS[@]}; i++)); do
    if [[ "${WORKTREE_PATHS[$i]}" == "$target" ]]; then
      WORKTREE_INDEX="$i"
      break
    fi
  done
}

ensure_safe_cwd() {
  local target_path="$1"
  local pwd_real

  canonical_path "$PWD"
  pwd_real="$CANONICAL_PATH"
  case "$pwd_real/" in
    "$target_path/"*)
      die "Refusing to remove worktree containing current working directory: $target_path. Run this command from $PROJECT_DIR or /tmp and retry."
      ;;
  esac
}

ensure_safe_removal() {
  local target="$1" i registered
  [[ "$target" != "$PROJECT_DIR" ]] ||
    die "Refusing to remove primary checkout: $PROJECT_DIR"
  ensure_safe_cwd "$target"
  for ((i = 0; i < ${#WORKTREE_PATHS[@]}; i++)); do
    registered="${WORKTREE_PATHS[$i]}"
    if [[ "$registered" != "$target" ]] && path_contains "$target" "$registered"; then
      die "Refusing to remove worktree containing descendant worktree: $registered. Preserve its contents and arrange separate cleanup or relocation. If missing, verify whether it was deleted, moved, or is temporarily unavailable; restore/repair as appropriate. For confirmed obsolete records, preview git worktree prune --dry-run --verbose, inspect all proposed removals, then prune and retry."
    fi
  done
  find_shared_editable_binding "$target"
  if [[ -n "$BOUND_EDITABLE_PATH" ]]; then
    die "Refusing to remove worktree while the shared .venv editable install points inside it: $BOUND_EDITABLE_PATH. Reinstall the editable package from the main checkout first, then retry."
  fi
}

BRANCH_NAME=""
TARGET_PATH=""
DELETE_BRANCH=false
FORCE_REMOVE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      [[ $# -ge 2 ]] || die "Missing value for --branch"
      BRANCH_NAME="$2"
      shift 2
      ;;
    --path)
      [[ $# -ge 2 ]] || die "Missing value for --path"
      TARGET_PATH="$2"
      shift 2
      ;;
    --delete-branch)
      DELETE_BRANCH=true
      shift
      ;;
    --force)
      FORCE_REMOVE=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

if [[ -z "$BRANCH_NAME" && -z "$TARGET_PATH" ]]; then
  die "Either --branch or --path is required"
fi
initialize_repository
if [[ -n "$TARGET_PATH" ]]; then
  [[ "$TARGET_PATH" == /* ]] || TARGET_PATH="$PROJECT_DIR/$TARGET_PATH"
  canonical_path "$TARGET_PATH"
  TARGET_PATH="$CANONICAL_PATH"
  [[ -d "$TARGET_PATH" ]] || die "Worktree path does not exist: $TARGET_PATH"
fi

if [[ -n "$BRANCH_NAME" ]]; then
  git check-ref-format "refs/heads/$BRANCH_NAME" >/dev/null ||
    die "Invalid literal branch name: $BRANCH_NAME"
  if [[ "$DELETE_BRANCH" == true ]]; then
    ensure_deletable_branch "$BRANCH_NAME"
  fi
  find_branch_index "$BRANCH_NAME"
  if [[ "$WORKTREE_INDEX" -lt 0 ]]; then
    if [[ "$DELETE_BRANCH" == true && -z "$TARGET_PATH" ]]; then
      echo "No worktree found for branch; deleting local branch only:"
      echo "  Branch: $BRANCH_NAME"
      delete_local_branch "$BRANCH_NAME"
      exit 0
    fi
    die "No worktree found for branch: $BRANCH_NAME"
  fi
  resolved_path="${WORKTREE_PATHS[$WORKTREE_INDEX]}"
  if [[ -n "$TARGET_PATH" && "$TARGET_PATH" != "$resolved_path" ]]; then
    die "--branch and --path refer to different worktrees"
  fi
  ensure_safe_removal "$resolved_path"
  if [[ ! -d "$resolved_path" ]]; then
    [[ -z "$TARGET_PATH" ]] || die "Worktree path does not exist: $TARGET_PATH"
    [[ "${WORKTREE_LOCKED[$WORKTREE_INDEX]}" == false ]] ||
      die "Missing worktree is locked: $resolved_path. Restore or repair it before retrying."
    ensure_safe_prune "$resolved_path"
    git -C "$PROJECT_DIR" worktree prune || die "Could not prune stale worktree metadata."
    load_worktrees
    find_branch_index "$BRANCH_NAME"
    [[ "$WORKTREE_INDEX" -lt 0 ]] || die "Branch still has a registered worktree: $BRANCH_NAME"
    if [[ "$DELETE_BRANCH" == true && -z "$TARGET_PATH" ]]; then
      echo "Pruned stale worktree record for missing directory: $resolved_path"
      echo "Deleting remaining local branch:"
      echo "  Branch: $BRANCH_NAME"
      delete_local_branch "$BRANCH_NAME"
      exit 0
    fi
    die "Worktree record for branch '$BRANCH_NAME' points to a missing directory. Stale metadata was pruned; pass --delete-branch without --path to delete the remaining local branch."
  fi
  TARGET_PATH="$resolved_path"
fi

[[ -d "$TARGET_PATH" ]] || die "Worktree path does not exist: $TARGET_PATH"
find_path_index "$TARGET_PATH"
[[ "$WORKTREE_INDEX" -ge 0 ]] || die "Path is not a registered worktree: $TARGET_PATH"
BRANCH_NAME="${WORKTREE_BRANCHES[$WORKTREE_INDEX]}"

if [[ "$DELETE_BRANCH" == true ]]; then
  [[ -n "$BRANCH_NAME" ]] || die "--delete-branch requires a branch-backed worktree"
  ensure_deletable_branch "$BRANCH_NAME"
fi

# Recheck the registry immediately before removal. This does not serialize
# concurrent raw Git commands or filesystem changes; see the runbook.
load_worktrees
find_path_index "$TARGET_PATH"
[[ "$WORKTREE_INDEX" -ge 0 ]] || die "Worktree registration changed; retry after inspecting it."
[[ "${WORKTREE_BRANCHES[$WORKTREE_INDEX]}" == "$BRANCH_NAME" ]] ||
  die "Worktree branch changed; retry after inspecting it."
ensure_safe_removal "$TARGET_PATH"
if [[ "$DELETE_BRANCH" == true ]]; then
  ensure_deletable_branch "$BRANCH_NAME"
fi

if [[ "$FORCE_REMOVE" == true ]]; then
  git -C "$PROJECT_DIR" worktree remove "$TARGET_PATH" --force
else
  git -C "$PROJECT_DIR" worktree remove "$TARGET_PATH"
fi

echo "Removed worktree:"
echo "  Path: $TARGET_PATH"
if [[ -n "$BRANCH_NAME" ]]; then
  echo "  Branch: $BRANCH_NAME"
fi

if [[ "$DELETE_BRANCH" == true ]]; then
  delete_local_branch "$BRANCH_NAME"
fi

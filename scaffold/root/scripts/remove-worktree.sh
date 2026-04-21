#!/usr/bin/env bash
# agent-vault-managed: helper-script; file=remove-worktree.sh

# Safely remove one issue-scoped git worktree created for an agent session.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

usage() {
    cat <<EOF
Usage: $0 (--branch NAME | --path DIR) [--delete-branch] [--force]

Remove a non-primary git worktree from a safe working directory.

Options:
  --branch NAME     Local branch name attached to the worktree to remove
  --path DIR        Worktree path to remove. Relative paths are resolved from
                    the current repo root.
  --delete-branch   Delete the local branch with git branch -D after removal.
                    Use only after the PR is merged or the branch is disposable.
  --force           Pass --force to git worktree remove.
  -h, --help        Show this help

Examples:
  $0 --branch codex/123-feature-slice
  $0 --branch codex/123-feature-slice --delete-branch
  $0 --path ../example-app-wt/codex-123-feature-slice --force
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

resolve_path() {
    local raw="$1"
    if [[ "$raw" = /* ]]; then
        printf '%s\n' "$raw"
    else
        printf '%s\n' "$PROJECT_DIR/$raw"
    fi
}

canonical_dir() {
    local path="$1"
    (
        cd "$path" || return 1
        pwd -P
    )
}

find_shared_editable_binding() {
    local target_path="$1"
    local venv_dir="$PROJECT_DIR/.venv"
    local pth_file=""
    local bound_path=""
    local line=""

    [[ -d "$venv_dir" ]] || return 1

    while IFS= read -r -d '' pth_file; do
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -n "$line" ]] || continue
            [[ "$line" != \#* ]] || continue
            [[ -d "$line" ]] || continue
            bound_path="$(canonical_dir "$line" 2>/dev/null || true)"
            [[ -n "$bound_path" ]] || continue
            if [[ "$bound_path" == "$target_path" || "$bound_path" == "$target_path/"* ]]; then
                printf '%s\n' "$bound_path"
                return 0
            fi
        done < "$pth_file"
    done < <(find "$venv_dir" -type f -path '*/site-packages/*.pth' -print0 2>/dev/null)

    return 1
}

find_branch_worktree() {
    local branch_name="$1"
    local current_worktree=""
    local line=""

    while IFS= read -r line; do
        case "$line" in
            worktree\ *)
                current_worktree="${line#worktree }"
                ;;
            branch\ refs/heads/*)
                if [[ "${line#branch refs/heads/}" == "$branch_name" ]]; then
                    printf '%s\n' "$current_worktree"
                    return 0
                fi
                ;;
        esac
    done < <(git -C "$PROJECT_DIR" worktree list --porcelain)

    return 1
}

find_worktree_branch() {
    local target_path="$1"
    local current_worktree=""
    local current_branch=""
    local current_worktree_real=""
    local line=""

    while IFS= read -r line; do
        case "$line" in
            worktree\ *)
                current_worktree="${line#worktree }"
                ;;
            branch\ refs/heads/*)
                current_branch="${line#branch refs/heads/}"
                current_worktree_real="$(canonical_dir "$current_worktree" 2>/dev/null || true)"
                if [[ "$current_worktree_real" == "$target_path" ]]; then
                    printf '%s\n' "$current_branch"
                    return 0
                fi
                ;;
        esac
    done < <(git -C "$PROJECT_DIR" worktree list --porcelain)

    return 1
}

require_git_repo() {
    git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "Not inside a git worktree: $PROJECT_DIR"
}

ensure_safe_cwd() {
    local target_path="$1"
    local pwd_real

    pwd_real="$(pwd -P)"
    case "$pwd_real/" in
        "$target_path/"*)
            die "Refusing to remove worktree containing current working directory: $target_path. Run this command from $PROJECT_DIR or /tmp and retry."
            ;;
    esac
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
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

require_git_repo

if [[ -z "$BRANCH_NAME" && -z "$TARGET_PATH" ]]; then
    die "Either --branch or --path is required"
fi

if [[ -n "$BRANCH_NAME" ]]; then
    resolved_path="$(find_branch_worktree "$BRANCH_NAME" || true)"
    [[ -n "$resolved_path" ]] || die "No worktree found for branch: $BRANCH_NAME"
    if [[ ! -d "$resolved_path" ]]; then
        git -C "$PROJECT_DIR" worktree prune >/dev/null 2>&1 || true
        die "Worktree record for branch '$BRANCH_NAME' points to a missing directory. Stale metadata was pruned; rerun this command to remove the remaining branch."
    fi
    resolved_path="$(canonical_dir "$resolved_path")" \
        || die "Worktree path does not exist: $resolved_path"
    if [[ -n "$TARGET_PATH" ]]; then
        raw_target_path="$(resolve_path "$TARGET_PATH")"
        [[ -d "$raw_target_path" ]] || die "Worktree path does not exist: $raw_target_path"
        TARGET_PATH="$(canonical_dir "$raw_target_path")" \
            || die "Worktree path does not exist: $raw_target_path"
        [[ "$TARGET_PATH" == "$resolved_path" ]] \
            || die "--branch and --path refer to different worktrees"
    else
        TARGET_PATH="$resolved_path"
    fi
else
    raw_target_path="$(resolve_path "$TARGET_PATH")"
    [[ -d "$raw_target_path" ]] || die "Worktree path does not exist: $raw_target_path"
    TARGET_PATH="$(canonical_dir "$raw_target_path")" \
        || die "Worktree path does not exist: $raw_target_path"
fi

[[ -d "$TARGET_PATH" ]] || die "Worktree path does not exist: $TARGET_PATH"

if [[ -z "$BRANCH_NAME" ]]; then
    BRANCH_NAME="$(find_worktree_branch "$TARGET_PATH" || true)"
fi

if [[ "$DELETE_BRANCH" == true ]]; then
    [[ -n "$BRANCH_NAME" ]] || die "--delete-branch requires a branch-backed worktree"
fi

[[ "$TARGET_PATH" != "$PROJECT_DIR" ]] \
    || die "Refusing to remove primary checkout: $PROJECT_DIR"

ensure_safe_cwd "$TARGET_PATH"

bound_editable_path="$(find_shared_editable_binding "$TARGET_PATH" || true)"
if [[ -n "$bound_editable_path" ]]; then
    die "Refusing to remove worktree while the shared .venv editable install points inside it: $bound_editable_path. Reinstall the editable package from the main checkout first, then retry."
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
    git -C "$PROJECT_DIR" branch -D "$BRANCH_NAME"
fi

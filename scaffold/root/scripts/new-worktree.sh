#!/usr/bin/env bash
# agent-vault-managed: helper-script; file=new-worktree.sh

# Create one issue-scoped git worktree for one writing agent.
#
# This only creates or reuses the branch + worktree and prints the next command
# to run from that directory. Launch the writing agent from inside the worktree
# so agent sandboxes use that worktree as their active workspace.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
DEFAULT_ROOT="${PROJECT_DIR}/.worktrees"

usage() {
  cat <<EOF
Usage: $0 --agent NAME --issue NUMBER [--slug TEXT] [--base REF] [--root DIR]

Create or reuse one issue-scoped worktree for one writing agent.

Options:
  --agent NAME   Agent label, for example: codex, claude, gemini
  --issue N      Issue number
  --slug TEXT    Optional short slug, for example: feature-slice
  --base REF     Optional base ref. Defaults to origin/main when available,
                 otherwise main, otherwise the current branch.
  --root DIR     Optional worktree root. Relative paths are resolved from the
                 current repo root. Overrides AGENT_VAULT_WORKTREE_ROOT.
                 Default: $DEFAULT_ROOT
  AGENT_VAULT_WORKTREE_ROOT
                 Optional environment default for the worktree root. Relative
                 paths are resolved from the current repo root.
  -h, --help     Show this help

Examples:
  $0 --agent codex --issue 123 --slug feature-slice
  $0 --agent claude --issue 124 --slug review-cleanup
  $0 --agent gemini --issue 125 --slug docs-followup
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

normalize_token() {
  local raw="$1"
  printf '%s' "$raw" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g'
}

resolve_root_dir() {
  local raw="$1"
  if [[ "$raw" = /* ]]; then
    printf '%s\n' "$raw"
  else
    printf '%s\n' "$PROJECT_DIR/$raw"
  fi
}

default_base_ref() {
  if git -C "$PROJECT_DIR" rev-parse --verify --quiet "refs/remotes/origin/main" >/dev/null; then
    printf 'origin/main\n'
    return
  fi
  if git -C "$PROJECT_DIR" rev-parse --verify --quiet "refs/heads/main" >/dev/null; then
    printf 'main\n'
    return
  fi
  git -C "$PROJECT_DIR" branch --show-current
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

launch_hint() {
  local normalized_agent="$1"
  case "$normalized_agent" in
    codex*)
      printf 'codex\n'
      ;;
    claude*)
      printf 'claude\n'
      ;;
    gemini*)
      printf 'gemini\n'
      ;;
    *)
      printf '\n'
      ;;
  esac
}

print_next_steps() {
  local worktree_path="$1"
  local normalized_agent="$2"
  local hint

  hint="$(launch_hint "$normalized_agent")"

  echo ""
  echo "Next:"
  echo "  cd $worktree_path"
  if [[ -n "$hint" ]]; then
    echo "  $hint"
  else
    echo "  # launch your writing agent from this directory"
  fi
}

require_git_repo() {
  git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "Not inside a git worktree: $PROJECT_DIR"
}

AGENT=""
ISSUE=""
SLUG=""
BASE_REF=""
ROOT_DIR="${AGENT_VAULT_WORKTREE_ROOT:-$DEFAULT_ROOT}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)
      [[ $# -ge 2 ]] || die "Missing value for --agent"
      AGENT="$2"
      shift 2
      ;;
    --issue)
      [[ $# -ge 2 ]] || die "Missing value for --issue"
      ISSUE="$2"
      shift 2
      ;;
    --slug)
      [[ $# -ge 2 ]] || die "Missing value for --slug"
      SLUG="$2"
      shift 2
      ;;
    --base)
      [[ $# -ge 2 ]] || die "Missing value for --base"
      BASE_REF="$2"
      shift 2
      ;;
    --root)
      [[ $# -ge 2 ]] || die "Missing value for --root"
      ROOT_DIR="$2"
      shift 2
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

require_git_repo

[[ -n "$AGENT" ]] || die "--agent is required"
[[ -n "$ISSUE" ]] || die "--issue is required"
[[ "$ISSUE" =~ ^[0-9]+$ ]] || die "--issue must be numeric"

NORMALIZED_AGENT="$(normalize_token "$AGENT")"
[[ -n "$NORMALIZED_AGENT" ]] || die "--agent must contain letters or numbers"

NORMALIZED_SLUG=""
if [[ -n "$SLUG" ]]; then
  NORMALIZED_SLUG="$(normalize_token "$SLUG")"
  [[ -n "$NORMALIZED_SLUG" ]] || die "--slug must contain letters or numbers"
fi

NAME_SUFFIX="$ISSUE"
if [[ -n "$NORMALIZED_SLUG" ]]; then
  NAME_SUFFIX="${NAME_SUFFIX}-${NORMALIZED_SLUG}"
fi

ROOT_DIR="$(resolve_root_dir "$ROOT_DIR")"
BRANCH_NAME="${NORMALIZED_AGENT}/${NAME_SUFFIX}"
WORKTREE_NAME="${NORMALIZED_AGENT}-${NAME_SUFFIX}"

EXISTING_WORKTREE="$(find_branch_worktree "$BRANCH_NAME" || true)"
if [[ -n "$EXISTING_WORKTREE" && ! -d "$EXISTING_WORKTREE" ]]; then
  git -C "$PROJECT_DIR" worktree prune >/dev/null 2>&1 || true
  EXISTING_WORKTREE="$(find_branch_worktree "$BRANCH_NAME" || true)"
fi
if [[ -n "$EXISTING_WORKTREE" ]]; then
  echo "Worktree already exists:"
  echo "  Path: $EXISTING_WORKTREE"
  echo "  Branch: $BRANCH_NAME"
  print_next_steps "$EXISTING_WORKTREE" "$NORMALIZED_AGENT"
  exit 0
fi

if [[ -z "$BASE_REF" ]]; then
  BASE_REF="$(default_base_ref)"
fi
[[ -n "$BASE_REF" ]] || die "Could not determine a base ref"
git -C "$PROJECT_DIR" rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null ||
  die "Base ref not found: $BASE_REF"

mkdir -p "$ROOT_DIR"
ROOT_DIR="$(cd "$ROOT_DIR" && pwd -P)"
WORKTREE_PATH="${ROOT_DIR}/${WORKTREE_NAME}"

if [[ -e "$WORKTREE_PATH" ]]; then
  die "Target path already exists: $WORKTREE_PATH"
fi

if git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
  git -C "$PROJECT_DIR" worktree add "$WORKTREE_PATH" "$BRANCH_NAME"
else
  git -C "$PROJECT_DIR" worktree add "$WORKTREE_PATH" -b "$BRANCH_NAME" "$BASE_REF"
fi

echo "Created worktree:"
echo "  Path: $WORKTREE_PATH"
echo "  Branch: $BRANCH_NAME"
echo "  Base: $BASE_REF"
print_next_steps "$WORKTREE_PATH" "$NORMALIZED_AGENT"

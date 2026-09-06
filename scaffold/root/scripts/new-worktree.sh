#!/usr/bin/env bash
# agent-vault-managed: helper-script; file=new-worktree.sh

# Create one issue-scoped git worktree for one writing agent.
#
# This only creates or reuses the branch + worktree and prints the next command
# to run from that directory. Launch the writing agent from inside the worktree
# so agent sandboxes use that worktree as their active workspace.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="${SCRIPT_DIR%/*}"

usage() {
  cat <<EOF
Usage: $0 --agent NAME --issue NUMBER [--slug TEXT] [--base REF] [--root DIR]

Create or reuse one issue-scoped worktree for one writing agent.
Requires Git 2.36+ and Bash 3.2+. Linked helper copies use the primary checkout.

Options:
  --agent NAME   Agent label, for example: codex, claude, gemini, grok
  --issue N      Issue number
  --slug TEXT    Optional short slug, for example: feature-slice
  --base REF     Optional base ref. Defaults to origin/main when available,
                 otherwise main, otherwise the current branch.
  --root DIR     Optional worktree root. Relative paths are resolved from the
                 primary checkout. Overrides AGENT_VAULT_WORKTREE_ROOT.
                 Default: <primary checkout>/.worktrees
  AGENT_VAULT_WORKTREE_ROOT
                 Optional environment default for the worktree root. Relative
                 paths are resolved from the primary checkout.
  -h, --help     Show this help

Linked worktrees must be siblings, never inside another linked worktree.
Unsafe existing layouts are refused on reuse as well as creation; preserve
their contents and arrange separate cleanup or relocation before retrying.

Automatic stale-record pruning is refused if another registered worktree is
missing or prunable. Inspect those records before any repository-wide prune.

Examples:
  $0 --agent codex --issue 123 --slug feature-slice
  $0 --agent claude --issue 124 --slug review-cleanup
  $0 --agent gemini --issue 125 --slug docs-followup
  $0 --agent grok --issue 126 --slug grok-build-support
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

normalize_token() {
  local raw="$1"
  printf '%s' "$raw" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g'
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

ensure_safe_layout() {
  local target="$1" reuse_index="$2" i registered
  path_contains "$COMMON_DIR" "$target" &&
    die "Refusing to create a worktree inside Git metadata: $target"
  for ((i = 0; i < ${#WORKTREE_PATHS[@]}; i++)); do
    registered="${WORKTREE_PATHS[$i]}"
    if [[ "$i" -eq "$reuse_index" && "$target" == "$registered" && "$i" -ne 0 ]]; then
      continue
    fi
    if [[ "$i" -ne 0 ]] && path_contains "$registered" "$target"; then
      die "Refusing nested worktree layout: $target is inside linked worktree $registered. Choose a sibling root in the primary checkout or an external directory."
    fi
    if path_contains "$target" "$registered"; then
      die "Refusing worktree layout containing registered worktree: $registered. Preserve its contents and arrange separate cleanup or relocation first."
    fi
  done
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
    grok*)
      printf 'grok\n'
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

AGENT=""
ISSUE=""
SLUG=""
BASE_REF=""
ROOT_DIR="${AGENT_VAULT_WORKTREE_ROOT:-}"

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
      [[ -n "$ROOT_DIR" ]] || die "--root must not be empty"
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

initialize_repository
DEFAULT_ROOT="${PROJECT_DIR}/.worktrees"
ROOT_DIR="${ROOT_DIR:-$DEFAULT_ROOT}"
if [[ "$ROOT_DIR" != /* ]]; then
  ROOT_DIR="$PROJECT_DIR/$ROOT_DIR"
fi
canonical_path "$ROOT_DIR"
ROOT_DIR="$CANONICAL_PATH"
BRANCH_NAME="${NORMALIZED_AGENT}/${NAME_SUFFIX}"
WORKTREE_NAME="${NORMALIZED_AGENT}-${NAME_SUFFIX}"
WORKTREE_PATH="${ROOT_DIR%/}/${WORKTREE_NAME}"

find_branch_index "$BRANCH_NAME"
existing_index="$WORKTREE_INDEX"
if [[ "$existing_index" -ge 0 ]]; then
  [[ "$existing_index" -ne 0 ]] ||
    die "Branch $BRANCH_NAME is attached to the primary checkout; switch the primary to another branch or choose a different --agent/--issue/--slug."
  EXISTING_WORKTREE="${WORKTREE_PATHS[$existing_index]}"
  ensure_safe_layout "$EXISTING_WORKTREE" "$existing_index"
fi
if [[ "$existing_index" -ge 0 && -d "$EXISTING_WORKTREE" ]]; then
  echo "Worktree already exists:"
  [[ "$SOURCE_CHECKOUT" == "$PROJECT_DIR" ]] || echo "  Primary: $PROJECT_DIR"
  echo "  Path: $EXISTING_WORKTREE"
  echo "  Branch: $BRANCH_NAME"
  print_next_steps "$EXISTING_WORKTREE" "$NORMALIZED_AGENT"
  exit 0
fi

ensure_safe_layout "$WORKTREE_PATH" "$existing_index"
[[ ! -e "$WORKTREE_PATH" && ! -L "$WORKTREE_PATH" ]] ||
  die "Target path already exists: $WORKTREE_PATH"

if [[ -z "$BASE_REF" ]]; then
  BASE_REF="$(default_base_ref)"
fi
[[ -n "$BASE_REF" ]] || die "Could not determine a base ref"
git -C "$PROJECT_DIR" rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null ||
  die "Base ref not found: $BASE_REF"

if [[ "$existing_index" -ge 0 ]]; then
  [[ "${WORKTREE_LOCKED[$existing_index]}" == false ]] ||
    die "Missing worktree is locked: $EXISTING_WORKTREE. Restore or repair it before retrying."
  ensure_safe_prune "$EXISTING_WORKTREE"
  git -C "$PROJECT_DIR" worktree prune ||
    die "Could not prune stale worktree metadata."
fi
load_worktrees
find_branch_index "$BRANCH_NAME"
[[ "$WORKTREE_INDEX" -lt 0 ]] || die "Branch still has a registered worktree: $BRANCH_NAME"
ensure_safe_layout "$WORKTREE_PATH" -1
mkdir -p "$ROOT_DIR"

if git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
  git -C "$PROJECT_DIR" worktree add "$WORKTREE_PATH" "$BRANCH_NAME"
else
  git -C "$PROJECT_DIR" worktree add "$WORKTREE_PATH" -b "$BRANCH_NAME" "$BASE_REF"
fi

echo "Created worktree:"
[[ "$SOURCE_CHECKOUT" == "$PROJECT_DIR" ]] || echo "  Primary: $PROJECT_DIR"
echo "  Path: $WORKTREE_PATH"
echo "  Branch: $BRANCH_NAME"
echo "  Base: $BASE_REF"
print_next_steps "$WORKTREE_PATH" "$NORMALIZED_AGENT"

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

# Extract the paths a setuptools finder-style (PEP 660) editable record maps.
# The generated module is metadata, not configuration, and this runs inside a
# destructive cleanup path, so it is parsed statically: sourcing it or handing it to
# an interpreter here would execute whatever the file happens to contain.
# `MAPPING` holds package or module paths and `NAMESPACES` holds lists of them, both
# on a single line, annotated on newer setuptools and bare on older releases.
# Values are Python `repr` output, so the source spelling is not the path: a
# backslash arrives doubled, and when a path holds both quote characters `repr`
# single-quotes it and escapes the inner quote. The scanner therefore tracks
# escapes when finding the closing quote and decodes the literal before emitting
# it. Output is NUL-delimited because a decoded path may legally contain a newline.
# Every literal is emitted and the caller filters: a dict key is a package name,
# which cannot resolve to a path inside the target worktree.
finder_record_paths() {
  local finder_module_file="$1"

  [[ -f "$finder_module_file" ]] || return 0

  LC_ALL=C awk '
    BEGIN { SQ = sprintf("%c", 39); DQ = "\"" }

    function hexval(c,   position) {
      position = index("0123456789abcdef", tolower(c))
      return position - 1
    }

    function hexnum(s, count,   i, value, digit) {
      if (length(s) < count) {
        return -1
      }
      value = 0
      for (i = 1; i <= count; i++) {
        digit = hexval(substr(s, i, 1))
        if (digit < 0) {
          return -1
        }
        value = value * 16 + digit
      }
      return value
    }

    # A repr escape names a codepoint; the filename holds its UTF-8 encoding. Emit
    # the bytes explicitly so the result does not depend on the locale awk runs in.
    # Lone surrogates in DC80..DCFF are Python surrogateescape placeholders for
    # bytes that would not decode, so they map back to that single byte.
    function utf8(code) {
      if (code >= 56448 && code <= 56575) {
        return sprintf("%c", code - 56320)
      }
      if (code < 128) {
        return sprintf("%c", code)
      }
      if (code < 2048) {
        return sprintf("%c%c", 192 + int(code / 64), 128 + (code % 64))
      }
      if (code < 65536) {
        return sprintf("%c%c%c", 224 + int(code / 4096), \
          128 + int((code % 4096) / 64), 128 + (code % 64))
      }
      return sprintf("%c%c%c%c", 240 + int(code / 262144), \
        128 + int((code % 262144) / 4096), 128 + int((code % 4096) / 64), \
        128 + (code % 64))
    }

    function decode(raw,   out, i, n, c, width, code) {
      out = ""
      i = 1
      n = length(raw)
      while (i <= n) {
        c = substr(raw, i, 1)
        if (c != "\\" || i == n) {
          out = out c
          i++
          continue
        }
        i++
        c = substr(raw, i, 1)
        if (c == "n") {
          out = out "\n"
        } else if (c == "t") {
          out = out "\t"
        } else if (c == "r") {
          out = out "\r"
        } else if (c == "\\" || c == SQ || c == DQ) {
          out = out c
        } else if (c == "x" || c == "u" || c == "U") {
          width = (c == "x") ? 2 : ((c == "u") ? 4 : 8)
          code = hexnum(substr(raw, i + 1, width), width)
          if (code > 0) {
            out = out utf8(code)
            i += width
          } else {
            out = out "\\" c
          }
        } else {
          # Python keeps the backslash for an unrecognized escape.
          out = out "\\" c
        }
        i++
      }
      return out
    }

    /^[[:space:]]*(MAPPING|NAMESPACES)[[:space:]]*(:[^=]*)?=/ {
      rest = substr($0, index($0, "=") + 1)
      i = 1
      n = length(rest)
      while (i <= n) {
        c = substr(rest, i, 1)
        if (c != SQ && c != DQ) {
          i++
          continue
        }
        quote = c
        i++
        raw = ""
        while (i <= n) {
          c = substr(rest, i, 1)
          if (c == "\\" && i < n) {
            raw = raw substr(rest, i, 2)
            i += 2
            continue
          }
          if (c == quote) {
            i++
            break
          }
          raw = raw c
          i++
        }
        value = decode(raw)
        if (value != "") {
          printf "%s%c", value, 0
        }
      }
    }
  ' "$finder_module_file" 2>/dev/null
}

# Record the binding and succeed when one candidate resolves inside the target.
# Relative candidates resolve against the .pth directory, matching Python.
#
# An existing directory is canonicalized whole, preserving symlink resolution for
# literal .pth entries. Otherwise the containing directory is canonicalized and the
# leaf appended, because a finder maps a top-level py-module to an extensionless
# stem: `py-modules = ["mymodule"]` yields `.../mymodule` while the file is
# `mymodule.py`, and the finder resolves that stem through Python's module
# suffixes, which are interpreter- and platform-specific. Requiring the leaf to
# exist would miss that binding. Anchoring on the directory also keeps
# canonical_path away from regular files, which it refuses by design.
editable_candidate_binds_target() {
  local candidate="$1"
  local pth_dir="$2"
  local target_path="$3"
  local candidate_dir=""
  local candidate_base=""

  [[ -n "$candidate" ]] || return 1
  [[ "$candidate" == /* ]] || candidate="$pth_dir/$candidate"

  if [[ -d "$candidate" ]]; then
    canonical_path "$candidate"
    candidate="$CANONICAL_PATH"
  else
    # Split with parameter expansion, as canonical_path does. `$(dirname ...)`
    # strips trailing newlines from its output, so a component ending in one would
    # resolve against the wrong parent and the binding would be skipped.
    candidate_base="${candidate##*/}"
    candidate_dir="${candidate%/*}"
    [[ -n "$candidate_dir" ]] || candidate_dir="/"
    [[ -n "$candidate_base" ]] || return 1
    [[ -d "$candidate_dir" ]] || return 1
    canonical_path "$candidate_dir"
    candidate="${CANONICAL_PATH%/}/$candidate_base"
  fi

  if [[ "$candidate" == "$target_path" || "$candidate" == "$target_path/"* ]]; then
    BOUND_EDITABLE_PATH="$candidate"
    return 0
  fi

  return 1
}

find_shared_editable_binding() {
  local target_path="$1"
  local venv_dir="$PROJECT_DIR/.venv"
  local pth_file=""
  local pth_dir=""
  local line=""
  local resolved=""
  local finder_module=""
  local candidate=""

  BOUND_EDITABLE_PATH=""
  [[ -d "$venv_dir" ]] || return 0

  # Python's site.addsitedir() selects `name.endswith(".pth") and not
  # name.startswith(".")`, so a disabled record such as .disabled.pth is not an
  # active binding and must not block cleanup. This matters more now that relative
  # entries resolve: a relative entry in a hidden file used to be skipped by
  # accident, while an absolute one was already treated as active.
  while IFS= read -r -d '' pth_file; do
    # Python resolves a relative .pth entry against the directory holding the
    # .pth file, not the caller's working directory. Resolve first, then test:
    # checking the raw entry against $PWD skips a live binding whenever this
    # helper runs from anywhere other than that site-packages directory.
    pth_dir="${pth_file%/*}"
    [[ -n "$pth_dir" ]] || pth_dir="/"
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      [[ "$line" != \#* ]] || continue

      # site.addpackage() executes a .pth line only when it starts with "import "
      # or "import<tab>". A finder-style editable record is exactly that and
      # carries no path at all, so the literal handling below cannot see it. Other
      # import lines ship in ordinary venvs (distutils-precedence.pth) and must be
      # ignored rather than treated as bindings or reported as errors.
      if [[ "$line" == "import "* || "$line" == "import	"* ]]; then
        finder_module=""
        read -r _ finder_module _ <<<"$line"
        finder_module="${finder_module%%[!A-Za-z0-9_]*}"
        case "$finder_module" in
          __editable__?*) ;;
          *) continue ;;
        esac

        while IFS= read -r -d '' candidate; do
          if editable_candidate_binds_target "$candidate" "$pth_dir" "$target_path"; then
            return 0
          fi
        done < <(finder_record_paths "$pth_dir/$finder_module.py")

        continue
      fi

      # Literal entries: Python only adds directories to sys.path. This also
      # covers `editable_mode=compat`, which writes a literal project path rather
      # than a finder module, verified on setuptools 84.0.0 for both a plain flat
      # layout and a package-dir remap. A `_LinkTree` variant would instead point
      # at a symlink tree inside site-packages, which no longer names the worktree
      # and is deliberately out of scope here.
      resolved="$line"
      [[ "$resolved" == /* ]] || resolved="$pth_dir/$resolved"
      [[ -d "$resolved" ]] || continue
      if editable_candidate_binds_target "$resolved" "$pth_dir" "$target_path"; then
        return 0
      fi
    done <"$pth_file"
  done < <(find "$venv_dir" -type f -path '*/site-packages/*.pth' ! -name '.*' -print0 2>/dev/null)

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

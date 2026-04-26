#!/usr/bin/env bash

set -euo pipefail

SHELLCHECK_BIN="${SHELLCHECK_BIN:-shellcheck}"
SHFMT_BIN="${SHFMT_BIN:-shfmt}"
SHELLCHECK_SEVERITY="warning"
SHFMT_FLAGS=(-i 2 -ci)

usage() {
  cat <<EOF
Usage: $0 [--fix|--write]

Run shell syntax, static-analysis, and formatting checks.

Options:
  --fix, --write  Rewrite shell formatting with shfmt instead of printing a diff.
  -h, --help      Show this help.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
fix_mode="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix | --write)
      fix_mode="true"
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

cd "$repo_root"

missing_tools=()
for tool in "$SHELLCHECK_BIN" "$SHFMT_BIN"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing_tools+=("$tool")
  fi
done

if [[ "${#missing_tools[@]}" -gt 0 ]]; then
  echo "Missing required style-check tool(s): ${missing_tools[*]}" >&2
  cat >&2 <<'EOF'

Install them locally before running this command:
  macOS:   brew install shellcheck shfmt
  Ubuntu: install ShellCheck and shfmt from their pinned release binaries.

CI pins the exact tool versions in .github/workflows/style-check.yml.
EOF
  exit 127
fi

targets=()

add_target() {
  local file_path="$1"
  local existing

  if [[ "${#targets[@]}" -gt 0 ]]; then
    for existing in "${targets[@]}"; do
      if [[ "$existing" == "$file_path" ]]; then
        return 0
      fi
    done
  fi

  targets+=("$file_path")
}

is_direct_child_sh_file() {
  local file_path="$1"
  local directory="$2"
  local relative_path=""

  case "$file_path" in
    "$directory"/*.sh)
      relative_path="${file_path#${directory}/}"
      [[ "$relative_path" != */* ]]
      return
      ;;
    *)
      return 1
      ;;
  esac
}

has_shell_shebang() {
  local file_path="$1"
  local first_line=""

  IFS= read -r first_line <"$repo_root/$file_path" || return 1
  [[ "$first_line" == '#!'*bash* || "$first_line" == '#!'*'/sh'* || "$first_line" == '#!'*' sh'* ]]
}

# Keep target roots explicit. If future test fixtures need intentionally broken
# shell, add a narrow opt-out instead of broadening discovery.
while IFS= read -r file_path; do
  [[ -n "$file_path" ]] || continue

  if is_direct_child_sh_file "$file_path" "scripts" ||
    is_direct_child_sh_file "$file_path" "scripts/lib" ||
    is_direct_child_sh_file "$file_path" "scaffold/root/scripts" ||
    is_direct_child_sh_file "$file_path" "scaffold/agent-vault/_assets/hooks/lib"; then
    add_target "$file_path"
    continue
  fi

  case "$file_path" in
    scaffold/agent-vault/_assets/hooks/*)
      if [[ -f "$repo_root/$file_path" ]] && has_shell_shebang "$file_path"; then
        add_target "$file_path"
      fi
      ;;
  esac
done < <(git ls-files)

if [[ -f "scripts/check-style.sh" ]]; then
  add_target "scripts/check-style.sh"
fi

if [[ "${#targets[@]}" -eq 0 ]]; then
  echo "No shell style-check targets found."
  exit 0
fi

echo "Checking ${#targets[@]} shell file(s)."
echo "Running bash syntax checks..."
for file_path in "${targets[@]}"; do
  bash -n "$file_path"
done

echo "Running ShellCheck with --severity=$SHELLCHECK_SEVERITY..."
"$SHELLCHECK_BIN" --severity="$SHELLCHECK_SEVERITY" -x "${targets[@]}"

if [[ "$fix_mode" == "true" ]]; then
  echo "Formatting shell files with shfmt ${SHFMT_FLAGS[*]} -w..."
  "$SHFMT_BIN" "${SHFMT_FLAGS[@]}" -w "${targets[@]}"
else
  echo "Checking shell formatting with shfmt ${SHFMT_FLAGS[*]} -d..."
  "$SHFMT_BIN" "${SHFMT_FLAGS[@]}" -d "${targets[@]}"
fi

echo "Shell style checks passed."

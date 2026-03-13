#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-session-hook-test.XXXXXX")"
today="$(date '+%Y-%m-%d')"

cleanup() {
  rm -rf "$tmp_root"
}

trap cleanup EXIT

assert_output_contains() {
  local output="$1"
  local expected_text="$2"

  if [[ "$output" != *"$expected_text"* ]]; then
    echo "Expected text not found in command output: $expected_text" >&2
    echo "Actual output:" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

assert_file_exists() {
  local file_path="$1"

  if [[ ! -f "$file_path" ]]; then
    echo "Expected file not found: $file_path" >&2
    exit 1
  fi
}

assert_executable() {
  local file_path="$1"

  if [[ ! -x "$file_path" ]]; then
    echo "Expected executable file: $file_path" >&2
    exit 1
  fi
}

init_repo() {
  local repo_path="$1"

  mkdir -p "$repo_path"
  git -C "$repo_path" init >/dev/null
  git -C "$repo_path" config user.name "Agent Vault Test"
  git -C "$repo_path" config user.email "agent-vault-tests@example.com"
}

run_hook_expect_failure() {
  local repo_path="$1"
  local output=""

  if output="$(cd "$repo_path" && agent-vault/_assets/hooks/pre-commit 2>&1)"; then
    echo "Expected hook to fail in $repo_path" >&2
    exit 1
  fi

  printf '%s\n' "$output"
}

run_hook_expect_success() {
  local repo_path="$1"

  (cd "$repo_path" && agent-vault/_assets/hooks/pre-commit)
}

hook_repo="$tmp_root/hook-enforcement"
init_repo "$hook_repo"
"$repo_root/scripts/new-project.sh" "hook-test" "$hook_repo" >/dev/null
assert_file_exists "$hook_repo/agent-vault/_assets/hooks/pre-commit"
assert_file_exists "$hook_repo/agent-vault/_assets/hooks/README.md"
assert_executable "$hook_repo/agent-vault/_assets/hooks/pre-commit"
if [[ "$(git -C "$hook_repo" config --local --get core.hooksPath)" != "agent-vault/_assets/hooks" ]]; then
  echo "Expected new-project.sh to enable the tracked hooks path." >&2
  exit 1
fi

mkdir -p "$hook_repo/src"
printf 'print(\"hello\")\n' > "$hook_repo/src/app.py"
git -C "$hook_repo" add src/app.py

failure_output="$(run_hook_expect_failure "$hook_repo")"
assert_output_contains "$failure_output" "agent-vault metadata gate failed."
assert_output_contains "$failure_output" "stage agent-vault/context-log.md"
assert_output_contains "$failure_output" "stage one note under agent-vault/daily/"
assert_output_contains "$failure_output" "stage one note under agent-vault/design-log/"
(cd "$hook_repo" && AGENT_VAULT_SKIP_METADATA_GATE=1 agent-vault/_assets/hooks/pre-commit)

printf '\nHook coverage update.\n' >> "$hook_repo/agent-vault/context-log.md"
cat <<EOF > "$hook_repo/agent-vault/daily/$today.md"
# Daily Note

- Verified hook coverage.
EOF
cat <<EOF > "$hook_repo/agent-vault/design-log/$today-0100-hook-coverage.md"
# Design Log

- Verified metadata gate behavior.
EOF

git -C "$hook_repo" add \
  agent-vault/context-log.md \
  "agent-vault/daily/$today.md" \
  "agent-vault/design-log/$today-0100-hook-coverage.md"
run_hook_expect_success "$hook_repo"

metadata_only_repo="$tmp_root/metadata-only"
init_repo "$metadata_only_repo"
"$repo_root/scripts/new-project.sh" "hook-test" "$metadata_only_repo" >/dev/null
printf '\nMetadata-only change.\n' >> "$metadata_only_repo/agent-vault/context-log.md"
git -C "$metadata_only_repo" add agent-vault/context-log.md
run_hook_expect_success "$metadata_only_repo"

update_repo="$tmp_root/update-project-hook-seed"
init_repo "$update_repo"
"$repo_root/scripts/new-project.sh" "hook-test" "$update_repo" >/dev/null
git -C "$update_repo" config --local --unset core.hooksPath
rm -rf "$update_repo/agent-vault/_assets/hooks"
"$repo_root/scripts/update-project.sh" "$update_repo" >/dev/null
assert_file_exists "$update_repo/agent-vault/_assets/hooks/pre-commit"
assert_file_exists "$update_repo/agent-vault/_assets/hooks/README.md"
assert_executable "$update_repo/agent-vault/_assets/hooks/pre-commit"
if [[ "$(git -C "$update_repo" config --local --get core.hooksPath)" != "agent-vault/_assets/hooks" ]]; then
  echo "Expected update-project.sh to enable the tracked hooks path." >&2
  exit 1
fi

custom_hooks_repo="$tmp_root/custom-hooks-path"
init_repo "$custom_hooks_repo"
git -C "$custom_hooks_repo" config --local core.hooksPath .githooks
"$repo_root/scripts/new-project.sh" "hook-test" "$custom_hooks_repo" >/dev/null
if [[ "$(git -C "$custom_hooks_repo" config --local --get core.hooksPath)" != ".githooks" ]]; then
  echo "Expected custom core.hooksPath to remain unchanged." >&2
  exit 1
fi

global_hooks_repo="$tmp_root/global-hooks-path"
global_hooks_config="$tmp_root/global-hooks.gitconfig"
init_repo "$global_hooks_repo"
git config --file "$global_hooks_config" core.hooksPath .global-hooks
GIT_CONFIG_GLOBAL="$global_hooks_config" "$repo_root/scripts/new-project.sh" "hook-test" "$global_hooks_repo" >/dev/null
if git -C "$global_hooks_repo" config --local --get core.hooksPath >/dev/null 2>&1; then
  echo "Expected inherited global core.hooksPath to remain non-local." >&2
  exit 1
fi
if [[ "$(GIT_CONFIG_GLOBAL="$global_hooks_config" git -C "$global_hooks_repo" config --get core.hooksPath)" != ".global-hooks" ]]; then
  echo "Expected inherited global core.hooksPath to remain effective." >&2
  exit 1
fi

deletion_repo="$tmp_root/deleted-metadata-does-not-count"
init_repo "$deletion_repo"
"$repo_root/scripts/new-project.sh" "hook-test" "$deletion_repo" >/dev/null
git -C "$deletion_repo" add .
(cd "$deletion_repo" && AGENT_VAULT_SKIP_METADATA_GATE=1 git commit -m "Bootstrap hook test fixture" >/dev/null)
mkdir -p "$deletion_repo/src"
printf 'print("old")\n' > "$deletion_repo/src/app.py"
printf '\nDeletion fixture context.\n' >> "$deletion_repo/agent-vault/context-log.md"
cat <<EOF > "$deletion_repo/agent-vault/daily/$today.md"
# Daily Note

- Seed metadata for deletion coverage.
EOF
cat <<EOF > "$deletion_repo/agent-vault/design-log/$today-0200-delete-coverage.md"
# Design Log

- Seed metadata for deletion coverage.
EOF
git -C "$deletion_repo" add \
  src/app.py \
  agent-vault/context-log.md \
  "agent-vault/daily/$today.md" \
  "agent-vault/design-log/$today-0200-delete-coverage.md"
(cd "$deletion_repo" && AGENT_VAULT_SKIP_METADATA_GATE=1 git commit -m "Seed deletion coverage metadata" >/dev/null)
printf 'print("new")\n' > "$deletion_repo/src/app.py"
git -C "$deletion_repo" add src/app.py
git -C "$deletion_repo" rm -f \
  agent-vault/context-log.md \
  "agent-vault/daily/$today.md" \
  "agent-vault/design-log/$today-0200-delete-coverage.md" >/dev/null
deletion_failure_output="$(run_hook_expect_failure "$deletion_repo")"
assert_output_contains "$deletion_failure_output" "stage agent-vault/context-log.md"
assert_output_contains "$deletion_failure_output" "stage one note under agent-vault/daily/"
assert_output_contains "$deletion_failure_output" "stage one note under agent-vault/design-log/"

echo "session metadata hook regression checks passed."

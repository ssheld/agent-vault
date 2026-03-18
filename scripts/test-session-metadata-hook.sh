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

replace_first_match() {
  local file_path="$1"
  local search_text="$2"
  local replacement_text="$3"

  perl -0pi -e 's/\Q'"$search_text"'\E/'"$replacement_text"'/' "$file_path"
}

replace_first_context_log_timestamp() {
  local file_path="$1"
  local replacement_timestamp="$2"

  perl -0pi -e 's/^### [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} local - /### '"$replacement_timestamp"' local - /m' "$file_path"
}

replace_first_context_log_heading() {
  local file_path="$1"
  local replacement_heading="$2"

  perl -0pi -e 's/^### [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} local - .*$/### '"$replacement_heading"'/m' "$file_path"
}

clear_context_log_entries() {
  local file_path="$1"

  perl -0pi -e 's/^## Entries\s*\n.*\z/## Entries\n/mgs' "$file_path"
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

metadata_only_invalid_repo="$tmp_root/metadata-only-invalid"
init_repo "$metadata_only_invalid_repo"
"$repo_root/scripts/new-project.sh" "hook-test" "$metadata_only_invalid_repo" >/dev/null
replace_first_match "$metadata_only_invalid_repo/agent-vault/context-log.md" "last_updated: $today" "last_updated: 2000-01-01"
replace_first_match "$metadata_only_invalid_repo/agent-vault/context-log.md" "- Last updated: $today" "- Last updated: 2000-01-01"
git -C "$metadata_only_invalid_repo" add agent-vault/context-log.md
metadata_only_invalid_output="$(run_hook_expect_failure "$metadata_only_invalid_repo")"
assert_output_contains "$metadata_only_invalid_output" "Context log validation failed:"
assert_output_contains "$metadata_only_invalid_output" 'frontmatter `last_updated` must match the top entry date'
assert_output_contains "$metadata_only_invalid_output" 'Current Snapshot `Last updated` must match the top entry date'

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

ordering_repo="$tmp_root/context-log-ordering"
init_repo "$ordering_repo"
"$repo_root/scripts/new-project.sh" "hook-test" "$ordering_repo" >/dev/null
replace_first_context_log_timestamp "$ordering_repo/agent-vault/context-log.md" "$today 09:00"
cat <<EOF >> "$ordering_repo/agent-vault/context-log.md"

### $today 10:00 local - test-agent - appended newer entry below older one
#### Goal
Exercise ordering validation.

#### State
- Added a newer entry in the wrong position.

#### Decisions
- None.

#### Open Questions
- None.

#### Next Prompt
"Fix context log ordering."

#### References
- agent-vault/context-log.md
EOF
cat <<EOF > "$ordering_repo/agent-vault/daily/$today.md"
# Daily Note

- Seed ordering validation fixture.
EOF
cat <<EOF > "$ordering_repo/agent-vault/design-log/$today-0300-context-log-ordering.md"
# Design Log

- Seed ordering validation fixture.
EOF
mkdir -p "$ordering_repo/src"
printf 'print("ordering")\n' > "$ordering_repo/src/app.py"
git -C "$ordering_repo" add \
  src/app.py \
  agent-vault/context-log.md \
  "agent-vault/daily/$today.md" \
  "agent-vault/design-log/$today-0300-context-log-ordering.md"
ordering_failure_output="$(run_hook_expect_failure "$ordering_repo")"
assert_output_contains "$ordering_failure_output" "Context log validation failed:"
assert_output_contains "$ordering_failure_output" 'must keep entries newest-first'

freshness_repo="$tmp_root/context-log-freshness"
init_repo "$freshness_repo"
"$repo_root/scripts/new-project.sh" "hook-test" "$freshness_repo" >/dev/null
replace_first_match "$freshness_repo/agent-vault/context-log.md" "last_updated: $today" "last_updated: 2000-01-01"
replace_first_match "$freshness_repo/agent-vault/context-log.md" "- Last updated: $today" "- Last updated: 2000-01-01"
cat <<EOF > "$freshness_repo/agent-vault/daily/$today.md"
# Daily Note

- Seed freshness validation fixture.
EOF
cat <<EOF > "$freshness_repo/agent-vault/design-log/$today-0400-context-log-freshness.md"
# Design Log

- Seed freshness validation fixture.
EOF
mkdir -p "$freshness_repo/src"
printf 'print("freshness")\n' > "$freshness_repo/src/app.py"
git -C "$freshness_repo" add \
  src/app.py \
  agent-vault/context-log.md \
  "agent-vault/daily/$today.md" \
  "agent-vault/design-log/$today-0400-context-log-freshness.md"
freshness_failure_output="$(run_hook_expect_failure "$freshness_repo")"
assert_output_contains "$freshness_failure_output" 'frontmatter `last_updated` must match the top entry date'
assert_output_contains "$freshness_failure_output" 'Current Snapshot `Last updated` must match the top entry date'

invalid_heading_repo="$tmp_root/context-log-invalid-heading"
init_repo "$invalid_heading_repo"
"$repo_root/scripts/new-project.sh" "hook-test" "$invalid_heading_repo" >/dev/null
replace_first_context_log_heading "$invalid_heading_repo/agent-vault/context-log.md" "bad heading format"
git -C "$invalid_heading_repo" add agent-vault/context-log.md
invalid_heading_output="$(run_hook_expect_failure "$invalid_heading_repo")"
assert_output_contains "$invalid_heading_output" 'entry headings must start with `YYYY-MM-DD HH:MM local - <agent> - <topic>`'

empty_entries_repo="$tmp_root/context-log-empty-entries"
init_repo "$empty_entries_repo"
"$repo_root/scripts/new-project.sh" "hook-test" "$empty_entries_repo" >/dev/null
clear_context_log_entries "$empty_entries_repo/agent-vault/context-log.md"
git -C "$empty_entries_repo" add agent-vault/context-log.md
empty_entries_output="$(run_hook_expect_failure "$empty_entries_repo")"
assert_output_contains "$empty_entries_output" 'must include at least one entry under `## Entries`'

# shellcheck source=./lib/tracked-hooks.sh
source "$script_dir/lib/tracked-hooks.sh"

custom_rc_repo="$tmp_root/custom-hooks-returns-nonzero"
init_repo "$custom_rc_repo"
git -C "$custom_rc_repo" config --local core.hooksPath .githooks
custom_rc=0
configure_tracked_hooks_path "$custom_rc_repo" || custom_rc=$?
if [[ "$custom_rc" -eq 0 ]]; then
  echo "Expected configure_tracked_hooks_path to return non-zero when custom core.hooksPath is set." >&2
  exit 1
fi

success_rc_repo="$tmp_root/activation-returns-zero"
init_repo "$success_rc_repo"
success_rc=0
configure_tracked_hooks_path "$success_rc_repo" || success_rc=$?
if [[ "$success_rc" -ne 0 ]]; then
  echo "Expected configure_tracked_hooks_path to return zero on successful activation." >&2
  exit 1
fi
if [[ "$(git -C "$success_rc_repo" config --local --get core.hooksPath)" != "agent-vault/_assets/hooks" ]]; then
  echo "Expected core.hooksPath to be set after successful activation." >&2
  exit 1
fi

dryrun_rc_repo="$tmp_root/dryrun-returns-zero"
init_repo "$dryrun_rc_repo"
dryrun_rc=0
dryrun_output="$(configure_tracked_hooks_path "$dryrun_rc_repo" "true")" || dryrun_rc=$?
if [[ "$dryrun_rc" -ne 0 ]]; then
  echo "Expected configure_tracked_hooks_path to return zero on dry-run activation." >&2
  exit 1
fi
if git -C "$dryrun_rc_repo" config --local --get core.hooksPath >/dev/null 2>&1; then
  echo "Expected core.hooksPath to remain unset after dry-run activation." >&2
  exit 1
fi

echo "session metadata hook regression checks passed."

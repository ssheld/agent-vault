#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-main-push-gate-test.XXXXXX")"
today="$(date '+%Y-%m-%d')"
zero_sha="0000000000000000000000000000000000000000"

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
  git -C "$repo_path" checkout -b main >/dev/null 2>&1
  git -C "$repo_path" config user.name "Agent Vault Test"
  git -C "$repo_path" config user.email "agent-vault-tests@example.com"
}

seed_project() {
  local repo_path="$1"

  init_repo "$repo_path"
  "$repo_root/scripts/new-project.sh" "push-gate-test" "$repo_path" >/dev/null
  assert_file_exists "$repo_path/agent-vault/_assets/hooks/lib/runtime-note.sh"
  assert_file_exists "$repo_path/agent-vault/_assets/hooks/pre-push"
  assert_executable "$repo_path/agent-vault/_assets/hooks/pre-push"
  git -C "$repo_path" add .
  (cd "$repo_path" && AGENT_VAULT_SKIP_METADATA_GATE=1 git commit -m "Bootstrap push gate test fixture" >/dev/null)
}

enable_gate() {
  local repo_path="$1"

  git -C "$repo_path" config --local agent-vault.allowMetadataOnlyMainPush true
}

commit_metadata_change() {
  local repo_path="$1"

  printf '\nPost-merge metadata refresh.\n' >>"$repo_path/agent-vault/context-log.md"
  git -C "$repo_path" add agent-vault/context-log.md
  (cd "$repo_path" && AGENT_VAULT_SKIP_METADATA_GATE=1 git commit -m "Update agent-vault metadata" >/dev/null)
}

commit_source_change() {
  local repo_path="$1"

  mkdir -p "$repo_path/src"
  printf 'print("source change")\n' >"$repo_path/src/app.py"
  git -C "$repo_path" add src/app.py
  (cd "$repo_path" && AGENT_VAULT_SKIP_METADATA_GATE=1 git commit -m "Change source" >/dev/null)
}

commit_mixed_change() {
  local repo_path="$1"

  mkdir -p "$repo_path/src"
  printf 'print("mixed change")\n' >"$repo_path/src/app.py"
  printf '\nMixed metadata refresh.\n' >>"$repo_path/agent-vault/context-log.md"
  git -C "$repo_path" add src/app.py agent-vault/context-log.md
  (cd "$repo_path" && AGENT_VAULT_SKIP_METADATA_GATE=1 git commit -m "Change source and metadata" >/dev/null)
}

run_pre_push() {
  local repo_path="$1"
  local local_ref="$2"
  local local_sha="$3"
  local remote_ref="$4"
  local remote_sha="$5"

  (cd "$repo_path" && printf '%s %s %s %s\n' "$local_ref" "$local_sha" "$remote_ref" "$remote_sha" | agent-vault/_assets/hooks/pre-push)
}

run_pre_push_expect_failure() {
  local repo_path="$1"
  local local_ref="$2"
  local local_sha="$3"
  local remote_ref="$4"
  local remote_sha="$5"
  local output=""

  if output="$(run_pre_push "$repo_path" "$local_ref" "$local_sha" "$remote_ref" "$remote_sha" 2>&1)"; then
    echo "Expected pre-push hook to fail in $repo_path" >&2
    exit 1
  fi

  printf '%s\n' "$output"
}

opt_out_repo="$tmp_root/opt-out-source-allowed"
seed_project "$opt_out_repo"
opt_out_remote_sha="$(git -C "$opt_out_repo" rev-parse HEAD)"
commit_source_change "$opt_out_repo"
opt_out_local_sha="$(git -C "$opt_out_repo" rev-parse HEAD)"
run_pre_push "$opt_out_repo" "refs/heads/main" "$opt_out_local_sha" "refs/heads/main" "$opt_out_remote_sha"

no_vault_repo="$tmp_root/no-agent-vault-noop"
init_repo "$no_vault_repo"
printf 'plain repo\n' >"$no_vault_repo/README.md"
git -C "$no_vault_repo" add README.md
git -C "$no_vault_repo" commit -m "Bootstrap plain repo" >/dev/null
git -C "$no_vault_repo" config --local agent-vault.allowMetadataOnlyMainPush true
no_vault_remote_sha="$(git -C "$no_vault_repo" rev-parse HEAD)"
printf 'plain repo update\n' >"$no_vault_repo/README.md"
git -C "$no_vault_repo" commit -am "Change plain repo" >/dev/null
no_vault_local_sha="$(git -C "$no_vault_repo" rev-parse HEAD)"
(cd "$no_vault_repo" && printf '%s %s %s %s\n' \
  "refs/heads/main" "$no_vault_local_sha" "refs/heads/main" "$no_vault_remote_sha" \
  | "$repo_root/scaffold/agent-vault/_assets/hooks/pre-push")

global_config_repo="$tmp_root/global-config-ignored"
global_config_file="$tmp_root/global-config.gitconfig"
seed_project "$global_config_repo"
git config --file "$global_config_file" agent-vault.allowMetadataOnlyMainPush true
global_config_remote_sha="$(git -C "$global_config_repo" rev-parse HEAD)"
commit_source_change "$global_config_repo"
global_config_local_sha="$(git -C "$global_config_repo" rev-parse HEAD)"
(cd "$global_config_repo" && printf '%s %s %s %s\n' \
  "refs/heads/main" "$global_config_local_sha" "refs/heads/main" "$global_config_remote_sha" \
  | GIT_CONFIG_GLOBAL="$global_config_file" agent-vault/_assets/hooks/pre-push)

metadata_repo="$tmp_root/metadata-only-allowed"
seed_project "$metadata_repo"
enable_gate "$metadata_repo"
metadata_remote_sha="$(git -C "$metadata_repo" rev-parse HEAD)"
commit_metadata_change "$metadata_repo"
metadata_local_sha="$(git -C "$metadata_repo" rev-parse HEAD)"
run_pre_push "$metadata_repo" "refs/heads/main" "$metadata_local_sha" "refs/heads/main" "$metadata_remote_sha"

empty_commit_repo="$tmp_root/empty-commit-allowed"
seed_project "$empty_commit_repo"
enable_gate "$empty_commit_repo"
empty_commit_remote_sha="$(git -C "$empty_commit_repo" rev-parse HEAD)"
git -C "$empty_commit_repo" commit --allow-empty -m "Empty metadata checkpoint" >/dev/null
empty_commit_local_sha="$(git -C "$empty_commit_repo" rev-parse HEAD)"
run_pre_push "$empty_commit_repo" "refs/heads/main" "$empty_commit_local_sha" "refs/heads/main" "$empty_commit_remote_sha"

source_repo="$tmp_root/source-blocked"
seed_project "$source_repo"
enable_gate "$source_repo"
source_remote_sha="$(git -C "$source_repo" rev-parse HEAD)"
commit_source_change "$source_repo"
source_local_sha="$(git -C "$source_repo" rev-parse HEAD)"
source_output="$(run_pre_push_expect_failure "$source_repo" "refs/heads/main" "$source_local_sha" "refs/heads/main" "$source_remote_sha")"
assert_output_contains "$source_output" "Direct push to main is allowed only for runtime agent-vault metadata."
assert_output_contains "$source_output" "- src/app.py"

mixed_repo="$tmp_root/mixed-blocked"
seed_project "$mixed_repo"
enable_gate "$mixed_repo"
mixed_remote_sha="$(git -C "$mixed_repo" rev-parse HEAD)"
commit_mixed_change "$mixed_repo"
mixed_local_sha="$(git -C "$mixed_repo" rev-parse HEAD)"
mixed_output="$(run_pre_push_expect_failure "$mixed_repo" "refs/heads/main" "$mixed_local_sha" "refs/heads/main" "$mixed_remote_sha")"
assert_output_contains "$mixed_output" "- src/app.py"

range_repo="$tmp_root/intermediate-blocked-file-blocked"
seed_project "$range_repo"
enable_gate "$range_repo"
range_remote_sha="$(git -C "$range_repo" rev-parse HEAD)"
printf '\nTemporary policy change.\n' >>"$range_repo/agent-vault/AGENTS.md"
git -C "$range_repo" add agent-vault/AGENTS.md
(cd "$range_repo" && AGENT_VAULT_SKIP_METADATA_GATE=1 git commit -m "Temporarily change policy" >/dev/null)
git -C "$range_repo" checkout "$range_remote_sha" -- agent-vault/AGENTS.md
git -C "$range_repo" add agent-vault/AGENTS.md
(cd "$range_repo" && AGENT_VAULT_SKIP_METADATA_GATE=1 git commit -m "Revert temporary policy change" >/dev/null)
range_local_sha="$(git -C "$range_repo" rev-parse HEAD)"
range_output="$(run_pre_push_expect_failure "$range_repo" "refs/heads/main" "$range_local_sha" "refs/heads/main" "$range_remote_sha")"
assert_output_contains "$range_output" "- agent-vault/AGENTS.md"

feature_repo="$tmp_root/non-main-unaffected"
seed_project "$feature_repo"
enable_gate "$feature_repo"
feature_remote_sha="$(git -C "$feature_repo" rev-parse HEAD)"
commit_source_change "$feature_repo"
feature_local_sha="$(git -C "$feature_repo" rev-parse HEAD)"
run_pre_push "$feature_repo" "refs/heads/feature" "$feature_local_sha" "refs/heads/feature" "$feature_remote_sha"

for blocked_path in \
  agent-vault/AGENTS.md \
  agent-vault/shared-rules.md \
  agent-vault/review-policy.md \
  "agent-vault/Templates/Plan.md" \
  agent-vault/_assets/hooks/pre-commit
do
  blocked_repo="$tmp_root/blocked-${blocked_path//\//-}"
  seed_project "$blocked_repo"
  enable_gate "$blocked_repo"
  blocked_remote_sha="$(git -C "$blocked_repo" rev-parse HEAD)"
  printf '\nBlocked direct-main change.\n' >>"$blocked_repo/$blocked_path"
  git -C "$blocked_repo" add "$blocked_path"
  (cd "$blocked_repo" && AGENT_VAULT_SKIP_METADATA_GATE=1 git commit -m "Change blocked agent-vault file" >/dev/null)
  blocked_local_sha="$(git -C "$blocked_repo" rev-parse HEAD)"
  blocked_output="$(run_pre_push_expect_failure "$blocked_repo" "refs/heads/main" "$blocked_local_sha" "refs/heads/main" "$blocked_remote_sha")"
  assert_output_contains "$blocked_output" "- $blocked_path"
done

delete_repo="$tmp_root/delete-main-blocked"
seed_project "$delete_repo"
enable_gate "$delete_repo"
delete_remote_sha="$(git -C "$delete_repo" rev-parse HEAD)"
delete_output="$(run_pre_push_expect_failure "$delete_repo" "refs/heads/main" "$zero_sha" "refs/heads/main" "$delete_remote_sha")"
assert_output_contains "$delete_output" "Direct deletion of main is not allowed."

create_repo="$tmp_root/create-main-blocked"
seed_project "$create_repo"
enable_gate "$create_repo"
create_local_sha="$(git -C "$create_repo" rev-parse HEAD)"
create_output="$(run_pre_push_expect_failure "$create_repo" "refs/heads/main" "$create_local_sha" "refs/heads/main" "$zero_sha")"
assert_output_contains "$create_output" "Direct creation of main is not allowed."

non_ff_repo="$tmp_root/non-fast-forward-blocked"
seed_project "$non_ff_repo"
enable_gate "$non_ff_repo"
non_ff_base_sha="$(git -C "$non_ff_repo" rev-parse HEAD)"
commit_metadata_change "$non_ff_repo"
non_ff_local_sha="$(git -C "$non_ff_repo" rev-parse HEAD)"
git -C "$non_ff_repo" checkout -b remote-side "$non_ff_base_sha" >/dev/null 2>&1
mkdir -p "$non_ff_repo/remote"
printf 'remote side\n' >"$non_ff_repo/remote/file.txt"
git -C "$non_ff_repo" add remote/file.txt
(cd "$non_ff_repo" && AGENT_VAULT_SKIP_METADATA_GATE=1 git commit -m "Remote side divergence" >/dev/null)
non_ff_remote_sha="$(git -C "$non_ff_repo" rev-parse HEAD)"
non_ff_output="$(run_pre_push_expect_failure "$non_ff_repo" "refs/heads/main" "$non_ff_local_sha" "refs/heads/main" "$non_ff_remote_sha")"
assert_output_contains "$non_ff_output" "Direct non-fast-forward push to main is not allowed."

rename_repo="$tmp_root/rename-source-blocked"
seed_project "$rename_repo"
enable_gate "$rename_repo"
rename_remote_sha="$(git -C "$rename_repo" rev-parse HEAD)"
git -C "$rename_repo" mv agent-vault/AGENTS.md "agent-vault/daily/$today-renamed.md"
(cd "$rename_repo" && AGENT_VAULT_SKIP_METADATA_GATE=1 git commit -m "Rename policy into runtime note path" >/dev/null)
rename_local_sha="$(git -C "$rename_repo" rev-parse HEAD)"
rename_output="$(run_pre_push_expect_failure "$rename_repo" "refs/heads/main" "$rename_local_sha" "refs/heads/main" "$rename_remote_sha")"
assert_output_contains "$rename_output" "- agent-vault/AGENTS.md"

invalid_config_repo="$tmp_root/invalid-config"
seed_project "$invalid_config_repo"
git -C "$invalid_config_repo" config --local agent-vault.allowMetadataOnlyMainPush maybe
invalid_config_remote_sha="$(git -C "$invalid_config_repo" rev-parse HEAD)"
commit_metadata_change "$invalid_config_repo"
invalid_config_local_sha="$(git -C "$invalid_config_repo" rev-parse HEAD)"
invalid_config_output="$(run_pre_push_expect_failure "$invalid_config_repo" "refs/heads/main" "$invalid_config_local_sha" "refs/heads/main" "$invalid_config_remote_sha")"
assert_output_contains "$invalid_config_output" "Invalid local git config value for agent-vault.allowMetadataOnlyMainPush"

echo "main push metadata gate regression checks passed."

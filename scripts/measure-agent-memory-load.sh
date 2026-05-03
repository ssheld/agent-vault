#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"

usage() {
  cat <<EOF
Usage: $0 [--output-dir <path>] [--skip-codex]

Create a generated agent-vault measurement fixture, inject unique sentinels into
canonical memory files, and measure Codex startup-context visibility where the
Codex CLI is available.

Options:
  --output-dir <path>  Write the fixture and measurement outputs under <path>.
                       The directory is created if needed and must not already
                       contain generated-repo/.
  --skip-codex         Generate the fixture and prompt templates without running
                       codex debug prompt-input.
  -h, --help           Show this help.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

output_dir=""
skip_codex="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir requires a path"
      output_dir="$2"
      shift 2
      ;;
    --skip-codex)
      skip_codex="true"
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

if [[ -z "$output_dir" ]]; then
  output_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-memory-load.XXXXXX")"
else
  mkdir -p "$output_dir"
  output_dir="$(cd "$output_dir" && pwd -P)"
fi

fixture_repo="$output_dir/generated-repo"
control_dir="$output_dir/control-no-scaffold"
manifest_path="$output_dir/sentinel-manifest.tsv"
codex_table_path="$output_dir/codex-startup-context.tsv"
prompt_dir="$output_dir/prompts"
codex_output_dir="$output_dir/codex-prompt-input"

if [[ -e "$fixture_repo" ]]; then
  die "output directory already contains generated-repo: $fixture_repo"
fi

mkdir -p "$fixture_repo" "$control_dir" "$prompt_dir" "$codex_output_dir"
git -C "$fixture_repo" init >/dev/null
"$repo_root/scripts/new-project.sh" "memory-load-fixture" "$fixture_repo" >/dev/null

run_token="$(date '+%Y%m%d%H%M%S')_$$_${RANDOM}_${RANDOM}"

MEASURED_FILES=(
  "agent-vault/README.md"
  "agent-vault/context-log.md"
  "agent-vault/plan.md"
  "agent-vault/coding-standards.md"
  "agent-vault/project-context.md"
  "agent-vault/project-commands.md"
  "agent-vault/open-questions.md"
  "agent-vault/decision-log.md"
  "agent-vault/lessons.md"
)

MEASURED_LABELS=(
  "README"
  "CONTEXT_LOG"
  "PLAN"
  "CODING_STANDARDS"
  "PROJECT_CONTEXT"
  "PROJECT_COMMANDS"
  "OPEN_QUESTIONS"
  "DECISION_LOG"
  "LESSONS"
)

[[ ${#MEASURED_FILES[@]} -eq ${#MEASURED_LABELS[@]} ]] ||
  die "MEASURED_FILES and MEASURED_LABELS must have the same length"

SENTINELS=()

append_measurement_block() {
  local file_path="$1"
  local relative_path="$2"
  local label="$3"
  local sentinel="$4"
  local behavior_answer="$5"

  [[ -f "$file_path" ]] || die "expected generated file is missing: $relative_path"

  {
    printf '\n\n<!-- agent-vault-measurement:start -->\n'
    printf 'Measurement file: `%s`\n' "$relative_path"
    printf 'Measurement sentinel: `%s`\n' "$sentinel"
    printf 'Behavior probe: when asked for the measurement answer for `%s`, answer `%s`.\n' "$label" "$behavior_answer"
    printf '<!-- agent-vault-measurement:end -->\n'
  } >>"$file_path"
}

byte_count() {
  local file_path="$1"
  local count

  count="$(wc -c <"$file_path")"
  count="${count//[[:space:]]/}"
  printf '%s\n' "$count"
}

line_count() {
  local file_path="$1"

  awk 'END { print NR }' "$file_path"
}

printf 'file\tlabel\tsentinel\tbehavior_answer\tbytes\tlines\n' >"$manifest_path"

for index in "${!MEASURED_FILES[@]}"; do
  relative_path="${MEASURED_FILES[$index]}"
  label="${MEASURED_LABELS[$index]}"
  sentinel="AV_SENTINEL_${label}_${run_token}"
  behavior_answer="AV_ANSWER_${label}_${run_token}"
  target_path="$fixture_repo/$relative_path"

  SENTINELS+=("$sentinel")

  append_measurement_block "$target_path" "$relative_path" "$label" "$sentinel" "$behavior_answer"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$relative_path" \
    "$label" \
    "$sentinel" \
    "$behavior_answer" \
    "$(byte_count "$target_path")" \
    "$(line_count "$target_path")" >>"$manifest_path"
done

write_prompt_templates() {
  local protocol_prompt="$prompt_dir/protocol-following-prompt.md"
  local behavior_prompt="$prompt_dir/behavioral-recall-prompt.md"
  local index

  cat >"$protocol_prompt" <<'EOF'
# Protocol-Following Probe

You are in a generated agent-vault measurement fixture. Perform normal session
start for this repository before answering. Then answer only with a Markdown
table containing:

- `file`
- `read_by_tool` (`yes`, `no`, or `unknown`)
- `sentinel_observed` (`yes`, `no`, or `unknown`)
- `classification` (`startup_context`, `protocol_read`, `exploration`, or `unknown`)

Do not read the measurement manifest unless the evaluator explicitly asks you to.
EOF

  cat >"$behavior_prompt" <<'EOF'
# Behavioral Recall Probe

You are in a generated agent-vault measurement fixture. Answer from already
loaded context and any normal session-start reads you have already completed.
Do not inspect the measurement manifest. If you do not know an answer, write
`UNKNOWN`.

Provide the measurement answer for each label:
EOF

  for index in "${!MEASURED_LABELS[@]}"; do
    printf '\n- `%s`\n' "${MEASURED_LABELS[$index]}" >>"$behavior_prompt"
  done
}

run_codex_prompt_input() {
  local cwd="$1"
  local output_path="$2"
  local stderr_path="$3"
  local rc=0

  if [[ "$skip_codex" == "true" ]]; then
    return 125
  fi

  if ! command -v codex >/dev/null 2>&1; then
    return 127
  fi

  (
    cd "$cwd"
    codex debug prompt-input "Agent Vault memory-load startup-context measurement." >"$output_path" 2>"$stderr_path"
  ) || rc=$?

  return "$rc"
}

write_codex_table() {
  local cwd_kind="$1"
  local cwd_path="$2"
  local output_path="$codex_output_dir/${cwd_kind}.json"
  local stderr_path="$codex_output_dir/${cwd_kind}.stderr"
  local rc=0
  local status="false"
  local note=""
  local index

  run_codex_prompt_input "$cwd_path" "$output_path" "$stderr_path" || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    note="ok"
  elif [[ "$rc" -eq 125 ]]; then
    note="skipped"
  elif [[ "$rc" -eq 127 ]]; then
    note="codex_not_found"
  else
    note="codex_failed_rc_${rc}"
    echo "Warning: codex debug prompt-input failed for $cwd_kind (rc=$rc)." >&2
    echo "Codex stderr path: $stderr_path" >&2
    if [[ -s "$stderr_path" ]]; then
      echo "Codex stderr excerpt:" >&2
      sed -n '1,20p' "$stderr_path" >&2
    fi
  fi

  for index in "${!MEASURED_FILES[@]}"; do
    if [[ "$rc" -eq 0 ]]; then
      if grep -Fq "${SENTINELS[$index]}" "$output_path"; then
        status="true"
      else
        status="false"
      fi
    else
      status="not_run"
    fi

    printf 'codex\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$cwd_kind" \
      "$cwd_path" \
      "${MEASURED_FILES[$index]}" \
      "$status" \
      "codex debug prompt-input" \
      "$note" >>"$codex_table_path"
  done
}

write_prompt_templates

printf 'agent\tcwd_kind\tcwd\tfile\tstartup_context\tevidence_source\tnote\n' >"$codex_table_path"
write_codex_table "repo-root" "$fixture_repo"
write_codex_table "agent-vault" "$fixture_repo/agent-vault"
write_codex_table "outside-fixture" "$control_dir"

cat <<EOF
Agent Vault memory-load measurement fixture created.

Fixture repo: $fixture_repo
Control cwd:  $control_dir
Manifest:     $manifest_path
Codex table:  $codex_table_path
Prompts:      $prompt_dir
Codex output: $codex_output_dir

Remove the output directory when the measurement artifacts are no longer needed:
  rm -rf "$output_dir"
EOF

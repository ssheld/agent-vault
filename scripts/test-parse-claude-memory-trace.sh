#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
parser="$repo_root/scripts/parse-claude-memory-trace.py"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-parser-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp_root"
}

trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0

fail() {
  echo "FAIL: $*" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
}

assert_grep() {
  local file_path="$1"
  local pattern="$2"
  local label="$3"

  if grep -F -- "$pattern" "$file_path" >/dev/null; then
    pass
  else
    fail "$label: expected '$pattern' in $file_path"
    echo "--- $file_path ---" >&2
    cat "$file_path" >&2
    echo "--- end ---" >&2
  fi
}

assert_no_grep() {
  local file_path="$1"
  local pattern="$2"
  local label="$3"

  if grep -F -- "$pattern" "$file_path" >/dev/null; then
    fail "$label: did not expect '$pattern' in $file_path"
    echo "--- $file_path ---" >&2
    cat "$file_path" >&2
    echo "--- end ---" >&2
  else
    pass
  fi
}

assert_row_count() {
  local file_path="$1"
  local expected="$2"
  local label="$3"
  local actual
  actual="$(awk 'NR>1' "$file_path" | wc -l | tr -d '[:space:]')"
  if [[ "$actual" == "$expected" ]]; then
    pass
  else
    fail "$label: expected $expected data rows in $file_path, got $actual"
    echo "--- $file_path ---" >&2
    cat "$file_path" >&2
    echo "--- end ---" >&2
  fi
}

write_manifest() {
  local manifest_path="$1"
  shift
  {
    printf 'file\tlabel\tsentinel\tbehavior_answer\tbytes\tlines\n'
    for file_path in "$@"; do
      local label="${file_path//\//_}"
      printf '%s\tLABEL_%s\tSENTINEL_%s\tANSWER_%s\t100\t10\n' \
        "$file_path" "$label" "$label" "$label"
    done
  } >"$manifest_path"
}

build_fixture() {
  local out_path="$1"
  local fixture_name="$2"
  python3 - "$out_path" "$fixture_name" <<'PYEOF'
import json
import sys

out_path, fixture_name = sys.argv[1], sys.argv[2]


def write(entries):
    with open(out_path, "w") as fh:
        for entry in entries:
            fh.write(json.dumps(entry) + "\n")


def main_user(uuid, parent, text, cwd="/fixture"):
    return {
        "type": "user",
        "uuid": uuid,
        "parentUuid": parent,
        "isSidechain": False,
        "cwd": cwd,
        "message": {"role": "user", "content": text},
    }


def main_user_clear(uuid, parent, cwd="/fixture"):
    text = (
        "<command-name>/clear</command-name>\n"
        "<command-message>clear</command-message>\n"
    )
    return main_user(uuid, parent, text, cwd=cwd)


def main_assistant_text(uuid, parent, text, cwd="/fixture"):
    return {
        "type": "assistant",
        "uuid": uuid,
        "parentUuid": parent,
        "isSidechain": False,
        "cwd": cwd,
        "message": {
            "role": "assistant",
            "content": [{"type": "text", "text": text}],
        },
    }


def main_assistant_tool(uuid, parent, tool_name, tool_input, tool_id="tool_x",
                       cwd="/fixture"):
    return {
        "type": "assistant",
        "uuid": uuid,
        "parentUuid": parent,
        "isSidechain": False,
        "cwd": cwd,
        "message": {
            "role": "assistant",
            "content": [
                {
                    "type": "tool_use",
                    "id": tool_id,
                    "name": tool_name,
                    "input": tool_input,
                }
            ],
        },
    }


fixtures = {}


def fixture_basic_main_read():
    return [
        main_user("u1", None, "do work"),
        main_assistant_tool(
            "a1",
            "u1",
            "Read",
            {"file_path": "/fixture/agent-vault/context-log.md"},
            tool_id="t1",
        ),
    ]


fixtures["basic_main_read"] = fixture_basic_main_read()


def fixture_main_grep_scoped():
    return [
        main_user("u1", None, "find something"),
        main_assistant_tool(
            "a1",
            "u1",
            "Grep",
            {"pattern": "TODO", "path": "agent-vault/", "output_mode": "files_with_matches"},
            tool_id="t1",
        ),
    ]


fixtures["main_grep_scoped"] = fixture_main_grep_scoped()


def fixture_bash_cat_high():
    return [
        main_user("u1", None, "show file"),
        main_assistant_tool(
            "a1",
            "u1",
            "Bash",
            {
                "command": "cat agent-vault/context-log.md",
                "description": "show context log",
            },
            tool_id="t1",
        ),
    ]


fixtures["bash_cat_high"] = fixture_bash_cat_high()


def fixture_bash_echo_low():
    return [
        main_user("u1", None, "echo a hint"),
        main_assistant_tool(
            "a1",
            "u1",
            "Bash",
            {
                "command": 'echo "see agent-vault/context-log.md for context"',
                "description": "log a hint",
            },
            tool_id="t1",
        ),
    ]


fixtures["bash_echo_low"] = fixture_bash_echo_low()


def fixture_agent_invocation():
    return [
        main_user("u1", None, "delegate"),
        main_assistant_tool(
            "a1",
            "u1",
            "Agent",
            {
                "description": "explore",
                "prompt": "investigate context",
                "subagent_type": "general-purpose",
            },
            tool_id="t_agent",
        ),
        main_user(
            "u2",
            "a1",
            [
                {
                    "type": "tool_result",
                    "tool_use_id": "t_agent",
                    "content": [
                        {"type": "text", "text": "agent reports: done"},
                    ],
                }
            ],
        ),
    ]


fixtures["agent_invocation"] = fixture_agent_invocation()


def fixture_clear_boundary():
    return [
        main_user("u1", None, "first task"),
        main_assistant_tool(
            "a1",
            "u1",
            "Read",
            {"file_path": "/fixture/agent-vault/context-log.md"},
            tool_id="t1",
        ),
        main_user_clear("u_clear", "a1"),
        main_user("u2", "u_clear", "post-clear task"),
        main_assistant_tool(
            "a2",
            "u2",
            "Read",
            {"file_path": "/fixture/agent-vault/plan.md"},
            tool_id="t2",
        ),
    ]


fixtures["clear_boundary"] = fixture_clear_boundary()


def fixture_no_clear_marker():
    return [
        main_user("u1", None, "task"),
        main_assistant_tool(
            "a1",
            "u1",
            "Read",
            {"file_path": "/fixture/agent-vault/coding-standards.md"},
            tool_id="t1",
        ),
    ]


fixtures["no_clear_marker"] = fixture_no_clear_marker()


def fixture_density_no_reads():
    return [
        main_user("u1", None, "talk only"),
        main_assistant_text("a1", "u1", "I do not need to read anything."),
    ]


fixtures["density_no_reads"] = fixture_density_no_reads()


def fixture_grep_pattern_mention():
    return [
        main_user("u1", None, "search"),
        main_assistant_tool(
            "a1",
            "u1",
            "Grep",
            {"pattern": "agent-vault/context-log.md is the source"},
            tool_id="t1",
        ),
    ]


fixtures["grep_pattern_mention"] = fixture_grep_pattern_mention()


def fixture_malformed_clear():
    return [
        main_user("u1", None, "task"),
        main_user("u_almost_clear", "u1", "<command-name>/cleared</command-name>"),
        main_assistant_tool(
            "a1",
            "u_almost_clear",
            "Read",
            {"file_path": "/fixture/agent-vault/context-log.md"},
            tool_id="t1",
        ),
    ]


fixtures["malformed_clear"] = fixture_malformed_clear()


def fixture_absolute_grep_path():
    return [
        main_user("u1", None, "search"),
        main_assistant_tool(
            "a1",
            "u1",
            "Grep",
            {
                "pattern": "TODO",
                "path": "/fixture/agent-vault/",
                "output_mode": "files_with_matches",
            },
            tool_id="t1",
        ),
    ]


fixtures["absolute_grep_path"] = fixture_absolute_grep_path()


def fixture_absolute_bash_cat():
    return [
        main_user("u1", None, "show file"),
        main_assistant_tool(
            "a1",
            "u1",
            "Bash",
            {
                "command": "cat /fixture/agent-vault/context-log.md",
                "description": "show context log via absolute path",
            },
            tool_id="t1",
        ),
    ]


fixtures["absolute_bash_cat"] = fixture_absolute_bash_cat()


def fixture_cd_prefix_bash_cat():
    return [
        main_user("u1", None, "show file via cd"),
        main_assistant_tool(
            "a1",
            "u1",
            "Bash",
            {
                "command": "cd /fixture && cat agent-vault/context-log.md",
                "description": "show context log via cd",
            },
            tool_id="t1",
            cwd="/elsewhere",
        ),
    ]


fixtures["cd_prefix_bash_cat"] = fixture_cd_prefix_bash_cat()


def fixture_subagent_fresh_only():
    return [
        main_user("u1", None, "delegate before any clear"),
        main_assistant_tool(
            "a1",
            "u1",
            "Agent",
            {
                "description": "explore",
                "prompt": "investigate",
                "subagent_type": "general-purpose",
            },
            tool_id="t_agent",
        ),
        main_user(
            "u2",
            "a1",
            [
                {
                    "type": "tool_result",
                    "tool_use_id": "t_agent",
                    "content": [{"type": "text", "text": "done"}],
                }
            ],
        ),
        main_user_clear("u_clear", "u2"),
        main_user("u3", "u_clear", "post-clear continuing"),
        main_assistant_text("a2", "u3", "I do not delegate now."),
    ]


fixtures["subagent_fresh_only"] = fixture_subagent_fresh_only()


def fixture_subagent_post_clear_only():
    return [
        main_user("u1", None, "main work"),
        main_assistant_text("a1", "u1", "doing main work"),
        main_user_clear("u_clear", "a1"),
        main_user("u2", "u_clear", "post-clear delegate"),
        main_assistant_tool(
            "a2",
            "u2",
            "Agent",
            {
                "description": "review",
                "prompt": "review the change",
                "subagent_type": "general-purpose",
            },
            tool_id="t_agent",
        ),
        main_user(
            "u3",
            "a2",
            [
                {
                    "type": "tool_result",
                    "tool_use_id": "t_agent",
                    "content": [{"type": "text", "text": "approved"}],
                }
            ],
        ),
    ]


fixtures["subagent_post_clear_only"] = fixture_subagent_post_clear_only()


def fixture_first_read_before_strongest():
    return [
        main_user("u1", None, "search then read"),
        main_assistant_tool(
            "a_medium",
            "u1",
            "Bash",
            {
                "command": "wc -l agent-vault/context-log.md",
                "description": "count lines",
            },
            tool_id="t_med",
        ),
        main_user(
            "u2",
            "a_medium",
            [
                {
                    "type": "tool_result",
                    "tool_use_id": "t_med",
                    "content": [{"type": "text", "text": "120 agent-vault/context-log.md"}],
                }
            ],
        ),
        main_assistant_tool(
            "a_high",
            "u2",
            "Read",
            {"file_path": "/fixture/agent-vault/context-log.md"},
            tool_id="t_high",
        ),
    ]


fixtures["first_read_before_strongest"] = fixture_first_read_before_strongest()


def fixture_relative_dot_grep_path():
    return [
        main_user("u1", None, "search via ./"),
        main_assistant_tool(
            "a1",
            "u1",
            "Grep",
            {
                "pattern": "TODO",
                "path": "./agent-vault/",
                "output_mode": "files_with_matches",
            },
            tool_id="t1",
        ),
    ]


fixtures["relative_dot_grep_path"] = fixture_relative_dot_grep_path()


def fixture_dot_only_grep():
    return [
        main_user("u1", None, "search the whole repo"),
        main_assistant_tool(
            "a1",
            "u1",
            "Grep",
            {"pattern": "TODO", "path": ".", "output_mode": "files_with_matches"},
            tool_id="t1",
        ),
    ]


fixtures["dot_only_grep"] = fixture_dot_only_grep()

if fixture_name not in fixtures:
    sys.exit(f"unknown fixture: {fixture_name}")

write(fixtures[fixture_name])
PYEOF
}

run_parser() {
  local jsonl_path="$1"
  local manifest_path="$2"
  local out_path="$3"
  python3 "$parser" --jsonl "$jsonl_path" --manifest "$manifest_path" --output "$out_path"
}

manifest_path="$tmp_root/manifest.tsv"
write_manifest "$manifest_path" \
  "agent-vault/context-log.md" \
  "agent-vault/plan.md" \
  "agent-vault/coding-standards.md"

# 1. basic_main_read: Read of context-log.md → tool_read=true, high
out_path="$tmp_root/out_basic_main_read.tsv"
build_fixture "$tmp_root/basic.jsonl" "basic_main_read"
run_parser "$tmp_root/basic.jsonl" "$manifest_path" "$out_path"

assert_row_count "$out_path" "3" "basic: 3 rows for 3 manifest files in main/fresh_start"
assert_grep "$out_path" $'main\t\tfresh_start' "basic: main fresh_start cell exists"
assert_grep "$out_path" $'agent-vault/context-log.md\ttrue\thigh' "basic: context-log read=true high"
assert_grep "$out_path" $'agent-vault/plan.md\tfalse\tnone' "basic: plan no evidence"
assert_grep "$out_path" $'agent-vault/coding-standards.md\tfalse\tnone' "basic: coding-standards no evidence"
assert_no_grep "$out_path" $'\tsubagent\t' "basic: no subagent rows"
assert_no_grep "$out_path" "post_clear" "basic: no post_clear rows"

# 2. main_grep_scoped: Grep with path="agent-vault/" → high for files in that dir
out_path="$tmp_root/out_grep.tsv"
build_fixture "$tmp_root/grep.jsonl" "main_grep_scoped"
run_parser "$tmp_root/grep.jsonl" "$manifest_path" "$out_path"

assert_grep "$out_path" $'agent-vault/context-log.md\ttrue\thigh' "grep: context-log scoped high"
assert_grep "$out_path" $'agent-vault/plan.md\ttrue\thigh' "grep: plan scoped high"
assert_grep "$out_path" $'agent-vault/coding-standards.md\ttrue\thigh' "grep: coding-standards scoped high"

# 3. bash_cat_high: cat <file> → tool_read=true high
out_path="$tmp_root/out_bash_cat.tsv"
build_fixture "$tmp_root/bash_cat.jsonl" "bash_cat_high"
run_parser "$tmp_root/bash_cat.jsonl" "$manifest_path" "$out_path"

assert_grep "$out_path" $'agent-vault/context-log.md\ttrue\thigh' "bash_cat: high confidence"
assert_grep "$out_path" "Bash: cat <file>" "bash_cat: evidence string"

# 4. bash_echo_low: echo "see <file>" → tool_read=false low_path_mention_only
out_path="$tmp_root/out_bash_echo.tsv"
build_fixture "$tmp_root/bash_echo.jsonl" "bash_echo_low"
run_parser "$tmp_root/bash_echo.jsonl" "$manifest_path" "$out_path"

assert_grep "$out_path" $'agent-vault/context-log.md\tfalse\tlow_path_mention_only' \
  "bash_echo: low confidence, tool_read false"

# 5. agent_invocation: Agent tool spawns subagent → subagent row, tool_read=false, note set
out_path="$tmp_root/out_agent.tsv"
build_fixture "$tmp_root/agent.jsonl" "agent_invocation"
run_parser "$tmp_root/agent.jsonl" "$manifest_path" "$out_path"

assert_grep "$out_path" $'subagent\tgeneral-purpose\tfresh_start' \
  "agent: subagent cell exists with subagent_type"
assert_grep "$out_path" "subagent internal tool calls are not visible" \
  "agent: visibility-gap note attached"
assert_no_grep "$out_path" $'subagent\tgeneral-purpose\tfresh_start\t/fixture\tagent-vault/context-log.md\ttrue' \
  "agent: subagent never claims tool_read=true"

# 6. clear_boundary: pre-clear context-log read, post-clear plan read
out_path="$tmp_root/out_clear.tsv"
build_fixture "$tmp_root/clear.jsonl" "clear_boundary"
run_parser "$tmp_root/clear.jsonl" "$manifest_path" "$out_path"

assert_grep "$out_path" $'main\t\tfresh_start' "clear: fresh_start cell"
assert_grep "$out_path" $'main\t\tpost_clear' "clear: post_clear cell"
assert_grep "$out_path" $'fresh_start\t/fixture\tagent-vault/context-log.md\ttrue\thigh' \
  "clear: context-log read in fresh_start"
assert_grep "$out_path" $'post_clear\t/fixture\tagent-vault/plan.md\ttrue\thigh' \
  "clear: plan read in post_clear"
assert_grep "$out_path" $'fresh_start\t\tagent-vault/plan.md\tfalse\tnone' \
  "clear: plan not read in fresh_start"
assert_grep "$out_path" $'post_clear\t\tagent-vault/context-log.md\tfalse\tnone' \
  "clear: context-log not read in post_clear"

# 7. no_clear_marker: no /clear → only fresh_start cells
out_path="$tmp_root/out_noclear.tsv"
build_fixture "$tmp_root/noclear.jsonl" "no_clear_marker"
run_parser "$tmp_root/noclear.jsonl" "$manifest_path" "$out_path"

assert_no_grep "$out_path" "post_clear" "no_clear: no post_clear cells"
assert_grep "$out_path" $'agent-vault/coding-standards.md\ttrue\thigh' \
  "no_clear: coding-standards read"

# 8. density_no_reads: 3 manifest files, no reads → 3 dense rows
out_path="$tmp_root/out_density.tsv"
build_fixture "$tmp_root/density.jsonl" "density_no_reads"
run_parser "$tmp_root/density.jsonl" "$manifest_path" "$out_path"

assert_row_count "$out_path" "3" "density: 3 rows even with no reads"
assert_no_grep "$out_path" $'\ttrue\t' "density: no tool_read=true"

# 9. grep_pattern_mention: pattern contains file path → medium confidence
out_path="$tmp_root/out_grep_pattern.tsv"
build_fixture "$tmp_root/grep_pattern.jsonl" "grep_pattern_mention"
run_parser "$tmp_root/grep_pattern.jsonl" "$manifest_path" "$out_path"

assert_grep "$out_path" $'agent-vault/context-log.md\ttrue\tmedium' \
  "grep_pattern: pattern mention is medium"

# 10. malformed_clear: literal "/cleared" should not trip /clear detection
out_path="$tmp_root/out_malformed.tsv"
build_fixture "$tmp_root/malformed.jsonl" "malformed_clear"
run_parser "$tmp_root/malformed.jsonl" "$manifest_path" "$out_path"

assert_no_grep "$out_path" "post_clear" "malformed_clear: no post_clear cells"
assert_grep "$out_path" $'fresh_start\t/fixture\tagent-vault/context-log.md\ttrue\thigh' \
  "malformed_clear: read still recorded under fresh_start"

# 11. session-id resolution supports Claude's punctuation-normalized cwd encoding
session_home="$tmp_root/home"
session_cwd="$tmp_root/session.root_with_punctuation/generated.repo"
session_id="11111111-1111-1111-1111-111111111111"
mkdir -p "$session_cwd"
encoded_session_cwd="$(
  python3 - "$session_cwd" <<'PYEOF'
import pathlib
import re
import sys

cwd = str(pathlib.Path(sys.argv[1]).resolve())
slash_only = cwd.replace("/", "-")
print(re.sub(r"[^A-Za-z0-9-]", "-", slash_only))
PYEOF
)"
session_jsonl="$session_home/.claude/projects/$encoded_session_cwd/$session_id.jsonl"
mkdir -p "$(dirname "$session_jsonl")"
build_fixture "$session_jsonl" "basic_main_read"

out_path="$tmp_root/out_session_success.tsv"
HOME="$session_home" python3 "$parser" \
  --session-id "$session_id" \
  --cwd "$session_cwd" \
  --manifest "$manifest_path" \
  --output "$out_path"
assert_grep "$out_path" $'agent-vault/context-log.md\ttrue\thigh' \
  "session-id success: punctuation-normalized cwd resolved"

# 12. session-id resolution failure
session_out_path="$tmp_root/out_session_err.txt"
session_rc=0
python3 "$parser" \
  --session-id "00000000-0000-0000-0000-000000000000" \
  --cwd "$tmp_root" \
  --manifest "$manifest_path" \
  --output "$tmp_root/should_not_exist.tsv" \
  >"$session_out_path" 2>&1 || session_rc=$?
if [[ "$session_rc" -ne 0 ]]; then
  pass
else
  fail "session-id missing: expected non-zero exit, got 0"
fi
assert_grep "$session_out_path" "could not resolve session id" \
  "session-id missing: error message present"

# 13. require either --jsonl or --session-id
missing_out_path="$tmp_root/out_missing.txt"
missing_rc=0
python3 "$parser" --manifest "$manifest_path" >"$missing_out_path" 2>&1 || missing_rc=$?
if [[ "$missing_rc" -ne 0 ]]; then
  pass
else
  fail "missing input: expected non-zero exit"
fi
assert_grep "$missing_out_path" "either --jsonl or both" \
  "missing input: helpful message"

# 13. absolute_grep_path: Grep path="/fixture/agent-vault/" with cwd /fixture → high
out_path="$tmp_root/out_abs_grep.tsv"
build_fixture "$tmp_root/abs_grep.jsonl" "absolute_grep_path"
run_parser "$tmp_root/abs_grep.jsonl" "$manifest_path" "$out_path"

assert_grep "$out_path" $'agent-vault/context-log.md\ttrue\thigh' \
  "abs_grep: context-log scoped via absolute path is high"
assert_grep "$out_path" $'agent-vault/plan.md\ttrue\thigh' \
  "abs_grep: plan scoped via absolute path is high"

# 14. absolute_bash_cat: Bash "cat /fixture/agent-vault/context-log.md" with cwd /fixture → high
out_path="$tmp_root/out_abs_cat.tsv"
build_fixture "$tmp_root/abs_cat.jsonl" "absolute_bash_cat"
run_parser "$tmp_root/abs_cat.jsonl" "$manifest_path" "$out_path"

assert_grep "$out_path" $'agent-vault/context-log.md\ttrue\thigh' \
  "abs_cat: absolute Bash cat is high"
assert_grep "$out_path" "Bash: cat <file>" "abs_cat: evidence string"

# 15. cd_prefix_bash_cat: "cd /fixture && cat agent-vault/context-log.md" with cwd /elsewhere → high
out_path="$tmp_root/out_cd_cat.tsv"
build_fixture "$tmp_root/cd_cat.jsonl" "cd_prefix_bash_cat"
run_parser "$tmp_root/cd_cat.jsonl" "$manifest_path" "$out_path"

assert_grep "$out_path" $'agent-vault/context-log.md\ttrue\thigh' \
  "cd_cat: cd-prefixed cat is high"

# 16. subagent_fresh_only: Agent invoked before /clear; no Agent after → only fresh_start cell
out_path="$tmp_root/out_sub_fresh.tsv"
build_fixture "$tmp_root/sub_fresh.jsonl" "subagent_fresh_only"
run_parser "$tmp_root/sub_fresh.jsonl" "$manifest_path" "$out_path"

assert_grep "$out_path" $'subagent\tgeneral-purpose\tfresh_start' \
  "sub_fresh: fresh_start subagent cell present"
assert_no_grep "$out_path" $'subagent\tgeneral-purpose\tpost_clear' \
  "sub_fresh: no fabricated post_clear subagent cell"
# Sanity: main post_clear cell still exists since /clear happened
assert_grep "$out_path" $'main\t\tpost_clear' \
  "sub_fresh: main post_clear cell still emitted"

# 17. subagent_post_clear_only: Agent invoked after /clear; no Agent before → only post_clear cell
out_path="$tmp_root/out_sub_post.tsv"
build_fixture "$tmp_root/sub_post.jsonl" "subagent_post_clear_only"
run_parser "$tmp_root/sub_post.jsonl" "$manifest_path" "$out_path"

assert_grep "$out_path" $'subagent\tgeneral-purpose\tpost_clear' \
  "sub_post: post_clear subagent cell present"
assert_no_grep "$out_path" $'subagent\tgeneral-purpose\tfresh_start' \
  "sub_post: no fabricated fresh_start subagent cell"

# 18. first_read_before_strongest: medium read at idx=1, high read at idx=3 → first_read_event_index=1, confidence=high
out_path="$tmp_root/out_first_read.tsv"
build_fixture "$tmp_root/first_read.jsonl" "first_read_before_strongest"
run_parser "$tmp_root/first_read.jsonl" "$manifest_path" "$out_path"

# Strongest confidence row should be high (from the Read at later index)
assert_grep "$out_path" $'agent-vault/context-log.md\ttrue\thigh' \
  "first_read: strongest is high"
# But first_read_event_index must point to the earlier medium read at index 1
context_log_row="$(awk -F'\t' '$6 == "agent-vault/context-log.md" && $4 == "fresh_start"' "$out_path")"
first_index="$(echo "$context_log_row" | awk -F'\t' '{print $10}')"
if [[ "$first_index" == "1" ]]; then
  pass
else
  fail "first_read: expected first_read_event_index=1, got '$first_index'"
  echo "context-log row: $context_log_row" >&2
fi
first_uuid="$(echo "$context_log_row" | awk -F'\t' '{print $11}')"
if [[ "$first_uuid" == "a_medium" ]]; then
  pass
else
  fail "first_read: expected first_read_uuid=a_medium, got '$first_uuid'"
fi

# 19. relative_dot_grep_path: Grep path="./agent-vault/" → high for files under agent-vault/
out_path="$tmp_root/out_dotrel_grep.tsv"
build_fixture "$tmp_root/dotrel_grep.jsonl" "relative_dot_grep_path"
run_parser "$tmp_root/dotrel_grep.jsonl" "$manifest_path" "$out_path"

assert_grep "$out_path" $'agent-vault/context-log.md\ttrue\thigh' \
  "dotrel_grep: context-log under ./agent-vault/ is high"
assert_grep "$out_path" $'agent-vault/plan.md\ttrue\thigh' \
  "dotrel_grep: plan under ./agent-vault/ is high"

# 20. dot_only_grep: Grep path="." → high for every manifest entry
out_path="$tmp_root/out_dot_grep.tsv"
build_fixture "$tmp_root/dot_grep.jsonl" "dot_only_grep"
run_parser "$tmp_root/dot_grep.jsonl" "$manifest_path" "$out_path"

assert_grep "$out_path" $'agent-vault/context-log.md\ttrue\thigh' \
  "dot_grep: context-log scoped to . is high"
assert_grep "$out_path" $'agent-vault/plan.md\ttrue\thigh' \
  "dot_grep: plan scoped to . is high"
assert_grep "$out_path" $'agent-vault/coding-standards.md\ttrue\thigh' \
  "dot_grep: coding-standards scoped to . is high"

echo
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "Claude memory-trace parser tests: $PASS_COUNT passed, $FAIL_COUNT failed."
  exit 1
fi
echo "Claude memory-trace parser tests: $PASS_COUNT passed."

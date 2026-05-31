#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
checker="$repo_root/scaffold/root/scripts/check-lessons-archive.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-lessons-test.XXXXXX")"

cleanup() { rm -rf "$tmp_root"; }
trap cleanup EXIT

# expect_result <expected_exit> <must_contain|""> <checker args...>
expect_result() {
  local expected_rc="$1" must_contain="$2"
  shift 2
  local output rc
  set +e
  output="$("$checker" "$@" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne "$expected_rc" ]]; then
    echo "FAIL: expected exit $expected_rc, got $rc for: $*" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if [[ -n "$must_contain" && "$output" != *"$must_contain"* ]]; then
    echo "FAIL: output missing '$must_contain' for: $*" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

# --- Canonical layout fixture: agent-vault/{lessons.md, context/archive/...} ---
mk_layout() {
  local d="$1"
  mkdir -p "$d/agent-vault/context/archive"
  cat >"$d/agent-vault/lessons.md" <<'EOF'
# Lessons Learned

## Usage Rules
- Newest entry at top.

## Entries

### Always use real date timestamps in durable memory
- Don't fabricate dates.
EOF
  cat >"$d/agent-vault/context/archive/lessons-archive.md" <<'EOF'
# Lessons Archive

## Entries

### Avoid SC2178 local-var name collisions across functions
- Full write-up...

### Old workaround for the pre-2025 hook bug
- Full write-up...
EOF
}

manifest_path() { printf '%s/agent-vault/context/archive/lessons-manifest.md' "$1"; }

# --- 1. Healthy manifest passes in both default and strict modes ----------
d="$tmp_root/ok"
mk_layout "$d"
cat >"$(manifest_path "$d")" <<'EOF'
# Lessons Archive Manifest

## lesson: Avoid SC2178 local-var name collisions across functions
- classification: retained-as-quick-rule

## lesson: Old workaround for the pre-2025 hook bug
- classification: covered-by-a-named-always-on-rule
- covered_by: Always use real date timestamps in durable memory
EOF
expect_result 0 "check passed" "$(manifest_path "$d")"
expect_result 0 "check passed" "$(manifest_path "$d")" --strict

# --- 2. Invalid classification: warn (exit 0) by default, fail under --strict
d="$tmp_root/badclass"
mk_layout "$d"
cat >"$(manifest_path "$d")" <<'EOF'
# Lessons Archive Manifest

## lesson: Avoid SC2178 local-var name collisions across functions
- classification: keep-it-around

## lesson: Old workaround for the pre-2025 hook bug
- classification: archival-only
EOF
expect_result 0 "invalid classification" "$(manifest_path "$d")"
expect_result 1 "invalid classification" "$(manifest_path "$d")" --strict

# --- 3. Missing classification is flagged ---------------------------------
d="$tmp_root/noclass"
mk_layout "$d"
cat >"$(manifest_path "$d")" <<'EOF'
# Lessons Archive Manifest

## lesson: Avoid SC2178 local-var name collisions across functions
- note: forgot to classify

## lesson: Old workaround for the pre-2025 hook bug
- classification: archival-only
EOF
expect_result 1 "has no classification" "$(manifest_path "$d")" --strict

# --- 4. Duplicate lesson keys are flagged --------------------------------
d="$tmp_root/dup"
mk_layout "$d"
cat >"$(manifest_path "$d")" <<'EOF'
# Lessons Archive Manifest

## lesson: Avoid SC2178 local-var name collisions across functions
- classification: archival-only

## lesson: Avoid SC2178 local-var name collisions across functions
- classification: archival-only
EOF
expect_result 1 "duplicate lesson key" "$(manifest_path "$d")" --strict

# --- 5. covered-by-a-named-... with no covered_by is flagged --------------
d="$tmp_root/nocovered"
mk_layout "$d"
cat >"$(manifest_path "$d")" <<'EOF'
# Lessons Archive Manifest

## lesson: Avoid SC2178 local-var name collisions across functions
- classification: covered-by-a-named-always-on-rule
EOF
expect_result 1 "names no \"covered_by\" rule" "$(manifest_path "$d")" --strict

# --- 6. covered_by that is NOT in any live rules source is flagged --------
d="$tmp_root/deadrule"
mk_layout "$d"
cat >"$(manifest_path "$d")" <<'EOF'
# Lessons Archive Manifest

## lesson: Avoid SC2178 local-var name collisions across functions
- classification: covered-by-a-named-always-on-rule
- covered_by: A rule that does not exist in any live file
EOF
expect_result 1 "was not found in any live rules source" "$(manifest_path "$d")" --strict

# --- 7. covered_by set on a non-covered-by record is flagged --------------
d="$tmp_root/straycovered"
mk_layout "$d"
cat >"$(manifest_path "$d")" <<'EOF'
# Lessons Archive Manifest

## lesson: Avoid SC2178 local-var name collisions across functions
- classification: archival-only
- covered_by: Always use real date timestamps in durable memory
EOF
expect_result 1 "sets covered_by but is not covered-by" "$(manifest_path "$d")" --strict

# --- 8. --strict completeness: an archived lesson with no record fails ----
d="$tmp_root/incomplete"
mk_layout "$d"
cat >"$(manifest_path "$d")" <<'EOF'
# Lessons Archive Manifest

## lesson: Avoid SC2178 local-var name collisions across functions
- classification: archival-only
EOF
# Default mode tolerates it (warn-only); strict enforces completeness.
expect_result 0 "check" "$(manifest_path "$d")"
expect_result 1 "not classified in the manifest" "$(manifest_path "$d")" --strict

# --- 9. A manifest record for a lesson absent from the archive is flagged --
d="$tmp_root/dangling"
mk_layout "$d"
cat >"$(manifest_path "$d")" <<'EOF'
# Lessons Archive Manifest

## lesson: Avoid SC2178 local-var name collisions across functions
- classification: archival-only

## lesson: Old workaround for the pre-2025 hook bug
- classification: archival-only

## lesson: A lesson that was never archived
- classification: archival-only
EOF
expect_result 1 "not present in the archive" "$(manifest_path "$d")" --strict

# --- 10. Explicit --rules resolves covered_by against another file --------
d="$tmp_root/explicitrules"
mk_layout "$d"
cat >"$d/agent-vault/shared-rules.md" <<'EOF'
## Memory Size Budgets & Compaction
- Treat budget overflow as a defect rather than cosmetic.
EOF
cat >"$(manifest_path "$d")" <<'EOF'
# Lessons Archive Manifest

## lesson: Avoid SC2178 local-var name collisions across functions
- classification: covered-by-a-named-always-on-rule
- covered_by: Treat budget overflow as a defect

## lesson: Old workaround for the pre-2025 hook bug
- classification: archival-only
EOF
expect_result 0 "check passed" "$(manifest_path "$d")" --strict \
  --rules "$d/agent-vault/lessons.md" --rules "$d/agent-vault/shared-rules.md"

# --- 11. With no resolvable rules source, covered_by liveness is skipped ---
d="$tmp_root/norules"
mkdir -p "$d/isolated"
cat >"$d/isolated/lessons-manifest.md" <<'EOF'
# Lessons Archive Manifest

## lesson: some lesson
- classification: covered-by-a-named-always-on-rule
- covered_by: an unverifiable rule name
EOF
# No archive and no lessons.md next to it -> liveness check is skipped, the
# record is otherwise valid, so default mode passes.
expect_result 0 "check passed" "$d/isolated/lessons-manifest.md"

# --- 12. Usage / IO errors ------------------------------------------------
expect_result 2 "manifest not found" "$tmp_root/does-not-exist.md"
expect_result 2 "" # no manifest arg
expect_result 2 "archive file not found" "$(manifest_path "$tmp_root/ok")" --archive "$tmp_root/nope.md"
expect_result 2 "rules file not found" "$(manifest_path "$tmp_root/ok")" --rules "$tmp_root/nope.md"

# --- 13. --quiet suppresses success output but not failures ---------------
quiet_out="$("$checker" "$(manifest_path "$tmp_root/ok")" --quiet 2>&1)"
[[ -z "$quiet_out" ]] || {
  echo "FAIL: --quiet should print nothing on success; got: $quiet_out" >&2
  exit 1
}

# --- 14. CRLF manifest is tolerated --------------------------------------
d="$tmp_root/crlf"
mk_layout "$d"
cat >"$tmp_root/crlf-src.md" <<'EOF'
# Lessons Archive Manifest

## lesson: Avoid SC2178 local-var name collisions across functions
- classification: archival-only

## lesson: Old workaround for the pre-2025 hook bug
- classification: archival-only
EOF
sed 's/$/\r/' "$tmp_root/crlf-src.md" >"$(manifest_path "$d")"
expect_result 0 "check passed" "$(manifest_path "$d")" --strict

echo "lessons-archive checker regression checks passed."

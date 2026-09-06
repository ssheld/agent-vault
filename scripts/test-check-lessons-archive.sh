#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
checker="$repo_root/scaffold/root/scripts/check-lessons-archive.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-lessons-test.XXXXXX")"
tmp_root="$(cd "$tmp_root" && pwd -P)"

cleanup() { rm -rf "$tmp_root"; }
trap cleanup EXIT

# expect_result <expected_exit> <required substrings, one per line|""> <checker args...>
expect_result() {
  local expected_rc="$1" must_contain="$2"
  shift 2
  local output rc required
  set +e
  output="$("$checker" "$@" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne "$expected_rc" ]]; then
    echo "FAIL: expected exit $expected_rc, got $rc for: $*" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  while IFS= read -r required; do
    if [[ -n "$required" && "$output" != *"$required"* ]]; then
      echo "FAIL: output missing '$required' for: $*" >&2
      printf '%s\n' "$output" >&2
      exit 1
    fi
  done <<<"$must_contain"
  if [[ "$output" == *"skipped"* && "$output" == *"lessons-archive check passed:"* ]]; then
    echo "FAIL: skipped checks must not report success for: $*" >&2
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

# --- 11. Missing implicit sources warn by default and fail under --strict ---
d="$tmp_root/norules"
mkdir -p "$d/agent-vault/context/archive"
cat >"$(manifest_path "$d")" <<'EOF'
# Lessons Archive Manifest

## lesson: some lesson
- classification: covered-by-a-named-always-on-rule
- covered_by: an unverifiable rule name
EOF
# Both implicit lookup paths stay inside this fixture; the diagnostics must
# identify both unavailable checks, their concrete paths, and remediation.
missing_sources="archive checks skipped
$d/agent-vault/context/archive/lessons-archive.md
--archive <file>
lesson \"some lesson\" covered_by liveness check skipped
$d/agent-vault/context/archive/../../lessons.md
--rules <file>"
expect_result 0 "$missing_sources" "$(manifest_path "$d")"
expect_result 1 "$missing_sources" "$(manifest_path "$d")" --strict
expect_result 1 "$missing_sources" "$(manifest_path "$d")" --strict --quiet
quiet_out="$("$checker" "$(manifest_path "$d")" --quiet 2>&1)"
[[ -z "$quiet_out" ]] || {
  echo "FAIL: --quiet should suppress missing-source warnings; got: $quiet_out" >&2
  exit 1
}

# --- 11b. --rules is ADDITIVE: passing an extra source must not drop the default
# lessons.md, so a rule that lives in lessons.md still resolves.
d="$tmp_root/additive"
mk_layout "$d"
cat >"$d/agent-vault/shared-rules.md" <<'EOF'
## Memory Size Budgets & Compaction
- Treat budget overflow as a defect rather than cosmetic.
EOF
cat >"$(manifest_path "$d")" <<'EOF'
# Lessons Archive Manifest

## lesson: Avoid SC2178 local-var name collisions across functions
- classification: covered-by-a-named-always-on-rule
- covered_by: Always use real date timestamps in durable memory

## lesson: Old workaround for the pre-2025 hook bug
- classification: covered-by-a-named-always-on-rule
- covered_by: Treat budget overflow as a defect
EOF
# Only the shared-rules source is passed; the first rule (in the default
# lessons.md) must still resolve.
expect_result 0 "check passed" "$(manifest_path "$d")" --strict \
  --rules "$d/agent-vault/shared-rules.md"

# --- 11c. Optional quick_rule on a retained-as-quick-rule lesson is liveness-
# checked the same way as covered_by.
d="$tmp_root/quick"
mk_layout "$d"
cat >"$(manifest_path "$d")" <<'EOF'
# Lessons Archive Manifest

## lesson: Avoid SC2178 local-var name collisions across functions
- classification: retained-as-quick-rule
- quick_rule: Always use real date timestamps in durable memory

## lesson: Old workaround for the pre-2025 hook bug
- classification: archival-only
EOF
expect_result 0 "check passed" "$(manifest_path "$d")" --strict
cat >"$(manifest_path "$d")" <<'EOF'
# Lessons Archive Manifest

## lesson: Avoid SC2178 local-var name collisions across functions
- classification: retained-as-quick-rule
- quick_rule: a one-liner that is no longer in the live lessons file

## lesson: Old workaround for the pre-2025 hook bug
- classification: archival-only
EOF
expect_result 1 "quick_rule" "$(manifest_path "$d")" --strict
cat >"$(manifest_path "$d")" <<'EOF'
# Lessons Archive Manifest

## lesson: Avoid SC2178 local-var name collisions across functions
- classification: archival-only
- quick_rule: Always use real date timestamps in durable memory

## lesson: Old workaround for the pre-2025 hook bug
- classification: archival-only
EOF
expect_result 1 "sets quick_rule but is not retained-as-quick-rule" "$(manifest_path "$d")" --strict

# --- 12. Usage / IO errors ------------------------------------------------
expect_result 2 "manifest not found" "$tmp_root/does-not-exist.md"
expect_result 2 "" # no manifest arg
expect_result 2 "archive file not found" "$(manifest_path "$tmp_root/ok")" --archive "$tmp_root/nope.md"
expect_result 2 "rules file not found" "$(manifest_path "$tmp_root/ok")" --rules "$tmp_root/nope.md"
# Explicit missing paths remain usage/IO errors even with valid fallback sources.
expect_result 2 "archive file not found" "$(manifest_path "$tmp_root/ok")" --strict --archive "$tmp_root/nope.md"
expect_result 2 "rules file not found" "$(manifest_path "$tmp_root/ok")" --strict \
  --rules "$tmp_root/ok/agent-vault/lessons.md" --rules "$tmp_root/nope.md"

# --- 13. --quiet means "print only on failure": silent on success and on
# warn-mode findings (exit 0), but a --strict failure is still reported.
quiet_out="$("$checker" "$(manifest_path "$tmp_root/ok")" --quiet 2>&1)"
[[ -z "$quiet_out" ]] || {
  echo "FAIL: --quiet should print nothing on success; got: $quiet_out" >&2
  exit 1
}
d="$tmp_root/quietwarn"
mk_layout "$d"
cat >"$(manifest_path "$d")" <<'EOF'
# Lessons Archive Manifest

## lesson: Avoid SC2178 local-var name collisions across functions
- classification: not-a-real-class

## lesson: Old workaround for the pre-2025 hook bug
- classification: archival-only
EOF
set +e
qw_out="$("$checker" "$(manifest_path "$d")" --quiet 2>&1)"
qw_rc=$?
set -e
[[ "$qw_rc" -eq 0 && -z "$qw_out" ]] || {
  echo "FAIL: --quiet warn mode should be silent with rc 0; rc=$qw_rc out=$qw_out" >&2
  exit 1
}
# The same finding under --strict --quiet IS reported (it is a failure).
expect_result 1 "invalid classification" "$(manifest_path "$d")" --strict --quiet

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

# --- 15. Archive required regardless of rules availability or record count ---
d="$tmp_root/noarchive"
mkdir -p "$d/agent-vault/context/archive"
printf '%s\n' 'a live rule' >"$d/agent-vault/lessons.md"
cat >"$(manifest_path "$d")" <<'EOF'
## lesson: some lesson
- classification: covered-by-a-named-always-on-rule
- covered_by: a live rule
EOF
expect_result 0 "archive checks skipped" "$(manifest_path "$d")"
expect_result 1 "archive checks skipped" "$(manifest_path "$d")" --strict
printf '%s\n' '# Empty manifest' >"$(manifest_path "$d")"
expect_result 1 "archive checks skipped" "$(manifest_path "$d")" --strict
# With an empty archive, completeness can be checked and the empty pair passes.
printf '%s\n' '# Empty archive' >"$d/agent-vault/context/archive/lessons-archive.md"
expect_result 0 "check passed" "$(manifest_path "$d")" --strict

# --- 16. Rules required only for non-empty references on the matching class ---
for field in covered_by quick_rule; do
  d="$tmp_root/missing-$field"
  mkdir -p "$d/agent-vault/context/archive"
  printf '%s\n' '### some lesson' >"$d/agent-vault/context/archive/lessons-archive.md"
  classification="covered-by-a-named-always-on-rule"
  [[ "$field" != "quick_rule" ]] || classification="retained-as-quick-rule"
  cat >"$(manifest_path "$d")" <<EOF
## lesson: some lesson
- classification: $classification
- $field: a live rule
EOF
  missing_rules="lesson \"some lesson\" $field liveness check skipped
no live rules source resolved
$d/agent-vault/context/archive/../../lessons.md
--rules <file>"
  expect_result 0 "$missing_rules" "$(manifest_path "$d")"
  expect_result 1 "$missing_rules" "$(manifest_path "$d")" --strict
  expect_result 1 "$missing_rules" "$(manifest_path "$d")" --strict --quiet
  quiet_out="$("$checker" "$(manifest_path "$d")" --quiet 2>&1)"
  [[ -z "$quiet_out" ]] || {
    echo "FAIL: --quiet should suppress missing-$field warnings; got: $quiet_out" >&2
    exit 1
  }

  # An empty --rules argument is accepted but cannot establish availability.
  expect_result 0 "$missing_rules" "$(manifest_path "$d")" --rules ""
  expect_result 1 "$missing_rules" "$(manifest_path "$d")" --strict --rules ""

  # An existing empty file IS a source: a search is possible but finds no rule.
  : >"$d/empty-rules.md"
  expect_result 0 "was not found in any live rules source" "$(manifest_path "$d")" --rules "$d/empty-rules.md"
  expect_result 1 "was not found in any live rules source" "$(manifest_path "$d")" --strict --rules "$d/empty-rules.md"

  # Explicit-only rules resolve even with an empty argument before or after them.
  printf '%s\n' 'a live rule' >"$d/extra-rules.md"
  expect_result 0 "check passed" "$(manifest_path "$d")" --strict --rules "$d/extra-rules.md"
  expect_result 0 "check passed" "$(manifest_path "$d")" --strict --rules "" --rules "$d/extra-rules.md" --rules ""
  # Canonical discovery must likewise survive empty explicit arguments.
  cp "$d/extra-rules.md" "$d/agent-vault/lessons.md"
  expect_result 0 "check passed" "$(manifest_path "$d")" --strict --rules ""
done

d="$tmp_root/no-references"
mkdir -p "$d/agent-vault/context/archive"
cat >"$d/agent-vault/context/archive/lessons-archive.md" <<'EOF'
### archival lesson
### retained lesson
### retained lesson with empty reference
EOF
cat >"$(manifest_path "$d")" <<'EOF'
## lesson: archival lesson
- classification: archival-only
## lesson: retained lesson
- classification: retained-as-quick-rule
## lesson: retained lesson with empty reference
- classification: retained-as-quick-rule
- quick_rule:
EOF
expect_result 0 "check passed" "$(manifest_path "$d")" --strict
expect_result 0 "check passed" "$(manifest_path "$d")" --strict --rules ""

# Invalid records still produce their own findings without any rules source.
cat >"$(manifest_path "$d")" <<'EOF'
## lesson: archival lesson
- classification: covered-by-a-named-always-on-rule
## lesson: retained lesson
- classification: archival-only
- covered_by: stray covered rule
## lesson: retained lesson with empty reference
- classification: archival-only
- quick_rule: stray quick rule
EOF
expect_result 1 'names no "covered_by" rule
sets covered_by but is not covered-by-a-named-always-on-rule
sets quick_rule but is not retained-as-quick-rule' "$(manifest_path "$d")" --strict

# --- 17. Explicit sources support noncanonical layouts and paths with spaces ---
d="$tmp_root/explicit sources"
mkdir -p "$d/manifests/nested"
cat >"$d/manifests/nested/manifest.md" <<'EOF'
## lesson: some lesson
- classification: covered-by-a-named-always-on-rule
- covered_by: a live rule
EOF
printf '%s\n' '### some lesson' >"$d/archive.md"
printf '%s\n' 'a live rule' >"$d/rules.md"
expect_result 0 "check passed" "$d/manifests/nested/manifest.md" --strict \
  --archive "$d/archive.md" --rules "$d/rules.md"

echo "lessons-archive checker regression checks passed."

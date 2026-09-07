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
  if [[ "$output" == *"lessons-archive check passed:"* ]] &&
    [[ "$rc" -ne 0 || "$output" == *"warning:"* || "$output" == *"FAILED:"* || "$output" == *"skipped"* || "$output" == *"Error:"* ]]; then
    echo "FAIL: findings and errors must not report success for: $*" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  result_output="$output"
}

reject_output() {
  local forbidden
  for forbidden in "$@"; do
    if [[ "$result_output" == *"$forbidden"* ]]; then
      echo "FAIL: unexpected output '$forbidden'" >&2
      printf '%s\n' "$result_output" >&2
      exit 1
    fi
  done
}

expect_occurrences() {
  local expected="$1" needle="$2" actual
  actual="$(grep -Fo -- "$needle" <<<"$result_output" | wc -l)" || :
  actual="${actual//[[:space:]]/}"
  [[ "$actual" == "$expected" ]] || {
    echo "FAIL: expected $expected occurrences of '$needle', got $actual" >&2
    printf '%s\n' "$result_output" >&2
    exit 1
  }
}

expect_silent() {
  expect_result 0 "" "$@" --quiet
  [[ -z "$result_output" ]] || {
    echo "FAIL: --quiet advisory mode must be silent" >&2
    printf '%s\n' "$result_output" >&2
    exit 1
  }
}

expect_finding_modes() {
  local required="$1"
  shift
  expect_result 0 "$required" "$@"
  reject_output "check passed"
  expect_silent "$@"
  expect_result 1 "$required" "$@" --strict
  reject_output "check passed"
  expect_result 1 "$required" "$@" --strict --quiet
  reject_output "check passed"
}

# Count literal occurrences even when multiple matches share one line.
result_output=$'repeated repeated\nonce'
expect_occurrences 2 repeated
expect_occurrences 1 once
expect_occurrences 0 absent

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
# Empty --archive arguments retain canonical discovery in both modes.
expect_result 0 "check passed" "$(manifest_path "$d")" --archive ""
expect_result 0 "check passed" "$(manifest_path "$d")" --strict --archive ""

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
$d/agent-vault/lessons.md
--rules <file>"
expect_result 0 "$missing_sources" "$(manifest_path "$d")"
expect_result 1 "$missing_sources" "$(manifest_path "$d")" --strict
expect_result 1 "$missing_sources" "$(manifest_path "$d")" --strict --quiet
set +e
quiet_out="$("$checker" "$(manifest_path "$d")" --quiet 2>&1)"
quiet_rc=$?
set -e
[[ "$quiet_rc" -eq 0 && -z "$quiet_out" ]] || {
  echo "FAIL: --quiet should suppress missing-source warnings with rc 0; rc=$quiet_rc out=$quiet_out" >&2
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
expect_result 0 "archive checks skipped" "$(manifest_path "$d")" --archive ""
expect_result 1 "archive checks skipped" "$(manifest_path "$d")" --strict --archive ""
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
$d/agent-vault/lessons.md
--rules <file>"
  expect_result 0 "$missing_rules" "$(manifest_path "$d")"
  expect_result 1 "$missing_rules" "$(manifest_path "$d")" --strict
  expect_result 1 "$missing_rules" "$(manifest_path "$d")" --strict --quiet
  set +e
  quiet_out="$("$checker" "$(manifest_path "$d")" --quiet 2>&1)"
  quiet_rc=$?
  set -e
  [[ "$quiet_rc" -eq 0 && -z "$quiet_out" ]] || {
    echo "FAIL: --quiet should suppress missing-$field warnings with rc 0; rc=$quiet_rc out=$quiet_out" >&2
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

# --- 18. Report one missing archive and one liveness finding per lesson ---
d="$tmp_root/multiple-missing-sources"
mkdir -p "$d/agent-vault/context/archive"
cat >"$(manifest_path "$d")" <<'EOF'
## lesson: covered lesson
- classification: covered-by-a-named-always-on-rule
- covered_by: a covered rule
## lesson: retained lesson
- classification: retained-as-quick-rule
- quick_rule: a retained rule
EOF
multi_rc=0
multi_out="$("$checker" "$(manifest_path "$d")" --strict 2>&1)" || multi_rc=$?
finding_counts="$(awk '
  /^- archive checks skipped:/ { archives++ }
  /^- lesson "covered lesson" covered_by liveness check skipped:/ { covered++ }
  /^- lesson "retained lesson" quick_rule liveness check skipped:/ { quick++ }
  END { printf "%d %d %d", archives, covered, quick }
' <<<"$multi_out")"
if [[ "$multi_rc" -ne 1 || "$finding_counts" != "1 1 1" || "$multi_out" == *"check passed"* ]]; then
  echo "FAIL: expected one archive finding and one per lesson; rc=$multi_rc counts=$finding_counts" >&2
  printf '%s\n' "$multi_out" >&2
  exit 1
fi

# --- 19. Both inputs share delimiter-aware fences before interpreting content ---
d="$tmp_root/parser cases"
mkdir -p "$d/agent-vault/context/archive"
parser_manifest="$(manifest_path "$d")"
parser_archive="$d/agent-vault/context/archive/lessons-archive.md"
printf '%s\n' 'a live rule' >"$d/agent-vault/lessons.md"
# opener | line that must NOT close it | closer. Closing runs may be longer,
# info strings are allowed, and indentation is limited to three spaces.
fence_cases=(
  '```|~~~|```'
  '~~~|```|~~~'
  '````|```|````'
  '~~~~|~~~|~~~~'
  '```sh|``` trailing text|````  '
  $'~~~markdown|~~~ trailing text|~~~~\t'
  ' ```sh|``| ```'
  '  ~~~ info `ok`|~~|  ~~~'
  '   ```sh|``|   ```'
  '   ```sh|~~~| ```'
  '~~~|```|   ~~~~'
  '```|    ```|```'
  '~~~|    ~~~|~~~'
)
for fence_case in "${fence_cases[@]}"; do
  IFS='|' read -r opener false_closer closer <<<"$fence_case"
  for line_ending in lf crlf; do
    # The sample must not invent an archive heading, even after a false closer.
    printf '%s\n' '## lesson: real lesson' '- classification: archival-only' >"$parser_manifest"
    printf '%s\n' '### real lesson' "$opener" "$false_closer" '### ghost lesson' >"$parser_archive"
    # No final newline is intentional; CRLF conversion must preserve that case.
    printf '%s' "$closer" >>"$parser_archive"
    if [[ "$line_ending" == crlf ]]; then
      awk 'NR > 1 { printf "\r\n" } { printf "%s", $0 }' "$parser_archive" >"$d/converted.md"
      mv "$d/converted.md" "$parser_archive"
    fi
    cp "$parser_archive" "$d/archive-before.md"
    cp "$parser_manifest" "$d/manifest-before.md"
    expect_result 0 '(1 classified)' "$parser_manifest" --strict
    cmp "$d/archive-before.md" "$parser_archive"
    cmp "$d/manifest-before.md" "$parser_manifest"
    # A real heading after the closing fence must reach strict completeness.
    printf '\n%s\n' '### unclassified lesson' >>"$parser_archive"
    expect_result 1 'archived lesson is not classified in the manifest: "unclassified lesson"' "$parser_manifest" --strict
    reject_output 'ghost lesson' 'check passed'
    expect_result 0 'check passed' "$parser_manifest"

    # Fenced headings, section boundaries, identity and classification bullets
    # cannot create a record, end the real record, or alter its fields.
    printf '%s\n' '### real lesson' >"$parser_archive"
    printf '%s\n' '## lesson: real lesson' '- classification: covered-by-a-named-always-on-rule' \
      "$opener" "$false_closer" '- classification: invalid-inside-fence' \
      '- key: hijacked' '- quick_rule: hidden rule' '# Example section' '## Example subsection' \
      '## lesson: unclassified lesson' '- classification: archival-only' "$closer" >"$parser_manifest"
    printf '%s' '- covered_by: a live rule' >>"$parser_manifest"
    if [[ "$line_ending" == crlf ]]; then
      awk 'NR > 1 { printf "\r\n" } { printf "%s", $0 }' "$parser_manifest" >"$d/converted.md"
      mv "$d/converted.md" "$parser_manifest"
    fi
    expect_result 0 '(1 classified)' "$parser_manifest" --strict
    printf '%s\n' '### unclassified lesson' >>"$parser_archive"
    expect_result 1 'archived lesson is not classified in the manifest: "unclassified lesson"' "$parser_manifest" --strict
    reject_output 'not present in the archive' 'hijacked' 'invalid-inside-fence' 'check passed'
  done
done

# A backtick in a backtick opener's info string invalidates the opener; four
# leading spaces and runs shorter than three are likewise not fence openers.
for non_opener in '```bad`info' '    ```' '    ~~~' '``' '~~'; do
  printf '%s\n' "$non_opener" '### real lesson' >"$parser_archive"
  printf '%s\n' "$non_opener" '## lesson: real lesson' '- classification: archival-only' >"$parser_manifest"
  expect_result 0 '(1 classified)' "$parser_manifest" --strict
  reject_output 'unterminated'
done

# --- 20. Unclosed fences are findings, not successful or complete parses ---
for input_kind in manifest archive; do
  for prefix in empty populated; do
    for opener in '```' '~~~'; do
      printf '%s\n' '# Manifest' >"$parser_manifest"
      printf '%s\n' '# Archive' >"$parser_archive"
      if [[ "$prefix" == populated ]]; then
        printf '%s\n' '## lesson: real lesson' '- classification: archival-only' >>"$parser_manifest"
        printf '%s\n' '### real lesson' >>"$parser_archive"
      fi
      if [[ "$input_kind" == archive ]]; then
        source_path="$parser_archive"
        # This lesson may be hidden in the truncated archive: do not infer absence.
        printf '%s\n' '## lesson: hidden lesson' '- classification: archival-only' >>"$parser_manifest"
      else
        source_path="$parser_manifest"
        printf '%s\n' '### hidden lesson' >>"$parser_archive"
      fi
      opening_line="$(awk 'END { print NR + 1 }' "$source_path")"
      printf '%s\n' "$opener" >>"$source_path"
      printf '%s' 'unterminated content without final newline' >>"$source_path"
      expect_finding_modes "unterminated fence in $input_kind
$source_path:$opening_line" "$parser_manifest"
      reject_output 'not present in the archive' 'not classified in the manifest'
      expect_occurrences 1 'unterminated fence'
    done
  done
done
# Even known headings in an incomplete input cannot support absence claims.
printf '%s\n' '## lesson: missing from archive' '- classification: archival-only' '```' >"$parser_manifest"
printf '%s\n' '### missing from manifest' '~~~' >"$parser_archive"
expect_finding_modes 'unterminated fence in manifest
unterminated fence in archive' "$parser_manifest"
reject_output 'not present in the archive' 'not classified in the manifest'

# --- 21. Classifications are exact values; invalid records do not cover lessons ---
printf '%s\n' '### real lesson' >"$parser_archive"
for bad_class in \
  'retained-as-quick-rule covered-by-a-named-always-on-rule' \
  'covered-by-a-named-always-on-rule archival-only' \
  'retained-as-quick-rule covered-by-a-named-always-on-rule archival-only' \
  'totally-bogus' 'archival-only extra-garbage' ''; do
  printf '%s\n' '## lesson: real lesson' "- classification: $bad_class" \
    '- covered_by: irrelevant' '- quick_rule: irrelevant' >"$parser_manifest"
  class_finding='has an invalid classification'
  [[ -n "$bad_class" ]] || class_finding='has no classification'
  expect_result 0 "$class_finding" "$parser_manifest"
  reject_output 'not classified in the manifest' 'sets covered_by' 'sets quick_rule' 'check passed'
  expect_occurrences 1 "$class_finding"
  expect_silent "$parser_manifest"
  for quiet_flag in '' '--quiet'; do
    mode_flags=(--strict)
    [[ -z "$quiet_flag" ]] || mode_flags+=("$quiet_flag")
    expect_result 1 "$class_finding
archived lesson is not classified in the manifest" "$parser_manifest" "${mode_flags[@]}"
    expect_occurrences 1 "$class_finding"
    expect_occurrences 1 'archived lesson is not classified in the manifest'
    reject_output 'sets covered_by' 'sets quick_rule' 'check passed'
  done
done
# All three exact values still pass, including surrounding whitespace.
printf '%s\n' 'a live rule' >"$d/agent-vault/lessons.md"
for good_class in retained-as-quick-rule covered-by-a-named-always-on-rule archival-only; do
  printf '%s\n' '## lesson: real lesson' "- classification:   $good_class   " >"$parser_manifest"
  if [[ "$good_class" == covered-by-a-named-always-on-rule ]]; then
    printf '%s\n' '- covered_by: a live rule' >>"$parser_manifest"
  fi
  expect_result 0 '(1 classified)' "$parser_manifest" --strict
done
# Independent valid records still receive their own class-specific checks.
printf '%s\n' '## lesson: real lesson' '- classification: totally-bogus' \
  '## lesson: another lesson' '- classification: covered-by-a-named-always-on-rule' >"$parser_manifest"
printf '%s\n' '### another lesson' >>"$parser_archive"
expect_result 1 'invalid classification
names no "covered_by" rule
archived lesson is not classified in the manifest: "real lesson"' "$parser_manifest" --strict
expect_occurrences 1 'archived lesson is not classified in the manifest'

# --- 22. Only the heading supplies identity; field names cannot hide duplicates ---
printf '%s\n' '### real lesson' >"$parser_archive"
printf '%s\n' '## lesson: real lesson' '- classification: archival-only' \
  '- key: hijacked' '- record: hijacked' '- heading: hijacked' '- COUNT: 99' >"$parser_manifest"
expect_result 0 '(1 classified)' "$parser_manifest" --strict
printf '%s\n' '## lesson: real lesson' '- classification: archival-only' \
  '- key: another hijacked key' >>"$parser_manifest"
expect_finding_modes 'duplicate lesson key: "real lesson"' "$parser_manifest"
reject_output 'hijacked' 'not present in the archive' 'not classified in the manifest'
expect_occurrences 1 'duplicate lesson key'

# --- 23. H1/H2 sections end records; H3+ stays in the active record ---
for boundary in '# Section' '## Section' '#' '##' $'#\tSection' $'##\t'; do
  for line_ending in lf crlf; do
    printf '%s\n' '## lesson: real lesson' '- classification: archival-only' \
      "$boundary" '- classification: invalid-after-section' '- key: hijacked' \
      '## lesson: another lesson' '### Details' '- classification: archival-only' >"$parser_manifest"
    printf '%s\n' '### real lesson' '### another lesson' >"$parser_archive"
    if [[ "$line_ending" == crlf ]]; then
      awk '{ printf "%s\r\n", $0 }' "$parser_manifest" >"$d/converted.md"
      mv "$d/converted.md" "$parser_manifest"
    fi
    expect_result 0 '(2 classified)' "$parser_manifest" --strict
  done
done

# --- 24. Repeated --archive validates every nonempty value, selects the last ---
printf '%s\n' '## lesson: real lesson' '- classification: archival-only' >"$parser_manifest"
printf '%s\n' '### real lesson' >"$parser_archive"
printf '%s\n' '### different lesson' >"$d/other archive.md"
for mode in advisory quiet strict strict-quiet; do
  mode_flags=()
  case "$mode" in
    quiet) mode_flags=(--quiet) ;;
    strict) mode_flags=(--strict) ;;
    strict-quiet) mode_flags=(--strict --quiet) ;;
  esac
  expect_result 2 "archive file not found: $d/missing.md" "$parser_manifest" "${mode_flags[@]}" \
    --archive "$d/missing.md" --archive "$parser_archive"
  expect_result 2 "archive file not found: $d/missing.md" "$parser_manifest" "${mode_flags[@]}" \
    --archive "$parser_archive" --archive "$d/missing.md"
  expect_result 2 "archive file not found: $d/missing.md" "$parser_manifest" "${mode_flags[@]}" \
    --archive "$d/missing.md" --archive ''
done
expect_result 0 '(1 classified)' "$parser_manifest" --strict --archive "$d/other archive.md" --archive "$parser_archive"
expect_result 1 'not present in the archive: "real lesson"' "$parser_manifest" --strict \
  --archive "$parser_archive" --archive "$d/other archive.md"
expect_result 0 '(1 classified)' "$parser_manifest" --strict --archive '' --archive "$parser_archive"
expect_result 0 '(1 classified)' "$parser_manifest" --strict --archive "$d/other archive.md" --archive ''
expect_result 0 '(1 classified)' "$parser_manifest" --strict --archive '' --archive ''

# --- 25. Parser errors cannot become empty/partial success, even as root ---
# Intercept awk only for a marked input. Run its real parser on a prefix for the
# partial-output case, then fail. Other awk calls retain normal behavior. This
# exercises status propagation rather than relying on chmod, which root bypasses.
mkdir -p "$d/bin"
real_awk="$(command -v awk)"
cat >"$d/bin/awk" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
last_arg="${args[${#args[@]} - 1]}"
# Accept either file arguments or redirected stdin, so this fixture also
# exercises the historical parser when demonstrating the regression.
if [[ -f "$last_arg" ]]; then
  cp "$last_arg" "$PARSER_CAPTURE"
  unset 'args[${#args[@]}-1]'
else
  cat >"$PARSER_CAPTURE"
fi
if grep -Fq '# INJECT PARSER FAILURE' "$PARSER_CAPTURE"; then
  if [[ "$PARSER_FAILURE_OUTPUT" == partial ]]; then
    head -n 3 "$PARSER_CAPTURE" | "$REAL_AWK" "${args[@]}"
  fi
  echo 'injected parser read failure' >&2
  exit 74
fi
exec "$REAL_AWK" "${args[@]}" <"$PARSER_CAPTURE"
EOF
chmod +x "$d/bin/awk"
for input_kind in manifest archive; do
  for failure_output in empty partial; do
    printf '%s\n' '# Manifest' '## lesson: real lesson' '- classification: archival-only' \
      '## lesson: later lesson' '- classification: archival-only' >"$parser_manifest"
    printf '%s\n' '# Archive' '### real lesson' 'write-up' '### later lesson' >"$parser_archive"
    source_path="$parser_manifest"
    [[ "$input_kind" == manifest ]] || source_path="$parser_archive"
    printf '%s\n' '# INJECT PARSER FAILURE' >>"$source_path"
    cp "$parser_manifest" "$d/manifest-before.md"
    cp "$parser_archive" "$d/archive-before.md"
    for mode in advisory quiet strict strict-quiet; do
      mode_flags=()
      case "$mode" in
        quiet) mode_flags=(--quiet) ;;
        strict) mode_flags=(--strict) ;;
        strict-quiet) mode_flags=(--strict --quiet) ;;
      esac
      PATH="$d/bin:$PATH" REAL_AWK="$real_awk" PARSER_CAPTURE="$d/awk-input" PARSER_FAILURE_OUTPUT="$failure_output" \
        expect_result 2 "could not parse $input_kind: $source_path
injected parser read failure" "$parser_manifest" "${mode_flags[@]}"
      reject_output 'check passed' 'not present in the archive' 'not classified in the manifest'
    done
    cmp "$d/manifest-before.md" "$parser_manifest"
    cmp "$d/archive-before.md" "$parser_archive"
  done
done

# --- 26. Indented examples cannot supply fields to a live record ---
printf '%s\n' '### real lesson' >"$parser_archive"
for indent in '    ' '        ' $'\t'; do
  for example_kind in bare fenced; do
    for example_field in '- classification: archival-only' '- covered_by: a live rule'; do
      printf '%s\n' '## lesson: real lesson' '- classification: covered-by-a-named-always-on-rule' '' >"$parser_manifest"
      [[ "$example_kind" != fenced ]] || printf '%s%s\n' "$indent" '```md' >>"$parser_manifest"
      printf '%s%s\n' "$indent" "$example_field" >>"$parser_manifest"
      [[ "$example_kind" != fenced ]] || printf '%s%s\n' "$indent" '```' >>"$parser_manifest"
      expect_finding_modes 'names no "covered_by" rule' "$parser_manifest"
    done
  done
done
printf '%s\n' '## lesson: real lesson' '- classification: retained-as-quick-rule' '' \
  '    - quick_rule: an inert example' >"$parser_manifest"
expect_result 0 '(1 classified)' "$parser_manifest" --strict
# Zero through three leading spaces still support real field bullets.
for indent in '' ' ' '  ' '   '; do
  printf '%s\n' '## lesson: real lesson' >"$parser_manifest"
  printf '%s%s\n' "$indent" '- classification: covered-by-a-named-always-on-rule' \
    "$indent" '- covered_by: a live rule' >>"$parser_manifest"
  expect_result 0 '(1 classified)' "$parser_manifest" --strict
done

# --- 27. Only the input being checked for absence must be complete ---
printf '%s\n' '# Empty manifest' >"$parser_manifest"
printf '%s\n' '### visible lesson' '```' '### hidden example' >"$parser_archive"
expect_result 0 'unterminated fence in archive' "$parser_manifest"
reject_output 'not classified in the manifest' 'check passed'
expect_silent "$parser_manifest"
for quiet_flag in '' '--quiet'; do
  mode_flags=(--strict)
  [[ -z "$quiet_flag" ]] || mode_flags+=("$quiet_flag")
  expect_result 1 'unterminated fence in archive
archived lesson is not classified in the manifest: "visible lesson"' "$parser_manifest" "${mode_flags[@]}"
  reject_output 'hidden example' 'check passed'
done
printf '%s\n' '# Empty archive' >"$parser_archive"
printf '%s\n' '## lesson: visible lesson' '- classification: archival-only' '~~~' \
  '## lesson: hidden example' >"$parser_manifest"
expect_finding_modes 'unterminated fence in manifest
manifest classifies a lesson not present in the archive: "visible lesson"' "$parser_manifest"
reject_output 'hidden example'

# --- 28. Archive ATX headings accept up to three leading spaces ---
for indent in '' ' ' '  ' '   '; do
  for ending in lf crlf; do
    printf '%s\n' '# Empty manifest' >"$parser_manifest"
    printf '%s%s' "$indent" '### real lesson' >"$parser_archive"
    [[ "$ending" != crlf ]] || printf '\r\n' >>"$parser_archive"
    expect_result 1 'archived lesson is not classified in the manifest: "real lesson"' "$parser_manifest" --strict
    reject_output 'check passed'
    printf '%s\n' '## lesson: real lesson' '- classification: archival-only' >"$parser_manifest"
    expect_result 0 '(1 classified)' "$parser_manifest" --strict
  done
done
printf '%s\n' '### real lesson' '    ### indented code' $'\t### tab-indented code' >"$parser_archive"
expect_result 0 '(1 classified)' "$parser_manifest" --strict

# --- 29. Repeated recognized fields cannot silently replace earlier values ---
printf '%s\n' '### real lesson' >"$parser_archive"
for values in 'totally-bogus|archival-only' 'archival-only|totally-bogus' 'archival-only|archival-only' '|archival-only'; do
  IFS='|' read -r first_class second_class <<<"$values"
  printf '%s\n' '## lesson: real lesson' "- classification: $first_class" \
    "- classification: $second_class" '- classification: archival-only' >"$parser_manifest"
  expect_finding_modes 'repeats "classification" field' "$parser_manifest"
  expect_occurrences 1 'repeats "classification" field'
  expect_occurrences 1 'archived lesson is not classified in the manifest'
  case "$first_class" in
    totally-bogus) expect_occurrences 1 'has an invalid classification "totally-bogus"' ;;
    '') expect_occurrences 1 'has no classification' ;;
    *) reject_output 'has an invalid classification' ;;
  esac
done
for reference_field in covered_by quick_rule; do
  reference_class=covered-by-a-named-always-on-rule
  [[ "$reference_field" != quick_rule ]] || reference_class=retained-as-quick-rule
  printf '%s\n' '## lesson: real lesson' "- classification: $reference_class" \
    "- $reference_field: a live rule" "- $reference_field: a live rule" \
    "- $reference_field: a live rule" >"$parser_manifest"
  expect_finding_modes "repeats \"$reference_field\" field" "$parser_manifest"
  expect_occurrences 1 "repeats \"$reference_field\" field"
done
# Repeated unknown extension fields remain ignored.
printf '%s\n' '## lesson: real lesson' '- classification: archival-only' \
  '- key: ignored' '- key: also ignored' '- note: one' '- note: two' >"$parser_manifest"
expect_result 0 '(1 classified)' "$parser_manifest" --strict

# --- 30. Each distinct missing lesson has one absence finding ---
printf '%s\n' '# Empty archive' >"$parser_archive"
printf '%s\n' '## lesson: missing lesson' '- classification: archival-only' \
  '## lesson: missing lesson' '- classification: archival-only' >"$parser_manifest"
expect_finding_modes 'duplicate lesson key: "missing lesson"
manifest classifies a lesson not present in the archive: "missing lesson"' "$parser_manifest"
expect_occurrences 1 'duplicate lesson key'
expect_occurrences 1 'not present in the archive'
expect_result 0 '2 warning(s)' "$parser_manifest"

# Comment fixtures exercise the mode contract and preserve all three inputs.
# Empty finding text means a clean run in that mode.
expect_comment_case() {
  local advisory_findings="$1" strict_findings="$2" clean_text="${3:-(1 classified)}"
  local mode required expected_rc finding
  local -a mode_flags
  cp "$parser_manifest" "$d/manifest-before.md"
  cp "$parser_archive" "$d/archive-before.md"
  cp "$d/agent-vault/lessons.md" "$d/rules-before.md"
  for mode in advisory quiet strict strict-quiet; do
    mode_flags=()
    required="$advisory_findings"
    expected_rc=0
    case "$mode" in
      quiet) mode_flags=(--quiet) ;;
      strict | strict-quiet)
        mode_flags=(--strict)
        [[ "$mode" != strict-quiet ]] || mode_flags+=(--quiet)
        required="$strict_findings"
        [[ -z "$required" ]] || expected_rc=1
        ;;
    esac
    expect_result "$expected_rc" "" "$parser_manifest" "${mode_flags[@]}"
    if [[ "$mode" == quiet || ("$mode" == strict-quiet && -z "$required") ]]; then
      [[ -z "$result_output" ]] || {
        echo "FAIL: successful quiet comment check must be silent" >&2
        exit 1
      }
    elif [[ -n "$required" ]]; then
      while IFS= read -r finding; do
        [[ "$result_output" == *"$finding"* ]] || {
          echo "FAIL: comment check missing '$finding'" >&2
          printf '%s\n' "$result_output" >&2
          exit 1
        }
      done <<<"$required"
      reject_output 'check passed'
    else
      [[ "$result_output" == *"check passed:"* && "$result_output" == *"$clean_text"* ]] || {
        echo "FAIL: expected clean comment check with $clean_text" >&2
        printf '%s\n' "$result_output" >&2
        exit 1
      }
    fi
  done
  cmp "$d/manifest-before.md" "$parser_manifest"
  cmp "$d/archive-before.md" "$parser_archive"
  cmp "$d/rules-before.md" "$d/agent-vault/lessons.md"
}

comment_line_endings() {
  local ending="$1" source_path
  shift
  for source_path in "$@"; do
    case "$ending" in
      crlf) awk '{ printf "%s\r\n", $0 }' "$source_path" >"$d/converted.md" ;;
      no-final-newline) awk 'NR > 1 { printf "\n" } { printf "%s", $0 }' "$source_path" >"$d/converted.md" ;;
      *) continue ;;
    esac
    mv "$d/converted.md" "$source_path"
  done
}

# --- 31. Commented records cannot classify; commented headings need no record ---
for indent in '' ' ' '  ' '   '; do
  for ending in lf crlf no-final-newline; do
    printf '%s\n' '## lesson: real lesson' '- classification: archival-only' \
      "$indent<!--" '## lesson: hidden lesson' '- classification: archival-only' \
      "$indent-->" >"$parser_manifest"
    printf '%s\n' '### real lesson' '### hidden lesson' >"$parser_archive"
    comment_line_endings "$ending" "$parser_manifest" "$parser_archive"
    expect_comment_case '' 'archived lesson is not classified in the manifest: "hidden lesson"'
    expect_occurrences 1 'not classified in the manifest'
    reject_output 'not present in the archive'

    # With the heading commented too, exactly the visible lesson remains.
    printf '%s\n' '### real lesson' "$indent<!--" '### hidden lesson' \
      "$indent-->" >"$parser_archive"
    comment_line_endings "$ending" "$parser_archive"
    expect_comment_case '' ''
  done
done

# --- 32. Comments cannot create/end records or supply/replace any field ---
printf '%s\n' '### real lesson' >"$parser_archive"
printf '%s\n' '## lesson: real lesson' '- classification: covered-by-a-named-always-on-rule' \
  '<!--' '- classification: invalid-hidden' '- covered_by: hidden rule' \
  '- quick_rule: hidden rule' '- key: hijacked' '#' '##' \
  '## lesson: real lesson' '- classification: archival-only' '-->' \
  '- covered_by: a live rule' >"$parser_manifest"
expect_comment_case '' ''
for reference_field in classification covered_by quick_rule; do
  reference_class=covered-by-a-named-always-on-rule
  [[ "$reference_field" != quick_rule ]] || reference_class=retained-as-quick-rule
  printf '%s\n' '## lesson: real lesson' >"$parser_manifest"
  [[ "$reference_field" == classification ]] ||
    printf '%s\n' "- classification: $reference_class" >>"$parser_manifest"
  printf '%s\n' '<!--' "- $reference_field: archival-only" '-->' >>"$parser_manifest"
  case "$reference_field" in
    classification)
      expect_comment_case 'has no classification' 'has no classification
archived lesson is not classified in the manifest: "real lesson"'
      ;;
    covered_by) expect_comment_case 'names no "covered_by" rule' 'names no "covered_by" rule' ;;
    quick_rule) expect_comment_case '' '' ;;
  esac
done

# --- 33. Comments and fences cannot change each other's state ---
for fence_case in "${fence_cases[@]}"; do
  IFS='|' read -r opener false_closer closer <<<"$fence_case"
  printf '%s\n' '## lesson: real lesson' '<!--' "$opener" "$false_closer" \
    '- classification: hidden' '## lesson: ghost lesson' '-->' \
    '- classification: archival-only' "$opener" '<!--' "$false_closer" '-->' \
    '<!--' '## lesson: ghost lesson' "$closer" \
    '## lesson: later lesson' '- classification: archival-only' >"$parser_manifest"
  printf '%s\n' '### real lesson' '<!--' "$opener" "$false_closer" \
    '### ghost lesson' '-->' "$opener" '<!--' "$false_closer" '-->' \
    '<!--' '### ghost lesson' "$closer" '### later lesson' >"$parser_archive"
  expect_comment_case '' '' '(2 classified)'
done

# --- 34. Consume the closing physical line, including any second comment ---
# Exercise single-line and multiline blocks. Even an unclosed second opener
# on the closing line is just raw suffix text, not another parser state.
for opening_line in '<!-- first -->' '<!-- first'; do
  for suffix in '## lesson: ghost lesson' '### ghost lesson' '#' '##' \
    '- classification: invalid-suffix' '- covered_by: hidden rule' \
    '- quick_rule: hidden rule' '```' '~~~' '<!-- second -->' '<!-- second'; do
    printf '%s\n' '## lesson: real lesson' '- classification: archival-only' >"$parser_manifest"
    printf '%s\n' '### real lesson' >"$parser_archive"
    for source_path in "$parser_manifest" "$parser_archive"; do
      if [[ "$opening_line" == '<!-- first' ]]; then
        printf '%s\n' "$opening_line" "--> $suffix" >>"$source_path"
      else
        printf '%s\n' "$opening_line $suffix" >>"$source_path"
      fi
    done
    expect_comment_case '' ''
  done
done
# Empty, nested-looking, and overlapping delimiters still use the first -->.
for comment in '<!---->' '<!-->' '<!--->' '<!-- <!-- nested -->'; do
  printf '%s\n' "$comment" '## lesson: real lesson' '- classification: archival-only' >"$parser_manifest"
  printf '%s\n' "$comment" '### real lesson' >"$parser_archive"
  expect_comment_case '' ''
done

# --- 35. Only block openers are interpreted; inline markers stay literal ---
for non_opener in '    <!--' '        <!--' $'\t<!--' 'text <!--' '\<!--' \
  '`<!--`' '``<!--``' '<! --'; do
  printf '%s\n' "$non_opener" '## lesson: real lesson' '- classification: archival-only' >"$parser_manifest"
  printf '%s\n' "$non_opener" '### real lesson' >"$parser_archive"
  expect_comment_case '' ''
done
printf '%s\n' '## lesson: real lesson <!-- same note -->' '- classification: archival-only' >"$parser_manifest"
printf '%s\n' '### real lesson <!-- same note -->' >"$parser_archive"
expect_comment_case '' ''
printf '%s\n' '### real lesson' >"$parser_archive"
expect_comment_case 'not present in the archive' 'not present in the archive
archived lesson is not classified in the manifest: "real lesson"'
printf '%s\n' '## lesson: real lesson' '- classification: archival-only <!-- note -->' >"$parser_manifest"
expect_comment_case 'has an invalid classification' 'has an invalid classification
archived lesson is not classified in the manifest: "real lesson"'

# --- 36. Unclosed comments are findings and incomplete inputs in every mode ---
for input_kind in manifest archive; do
  for prefix in empty populated; do
    for ending in lf crlf no-final-newline; do
      for opener in '<!--' '<!--lookalike'; do
        printf '%s\n' '# Manifest' >"$parser_manifest"
        printf '%s\n' '# Archive' >"$parser_archive"
        if [[ "$prefix" == populated ]]; then
          printf '%s\n' '## lesson: real lesson' '- classification: archival-only' >>"$parser_manifest"
          printf '%s\n' '### real lesson' >>"$parser_archive"
        fi
        source_path="$parser_manifest"
        if [[ "$input_kind" == archive ]]; then
          source_path="$parser_archive"
          printf '%s\n' '## lesson: hidden lesson' '- classification: archival-only' >>"$parser_manifest"
        else
          printf '%s\n' '### hidden lesson' >>"$parser_archive"
        fi
        opening_line="$(awk 'END { print NR + 1 }' "$source_path")"
        printf '%s\n' "$opener" '```' '### hidden lesson' \
          '## lesson: hidden lesson' '- classification: archival-only' >>"$source_path"
        comment_line_endings "$ending" "$parser_manifest" "$parser_archive"
        required="unterminated HTML comment in $input_kind: $source_path:$opening_line"
        expect_comment_case "$required" "$required"
        expect_occurrences 1 'unterminated HTML comment'
        reject_output 'unterminated fence' 'not present in the archive' 'not classified in the manifest'
      done
    done
  done
done

# --- 37. Incomplete comments retain independent validation and absence checks ---
printf '%s\n' '# Empty manifest' >"$parser_manifest"
printf '%s\n' '### visible lesson' '<!--' '### hidden lesson' >"$parser_archive"
expect_comment_case 'unterminated HTML comment in archive' 'unterminated HTML comment in archive
archived lesson is not classified in the manifest: "visible lesson"'
reject_output 'hidden lesson'
printf '%s\n' '# Empty archive' >"$parser_archive"
printf '%s\n' '## lesson: visible lesson' '- classification: archival-only' '<!--' \
  '## lesson: hidden lesson' >"$parser_manifest"
required='unterminated HTML comment in manifest
manifest classifies a lesson not present in the archive: "visible lesson"'
expect_comment_case "$required" "$required"
reject_output 'hidden lesson'
# Local record errors survive incomplete parses of both inputs.
printf '%s\n' '## lesson: visible lesson' '- classification: bogus' '<!--' >"$parser_manifest"
printf '%s\n' '### other lesson' '<!--' >"$parser_archive"
required='unterminated HTML comment in manifest
unterminated HTML comment in archive
has an invalid classification "bogus"'
expect_comment_case "$required" "$required"
reject_output 'not present in the archive' 'not classified in the manifest'
expect_occurrences 2 'unterminated HTML comment'
# An unclosed fence in one file and comment in the other report independently.
printf '%s\n' '~~~' >"$parser_archive"
required='unterminated HTML comment in manifest
unterminated fence in archive
has an invalid classification "bogus"'
expect_comment_case "$required" "$required"
reject_output 'not present in the archive' 'not classified in the manifest'

# --- 38. Comment scanning preserves empty/partial producer failure semantics ---
for input_kind in manifest archive; do
  for failure_output in empty partial; do
    printf '%s\n' '# Manifest' '## lesson: real lesson' '- classification: archival-only' \
      '<!-- -->' '<!--' >"$parser_manifest"
    printf '%s\n' '# Archive' '### real lesson' 'write-up' '<!-- -->' '<!--' >"$parser_archive"
    source_path="$parser_manifest"
    [[ "$input_kind" == manifest ]] || source_path="$parser_archive"
    printf '%s\n' '# INJECT PARSER FAILURE' >>"$source_path"
    cp "$parser_manifest" "$d/manifest-before.md"
    cp "$parser_archive" "$d/archive-before.md"
    for mode in advisory quiet strict strict-quiet; do
      mode_flags=()
      case "$mode" in
        quiet) mode_flags=(--quiet) ;;
        strict) mode_flags=(--strict) ;;
        strict-quiet) mode_flags=(--strict --quiet) ;;
      esac
      PATH="$d/bin:$PATH" REAL_AWK="$real_awk" PARSER_CAPTURE="$d/awk-input" PARSER_FAILURE_OUTPUT="$failure_output" \
        expect_result 2 "could not parse $input_kind: $source_path
injected parser read failure" "$parser_manifest" "${mode_flags[@]}"
      reject_output 'check passed' 'not present in the archive' 'not classified in the manifest'
    done
    cmp "$d/manifest-before.md" "$parser_manifest"
    cmp "$d/archive-before.md" "$parser_archive"
  done
done

echo "lessons-archive checker regression checks passed."

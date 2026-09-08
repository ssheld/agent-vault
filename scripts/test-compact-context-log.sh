#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
compactor="$repo_root/scaffold/root/scripts/compact-context-log.sh"
checker="$repo_root/scaffold/root/scripts/check-context-log-rollover.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-compact-test.XXXXXX")"
tmp_root="$(cd "$tmp_root" && pwd -P)"

cleanup() { rm -rf "$tmp_root"; }
trap cleanup EXIT

# Share one clock with child compactors, including those behind fault-injection PATHs.
# shellcheck source=scripts/lib/fixed-test-clock.sh
source "$repo_root/scripts/lib/fixed-test-clock.sh"
clock_bin="$tmp_root/clock-bin"
install_fixed_test_clock "$clock_bin"

pass=0
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Run the compactor; capture combined output + rc without tripping set -e.
run_compact() {
  set +e
  COMPACT_OUT="$("$compactor" "$@" 2>&1)"
  COMPACT_RC=$?
  set -e
}

assert_rc() {
  local want="$1" got="$2" ctx="$3"
  [[ "$got" -eq "$want" ]] || fail "$ctx: expected rc $want, got $got. Output:\n$COMPACT_OUT"
  pass=$((pass + 1))
}

assert_contains() {
  local hay="$1" needle="$2" ctx="$3"
  [[ "$hay" == *"$needle"* ]] || fail "$ctx: missing '$needle' in:\n$hay"
  pass=$((pass + 1))
}

assert_file_contains() {
  local file="$1" needle="$2" ctx="$3"
  [[ -f "$file" ]] || fail "$ctx: file missing: $file"
  grep -Fq -- "$needle" "$file" || fail "$ctx: '$needle' not in $file"
  pass=$((pass + 1))
}

assert_not_exists() {
  [[ ! -e "$1" ]] || fail "$2: expected $1 to not exist"
  pass=$((pass + 1))
}

# Count canonical entry headings in a file (the same strict shape the compactor
# and checker split on; nested date-prefixed sub-headings must not count).
count_entries() {
  awk '
    {
      l = $0; sub(/\r$/, "", l); candidate = l
      sub(/^ ? ? ?/, "", candidate)
      match(candidate, /^(`+|~+)/); run = RLENGTH
      m = substr(candidate, 1, 1); rest = substr(candidate, run + 1)
      if (marker != "") {
        if (m == marker && run >= length_open && rest ~ /^[ \t]*$/) marker = ""
        next
      }
      if (run >= 3 && (m == "~" || !index(rest, "`"))) {
        marker = m; length_open = run; next
      }
      if (l ~ /^### [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9] local - /) c++ }
    END { print c + 0 }
  ' "$1"
}

# Build a healthy live log with 5 entries (newest first), snapshot, usage.
make_log() {
  cat >"$1" <<'EOF'
# Context Log

## Usage Rules
- Newest entry at top.

## Current Snapshot
- Active branch: `main`
- Last updated: 2026-05-30

## Entries

### 2026-05-30 09:00 local - claude - rollover session entry
#### State
- Bookkeeping for the rollover.

### 2026-05-29 11:00 local - claude - feature work
- Implemented X.

### 2026-05-28 10:00 local - codex - older work
- Body.

### 2026-05-27 10:00 local - gemini - older still
- Body.

### 2026-05-26 09:00 local - bootstrap - initial project setup
- Body.
EOF
}

# Formatted default anchors must validate without changing the archived bytes.
d="$tmp_root/formatted-topics"
mkdir -p "$d"
make_log "$d/log.md"
sed 's/older work/fix `foo` in **setup**/' "$d/log.md" >"$d/log.next"
mv "$d/log.next" "$d/log.md"
cp "$d/log.md" "$d/before"
run_compact "$d/log.md" --keep 2 --archive "$d/history/archive.md" --manifest "$d/metadata/manifest.md" \
  --rollover-id formatted --require-top-entry 'rollover session' --dry-run
assert_rc 0 "$COMPACT_RC" 'formatted default anchors preview'
cmp -s "$d/log.md" "$d/before" || fail 'formatted preview changed the log'
assert_not_exists "$d/history" 'formatted preview creates no output parents'
run_compact "$d/log.md" --keep 2 --archive "$d/history/archive.md" --manifest "$d/metadata/manifest.md" \
  --rollover-id formatted --require-top-entry 'rollover session'
assert_rc 0 "$COMPACT_RC" 'formatted default anchors'
assert_file_contains "$d/history/archive.md" 'fix `foo` in **setup**' 'archive retains formatting'
assert_file_contains "$d/metadata/manifest.md" '- archive_path_base: manifest' 'new record declares path base'
assert_file_contains "$d/metadata/manifest.md" '- archive_file: ../history/archive.md' 'record is relative to final manifest'
"$checker" "$d/log.md" --manifest "$d/metadata/manifest.md" --quiet
# Resolution must not depend on the invocation directory or the original root.
mv "$d" "$tmp_root/relocated project"
d="$tmp_root/relocated project"
(cd / && "$checker" "$d/log.md" --manifest "$d/metadata/manifest.md" --quiet)

# Legacy-format records remain untouched on a no-op; a real rollover marks only
# the new record, without rewriting retained historical records.
d="$tmp_root/legacy-path-record"
mkdir -p "$d"
make_log "$d/log.md"
run_compact "$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md" \
  --rollover-id legacy --require-top-entry 'rollover session'
assert_rc 0 "$COMPACT_RC" 'legacy record setup'
sed -e '/^- archive_path_base:/d' -e 's|^- archive_file: .*|- archive_file: agent-vault/context/archive/archive.md|' \
  "$d/manifest.md" >"$d/manifest.next"
mv "$d/manifest.next" "$d/manifest.md"
cp "$d/manifest.md" "$d/legacy-manifest"
run_compact "$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md"
assert_rc 0 "$COMPACT_RC" 'unmarked record no-op'
cmp -s "$d/manifest.md" "$d/legacy-manifest" || fail 'no-op migrated a legacy record'
"$checker" "$d/log.md" --manifest "$d/manifest.md" --quiet 2>"$d/warning"
assert_file_contains "$d/warning" 'legacy archive path' 'legacy no-op remains checkable with warning'
run_compact "$d/log.md" --keep 1 --archive "$d/archive.md" --manifest "$d/manifest.md" \
  --rollover-id migrated --require-top-entry 'rollover session'
assert_rc 0 "$COMPACT_RC" 'rollover on legacy record'
sed -n '/^## rollover: legacy$/,$p' "$d/legacy-manifest" >"$d/legacy-record"
sed -n '/^## rollover: legacy$/,$p' "$d/manifest.md" >"$d/retained-record"
cmp -s "$d/legacy-record" "$d/retained-record" || fail 'rollover rewrote legacy history'
[[ "$(grep -c '^- archive_path_base: manifest$' "$d/manifest.md")" == 1 ]] || fail 'only newest record should be marked'
"$checker" "$d/log.md" --manifest "$d/manifest.md" --quiet 2>"$d/warning"
[[ ! -s "$d/warning" ]] || fail 'marked newest record emitted legacy warning'

# Bound both selection and counting, then append the untouched suffix after
# pointer rewriting. Exercise LF/CRLF and an unterminated final suffix line.
for ending in lf crlf unterminated; do
  d="$tmp_root/suffix-$ending"
  mkdir -p "$d"
  make_log "$d/log.md"
  cat >"$d/suffix" <<'EOF'
## Appendix
- Keep this non-entry section.
### 2026-05-01 09:00 local - example - historical sample
- This is not a live entry.
# Further Notes
~~~md
## Entries
### 2026-05-02 09:00 local - example - fenced sample
## Current Snapshot
- Context-log rollover: preserve this literal example.
~~~
EOF
  case "$ending" in
    crlf)
      sed 's/$/\r/' "$d/log.md" >"$d/log.next" && mv "$d/log.next" "$d/log.md"
      sed 's/$/\r/' "$d/suffix" >"$d/suffix.next" && mv "$d/suffix.next" "$d/suffix"
      ;;
    unterminated) printf '%s' '- Final line without newline.' >>"$d/suffix" ;;
  esac
  cat "$d/suffix" >>"$d/log.md"
  cp "$d/log.md" "$d/before"
  for mode in noop preview write; do
    suffix_args=("$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md" --rollover-id suffix --require-top-entry 'rollover session' --quiet)
    [[ "$mode" != noop ]] || suffix_args+=(--keep 5)
    [[ "$mode" != preview ]] || suffix_args+=(--dry-run)
    run_compact "${suffix_args[@]}"
    assert_rc 0 "$COMPACT_RC" "$ending $mode succeeds"
    assert_contains "$COMPACT_OUT" '1 canonical entry heading(s) outside the Entries section' "$ending $mode warns even in quiet mode"
    assert_contains "$COMPACT_OUT" 'line(s)' "$ending $mode locates excluded headings"
    if [[ "$mode" != write ]]; then
      cmp -s "$d/log.md" "$d/before" || fail 'preview/no-op changed suffix'
      assert_not_exists "$d/archive.md" 'preview/no-op created archive'
    fi
  done
  suffix_line="$(awk '/^## Appendix/ { print NR; exit }' "$d/log.md")"
  tail -n "+$suffix_line" "$d/log.md" >"$d/actual-suffix"
  cmp -s "$d/suffix" "$d/actual-suffix" || fail "$ending suffix bytes changed"
  assert_file_contains "$d/manifest.md" '- archived: 3' 'suffix headings do not inflate counts'
  if grep -Fq '## Appendix' "$d/archive.md"; then fail 'appendix moved to archive'; fi
  "$checker" "$d/log.md" --manifest "$d/manifest.md" --quiet
done

# A mid-log section used to make later entries silently invisible after bounding.
d="$tmp_root/mid-log-notes"
mkdir -p "$d"
make_log "$d/log.md"
awk '/^### 2026-05-28/ { print "## Notes"; print "" } { print }' "$d/log.md" >"$d/log.next"
mv "$d/log.next" "$d/log.md"
cp "$d/log.md" "$d/before"
run_compact "$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md" --quiet
assert_rc 0 "$COMPACT_RC" 'mid-log notes is a bounded no-op'
assert_contains "$COMPACT_OUT" '3 canonical entry heading(s) outside the Entries section' 'mid-log notes warning'
cmp -s "$d/log.md" "$d/before" || fail 'mid-log no-op rewrote excluded entries'
assert_not_exists "$d/archive.md" 'mid-log no-op archive'

# Fenced H1/H2 examples inside kept AND moved entries are not terminators.
# The real H1 terminator and its canonical-looking sample survive repeated runs.
d="$tmp_root/fenced-sections"
mkdir -p "$d"
make_log "$d/base"
awk '
  { print }
  /^### 2026-05-29/ { print "```md\n# Fenced title\n## Fenced section\n```" }
  /^### 2026-05-28/ { print "~~~md\n## Fenced section\n# Fenced title\n~~~" }
' "$d/base" >"$d/log.md"
printf '# Appendix\n' >"$d/suffix"
# The suffix contains the exact oldest archived entry; #138 overlap detection
# must stop at the same live Entries boundary, even on a later no-op.
sed -n '/^### 2026-05-26/,$p' "$d/base" >>"$d/suffix"
cat "$d/suffix" >>"$d/log.md"
for keep_window in 2 2 1; do
  run_compact "$d/log.md" --keep "$keep_window" --archive "$d/archive.md" --manifest "$d/manifest.md" \
    --rollover-id "fenced-$keep_window" --require-top-entry 'rollover session'
  assert_rc 0 "$COMPACT_RC" 'fenced sections and excluded overlap allow rollover/no-op'
  assert_contains "$COMPACT_OUT" '1 canonical entry heading(s) outside the Entries section' 'only real suffix entry excluded'
  suffix_line="$(awk '/^# Appendix$/ { print NR; exit }' "$d/log.md")"
  tail -n "+$suffix_line" "$d/log.md" >"$d/actual-suffix"
  cmp -s "$d/suffix" "$d/actual-suffix" || fail 'repeated rollover rewrote H1 suffix'
  "$checker" "$d/log.md" --manifest "$d/manifest.md" --quiet
done
assert_file_contains "$d/archive.md" '## Fenced section' 'fenced archive body preserved'
[[ "$(count_entries "$d/archive.md")" == 4 ]] || fail 'repeated bounded rollover lost or duplicated entries'

# Even empty H1/H2 headings terminate Entries and its overlap scan.
for empty_heading in '#' '##'; do
  d="$tmp_root/empty-heading-$empty_heading"
  mkdir -p "$d"
  make_log "$d/log.md"
  printf '%s\n' "$empty_heading" >"$d/suffix"
  sed -n '/^### 2026-05-26/,$p' "$d/log.md" >>"$d/suffix"
  cat "$d/suffix" >>"$d/log.md"
  for mode in write noop; do
    run_compact "$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md" \
      --rollover-id empty-heading --require-top-entry 'rollover session'
    assert_rc 0 "$COMPACT_RC" "$mode with empty H1/H2 heading"
    assert_contains "$COMPACT_OUT" '1 canonical entry heading(s) outside the Entries section' 'empty section boundary warning'
    suffix_line="$(awk -v heading="$empty_heading" '$0 == heading { print NR; exit }' "$d/log.md")"
    tail -n "+$suffix_line" "$d/log.md" >"$d/actual-suffix"
    cmp -s "$d/suffix" "$d/actual-suffix" || fail 'empty-heading suffix changed'
  done
done

# Relative-path computation uses directory components, not string prefixes, and
# keeps quotes, backslashes, spaces and shell/glob syntax literal.
d="$tmp_root/path-generation"
odd_dir='history with "quotes" \slashes [glob] $(literal)'
for layout in nested sibling ancestor; do
  project="$d/$layout"
  mkdir -p "$project"
  make_log "$project/log.md"
  case "$layout" in
    nested)
      archive_rel="metadata/$odd_dir/archive.md"
      manifest_rel=metadata/manifest.md
      expected_path="$odd_dir/archive.md"
      ;;
    sibling)
      archive_rel=metadata-extra/archive.md
      manifest_rel=metadata/deep/manifest.md
      expected_path=../../metadata-extra/archive.md
      ;;
    ancestor)
      archive_rel=archive.md
      manifest_rel=metadata/deep/manifest.md
      expected_path=../../archive.md
      ;;
  esac
  (
    cd "$project" && run_compact log.md --keep 2 --archive "$archive_rel" --manifest "$manifest_rel" \
      --rollover-id literal-path --require-top-entry 'rollover session'
    assert_rc 0 "$COMPACT_RC" "$layout path generation"
  )
  assert_file_contains "$project/$manifest_rel" "- archive_file: $expected_path" "$layout relative record"
  (cd / && "$checker" "$project/log.md" --manifest "$project/$manifest_rel" --quiet)
done

# Manual rollovers can have a live pointer and archive but no compactor manifest.
# Preview is safe; a write needs an explicit adoption acknowledgement.
for manifest_kind in absent empty header; do
  d="$tmp_root/manual-adoption-$manifest_kind"
  mkdir -p "$d"
  make_log "$d/log.md"
  awk '/^## Current Snapshot$/ { print; print "- Context-log rollover: `manual-history` — boundary: through earlier work"; next } { print }' \
    "$d/log.md" >"$d/log.next" && mv "$d/log.next" "$d/log.md"
  printf '# Context Log Archive\n\n### 2026-05-01 09:00 local - bootstrap - earlier work\n- Previously archived by hand.\n' >"$d/archive.md"
  case "$manifest_kind" in
    empty) : >"$d/manifest.md" ;;
    header) printf '# Context Log Rollover Manifest\n' >"$d/manifest.md" ;;
  esac
  cp "$d/log.md" "$d/log.before"
  cp "$d/archive.md" "$d/archive.before"
  adoption_args=("$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md" --require-top-entry 'rollover session')
  run_compact "${adoption_args[@]}"
  assert_rc 3 "$COMPACT_RC" "$manifest_kind manual pointer requires an adoption decision"
  assert_contains "$COMPACT_OUT" 'has no rollover records' 'adoption has a distinct diagnostic'
  assert_contains "$COMPACT_OUT" '--adopt-manual-rollover' 'diagnostic names the adoption opt-in'
  run_compact "${adoption_args[@]}" --dry-run
  assert_rc 0 "$COMPACT_RC" 'manual adoption can be previewed without opting in'
  assert_contains "$COMPACT_OUT" 'kept 2, archived 3' 'manual adoption preview produces a plan'
  assert_contains "$COMPACT_OUT" 'Preview only' 'preview does not imply permission to write'
  run_compact "${adoption_args[@]}" --adopt-manual-rollover --keep 99
  assert_rc 0 "$COMPACT_RC" 'adoption no-op does not seed a fictional rollover'
  cmp -s "$d/log.md" "$d/log.before" || fail 'manual adoption preview/no-op changed the log'
  cmp -s "$d/archive.md" "$d/archive.before" || fail 'manual adoption preview/no-op changed the archive'
  case "$manifest_kind" in
    absent) assert_not_exists "$d/manifest.md" 'adoption preview/no-op must not create a manifest' ;;
    empty) [[ ! -s "$d/manifest.md" ]] || fail 'adoption preview/no-op changed empty manifest' ;;
    header) [[ "$(cat "$d/manifest.md")" == '# Context Log Rollover Manifest' ]] || fail 'adoption preview/no-op changed manifest header' ;;
  esac
  [[ -z "$(find "$d" -name '.agent-vault-rollover-*' -print)" ]] || fail 'adoption preview/no-op left recovery artifacts'
  run_compact "$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md" --adopt-manual-rollover
  assert_rc 1 "$COMPACT_RC" 'adoption does not bypass the session-entry gate'
  run_compact "${adoption_args[@]}" --adopt-manual-rollover --rollover-id first-automated
  assert_rc 0 "$COMPACT_RC" 'explicit manual adoption succeeds'
  assert_file_contains "$d/log.md" first-automated 'adoption replaces the manual pointer'
  assert_file_contains "$d/archive.md" 'Previously archived by hand.' 'adoption preserves manual history'
  [[ "$(count_entries "$d/archive.md")" == 4 ]] || fail 'adoption lost or duplicated archive entries'
  [[ "$(grep -c '^## rollover:' "$d/manifest.md")" == 1 ]] || fail 'adoption must create only the current rollover record'
  "$checker" "$d/log.md" --archive "$d/archive.md" --manifest "$d/manifest.md" --quiet
  run_compact "${adoption_args[@]}" --adopt-manual-rollover
  assert_rc 2 "$COMPACT_RC" 'adoption opt-in is only valid for a pointer with no manifest records'
done

# --- 1. Happy path: keep 2 of 5, result passes the checker ----------------
d="$tmp_root/happy"
mkdir -p "$d/archive"
make_log "$d/log.md"
run_compact "$d/log.md" --keep 2 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --rollover-id 2026-05-31-1 \
  --require-top-entry "rollover session"
assert_rc 0 "$COMPACT_RC" "happy path"
assert_contains "$COMPACT_OUT" "kept 2, archived 3" "happy path summary"
# The contract: the rolled-over result passes the Layer-2 checker.
"$checker" "$d/log.md" --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" >/dev/null ||
  fail "happy path: checker rejected the rolled-over result"
pass=$((pass + 1))
assert_file_contains "$d/log.md" "Context-log rollover: \`2026-05-31-1\`" "live pointer written"
assert_file_contains "$d/archive/context-log-2026.md" "older work" "archive has moved entry"
assert_file_contains "$d/archive/manifest.md" "## rollover: 2026-05-31-1" "manifest record written"

# --- 2. Count consistency (Codex's PR-B1 ask) -----------------------------
live_n="$(count_entries "$d/log.md")"
arch_n="$(count_entries "$d/archive/context-log-2026.md")"
[[ "$live_n" -eq 2 ]] || fail "count: live log should have 2 entries, has $live_n"
pass=$((pass + 1))
[[ "$arch_n" -eq 3 ]] || fail "count: archive should have 3 entries, has $arch_n"
pass=$((pass + 1))
assert_file_contains "$d/archive/manifest.md" "- kept: 2" "manifest kept matches live count"
assert_file_contains "$d/archive/manifest.md" "- archived: 3" "manifest archived matches batch count"
assert_file_contains "$d/archive/manifest.md" \
  "- newest_archived: 2026-05-28 10:00 local - codex - older work" "newest_archived is batch top"
assert_file_contains "$d/archive/manifest.md" \
  "- oldest_archived: 2026-05-26 09:00 local - bootstrap - initial project setup" "oldest_archived is archive bottom"

# --- 3. --require-top-entry mismatch aborts with ZERO writes ---------------
d="$tmp_root/gate"
mkdir -p "$d/archive"
make_log "$d/log.md"
before="$(cksum "$d/log.md")"
run_compact "$d/log.md" --keep 2 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --rollover-id x --require-top-entry "NOT THERE"
assert_rc 1 "$COMPACT_RC" "gate mismatch aborts"
assert_contains "$COMPACT_OUT" "gate-required rollover entry missing" "gate mismatch message"
[[ "$(cksum "$d/log.md")" == "$before" ]] || fail "gate: live log must be unchanged on abort"
pass=$((pass + 1))
assert_not_exists "$d/archive/context-log-2026.md" "gate: no archive written on abort"
assert_not_exists "$d/archive/manifest.md" "gate: no manifest written on abort"

# --- 4. Nothing to roll over (keep >= total) is a no-op success -----------
d="$tmp_root/noop"
mkdir -p "$d/archive"
make_log "$d/log.md"
before="$(cksum "$d/log.md")"
run_compact "$d/log.md" --keep 5 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --rollover-id x
assert_rc 0 "$COMPACT_RC" "no-op keep==total"
assert_contains "$COMPACT_OUT" "Nothing to roll over" "no-op message"
[[ "$(cksum "$d/log.md")" == "$before" ]] || fail "no-op: live log must be unchanged"
pass=$((pass + 1))
assert_not_exists "$d/archive/manifest.md" "no-op: no manifest written"

# --- 5. --dry-run writes nothing ------------------------------------------
d="$tmp_root/dry"
mkdir -p "$d/archive"
make_log "$d/log.md"
before="$(cksum "$d/log.md")"
run_compact "$d/log.md" --keep 2 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --rollover-id x --require-top-entry "rollover session" --dry-run
assert_rc 0 "$COMPACT_RC" "dry-run rc"
assert_contains "$COMPACT_OUT" "[dry-run]" "dry-run marker"
assert_contains "$COMPACT_OUT" "passed check-context-log-rollover.sh" "dry-run self-validated"
[[ "$(cksum "$d/log.md")" == "$before" ]] || fail "dry-run: live log must be unchanged"
pass=$((pass + 1))
assert_not_exists "$d/archive/context-log-2026.md" "dry-run: no archive written"

# --- 6. Structurally invalid log aborts before any work -------------------
d="$tmp_root/invalid"
mkdir -p "$d/archive"
make_log "$d/log.md"
printf '\n## Current Snapshot\n- stale duplicate\n' >>"$d/log.md"
before="$(cksum "$d/log.md")"
run_compact "$d/log.md" --keep 2 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --rollover-id x
assert_rc 1 "$COMPACT_RC" "invalid structure aborts"
assert_contains "$COMPACT_OUT" "structural rollover check" "invalid structure message"
[[ "$(cksum "$d/log.md")" == "$before" ]] || fail "invalid: live log must be unchanged"
pass=$((pass + 1))

# --- 7. Orphan and candidate-validation refusals leave outputs unchanged ---
# Bounding Entries must not turn the old orphan-prompt refusal into success.
d="$tmp_root/selfval"
mkdir -p "$d/archive"
cat >"$d/log.md" <<'EOF'
# Context Log

## Usage Rules
- Newest entry at top.

## Current Snapshot
- Active branch: `main`

## Entries

### 2026-05-30 09:00 local - claude - kept entry
- Body.

### 2026-05-29 09:00 local - claude - older entry
- Body.

## Next Prompt
- This orphan top-level heading must be nested under its entry.
EOF
before="$(cksum "$d/log.md")"
run_compact "$d/log.md" --keep 1 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --rollover-id x --require-top-entry "kept entry"
assert_rc 1 "$COMPACT_RC" "orphan prompt aborts"
assert_contains "$COMPACT_OUT" "orphaned top-level Next Prompt" "orphan diagnostic"
[[ "$(cksum "$d/log.md")" == "$before" ]] || fail "selfval: live log must be unchanged on abort"
pass=$((pass + 1))
assert_not_exists "$d/archive/context-log-2026.md" "selfval: no archive written on abort"

# The bounded parser rejects an orphan before building output candidates. Keep
# separate coverage for candidate self-validation failure (bad custom anchors).
make_log "$d/log.md"
cp "$d/log.md" "$d/before"
run_compact "$d/log.md" --keep 2 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --rollover-id invalid-anchors \
  --require-top-entry "rollover session" --anchors 'not present in this archive'
assert_rc 1 "$COMPACT_RC" 'candidate self-validation aborts'
assert_contains "$COMPACT_OUT" 'failed check-context-log-rollover.sh' 'candidate validation diagnostic'
cmp -s "$d/log.md" "$d/before" || fail 'candidate validation changed live bytes'
assert_not_exists "$d/archive/context-log-2026.md" 'candidate validation creates no archive'
assert_not_exists "$d/archive/manifest.md" 'candidate validation creates no manifest'

# Both H1/H2 and the Suggested variant remain explicit no-write refusals.
for prompt_heading in '# Next Prompt' '## Suggested Next Prompt'; do
  make_log "$d/log.md"
  printf '\n%s\n- Must be nested.\n' "$prompt_heading" >>"$d/log.md"
  cp "$d/log.md" "$d/before"
  run_compact "$d/log.md" --keep 2 --archive "$d/archive/context-log-2026.md" \
    --manifest "$d/archive/manifest.md" --rollover-id orphan --require-top-entry 'rollover session'
  assert_rc 1 "$COMPACT_RC" 'orphan variants refuse'
  assert_contains "$COMPACT_OUT" 'orphaned top-level Next Prompt' 'orphan variant diagnostic'
  cmp -s "$d/log.md" "$d/before" || fail 'orphan variant changed live bytes'
  assert_not_exists "$d/archive/context-log-2026.md" 'orphan variant creates no archive'
done

# --- 8. Second rollover prepends to the manifest and archive --------------
d="$tmp_root/second"
mkdir -p "$d/archive"
make_log "$d/log.md"
run_compact "$d/log.md" --keep 2 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --rollover-id 2026-05-31-1 --require-top-entry "rollover session"
assert_rc 0 "$COMPACT_RC" "second: first rollover"
# Simulate fresh work: prepend two newer entries to the live log's Entries.
awk '
  /^## Entries[[:space:]]*$/ && !done {
    print
    print ""
    print "### 2026-06-02 09:00 local - claude - newest session entry"
    print "- New work."
    print ""
    print "### 2026-06-01 09:00 local - claude - newer work"
    print "- More work."
    done = 1
    next
  }
  { print }
' "$d/log.md" >"$d/log.next" && mv "$d/log.next" "$d/log.md"
run_compact "$d/log.md" --keep 1 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --rollover-id 2026-06-02-1 \
  --require-top-entry "newest session entry"
assert_rc 0 "$COMPACT_RC" "second: second rollover"
"$checker" "$d/log.md" --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" >/dev/null ||
  fail "second: checker rejected the twice-rolled result"
pass=$((pass + 1))
# Manifest: newest record first, both present.
head -n 20 "$d/archive/manifest.md" | grep -Fq "## rollover: 2026-06-02-1" ||
  fail "second: newest manifest record is not first"
pass=$((pass + 1))
assert_file_contains "$d/archive/manifest.md" "## rollover: 2026-05-31-1" "second: first record retained"
# The newest record's newest_archived is the newer batch's top (2026-06-01).
sed -n '/## rollover: 2026-06-02-1/,/## rollover: 2026-05-31-1/p' "$d/archive/manifest.md" |
  grep -Fq "newest_archived: 2026-06-01 09:00 local - claude - newer work" ||
  fail "second: newest record newest_archived should be the newer batch top"
pass=$((pass + 1))

# --- 9. Custom boundary / anchors / id all flow through, result valid -----
d="$tmp_root/custom"
mkdir -p "$d/archive"
make_log "$d/log.md"
run_compact "$d/log.md" --keep 2 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --rollover-id rid-9 --require-top-entry "rollover session" \
  --boundary "through the codex work window" --anchors "older work; initial project setup"
assert_rc 0 "$COMPACT_RC" "custom fields"
"$checker" "$d/log.md" --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" >/dev/null || fail "custom: checker rejected result"
pass=$((pass + 1))
assert_file_contains "$d/archive/manifest.md" "- boundary: through the codex work window" "custom boundary"
assert_file_contains "$d/log.md" "boundary: through the codex work window" "custom boundary in pointer"

# --- 10. Default fields + --allow-missing-top-entry escape hatch ----------
d="$tmp_root/defaults"
mkdir -p "$d/archive"
make_log "$d/log.md"
run_compact "$d/log.md" --keep 2 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --allow-missing-top-entry
assert_rc 0 "$COMPACT_RC" "default derivation + escape hatch"
"$checker" "$d/log.md" --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" >/dev/null || fail "defaults: checker rejected result"
pass=$((pass + 1))

# --- 10b. The gate is mandatory: a real rollover without either gate flag
# aborts with zero writes (Codex finding 1). ------------------------------
d="$tmp_root/gate-default"
mkdir -p "$d/archive"
make_log "$d/log.md"
before="$(cksum "$d/log.md")"
run_compact "$d/log.md" --keep 2 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --rollover-id x
assert_rc 1 "$COMPACT_RC" "rollover without a gate flag aborts"
assert_contains "$COMPACT_OUT" "refusing to roll over without asserting" "default-gate message"
[[ "$(cksum "$d/log.md")" == "$before" ]] || fail "default-gate: live log must be unchanged"
pass=$((pass + 1))
assert_not_exists "$d/archive/context-log-2026.md" "default-gate: no archive written"
assert_not_exists "$d/archive/manifest.md" "default-gate: no manifest written"

# --- 10c. Output path collisions are rejected before any write (Codex finding 2).
d="$tmp_root/collide"
mkdir -p "$d/archive"
make_log "$d/log.md"
before="$(cksum "$d/log.md")"
# archive == manifest
run_compact "$d/log.md" --keep 2 --archive "$d/archive/same.md" \
  --manifest "$d/archive/same.md" --require-top-entry "rollover session"
assert_rc 2 "$COMPACT_RC" "archive==manifest rejected"
assert_contains "$COMPACT_OUT" "--archive and --manifest must differ" "archive==manifest message"
# manifest == live log
run_compact "$d/log.md" --keep 2 --archive "$d/archive/a.md" \
  --manifest "$d/log.md" --require-top-entry "rollover session"
assert_rc 2 "$COMPACT_RC" "manifest==log rejected"
# archive == live log (spelled via ./)
run_compact "$d/log.md" --keep 2 --archive "$d/log.md" \
  --manifest "$d/archive/m.md" --require-top-entry "rollover session"
assert_rc 2 "$COMPACT_RC" "archive==log rejected"
# Equivalent spellings under a not-yet-created parent must also be rejected
# (the parent gets mkdir -p'd at commit, so a missed collision would clobber).
run_compact "$d/log.md" --keep 2 --archive "$d/fresh/a.md" \
  --manifest "$d/fresh/./a.md" --require-top-entry "rollover session"
assert_rc 2 "$COMPACT_RC" "missing-parent equivalent paths rejected"
assert_contains "$COMPACT_OUT" "must differ" "missing-parent collision message"
assert_not_exists "$d/fresh" "collide: missing parent not created on rejected collision"
# An existing-directory destination would make commit-time "mv" drop the temp
# inside it, committing the live pointer against a non-file path. Reject it.
mkdir -p "$d/arch.dir" "$d/man.dir"
run_compact "$d/log.md" --keep 2 --archive "$d/arch.dir" \
  --manifest "$d/archive/m.md" --require-top-entry "rollover session"
assert_rc 2 "$COMPACT_RC" "--archive existing-directory rejected"
assert_contains "$COMPACT_OUT" "not an existing directory" "archive-dir message"
[[ -z "$(ls -A "$d/arch.dir")" ]] || fail "collide: nothing written inside --archive directory"
pass=$((pass + 1))
run_compact "$d/log.md" --keep 2 --archive "$d/archive/a2.md" \
  --manifest "$d/man.dir" --require-top-entry "rollover session"
assert_rc 2 "$COMPACT_RC" "--manifest existing-directory rejected"
[[ -z "$(ls -A "$d/man.dir")" ]] || fail "collide: nothing written inside --manifest directory"
assert_not_exists "$d/archive/a2.md" "collide: no archive written when manifest is a dir"
pass=$((pass + 1))
[[ "$(cksum "$d/log.md")" == "$before" ]] || fail "collide: live log must be unchanged"
pass=$((pass + 1))
assert_not_exists "$d/archive/same.md" "collide: no colliding file written"
assert_not_exists "$d/archive/a.md" "collide: no archive written on collision"

# --- 10d. Default rollover_id uses max same-day suffix + 1, never a gap re-use
# (Codex/Composer): a manifest with -1 and -3 yields -4, not a duplicate -3.
d="$tmp_root/seq"
mkdir -p "$d/archive"
make_log "$d/log.md"
# Keep this date call: fixture seeding and the default-ID path must share the clock.
today="$(date +%Y-%m-%d)"
# Existing records now require their matching live pointer; keep this sequence
# fixture internally consistent rather than bypassing partial-state detection.
awk -v id="${today}-3" '/^## Current Snapshot$/ { print; print "- Context-log rollover: `" id "` — boundary: through old"; next } { print }' \
  "$d/log.md" >"$d/log.next" && mv "$d/log.next" "$d/log.md"
cat >"$d/archive/manifest.md" <<EOF
# Context Log Rollover Manifest

## rollover: ${today}-3
- archive_file: $d/archive/context-log-2026.md
- boundary: through old
- newest_archived: 2026-05-20 09:00 local - x - a
- oldest_archived: 2026-05-19 09:00 local - x - b
- kept: 1
- archived: 1
- anchors: a; b

## rollover: ${today}-1
- archive_file: $d/archive/context-log-2026.md
- boundary: through older
- newest_archived: 2026-05-18 09:00 local - x - c
- oldest_archived: 2026-05-17 09:00 local - x - d
- kept: 1
- archived: 1
- anchors: c; d
EOF
run_compact "$d/log.md" --keep 2 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --require-top-entry "rollover session"
assert_rc 0 "$COMPACT_RC" "seq: rollover with gapped same-day ids"
assert_file_contains "$d/archive/manifest.md" "## rollover: ${today}-4" "seq: next id is max+1, not a re-used gap"
# Exactly one record carries the new id (no duplicate).
[[ "$(grep -c "^## rollover: ${today}-4\$" "$d/archive/manifest.md")" -eq 1 ]] ||
  fail "seq: the new id must be unique"
pass=$((pass + 1))

# --- 10e. The live rollover pointer is replaced, not duplicated, on re-run.
d="$tmp_root/idem"
mkdir -p "$d/archive"
make_log "$d/log.md"
run_compact "$d/log.md" --keep 2 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --rollover-id 2026-05-31-1 --require-top-entry "rollover session"
# Add fresh newest work, then roll over again with a new id.
awk '/^## Entries[[:space:]]*$/ && !d { print; print ""; print "### 2026-06-03 09:00 local - claude - second rollover session"; print "- Work."; d = 1; next } { print }' \
  "$d/log.md" >"$d/log.next" && mv "$d/log.next" "$d/log.md"
run_compact "$d/log.md" --keep 1 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --rollover-id 2026-06-03-1 --require-top-entry "second rollover session"
assert_rc 0 "$COMPACT_RC" "idem: second rollover"
ptr_count="$(grep -c "Context-log rollover:" "$d/log.md")"
[[ "$ptr_count" -eq 1 ]] || fail "idem: live log must have exactly one rollover pointer, found $ptr_count"
pass=$((pass + 1))
assert_file_contains "$d/log.md" "Context-log rollover: \`2026-06-03-1\`" "idem: pointer updated to newest id"

# --- 11. Usage / IO errors ------------------------------------------------
run_compact "$tmp_root/nope.md" --keep 2 --archive a --manifest m
assert_rc 2 "$COMPACT_RC" "nonexistent log -> exit 2"
make_log "$tmp_root/u.md"
run_compact "$tmp_root/u.md" --archive a --manifest m
assert_rc 2 "$COMPACT_RC" "missing --keep -> exit 2"
run_compact "$tmp_root/u.md" --keep 0 --archive a --manifest m
assert_rc 2 "$COMPACT_RC" "--keep 0 -> exit 2"
run_compact "$tmp_root/u.md" --keep notanumber --archive a --manifest m
assert_rc 2 "$COMPACT_RC" "--keep non-numeric -> exit 2"

# --- 12. Guard: refuse to grow an archive whose own header carries metadata
# this tool cannot keep in sync (a frontmatter "covers:" field or a relocation
# manifest). Prepending a newer batch below such a header silently stales it
# while check-context-log-rollover.sh still passes, so it must fail closed.
make_meta_archive() {
  # $1 = path; an existing archive with frontmatter "covers:", a relocation
  # manifest, and one old entry older than the batch make_log will move.
  cat >"$1" <<'EOF'
---
type: context-log-archive
project: test
archived_on: 2026-05-20
covers: 2026 entries from 2026-05-15 08:00 and earlier
---

# Context Log Archive — 2026

## Relocation manifest

| Source | What | Read when |
| --- | --- | --- |
| `## Entries` older rows | older sessions | researching older work |

---

### 2026-05-15 08:00 local - claude - old archived entry
- Body.
EOF
}

# 12a. Frontmatter "covers:" archive -> abort with zero writes.
d="$tmp_root/guard-frontmatter"
mkdir -p "$d/archive"
make_log "$d/log.md"
make_meta_archive "$d/archive/context-log-2026.md"
log_before="$(cksum "$d/log.md")"
arch_before="$(cksum "$d/archive/context-log-2026.md")"
run_compact "$d/log.md" --keep 1 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --require-top-entry "rollover session"
assert_rc 1 "$COMPACT_RC" "guard: frontmatter covers archive aborts"
assert_contains "$COMPACT_OUT" "cannot keep in sync" "guard: refusal message"
[[ "$(cksum "$d/log.md")" == "$log_before" ]] || fail "guard: live log must be unchanged on refusal"
pass=$((pass + 1))
[[ "$(cksum "$d/archive/context-log-2026.md")" == "$arch_before" ]] ||
  fail "guard: existing archive must be unchanged on refusal"
pass=$((pass + 1))
assert_not_exists "$d/archive/manifest.md" "guard: no manifest written on refusal"

# 12b. The explicit override lets it through, and the result still validates.
d="$tmp_root/guard-override"
mkdir -p "$d/archive"
make_log "$d/log.md"
make_meta_archive "$d/archive/context-log-2026.md"
run_compact "$d/log.md" --keep 1 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --require-top-entry "rollover session" \
  --allow-stale-archive-metadata
assert_rc 0 "$COMPACT_RC" "guard: override compacts"
"$checker" "$d/log.md" --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" >/dev/null ||
  fail "guard override: checker rejected the overridden result"
pass=$((pass + 1))
assert_file_contains "$d/archive/context-log-2026.md" "old archived entry" "guard override: old entry retained"
assert_file_contains "$d/archive/context-log-2026.md" "feature work" "guard override: newer batch prepended"

# 12c. A relocation-manifest heading alone (no frontmatter) also trips the guard.
d="$tmp_root/guard-manifest-heading"
mkdir -p "$d/archive"
make_log "$d/log.md"
cat >"$d/archive/context-log-2026.md" <<'EOF'
# Context Log Archive — 2026

## Relocation manifest

| Source | What | Read when |
| --- | --- | --- |
| older rows | older sessions | researching older work |

---

### 2026-05-15 08:00 local - claude - old archived entry
- Body.
EOF
arch_before="$(cksum "$d/archive/context-log-2026.md")"
run_compact "$d/log.md" --keep 1 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --require-top-entry "rollover session"
assert_rc 1 "$COMPACT_RC" "guard: relocation-manifest heading aborts"
assert_contains "$COMPACT_OUT" "cannot keep in sync" "guard: manifest-heading refusal message"
[[ "$(cksum "$d/archive/context-log-2026.md")" == "$arch_before" ]] ||
  fail "guard: archive unchanged on manifest-heading refusal"
pass=$((pass + 1))

# 12d. A plain archive with no such header still compacts (no false positive).
# (Also covered by cases 1 and 8; this asserts the guard does not over-fire.)
d="$tmp_root/guard-plain"
mkdir -p "$d/archive"
make_log "$d/log.md"
cat >"$d/archive/context-log-2026.md" <<'EOF'
# Context Log Archive

### 2026-05-15 08:00 local - claude - old archived entry
- Body.
EOF
run_compact "$d/log.md" --keep 1 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --require-top-entry "rollover session"
assert_rc 0 "$COMPACT_RC" "guard: plain archive compacts (no false positive)"
pass=$((pass + 1))

# 12e. Frontmatter "covers:" ALONE (no relocation-manifest heading) trips the
# guard, pinning the frontmatter branch independently of case 12a's combined
# fixture.
d="$tmp_root/guard-covers-only"
mkdir -p "$d/archive"
make_log "$d/log.md"
cat >"$d/archive/context-log-2026.md" <<'EOF'
---
type: context-log-archive
covers: 2026 entries from 2026-05-15 08:00 and earlier
---

# Context Log Archive — 2026

### 2026-05-15 08:00 local - claude - old archived entry
- Body.
EOF
arch_before="$(cksum "$d/archive/context-log-2026.md")"
run_compact "$d/log.md" --keep 1 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --require-top-entry "rollover session"
assert_rc 1 "$COMPACT_RC" "guard: frontmatter covers-only aborts"
assert_contains "$COMPACT_OUT" "cannot keep in sync" "guard: covers-only refusal message"
[[ "$(cksum "$d/archive/context-log-2026.md")" == "$arch_before" ]] ||
  fail "guard: archive unchanged on covers-only refusal"
pass=$((pass + 1))

# 12f. The guard also fires under --dry-run: it runs during archive build, before
# the dry-run write-skip, so a dry-run preview reports the refusal with no writes.
d="$tmp_root/guard-dry-run"
mkdir -p "$d/archive"
make_log "$d/log.md"
make_meta_archive "$d/archive/context-log-2026.md"
log_before="$(cksum "$d/log.md")"
arch_before="$(cksum "$d/archive/context-log-2026.md")"
run_compact "$d/log.md" --keep 1 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --require-top-entry "rollover session" --dry-run
assert_rc 1 "$COMPACT_RC" "guard: --dry-run also aborts on the guard path"
assert_contains "$COMPACT_OUT" "cannot keep in sync" "guard: dry-run refusal message"
[[ "$(cksum "$d/log.md")" == "$log_before" ]] || fail "guard dry-run: live log unchanged"
pass=$((pass + 1))
[[ "$(cksum "$d/archive/context-log-2026.md")" == "$arch_before" ]] ||
  fail "guard dry-run: archive unchanged"
pass=$((pass + 1))
assert_not_exists "$d/archive/manifest.md" "guard dry-run: no manifest written"

# 13. Headerless existing archive (first dated entry on line 1): no duplication or
# reorder. first_entry_line returns 1, so the header slice must NOT be sed "1,0p"
# (GNU sed emits line 1, which would then be re-appended from arch_existing).
d="$tmp_root/headerless"
mkdir -p "$d/archive"
make_log "$d/log.md"
cat >"$d/archive/context-log-2026.md" <<'EOF'
### 2026-05-01 09:00 local - claude - pre-existing archived entry
- Body.
EOF
run_compact "$d/log.md" --keep 1 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --require-top-entry "rollover session"
assert_rc 0 "$COMPACT_RC" "headerless archive compacts"
"$checker" "$d/log.md" --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" >/dev/null || fail "headerless: checker rejected result"
pass=$((pass + 1))
# The pre-existing entry must appear exactly once (the bug duplicated it).
[[ "$(grep -c 'pre-existing archived entry' "$d/archive/context-log-2026.md")" -eq 1 ]] ||
  fail "headerless: pre-existing entry must not be duplicated"
pass=$((pass + 1))
# Order: the newly moved batch (newer) sits above the older pre-existing entry.
moved_ln="$(grep -n 'feature work' "$d/archive/context-log-2026.md" | head -n1 | cut -d: -f1)"
old_ln="$(grep -n 'pre-existing archived entry' "$d/archive/context-log-2026.md" | head -n1 | cut -d: -f1)"
[[ -n "$moved_ln" && -n "$old_ln" && "$moved_ln" -lt "$old_ln" ]] ||
  fail "headerless: moved batch must be newest-first above the pre-existing entry"
pass=$((pass + 1))

# 14. Header present but no dated entries yet (first_entry_line empty -> else
# branch): the batch is appended after the existing header, no duplication.
d="$tmp_root/header-no-entries"
mkdir -p "$d/archive"
make_log "$d/log.md"
printf '# Context Log Archive\n\nSome prose, no dated entries yet.\n' >"$d/archive/context-log-2026.md"
run_compact "$d/log.md" --keep 1 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --require-top-entry "rollover session"
assert_rc 0 "$COMPACT_RC" "header-only archive compacts"
"$checker" "$d/log.md" --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" >/dev/null || fail "header-only: checker rejected result"
pass=$((pass + 1))
[[ "$(grep -c 'Some prose, no dated entries yet' "$d/archive/context-log-2026.md")" -eq 1 ]] ||
  fail "header-only: existing header prose must not be duplicated"
pass=$((pass + 1))

# 15. Headerless manifest (first record on line 1): parity with the archive fix —
# the same sed "1,0p" class must not duplicate/mangle the existing manifest record.
d="$tmp_root/headerless-manifest"
mkdir -p "$d/archive"
make_log "$d/log.md"
awk '/^## Current Snapshot$/ { print; print "- Context-log rollover: `2026-05-01-1` — boundary: through old"; next } { print }' \
  "$d/log.md" >"$d/log.next" && mv "$d/log.next" "$d/log.md"
cat >"$d/archive/manifest.md" <<'EOF'
## rollover: 2026-05-01-1
- archive_file: x/context-log-2026.md
- boundary: through old
- newest_archived: 2026-05-01 09:00 local - x - older
- oldest_archived: 2026-05-01 09:00 local - x - older
- kept: 1
- archived: 1
- anchors: older; older
EOF
run_compact "$d/log.md" --keep 1 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --rollover-id 2026-06-02-1 --require-top-entry "rollover session"
assert_rc 0 "$COMPACT_RC" "headerless manifest compacts"
"$checker" "$d/log.md" --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" >/dev/null || fail "headerless manifest: checker rejected result"
pass=$((pass + 1))
# The pre-existing record must appear exactly once (the bug duplicated/mangled it).
[[ "$(grep -c '^## rollover: 2026-05-01-1' "$d/archive/manifest.md")" -eq 1 ]] ||
  fail "headerless manifest: existing record must not be duplicated"
pass=$((pass + 1))
# The newest record is the freshly written one, above the pre-existing record.
new_ln="$(grep -n '^## rollover: 2026-06-02-1' "$d/archive/manifest.md" | head -n1 | cut -d: -f1)"
old_ln="$(grep -n '^## rollover: 2026-05-01-1' "$d/archive/manifest.md" | head -n1 | cut -d: -f1)"
[[ -n "$new_ln" && -n "$old_ln" && "$new_ln" -lt "$old_ln" ]] ||
  fail "headerless manifest: new record must be newest-first above the pre-existing record"
pass=$((pass + 1))

# --- Nested date-prefixed sub-heading is body text, not an entry boundary --
# (regression: the loose matcher counted any heading starting with a date, so a
# "#### <date> ..." sub-heading landing at the keep boundary split its parent
# entry mid-body, and the checker's identical matcher passed the corrupted result)
make_nested_log() {
  cat >"$1" <<'EOF'
# Context Log

## Usage Rules
- Newest entry at top.

## Current Snapshot
- Active branch: `main`
- Last updated: 2026-05-30

## Entries

### 2026-05-30 09:00 local - claude - rollover session entry
#### State
- Bookkeeping for the rollover.

### 2026-05-29 11:00 local - claude - feature work
- Implemented X.

#### 2026-05-29 follow-up
- Fixed the import edge case later the same day; belongs to the entry above.

```md
### 2026-05-29 12:00 local - example - fenced entry heading, not a boundary
```

### 2026-05-28 10:00 local - codex - older work
- Body.

### 2026-05-27 10:00 local - gemini - older still
- Body.
EOF
}
d="$tmp_root/nested"
mkdir -p "$d/archive"
make_nested_log "$d/log.md"
# --keep 2: with the loose matcher the nested heading was the 3rd "entry" and
# became the split line, tearing "feature work" apart.
run_compact "$d/log.md" --keep 2 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --rollover-id 2026-05-31-1 \
  --require-top-entry "rollover session"
assert_rc 0 "$COMPACT_RC" "nested heading rollover"
assert_contains "$COMPACT_OUT" "kept 2, archived 2" "nested: only real entries counted"
# The kept "feature work" entry keeps its nested sub-heading; the archive gets
# whole entries, so its first dated heading (after the archive header) must be
# the canonical boundary entry -- an orphaned "#### <date>" fragment would
# surface here as the first dated heading.
assert_file_contains "$d/log.md" "#### 2026-05-29 follow-up" "nested: sub-heading stays with kept entry"
first_dated_heading="$(awk '
  /^(```|~~~)/ { f = !f; next }
  { if (f) next; l = $0; sub(/\r$/, "", l)
    if (l !~ /^#+[[:space:]]/) next
    t = l; sub(/^#+[[:space:]]+/, "", t)
    if (t ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) { print l; exit } }
' "$d/archive/context-log-2026.md")"
[[ "$first_dated_heading" == "### 2026-05-28 10:00 local - codex - older work" ]] ||
  fail "nested: archive's first dated heading must be the canonical boundary entry, got: $first_dated_heading"
pass=$((pass + 1))
[[ "$(count_entries "$d/log.md")" -eq 2 ]] || fail "nested: live log should keep 2 entries"
pass=$((pass + 1))
[[ "$(count_entries "$d/archive/context-log-2026.md")" -eq 2 ]] || fail "nested: archive should hold 2 entries"
pass=$((pass + 1))
assert_file_contains "$d/archive/manifest.md" \
  "- newest_archived: 2026-05-28 10:00 local - codex - older work" "nested: boundary is a real entry"
"$checker" "$d/log.md" --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" >/dev/null || fail "nested: checker rejected the result"
pass=$((pass + 1))

# --- Nested dated heading must not inflate the rollover trigger ------------
# (regression: 4 real entries + 1 nested dated heading counted as 5, so
# --keep 4 rolled over a should-be no-op log and archived only the fragment)
d="$tmp_root/nested-noop"
mkdir -p "$d/archive"
make_nested_log "$d/log.md"
before="$(cksum "$d/log.md")"
run_compact "$d/log.md" --keep 4 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --rollover-id x --require-top-entry "rollover session"
assert_rc 0 "$COMPACT_RC" "nested no-op keep==real total"
assert_contains "$COMPACT_OUT" "Nothing to roll over" "nested no-op message"
[[ "$(cksum "$d/log.md")" == "$before" ]] || fail "nested no-op: live log must be unchanged"
pass=$((pass + 1))
assert_not_exists "$d/archive/manifest.md" "nested no-op: no manifest written"

# --- Existing archive with noncanonical dated entries: abort, zero writes --
# (regression: the strict matcher made first_entry_line blind to legacy entry
# styles, so the whole archive was treated as header prose and silently
# reordered above the newer batch, invisible to boundary validation)
d="$tmp_root/legacy-archive"
mkdir -p "$d/archive"
make_log "$d/log.md"
cat >"$d/archive/context-log-2026.md" <<'EOF'
# Context Log Archive

## 2026-04-01 - legacy hand-written entry
- Old-style body the strict boundary scan cannot see.

### 2026-03-15 09:00 local — em-dash legacy entry
- Body.
EOF
before_log="$(cksum "$d/log.md")"
before_arch="$(cksum "$d/archive/context-log-2026.md")"
run_compact "$d/log.md" --keep 2 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --rollover-id x --require-top-entry "rollover session"
assert_rc 1 "$COMPACT_RC" "legacy archive aborts"
assert_contains "$COMPACT_OUT" "existing archive" "legacy archive abort message"
[[ "$(cksum "$d/log.md")" == "$before_log" ]] || fail "legacy archive: live log must be unchanged"
pass=$((pass + 1))
[[ "$(cksum "$d/archive/context-log-2026.md")" == "$before_arch" ]] || fail "legacy archive: archive must be unchanged"
pass=$((pass + 1))
assert_not_exists "$d/archive/manifest.md" "legacy archive: no manifest written"

# --- Mixed archive (noncanonical below canonical entries): same abort -------
d="$tmp_root/mixed-archive"
mkdir -p "$d/archive"
make_log "$d/log.md"
cat >"$d/archive/context-log-2026.md" <<'EOF'
# Context Log Archive

### 2026-04-02 10:00 local - claude - canonical archived entry
- Body.

## 2026-02-01 - legacy tail entry
- Old-style body below a canonical entry.
EOF
before_arch="$(cksum "$d/archive/context-log-2026.md")"
run_compact "$d/log.md" --keep 2 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --rollover-id x --require-top-entry "rollover session"
assert_rc 1 "$COMPACT_RC" "mixed archive aborts"
assert_contains "$COMPACT_OUT" "existing archive" "mixed archive abort message"
[[ "$(cksum "$d/archive/context-log-2026.md")" == "$before_arch" ]] || fail "mixed archive: archive must be unchanged"
pass=$((pass + 1))
assert_not_exists "$d/archive/manifest.md" "mixed archive: no manifest written"

# --- Destination preparation must finish before any output changes (#138) ---
d="$tmp_root/blocked-manifest-parent"
mkdir -p "$d"
make_log "$d/log.md"
cp "$d/log.md" "$d/original.md"
printf 'not a directory\n' >"$d/blocked"
run_compact "$d/log.md" --keep 2 --archive "$d/archive.md" \
  --manifest "$d/blocked/manifest.md" --require-top-entry "rollover session"
assert_rc 2 "$COMPACT_RC" "blocked manifest parent is a pre-commit IO error"
cmp -s "$d/log.md" "$d/original.md" || fail "blocked parent changed the log"
assert_not_exists "$d/archive.md" "blocked parent must not create archive"

# A deterministic destination-specific wrapper exercises the real writer. It
# never evaluates commands or sleeps, and only faults on a test-owned path.
fault_bin="$tmp_root/fault-bin"
mkdir -p "$fault_bin"
real_mv="$(command -v mv)"
cat >"$fault_bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${@: -1}" == "${ROLLOVER_TEST_DEST:-}" ]]; then
  if [[ "${ROLLOVER_TEST_FAULT:-}" == before ]]; then
    echo 'injected failure before replacement' >&2
    exit 73
  fi
  "$ROLLOVER_TEST_MV" "$@"
  case "${ROLLOVER_TEST_FAULT:-}" in
    after) echo 'injected failure after replacement' >&2; exit 73 ;;
    kill) kill -KILL "$PPID" ;;
    term) kill -TERM "$PPID" ;;
  esac
else
  exec "$ROLLOVER_TEST_MV" "$@"
fi
EOF
chmod +x "$fault_bin/mv"

run_fault() {
  local fault="$1" destination="$2"
  shift 2
  PATH="$fault_bin:$PATH" ROLLOVER_TEST_MV="$real_mv" \
    ROLLOVER_TEST_DEST="$destination" ROLLOVER_TEST_FAULT="$fault" run_compact "$@"
}

# Combine #139 formatting/paths/suffix and #156 mixed fences with #138 recovery.
# Compare with an uninterrupted run at identical paths.
d="$tmp_root/combined-recovery"
mkdir -p "$d"
make_log "$d/log.md"
sed 's/older work/fix `foo` in **setup**/' "$d/log.md" >"$d/log.next"
mv "$d/log.next" "$d/log.md"
awk '/^- Body/ { print "````md\n```\n## Example inside a longer fence\n~~~\n````" } { print }' "$d/log.md" >"$d/log.next"
mv "$d/log.next" "$d/log.md"
printf '\n## Appendix\r\n- Keep exactly, without final newline.' >>"$d/log.md"
cp "$d/log.md" "$d/before"
combined_args=("$d/log.md" --keep 2 --archive "$d/history/archive.md" --manifest "$d/metadata/manifest.md"
  --rollover-id combined --require-top-entry 'rollover session')
run_compact "${combined_args[@]}"
assert_rc 0 "$COMPACT_RC" 'combined uninterrupted oracle'
cp "$d/log.md" "$d/expected-log"
cp "$d/history/archive.md" "$d/expected-archive"
cp "$d/metadata/manifest.md" "$d/expected-manifest"
for destination in "$d/history/archive.md" "$d/metadata/manifest.md" "$d/log.md"; do
  cp "$d/before" "$d/log.md"
  rm "$d/history/archive.md" "$d/metadata/manifest.md"
  run_fault after "$destination" "${combined_args[@]}"
  assert_rc 3 "$COMPACT_RC" 'combined interrupted replacement'
  run_compact "$d/log.md" --recover --dry-run
  assert_rc 0 "$COMPACT_RC" 'combined recovery preview'
  if [[ "$destination" == "$d/log.md" ]]; then expected_live="$d/expected-log"; else expected_live="$d/before"; fi
  cmp -s "$d/log.md" "$expected_live" || fail 'combined recovery preview wrote live log'
  run_compact "$d/log.md" --recover
  assert_rc 0 "$COMPACT_RC" 'combined recovery'
  cmp -s "$d/log.md" "$d/expected-log" || fail 'combined live bytes differ'
  cmp -s "$d/history/archive.md" "$d/expected-archive" || fail 'combined archive bytes differ'
  cmp -s "$d/metadata/manifest.md" "$d/expected-manifest" || fail 'combined manifest bytes differ'
  "$checker" "$d/log.md" --manifest "$d/metadata/manifest.md" --quiet
done

# Named regression: a live replacement failure used to permit a silent-success
# retry that duplicated history, issued another ID, and still passed the checker.
d="$tmp_root/silent-success-retry"
mkdir -p "$d"
make_log "$d/log.md"
run_fault before "$d/log.md" "$d/log.md" --keep 2 --archive "$d/archive.md" \
  --manifest "$d/manifest.md" --rollover-id original-id --boundary original-boundary \
  --require-top-entry "rollover session"
assert_rc 3 "$COMPACT_RC" "live replacement failure requires recovery"
assert_contains "$COMPACT_OUT" "--recover" "failure explains recovery"
[[ "$(count_entries "$d/archive.md")" == 3 ]] || fail "partial archive batch count"
run_compact "$d/log.md" --keep 2 --archive "$d/archive.md" \
  --manifest "$d/manifest.md" --require-top-entry "rollover session"
assert_rc 3 "$COMPACT_RC" "ordinary retry must not duplicate history"
run_compact "$d/log.md" --recover
assert_rc 0 "$COMPACT_RC" "explicit recovery finishes original operation"
assert_file_contains "$d/log.md" 'original-id' "recovery keeps original ID"
assert_file_contains "$d/log.md" 'original-boundary' "recovery keeps original boundary"
[[ "$(count_entries "$d/archive.md")" == 3 ]] || fail "recovery duplicated history"
[[ "$(grep -c '^## rollover:' "$d/manifest.md")" == 1 ]] || fail "recovery duplicated manifest"
"$checker" "$d/log.md" --archive "$d/archive.md" --manifest "$d/manifest.md" >/dev/null
run_compact "$d/log.md" --recover
assert_rc 0 "$COMPACT_RC" "repeated recovery is a no-op"

# Snapshot assertions compare exact bytes (including all historical entries),
# not only counts. The oracle is an uninterrupted run at the SAME destinations.
snapshot_outputs() {
  local destination="$1" role
  mkdir -p "$destination"
  for role in log archive manifest; do
    if [[ -f "$d/$role.md" ]]; then cp -p "$d/$role.md" "$destination/$role.md"; fi
  done
}

assert_outputs() {
  local expected="$1" label="$2" role
  for role in log archive manifest; do
    if [[ -f "$expected/$role.md" ]]; then
      cmp -s "$d/$role.md" "$expected/$role.md" || fail "$label: $role bytes differ"
    else
      [[ ! -e "$d/$role.md" ]] || fail "$label: $role should be absent"
    fi
    pass=$((pass + 1))
  done
}

assert_no_transaction_artifacts() {
  [[ -z "$(find "$d" -name '.agent-vault-rollover-*' -print)" ]] || fail "$1: transaction artifacts remain"
  pass=$((pass + 1))
}

prepare_recovery_case() {
  local name="$1" existing="${2:-false}" role
  d="$tmp_root/$name"
  mkdir -p "$d"
  make_log "$d/log.md"
  if [[ "$existing" == true ]]; then
    cat >"$d/archive.md" <<'EOF'
# Context Log Archive

### 2026-05-01 09:00 local - bootstrap - earlier archived work
- Preserve this older history, including its body.
EOF
    printf '# Context Log Rollover Manifest\n' >"$d/manifest.md"
    chmod 640 "$d/archive.md"
    chmod 444 "$d/manifest.md"
  fi
  snapshot_outputs "$d/before"
  run_compact "$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md" \
    --rollover-id frozen-id --boundary 'frozen boundary' --anchors 'older work; initial project setup' \
    --require-top-entry 'rollover session'
  assert_rc 0 "$COMPACT_RC" "$name: uninterrupted oracle"
  snapshot_outputs "$d/expected"
  for role in log archive manifest; do
    # Remove before copying so read-only destinations are faithfully restored.
    rm -f "$d/$role.md"
    if [[ -f "$d/before/$role.md" ]]; then cp -p "$d/before/$role.md" "$d/$role.md"; fi
  done
}

fault_recovery_case() {
  run_fault "$1" "$2" "$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md" \
    --rollover-id frozen-id --boundary 'frozen boundary' --anchors 'older work; initial project setup' \
    --require-top-entry 'rollover session'
}

read_test_record() {
  record=()
  local field
  while IFS= read -r -d '' field; do record+=("$field"); done <"$d/.agent-vault-rollover-log.md/record"
}

# Model older-helper after-images explicitly, including hashes, rather than
# relying on a historical Git checkout being available in a shallow CI clone.
# Only these disposable fixtures author their records; recovery must never
# rewrite a real journal or repair payloads to make them validate.
for legacy_case in archive-tail manifest-tail log-tail archive-hidden manifest-hidden log-hidden; do
  prepare_recovery_case "legacy-fence-$legacy_case"
  fault_recovery_case before "$d/archive.md"
  assert_rc 3 "$COMPACT_RC" 'prepare legacy fence after-images'
  read_test_record
  role="${legacy_case%%-*}"
  case "$role" in archive) offset=3 ;; manifest) offset=8 ;; log) offset=13 ;; esac
  payload="${record[$((offset + 3))]}/$role.md"
  if [[ "$legacy_case" == *-tail ]]; then
    printf '\n```md\nOld example through EOF.\n' >>"$payload"
    cp -p "$payload" "$d/expected/$role.md"
  else
    cp -p "$payload" "$d/payload.before"
    {
      printf '```md\n'
      cat "$d/payload.before"
    } >"$payload"
  fi
  digest="$(shasum -a 256 "$payload")"
  record[$((offset + 2))]="${digest%% *}"
  printf '%s\0' "${record[@]}" >"$d/.agent-vault-rollover-log.md/record"
  cp "$d/.agent-vault-rollover-log.md/record" "$d/record.before"
  cp "$payload" "$d/payload.recorded"
  for mode in preview apply; do
    if [[ "$mode" == preview ]]; then run_compact "$d/log.md" --recover --dry-run; else run_compact "$d/log.md" --recover; fi
    if [[ "$legacy_case" == *-tail ]]; then
      assert_rc 0 "$COMPACT_RC" 'safe legacy tail remains recoverable'
      assert_contains "$COMPACT_OUT" 'Warning: unterminated fence' 'recovery surfaces EOF warning on success'
      assert_contains "$COMPACT_OUT" "$d/$role.md" 'recovery diagnostic names original destination'
      if [[ "$mode" == preview ]]; then assert_outputs "$d/before" 'legacy tail preview does not write'; else assert_outputs "$d/expected" 'legacy tail recovery preserves bytes'; fi
    else
      assert_rc 3 "$COMPACT_RC" 'hidden legacy structure refuses recovery'
      assert_contains "$COMPACT_OUT" 'failed validation' 'refusal comes from structural validation, not fingerprints'
      assert_outputs "$d/before" 'invalid after-images write nothing'
      cmp -s "$d/record.before" "$d/.agent-vault-rollover-log.md/record" || fail 'recovery changed legacy journal'
      cmp -s "$d/payload.recorded" "$payload" || fail 'recovery changed legacy payload'
    fi
  done
  if [[ "$legacy_case" == *-tail ]]; then assert_no_transaction_artifacts 'EOF recovery reaches commitment and cleanup'; fi
done

# Closure-only live after-images may recover in every partial-install state.
# Pair with a real violation: the policy must not suppress a generic exit 1.
for installed in 0 1 2 3; do
  for violation in none structure; do
    prepare_recovery_case "live-eof-$installed-$violation"
    fault_recovery_case before "$d/archive.md"
    assert_rc 3 "$COMPACT_RC" 'prepare recorded live EOF case'
    read_test_record
    payload="${record[16]}/log.md"
    if [[ "$violation" == structure ]]; then printf '\n## Current Snapshot\nDuplicate active snapshot.\n' >>"$payload"; fi
    printf '\n## Appendix\n~~~md\nOld recorded example through EOF.\n' >>"$payload"
    digest="$(shasum -a 256 "$payload")"
    record[15]="${digest%% *}"
    printf '%s\0' "${record[@]}" >"$d/.agent-vault-rollover-log.md/record"
    cp -p "$payload" "$d/expected/log.md"
    for ((i = 0; i < installed; i++)); do
      offset=$((3 + i * 5))
      destination="${record[$offset]}"
      cp -p "${record[$((offset + 3))]}/${destination##*/}" "$destination"
    done
    snapshot_outputs "$d/partial"
    cp "$d/.agent-vault-rollover-log.md/record" "$d/record.before"
    cp "$payload" "$d/payload.before"
    refusal_before="$(find "$d" -type f -exec shasum -a 256 {} \; | sort)"
    run_compact "$d/log.md" --keep 99 --archive "$d/archive.md" --manifest "$d/manifest.md"
    assert_rc 3 "$COMPACT_RC" 'pending state retains precedence over ordinary EOF/no-op'
    for mode in preview apply; do
      if [[ "$mode" == preview ]]; then
        run_compact "$d/log.md" --recover --dry-run --quiet
      else
        run_compact "$d/log.md" --recover --quiet
      fi
      assert_contains "$COMPACT_OUT" 'Warning: unterminated fence in live' 'recovery EOF warning visible under quiet'
      assert_contains "$COMPACT_OUT" "$d/log.md" 'recovery warning uses destination path'
      if [[ "$violation" == structure ]]; then
        assert_rc 3 "$COMPACT_RC" 'real finding still refuses EOF recovery'
        assert_contains "$COMPACT_OUT" 'duplicate "## Current Snapshot"' 'specific structural finding preserved'
      else
        assert_rc 0 "$COMPACT_RC" 'closure-only recovery succeeds'
      fi
      if [[ "$mode" == preview || "$violation" == structure ]]; then
        assert_outputs "$d/partial" 'preview/refusal writes no output'
        cmp -s "$d/record.before" "$d/.agent-vault-rollover-log.md/record" || fail 'EOF preview/refusal changed record'
        cmp -s "$d/payload.before" "$payload" || fail 'EOF preview/refusal changed staged log'
        [[ "$(find "$d" -type f -exec shasum -a 256 {} \; | sort)" == "$refusal_before" ]] || fail 'EOF preview/refusal changed a recorded artifact'
      else
        assert_outputs "$d/expected" 'recovery installs immutable after-images'
        assert_no_transaction_artifacts 'both recovery validations allow commitment and cleanup'
        run_compact "$d/log.md" --recover --quiet
        assert_rc 0 "$COMPACT_RC" 'EOF recovery is idempotent'
        assert_contains "$COMPACT_OUT" 'No pending transaction' 'recovery does not loop in ready state'
        run_compact "$d/log.md" --keep 99 --archive "$d/archive.md" --manifest "$d/manifest.md" --quiet
        assert_rc 1 "$COMPACT_RC" 'ordinary no-op is strict after successful recovery'
        assert_contains "$COMPACT_OUT" 'unterminated fence in live' 'ordinary EOF refusal is actionable'
      fi
    done
  done
done

# Recovery validates recorded after-images, not an unclosed original live file.
prepare_recovery_case open-before-closed-after
fault_recovery_case before "$d/archive.md"
assert_rc 3 "$COMPACT_RC" 'prepare unclosed before-image case'
printf '\n~~~\nUnclosed original, not the recorded replacement.\n' >>"$d/log.md"
read_test_record
digest="$(shasum -a 256 "$d/log.md")"
record[14]="${digest%% *}"
printf '%s\0' "${record[@]}" >"$d/.agent-vault-rollover-log.md/record"
run_compact "$d/log.md" --recover --quiet
assert_rc 0 "$COMPACT_RC" 'unclosed before-image does not veto a valid result'
assert_outputs "$d/expected" 'closed after-image replaces original'
assert_no_transaction_artifacts 'before-image recovery cleanup'

for existing in false true; do
  for fault in before after; do
    for role in archive manifest log; do
      prepare_recovery_case "matrix-$existing-$fault-$role" "$existing"
      fault_recovery_case "$fault" "$d/$role.md"
      assert_rc 3 "$COMPACT_RC" "matrix $existing/$fault/$role reports pending transaction"
      snapshot_outputs "$d/partial"
      run_compact "$d/log.md" --keep 99 --archive "$d/different-archive.md" --manifest "$d/different-manifest.md"
      assert_rc 3 "$COMPACT_RC" "pending detection precedes no-op and changed targets"
      run_compact "$d/log.md" --recover --keep 2
      assert_rc 2 "$COMPACT_RC" "recovery rejects generation options"
      run_compact "$d/log.md" --recover --dry-run
      assert_rc 0 "$COMPACT_RC" "pending dry-run validates without writing"
      assert_outputs "$d/partial" "dry-run and retries leave partial state untouched"
      run_compact "$d/log.md" --recover
      assert_rc 0 "$COMPACT_RC" "matrix recovery succeeds"
      assert_outputs "$d/expected" "recovery equals uninterrupted result"
      assert_no_transaction_artifacts 'successful recovery cleanup'
      run_compact "$d/log.md" --recover
      assert_rc 0 "$COMPACT_RC" "recovery is idempotent"
      run_compact "$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md"
      assert_rc 0 "$COMPACT_RC" "ordinary retry after recovery is a no-op"
      assert_outputs "$d/expected" "repeated recovery/retry is unchanged"
    done
  done
done

# Both a caught signal and termination bypassing EXIT cleanup leave recoverable
# state. The wrapper signals only its own writer parent, after a known rename.
for signal_fault in term kill; do
  prepare_recovery_case "signal-$signal_fault"
  fault_recovery_case "$signal_fault" "$d/archive.md"
  expected_rc=143
  [[ "$signal_fault" != kill ]] || expected_rc=137
  assert_rc "$expected_rc" "$COMPACT_RC" "$signal_fault preserves signal status"
  run_compact "$d/log.md" --recover
  assert_rc 0 "$COMPACT_RC" "recover after $signal_fault"
  assert_outputs "$d/expected" "$signal_fault recovery bytes"
done

prepare_recovery_case killed-after-publication
fault_recovery_case kill "$d/.agent-vault-rollover-log.md/record"
assert_rc 137 "$COMPACT_RC" "kill after journal publication"
assert_outputs "$d/before" "no output replaced before journal publication"
run_compact "$d/log.md" --recover
assert_rc 0 "$COMPACT_RC" "recover an unstarted prepared transaction"
assert_outputs "$d/expected" "unstarted recovery bytes"

prepare_recovery_case interrupted-recovery
fault_recovery_case after "$d/archive.md"
run_fault after "$d/manifest.md" "$d/log.md" --recover
assert_rc 3 "$COMPACT_RC" "recovery can itself be interrupted"
run_compact "$d/log.md" --recover
assert_rc 0 "$COMPACT_RC" "retry interrupted recovery"
assert_outputs "$d/expected" 'interrupted recovery bytes'

# Adoption is a generation decision only; recovery must retain its original
# intent and require no adoption flag after an interrupted first automated run.
prepare_recovery_case interrupted-manual-adoption true
awk '/^## Current Snapshot$/ { print; print "- Context-log rollover: `manual-history` — boundary: through earlier work"; next } { print }' \
  "$d/log.md" >"$d/log.next" && mv "$d/log.next" "$d/log.md"
run_fault after "$d/archive.md" "$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md" \
  --rollover-id frozen-id --boundary 'frozen boundary' --anchors 'older work; initial project setup' \
  --require-top-entry 'rollover session' --adopt-manual-rollover
assert_rc 3 "$COMPACT_RC" 'interrupted manual adoption retains a recoverable record'
run_compact "$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md" --adopt-manual-rollover --dry-run
assert_rc 3 "$COMPACT_RC" 'adoption preview cannot bypass a pending record'
run_compact "$d/log.md" --recover
assert_rc 0 "$COMPACT_RC" 'manual adoption recovers without generation options'
assert_outputs "$d/expected" 'manual adoption recovery preserves original replacement bytes'

# Committed-state cleanup must never replay over later user edits.
real_rm="$(command -v rm)"
cat >"$fault_bin/rm" <<'EOF'
#!/usr/bin/env bash
if [[ "${@: -1}" == "${ROLLOVER_TEST_CLEANUP_DEST:-}" ]]; then exit 73; fi
exec "$ROLLOVER_TEST_RM" "$@"
EOF
chmod +x "$fault_bin/rm"
prepare_recovery_case interrupted-cleanup
PATH="$fault_bin:$PATH" ROLLOVER_TEST_RM="$real_rm" ROLLOVER_TEST_MV="$real_mv" \
  ROLLOVER_TEST_CLEANUP_DEST="$d/.agent-vault-rollover-log.md/record" \
  run_compact "$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md" \
  --rollover-id frozen-id --boundary 'frozen boundary' --anchors 'older work; initial project setup' \
  --require-top-entry 'rollover session'
assert_rc 3 "$COMPACT_RC" 'cleanup failure leaves committed state'
assert_outputs "$d/expected" 'cleanup failure leaves complete outputs'
printf '\n~~~\nUser edit after successful output installation, deliberately unclosed.\n' >>"$d/log.md"
snapshot_outputs "$d/edited"
run_compact "$d/log.md" --recover
assert_rc 0 "$COMPACT_RC" 'committed cleanup succeeds after user edit'
assert_outputs "$d/edited" 'committed cleanup never replays output bytes'
assert_no_transaction_artifacts 'committed cleanup removes metadata'
run_compact "$d/log.md" --recover
assert_rc 0 "$COMPACT_RC" 'second committed cleanup recovery is a no-op'
assert_outputs "$d/edited" 'repeated committed cleanup preserves later edits'
assert_no_transaction_artifacts 'repeated committed cleanup leaves no artifacts'
# The rm wrapper is no longer needed; do not affect later fault fixtures.
rm "$fault_bin/rm"

# Final rmdir can fail AFTER the committed record has been removed. The empty
# residue does not prove completion to a later invocation, but its diagnostic
# should name that benign possibility and the checks needed before manual cleanup.
real_rmdir="$(command -v rmdir)"
cat >"$fault_bin/rmdir" <<'EOF'
#!/usr/bin/env bash
if [[ "${@: -1}" == "${ROLLOVER_TEST_RMDIR_DEST:-}" ]]; then exit 73; fi
exec "$ROLLOVER_TEST_RMDIR" "$@"
EOF
chmod +x "$fault_bin/rmdir"
prepare_recovery_case completed-cleanup-residue
PATH="$fault_bin:$PATH" ROLLOVER_TEST_RMDIR="$real_rmdir" ROLLOVER_TEST_MV="$real_mv" \
  ROLLOVER_TEST_RMDIR_DEST="$d/.agent-vault-rollover-log.md" \
  run_compact "$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md" \
  --rollover-id frozen-id --boundary 'frozen boundary' --anchors 'older work; initial project setup' \
  --require-top-entry 'rollover session'
assert_rc 3 "$COMPACT_RC" 'final rmdir failure reports incomplete cleanup'
assert_outputs "$d/expected" 'final rmdir failure leaves all intended output bytes installed'
assert_not_exists "$d/.agent-vault-rollover-log.md/record" 'committed record was removed before final rmdir failure'
[[ -d "$d/.agent-vault-rollover-log.md" && -z "$(find "$d/.agent-vault-rollover-log.md" -mindepth 1 -print)" ]] || fail 'final rmdir failure should leave an empty transaction directory'
"$checker" "$d/log.md" --archive "$d/archive.md" --manifest "$d/manifest.md" --quiet
for invocation in ordinary recovery recovery-preview; do
  case "$invocation" in
    ordinary) run_compact "$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md" ;;
    recovery) run_compact "$d/log.md" --recover ;;
    recovery-preview) run_compact "$d/log.md" --recover --dry-run ;;
  esac
  assert_rc 3 "$COMPACT_RC" "$invocation still requires confirmation of empty residue"
  assert_contains "$COMPACT_OUT" 'completed rollover whose final cleanup was interrupted' "$invocation diagnostic names completed-rollover residue"
  assert_contains "$COMPACT_OUT" 'check-context-log-rollover.sh' "$invocation diagnostic names the validation check"
  assert_contains "$COMPACT_OUT" 'each intended entry appears exactly once' "$invocation diagnostic requires more than a checker pass"
  assert_contains "$COMPACT_OUT" 'original archive/manifest paths are unknown' "$invocation does not infer the missing destination identities"
  assert_outputs "$d/expected" "$invocation leaves complete outputs untouched"
  [[ -d "$d/.agent-vault-rollover-log.md" ]] || fail "$invocation cleared the empty residue automatically"
done
# Exact-byte comparisons and the checker above confirm this fixture's originals;
# only the fixture owner now removes its confirmed-empty directory.
rmdir "$d/.agent-vault-rollover-log.md"
rm "$fault_bin/rmdir"
run_compact "$d/log.md" --recover
assert_rc 0 "$COMPACT_RC" 'manual removal of confirmed-empty residue unblocks recovery'
assert_no_transaction_artifacts 'confirmed-empty residue cleanup leaves no artifacts'
awk '/^## Entries$/ { print; print ""; print "### 2026-06-01 09:00 local - codex - next rollover session"; print "- New work after cleanup."; next } { print }' \
  "$d/log.md" >"$d/log.next" && mv "$d/log.next" "$d/log.md"
run_compact "$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md" --require-top-entry 'rollover session'
assert_rc 0 "$COMPACT_RC" 'ordinary later rollover succeeds after confirmed-empty cleanup'
[[ "$(count_entries "$d/archive.md")" == 4 ]] || fail 'later rollover duplicated previously installed entries'
[[ "$(grep -c '^## rollover:' "$d/manifest.md")" == 2 ]] || fail 'later rollover duplicated the committed manifest record'
"$checker" "$d/log.md" --archive "$d/archive.md" --manifest "$d/manifest.md" --quiet

for role in archive manifest log; do
  prepare_recovery_case "edited-$role" true
  fault_recovery_case after "$d/archive.md"
  chmod u+w "$d/$role.md"
  printf '\nAn intervening user edit.\n' >>"$d/$role.md"
  snapshot_outputs "$d/edited"
  run_compact "$d/log.md" --recover
  assert_rc 3 "$COMPACT_RC" "refuse edited $role"
  assert_contains "$COMPACT_OUT" 'diverged' "explain edited $role"
  assert_outputs "$d/edited" 'all outputs checked before any recovery write'
done

for damage in missing-payload altered-payload version truncated extra-field outside-stage; do
  prepare_recovery_case "damaged-$damage"
  fault_recovery_case before "$d/archive.md"
  read_test_record
  case "$damage" in
    missing-payload) rm "${record[6]}/archive.md" ;;
    altered-payload) printf '\nchanged payload\n' >>"${record[6]}/archive.md" ;;
    version) record[0]=unrecognized-version ;;
    truncated) printf 'agent-vault-rollover-v1\0ready' >"$d/.agent-vault-rollover-log.md/record" ;;
    extra-field) record+=(unexpected) ;;
    outside-stage)
      record[6]="$tmp_root/precious"
      mkdir -p "$tmp_root/precious"
      printf 'keep\n' >"$tmp_root/precious/archive.md"
      ;;
  esac
  case "$damage" in
    version | extra-field | outside-stage) printf '%s\0' "${record[@]}" >"$d/.agent-vault-rollover-log.md/record" ;;
  esac
  run_compact "$d/log.md" --recover
  assert_rc 3 "$COMPACT_RC" "refuse damaged state: $damage"
  assert_outputs "$d/before" 'damaged record/payload causes no output writes'
  run_compact "$d/log.md" --keep 99 --archive "$d/archive.md" --manifest "$d/manifest.md"
  assert_rc 3 "$COMPACT_RC" 'damaged state does not become a fresh rollover'
done
assert_file_contains "$tmp_root/precious/archive.md" keep 'untrusted staging reference is never cleaned'

# stat emits unpadded octal modes (0, 4, 40) for low permissions. Exercise the
# parser without elevated privileges: a syntactically valid mode must reach the
# independent stage-permission check, not be rejected as a malformed record.
for recorded_mode in 0 4 40 888 00000; do
  prepare_recovery_case "record-mode-$recorded_mode"
  fault_recovery_case before "$d/archive.md"
  read_test_record
  record[7]="$recorded_mode"
  printf '%s\0' "${record[@]}" >"$d/.agent-vault-rollover-log.md/record"
  run_compact "$d/log.md" --recover
  assert_rc 3 "$COMPACT_RC" 'mode fixture refuses without changing actual permissions'
  case "$recorded_mode" in
    0 | 4 | 40) assert_contains "$COMPACT_OUT" 'staged permissions changed' 'unpadded octal mode parses successfully' ;;
    *) assert_contains "$COMPACT_OUT" 'invalid destination record' 'non-octal or oversized mode is rejected' ;;
  esac
  assert_outputs "$d/before" 'mode validation never changes output bytes'
done

# Remove just the journal to model cleanup of ignored state (or an old helper
# with no journal). In both partial states, fallback must refuse, not resume.
for role in archive manifest; do
  prepare_recovery_case "missing-record-$role"
  fault_recovery_case after "$d/$role.md"
  rm "$d/.agent-vault-rollover-log.md/record"
  rmdir "$d/.agent-vault-rollover-log.md"
  snapshot_outputs "$d/partial"
  for retry_keep in 1 2 4 99; do
    run_compact "$d/log.md" --keep "$retry_keep" --archive "$d/archive.md" --manifest "$d/manifest.md" \
      --require-top-entry 'rollover session'
    assert_rc 3 "$COMPACT_RC" 'missing-record fallback cannot be bypassed by keep changes/no-op'
    assert_contains "$COMPACT_OUT" 'reconcile manually' 'missing-record diagnostic'
    assert_outputs "$d/partial" 'missing-record fallback writes nothing'
  done
  run_compact "$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md" \
    --require-top-entry 'rollover session' --adopt-manual-rollover --dry-run
  assert_rc 3 "$COMPACT_RC" 'adoption preview cannot bypass partial-state overlap'
  assert_outputs "$d/partial" 'adoption leaves partial-state outputs untouched'
done

# An empty journal still signals an unknown operation: newly supplied paths
# cannot prove that the ORIGINAL destinations are pristine.
prepare_recovery_case empty-journal-changed-targets
fault_recovery_case after "$d/archive.md"
rm "$d/.agent-vault-rollover-log.md/record"
snapshot_outputs "$d/partial"
run_compact "$d/log.md" --keep 2 --archive "$d/new-archive.md" --manifest "$d/new-manifest.md" \
  --require-top-entry 'rollover session' --dry-run
assert_rc 3 "$COMPACT_RC" 'empty journal must not trust changed destination arguments'
assert_contains "$COMPACT_OUT" 'original archive/manifest paths are unknown' 'incomplete-record diagnostic explains the missing evidence'
assert_outputs "$d/partial" 'empty journal preserves the original partial operation'
# Demonstrate why checking only the supplied destinations is insufficient: with
# the empty marker moved aside, those fresh paths pass the missing-record floor.
mv "$d/.agent-vault-rollover-log.md" "$d/saved-empty-journal"
run_compact "$d/log.md" --keep 2 --archive "$d/new-archive.md" --manifest "$d/new-manifest.md" \
  --require-top-entry 'rollover session' --dry-run
assert_rc 0 "$COMPACT_RC" 'wrong-destination floor alone cannot detect the old partial archive'
run_compact "$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md" \
  --require-top-entry 'rollover session' --dry-run
assert_rc 3 "$COMPACT_RC" 'original destinations still expose the partial archive'
mv "$d/saved-empty-journal" "$d/.agent-vault-rollover-log.md"
assert_outputs "$d/partial" 'diagnostic counterexample changes no output bytes'
assert_not_exists "$d/new-archive.md" 'counterexample preview does not create another archive'

# Last/single-entry overlap exercises the EOF flush, not just heading transitions.
d="$tmp_root/single-entry-overlap"
mkdir -p "$d"
make_log "$d/log.md"
sed -n '/^### 2026-05-26/,$p' "$d/log.md" >"$d/archive.md"
run_compact "$d/log.md" --keep 99 --archive "$d/archive.md" --manifest "$d/manifest.md"
assert_rc 3 "$COMPACT_RC" 'one-entry overlap at archive EOF refuses before no-op'

d="$tmp_root/heading-collision"
mkdir -p "$d"
make_log "$d/log.md"
printf '# Context Log Archive\n\n### 2026-05-28 10:00 local - codex - older work\n- A different body, not the same entry.\n' >"$d/archive.md"
run_compact "$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md" --require-top-entry 'rollover session'
assert_rc 0 "$COMPACT_RC" 'same heading with different bodies is not overlap'

# Full destination preflight also covers special files, aliases, and hierarchy.
for unsafe in symlink fifo hardlink parent; do
  d="$tmp_root/unsafe-$unsafe"
  mkdir -p "$d"
  make_log "$d/log.md"
  case "$unsafe" in
    symlink) ln -s "$d/log.md" "$d/archive.md" ;;
    fifo) mkfifo "$d/archive.md" ;;
    hardlink) ln "$d/log.md" "$d/archive.md" ;;
    parent) : ;;
  esac
  unsafe_manifest="$d/manifest.md"
  [[ "$unsafe" != parent ]] || unsafe_manifest="$d/archive.md/manifest.md"
  before="$(cksum <"$d/log.md")"
  run_compact "$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$unsafe_manifest" --require-top-entry 'rollover session'
  assert_rc 2 "$COMPACT_RC" "unsafe destination: $unsafe"
  [[ "$(cksum <"$d/log.md")" == "$before" ]] || fail 'unsafe destination changed live log'
done

prepare_recovery_case 'spaces $literal; [brackets] and\backslash'
fault_recovery_case after "$d/archive.md"
assert_rc 3 "$COMPACT_RC" 'literal shell metacharacters in destination paths'
run_compact "$d/log.md" --keep 99 --archive "$d/archive.md" --manifest "$d/manifest.md"
assert_rc 3 "$COMPACT_RC" 'literal destination ordinary retry requires recovery'
printf -v expected_command '%q %q --recover' "$compactor" "$d/log.md"
assert_contains "$COMPACT_OUT" "run $expected_command before" 'recovery guidance quotes literal shell metacharacters'
run_compact "$d/log.md" --recover
assert_rc 0 "$COMPACT_RC" 'recover literal destination paths'
assert_outputs "$d/expected" 'literal destination bytes'

# Every candidate copy must succeed before the first output replacement. Existing
# outputs (including a read-only manifest) are unchanged on a late staging error.
real_cp="$(command -v cp)"
cat >"$fault_bin/cp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination="${@: -1}"
if [[ "$destination" == */.agent-vault-rollover-stage.* && "${destination##*/}" == "$ROLLOVER_TEST_COPY_FILE" ]]; then
  if [[ "$ROLLOVER_TEST_COPY_FAULT" == fail ]]; then exit 73; fi
  "$ROLLOVER_TEST_CP" "$@"
  printf '\ncorrupted staged copy\n' >>"$destination"
else
  exec "$ROLLOVER_TEST_CP" "$@"
fi
EOF
chmod +x "$fault_bin/cp"
for role in archive manifest log; do
  for copy_fault in fail corrupt; do
    prepare_recovery_case "stage-$copy_fault-$role" true
    PATH="$fault_bin:$PATH" ROLLOVER_TEST_MV="$real_mv" ROLLOVER_TEST_CP="$real_cp" \
      ROLLOVER_TEST_COPY_FILE="$role.md" ROLLOVER_TEST_COPY_FAULT="$copy_fault" \
      run_compact "$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md" --require-top-entry 'rollover session'
    assert_rc 2 "$COMPACT_RC" 'staging failure/corruption is a no-output IO failure'
    assert_outputs "$d/before" 'all originals unchanged when staging fails'
    assert_no_transaction_artifacts 'preparation cleans its own staging data'
  done
done
rm "$fault_bin/cp"

# An empty journal is ambiguous: it can also be a deleted ready record. Do not
# claim successful recovery or discard the remaining evidence automatically.
prepare_recovery_case empty-journal
mkdir "$d/.agent-vault-rollover-log.md"
run_compact "$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md" --require-top-entry 'rollover session'
assert_rc 3 "$COMPACT_RC" 'empty journal on pristine outputs still requires original-path confirmation'
assert_contains "$COMPACT_OUT" 'original archive/manifest paths are unknown' 'normal empty-journal diagnostic is actionable, not a recover loop'
run_compact "$d/log.md" --recover --dry-run
assert_rc 3 "$COMPACT_RC" 'empty journal preview refuses to guess'
[[ -d "$d/.agent-vault-rollover-log.md" ]] || fail 'dry-run removed empty journal'
run_compact "$d/log.md" --recover
assert_rc 3 "$COMPACT_RC" 'empty journal requires inspection'
assert_outputs "$d/before" 'empty journal never replaces outputs'
printf 'unfinished metadata\n' >"$d/.agent-vault-rollover-log.md/record.next"
run_compact "$d/log.md" --recover
assert_rc 3 "$COMPACT_RC" 'incomplete nonempty journal requires inspection'
assert_file_contains "$d/.agent-vault-rollover-log.md/record.next" 'unfinished metadata' 'incomplete data preserved'

# The helper must not follow a malicious record.next symlink on ready->committed.
prepare_recovery_case unsafe-next-record
fault_recovery_case before "$d/archive.md"
printf 'precious\n' >"$d/precious"
ln -s "$d/precious" "$d/.agent-vault-rollover-log.md/record.next"
run_compact "$d/log.md" --recover
assert_rc 3 "$COMPACT_RC" 'unsafe next-record path refuses'
assert_file_contains "$d/precious" precious 'record writer did not follow symlink'
assert_outputs "$d/before" 'unsafe metadata refuses before output replacement'

# A genuinely new annual archive is compatible with a consistent OLD pointer
# and manifest. The safety floor must not validate the old record against it.
prepare_recovery_case annual-archive
run_compact "$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md" --require-top-entry 'rollover session'
assert_rc 0 "$COMPACT_RC" 'initial annual-archive rollover'
awk '/^## Entries$/ { print; print ""; print "### 2027-01-01 09:00 local - codex - new rollover session"; print "- New work."; next } { print }' \
  "$d/log.md" >"$d/log.next" && mv "$d/log.next" "$d/log.md"
cp "$d/archive.md" "$d/prior-archive.md"
run_compact "$d/log.md" --keep 1 --archive "$d/next-year/archive.md" --manifest "$d/manifest.md" --require-top-entry 'rollover session'
assert_rc 0 "$COMPACT_RC" 'new annual archive does not spuriously look inconsistent'
cmp -s "$d/archive.md" "$d/prior-archive.md" || fail 'annual rollover touched previous archive'

prepare_recovery_case missing-manifest
run_compact "$d/log.md" --keep 2 --archive "$d/archive.md" --manifest "$d/manifest.md" --require-top-entry 'rollover session'
rm "$d/manifest.md"
run_compact "$d/log.md" --keep 99 --archive "$d/archive.md" --manifest "$d/manifest.md"
assert_rc 3 "$COMPACT_RC" 'missing manifest with a live pointer refuses before no-op'

# Adoption cannot discard an existing inconsistent manifest, even during preview.
cp "$d/expected/manifest.md" "$d/manifest.md"
for preview in false true; do
  adoption_args=("$d/log.md" --keep 1 --archive "$d/archive.md" --manifest "$d/manifest.md" --adopt-manual-rollover --require-top-entry 'rollover session')
  [[ "$preview" != true ]] || adoption_args+=(--dry-run)
  run_compact "${adoption_args[@]}"
  assert_rc 3 "$COMPACT_RC" 'adoption does not bypass mismatched existing pointer/manifest'
done
run_compact "$d/log.md" --recover --adopt-manual-rollover
assert_rc 2 "$COMPACT_RC" 'recovery rejects adoption generation options'

d="$tmp_root/private-dry-run"
mkdir -p "$d"
make_log "$d/log.md"
run_compact "$d/log.md" --keep 2 --archive "$d/new/a/archive.md" --manifest "$d/new/b/manifest.md" --require-top-entry 'rollover session' --dry-run
assert_rc 0 "$COMPACT_RC" 'dry-run validates nested missing destinations'
assert_not_exists "$d/new" 'dry-run does not create destination parents'
assert_no_transaction_artifacts 'dry-run does not create recovery state'

echo "compact-context-log compactor regression checks passed ($pass assertions)."

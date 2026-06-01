#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
compactor="$repo_root/scaffold/root/scripts/compact-context-log.sh"
checker="$repo_root/scaffold/root/scripts/check-context-log-rollover.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-compact-test.XXXXXX")"

cleanup() { rm -rf "$tmp_root"; }
trap cleanup EXIT

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

# Count dated entry headings in a file (### or compact ## with a leading date).
count_entries() {
  awk '
    /^(```|~~~)/ { f = !f; next }
    { if (f) next; l = $0; sub(/\r$/, "", l)
      if (l !~ /^#+[[:space:]]/) next
      sub(/^#+[[:space:]]+/, "", l)
      if (l ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) c++ }
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

# --- 7. Self-validation failure aborts with zero writes -------------------
# An archived entry carrying a top-level "## Next Prompt" would orphan in the
# archive; the checker rejects it, so the compactor must abort and write nothing.
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
- This orphan top-level heading rides along into the archive.
EOF
before="$(cksum "$d/log.md")"
run_compact "$d/log.md" --keep 1 --archive "$d/archive/context-log-2026.md" \
  --manifest "$d/archive/manifest.md" --rollover-id x --require-top-entry "kept entry"
assert_rc 1 "$COMPACT_RC" "self-validation failure aborts"
assert_contains "$COMPACT_OUT" "failed check-context-log-rollover.sh" "self-validation message"
[[ "$(cksum "$d/log.md")" == "$before" ]] || fail "selfval: live log must be unchanged on abort"
pass=$((pass + 1))
assert_not_exists "$d/archive/context-log-2026.md" "selfval: no archive written on abort"

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
today="$(date +%Y-%m-%d)"
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

echo "compact-context-log compactor regression checks passed ($pass assertions)."

#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
checker="$repo_root/scaffold/root/scripts/check-context-log-rollover.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-rollover-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp_root"
}

trap cleanup EXIT

# expect_result <expected_exit> <must_contain|""> <checker args...>
expect_result() {
  local expected_rc="$1"
  local must_contain="$2"
  shift 2
  local output rc

  set +e
  output="$("$checker" "$@" 2>&1)"
  rc=$?
  set -e

  if [[ "$rc" -ne "$expected_rc" ]]; then
    echo "FAIL: expected exit $expected_rc, got $rc for: $*" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  if [[ -n "$must_contain" && "$output" != *"$must_contain"* ]]; then
    echo "FAIL: output missing '$must_contain' for: $*" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

# --- Fixtures ------------------------------------------------------------

# Canonical, healthy log. Exercises tolerance of mixed entry heading styles
# (### and compact ##, em-dash variants) and a valid latest-handoff pointer.
cat >"$tmp_root/good-live.md" <<'EOF'
---
type: context-log
project: fixture
last_updated: 2026-05-30
---

# Context Log

## Usage Rules
- Newest entry at top.

## Current Snapshot
- Project: fixture
- Active branch: `main`
- Latest handoff: `agent-vault/context/handoffs/2026-05-30-0900-a-to-b-topic.md`
- Last updated: 2026-05-30

## Entries

### 2026-05-30 09:00 local - agent - recent work
#### State
- Did the thing.

## 2026-05-20 - agent — compact legacy entry
- Older compact-style entry with an em-dash heading.
EOF

# Same as good, with no handoff pointer at all (conditional check must skip).
cat >"$tmp_root/no-handoff-live.md" <<'EOF'
# Context Log

## Usage Rules
- Newest entry at top.

## Current Snapshot
- Project: fixture
- Active branch: `main`

## Entries

### 2026-05-30 09:00 local - agent - recent work
- Body.
EOF

# Stale duplicate "## Current Snapshot" -- the core bug.
cat >"$tmp_root/dup-snapshot-live.md" <<'EOF'
# Context Log

## Usage Rules
- Newest entry at top.

## Current Snapshot
- Active branch: `main`

## Entries

### 2026-05-30 09:00 local - agent - recent work
- Body.

## Current Snapshot
- Active branch: `old-stale-branch`
EOF

# Duplicate "## Usage Rules" from un-rolled stale content (NOT mere presence:
# the canonical log has exactly one Usage Rules block).
cat >"$tmp_root/dup-usage-rules-live.md" <<'EOF'
# Context Log

## Usage Rules
- Newest entry at top.

## Current Snapshot
- Active branch: `main`

## Entries

### 2026-05-30 09:00 local - agent - recent work
- Body.

## Usage Rules
- Leftover duplicate from an un-rolled lower half.
EOF

# Leftover Git conflict markers.
cat >"$tmp_root/conflict-live.md" <<'EOF'
# Context Log

## Usage Rules
- Newest entry at top.

## Current Snapshot
<<<<<<< HEAD
- Active branch: `main`
=======
- Active branch: `other`
>>>>>>> other

## Entries

### 2026-05-30 09:00 local - agent - recent work
- Body.
EOF

# Leftover "=======" separator only (other conflict sides removed in a bad cleanup).
cat >"$tmp_root/separator-conflict-live.md" <<'EOF'
# Context Log

## Usage Rules
- Newest entry at top.

## Current Snapshot
- Active branch: `main`
=======

## Entries

### 2026-05-30 09:00 local - agent - recent work
- Body.
EOF

# Declared latest-handoff pointer with no value.
cat >"$tmp_root/empty-handoff-live.md" <<'EOF'
# Context Log

## Usage Rules
- Newest entry at top.

## Current Snapshot
- Active branch: `main`
- Latest handoff:
- Last updated: 2026-05-30

## Entries

### 2026-05-30 09:00 local - agent - recent work
- Body.
EOF

# Missing "## Entries".
cat >"$tmp_root/missing-entries-live.md" <<'EOF'
# Context Log

## Usage Rules
- Newest entry at top.

## Current Snapshot
- Active branch: `main`
EOF

# Archive with a properly superseded snapshot.
cat >"$tmp_root/archive-superseded.md" <<'EOF'
# Context Log Archive (2026)

## Current Snapshot — SUPERSEDED (archived 2026-05-30; see live log for current state)
- Active branch: `old-branch`

### 2026-03-01 09:00 local - agent - old work
- Body.
EOF

# Archive with an unlabeled snapshot that can read as active.
cat >"$tmp_root/archive-unlabeled.md" <<'EOF'
# Context Log Archive (2026)

## Current Snapshot
- Active branch: `old-branch`

### 2026-03-01 09:00 local - agent - old work
- Body.
EOF

# --- Assertions ----------------------------------------------------------

# Healthy logs pass.
expect_result 0 "passed" "$tmp_root/good-live.md"
expect_result 0 "passed" "$tmp_root/no-handoff-live.md"

# Structural defects fail with actionable findings.
expect_result 1 'duplicate "## Current Snapshot"' "$tmp_root/dup-snapshot-live.md"
expect_result 1 'duplicate "## Usage Rules"' "$tmp_root/dup-usage-rules-live.md"
expect_result 1 "Git conflict markers" "$tmp_root/conflict-live.md"
expect_result 1 "Git conflict markers" "$tmp_root/separator-conflict-live.md"
expect_result 1 "latest-handoff pointer" "$tmp_root/empty-handoff-live.md"
expect_result 1 'missing "## Entries"' "$tmp_root/missing-entries-live.md"

# Archive superseded labeling.
expect_result 0 "passed" "$tmp_root/good-live.md" --archive "$tmp_root/archive-superseded.md"
expect_result 1 "not labeled superseded" "$tmp_root/good-live.md" --archive "$tmp_root/archive-unlabeled.md"

# Usage / IO errors.
expect_result 2 "context log not found" "$tmp_root/does-not-exist.md"
expect_result 2 "" --quiet

# diff3 base marker (|||||||) is a conflict.
cat >"$tmp_root/diff3-live.md" <<'EOF'
# Context Log

## Usage Rules
- x

## Current Snapshot
- a

## Entries

### 2026-05-30 09:00 local - a - b
||||||| base
- c
EOF
expect_result 1 "Git conflict markers" "$tmp_root/diff3-live.md"

# Fence-aware: a snapshot heading and a conflict marker quoted inside a fenced
# code block are ignored (no false failure).
cat >"$tmp_root/fenced-live.md" <<'EOF'
# Context Log

## Usage Rules
- x

## Current Snapshot
- a

## Entries

### 2026-05-30 09:00 local - a - b
Example of the stale-snapshot bug:
```
## Current Snapshot
=======
```
- c
EOF
expect_result 0 "passed" "$tmp_root/fenced-live.md"

# Exact heading anchor: a distinct section sharing a name prefix is not a duplicate.
cat >"$tmp_root/distinct-heading-live.md" <<'EOF'
# Context Log

## Usage Rules
- x

## Current Snapshot
- a

## Entries

### 2026-05-30 09:00 local - a - b
- c

## Current Snapshot Format Notes
- doc
EOF
expect_result 0 "passed" "$tmp_root/distinct-heading-live.md"

# A bolded but empty handoff pointer is flagged.
cat >"$tmp_root/bold-handoff-live.md" <<'EOF'
# Context Log

## Usage Rules
- x

## Current Snapshot
- **Latest handoff:**

## Entries

### 2026-05-30 09:00 local - a - b
- c
EOF
expect_result 1 "latest-handoff pointer" "$tmp_root/bold-handoff-live.md"

# require_exactly_one matrix: missing snapshot, missing usage rules, duplicate entries.
cat >"$tmp_root/missing-snapshot-live.md" <<'EOF'
# Context Log

## Usage Rules
- x

## Entries

### 2026-05-30 09:00 local - a - b
- c
EOF
expect_result 1 'missing "## Current Snapshot"' "$tmp_root/missing-snapshot-live.md"

cat >"$tmp_root/missing-usage-live.md" <<'EOF'
# Context Log

## Current Snapshot
- a

## Entries

### 2026-05-30 09:00 local - a - b
- c
EOF
expect_result 1 'missing "## Usage Rules"' "$tmp_root/missing-usage-live.md"

cat >"$tmp_root/dup-entries-live.md" <<'EOF'
# Context Log

## Usage Rules
- x

## Current Snapshot
- a

## Entries

### 2026-05-30 09:00 local - a - b
- c

## Entries
- leftover
EOF
expect_result 1 'duplicate "## Entries"' "$tmp_root/dup-entries-live.md"

# CRLF: a CRLF-terminated good log passes (CR is tolerated).
sed 's/$/\r/' "$tmp_root/good-live.md" >"$tmp_root/good-crlf-live.md"
expect_result 0 "passed" "$tmp_root/good-crlf-live.md"

# Archive: a body mention of "superseded" does NOT label the heading.
cat >"$tmp_root/archive-body-mention.md" <<'EOF'
# Context Log Archive (2026)

## Current Snapshot
- This work was later superseded by a newer plan.

### 2026-03-01 09:00 local - a - b
- c
EOF
expect_result 1 "not labeled superseded" "$tmp_root/good-live.md" --archive "$tmp_root/archive-body-mention.md"

# --quiet suppresses success output but never suppresses failures.
quiet_out="$("$checker" "$tmp_root/good-live.md" --quiet 2>&1)"
[[ -z "$quiet_out" ]] || {
  echo "FAIL: --quiet should print nothing on success; got: $quiet_out" >&2
  exit 1
}
set +e
quiet_fail="$("$checker" "$tmp_root/dup-snapshot-live.md" --quiet 2>&1)"
quiet_fail_rc=$?
set -e
[[ "$quiet_fail_rc" -eq 1 && -n "$quiet_fail" ]] || {
  echo "FAIL: --quiet must still report failures" >&2
  exit 1
}

# --- Layer-2: rollover manifest assertions (--manifest) ------------------

# A good archive: superseded snapshot + dated entries, newest first. The newest
# entry carries a *nested* "#### Next Prompt" (legal -- must NOT be flagged).
cat >"$tmp_root/context-log-2026.md" <<'EOF'
# Context Log Archive (2026)

## Current Snapshot — SUPERSEDED (archived 2026-05-30; see live log for current state)
- Active branch: `old-branch`

### 2026-05-29 17:00 local - claude - PR-A net-of-excepted shipped
#### State
- Implemented net-of-excepted chain budget.
#### Next Prompt
- Continue with PR-B2 (rollover Layer-2).

### 2026-03-15 09:00 local - codex - mid-window work
- Body.

### 2026-01-04 09:00 local - bootstrap - initial project setup
- Body.
EOF

# A live log whose Current Snapshot carries a rollover pointer back to the manifest.
cat >"$tmp_root/good-rollover-live.md" <<'EOF'
# Context Log

## Usage Rules
- Newest entry at top.

## Current Snapshot
- Active branch: `main`
- Context-log rollover: `2026-05-29-1` — boundary: through PR-A net-of-excepted (recent-window top before rollover)
- Last updated: 2026-05-30

## Entries

### 2026-05-30 09:00 local - claude - recent work
- Body.
EOF

# The matching manifest: newest record first, claims consistent with the archive.
cat >"$tmp_root/manifest-good.md" <<'EOF'
# Context Log Rollover Manifest

<!-- One record per rollover, newest first. Validated by check-context-log-rollover.sh --manifest. -->

## rollover: 2026-05-29-1
- archive_file: agent-vault/context/archive/context-log-2026.md
- boundary: through PR-A net-of-excepted (recent-window top before rollover)
- newest_archived: 2026-05-29 17:00 local - claude - PR-A net-of-excepted shipped
- oldest_archived: 2026-01-04 09:00 local - bootstrap - initial project setup
- kept: 5
- archived: 3
- anchors: net-of-excepted; initial project setup
EOF

# Healthy rollover: pointer, manifest, and archive all agree.
expect_result 0 "passed" "$tmp_root/good-rollover-live.md" \
  --archive "$tmp_root/context-log-2026.md" --manifest "$tmp_root/manifest-good.md"

# The nested "#### Next Prompt" in the archive is legal and not flagged as orphan.
out_healthy="$("$checker" "$tmp_root/good-rollover-live.md" --archive "$tmp_root/context-log-2026.md" --manifest "$tmp_root/manifest-good.md" 2>&1)"
[[ "$out_healthy" != *"orphaned"* ]] || {
  echo "FAIL: nested Next Prompt should not be flagged as orphan; got: $out_healthy" >&2
  exit 1
}

# Manifest resolves its own archive (no --archive) when co-located by basename.
mkdir -p "$tmp_root/co"
cp "$tmp_root/context-log-2026.md" "$tmp_root/co/context-log-2026.md"
cp "$tmp_root/manifest-good.md" "$tmp_root/co/manifest.md"
expect_result 0 "passed" "$tmp_root/good-rollover-live.md" --manifest "$tmp_root/co/manifest.md"

# Scaffolded manifest with no records + a live log with no pointer = "no rollover
# yet" and passes; structural checks still run.
cat >"$tmp_root/manifest-empty.md" <<'EOF'
# Context Log Rollover Manifest

(No rollovers yet.)
EOF
expect_result 0 "passed" "$tmp_root/no-handoff-live.md" --manifest "$tmp_root/manifest-empty.md"

# A live pointer with no backing manifest record is a defect.
expect_result 1 "manifest has no records" "$tmp_root/good-rollover-live.md" --manifest "$tmp_root/manifest-empty.md"

# Manifest present but the live Current Snapshot has no rollover pointer.
expect_result 1 'declares no "Context-log rollover" pointer' \
  "$tmp_root/no-handoff-live.md" --archive "$tmp_root/context-log-2026.md" --manifest "$tmp_root/manifest-good.md"

# Pointer id does not match the newest manifest record.
cat >"$tmp_root/bad-id-live.md" <<'EOF'
# Context Log

## Usage Rules
- x

## Current Snapshot
- Context-log rollover: `2099-12-31-9` — boundary: through PR-A net-of-excepted (recent-window top before rollover)

## Entries

### 2026-05-30 09:00 local - a - b
- c
EOF
expect_result 1 "does not match newest manifest record" \
  "$tmp_root/bad-id-live.md" --archive "$tmp_root/context-log-2026.md" --manifest "$tmp_root/manifest-good.md"

# Pointer boundary text does not match the manifest boundary (the cite-then-mutate
# drift, caught at the pointer layer).
cat >"$tmp_root/bad-boundary-live.md" <<'EOF'
# Context Log

## Usage Rules
- x

## Current Snapshot
- Context-log rollover: `2026-05-29-1` — boundary: an entirely different boundary description

## Entries

### 2026-05-30 09:00 local - a - b
- c
EOF
expect_result 1 "boundary does not match the manifest boundary" \
  "$tmp_root/bad-boundary-live.md" --archive "$tmp_root/context-log-2026.md" --manifest "$tmp_root/manifest-good.md"

# A rollover pointer with no "boundary:" value is flagged.
cat >"$tmp_root/no-boundary-live.md" <<'EOF'
# Context Log

## Usage Rules
- x

## Current Snapshot
- Context-log rollover: `2026-05-29-1`

## Entries

### 2026-05-30 09:00 local - a - b
- c
EOF
expect_result 1 'declares no "boundary:" value' \
  "$tmp_root/no-boundary-live.md" --archive "$tmp_root/context-log-2026.md" --manifest "$tmp_root/manifest-good.md"

# newest_archived is NOT the actual newest entry -- the core cite-then-mutate
# mechanical catch. Same id/boundary as the good pointer to isolate this finding.
cat >"$tmp_root/manifest-stale-newest.md" <<'EOF'
# Context Log Rollover Manifest

## rollover: 2026-05-29-1
- archive_file: agent-vault/context/archive/context-log-2026.md
- boundary: through PR-A net-of-excepted (recent-window top before rollover)
- newest_archived: 2026-03-15 09:00 local - codex - mid-window work
- oldest_archived: 2026-01-04 09:00 local - bootstrap - initial project setup
- anchors: net-of-excepted
EOF
expect_result 1 "is not the newest entry in the archive" \
  "$tmp_root/good-rollover-live.md" --archive "$tmp_root/context-log-2026.md" --manifest "$tmp_root/manifest-stale-newest.md"

# newest_archived names a heading absent from the archive.
cat >"$tmp_root/manifest-missing-newest.md" <<'EOF'
# Context Log Rollover Manifest

## rollover: 2026-05-29-1
- archive_file: agent-vault/context/archive/context-log-2026.md
- boundary: through PR-A net-of-excepted (recent-window top before rollover)
- newest_archived: 2026-05-29 17:00 local - claude - a heading that was never archived
- oldest_archived: 2026-01-04 09:00 local - bootstrap - initial project setup
EOF
expect_result 1 "newest_archived heading not found in the archive" \
  "$tmp_root/good-rollover-live.md" --archive "$tmp_root/context-log-2026.md" --manifest "$tmp_root/manifest-missing-newest.md"

# oldest_archived names a heading absent from the archive.
cat >"$tmp_root/manifest-missing-oldest.md" <<'EOF'
# Context Log Rollover Manifest

## rollover: 2026-05-29-1
- archive_file: agent-vault/context/archive/context-log-2026.md
- boundary: through PR-A net-of-excepted (recent-window top before rollover)
- newest_archived: 2026-05-29 17:00 local - claude - PR-A net-of-excepted shipped
- oldest_archived: 2025-01-01 00:00 local - nobody - never archived
EOF
expect_result 1 "oldest_archived heading not found in the archive" \
  "$tmp_root/good-rollover-live.md" --archive "$tmp_root/context-log-2026.md" --manifest "$tmp_root/manifest-missing-oldest.md"

# A representative anchor is absent from the archive.
cat >"$tmp_root/manifest-bad-anchor.md" <<'EOF'
# Context Log Rollover Manifest

## rollover: 2026-05-29-1
- archive_file: agent-vault/context/archive/context-log-2026.md
- boundary: through PR-A net-of-excepted (recent-window top before rollover)
- newest_archived: 2026-05-29 17:00 local - claude - PR-A net-of-excepted shipped
- oldest_archived: 2026-01-04 09:00 local - bootstrap - initial project setup
- anchors: net-of-excepted; this-anchor-string-is-nowhere-in-the-archive
EOF
expect_result 1 "anchor not found in the archive" \
  "$tmp_root/good-rollover-live.md" --archive "$tmp_root/context-log-2026.md" --manifest "$tmp_root/manifest-bad-anchor.md"

# A required manifest field is missing.
cat >"$tmp_root/manifest-missing-field.md" <<'EOF'
# Context Log Rollover Manifest

## rollover: 2026-05-29-1
- archive_file: agent-vault/context/archive/context-log-2026.md
- newest_archived: 2026-05-29 17:00 local - claude - PR-A net-of-excepted shipped
- oldest_archived: 2026-01-04 09:00 local - bootstrap - initial project setup
EOF
expect_result 1 "missing required field: boundary" \
  "$tmp_root/good-rollover-live.md" --archive "$tmp_root/context-log-2026.md" --manifest "$tmp_root/manifest-missing-field.md"

# An orphaned top-level "Next Prompt" survives in the archive.
cat >"$tmp_root/context-log-orphan.md" <<'EOF'
# Context Log Archive (2026)

## Current Snapshot — SUPERSEDED (archived 2026-05-30)
- Active branch: `old-branch`

### 2026-05-29 17:00 local - claude - PR-A net-of-excepted shipped
- Body.

### 2026-01-04 09:00 local - bootstrap - initial project setup
- Body.

## Suggested Next Prompt
- Continue the work.
EOF
cat >"$tmp_root/manifest-orphan.md" <<'EOF'
# Context Log Rollover Manifest

## rollover: 2026-05-29-1
- archive_file: agent-vault/context/archive/context-log-orphan.md
- boundary: through PR-A net-of-excepted (recent-window top before rollover)
- newest_archived: 2026-05-29 17:00 local - claude - PR-A net-of-excepted shipped
- oldest_archived: 2026-01-04 09:00 local - bootstrap - initial project setup
EOF
expect_result 1 'orphaned top-level "Next Prompt"' \
  "$tmp_root/good-rollover-live.md" --archive "$tmp_root/context-log-orphan.md" --manifest "$tmp_root/manifest-orphan.md"

# Manifest archive_file basename disagrees with an explicit --archive.
cat >"$tmp_root/manifest-altarchive.md" <<'EOF'
# Context Log Rollover Manifest

## rollover: 2026-05-29-1
- archive_file: agent-vault/context/archive/context-log-2025.md
- boundary: through PR-A net-of-excepted (recent-window top before rollover)
- newest_archived: 2026-05-29 17:00 local - claude - PR-A net-of-excepted shipped
- oldest_archived: 2026-01-04 09:00 local - bootstrap - initial project setup
EOF
expect_result 1 "does not match --archive" \
  "$tmp_root/good-rollover-live.md" --archive "$tmp_root/context-log-2026.md" --manifest "$tmp_root/manifest-altarchive.md"

# Manifest names an archive that cannot be located next to it (no --archive).
cat >"$tmp_root/manifest-lonely.md" <<'EOF'
# Context Log Rollover Manifest

## rollover: 2026-05-29-1
- archive_file: agent-vault/context/archive/context-log-missing.md
- boundary: through PR-A net-of-excepted (recent-window top before rollover)
- newest_archived: 2026-05-29 17:00 local - claude - PR-A net-of-excepted shipped
- oldest_archived: 2026-01-04 09:00 local - bootstrap - initial project setup
EOF
expect_result 1 "was not found next to the manifest" \
  "$tmp_root/good-rollover-live.md" --manifest "$tmp_root/manifest-lonely.md"

# A missing manifest file is an IO error.
expect_result 2 "manifest file not found" \
  "$tmp_root/good-rollover-live.md" --manifest "$tmp_root/does-not-exist-manifest.md"

# CRLF manifest + live log still validate (CR tolerated on both sides).
sed 's/$/\r/' "$tmp_root/good-rollover-live.md" >"$tmp_root/good-rollover-crlf-live.md"
sed 's/$/\r/' "$tmp_root/manifest-good.md" >"$tmp_root/manifest-good-crlf.md"
expect_result 0 "passed" "$tmp_root/good-rollover-crlf-live.md" \
  --archive "$tmp_root/context-log-2026.md" --manifest "$tmp_root/manifest-good-crlf.md"

echo "context-log rollover checker regression checks passed."

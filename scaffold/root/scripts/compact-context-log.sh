#!/usr/bin/env bash
# agent-vault-managed: helper-script; file=compact-context-log.sh

set -euo pipefail

# Roll over agent-vault/context-log.md: keep the single Current Snapshot plus the
# most recent --keep entries, move older entries into a dated archive, update the
# live "Context-log rollover" pointer, and prepend a record to the rollover
# manifest. This is the automation behind the manual rollover convention; prose
# memory files (project-context.md, lessons.md, ...) deliberately stay agent-
# driven and are out of scope here.
#
# Contract (so a half-finished rollover can never land):
#   - It does NOT invent the gate-required rollover session entry. The caller adds
#     that entry first (the metadata gate), then runs this; --require-top-entry
#     asserts it is the newest entry and aborts with zero writes if it is not.
#   - Counts and the boundary are finalized AFTER that entry is in place, from the
#     live file as it stands, so they cannot describe a pre-entry state.
#   - Everything is built and SELF-VALIDATED with check-context-log-rollover.sh
#     --manifest before anything is written; on any precondition or validation
#     failure it aborts non-zero having written nothing.
#   - Each destination is replaced by an atomic rename of a fully-formed temp file
#     in the same directory; the live log is written last so a crash mid-commit
#     never loses entries (worst case leaves an un-pointed manifest record).
#
# Exit status: 0 = rolled over (or nothing to roll over), 1 = precondition or
# self-validation failure (no writes), 2 = usage or IO error.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
checker="$here/check-context-log-rollover.sh"

usage() {
  cat <<EOF
Usage: $0 <context-log-file> --keep <N> --archive <file> --manifest <file>
          [--rollover-id <id>] [--boundary <text>] [--anchors "<a>; <b>"]
          [--require-top-entry <substring>] [--dry-run] [--quiet]

Keeps the Current Snapshot plus the newest <N> entries in the live log and moves
older entries into <archive>, newest-at-top. Writes the live rollover pointer and
prepends a record to <manifest>; the result must pass:

  check-context-log-rollover.sh <log> --archive <archive> --manifest <manifest>

Options:
  --keep <N>                 Entries to keep live (>=1; the newest, snapshot aside).
  --archive <file>           Dated archive to grow (created if missing).
  --manifest <file>          Rollover manifest to prepend to (created if missing).
  --rollover-id <id>         Manifest/pointer id (default: <YYYY-MM-DD>-<seq>).
  --boundary <text>          Boundary description (default: "through <topic>").
  --anchors "<a>; <b>"       Representative anchors (default: derived from the
                             moved entries; each must appear in the archive).
  --require-top-entry <str>  Abort unless the newest entry heading contains <str>
                             (assert the gate-required rollover entry is present).
                             Required for any write unless --allow-missing-top-entry.
  --allow-missing-top-entry  Explicit escape hatch: roll over without asserting the
                             gate-required session entry. Use only when verified.
  --dry-run                  Build and self-validate, print a summary, write nothing.
  --quiet                    Print only on failure / a one-line success.
  -h, --help                 Show this help.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 2
}

abort() {
  echo "Aborted (no changes written): $*" >&2
  exit 1
}

context_log=""
keep=""
archive_file=""
manifest_file=""
rollover_id=""
boundary=""
anchors=""
require_top_entry=""
allow_missing_top_entry="false"
dry_run="false"
quiet="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)
      [[ $# -ge 2 ]] || die "--keep requires a value"
      keep="$2"
      shift 2
      ;;
    --archive)
      [[ $# -ge 2 ]] || die "--archive requires a path"
      archive_file="$2"
      shift 2
      ;;
    --manifest)
      [[ $# -ge 2 ]] || die "--manifest requires a path"
      manifest_file="$2"
      shift 2
      ;;
    --rollover-id)
      [[ $# -ge 2 ]] || die "--rollover-id requires a value"
      rollover_id="$2"
      shift 2
      ;;
    --boundary)
      [[ $# -ge 2 ]] || die "--boundary requires a value"
      boundary="$2"
      shift 2
      ;;
    --anchors)
      [[ $# -ge 2 ]] || die "--anchors requires a value"
      anchors="$2"
      shift 2
      ;;
    --require-top-entry)
      [[ $# -ge 2 ]] || die "--require-top-entry requires a value"
      require_top_entry="$2"
      shift 2
      ;;
    --allow-missing-top-entry)
      allow_missing_top_entry="true"
      shift
      ;;
    --dry-run)
      dry_run="true"
      shift
      ;;
    --quiet)
      quiet="true"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      [[ -z "$context_log" ]] || die "unexpected extra argument: $1"
      context_log="$1"
      shift
      ;;
  esac
done

[[ -n "$context_log" ]] || {
  usage >&2
  exit 2
}
[[ -f "$context_log" ]] || die "context log not found: $context_log"
[[ -n "$keep" ]] || die "--keep is required"
[[ "$keep" =~ ^[0-9]+$ ]] || die "--keep must be a non-negative integer, got: $keep"
[[ "$keep" -ge 1 ]] || die "--keep must be >= 1 (the newest entry is always kept)"
[[ -n "$archive_file" ]] || die "--archive is required"
[[ -n "$manifest_file" ]] || die "--manifest is required"
[[ -x "$checker" || -f "$checker" ]] || die "checker not found next to this script: $checker"

# --- small helpers -------------------------------------------------------

# Strip trailing blank lines from a file in place.
strip_trailing_blanks() {
  awk 'BEGIN { blanks = 0 }
    { for (; blanks > 0; blanks--) print ""; if ($0 ~ /^[[:space:]]*$/) { blanks++; next } print }
  ' "$1"
}

# Entry-heading line numbers inside the "## Entries" section (fence-aware).
entry_heading_lines() {
  awk '
    /^(```|~~~)/ { in_fence = !in_fence; next }
    {
      if (in_fence) next
      line = $0; sub(/\r$/, "", line)
      if (line ~ /^## Entries[[:space:]]*$/) { in_entries = 1; next }
      if (!in_entries) next
      if (line !~ /^#+[[:space:]]/) next
      htext = line; sub(/^#+[[:space:]]+/, "", htext)
      if (htext ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) print NR
    }
  ' "$1"
}

# Inject the rollover pointer as the first bullet of "## Current Snapshot",
# dropping any existing rollover-pointer line (idempotent across rollovers).
inject_pointer() {
  awk -v ptr="$1" '
    /^## Current Snapshot[[:space:]]*$/ { print; print ptr; in_snap = 1; next }
    in_snap && /^## / { in_snap = 0; print; next }
    in_snap {
      if (tolower($0) ~ /context-log rollover[[:space:]]*:/) next
      print; next
    }
    { print }
  ' "$2"
}

# Split a file at the first entry heading: prints "HEADER\n<n>" where line <n> is
# the first dated heading (or 0 if none), so the caller can slice header/entries.
first_entry_line() {
  awk '
    /^(```|~~~)/ { in_fence = !in_fence; next }
    {
      if (in_fence) next
      line = $0; sub(/\r$/, "", line)
      if (line !~ /^#+[[:space:]]/) next
      htext = line; sub(/^#+[[:space:]]+/, "", htext)
      if (htext ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) { print NR; exit }
    }
    END { }
  ' "$1"
}

# Newest/oldest archive entry headings, selected exactly as the checker does:
# max/min normalized timestamp, ties broken by newest-at-top position (newest =
# top-most at the max minute, oldest = bottom-most at the min minute).
select_boundaries() {
  awk '
    function entry_ts(text,   d, rest, t) {
      d = substr(text, 1, 10); rest = substr(text, 11)
      if (match(rest, /[0-9][0-9]:[0-9][0-9]/)) t = substr(rest, RSTART, 5)
      else t = "00:00"
      return d " " t
    }
    /^(```|~~~)/ { in_fence = !in_fence; next }
    {
      if (in_fence) next
      line = $0; sub(/\r$/, "", line)
      if (line !~ /^#+[[:space:]]/) next
      sub(/^#+[[:space:]]+/, "", line)
      if (line !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) next
      ts = entry_ts(line); n++
      if (n == 1 || ts > max_ts) { max_ts = ts; max_h = line }
      if (n == 1 || ts <= min_ts) { min_ts = ts; min_h = line }
    }
    END { printf "%s\n%s\n", max_h, min_h }
  ' "$1"
}

# Lexically collapse "/", ".", "//", and ".." in an absolute path (no FS access),
# so equivalent spellings of a not-yet-created path compare equal.
normalize_lexical() {
  awk -v p="$1" 'BEGIN {
    n = split(p, a, "/")
    m = 0
    for (i = 1; i <= n; i++) {
      c = a[i]
      if (c == "" || c == ".") continue
      if (c == "..") { if (m > 0) m--; continue }
      out[++m] = c
    }
    s = ""
    for (i = 1; i <= m; i++) s = s "/" out[i]
    print (s == "" ? "/" : s)
  }'
}

# Canonical absolute path for a destination that need not exist yet: resolve the
# nearest existing ancestor through "pwd -P" (so symlinks in the existing prefix
# collapse), then lexically normalize the missing tail. Two spellings of the same
# destination compare equal even when the parent directory does not exist yet.
canonical_path() {
  local p="$1" dir rest=""
  case "$p" in
    /*) ;;
    *) p="$PWD/$p" ;;
  esac
  dir="$p"
  while [[ ! -d "$dir" ]]; do
    rest="${dir##*/}${rest:+/}$rest"
    dir="${dir%/*}"
    [[ -n "$dir" ]] || dir="/"
  done
  dir="$(cd "$dir" && pwd -P)"
  normalize_lexical "$dir${rest:+/}$rest"
}

# --- preconditions (no writes) -------------------------------------------

# The three outputs must be distinct files; otherwise self-validation passes on
# the scratch copies but the sequential commit renames clobber one another.
log_canon="$(canonical_path "$context_log")"
archive_canon="$(canonical_path "$archive_file")"
manifest_canon="$(canonical_path "$manifest_file")"
[[ "$log_canon" != "$archive_canon" ]] || die "--archive must differ from the context log ($archive_file)"
[[ "$log_canon" != "$manifest_canon" ]] || die "--manifest must differ from the context log ($manifest_file)"
[[ "$archive_canon" != "$manifest_canon" ]] || die "--archive and --manifest must differ ($archive_file)"

# Structure must be sound before we rearrange it.
if ! "$checker" "$context_log" --quiet >/dev/null 2>&1; then
  abort "context log fails the structural rollover check; run check-context-log-rollover.sh $context_log"
fi

mapfile -t heading_lines < <(entry_heading_lines "$context_log")
total_entries="${#heading_lines[@]}"

[[ "$total_entries" -ge 1 ]] || abort "no dated entries found under \"## Entries\""

if [[ "$total_entries" -le "$keep" ]]; then
  [[ "$quiet" == "true" ]] || echo "Nothing to roll over: $total_entries entr(y/ies) <= --keep $keep."
  exit 0
fi

# This rollover will write, so enforce the gate: the newest entry must be the
# gate-required rollover session entry. Refusing by DEFAULT (not only when a flag
# happens to be passed) is what keeps cite-then-mutate closed -- otherwise the
# durable counts/boundary could be finalized before that entry exists.
# --allow-missing-top-entry is the explicit, auditable escape hatch.
top_line="${heading_lines[0]}"
top_heading="$(sed -n "${top_line}p" "$context_log" | sed -E 's/\r$//; s/^#+[[:space:]]+//')"
if [[ -n "$require_top_entry" ]]; then
  [[ "$top_heading" == *"$require_top_entry"* ]] ||
    abort "newest entry does not contain required marker \"$require_top_entry\" (gate-required rollover entry missing); newest is: $top_heading"
elif [[ "$allow_missing_top_entry" != "true" ]]; then
  abort "refusing to roll over without asserting the gate-required session entry; pass --require-top-entry <marker> (recommended) or --allow-missing-top-entry to override. Newest entry is: $top_heading"
fi

# --- build everything in a scratch dir (still no writes to real files) ---

scratch="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-compact.XXXXXX")"
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT

archive_base="$(basename "$archive_file")"
new_log="$scratch/livelog"
new_archive="$scratch/$archive_base"
new_manifest="$scratch/manifest"

split_line="${heading_lines[$keep]}" # first archived entry heading (1-based)

# Live body = header + Current Snapshot + Usage Rules + the newest <keep> entries.
sed -n "1,$((split_line - 1))p" "$context_log" >"$scratch/live_body_raw"
strip_trailing_blanks "$scratch/live_body_raw" >"$scratch/live_body"

# Archived batch = the remaining (older) entries, newest-first as they appeared.
sed -n "${split_line},\$p" "$context_log" >"$scratch/batch_raw"
strip_trailing_blanks "$scratch/batch_raw" >"$scratch/batch"

archived_count=$((total_entries - keep))

# Build the new archive: existing header + this (newer) batch + existing entries.
if [[ -f "$archive_file" ]]; then
  first_existing="$(first_entry_line "$archive_file")"
  if [[ -n "$first_existing" ]]; then
    sed -n "1,$((first_existing - 1))p" "$archive_file" | strip_trailing_blanks - >"$scratch/arch_header"
    sed -n "${first_existing},\$p" "$archive_file" >"$scratch/arch_existing"
  else
    strip_trailing_blanks "$archive_file" >"$scratch/arch_header"
    : >"$scratch/arch_existing"
  fi
else
  printf '# Context Log Archive\n' >"$scratch/arch_header"
  : >"$scratch/arch_existing"
fi

{
  cat "$scratch/arch_header"
  printf '\n'
  cat "$scratch/batch"
  if [[ -s "$scratch/arch_existing" ]]; then
    printf '\n'
    cat "$scratch/arch_existing"
  fi
  printf '\n'
} >"$new_archive"

# Boundary fields, finalized now from the built archive (matches the checker's
# selection so the manifest can never cite a stale boundary).
mapfile -t bounds < <(select_boundaries "$new_archive")
newest_archived="${bounds[0]:-}"
oldest_archived="${bounds[1]:-}"
[[ -n "$newest_archived" && -n "$oldest_archived" ]] ||
  abort "could not determine archive boundaries after building the archive"

if [[ -z "$boundary" ]]; then
  boundary="through ${newest_archived##* - }"
fi
if [[ -z "$anchors" ]]; then
  anchors="${newest_archived##* - }; ${oldest_archived##* - }"
fi
if [[ -z "$rollover_id" ]]; then
  day="$(date +%Y-%m-%d)"
  # Next sequence = max existing same-day suffix + 1, so a gap (e.g. -1, -3) never
  # re-issues an in-use id (counting would). Default to 1 when none exist.
  next_seq=1
  if [[ -f "$manifest_file" ]]; then
    next_seq="$(awk -v day="$day" '
      $0 ~ ("^## rollover: " day "-[0-9]+[[:space:]]*$") {
        s = $0; sub(/.*-/, "", s); sub(/[[:space:]]+$/, "", s)
        if (s + 0 > max) max = s + 0
      }
      END { print max + 1 }
    ' "$manifest_file")"
  fi
  rollover_id="${day}-${next_seq}"
fi

pointer_line="- Context-log rollover: \`${rollover_id}\` — boundary: ${boundary}"
inject_pointer "$pointer_line" "$scratch/live_body" >"$new_log"

# Build the new manifest: header + this (newest) record + existing records.
new_record="$scratch/record"
{
  printf '## rollover: %s\n' "$rollover_id"
  printf -- '- archive_file: %s\n' "$archive_file"
  printf -- '- boundary: %s\n' "$boundary"
  printf -- '- newest_archived: %s\n' "$newest_archived"
  printf -- '- oldest_archived: %s\n' "$oldest_archived"
  printf -- '- kept: %s\n' "$keep"
  printf -- '- archived: %s\n' "$archived_count"
  printf -- '- anchors: %s\n' "$anchors"
} >"$new_record"

if [[ -f "$manifest_file" ]]; then
  first_record="$(grep -n '^## rollover:' "$manifest_file" | head -n1 | cut -d: -f1 || true)"
  if [[ -n "$first_record" ]]; then
    sed -n "1,$((first_record - 1))p" "$manifest_file" | strip_trailing_blanks - >"$scratch/man_header"
    sed -n "${first_record},\$p" "$manifest_file" >"$scratch/man_existing"
  else
    strip_trailing_blanks "$manifest_file" >"$scratch/man_header"
    : >"$scratch/man_existing"
  fi
else
  printf '# Context Log Rollover Manifest\n\n<!-- One record per rollover, newest first. Maintained by compact-context-log.sh; validated by check-context-log-rollover.sh --manifest. -->\n' >"$scratch/man_header"
  : >"$scratch/man_existing"
fi

{
  cat "$scratch/man_header"
  printf '\n'
  cat "$new_record"
  if [[ -s "$scratch/man_existing" ]]; then
    printf '\n'
    cat "$scratch/man_existing"
  fi
} >"$new_manifest"

# --- self-validate the built result with the real checker ----------------

if ! validation="$("$checker" "$new_log" --archive "$new_archive" --manifest "$new_manifest" 2>&1)"; then
  echo "$validation" >&2
  abort "the rolled-over result failed check-context-log-rollover.sh (see above); this is a bug in the rollover, not your log"
fi

summary="Rolled over $context_log: kept $keep, archived $archived_count (id $rollover_id; boundary: $boundary)."

if [[ "$dry_run" == "true" ]]; then
  echo "[dry-run] $summary"
  echo "[dry-run] no files written; result passed check-context-log-rollover.sh --manifest"
  exit 0
fi

# --- commit via atomic same-dir renames; live log written last -----------

commit_file() {
  local src="$1" dest="$2" tmp
  mkdir -p "$(dirname "$dest")"
  tmp="$(dirname "$dest")/.$(basename "$dest").rollover.$$"
  cat "$src" >"$tmp"
  mv -f "$tmp" "$dest"
}

commit_file "$new_archive" "$archive_file"
commit_file "$new_manifest" "$manifest_file"
commit_file "$new_log" "$context_log"

[[ "$quiet" == "true" ]] || echo "$summary"

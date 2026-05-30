#!/usr/bin/env bash
# agent-vault-managed: helper-script; file=check-context-log-rollover.sh

set -euo pipefail

# Validate the structure of an agent-vault context log after a rollover /
# compaction. This is a CHECKER only: it never edits, moves, or rewrites the
# log. It catches the failure modes a manual or scripted rollover can leave
# behind -- most importantly a stale duplicate "## Current Snapshot" that makes
# an agent treat months-old state as current.
#
# Heading and conflict-marker detection is fenced-code aware: a "## ..." heading
# or a conflict marker quoted inside a ``` or ~~~ code block is ignored, so a log
# that documents an example snapshot or a diff does not produce a false failure.
# A latest-handoff pointer value, when present, must be inline on the label line.

usage() {
  cat <<EOF
Usage: $0 <context-log-file> [--archive <archive-file>] [--quiet]

Checks (live context log; headings matched outside fenced code blocks):
  - exactly one "## Current Snapshot" (catches a stale duplicate snapshot)
  - exactly one "## Usage Rules"
  - exactly one "## Entries"
  - no leftover Git conflict markers (<<<<<<<, =======, |||||||, >>>>>>>)
  - if the snapshot declares a latest-handoff pointer, it has an inline value
Checks (when --archive is given):
  - every archived "## Current Snapshot" is labeled superseded

Section headings are matched exactly (a distinct heading such as
"## Current Snapshot Format Notes" is not a duplicate), and CRLF line endings
are tolerated. Entry heading styles inside "## Entries" are not constrained.

Exit status: 0 = clean, 1 = violations found, 2 = usage or IO error.

Options:
  --archive <file>  Also validate an archive file for superseded labeling.
  --quiet           Print only on failure.
  -h, --help        Show this help.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 2
}

context_log=""
archive_file=""
quiet="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive)
      [[ $# -ge 2 ]] || die "--archive requires a path"
      archive_file="$2"
      shift 2
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

if [[ -z "$context_log" ]]; then
  usage >&2
  exit 2
fi
[[ -f "$context_log" ]] || die "context log not found: $context_log"
if [[ -n "$archive_file" && ! -f "$archive_file" ]]; then
  die "archive file not found: $archive_file"
fi

findings=()

# One fenced-code-aware pass. Line 1: "<snapshot> <usage> <entries>" counts of
# exact section headings outside fences. Line 2 (optional): space-separated line
# numbers of leftover Git conflict markers found outside fences.
scan_log() {
  awk '
    function strip(s) {
      sub(/\r$/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    /^(```|~~~)/ { in_fence = !in_fence; next }
    {
      if (in_fence) next
      line = strip($0)
      if (line == "## Current Snapshot") snap++
      else if (line == "## Usage Rules") usage++
      else if (line == "## Entries") entries++
      if (line ~ /^(<<<<<<<|>>>>>>>|\|\|\|\|\|\|\|)/ || line == "=======") {
        conflicts = conflicts NR " "
      }
    }
    END {
      printf "%d %d %d\n", snap + 0, usage + 0, entries + 0
      if (conflicts != "") print conflicts
    }
  ' "$1"
}

check_count() {
  local count="$1" label="$2"
  if [[ "$count" -eq 1 ]]; then
    return 0
  fi
  if [[ "$count" -eq 0 ]]; then
    findings+=("missing \"$label\" heading (expected exactly 1, found 0)")
  else
    findings+=("duplicate \"$label\" heading (expected exactly 1, found $count) -- likely un-rolled stale content below the live block")
  fi
}

# Conditional: only validate a handoff pointer when the snapshot declares one as
# a field. Prints "EMPTY" when the declared pointer has no inline value (markup
# stripped); prints nothing otherwise.
inspect_handoff_pointer() {
  awk '
    /^## Current Snapshot[[:space:]]*$/ { in_snap = 1; next }
    in_snap && /^## / { exit }
    in_snap {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]*[-*]?[[:space:]]*\**[Ll]atest [Hh]andoff\**[[:space:]]*:/) {
        idx = index(line, ":")
        val = substr(line, idx + 1)
        gsub(/[*`[:space:]]/, "", val)
        if (val == "") print "EMPTY"
      }
    }
  ' "$1"
}

# Prints "<line>\t<heading>" for each archived "## Current Snapshot" heading
# (outside a fence) that is not labeled superseded on the heading line itself, so
# an archived snapshot cannot read as active. The label must be in the heading,
# e.g. "## Current Snapshot - SUPERSEDED (archived ...)".
inspect_archive_superseded() {
  awk '
    function strip(s) {
      sub(/\r$/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    /^(```|~~~)/ { in_fence = !in_fence; next }
    {
      if (in_fence) next
      line = strip($0)
      if (line ~ /^## Current Snapshot/ && tolower(line) !~ /superseded/) {
        printf "%d\t%s\n", NR, line
      }
    }
  ' "$1"
}

mapfile -t scan < <(scan_log "$context_log")
read -r snap_count usage_count entries_count <<<"${scan[0]:-0 0 0}"
conflict_lines="${scan[1]:-}"

check_count "$snap_count" "## Current Snapshot"
check_count "$usage_count" "## Usage Rules"
check_count "$entries_count" "## Entries"

if [[ -n "${conflict_lines// /}" ]]; then
  findings+=("Git conflict markers present at line(s): ${conflict_lines% }")
fi

handoff_state="$(inspect_handoff_pointer "$context_log")"
if [[ "$handoff_state" == *EMPTY* ]]; then
  findings+=("Current Snapshot declares a latest-handoff pointer but it has no inline value")
fi

if [[ -n "$archive_file" ]]; then
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    findings+=("archived snapshot is not labeled superseded (archive line ${row%%$'\t'*}) -- archived snapshots must be marked superseded so they cannot read as active")
  done < <(inspect_archive_superseded "$archive_file")
fi

if [[ "${#findings[@]}" -eq 0 ]]; then
  [[ "$quiet" == "true" ]] || echo "context-log rollover check passed: $context_log"
  exit 0
fi

echo "context-log rollover check FAILED: $context_log" >&2
for finding in "${findings[@]}"; do
  echo "- $finding" >&2
done
exit 1

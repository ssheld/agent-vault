#!/usr/bin/env bash

set -euo pipefail

# Validate the structure of an agent-vault context log after a rollover /
# compaction. This is a CHECKER only: it never edits, moves, or rewrites the
# log. It catches the failure modes a manual or scripted rollover can leave
# behind -- most importantly a stale duplicate "## Current Snapshot" that makes
# an agent treat months-old state as current.

usage() {
  cat <<EOF
Usage: $0 <context-log-file> [--archive <archive-file>] [--quiet]

Checks (live context log):
  - exactly one "## Current Snapshot" (catches a stale duplicate snapshot)
  - exactly one "## Usage Rules"
  - exactly one "## Entries"
  - no leftover Git conflict markers
  - if the snapshot declares a latest-handoff pointer, it is non-empty
Checks (when --archive is given):
  - every archived "## Current Snapshot" is labeled superseded

The check is tolerant of mixed entry heading styles (\`### YYYY-MM-DD ...\` and
compact \`## YYYY-MM-DD ...\`, em-dash variants); it keys on the named section
headings, not on entry formatting.

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

count_matches() {
  local file="$1"
  local pattern="$2"
  grep -cE "$pattern" "$file" || true
}

require_exactly_one() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  local count
  count="$(count_matches "$file" "$pattern")"

  if [[ "$count" -eq 1 ]]; then
    return 0
  fi

  if [[ "$count" -eq 0 ]]; then
    findings+=("missing \"$label\" heading (expected exactly 1, found 0)")
  else
    findings+=("duplicate \"$label\" heading (expected exactly 1, found $count) -- likely un-rolled stale content below the live block")
  fi
}

# Match the standard 7-character Git conflict markers, including a leftover
# "=======" separator on its own line (which a partial manual cleanup can leave
# behind after removing the <<<<<<< / >>>>>>> sides) and the "|||||||" diff3
# base marker.
check_conflict_markers() {
  local file="$1"
  local marker_lines
  marker_lines="$(grep -nE '^(<<<<<<<|>>>>>>>|\|\|\|\|\|\|\||=======$)' "$file" || true)"

  if [[ -n "$marker_lines" ]]; then
    findings+=("Git conflict markers present: $(printf '%s' "$marker_lines" | tr '\n' ';')")
  fi
}

# Conditional per reviewer guidance: only validate a handoff pointer when the
# snapshot actually declares one. Prints "EMPTY" or "NOCOLON" when a declared
# pointer has no value; prints nothing otherwise.
inspect_handoff_pointer() {
  local file="$1"

  awk '
    /^## Current Snapshot[[:space:]]*$/ { in_snap = 1; next }
    in_snap && /^## / { exit }
    in_snap && tolower($0) ~ /latest handoff/ {
      idx = index($0, ":")
      if (idx == 0) { print "NOCOLON"; next }
      val = substr($0, idx + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      if (val == "") { print "EMPTY" }
    }
  ' "$file"
}

# Prints "<line>\t<heading>" for each archived "## Current Snapshot" that is not
# labeled superseded within its heading line or the next two non-empty lines.
inspect_archive_superseded() {
  local file="$1"

  awk '
    function flush() {
      if (pending && tolower(window) !~ /superseded/) {
        printf "%d\t%s\n", snap_line, snap_text
      }
      pending = 0
      window = ""
    }
    /^## Current Snapshot/ {
      flush()
      pending = 1
      snap_line = NR
      snap_text = $0
      window = $0
      lookahead = 2
      next
    }
    pending && lookahead > 0 && $0 !~ /^[[:space:]]*$/ {
      window = window " " $0
      lookahead -= 1
    }
    END { flush() }
  ' "$file"
}

require_exactly_one "$context_log" '^## Current Snapshot' "## Current Snapshot"
require_exactly_one "$context_log" '^## Usage Rules' "## Usage Rules"
require_exactly_one "$context_log" '^## Entries' "## Entries"
check_conflict_markers "$context_log"

handoff_state="$(inspect_handoff_pointer "$context_log")"
if [[ "$handoff_state" == *EMPTY* || "$handoff_state" == *NOCOLON* ]]; then
  findings+=("Current Snapshot declares a latest-handoff pointer but it has no value")
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

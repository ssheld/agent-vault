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
Usage: $0 <context-log-file> [--archive <archive-file>] [--manifest <file>] [--quiet]

Checks (live context log; headings matched outside fenced code blocks):
  - exactly one "## Current Snapshot" (catches a stale duplicate snapshot)
  - exactly one "## Usage Rules"
  - exactly one "## Entries"
  - no leftover Git conflict markers (<<<<<<<, =======, |||||||, >>>>>>>)
  - if the snapshot declares a latest-handoff pointer, it has an inline value
Checks (when --archive is given):
  - every archived "## Current Snapshot" is labeled superseded
Checks (when --manifest is given -- Layer-2 rollover assertions):
  - the live Current Snapshot's "Context-log rollover" pointer references the
    newest manifest record's id and repeats its boundary text verbatim
  - the manifest's newest_archived / oldest_archived headings are the actual
    newest / oldest entries in the named archive (the cite-then-mutate catch)
  - every manifest anchor appears in the archive
  - no orphaned top-level "Next Prompt" heading survives in the archive

Section headings are matched exactly (a distinct heading such as
"## Current Snapshot Format Notes" is not a duplicate), and CRLF line endings
are tolerated. Entry heading styles inside "## Entries" are not constrained.

The rollover manifest (parsed source of truth) holds one record per rollover,
newest first. All fields are required; the *_archived headings are the entry
heading text with the leading "#"s removed, and the archive is newest-at-top so
a same-minute tie resolves to the top-most (newest) / bottom-most (oldest) entry:

  ## rollover: <id>
  - archive_file: agent-vault/context/archive/context-log-YYYY.md
  - boundary: <topic / recent-window boundary text>
  - newest_archived: <newest archived entry heading, no leading "#">
  - oldest_archived: <oldest archived entry heading, no leading "#">
  - kept: <N>
  - archived: <M>
  - anchors: <anchor>; <anchor>   (each must appear in the archive)

The live pointer carries the stable link back to that record:

  - Context-log rollover: \`<id>\` — boundary: <same boundary text>

Exit status: 0 = clean, 1 = violations found, 2 = usage or IO error.

Options:
  --archive <file>   Also validate an archive file for superseded labeling.
  --manifest <file>  Run Layer-2 assertions against a rollover manifest.
  --quiet            Print only on failure.
  -h, --help         Show this help.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 2
}

context_log=""
archive_file=""
manifest_file=""
quiet="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
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
if [[ -n "$manifest_file" && ! -f "$manifest_file" ]]; then
  die "manifest file not found: $manifest_file"
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

# --- Layer-2 (rollover manifest) helpers ---------------------------------
# These run only when --manifest is given. They verify the live pointer's claim
# against the manifest, and the manifest's claims against archive reality, so a
# "cite-then-mutate" rollover (numbers finalized before the gate-required entry
# was added) cannot leave a boundary that is not the archive's actual newest.

# Normalize a value for comparison/lookup: strip markup, collapse whitespace, trim.
norm() {
  local s="$1"
  s="${s//\`/}"
  s="${s//\*/}"
  s="$(printf '%s' "$s" | tr -s '[:space:]' ' ')"
  s="${s# }"
  s="${s% }"
  printf '%s' "$s"
}

# Newest manifest record (first "## rollover:" block) as "key<TAB>value" lines.
parse_manifest_newest() {
  awk '
    function strip(s) {
      sub(/\r$/, "", s)
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    /^##[[:space:]]+rollover:/ {
      if (seen) exit
      seen = 1
      id = $0
      sub(/^##[[:space:]]+rollover:[[:space:]]*/, "", id)
      printf "id\t%s\n", strip(id)
      next
    }
    seen && /^##[[:space:]]/ { exit }
    seen {
      line = $0
      sub(/\r$/, "", line)
      if (match(line, /^[[:space:]]*[-*][[:space:]]*[A-Za-z_]+[[:space:]]*:/)) {
        sub(/^[[:space:]]*[-*][[:space:]]*/, "", line)
        ci = index(line, ":")
        printf "%s\t%s\n", strip(substr(line, 1, ci - 1)), strip(substr(line, ci + 1))
      }
    }
  ' "$1"
}

# Live-log Current Snapshot rollover pointer as "field/id/boundary" rows.
parse_live_pointer() {
  awk '
    function strip(s) {
      sub(/\r$/, "", s)
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    /^##[[:space:]]+Current Snapshot[[:space:]]*$/ { in_snap = 1; next }
    in_snap && /^##[[:space:]]/ { exit }
    in_snap {
      line = $0
      sub(/\r$/, "", line)
      if (tolower(line) ~ /context-log rollover[[:space:]]*:/) {
        print "field\t1"
        id = ""
        if (match(line, /`[^`]+`/)) id = substr(line, RSTART + 1, RLENGTH - 2)
        printf "id\t%s\n", strip(id)
        bi = index(tolower(line), "boundary:")
        if (bi > 0) printf "boundary\t%s\n", strip(substr(line, bi + 9))
        else print "boundary_missing\t1"
      }
    }
  ' "$1"
}

# Archive entry-heading extremes + presence of the named newest/oldest headings.
# An "entry heading" is any heading (outside a fence) whose text starts with a
# YYYY-MM-DD date; timestamps normalize to "YYYY-MM-DD HH:MM" (00:00 if no time)
# so lexical compare gives chronological order and a shared minute is unambiguous.
verify_archive_boundaries() {
  awk -v newest="$1" -v oldest="$2" '
    function strip(s) {
      sub(/\r$/, "", s)
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function entry_ts(text,   d, rest, t) {
      d = substr(text, 1, 10)
      rest = substr(text, 11)
      if (match(rest, /[0-9][0-9]:[0-9][0-9]/)) t = substr(rest, RSTART, 5)
      else t = "00:00"
      return d " " t
    }
    /^(```|~~~)/ { in_fence = !in_fence; next }
    {
      if (in_fence) next
      line = strip($0)
      # mawk has no interval expressions ({1,6}); "#+" matches any heading depth.
      if (line !~ /^#+[[:space:]]/) next
      sub(/^#+[[:space:]]+/, "", line)
      if (line !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) next
      ts = entry_ts(line)
      n++
      # The newest entry is the top-most at the max timestamp and the oldest is
      # the bottom-most at the min timestamp (archives are newest-at-top). Ties
      # on a shared minute are broken by position, so max_h/min_h name one
      # specific heading and a same-minute mismatch is still caught.
      if (n == 1 || ts > max_ts) { max_ts = ts; max_h = line }
      if (n == 1 || ts <= min_ts) { min_ts = ts; min_h = line }
      if (line == newest) newest_found = 1
      if (line == oldest) oldest_found = 1
    }
    END {
      printf "count\t%d\n", n + 0
      printf "max\t%s\t%s\n", max_ts, max_h
      printf "min\t%s\t%s\n", min_ts, min_h
      printf "newest_found\t%d\n", newest_found + 0
      printf "oldest_found\t%d\n", oldest_found + 0
    }
  ' "$3"
}

# Line numbers of top-level (# or ##) "Next Prompt" headings outside fences --
# a Next Prompt belongs nested under its entry, never as a standalone section.
find_orphan_next_prompts() {
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
      # "##?" = one or two hashes (top-level only); mawk lacks intervals ({1,2}).
      if (line ~ /^##?[[:space:]]+(Suggested[[:space:]]+)?Next Prompt[[:space:]]*$/) printf "%d ", NR
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

if [[ -n "$manifest_file" ]]; then
  declare -A manifest=()
  manifest_has_record="false"
  while IFS=$'\t' read -r key value; do
    [[ -n "$key" ]] || continue
    manifest["$key"]="$value"
    manifest_has_record="true"
  done < <(parse_manifest_newest "$manifest_file")

  pointer_field="false"
  pointer_id=""
  pointer_boundary=""
  pointer_boundary_missing="false"
  while IFS=$'\t' read -r key value; do
    case "$key" in
      field) pointer_field="true" ;;
      id) pointer_id="$value" ;;
      boundary) pointer_boundary="$value" ;;
      boundary_missing) pointer_boundary_missing="true" ;;
    esac
  done < <(parse_live_pointer "$context_log")

  if [[ "$manifest_has_record" != "true" ]]; then
    # An empty manifest with no live pointer is a scaffolded "no rollover yet"
    # state and is fine; a live pointer with no backing record is not.
    if [[ "$pointer_field" == "true" ]]; then
      findings+=("live log declares a rollover pointer but the manifest has no records: $manifest_file")
    fi
  else
    for required in id archive_file boundary newest_archived oldest_archived kept archived anchors; do
      [[ -n "${manifest[$required]:-}" ]] || findings+=("manifest record is missing required field: $required")
    done
    for numeric in kept archived; do
      value="${manifest[$numeric]:-}"
      [[ -z "$value" || "$value" =~ ^[0-9]+$ ]] ||
        findings+=("manifest field $numeric must be a non-negative integer, got: \"$value\"")
    done

    # Pointer <-> manifest consistency.
    if [[ "$pointer_field" != "true" ]]; then
      findings+=("manifest present but live log Current Snapshot declares no \"Context-log rollover\" pointer")
    else
      if [[ "$pointer_boundary_missing" == "true" ]]; then
        findings+=("rollover pointer declares no \"boundary:\" value")
      fi
      if [[ -n "${manifest[id]:-}" && "$pointer_id" != "${manifest[id]}" ]]; then
        findings+=("rollover pointer id \"$pointer_id\" does not match newest manifest record \"${manifest[id]}\"")
      fi
      if [[ -n "${manifest[boundary]:-}" && "$pointer_boundary_missing" != "true" ]]; then
        if [[ "$(norm "$pointer_boundary")" != "$(norm "${manifest[boundary]}")" ]]; then
          findings+=("rollover pointer boundary does not match the manifest boundary for \"${manifest[id]:-?}\"")
        fi
      fi
    fi

    # Resolve the archive named by the manifest, to verify claims against reality.
    resolved_archive=""
    manifest_archive="${manifest[archive_file]:-}"
    if [[ -n "$archive_file" ]]; then
      resolved_archive="$archive_file"
      if [[ -n "$manifest_archive" && "$(basename "$manifest_archive")" != "$(basename "$archive_file")" ]]; then
        findings+=("manifest archive_file \"$(basename "$manifest_archive")\" does not match --archive \"$(basename "$archive_file")\"")
      fi
    elif [[ -n "$manifest_archive" ]]; then
      candidate="$(dirname "$manifest_file")/$(basename "$manifest_archive")"
      if [[ -f "$candidate" ]]; then
        resolved_archive="$candidate"
      else
        findings+=("manifest names archive \"$manifest_archive\" but it was not found next to the manifest (pass --archive to locate it)")
      fi
    fi

    if [[ -n "$resolved_archive" ]]; then
      declare -A boundary=()
      while IFS=$'\t' read -r tag col_a col_b; do
        case "$tag" in
          newest_found) boundary[nf]="$col_a" ;;
          oldest_found) boundary[of]="$col_a" ;;
          max) boundary[maxh]="$col_b" ;;
          min) boundary[minh]="$col_b" ;;
        esac
      done < <(verify_archive_boundaries "${manifest[newest_archived]:-}" "${manifest[oldest_archived]:-}" "$resolved_archive")

      # Require an exact heading match against the entry the checker independently
      # selects as newest/oldest (max/min timestamp, ties broken by position), so
      # naming a wrong same-minute heading is caught, not just an older timestamp.
      if [[ -n "${manifest[newest_archived]:-}" ]]; then
        if [[ "${boundary[nf]:-0}" != "1" ]]; then
          findings+=("manifest newest_archived heading not found in the archive: \"${manifest[newest_archived]}\"")
        elif [[ "${manifest[newest_archived]}" != "${boundary[maxh]:-}" ]]; then
          findings+=("manifest newest_archived is not the archive's newest entry -- the newest archived entry is: \"${boundary[maxh]}\"")
        fi
      fi
      if [[ -n "${manifest[oldest_archived]:-}" ]]; then
        if [[ "${boundary[of]:-0}" != "1" ]]; then
          findings+=("manifest oldest_archived heading not found in the archive: \"${manifest[oldest_archived]}\"")
        elif [[ "${manifest[oldest_archived]}" != "${boundary[minh]:-}" ]]; then
          findings+=("manifest oldest_archived is not the archive's oldest entry -- the oldest archived entry is: \"${boundary[minh]}\"")
        fi
      fi

      if [[ -n "${manifest[anchors]:-}" ]]; then
        IFS=';' read -ra anchor_list <<<"${manifest[anchors]}"
        for anchor in "${anchor_list[@]}"; do
          anchor="$(norm "$anchor")"
          [[ -n "$anchor" ]] || continue
          grep -Fq -- "$anchor" "$resolved_archive" || findings+=("manifest anchor not found in the archive: \"$anchor\"")
        done
      fi

      orphans="$(find_orphan_next_prompts "$resolved_archive")"
      orphans="${orphans%% }"
      if [[ -n "${orphans// /}" ]]; then
        findings+=("orphaned top-level \"Next Prompt\" heading in the archive at line(s): $orphans -- a Next Prompt must stay nested under its archived entry")
      fi
    fi
  fi
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

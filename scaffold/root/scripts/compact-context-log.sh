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
# Contract (single writer, local filesystem, recoverable process interruption):
#   - It does NOT invent the gate-required rollover session entry. The caller adds
#     that entry first (the metadata gate), then runs this; --require-top-entry
#     asserts it is the newest entry and leaves outputs unchanged if it is not.
#   - Counts and the boundary are finalized AFTER that entry is in place, from the
#     live file as it stands, so they cannot describe a pre-entry state.
#   - All outputs are prepared and self-validated before any output replacement.
#   - Destination-local renames are individually atomic, not a three-file atomic
#     operation. A private record and staged files allow explicit roll-forward.
#   - Without a record, recognizable partial states refuse rather than duplicate
#     entries. Missing evidence is not authority to reconstruct the original job.
#
# Exit status: 0 = success/no-op, 1 = gate/validation refusal (outputs unchanged),
# 2 = usage/preparation IO error, 3 = recovery/manual reconciliation required.
# Handled HUP/INT/TERM retain 129/130/143. No power-loss or concurrent-writer claim.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
checker="$here/check-context-log-rollover.sh"

usage() {
  cat <<EOF
Usage: $0 <context-log-file> --keep <N> --archive <file> --manifest <file>
          [--rollover-id <id>] [--boundary <text>] [--anchors "<a>; <b>"]
          [--require-top-entry <substring>] [--dry-run] [--quiet]
       $0 <context-log-file> --recover [--dry-run] [--quiet]

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
  --allow-stale-archive-metadata
                             Override the refusal to grow an archive whose own
                             header carries a frontmatter "covers:" field or a
                             relocation manifest this tool cannot keep in sync.
                             You must then update that header by hand.
  --adopt-manual-rollover     Start the first manifest for a verified manual rollover
                             pointer with no manifest records. Does not bypass
                             overlap checks, pending recovery, or session gates.
                             Remove this one-time option after adoption.
  --dry-run                  Build and self-validate, print a summary, write nothing.
  --recover                  Finish the recorded operation without generation options.
  --quiet                    Print only on failure / a one-line success.
  -h, --help                 Show this help.

Use only one writer for the log, archive, and manifest, including recovery. Stop
the original process and its children before recovering. Pending data lives in
.agent-vault-rollover-* directories beside the log and destinations; do not clean
or move it until recovery finishes. Recovery never overwrites intervening edits.
Exit 3 requires recovery or manual reconciliation, not a fresh rollover retry.
EOF
}

die() {
  echo "Error: $*" >&2
  reported_status=2
  exit 2
}

abort() {
  echo "Aborted (outputs unchanged): $*" >&2
  reported_status=1
  exit 1
}

pending() {
  echo "Recovery required: $*" >&2
  reported_status=3
  exit 3
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
allow_stale_archive_metadata="false"
adopt_manual_rollover="false"
dry_run="false"
quiet="false"
recover="false"
generation_options="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep | --archive | --manifest | --rollover-id | --boundary | --anchors | --require-top-entry | --allow-missing-top-entry | --allow-stale-archive-metadata | --adopt-manual-rollover)
      generation_options="true"
      ;;
  esac
  case "$1" in
    --recover)
      recover="true"
      shift
      ;;
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
    --allow-stale-archive-metadata)
      allow_stale_archive_metadata="true"
      shift
      ;;
    --adopt-manual-rollover)
      adopt_manual_rollover="true"
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
[[ -x "$checker" || -f "$checker" ]] || die "checker not found next to this script: $checker"

# --- small helpers -------------------------------------------------------

# Strip trailing blank lines from a file in place.
strip_trailing_blanks() {
  awk 'BEGIN { blanks = 0 }
    { for (; blanks > 0; blanks--) print ""; if ($0 ~ /^[[:space:]]*$/) { blanks++; next } print }
  ' "$1"
}

# Entry-heading line numbers inside the "## Entries" section (fence-aware).
# Only canonical entry headings ("### YYYY-MM-DD HH:MM local - <agent> - <topic>",
# the shape the pre-commit hook enforces) count: a nested sub-heading that merely
# starts with a date must never become a split boundary or inflate the entry count.
entry_heading_lines() {
  awk '
    /^(```|~~~)/ { in_fence = !in_fence; next }
    {
      if (in_fence) next
      line = $0; sub(/\r$/, "", line)
      if (line ~ /^## Entries[[:space:]]*$/) { in_entries = 1; next }
      if (!in_entries) next
      if (line !~ /^### [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9] local - /) next
      print NR
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

# Split a file at the first entry heading: prints the line number of the first
# canonical entry heading (nothing if none), so the caller can slice header/entries.
first_entry_line() {
  awk '
    /^(```|~~~)/ { in_fence = !in_fence; next }
    {
      if (in_fence) next
      line = $0; sub(/\r$/, "", line)
      if (line !~ /^### [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9] local - /) next
      print NR
      exit
    }
    END { }
  ' "$1"
}

# Newest/oldest archive entry headings, selected exactly as the checker does:
# max/min normalized timestamp, ties broken by newest-at-top position (newest =
# top-most at the max minute, oldest = bottom-most at the min minute).
select_boundaries() {
  awk '
    /^(```|~~~)/ { in_fence = !in_fence; next }
    {
      if (in_fence) next
      line = $0; sub(/\r$/, "", line)
      if (line !~ /^### [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9] local - /) next
      sub(/^### /, "", line)
      ts = substr(line, 1, 16); n++
      if (n == 1 || ts > max_ts) { max_ts = ts; max_h = line }
      if (n == 1 || ts <= min_ts) { min_ts = ts; min_h = line }
    }
    END { printf "%s\n%s\n", max_h, min_h }
  ' "$1"
}

# Print "1" if an existing archive's header (everything above its first dated
# entry) carries metadata this tool cannot keep in sync when it prepends a newer
# batch: a top-of-file YAML frontmatter "covers:" field (a coverage claim that
# would go stale) or a "relocation manifest" heading. The compactor only
# maintains the live pointer and the separate --manifest file, so growing such an
# archive in place would silently stale its own header while self-validation
# still passes.
archive_header_has_unmanaged_metadata() {
  awk '
    NR == 1 && $0 ~ /^---[[:space:]]*$/ { in_fm = 1; next }
    in_fm && $0 ~ /^---[[:space:]]*$/ { in_fm = 0; next }
    in_fm && tolower($0) ~ /^[[:space:]]*covers[[:space:]]*:/ { found = 1; next }
    /^(```|~~~)/ { in_fence = !in_fence; next }
    !in_fence && tolower($0) ~ /^#+[[:space:]]+.*relocation manifest/ { found = 1 }
    END { if (found) print "1" }
  ' "$1"
}

# Resolve directory components physically before interpreting subsequent '..'.
# Final file symlinks are deliberately not followed; validate_file rejects them.
# Newlines cannot be represented by the existing Markdown manifest/pointer format.
canonical_path() {
  local remaining="$1" physical="/" component next
  [[ "$remaining" != *$'\n'* && "$remaining" != *$'\r'* ]] || return 1
  [[ "$remaining" == /* ]] || remaining="$PWD/$remaining"
  remaining="${remaining#/}"
  while [[ -n "$remaining" ]]; do
    component="${remaining%%/*}"
    if [[ "$remaining" == */* ]]; then remaining="${remaining#*/}"; else remaining=""; fi
    case "$component" in
      '' | '.') continue ;;
      '..')
        physical="${physical%/*}"
        physical="${physical:-/}"
        continue
        ;;
    esac
    next="${physical%/}/$component"
    if [[ -n "$remaining" && (-e "$next" || -L "$next") ]]; then
      [[ -d "$next" && -x "$next" ]] || return 1
      physical="$(cd -P -- "$next" && pwd -P)" || return 1
    else
      physical="$next"
    fi
  done
  printf '%s\n' "$physical"
}

validate_file() {
  [[ ! -L "$1" && (! -e "$1" || -f "$1") ]]
}

validate_destinations() {
  local i j canonical
  for i in 0 1 2; do
    validate_file "${destinations[$i]}" || return 1
    canonical="$(canonical_path "${destinations[$i]}")" || return 1
    [[ "$canonical" == "${destinations[$i]}" && "$canonical" != */.agent-vault-rollover-* ]] || return 1
    for j in 0 1 2; do
      [[ "$i" == "$j" ]] && continue
      [[ "${destinations[$i]}" != "${destinations[$j]}" &&
        "${destinations[$i]}" != "${destinations[$j]}/"* &&
        ! "${destinations[$i]}" -ef "${destinations[$j]}" ]] || return 1
    done
  done
}

# SHA-256 is supplied by coreutils on Linux and shasum on macOS. Read stdin so
# filenames never become checksum-tool flags or escaped checksum output.
fingerprint() {
  local digest
  validate_file "$1" || return 1
  if [[ ! -e "$1" ]]; then
    printf 'absent\n'
    return
  fi
  digest="$("${hash_command[@]}" <"$1")" || return 1
  digest="${digest%% *}"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}

file_mode() {
  if [[ "$stat_style" == bsd ]]; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi
}

file_size() {
  if [[ "$stat_style" == bsd ]]; then stat -f '%z' "$1"; else stat -c '%s' "$1"; fi
}

scratch=""
journal=""
journal_owned="false"
preserve="false"
stages=()
destinations=()
before_hashes=()
after_hashes=()
modes=()
phase="ready"

stage_file() { printf '%s/%s\n' "${stages[$1]}" "${destinations[$1]##*/}"; }

# Never recursively delete a path obtained from a record. Extra/unrecognized
# files prevent directory removal and are left for inspection.
remove_stage() {
  local i="$1" file
  [[ ! -L "${stages[$i]}" ]] || return 1
  [[ -e "${stages[$i]}" ]] || return 0
  [[ -d "${stages[$i]}" && -O "${stages[$i]}" ]] || return 1
  file="$(stage_file "$i")"
  validate_file "$file" || return 1
  rm -f -- "$file" && rmdir -- "${stages[$i]}"
}

cleanup() {
  local status=$? i
  trap - EXIT
  # Publication might have succeeded even if mv reported failure.
  if [[ "$journal_owned" == true && -f "$journal/record" ]]; then preserve="true"; fi
  if [[ "$preserve" != true ]]; then
    if [[ "$status" -ne 0 && -z "${reported_status:-}" ]]; then
      echo "Preparation interrupted or failed; no output replacements were made." >&2
      case "$status" in 129 | 130 | 143) ;; *) status=2 ;; esac
    fi
    for i in "${!stages[@]}"; do
      remove_stage "$i" || echo "Warning: inspect leftover stage: ${stages[$i]}" >&2
    done
    if [[ "$journal_owned" == true ]]; then
      rm -f -- "$journal/record.next"
      rmdir -- "$journal" 2>/dev/null || true
    fi
  elif [[ "$status" -ne 0 ]]; then
    printf 'Pending transaction (%s); outputs may be partially replaced. Preserve %s and run:\n  %q %q --recover\n' \
      "$phase" "$journal" "$0" "$context_log" >&2
    case "$status" in 129 | 130 | 143) ;; *) status=3 ;; esac
  fi
  [[ -z "$scratch" ]] || rm -rf -- "$scratch"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

write_record() {
  local i
  validate_file "$journal/record.next" || return 1
  # Unlink an incomplete old image rather than truncating a possible hard link;
  # noclobber then requires a fresh file instead of overwriting an existing one.
  rm -f -- "$journal/record.next" || return 1
  (
    set -C
    {
      printf '%s\0' agent-vault-rollover-v1 "$phase" "$rollover_id" || exit 1
      for i in 0 1 2; do
        printf '%s\0' "${destinations[$i]}" "${before_hashes[$i]}" "${after_hashes[$i]}" "${stages[$i]}" "${modes[$i]}" || exit 1
      done
    } >"$journal/record.next"
  ) || return 1
  [[ "$(file_size "$journal/record.next")" -le 131072 ]] || return 1
  mv -f -- "$journal/record.next" "$journal/record"
}

incomplete_record() {
  pending "incomplete transaction record: $journal; original archive/manifest paths are unknown. An empty directory may be residue from a completed rollover whose final cleanup was interrupted, or from interrupted setup/a deleted record. Stop the original writer and children and preserve recovery data. Using the ORIGINAL log/archive/manifest paths, run check-context-log-rollover.sh with --archive and --manifest and confirm each intended entry appears exactly once across the live log and archive history. Only after confirming/reconciling those outputs may rmdir remove a confirmed-empty transaction directory."
}

read_record() {
  local field="" fields=() i offset parent stage_parent stage_name count
  [[ ! -L "$journal" && -d "$journal" && -O "$journal" ]] || pending "unsafe transaction directory: $journal"
  # Empty directories can mean interrupted setup/cleanup OR a deleted record.
  # Without the destinations/fingerprints, none of these proves a safe no-op.
  if [[ ! -e "$journal/record" && ! -L "$journal/record" ]]; then
    incomplete_record
  fi
  [[ -f "$journal/record" && ! -L "$journal/record" && -O "$journal/record" ]] || pending "unsafe transaction record: $journal"
  validate_file "$journal/record.next" || pending "unsafe next-record path: $journal/record.next"
  count="$(file_size "$journal/record")" || pending "cannot read transaction size"
  [[ "$count" -le 131072 ]] || pending "transaction record exceeds size limit"
  while IFS= read -r -d '' field; do
    fields+=("$field")
    [[ "${#fields[@]}" -le 18 ]] || pending "too many transaction fields"
  done <"$journal/record"
  [[ -z "$field" && "${#fields[@]}" -eq 18 && "${fields[0]}" == agent-vault-rollover-v1 ]] || pending "invalid transaction record/version"
  phase="${fields[1]}"
  rollover_id="${fields[2]}"
  [[ "$phase" == ready || "$phase" == committed ]] || pending "invalid transaction phase"
  [[ -n "$rollover_id" ]] || pending "missing rollover ID"
  for i in 0 1 2; do
    offset=$((3 + i * 5))
    destinations[$i]="${fields[$offset]}"
    before_hashes[$i]="${fields[$((offset + 1))]}"
    after_hashes[$i]="${fields[$((offset + 2))]}"
    stages[$i]="${fields[$((offset + 3))]}"
    modes[$i]="${fields[$((offset + 4))]}"
    [[ "${destinations[$i]}" == /* && "${stages[$i]}" == /* &&
      "${before_hashes[$i]}" =~ ^(absent|[0-9a-f]{64})$ &&
      "${after_hashes[$i]}" =~ ^[0-9a-f]{64}$ && "${modes[$i]}" =~ ^[0-7]{1,4}$ ]] || pending "invalid destination record"
    parent="${destinations[$i]%/*}"
    parent="${parent:-/}"
    stage_parent="${stages[$i]%/*}"
    stage_parent="${stage_parent:-/}"
    stage_name="${stages[$i]##*/}"
    [[ "$stage_parent" == "$parent" && "$stage_name" =~ ^\.agent-vault-rollover-stage\.[a-zA-Z0-9]{6}$ &&
      ! -L "${stages[$i]}" ]] || pending "unsafe staging reference"
    [[ ! -e "${stages[$i]}" || (-d "${stages[$i]}" && -O "${stages[$i]}") ]] || pending "unsafe staging directory"
  done
  [[ "${destinations[2]}" == "$log_canon" ]] || pending "transaction belongs to a different live log"
  validate_destinations || pending "destination identities/types changed; reconcile manually"
  [[ "${stages[0]}" != "${stages[1]}" && "${stages[0]}" != "${stages[2]}" && "${stages[1]}" != "${stages[2]}" ]] || pending "aliased stages"
}

finish_transaction() {
  local i file
  for i in 0 1 2; do remove_stage "$i" || pending "committed; inspect leftover stage: ${stages[$i]}"; done
  # Detect unrecognized files before removing the record so a cleanup refusal
  # retains the authoritative committed state for the next invocation.
  for file in "$journal"/* "$journal"/.[!.]* "$journal"/..?*; do
    [[ -e "$file" || -L "$file" ]] || continue
    [[ "$file" == "$journal/record" || "$file" == "$journal/record.next" ]] || pending "committed; unexpected transaction artifact: $file"
  done
  rm -f -- "$journal/record.next" "$journal/record" || pending "committed; cannot remove transaction record"
  rmdir -- "$journal" || pending "committed; inspect leftover transaction files: $journal"
  preserve="false"
  journal_owned="false"
  stages=()
}

apply_transaction() {
  local i current file validation effective=() states=()
  # Validate the WHOLE effective result before touching any remaining output.
  for i in 0 1 2; do
    current="$(fingerprint "${destinations[$i]}")" || pending "cannot fingerprint ${destinations[$i]}"
    if [[ "$current" == "${after_hashes[$i]}" ]]; then
      effective[$i]="${destinations[$i]}"
      states[$i]=after
    elif [[ "$current" == "${before_hashes[$i]}" ]]; then
      file="$(stage_file "$i")"
      [[ -f "$file" && ! -L "$file" && -O "$file" ]] || pending "missing/unsafe staged replacement: $file"
      [[ "$(fingerprint "$file")" == "${after_hashes[$i]}" ]] || pending "damaged staged replacement: $file"
      [[ "$(file_mode "$file")" == "${modes[$i]}" ]] || pending "staged permissions changed: $file"
      effective[$i]="$file"
      states[$i]=before
    else
      pending "destination diverged; no recovery writes: ${destinations[$i]}"
    fi
    if [[ "$current" != absent ]]; then
      [[ "$(file_mode "${destinations[$i]}")" == "${modes[$i]}" ]] || pending "destination permissions changed: ${destinations[$i]}"
    fi
  done
  if ! validation="$("$checker" "${effective[2]}" --archive "${effective[0]}" --manifest "${effective[1]}" 2>&1)"; then
    pending "recorded result failed validation: $validation"
  fi
  if [[ "$dry_run" == true ]]; then
    printf '[dry-run] transaction %s: archive=%s manifest=%s log=%s; no outputs changed\n' "$rollover_id" "${states[0]}" "${states[1]}" "${states[2]}"
    return
  fi
  for i in 0 1 2; do
    [[ "${states[$i]}" == after ]] && continue
    validate_destinations || pending "destination identities changed before replacement"
    [[ "$(fingerprint "${destinations[$i]}")" == "${before_hashes[$i]}" ]] || pending "destination changed before replacement: ${destinations[$i]}"
    mv -f -- "${effective[$i]}" "${destinations[$i]}" || pending "replacement failed: ${destinations[$i]}"
  done
  for i in 0 1 2; do
    [[ "$(fingerprint "${destinations[$i]}")" == "${after_hashes[$i]}" ]] || pending "installed output changed: ${destinations[$i]}"
  done
  "$checker" "${destinations[2]}" --archive "${destinations[0]}" --manifest "${destinations[1]}" --quiet || pending "installed result failed validation"
  phase=committed
  write_record || pending "outputs installed; could not record commitment"
  finish_transaction
}

# Refusal-only safety floor for deleted journals and legacy partial rollovers.
# Compare complete entries, ignoring only trailing blank separators. Matching
# headings with different bodies are not duplicates. Never infer a resume here.
overlapping_entry() {
  awk '
    function flush() {
      if (entry == "") return
      while (entry ~ /\n[ \t\r]*$/) sub(/\n[ \t\r]*$/, "", entry)
      if (live) entries[entry] = heading
      else if (entry in entries) overlap = heading
      entry = ""
    }
    FNR == 1 { flush(); live = (FILENAME == ARGV[1]); active = !live; fence = 0 }
    {
      line = $0; sub(/\r$/, "", line)
      if (!fence && line ~ /^##[[:space:]]/) {
        flush(); active = (!live || line ~ /^## Entries[[:space:]]*$/)
      }
      if (!fence && active && line ~ /^### [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9] local - /) {
        flush(); heading = line; entry = $0 "\n"
      } else if (entry != "") entry = entry $0 "\n"
      if (line ~ /^(```|~~~)/) fence = !fence
    }
    END { if (overlap == "") flush(); if (overlap != "") print overlap }
  ' "$1" "$2"
}

# Only compare the live pointer and newest record here, not the archive named
# by that OLD record: a fresh rollover may legitimately select a new annual file.
classify_pointer() {
  awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function norm(s) { gsub(/[`*]/, "", s); gsub(/[[:space:]]+/, " ", s); return trim(s) }
    FILENAME == ARGV[1] {
      if ($0 ~ /^##[[:space:]]+Current Snapshot[[:space:]]*$/) { snapshot = 1; next }
      if ($0 ~ /^##[[:space:]]/) snapshot = 0
      if (snapshot && tolower($0) ~ /context-log rollover[[:space:]]*:/) {
        pointer = 1
        if (match($0, /`[^`]+`/)) pid = trim(substr($0, RSTART + 1, RLENGTH - 2))
        bi = index(tolower($0), "boundary:")
        if (bi) pb = norm(substr($0, bi + 9))
      }
      next
    }
    /^##[[:space:]]+rollover:/ {
      if (record) exit
      record = 1; id = $0; sub(/^##[[:space:]]+rollover:[[:space:]]*/, "", id); id = trim(id); next
    }
    record && /^##[[:space:]]/ { exit }
    record && /^[[:space:]]*[-*][[:space:]]*boundary[[:space:]]*:/ {
      mb = $0; sub(/^[^:]*:/, "", mb); mb = norm(mb)
    }
    END {
      if (pointer && !record) print "missing-manifest"
      else if ((!pointer && !record) || (pointer && record && id != "" && pid == id && pb != "" && pb == mb)) print "consistent"
      else print "inconsistent"
    }
  ' "$1" "$2"
}

# --- preconditions (outputs unchanged) -----------------------------------

if command -v sha256sum >/dev/null 2>&1; then
  hash_command=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
  hash_command=(shasum -a 256)
else die "SHA-256 utility required (sha256sum or shasum)"; fi
stat_style=gnu
if [[ "$(uname -s)" == Darwin ]]; then stat_style=bsd; fi
umask 077

log_canon="$(canonical_path "$context_log")" || die "invalid log parent path (or newline in path): $context_log"
context_log="$log_canon"
journal="${log_canon%/*}/.agent-vault-rollover-${log_canon##*/}"
if [[ "$recover" == true ]]; then
  [[ "$generation_options" == false ]] || die "--recover cannot be combined with generation options"
  if [[ ! -e "$journal" && ! -L "$journal" ]]; then
    echo "No pending transaction. Without a record, use the ordinary command with --dry-run to inspect the original destinations."
    exit 0
  fi
  preserve=true
  read_record
  if [[ "$phase" == committed ]]; then
    if [[ "$dry_run" == true ]]; then
      echo "[dry-run] committed transaction; cleanup only: $journal"
    else
      finish_transaction
      echo "Finished committed transaction cleanup."
    fi
  else
    apply_transaction
    [[ "$dry_run" == true ]] || echo "Recovered rollover $rollover_id."
  fi
  exit 0
fi
if [[ -e "$journal" || -L "$journal" ]]; then
  if [[ -d "$journal" && ! -L "$journal" && -O "$journal" && ! -e "$journal/record" && ! -L "$journal/record" ]]; then
    incomplete_record
  fi
  printf -v recovery_command '%q %q --recover' "$0" "$context_log"
  pending "pending transaction at $journal; run $recovery_command before starting another rollover"
fi
[[ -f "$context_log" ]] || die "context log not found: $context_log"
[[ -n "$keep" ]] || die "--keep is required"
[[ "$keep" =~ ^[0-9]+$ ]] || die "--keep must be a non-negative integer, got: $keep"
[[ "$keep" -ge 1 ]] || die "--keep must be >= 1 (the newest entry is always kept)"
[[ -n "$archive_file" ]] || die "--archive is required"
[[ -n "$manifest_file" ]] || die "--manifest is required"
[[ ! -d "$archive_file" ]] || die "--archive must be a file path, not an existing directory: $archive_file"
[[ ! -d "$manifest_file" ]] || die "--manifest must be a file path, not an existing directory: $manifest_file"

# The three outputs must be distinct files; otherwise self-validation passes on
# the scratch copies but the sequential commit renames clobber one another.
archive_canon="$(canonical_path "$archive_file")" || die "invalid archive parent path (or newline in path): $archive_file"
manifest_canon="$(canonical_path "$manifest_file")" || die "invalid manifest parent path (or newline in path): $manifest_file"
[[ "$log_canon" != "$archive_canon" ]] || die "--archive must differ from the context log ($archive_file)"
[[ "$log_canon" != "$manifest_canon" ]] || die "--manifest must differ from the context log ($manifest_file)"
[[ "$archive_canon" != "$manifest_canon" ]] || die "--archive and --manifest must differ ($archive_file)"
destinations=("$archive_canon" "$manifest_canon" "$log_canon")
validate_destinations || die "destinations must be distinct regular files or absent, with no symlinks, parent collisions, or reserved .agent-vault-rollover-* paths"

# Read a consistent candidate input set, then verify the originals again before
# publishing. These temporary snapshots are not persistent rollback backups.
scratch="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-compact.XXXXXX")" || die "cannot create build scratch"
inputs=()
for i in 0 1 2; do
  before_hashes[$i]="$(fingerprint "${destinations[$i]}")" || die "cannot fingerprint ${destinations[$i]}"
  mkdir -p "$scratch/before/$i" || die "cannot create input staging"
  inputs[$i]="$scratch/before/$i/${destinations[$i]##*/}"
  modes[$i]=600
  if [[ "${before_hashes[$i]}" != absent ]]; then
    modes[$i]="$(file_mode "${destinations[$i]}")" || die "cannot read permissions: ${destinations[$i]}"
    cp -- "${destinations[$i]}" "${inputs[$i]}" || die "cannot snapshot ${destinations[$i]}"
    [[ "$(fingerprint "${inputs[$i]}")" == "${before_hashes[$i]}" ]] || die "input changed during snapshot: ${destinations[$i]}"
  fi
done
archive_input="${inputs[0]}"
manifest_input="${inputs[1]}"
log_input="${inputs[2]}"

# Structure must be sound before we rearrange it. An existing archive must
# validate too: dated headings the strict boundary scan cannot see (torn
# fragments, noncanonical legacy entries) would otherwise be treated as header
# prose and silently reordered above the newer batch.
checker_args=("$log_input")
[[ -f "$archive_input" ]] && checker_args+=(--archive "$archive_input")
if ! "$checker" "${checker_args[@]}" --quiet >/dev/null 2>&1; then
  if [[ -f "$archive_file" ]]; then
    abort "context log or existing archive fails the structural rollover check; run check-context-log-rollover.sh $context_log --archive $archive_file and normalize before rolling over"
  fi
  abort "context log fails the structural rollover check; run check-context-log-rollover.sh $context_log"
fi

if [[ -f "$archive_input" ]]; then
  overlap="$(overlapping_entry "$log_input" "$archive_input")" || die "cannot compare live/archive entries"
  [[ -z "$overlap" ]] || pending "live/archive entry overlap ($overlap); record unavailable, reconcile manually before retrying"
fi
pointer_manifest="$manifest_input"
if [[ ! -f "$pointer_manifest" ]]; then
  pointer_manifest="$scratch/empty-manifest"
  : >"$pointer_manifest"
fi
pointer_state="$(classify_pointer "$log_input" "$pointer_manifest")" || die "cannot compare manifest/live pointer"
case "$pointer_state" in
  consistent)
    [[ "$adopt_manual_rollover" == false ]] || die "--adopt-manual-rollover requires a live rollover pointer and no manifest records; remove this one-time option after adoption"
    ;;
  missing-manifest)
    adoption_message="manifest $manifest_file has no rollover records, but $context_log has a rollover pointer. This may be manual history, a missing/rotated manifest, or the wrong --manifest path. Use the existing manifest or restore it; for verified manual history, use --adopt-manual-rollover (preview with --dry-run)."
    if [[ "$adopt_manual_rollover" == true ]]; then
      echo "Adopting manual history: the next write-producing rollover will create the first manifest record; previous manual records are not reconstructed." >&2
    elif [[ "$dry_run" == true ]]; then
      echo "Preview only: $adoption_message No adoption or output changes are performed." >&2
    else
      pending "$adoption_message"
    fi
    ;;
  *) pending "manifest/live pointer inconsistent; record unavailable, reconcile manually" ;;
esac

mapfile -t heading_lines < <(entry_heading_lines "$log_input")
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
top_heading="$(sed -n "${top_line}p" "$log_input" | sed -E 's/\r$//; s/^#+[[:space:]]+//')"
if [[ -n "$require_top_entry" ]]; then
  [[ "$top_heading" == *"$require_top_entry"* ]] ||
    abort "newest entry does not contain required marker \"$require_top_entry\" (gate-required rollover entry missing); newest is: $top_heading"
elif [[ "$allow_missing_top_entry" != "true" ]]; then
  abort "refusing to roll over without asserting the gate-required session entry; pass --require-top-entry <marker> (recommended) or --allow-missing-top-entry to override. Newest entry is: $top_heading"
fi

# --- build everything in a scratch dir (still no writes to real files) ---

archive_base="$(basename "$archive_file")"
mkdir -p "$scratch/after/log" "$scratch/after/archive" "$scratch/after/manifest" || die "cannot create candidate staging"
new_log="$scratch/after/log/${log_canon##*/}"
new_archive="$scratch/after/archive/$archive_base"
new_manifest="$scratch/after/manifest/${manifest_canon##*/}"

split_line="${heading_lines[$keep]}" # first archived entry heading (1-based)

# Live body = header + Current Snapshot + Usage Rules + the newest <keep> entries.
sed -n "1,$((split_line - 1))p" "$log_input" >"$scratch/live_body_raw"
strip_trailing_blanks "$scratch/live_body_raw" >"$scratch/live_body"

# Archived batch = the remaining (older) entries, newest-first as they appeared.
sed -n "${split_line},\$p" "$log_input" >"$scratch/batch_raw"
strip_trailing_blanks "$scratch/batch_raw" >"$scratch/batch"

archived_count=$((total_entries - keep))

# Build the new archive: existing header + this (newer) batch + existing entries.
if [[ -f "$archive_input" ]]; then
  first_existing="$(first_entry_line "$archive_input")"
  if [[ -n "$first_existing" ]]; then
    if [[ "$first_existing" -gt 1 ]]; then
      sed -n "1,$((first_existing - 1))p" "$archive_input" | strip_trailing_blanks - >"$scratch/arch_header"
    else
      # Headerless archive: the first entry is on line 1, so there is no header to
      # slice. sed "1,0p" would wrongly emit line 1 on GNU sed and then re-append it
      # from arch_existing, duplicating and reordering the first archived entry.
      printf '# Context Log Archive\n' >"$scratch/arch_header"
    fi
    sed -n "${first_existing},\$p" "$archive_input" >"$scratch/arch_existing"
  else
    strip_trailing_blanks "$archive_input" >"$scratch/arch_header"
    : >"$scratch/arch_existing"
  fi
  # Refuse to grow an archive whose own header carries metadata we cannot keep in
  # sync (a frontmatter "covers:" claim or a relocation manifest). Prepending a
  # newer batch below such a header silently stales it while self-validation still
  # passes, so fail closed unless the maintainer explicitly overrides.
  unmanaged_metadata="$(archive_header_has_unmanaged_metadata "$scratch/arch_header")"
  if [[ "$allow_stale_archive_metadata" != "true" && -n "$unmanaged_metadata" ]]; then
    abort "existing archive \"$archive_file\" carries header metadata this tool cannot keep in sync (a frontmatter \"covers:\" field or a relocation manifest). Prepending a newer batch would leave that header claiming an older newest entry than the archive now holds, while check-context-log-rollover.sh still passes. Update the archive frontmatter/manifest by hand (or roll over manually), or pass --allow-stale-archive-metadata to override."
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
  if [[ -f "$manifest_input" ]]; then
    next_seq="$(awk -v day="$day" '
      $0 ~ ("^## rollover: " day "-[0-9]+[[:space:]]*$") {
        s = $0; sub(/.*-/, "", s); sub(/[[:space:]]+$/, "", s)
        if (s + 0 > max) max = s + 0
      }
      END { print max + 1 }
    ' "$manifest_input")"
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

if [[ -f "$manifest_input" ]]; then
  first_record="$(grep -n '^## rollover:' "$manifest_input" | head -n1 | cut -d: -f1 || true)"
  if [[ -n "$first_record" ]]; then
    if [[ "$first_record" -gt 1 ]]; then
      sed -n "1,$((first_record - 1))p" "$manifest_input" | strip_trailing_blanks - >"$scratch/man_header"
    else
      # Headerless manifest: the first record is on line 1, so there is no header to
      # slice. sed "1,0p" would wrongly emit line 1 on GNU sed and re-append it from
      # man_existing, duplicating the first record. Seed the standard manifest header.
      printf '# Context Log Rollover Manifest\n\n<!-- One record per rollover, newest first. Maintained by compact-context-log.sh; validated by check-context-log-rollover.sh --manifest. -->\n' >"$scratch/man_header"
    fi
    sed -n "${first_record},\$p" "$manifest_input" >"$scratch/man_existing"
  else
    strip_trailing_blanks "$manifest_input" >"$scratch/man_header"
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
  echo "[dry-run] no output files changed; result passed check-context-log-rollover.sh --manifest"
  exit 0
fi

# --- prepare every destination, publish intent, then replace outputs -------

candidates=("$new_archive" "$new_manifest" "$new_log")
for i in 0 1 2; do
  parent="${destinations[$i]%/*}"
  parent="${parent:-/}"
  mkdir -p -- "$parent" || die "cannot prepare destination parent: $parent"
  stages[$i]="$(mktemp -d "$parent/.agent-vault-rollover-stage.XXXXXX")" || die "cannot stage destination: ${destinations[$i]}"
  file="$(stage_file "$i")"
  cp -- "${candidates[$i]}" "$file" || die "cannot stage replacement: ${destinations[$i]}"
  chmod "${modes[$i]}" "$file" || die "cannot preserve destination permissions: ${destinations[$i]}"
  after_hashes[$i]="$(fingerprint "${candidates[$i]}")" || die "cannot fingerprint validated candidate"
  [[ "$(fingerprint "$file")" == "${after_hashes[$i]}" ]] || die "staged replacement differs from validated candidate"
done
validate_destinations || die "destination identities changed during preparation"
for i in 0 1 2; do
  [[ "$(fingerprint "${destinations[$i]}")" == "${before_hashes[$i]}" ]] || die "input changed during preparation: ${destinations[$i]}"
done
mkdir -- "$journal" || die "cannot create transaction directory: $journal"
journal_owned=true
write_record || die "cannot publish prepared transaction: $journal"
preserve=true
apply_transaction

[[ "$quiet" == "true" ]] || echo "$summary"

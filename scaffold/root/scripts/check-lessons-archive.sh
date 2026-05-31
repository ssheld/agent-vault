#!/usr/bin/env bash
# agent-vault-managed: helper-script; file=check-lessons-archive.sh

set -euo pipefail

# Validate a lessons-archive manifest (the #116 AC5 enforcement): every archived
# lesson is classified, and the classification is well-formed. The three classes
# (from the Memory Size Budgets & Compaction policy) are:
#   - retained-as-quick-rule            : the one-line rule stays in the live
#                                         lessons.md; the full write-up is archived
#   - covered-by-a-named-always-on-rule : fully archived; "covered_by" must name a
#                                         rule that still exists in a live always-on
#                                         file (so the lesson is not silently lost)
#   - archival-only                     : archived, low recurrence risk, no live rule
#
# This is a CHECKER only: it never edits the manifest, archive, or lessons file.
# It WARNS by default (exit 0 so it cannot block an unrelated commit); pass
# --strict to exit 1 on any finding and to also enforce completeness against the
# archive (every archived lesson classified, no dangling manifest record).
#
# Manifest format (one record per archived lesson):
#   ## lesson: <key matching the archived lesson's heading text>
#   - classification: <one of the three classes above>
#   - covered_by: <live rule name/anchor>   # required for covered-by-a-named-...
#
# Exit status: 0 = clean / warnings only, 1 = findings under --strict,
# 2 = usage or IO error.

VALID_CLASSES="retained-as-quick-rule covered-by-a-named-always-on-rule archival-only"

usage() {
  cat <<EOF
Usage: $0 <manifest-file> [--archive <file>] [--rules <file>]... [--strict] [--quiet]

Validates per-lesson classifications in a lessons-archive manifest. Checks:
  - every "## lesson:" record declares a classification, and it is one of:
      retained-as-quick-rule | covered-by-a-named-always-on-rule | archival-only
  - no duplicate lesson keys
  - a covered-by-a-named-always-on-rule record names a non-empty "covered_by"
    rule that still appears in a live always-on file (when one is resolved)
  - "covered_by" is not set on a record that is not covered-by-a-named-...
With --strict and --archive (completeness):
  - every archived lesson (a "###" heading in the archive) has a manifest record
  - every manifest record points at a lesson present in the archive

The archive defaults to "<manifest-dir>/lessons-archive.md" and the live rules
source to "<manifest-dir>/../../lessons.md" when present; pass --archive / --rules
to override or add more rule sources.

Options:
  --archive <file>  Lessons archive to check completeness against (--strict).
  --rules <file>    A live always-on file to resolve "covered_by" rules in
                    (repeatable). Defaults to the project lessons.md when found.
  --strict          Exit 1 on any finding and enforce archive completeness.
  --quiet           Print only on failure.
  -h, --help        Show this help.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 2
}

manifest=""
archive_file=""
strict="false"
quiet="false"
rules_files=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive)
      [[ $# -ge 2 ]] || die "--archive requires a path"
      archive_file="$2"
      shift 2
      ;;
    --rules)
      [[ $# -ge 2 ]] || die "--rules requires a path"
      rules_files+=("$2")
      shift 2
      ;;
    --strict)
      strict="true"
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
      [[ -z "$manifest" ]] || die "unexpected extra argument: $1"
      manifest="$1"
      shift
      ;;
  esac
done

[[ -n "$manifest" ]] || {
  usage >&2
  exit 2
}
[[ -f "$manifest" ]] || die "manifest not found: $manifest"
if [[ -n "$archive_file" && ! -f "$archive_file" ]]; then
  die "archive file not found: $archive_file"
fi
for rule_src in "${rules_files[@]:-}"; do
  [[ -z "$rule_src" || -f "$rule_src" ]] || die "rules file not found: $rule_src"
done

manifest_dir="$(cd "$(dirname "$manifest")" && pwd -P)"

# Default the archive and the live-rules source to the canonical layout when the
# caller did not name them and the files exist.
if [[ -z "$archive_file" && -f "$manifest_dir/lessons-archive.md" ]]; then
  archive_file="$manifest_dir/lessons-archive.md"
fi
if [[ "${#rules_files[@]}" -eq 0 && -f "$manifest_dir/../../lessons.md" ]]; then
  rules_files+=("$manifest_dir/../../lessons.md")
fi

findings=()

# Emit "<rec>\t<field>\t<value>" for each record field, plus "COUNT\t<n>".
# Records are delimited by "## lesson:" headings; any other "## " heading ends
# the current record.
parse_manifest() {
  awk '
    function strip(s) {
      sub(/\r$/, "", s)
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    /^##[[:space:]]+lesson:/ {
      rec++
      k = $0
      sub(/^##[[:space:]]+lesson:[[:space:]]*/, "", k)
      printf "%d\tkey\t%s\n", rec, strip(k)
      inrec = 1
      next
    }
    inrec && /^##[[:space:]]/ { inrec = 0 }
    inrec {
      line = $0
      sub(/\r$/, "", line)
      if (match(line, /^[[:space:]]*[-*][[:space:]]*[A-Za-z_]+[[:space:]]*:/)) {
        sub(/^[[:space:]]*[-*][[:space:]]*/, "", line)
        ci = index(line, ":")
        printf "%d\t%s\t%s\n", rec, strip(substr(line, 1, ci - 1)), strip(substr(line, ci + 1))
      }
    }
    END { printf "COUNT\t%d\n", rec + 0 }
  ' "$1"
}

# Lesson headings in the archive: level-3 "### <title>" outside fenced code.
archive_lessons() {
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
      if (line ~ /^###[[:space:]]/) {
        sub(/^###[[:space:]]+/, "", line)
        print line
      }
    }
  ' "$1"
}

declare -A KEY=()
declare -A CLASS=()
declare -A COVERED=()
declare -A HAS_COVERED=()
count=0
while IFS=$'\t' read -r rec field value; do
  case "$rec" in
    COUNT)
      count="$field"
      continue
      ;;
  esac
  case "$field" in
    key) KEY[$rec]="$value" ;;
    classification) CLASS[$rec]="$value" ;;
    covered_by)
      COVERED[$rec]="$value"
      HAS_COVERED[$rec]="true"
      ;;
  esac
done < <(parse_manifest "$manifest")

# A covered_by value is "live" if it appears in any resolved rules file.
covered_by_is_live() {
  local needle="$1" src
  for src in "${rules_files[@]:-}"; do
    [[ -n "$src" && -f "$src" ]] || continue
    if grep -Fq -- "$needle" "$src"; then
      return 0
    fi
  done
  return 1
}

declare -A SEEN_KEY=()
manifest_keys=()
for ((i = 1; i <= count; i++)); do
  key="${KEY[$i]:-}"
  classification="${CLASS[$i]:-}"
  manifest_keys+=("$key")

  if [[ -z "$key" ]]; then
    findings+=("manifest record $i has an empty lesson key")
    continue
  fi
  if [[ -n "${SEEN_KEY[$key]:-}" ]]; then
    findings+=("duplicate lesson key: \"$key\"")
  fi
  SEEN_KEY[$key]="true"

  if [[ -z "$classification" ]]; then
    findings+=("lesson \"$key\" has no classification (expected one of: $VALID_CLASSES)")
  elif [[ " $VALID_CLASSES " != *" $classification "* ]]; then
    findings+=("lesson \"$key\" has an invalid classification \"$classification\" (expected one of: $VALID_CLASSES)")
  fi

  if [[ "$classification" == "covered-by-a-named-always-on-rule" ]]; then
    covered="${COVERED[$i]:-}"
    if [[ -z "$covered" ]]; then
      findings+=("lesson \"$key\" is covered-by-a-named-always-on-rule but names no \"covered_by\" rule")
    elif [[ "${#rules_files[@]}" -gt 0 ]]; then
      covered_by_is_live "$covered" ||
        findings+=("lesson \"$key\" covered_by rule \"$covered\" was not found in any live rules source")
    fi
  elif [[ "${HAS_COVERED[$i]:-false}" == "true" && -n "${COVERED[$i]:-}" ]]; then
    findings+=("lesson \"$key\" sets covered_by but is not covered-by-a-named-always-on-rule")
  fi
done

# Completeness: archive lessons <-> manifest records. The manifest->archive
# direction always runs when an archive is resolved; the archive->manifest
# (every archived lesson classified) direction is the --strict completeness gate.
if [[ -n "$archive_file" ]]; then
  declare -A ARCHIVE_LESSON=()
  while IFS= read -r heading; do
    [[ -n "$heading" ]] || continue
    ARCHIVE_LESSON[$heading]="true"
  done < <(archive_lessons "$archive_file")

  for key in "${manifest_keys[@]}"; do
    [[ -n "$key" ]] || continue
    [[ -n "${ARCHIVE_LESSON[$key]:-}" ]] ||
      findings+=("manifest classifies a lesson not present in the archive: \"$key\"")
  done

  if [[ "$strict" == "true" ]]; then
    for heading in "${!ARCHIVE_LESSON[@]}"; do
      [[ -n "${SEEN_KEY[$heading]:-}" ]] ||
        findings+=("archived lesson is not classified in the manifest: \"$heading\"")
    done
  fi
fi

if [[ "${#findings[@]}" -eq 0 ]]; then
  [[ "$quiet" == "true" ]] || echo "lessons-archive check passed: $manifest ($count classified)"
  exit 0
fi

label="warning"
[[ "$strict" == "true" ]] && label="FAILED"
echo "lessons-archive check $label: $manifest" >&2
for finding in "${findings[@]}"; do
  echo "- $finding" >&2
done

if [[ "$strict" == "true" ]]; then
  exit 1
fi
[[ "$quiet" == "true" ]] || echo "lessons-archive check: ${#findings[@]} warning(s); pass --strict to enforce." >&2
exit 0

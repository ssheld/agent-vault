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
# --strict to exit 1 on any finding and enforce archive completeness. Strict
# checks require an archive and a live rules source for each non-empty reference.
# Missing implicit sources produce skipped-check findings in both modes.
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
Usage: $0 <manifest-file> [--archive <file>]... [--rules <file>]... [--strict] [--quiet]

Validates per-lesson classifications in a lessons-archive manifest. Checks:
  - every "## lesson:" record declares a classification, and it is one of:
      retained-as-quick-rule | covered-by-a-named-always-on-rule | archival-only
  - no duplicate lesson keys; only the "## lesson:" heading supplies the key
  - classification, covered_by, and quick_rule each appear at most once per record
  - a covered-by-a-named-always-on-rule record names a non-empty "covered_by"
    rule that still appears in a live always-on file
  - an optional "quick_rule" on a retained-as-quick-rule record likewise still
    appears live (so a retained lesson whose rule was dropped is caught)
  - "covered_by" / "quick_rule" are not set on records of the wrong class
When an archive is resolved:
  - every manifest record points at a lesson present in the archive
With --strict (completeness):
  - every archived lesson (a "###" heading in the archive) has a record with an
    exactly valid classification; combined class names are invalid

Manifest record and section headings use # prefixes at the start of a line.
Other #/## sections end a record; deeper headings stay inside it. Underlined
(setext) section headings are not supported; use #/## sections instead.
Archive ### headings and manifest field bullets allow up to three leading
spaces; four-space or tab-indented code cannot supply headings or fields.
Unknown fields (including "key") are ignored. Repeated recognized fields are
findings, and a repeated classification cannot satisfy completeness.
Both inputs ignore fenced examples before
interpreting headings or fields. HTML comments are not filtered; their contents
can still affect validation. Put reference examples in fenced code blocks.
Fences use at least three backticks or tildes, with up to three leading spaces.
A closing fence uses the same marker, at least the opening length, and only
spaces/tabs afterward. Backtick opening info strings cannot contain backticks.
CRLF and a missing final newline are accepted.
The checker requires every fence to close: an unterminated fence is a finding
with its source/opening line. Manifest-to-archive presence checks need a complete
archive; strict archive-to-manifest classification checks need a complete
manifest. Known keys from the other input still support checks if it is incomplete.

Missing implicit sources warn with skipped checks (exit 0) by default; a run
with skipped checks does not report "check passed". Strict mode requires an
archive even for an empty manifest, and a live rules source for each non-empty
covered_by or quick_rule reference on its matching class. Archival-only records
and retained records without a non-empty quick_rule need no rules source.
Any finding prevents "check passed". Usage errors, explicitly named missing
files, and manifest/archive parser execution or read errors exit 2 in either
mode, including --quiet. Partial parser output is never accepted as success.

Rule liveness is a substring match, so name the rule with distinctive text.
The archive defaults to "<manifest-dir>/lessons-archive.md", including when
the final --archive value is "". Repeated --archive flags select the last value,
but every nonempty supplied archive path must exist.
The canonical live "<manifest-dir>/../../lessons.md" is always a rules source
when present, and --rules ADDS further sources (e.g. shared-rules.md) rather
than replacing it.
Empty --rules arguments are ignored; an existing empty file is still a source.

Options:
  --archive <file>  Lessons archive to check records against (completeness with
                    --strict; repeatable, last value selects the archive).
  --rules <file>    Additional live always-on file to resolve covered_by /
                    quick_rule references in (repeatable; added to the default
                    project lessons.md).
  --strict          Exit 1 on any finding, including unavailable required sources,
                    and enforce archive completeness.
  --quiet           Print only on failure (suppresses warn-mode warnings).
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
archive_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive)
      [[ $# -ge 2 ]] || die "--archive requires a path"
      archive_file="$2"
      archive_args+=("$2")
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
for archive_arg in "${archive_args[@]:-}"; do
  [[ -z "$archive_arg" || -f "$archive_arg" ]] || die "archive file not found: $archive_arg"
done
for rule_src in "${rules_files[@]:-}"; do
  [[ -z "$rule_src" || -f "$rule_src" ]] || die "rules file not found: $rule_src"
done

manifest_dir="$(cd "$(dirname "$manifest")" && pwd -P)"
default_rules_dir="$(dirname "$(dirname "$manifest_dir")")"
default_rules_file="${default_rules_dir%/}/lessons.md"

# Default the archive and the live-rules source to the canonical layout when the
# caller did not name them and the files exist.
if [[ -z "$archive_file" && -f "$manifest_dir/lessons-archive.md" ]]; then
  archive_file="$manifest_dir/lessons-archive.md"
fi
# The canonical live lessons.md is always a rules source when present; --rules
# ADDS further sources (e.g. shared-rules.md) rather than replacing the default.
if [[ -f "$default_rules_file" ]]; then
  rules_files+=("$default_rules_file")
fi

# Empty explicit arguments are accepted for compatibility, but do not provide
# a source to search. An existing empty file does provide a source.
rules_source_available="false"
for rule_src in "${rules_files[@]:-}"; do
  if [[ -n "$rule_src" && -f "$rule_src" ]]; then
    rules_source_available="true"
    break
  fi
done

findings=()
if [[ -z "$archive_file" ]]; then
  findings+=("archive checks skipped: no archive resolved (expected \"$manifest_dir/lessons-archive.md\"; supply --archive <file>)")
fi

# One standalone parser for both inputs keeps fence precedence and delimiter
# rules identical. Events distinguish headings from user-supplied field names:
#   record <number> key <value> | field <number> <name> <value>
#   lesson 0 heading <value> | count <number> | unclosed <opening-line>
# All fields are tab-separated. Only the final value can contain tabs.
parse_lessons_input() {
  awk -v input_kind="$1" '
    function strip(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function fenced(line, candidate, marker, run, tail) {
      candidate = line
      sub(/^ ? ? ?/, "", candidate)
      marker = substr(candidate, 1, 1)
      run = 0
      if (marker == "`" || marker == "~") {
        while (substr(candidate, run + 1, 1) == marker) run++
      }
      tail = substr(candidate, run + 1)
      if (fence_marker != "") {
        if (marker == fence_marker && run >= fence_length && tail ~ /^[ \t]*$/) {
          fence_marker = ""
        }
        return 1
      }
      if (run < 3) return 0
      # Backtick info strings cannot contain backticks; tilde strings can.
      if (marker == "`" && index(tail, "`") != 0) return 0
      fence_marker = marker
      fence_length = run
      fence_line = NR
      return 1
    }
    {
      sub(/\r$/, "")
      if (fenced($0)) next
      if (input_kind == "archive") {
        line = $0
        sub(/^ ? ? ?/, "", line)
        sub(/[[:space:]]+$/, "", line)
        if (line ~ /^###[[:space:]]/) {
          sub(/^###[[:space:]]+/, "", line)
          printf "lesson\t0\theading\t%s\n", line
        }
        next
      }
      if ($0 ~ /^##[[:space:]]+lesson:/) {
        rec++
        key = $0
        sub(/^##[[:space:]]+lesson:[[:space:]]*/, "", key)
        printf "record\t%d\tkey\t%s\n", rec, strip(key)
        inrec = 1
        next
      }
      if ($0 ~ /^##?([[:space:]]|$)/) inrec = 0
      if (inrec) {
        line = $0
        if (match(line, /^ ? ? ?[-*][[:space:]]*[A-Za-z_]+[[:space:]]*:/)) {
          sub(/^ ? ? ?[-*][[:space:]]*/, "", line)
          ci = index(line, ":")
          printf "field\t%d\t%s\t%s\n", rec, strip(substr(line, 1, ci - 1)), strip(substr(line, ci + 1))
        }
      }
    }
    END {
      if (input_kind == "manifest") printf "count\t%d\n", rec + 0
      if (fence_marker != "") printf "unclosed\t%d\n", fence_line
    }
  ' <"$2"
}

# Capture status before consuming any output. A failing producer can emit an
# empty or partial parse, and process substitution would hide that failure.
manifest_output="$(parse_lessons_input manifest "$manifest")" || die "could not parse manifest: $manifest"
manifest_complete="true"
declare -A KEY=()
declare -A CLASS=()
declare -A COVERED=()
declare -A HAS_COVERED=()
declare -A QUICK=()
declare -A HAS_QUICK=()
declare -A SEEN_FIELD=()
declare -A DUPLICATE_FIELD=()
count=0
while IFS=$'\t' read -r event rec field value; do
  case "$event" in
    count) count="$rec" ;;
    record) KEY[$rec]="$value" ;;
    unclosed)
      manifest_complete="false"
      findings+=("unterminated fence in manifest: $manifest:$rec (archive classification completeness check skipped)")
      ;;
    field)
      case "$field" in
        classification | covered_by | quick_rule) ;;
        *) continue ;;
      esac
      field_key="$rec:$field"
      if [[ -n "${SEEN_FIELD[$field_key]:-}" ]]; then
        DUPLICATE_FIELD[$field_key]="true"
        continue
      fi
      SEEN_FIELD[$field_key]="true"
      case "$field" in
        classification) CLASS[$rec]="$value" ;;
        covered_by)
          COVERED[$rec]="$value"
          HAS_COVERED[$rec]="true"
          ;;
        quick_rule)
          QUICK[$rec]="$value"
          HAS_QUICK[$rec]="true"
          ;;
      esac
      ;;
  esac
done <<<"$manifest_output"

# A rule reference (covered_by / quick_rule) is "live" if it appears in any
# resolved rules file.
rule_is_live() {
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
declare -A CLASSIFIED_KEY=()
classified_count=0
for ((i = 1; i <= count; i++)); do
  key="${KEY[$i]:-}"
  classification="${CLASS[$i]:-}"

  if [[ -z "$key" ]]; then
    findings+=("manifest record $i has an empty lesson key")
    continue
  fi
  if [[ -n "${SEEN_KEY[$key]:-}" ]]; then
    findings+=("duplicate lesson key: \"$key\"")
  fi
  SEEN_KEY[$key]="true"

  duplicate_class="false"
  for record_field in classification covered_by quick_rule; do
    field_key="$i:$record_field"
    if [[ -n "${DUPLICATE_FIELD[$field_key]:-}" ]]; then
      findings+=("lesson \"$key\" repeats \"$record_field\" field")
      [[ "$record_field" != classification ]] || duplicate_class="true"
    fi
  done

  case "$classification" in
    retained-as-quick-rule | covered-by-a-named-always-on-rule | archival-only)
      [[ "$duplicate_class" == "false" ]] || continue
      if [[ -z "${CLASSIFIED_KEY[$key]:-}" ]]; then
        CLASSIFIED_KEY[$key]="true"
        classified_count=$((classified_count + 1))
      fi
      ;;
    '')
      findings+=("lesson \"$key\" has no classification (expected one of: $VALID_CLASSES)")
      continue
      ;;
    *)
      findings+=("lesson \"$key\" has an invalid classification \"$classification\" (expected one of: $VALID_CLASSES)")
      continue
      ;;
  esac

  if [[ "$classification" == "covered-by-a-named-always-on-rule" ]]; then
    covered="${COVERED[$i]:-}"
    if [[ -z "$covered" ]]; then
      findings+=("lesson \"$key\" is covered-by-a-named-always-on-rule but names no \"covered_by\" rule")
    elif [[ "$rules_source_available" == "true" ]]; then
      rule_is_live "$covered" ||
        findings+=("lesson \"$key\" covered_by rule \"$covered\" was not found in any live rules source")
    else
      findings+=("lesson \"$key\" covered_by liveness check skipped: no live rules source resolved (expected \"$default_rules_file\"; supply --rules <file>)")
    fi
  elif [[ "${HAS_COVERED[$i]:-false}" == "true" && -n "${COVERED[$i]:-}" ]]; then
    findings+=("lesson \"$key\" sets covered_by but is not covered-by-a-named-always-on-rule")
  fi

  # retained-as-quick-rule keeps a one-line rule live in lessons.md. quick_rule is
  # optional, but when given it is liveness-checked the same way as covered_by, so
  # a misclassified retained lesson whose rule is gone is caught.
  if [[ "$classification" == "retained-as-quick-rule" ]]; then
    quick="${QUICK[$i]:-}"
    if [[ -n "$quick" ]]; then
      if [[ "$rules_source_available" == "true" ]]; then
        rule_is_live "$quick" ||
          findings+=("lesson \"$key\" quick_rule \"$quick\" was not found in any live rules source (its retained one-line rule should still be in lessons.md)")
      else
        findings+=("lesson \"$key\" quick_rule liveness check skipped: no live rules source resolved (expected \"$default_rules_file\"; supply --rules <file>)")
      fi
    fi
  elif [[ "${HAS_QUICK[$i]:-false}" == "true" && -n "${QUICK[$i]:-}" ]]; then
    findings+=("lesson \"$key\" sets quick_rule but is not retained-as-quick-rule")
  fi
done

# An absence claim requires a complete parse of the file being searched. Keys
# already seen in the other input still support findings when that input is
# incomplete; only its unseen suffix is unavailable.
if [[ -n "$archive_file" ]]; then
  archive_output="$(parse_lessons_input archive "$archive_file")" || die "could not parse archive: $archive_file"
  archive_complete="true"
  declare -A ARCHIVE_LESSON=()
  while IFS=$'\t' read -r event rec field value; do
    case "$event" in
      lesson)
        [[ -z "$value" ]] || ARCHIVE_LESSON[$value]="true"
        ;;
      unclosed)
        archive_complete="false"
        findings+=("unterminated fence in archive: $archive_file:$rec (manifest lesson presence checks skipped)")
        ;;
    esac
  done <<<"$archive_output"

  if [[ "$archive_complete" == "true" ]]; then
    for key in "${!SEEN_KEY[@]}"; do
      [[ -n "${ARCHIVE_LESSON[$key]:-}" ]] ||
        findings+=("manifest classifies a lesson not present in the archive: \"$key\"")
    done
  fi

  if [[ "$strict" == "true" && "$manifest_complete" == "true" ]]; then
    for heading in "${!ARCHIVE_LESSON[@]}"; do
      [[ -n "${CLASSIFIED_KEY[$heading]:-}" ]] ||
        findings+=("archived lesson is not classified in the manifest: \"$heading\"")
    done
  fi
fi

if [[ "${#findings[@]}" -eq 0 ]]; then
  [[ "$quiet" == "true" ]] || echo "lessons-archive check passed: $manifest ($classified_count classified)"
  exit 0
fi

# Under --strict the findings are failures (exit 1) and are always reported, even
# with --quiet ("print only on failure"). In warn mode they are non-fatal
# warnings (exit 0), so --quiet suppresses them.
if [[ "$strict" == "true" ]]; then
  echo "lessons-archive check FAILED: $manifest" >&2
  for finding in "${findings[@]}"; do
    echo "- $finding" >&2
  done
  exit 1
fi

if [[ "$quiet" != "true" ]]; then
  echo "lessons-archive check warning: $manifest" >&2
  for finding in "${findings[@]}"; do
    echo "- $finding" >&2
  done
  echo "lessons-archive check: ${#findings[@]} warning(s); pass --strict to enforce." >&2
fi
exit 0

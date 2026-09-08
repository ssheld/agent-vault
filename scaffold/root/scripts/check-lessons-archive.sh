#!/usr/bin/env bash
# agent-vault-managed: helper-script; file=check-lessons-archive.sh

set -euo pipefail

# Keep this trusted, static awk source identical in all four standalone helpers.
# Tests check marker integrity, equality, and caller behavior.
# BEGIN markdown fences
markdown_fences='
    function reset_fence() { fence_marker = ""; fence_length = 0; fence_line = 0 }
    function fenced(line, candidate, marker, run, tail) {
      candidate = line
      sub(/\r$/, "", candidate)
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
      if (marker == "`" && index(tail, "`") != 0) return 0
      fence_marker = marker
      fence_length = run
      fence_line = FNR
      return 1
    }
    FNR == 1 { reset_fence() }
'
# END markdown fences

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
Other #/## sections end a record; deeper headings stay inside it. Supported
underlined (setext) sections also end a record, but never create one.
Setext titles and underlines start at column zero. Every title line begins
with an ASCII letter/digit and is not an ordered list marker. A title starts
after a blank line, a column-zero ATX heading/thematic break, a fence/comment
block, or at file start. Multiline titles have no intervening blank lines.
The next line is one or more identical = or - characters, optionally followed
by spaces/tabs. Indented, punctuation-led, and non-ASCII-led titles are outside
this flat grammar; use a column-zero #/## heading for those sections.
Outside fences/comments, a line beginning with < after zero to three spaces
is unsupported HTML-like content (including autolinks and literal < text).
The first such line produces a finding with its source/line and disables
setext boundaries for the rest of that manifest. ATX records, fields, and
other checks continue. Use fenced code or supported comments for examples.
Archive ### headings and manifest field bullets allow up to three leading
spaces; four-space or tab-indented code cannot supply headings or fields.
Unknown fields (including "key") are ignored. Repeated recognized fields are
findings, and a repeated classification cannot satisfy completeness.
Both inputs ignore fenced examples and HTML comment blocks before interpreting
headings or fields. A comment block starts with <!-- after zero to three leading
spaces and consumes through the whole physical line containing the first -->.
Commented headings/fields and closing-line suffixes never become records or fields.
Fences inside comments and comment markers inside fences are inert.
Inline comments are unsupported and remain literal heading/field text; they are
not guaranteed to produce a finding. Four-space or tab-indented comment markers
do not open a block. Use fenced code for reference examples. HTML comments do
not nest: a comment cannot wrap example content containing -->.
Fences use at least three backticks or tildes, with up to three leading spaces.
A closing fence uses the same marker, at least the opening length, and only
spaces/tabs afterward. Backtick opening info strings cannot contain backticks.
CRLF and a missing final newline are accepted.
The checker requires every fence and comment block to close: an unterminated
block is a finding with its source/opening line. Manifest-to-archive presence
checks need a complete archive; strict archive-to-manifest classification checks
need a complete manifest. Known keys from the other input still support checks
if it is incomplete.

Missing implicit sources warn with skipped checks (exit 0) by default; a run
with skipped checks does not report "check passed". Strict mode requires an
archive even for an empty manifest, and a live rules source for each non-empty
covered_by or quick_rule reference on its matching class. Archival-only records
and retained records without a non-empty quick_rule need no rules source.
Any finding prevents "check passed". Usage errors, explicitly named missing
files, and manifest/archive parser execution or read errors exit 2 in either
mode, including --quiet. Partial parser output is never accepted as success.

Rule liveness is a case-sensitive literal substring match on eligible physical
lines in rules sources. Prose, headings, bullets, and ordinary inline code count.
Fenced examples and four-space/tab-indented lines do not. Name code-only rules
with a descriptive prose heading outside the example, and reference that text.
Rules fences also recognize repeated quote (>) and list (-, +, *, 1., 1)) prefixes;
closers must retain the quote prefixes/list content indents and normal fence
closing rules. Container ends do not implicitly close fences.
Rules comments can start anywhere on a non-code line. Only text before the first
<!-- is eligible; comment contents and the whole closing-line suffix are excluded.
Comment state continues across lines, including paragraph-interrupting lists.
This is conservative filtering, not full Markdown parsing: literal/escaped HTML
comment markers also participate. Use entity spelling when describing a marker.
Fence markers after ordinary prose are literal; at the start of a line or after
recognized quote/list prefixes they can open a fence and require a matching closer.
Every resolved rules source is scanned when a reference needs checking. An
unterminated fence/comment discards that source's matches and is a finding even
if another source matches. Unmatched references are unverifiable when any source
is incomplete; otherwise they are reported as not found. Rules read/parser
errors exit 2, even after another source matched. Unused rules need no scan.
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

# Resolve once and deduplicate identical paths, retaining existing empty files.
# A later read failure must not turn an already resolved source into "missing".
resolved_rules=()
declare -A SEEN_SOURCE=()
for rule_src in "${rules_files[@]:-}"; do
  [[ -n "$rule_src" ]] || continue
  source_dir="$(cd "$(dirname "$rule_src")" && pwd -P)" || die "could not resolve rules source: $rule_src"
  rule_src="${source_dir%/}/$(basename "$rule_src")"
  [[ -z "${SEEN_SOURCE[$rule_src]:-}" ]] || continue
  SEEN_SOURCE[$rule_src]=true
  resolved_rules+=("$rule_src")
done

findings=()
if [[ -z "$archive_file" ]]; then
  findings+=("archive checks skipped: no archive resolved (expected \"$manifest_dir/lessons-archive.md\"; supply --archive <file>)")
fi

# One standalone parser shares fence rules across all inputs. Rules sources
# additionally filter inline comments and recognize container-prefixed fences. Events distinguish headings from user-supplied field names:
#   record <number> key <value> | field <number> <name> <value>
#   lesson 0 heading <value> | count <number> | unclosed <opening-line>
#   unclosed_comment <opening-line> | unsupported_html <first-line>
#   matched <reference-id>
# All fields are tab-separated. Only the final value can contain tabs.
parse_lessons_input() {
  LESSONS_RULE_REFERENCES="${reference_file:-}" awk -v input_kind="$1" "$markdown_fences"'
    BEGIN {
      reset_manifest_paragraph()
      if (input_kind == "rules") {
        path = ENVIRON["LESSONS_RULE_REFERENCES"]
        while ((status = (getline needle < path)) > 0) needles[++needle_count] = needle
        if (status < 0 || close(path) != 0) exit 2
      }
    }
    function strip(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function commented(line) {
      if (!in_comment) {
        if (line !~ /^ ? ? ?<!--/) return 0
        in_comment = 1
        comment_line = NR
      }
      if (index(line, "-->") != 0) in_comment = 0
      # HTML blocks end with the whole physical closing line, including suffixes.
      return 1
    }
    function reset_manifest_paragraph() {
      manifest_paragraph = 0
      manifest_block_start = 1
    }
    # A bounded flat grammar: only ASCII prose starts can seed a title.
    # Block starts must be precise, or lazy quote/list text can become a title.
    # Raw HTML can contain blanks; diagnose it and disable setext for this file.
    function setext_boundary(line) {
      if (!unsupported_html_line && line ~ /^ ? ? ?</) {
        unsupported_html_line = NR
        printf "unsupported_html\t%d\n", NR
      }
      if (!unsupported_html_line && manifest_paragraph && line ~ /^(=+|-+)[ \t]*$/) {
        manifest_paragraph = 0
        manifest_block_start = 0
        return 1
      }
      if (line ~ /^[ \t]*$/) {
        reset_manifest_paragraph()
      } else {
        # List bytes explicitly so locale collation cannot broaden ASCII ranges.
        manifest_paragraph = (line ~ /^[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789]/ &&
          line !~ /^[0-9]+[.)]([ \t]|$)/ &&
          (manifest_block_start || manifest_paragraph))
        # POSIX awk EREs have no backreferences. Each break uses one marker,
        # repeated at least three times; mixed/short runs do not end a block.
        manifest_block_start = (line ~ /^#{1,6}([ \t]|$)/ ||
          line ~ /^(-[ \t]*){3,}$/ || line ~ /^(\*[ \t]*){3,}$/ ||
          line ~ /^(_[ \t]*){3,}$/)
      }
      return 0
    }
    # Only delimiter recognition expands tabs. Matching uses original bytes.
    function expanded(line, out, i, ch) {
      out = ""
      for (i = 1; i <= length(line); i++) {
        ch = substr(line, i, 1)
        if (ch == "\t") {
          do { out = out " " } while (length(out) % 4 != 0)
        } else out = out ch
      }
      return out
    }
    # Bounded container syntax: repeated quote/list prefixes. Remember each
    # list content indent, so a deeply indented or sibling fence cannot close
    # an earlier block. Container ends never implicitly close a fence here.
    function rules_fenced(line, candidate, i, width, prefix, marker) {
      candidate = expanded(line)
      if (fence_marker != "") {
        for (i = 1; i <= container_count; i++) {
          if (container[i] == ">") {
            if (!match(candidate, /^ ? ? ?> ?/)) return 1
            candidate = substr(candidate, RLENGTH + 1)
          } else {
            width = container[i]
            prefix = substr(candidate, 1, width)
            if (length(prefix) != width || prefix !~ /^ *$/) return 1
            candidate = substr(candidate, width + 1)
          }
        }
        return fenced(candidate)
      }
      container_count = 0
      while (1) {
        if (match(candidate, /^ ? ? ?> ?/)) {
          container[++container_count] = ">"
          candidate = substr(candidate, RLENGTH + 1)
        } else if (match(candidate, /^ ? ? ?([-+*]|[0-9][0-9]*[.)]) /)) {
          width = RLENGTH
          marker = substr(candidate, 1, width)
          sub(/^ */, "", marker)
          if (marker ~ /^[0-9]/ && length(marker) > 11) break
          # One to four spaces after a list marker establish its content indent.
          prefix = substr(candidate, width + 1)
          if (match(prefix, /^ {1,3}([^ ]|$)/)) {
            while (substr(candidate, width + 1, 1) == " ") width++
          }
          container[++container_count] = width
          candidate = substr(candidate, width + 1)
        } else break
      }
      return fenced(candidate)
    }
    # Conservative rules-only comment filtering, including inline openers.
    # Keep only the prefix before the first comment, never join fragments.
    # Still inspect discarded suffixes for comments continuing onto later lines.
    function rules_text(line, candidate, rest, pos) {
      candidate = in_comment ? "" : line
      rest = line
      while (length(rest)) {
        if (in_comment) {
          pos = index(rest, "-->")
          if (!pos) break
          in_comment = 0
          rest = substr(rest, pos + 3)
        } else {
          pos = index(rest, "<!--")
          if (!pos) break
          if (candidate == line) candidate = substr(line, 1, pos - 1)
          in_comment = 1
          comment_line = NR
          rest = substr(rest, pos + 4)
        }
      }
      return candidate
    }
    function match_rules(line, id) {
      for (id = 1; id <= needle_count; id++) {
        if (index(line, needles[id])) matched[id] = 1
      }
    }
    {
      sub(/\r$/, "")
      if (input_kind == "rules") {
        if (in_comment) { rules_text($0); next }
        if (rules_fenced($0)) next
        if ($0 ~ /^(    | *\t)/) next
        match_rules(rules_text($0))
        next
      }
      # An active block owns its contents; neither parser can start the other.
      if (in_comment) {
        commented($0)
        reset_manifest_paragraph()
        next
      }
      if (fenced($0)) { reset_manifest_paragraph(); next }
      if (commented($0)) { reset_manifest_paragraph(); next }
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
      if (setext_boundary($0)) { inrec = 0; next }
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
      if (input_kind == "rules") {
        for (id = 1; id <= needle_count; id++) {
          if (matched[id]) printf "matched\t%d\n", id
        }
      }
      if (input_kind == "manifest") printf "count\t%d\n", rec + 0
      if (fence_marker != "") printf "unclosed\t%d\n", fence_line
      if (in_comment) printf "unclosed_comment\t%d\n", comment_line
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
    unclosed_comment)
      manifest_complete="false"
      findings+=("unterminated HTML comment in manifest: $manifest:$rec (archive classification completeness check skipped)")
      ;;
    unsupported_html)
      findings+=("unsupported HTML-like content in manifest: $manifest:$rec (setext boundaries disabled; use fenced code or HTML comments for examples)")
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

# Defer liveness until record validation has selected the applicable references.
declare -A REFERENCE_ID=()
declare -A EVENT_REFERENCE=()
declare -a REFERENCES=()
declare -A PENDING_ID=()
declare -A PENDING_FIELD=()
queue_reference() {
  local record="$1" name="$2" needle="$3" id
  id="${REFERENCE_ID[$needle]:-}"
  if [[ -z "$id" ]]; then
    id="${#REFERENCES[@]}"
    REFERENCES+=("$needle")
    REFERENCE_ID[$needle]="$id"
    EVENT_REFERENCE[$((id + 1))]="$id"
  fi
  PENDING_ID[$record]="$id"
  PENDING_FIELD[$record]="$name"
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
    else
      queue_reference "$i" covered_by "$covered"
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
      queue_reference "$i" quick_rule "$quick"
    fi
  elif [[ "${HAS_QUICK[$i]:-false}" == "true" && -n "${QUICK[$i]:-}" ]]; then
    findings+=("lesson \"$key\" sets quick_rule but is not retained-as-quick-rule")
  fi
done

# Scan all sources, even after every needle matches. References are file data,
# not awk assignments (which interpret backslash escapes) or program source.
reference_file=""
cleanup_references() {
  [[ -z "$reference_file" ]] || rm -f -- "$reference_file"
}
trap cleanup_references EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
rules_complete=true
declare -A LIVE_ID=()
if [[ "${#REFERENCES[@]}" -gt 0 && "${#resolved_rules[@]}" -gt 0 ]]; then
  reference_file="$(mktemp "${TMPDIR:-/tmp}/agent-vault-rule-references.XXXXXX")" || die "could not create rule reference data"
  printf '%s\n' "${REFERENCES[@]}" >"$reference_file" || die "could not write rule reference data"
  for rule_src in "${resolved_rules[@]}"; do
    rules_output="$(parse_lessons_input rules "$rule_src")" || die "could not parse rules source: $rule_src"
    source_complete=true
    source_matches=()
    while IFS=$'\t' read -r event id extra; do
      case "$event" in
        matched)
          # Validate producer IDs against submitted references as strings.
          [[ "$id" =~ ^[1-9][0-9]*$ && -z "$extra" ]] || die "invalid rules parser event: $rule_src"
          [[ -n "${EVENT_REFERENCE[$id]:-}" ]] || die "invalid rules parser reference: $rule_src"
          source_matches+=("${EVENT_REFERENCE[$id]}")
          ;;
        unclosed | unclosed_comment)
          source_complete=false
          rules_complete=false
          block=fence
          [[ "$event" != unclosed_comment ]] || block='HTML comment'
          findings+=("unterminated $block in rules source: $rule_src:$id (source matches discarded)")
          ;;
        '') ;;
        *) die "invalid rules parser event: $rule_src" ;;
      esac
    done <<<"$rules_output"
    if [[ "$source_complete" == true ]]; then
      for id in "${source_matches[@]}"; do LIVE_ID[$id]=true; done
    fi
  done
fi
for ((i = 1; i <= count; i++)); do
  [[ -n "${PENDING_FIELD[$i]:-}" ]] || continue
  field="${PENDING_FIELD[$i]}"
  id="${PENDING_ID[$i]}"
  key="${KEY[$i]}"
  needle="${REFERENCES[$id]}"
  if [[ "${#resolved_rules[@]}" -eq 0 ]]; then
    findings+=("lesson \"$key\" $field liveness check skipped: no live rules source resolved (expected \"$default_rules_file\"; supply --rules <file>)")
  elif [[ -n "${LIVE_ID[$id]:-}" ]]; then
    continue
  elif [[ "$rules_complete" != true ]]; then
    findings+=("lesson \"$key\" $field liveness check skipped: unverifiable because a rules source is incomplete")
  else
    suffix=""
    [[ "$field" != quick_rule ]] || suffix=' (its retained one-line rule should still be in lessons.md)'
    findings+=("lesson \"$key\" $field rule \"$needle\" was not found in any live rules source$suffix")
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
      unclosed_comment)
        archive_complete="false"
        findings+=("unterminated HTML comment in archive: $archive_file:$rec (manifest lesson presence checks skipped)")
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

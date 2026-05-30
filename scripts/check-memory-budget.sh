#!/usr/bin/env bash

set -euo pipefail

# Report the size of an agent-vault project's always-on / session-start memory
# against budgets, in three buckets:
#   1. Claude/Gemini @-import chain   (auto-discovered from CLAUDE.md, loaded
#                                      into every session)
#   2. Codex AGENTS chain             (AGENTS.md files Codex concatenates up to
#                                      its own project_doc_max_bytes cap)
#   3. Protocol-read files            (named by session-start rules; read, not
#                                      auto-imported)
#
# Defaults are sane but configurable, and the check is tolerant of missing
# files (reported, never fatal). By default it REPORTS and WARNS but exits 0 so
# it never blocks unrelated commits on a mature repo; pass --strict to fail on
# a non-excepted over-budget file or bucket. A file may be listed in an
# exceptions file (path<TAB>reason) to document an intentional overage -- the
# reason is printed and the file does not count as a strict violation.

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --repo <path>            Project root to inspect (default: git top-level or cwd).
  --file-budget <chars>    Per-file budget in characters (default: 40000).
  --chain-budget <chars>   Always-on @-chain total budget (default: 120000).
  --protocol-read "<list>" Space-separated repo-relative protocol-read files
                           (default: the canonical agent-vault session-start set).
  --exceptions <file>      File of "path<TAB>reason" lines documenting allowed
                           overages (does not count as a strict violation).
  --strict                 Exit 1 when a non-excepted file or bucket is over budget.
  --format text|tsv        Output format (default: text).
  -h, --help               Show this help.

Exit status: 0 = within budget or non-strict; 1 = strict violation; 2 = usage/IO error.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 2
}

repo=""
file_budget=40000
chain_budget=120000
protocol_read_override=""
exceptions_file=""
strict="false"
format="text"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires a path"
      repo="$2"
      shift 2
      ;;
    --file-budget)
      [[ $# -ge 2 ]] || die "--file-budget requires a number"
      file_budget="$2"
      shift 2
      ;;
    --chain-budget)
      [[ $# -ge 2 ]] || die "--chain-budget requires a number"
      chain_budget="$2"
      shift 2
      ;;
    --protocol-read)
      [[ $# -ge 2 ]] || die "--protocol-read requires a value"
      protocol_read_override="$2"
      shift 2
      ;;
    --exceptions)
      [[ $# -ge 2 ]] || die "--exceptions requires a path"
      exceptions_file="$2"
      shift 2
      ;;
    --strict)
      strict="true"
      shift
      ;;
    --format)
      [[ $# -ge 2 ]] || die "--format requires a value"
      format="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

[[ "$file_budget" =~ ^[0-9]+$ ]] || die "--file-budget must be a non-negative integer"
[[ "$chain_budget" =~ ^[0-9]+$ ]] || die "--chain-budget must be a non-negative integer"
[[ "$format" == "text" || "$format" == "tsv" ]] || die "--format must be text or tsv"

if [[ -z "$repo" ]]; then
  repo="$(git -C "${PWD}" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$repo" ]] || repo="$PWD"
fi
repo="$(cd "$repo" 2>/dev/null && pwd -P)" || die "repo path not found: $repo"

if [[ -n "$exceptions_file" && ! -f "$exceptions_file" ]]; then
  die "exceptions file not found: $exceptions_file"
fi

# --- exceptions ----------------------------------------------------------

declare -A EXCEPTION_REASON=()
if [[ -n "$exceptions_file" ]]; then
  while IFS=$'\t' read -r ex_path ex_reason; do
    [[ -n "$ex_path" ]] || continue
    [[ "$ex_path" == \#* ]] && continue
    EXCEPTION_REASON["$ex_path"]="${ex_reason:-documented exception}"
  done <"$exceptions_file"
fi

# --- @-import chain discovery -------------------------------------------

declare -A SEEN_CHAIN=()
CHAIN_FILES=()

normalize_relpath() {
  local p="$1"
  p="${p#./}"
  while [[ "$p" == *"/./"* ]]; do
    p="${p//\/.\//\/}"
  done
  printf '%s' "$p"
}

resolve_at_imports() {
  local rel="$1"
  local depth="$2"
  local abs="$repo/$rel"

  [[ "$depth" -le 8 ]] || return 0
  [[ -f "$abs" ]] || return 0
  [[ -z "${SEEN_CHAIN[$rel]:-}" ]] || return 0

  SEEN_CHAIN["$rel"]=1
  CHAIN_FILES+=("$rel")

  local dir
  dir="$(dirname "$rel")"

  local line target resolved
  while IFS= read -r line; do
    target="${line#@}"
    target="${target%%[[:space:]]*}"
    [[ -n "$target" ]] || continue
    [[ "$target" == /* ]] && continue
    if [[ "$dir" == "." ]]; then
      resolved="$target"
    else
      resolved="$dir/$target"
    fi
    resolved="$(normalize_relpath "$resolved")"
    resolve_at_imports "$resolved" "$((depth + 1))"
  done < <(grep -E '^@[^[:space:]]' "$abs" || true)
}

# The always-on chain entry points: a project root CLAUDE.md / GEMINI.md.
for entry in "CLAUDE.md" "GEMINI.md"; do
  [[ -f "$repo/$entry" ]] && resolve_at_imports "$entry" 0
done

# --- bucket file lists ---------------------------------------------------

agents_files=()
for candidate in "AGENTS.md" "agent-vault/AGENTS.md"; do
  agents_files+=("$candidate")
done

default_protocol_read=(
  "agent-vault/context-log.md"
  "agent-vault/plan.md"
  "agent-vault/open-questions.md"
  "agent-vault/decision-log.md"
  "agent-vault/coding-standards.md"
  "agent-vault/README.md"
)
protocol_read_files=()
if [[ -n "$protocol_read_override" ]]; then
  read -r -a protocol_read_files <<<"$protocol_read_override"
else
  protocol_read_files=("${default_protocol_read[@]}")
fi

# --- measurement ---------------------------------------------------------

violations=0

char_count() {
  local abs="$1"
  wc -c <"$abs" | tr -d '[:space:]'
}

emit_row() {
  local bucket="$1" rel="$2" status="$3" chars="$4" note="$5"
  if [[ "$format" == "tsv" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$bucket" "$rel" "$status" "$chars" "$note"
  else
    printf '  %-7s %-44s %10s  %s\n' "$status" "$rel" "$chars" "$note"
  fi
}

# Measure one bucket: print a row per file and accumulate the bucket's total
# character count into the caller-named variable (passed by nameref). Missing
# files are reported and skipped; non-excepted over-budget files increment the
# global violations counter.
measure_bucket() {
  local bucket="$1"
  shift
  local -n total_ref="$1"
  shift
  local rel abs chars status note
  total_ref=0

  for rel in "$@"; do
    abs="$repo/$rel"
    if [[ ! -f "$abs" ]]; then
      emit_row "$bucket" "$rel" "MISSING" "-" "(optional file absent)"
      continue
    fi
    chars="$(char_count "$abs")"
    total_ref=$((total_ref + chars))
    note=""
    status="ok"
    if [[ "$chars" -gt "$file_budget" ]]; then
      if [[ -n "${EXCEPTION_REASON[$rel]:-}" ]]; then
        status="EXCEPT"
        note="over file budget; documented: ${EXCEPTION_REASON[$rel]}"
      else
        status="OVER"
        note="over file budget ($file_budget)"
        violations=$((violations + 1))
      fi
    fi
    emit_row "$bucket" "$rel" "$status" "$chars" "$note"
  done
}

if [[ "$format" == "text" ]]; then
  echo "Memory budget report for: $repo"
  echo "Per-file budget: $file_budget chars | @-chain budget: $chain_budget chars"
  echo
fi

chain_total=0
agents_total=0
protocol_total=0

if [[ "$format" == "text" ]]; then echo "[1] Claude/Gemini @-import chain (always-on, every session):"; fi
if [[ "${#CHAIN_FILES[@]}" -eq 0 ]]; then
  emit_row "chain" "(no CLAUDE.md/GEMINI.md @-chain found)" "MISSING" "-" ""
else
  measure_bucket "chain" chain_total "${CHAIN_FILES[@]}"
fi

if [[ "$format" == "text" ]]; then
  echo
  echo "[2] Codex AGENTS chain (concatenated up to Codex project_doc_max_bytes):"
fi
measure_bucket "agents" agents_total "${agents_files[@]}"

if [[ "$format" == "text" ]]; then
  echo
  echo "[3] Protocol-read files (session-start reads; not auto-imported):"
fi
measure_bucket "protocol" protocol_total "${protocol_read_files[@]}"

chain_status="ok"
if [[ "$chain_total" -gt "$chain_budget" ]]; then
  chain_status="OVER"
  violations=$((violations + 1))
fi

if [[ "$format" == "tsv" ]]; then
  printf 'TOTAL\tchain\t%s\t%s\t\n' "$chain_status" "$chain_total"
  printf 'TOTAL\tagents\t-\t%s\t\n' "$agents_total"
  printf 'TOTAL\tprotocol\t-\t%s\t\n' "$protocol_total"
else
  echo
  echo "Totals:"
  printf '  %-7s %-44s %10s  %s\n' "$chain_status" "@-chain total" "$chain_total" "(budget $chain_budget)"
  printf '  %-7s %-44s %10s\n' "ok" "Codex AGENTS total" "$agents_total"
  printf '  %-7s %-44s %10s\n' "ok" "protocol-read total" "$protocol_total"
  echo
  if [[ "$violations" -eq 0 ]]; then
    echo "Within budget (no non-excepted overages)."
  else
    echo "$violations non-excepted overage(s) found."
    echo "Relocate historical/low-frequency content to docs/ (leave a pointer), or"
    echo "record an intentional overage in an --exceptions file with a reason."
  fi
fi

if [[ "$strict" == "true" && "$violations" -gt 0 ]]; then
  exit 1
fi
exit 0

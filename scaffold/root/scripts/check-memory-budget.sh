#!/usr/bin/env bash
# agent-vault-managed: helper-script; file=check-memory-budget.sh

set -euo pipefail

# Report the size of an agent-vault project's always-on / session-start memory
# against budgets, in separate buckets:
#   1a. Claude @-import chain    (resolved from CLAUDE.md; loaded every Claude session)
#   1b. Gemini @-import chain    (resolved from GEMINI.md; loaded every Gemini session)
#   2.  Codex AGENTS chain       (all AGENTS.md files Codex can concatenate up to
#                                 its project_doc_max_bytes cap)
#   3.  Protocol-read files      (named by session-start rules; read, not imported)
#
# The Claude and Gemini chains are reported and budgeted SEPARATELY because a
# session loads one or the other, never the union.
#
# Sizes are measured in BYTES (wc -c) for portability; for the mostly-ASCII
# memory files this tracks characters closely and is conservative for multibyte
# content. The 40000 per-file default mirrors Claude Code's memory-file
# performance-warning threshold; the 120000 per-chain default is a softer
# "standing context is getting heavy" line. The Codex AGENTS total is reported
# as informational only (Codex enforces its own project_doc_max_bytes cap, and a
# fresh scaffold already exceeds the 32 KiB default), though the per-file budget
# still flags an individual oversized AGENTS.md.
#
# Budgets are configurable at three levels (CLI flag > config file > built-in
# default; default config: agent-vault/memory-budget.config). The check is
# tolerant of missing files (reported, never fatal). By default it REPORTS and
# WARNS but exits 0 so it never blocks unrelated commits on a mature repo; pass
# --strict to fail on a non-excepted over-budget file or bucket. An exceptions
# file (path<TAB>reason) documents intentional per-file overages; the reserved
# path "@chain" documents an intentional always-on @-chain total overage (an
# excepted per-file overage still counts toward the chain total because the file
# still loads).

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --repo <path>            Project root to inspect (default: git top-level or cwd).
  --config <file>          Budget config file (default: <repo>/agent-vault/memory-budget.config
                           when present). Keys: file_budget, chain_budget,
                           protocol_read, agents, exceptions, chain_exception.
  --file-budget <bytes>    Per-file budget in bytes (default: 40000).
  --chain-budget <bytes>   Per @-chain total budget in bytes (default: 120000).
  --protocol-read "<list>" Space-separated protocol-read files (default: the
                           canonical session-start set).
  --agents "<list>"        Space-separated AGENTS.md files, or "discover" to find
                           every AGENTS.md in the repo (default: discover).
  --exceptions <file>      File of "path<TAB>reason" lines documenting allowed
                           overages. Use path "@chain" for an @-chain total.
  --strict                 Exit 1 when a non-excepted file or bucket is over budget.
  --format text|tsv        Output format (default: text).
  -h, --help               Show this help.

Precedence for budgets/lists: CLI flag > config file > built-in default.
Exit status: 0 = within budget or non-strict; 1 = strict violation; 2 = usage/IO error.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 2
}

repo=""
config_file=""
file_budget=""
chain_budget=""
protocol_read_cli=""
agents_cli=""
exceptions_cli=""
strict="false"
format="text"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires a path"
      repo="$2"
      shift 2
      ;;
    --config)
      [[ $# -ge 2 ]] || die "--config requires a path"
      config_file="$2"
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
      protocol_read_cli="$2"
      shift 2
      ;;
    --agents)
      [[ $# -ge 2 ]] || die "--agents requires a value"
      agents_cli="$2"
      shift 2
      ;;
    --exceptions)
      [[ $# -ge 2 ]] || die "--exceptions requires a path"
      exceptions_cli="$2"
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

[[ "$format" == "text" || "$format" == "tsv" ]] || die "--format must be text or tsv"

if [[ -z "$repo" ]]; then
  repo="$(git -C "${PWD}" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$repo" ]] || repo="$PWD"
fi
repo_arg="$repo"
repo="$(cd "$repo_arg" 2>/dev/null && pwd -P)" || die "repo path not found: $repo_arg"

# --- config file (CLI > config > default) --------------------------------

config_file_budget=""
config_chain_budget=""
config_protocol_read=""
config_agents=""
config_exceptions=""
config_chain_exception=""

if [[ -z "$config_file" && -f "$repo/agent-vault/memory-budget.config" ]]; then
  config_file="$repo/agent-vault/memory-budget.config"
fi

if [[ -n "$config_file" ]]; then
  [[ -f "$config_file" ]] || die "config file not found: $config_file"
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    raw_line="${raw_line%$'\r'}"
    cfg_line="${raw_line#"${raw_line%%[![:space:]]*}"}"
    [[ -z "$cfg_line" || "$cfg_line" == \#* ]] && continue
    [[ "$cfg_line" == *=* ]] || continue
    cfg_key="${cfg_line%%=*}"
    cfg_val="${cfg_line#*=}"
    cfg_key="${cfg_key%"${cfg_key##*[![:space:]]}"}"
    cfg_val="${cfg_val#"${cfg_val%%[![:space:]]*}"}"
    cfg_val="${cfg_val%"${cfg_val##*[![:space:]]}"}"
    case "$cfg_key" in
      file_budget) config_file_budget="$cfg_val" ;;
      chain_budget) config_chain_budget="$cfg_val" ;;
      protocol_read) config_protocol_read="$cfg_val" ;;
      agents) config_agents="$cfg_val" ;;
      exceptions) config_exceptions="$cfg_val" ;;
      chain_exception) config_chain_exception="$cfg_val" ;;
      *) die "unknown config key in $config_file: $cfg_key" ;;
    esac
  done <"$config_file"
fi

file_budget="${file_budget:-${config_file_budget:-40000}}"
chain_budget="${chain_budget:-${config_chain_budget:-120000}}"
[[ -n "$protocol_read_cli" ]] && config_protocol_read="$protocol_read_cli"
[[ -n "$agents_cli" ]] && config_agents="$agents_cli"
exceptions_file="${exceptions_cli:-$config_exceptions}"
chain_exception_reason="$config_chain_exception"

for b in file_budget chain_budget; do
  [[ "${!b}" =~ ^[0-9]+$ ]] || die "$b must be a non-negative integer"
done

if [[ -n "$exceptions_file" ]]; then
  case "$exceptions_file" in
    /*) : ;;
    *) exceptions_file="$repo/$exceptions_file" ;;
  esac
  [[ -f "$exceptions_file" ]] || die "exceptions file not found: $exceptions_file"
fi

# --- exceptions ----------------------------------------------------------

declare -A EXCEPTION_REASON=()
if [[ -n "$exceptions_file" ]]; then
  while IFS=$'\t' read -r ex_path ex_reason || [[ -n "$ex_path" ]]; do
    ex_path="${ex_path%$'\r'}"
    ex_reason="${ex_reason%$'\r'}"
    [[ -n "$ex_path" ]] || continue
    [[ "$ex_path" == \#* ]] && continue
    if [[ "$ex_path" == "@chain" ]]; then
      chain_exception_reason="${ex_reason:-documented chain exception}"
    else
      EXCEPTION_REASON["$ex_path"]="${ex_reason:-documented exception}"
    fi
  done <"$exceptions_file"
fi

# --- @-import chain discovery -------------------------------------------

# normalize_relpath collapses ., .. and // so the chain dedup and the displayed
# paths are canonical. Returns a path that may still begin with ".." when an
# import escapes the repo root; callers must reject those.
normalize_relpath() {
  local p="$1"
  local -a segs=() out=()
  local seg
  p="${p#./}"
  IFS='/' read -r -a segs <<<"$p"
  for seg in "${segs[@]}"; do
    case "$seg" in
      '' | '.') ;;
      '..')
        if [[ "${#out[@]}" -gt 0 && "${out[-1]}" != ".." ]]; then
          out=("${out[@]:0:${#out[@]}-1}")
        else
          out+=("..")
        fi
        ;;
      *) out+=("$seg") ;;
    esac
  done
  local IFS='/'
  printf '%s' "${out[*]}"
}

declare -A CHAIN_SEEN=()
CHAIN_RESULT=()

resolve_at_imports() {
  local rel="$1"
  local depth="$2"
  local abs="$repo/$rel"

  [[ "$depth" -le 8 ]] || return 0
  [[ -n "$rel" && "$rel" != ..* ]] || return 0
  [[ -f "$abs" ]] || return 0
  [[ -z "${CHAIN_SEEN[$rel]:-}" ]] || return 0

  CHAIN_SEEN["$rel"]=1
  CHAIN_RESULT+=("$rel")

  local dir
  dir="$(dirname "$rel")"

  local line target resolved
  while IFS= read -r line; do
    target="${line#"${line%%[![:space:]]*}"}"
    target="${target#@}"
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
  done < <(grep -E '^[[:space:]]*@[^[:space:]]' "$abs" || true)
}

resolve_chain() {
  CHAIN_SEEN=()
  CHAIN_RESULT=()
  if [[ -f "$repo/$1" ]]; then
    resolve_at_imports "$1" 0
  fi
}

claude_files=()
resolve_chain "CLAUDE.md"
claude_files=("${CHAIN_RESULT[@]}")
gemini_files=()
resolve_chain "GEMINI.md"
gemini_files=("${CHAIN_RESULT[@]}")

# --- AGENTS discovery ----------------------------------------------------

# Discover every AGENTS.md (Codex concatenates them along the working-directory
# ancestry, including nested ones). In a git repo: tracked + present-but-
# untracked, with .gitignore honored. In a non-git directory: a plain
# filesystem walk (which does NOT consult .gitignore). core.quotePath=false +
# NUL delimiters keep non-ASCII / unusual paths as real on-disk paths.
discover_agents_files() {
  if git -C "$repo" rev-parse >/dev/null 2>&1; then
    git -C "$repo" -c core.quotePath=false ls-files -z --cached --others --exclude-standard \
      -- 'AGENTS.md' '**/AGENTS.md' 2>/dev/null | sort -zu | tr '\0' '\n'
  else
    (cd "$repo" && find . -name AGENTS.md -not -path '*/.git/*' -printf '%P\n' 2>/dev/null | sort -u)
  fi
}

agents_files=()
if [[ -z "$config_agents" || "$config_agents" == "discover" ]]; then
  while IFS= read -r agents_path; do
    [[ -n "$agents_path" ]] || continue
    agents_files+=("$agents_path")
  done < <(discover_agents_files)
else
  read -r -a agents_files <<<"$config_agents"
fi

default_protocol_read=(
  "agent-vault/README.md"
  "agent-vault/context-log.md"
  "agent-vault/plan.md"
  "agent-vault/coding-standards.md"
  "agent-vault/project-context.md"
  "agent-vault/project-commands.md"
  "agent-vault/open-questions.md"
  "agent-vault/decision-log.md"
  "agent-vault/lessons.md"
)
protocol_read_files=()
if [[ -n "$config_protocol_read" ]]; then
  read -r -a protocol_read_files <<<"$config_protocol_read"
else
  protocol_read_files=("${default_protocol_read[@]}")
fi

# --- measurement ---------------------------------------------------------

violations=0
declare -A COUNTED_OVER=()

byte_count() {
  wc -c <"$1" | tr -d '[:space:]'
}

emit_row() {
  local bucket="$1" rel="$2" status="$3" bytes="$4" note="$5"
  if [[ "$format" == "tsv" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$bucket" "$rel" "$status" "$bytes" "$note"
  else
    printf '  %-7s %-44s %10s  %s\n' "$status" "$rel" "$bytes" "$note"
  fi
}

# Measure one bucket: print a row per file and accumulate the bucket's total
# byte count into the caller-named variable (nameref). Missing files are
# reported and skipped. A non-excepted over-budget file increments the global
# violations counter at most once across all buckets (deduplicated by path).
measure_bucket() {
  local bucket="$1"
  shift
  local -n total_ref="$1"
  shift
  local rel abs bytes status note
  total_ref=0

  for rel in "$@"; do
    abs="$repo/$rel"
    if [[ ! -f "$abs" ]]; then
      emit_row "$bucket" "$rel" "MISSING" "-" "(optional file absent)"
      continue
    fi
    bytes="$(byte_count "$abs")"
    total_ref=$((total_ref + bytes))
    note=""
    status="ok"
    if [[ "$bytes" -gt "$file_budget" ]]; then
      if [[ -n "${EXCEPTION_REASON[$rel]:-}" ]]; then
        status="EXCEPT"
        note="over file budget; documented: ${EXCEPTION_REASON[$rel]}"
      else
        status="OVER"
        note="over file budget ($file_budget bytes)"
        if [[ -z "${COUNTED_OVER[$rel]:-}" ]]; then
          COUNTED_OVER["$rel"]=1
          violations=$((violations + 1))
        fi
      fi
    fi
    emit_row "$bucket" "$rel" "$status" "$bytes" "$note"
  done
}

print_chain_bucket() {
  local label="$1" total_name="$2"
  shift 2
  if [[ "$format" == "text" ]]; then echo "$label"; fi
  if [[ "$#" -eq 0 ]]; then
    emit_row "${total_name%_total}" "(no $label entry point found)" "MISSING" "-" ""
    printf -v "$total_name" '%s' 0
  else
    measure_bucket "${total_name%_total}" "$total_name" "$@"
  fi
}

if [[ "$format" == "text" ]]; then
  echo "Memory budget report for: $repo"
  echo "Per-file: $file_budget bytes | per @-chain: $chain_budget bytes"
  [[ -n "$config_file" ]] && echo "Config: $config_file"
  echo
fi

claude_total=0
gemini_total=0
agents_total=0
protocol_total=0

print_chain_bucket "[1a] Claude @-import chain (CLAUDE.md; loaded every Claude session):" claude_total "${claude_files[@]}"
[[ "$format" == "text" ]] && echo
print_chain_bucket "[1b] Gemini @-import chain (GEMINI.md; loaded every Gemini session):" gemini_total "${gemini_files[@]}"

if [[ "$format" == "text" ]]; then
  echo
  echo "[2] Codex AGENTS chain (all discovered AGENTS.md; Codex cap project_doc_max_bytes):"
fi
if [[ "${#agents_files[@]}" -eq 0 ]]; then
  emit_row "agents" "(no AGENTS.md found)" "MISSING" "-" ""
else
  measure_bucket "agents" agents_total "${agents_files[@]}"
fi

if [[ "$format" == "text" ]]; then
  echo
  echo "[3] Protocol-read files (session-start reads; not auto-imported; informational total):"
fi
measure_bucket "protocol" protocol_total "${protocol_read_files[@]}"

chain_over="false"
[[ "$claude_total" -gt "$chain_budget" || "$gemini_total" -gt "$chain_budget" ]] && chain_over="true"
claude_status="ok"
gemini_status="ok"
if [[ "$chain_over" == "true" ]]; then
  if [[ -n "$chain_exception_reason" ]]; then
    [[ "$claude_total" -gt "$chain_budget" ]] && claude_status="EXCEPT"
    [[ "$gemini_total" -gt "$chain_budget" ]] && gemini_status="EXCEPT"
  else
    [[ "$claude_total" -gt "$chain_budget" ]] && claude_status="OVER"
    [[ "$gemini_total" -gt "$chain_budget" ]] && gemini_status="OVER"
    violations=$((violations + 1))
  fi
fi

agents_status="info"

if [[ "$format" == "tsv" ]]; then
  printf 'TOTAL\tclaude_chain\t%s\t%s\t%s\n' "$claude_status" "$claude_total" "$chain_exception_reason"
  printf 'TOTAL\tgemini_chain\t%s\t%s\t%s\n' "$gemini_status" "$gemini_total" "$chain_exception_reason"
  printf 'TOTAL\tagents\t%s\t%s\t\n' "$agents_status" "$agents_total"
  printf 'TOTAL\tprotocol\tinfo\t%s\t\n' "$protocol_total"
else
  echo
  echo "Totals (per @-chain budget: $chain_budget bytes; Codex AGENTS total is informational):"
  printf '  %-7s %-30s %10s\n' "$claude_status" "Claude @-chain total" "$claude_total"
  printf '  %-7s %-30s %10s\n' "$gemini_status" "Gemini @-chain total" "$gemini_total"
  printf '  %-7s %-30s %10s\n' "$agents_status" "Codex AGENTS total" "$agents_total"
  printf '  %-7s %-30s %10s\n' "info" "protocol-read total" "$protocol_total"
  [[ -n "$chain_exception_reason" && "$chain_over" == "true" ]] && echo "  @-chain overage documented: $chain_exception_reason"
  echo
  if [[ "$violations" -eq 0 ]]; then
    echo "Within budget (no non-excepted overages)."
  else
    echo "$violations non-excepted overage(s) found."
    echo "Relocate historical/low-frequency content to docs/ (leave a pointer), or"
    echo "record an intentional overage in an exceptions file with a reason."
  fi
fi

if [[ "$strict" == "true" && "$violations" -gt 0 ]]; then
  exit 1
fi
exit 0

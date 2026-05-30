#!/usr/bin/env bash

set -euo pipefail

# Report the size of an agent-vault project's always-on / session-start memory
# against budgets, in three buckets:
#   1. Claude/Gemini @-import chain   (auto-discovered from CLAUDE.md, loaded
#                                      into every session)
#   2. Codex AGENTS chain             (all AGENTS.md files Codex can concatenate
#                                      up to its own project_doc_max_bytes cap)
#   3. Protocol-read files            (named by session-start rules; read, not
#                                      auto-imported)
#
# Budgets are configurable at three levels (CLI flag > config file > built-in
# default). The built-in per-file default is 40000 chars, which mirrors the
# Claude Code memory-file performance-warning threshold; the @-chain default is
# 120000 chars (~33K tokens) as a "standing context is getting heavy" line.
# A repo can override either, plus the protocol-read and AGENTS file sets, in a
# committed config file (default: agent-vault/memory-budget.config). The check
# is tolerant of missing files (reported, never fatal). By default it REPORTS
# and WARNS but exits 0 so it never blocks unrelated commits on a mature repo;
# pass --strict to fail on a non-excepted over-budget file or bucket.
#
# An exceptions file (path<TAB>reason) documents intentional per-file overages.
# The reserved path "@chain" documents an intentional @-chain total overage
# (an excepted per-file overage still counts toward the chain total, because the
# file still loads into context; clear the chain total separately with @chain).

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --repo <path>            Project root to inspect (default: git top-level or cwd).
  --config <file>          Budget config file (default: <repo>/agent-vault/memory-budget.config
                           when present). Keys: file_budget, chain_budget,
                           protocol_read, agents, exceptions, chain_exception.
  --file-budget <chars>    Per-file budget in characters (default: 40000).
  --chain-budget <chars>   Always-on @-chain total budget (default: 120000).
  --protocol-read "<list>" Space-separated protocol-read files (default: the
                           canonical session-start set).
  --agents "<list>"        Space-separated AGENTS.md files, or "discover" to find
                           every AGENTS.md in the repo (default: discover).
  --exceptions <file>      File of "path<TAB>reason" lines documenting allowed
                           overages. Use path "@chain" for the chain total.
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
repo="$(cd "$repo" 2>/dev/null && pwd -P)" || die "repo path not found: $repo"

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
    local_line="${raw_line#"${raw_line%%[![:space:]]*}"}"
    [[ -z "$local_line" || "$local_line" == \#* ]] && continue
    [[ "$local_line" == *=* ]] || continue
    cfg_key="${local_line%%=*}"
    cfg_val="${local_line#*=}"
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

[[ "$file_budget" =~ ^[0-9]+$ ]] || die "file_budget must be a non-negative integer"
[[ "$chain_budget" =~ ^[0-9]+$ ]] || die "chain_budget must be a non-negative integer"

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

for entry in "CLAUDE.md" "GEMINI.md"; do
  [[ -f "$repo/$entry" ]] && resolve_at_imports "$entry" 0
done

# --- bucket file lists ---------------------------------------------------

# Codex bucket: by default discover every AGENTS.md in the repo (tracked or
# present-but-untracked, respecting .gitignore), since Codex concatenates
# AGENTS.md along the working-directory ancestry including nested ones. A repo
# can pin an explicit list via config/--agents.
discover_agents_files() {
  if git -C "$repo" rev-parse >/dev/null 2>&1; then
    git -C "$repo" ls-files --cached --others --exclude-standard -- 'AGENTS.md' '**/AGENTS.md' 2>/dev/null | sort -u
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
  [[ -n "$config_file" ]] && echo "Config: $config_file"
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
  echo "[2] Codex AGENTS chain (all discovered AGENTS.md, concatenated up to Codex project_doc_max_bytes):"
fi
if [[ "${#agents_files[@]}" -eq 0 ]]; then
  emit_row "agents" "(no AGENTS.md found)" "MISSING" "-" ""
else
  measure_bucket "agents" agents_total "${agents_files[@]}"
fi

if [[ "$format" == "text" ]]; then
  echo
  echo "[3] Protocol-read files (session-start reads; not auto-imported):"
fi
measure_bucket "protocol" protocol_total "${protocol_read_files[@]}"

chain_status="ok"
if [[ "$chain_total" -gt "$chain_budget" ]]; then
  if [[ -n "$chain_exception_reason" ]]; then
    chain_status="EXCEPT"
  else
    chain_status="OVER"
    violations=$((violations + 1))
  fi
fi

if [[ "$format" == "tsv" ]]; then
  printf 'TOTAL\tchain\t%s\t%s\t%s\n' "$chain_status" "$chain_total" "$chain_exception_reason"
  printf 'TOTAL\tagents\t-\t%s\t\n' "$agents_total"
  printf 'TOTAL\tprotocol\t-\t%s\t\n' "$protocol_total"
else
  echo
  echo "Totals:"
  if [[ "$chain_status" == "EXCEPT" ]]; then
    printf '  %-7s %-44s %10s  %s\n' "$chain_status" "@-chain total" "$chain_total" "over budget $chain_budget; documented: $chain_exception_reason"
  else
    printf '  %-7s %-44s %10s  %s\n' "$chain_status" "@-chain total" "$chain_total" "(budget $chain_budget)"
  fi
  printf '  %-7s %-44s %10s\n' "ok" "Codex AGENTS total" "$agents_total"
  printf '  %-7s %-44s %10s\n' "ok" "protocol-read total" "$protocol_total"
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

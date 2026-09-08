#!/usr/bin/env bash
# agent-vault-managed: helper-script; file=check-memory-budget.sh

set -euo pipefail

# Frozen delimiter primitive: changes require review of every existing consumer.
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
# --strict to fail on a non-excepted overage or incomplete in-scope import scan.
# Known external targets are listed but excluded from this repo-local scope.
# Actual usage/read/scanner errors exit 2 in either mode. An exceptions
# file (path<TAB>reason) documents intentional per-file overages. The @-chain
# budget is checked NET of those per-file exceptions, so an approved oversized
# file does not consume the chain budget while the chain budget keeps governing
# all non-excepted always-on content. (The legacy reserved "@chain" exception /
# chain_exception= config is still parsed but DEPRECATED: it no longer
# suppresses chain overage, because it was unbounded.)

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --repo <path>            Project root to inspect (default: git top-level or cwd).
  --config <file>          Budget config file (default: <repo>/agent-vault/memory-budget.config
                           when present). Keys: file_budget, chain_budget,
                           protocol_read, agents, exceptions, chain_exception,
                           gemini_import_depth.
  --file-budget <bytes>    Per-file budget in bytes (default: 40000).
  --chain-budget <bytes>   Per @-chain total budget in bytes (default: 120000).
  --gemini-import-depth N  Modeled Gemini tree depth, 0-64 (default: 5).
  --protocol-read "<list>" Space-separated protocol-read files (default: the
                           canonical session-start set).
  --agents "<list>"        Space-separated AGENTS.md files, or "discover" to find
                           every AGENTS.md in the repo (default: discover).
  --exceptions <file>      File of "path<TAB>reason" lines documenting allowed
                           per-file overages (subtracted from the @-chain total).
                           The reserved "@chain" path is deprecated and ignored.
  --strict                 Exit 1 on overage or incomplete in-scope import analysis.
  --format text|tsv        Output format (default: text).
  -h, --help               Show this help.

Precedence for budgets/lists: CLI flag > config file > built-in default.
Import scope: repo-local source bytes from CLAUDE.md and GEMINI.md, not the full
client memory hierarchy or expanded prompt. Physical files count once per chain;
every reached logical alias must be excepted before its source is subtracted.
Profiles: Claude documented/2.1.236 depth 4; Gemini 0.58.0 tree depth 5 by default.
EXTERNAL exclusions and MISSING imports are advisory; INCOMPLETE is strict-failing.
Safety ceilings: 10000 edges, 4194304 scan bytes/file, 16777216 scan bytes/chain.
Scanner shape bounds: 100000 lines/file, 128 delimiter characters/run, 4096 path bytes.
AGENT_VAULT_IMPORT_MAX_EDGES, AGENT_VAULT_IMPORT_MAX_FILE_BYTES, and
AGENT_VAULT_IMPORT_MAX_CHAIN_BYTES may only lower those positive ceilings.
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
gemini_import_depth=""
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
    --gemini-import-depth)
      [[ $# -ge 2 ]] || die "--gemini-import-depth requires a number"
      [[ -n "$2" ]] || die "--gemini-import-depth requires a number"
      gemini_import_depth="$2"
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
config_gemini_import_depth=""

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
      gemini_import_depth)
        [[ -n "$cfg_val" ]] || die "gemini_import_depth requires a number"
        config_gemini_import_depth="$cfg_val"
        ;;
      *) die "unknown config key in $config_file: $cfg_key" ;;
    esac
  done <"$config_file"
fi

file_budget="${file_budget:-${config_file_budget:-40000}}"
chain_budget="${chain_budget:-${config_chain_budget:-120000}}"
gemini_import_depth="${gemini_import_depth:-${config_gemini_import_depth:-5}}"
# Bound before arithmetic (including digit count) so hostile numeric input never
# becomes a Bash arithmetic expression or overflows before validation.
[[ "$gemini_import_depth" =~ ^[0-9]{1,2}$ ]] || die "gemini_import_depth must be an integer from 0 to 64"
gemini_import_depth=$((10#$gemini_import_depth))
[[ "$gemini_import_depth" -le 64 ]] || die "gemini_import_depth must be an integer from 0 to 64"
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

# Scanner source is trusted repository code, never text taken from an import.
# Client provenance and independently observed fixtures: scripts/fixtures/memory-imports/.
scan_imports() {
  MEMORY_IMPORT_PROFILE="$2" MEMORY_IMPORT_EDGES="$max_import_edges" LC_ALL=C awk "$markdown_fences"'
    BEGIN {
      for (i = 0; i < 129; i++) { long_ticks = long_ticks "`"; long_tildes = long_tildes "~" }
    }
    function opens_fence(s, old_marker, old_length, old_line, result) {
      old_marker = fence_marker; old_length = fence_length; old_line = fence_line
      reset_fence(); result = fenced(s)
      fence_marker = old_marker; fence_length = old_length; fence_line = old_line
      return result
    }
    function unsupported(line, reason) { print "U\t" line "\t" reason }
    # Balanced joining avoids repeatedly copying the entire growing document
    # on awk implementations without an optimized string-append operation.
    function join_lines(first, last, middle) {
      if (first == last) return lines[first] "\n"
      middle = int((first + last) / 2)
      return join_lines(first, middle) join_lines(middle + 1, last)
    }
    function run_at(p, n) {
      n = 0
      while (substr(text, p + n, 1) == "`") n++
      return n
    }
    function span_end(p, width, limit, gemini, ticks, q, hit, length_run) {
      # Gemini uses a greedy opening run with regex backtracking, and accepts
      # a closing prefix of a longer run. Claude requires exact run lengths.
      do {
        ticks = substr(text, p, width); q = p + width
        while (q < limit) {
          hit = index(substr(text, q, limit - q), ticks)
          if (!hit) break
          q += hit - 1; length_run = run_at(q)
          if (gemini || (length_run == width && substr(text, q - 1, 1) != "`")) return q + width
          q += length_run
        }
        width--
      } while (gemini && width > 0)
      return 0
    }
    function import_start(s, column, first) {
      if (substr(s, column, 1) != "@" ||
          (column > 1 && substr(s, column - 1, 1) !~ /[ \t\r\n]/)) return 0
      first = substr(s, column + 1, 1)
      return first ~ /[A-Za-z.\/]/ || (claude && first == "~")
    }
    # Return the first candidate line in this region, after the same escape,
    # comment and matched-span exclusions used by the main lexer. Region guards
    # do not interpret the container as supported Markdown or discover files.
    function region_candidate(first, last, offset, p, limit, row, col, s, c, hit, end, width, span_limit) {
      p = offset ? offset : starts[first]; limit = starts[last + 1]; row = first
      while (p < limit) {
        while (row < last && p >= starts[row + 1]) row++
        s = lines[row] "\n"; col = p - starts[row] + 1; c = substr(s, col, 1)
        if (c == "\\") { p += 2; continue }
        if (c == "<" && substr(s, col, 4) == "<!--") {
          hit = index(substr(text, p + 4, limit - p - 4), "-->")
          if (hit) { p += hit + 6; continue }
          p += 4; continue
        }
        if (c == "`") {
          width = run_at(p); span_limit = barrier[row] < limit ? barrier[row] : limit
          end = span_end(p, width, span_limit, 0)
          p = end ? end : p + width; continue
        }
        if (import_start(s, col)) return row
        hit = match(substr(s, col + 1), /[@`\\<\n]/)
        p = hit ? p + hit : starts[row + 1]
      }
      return 0
    }
    function indentation(s, i, width, c) {
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == " ") width++
        else if (c == "\t") width += 4 - width % 4
        else break
      }
      return width
    }
    # Only the continuation of this list item is ambiguous; a dedented sibling
    # or outside paragraph cannot contaminate its guard.
    function list_region_end(first, indent, n) {
      for (n = first + 1; n <= NR; n++) {
        if (quotes[n] != quotes[first]) break
        if (lines[n] !~ /^[ \t]*$/ && indentation(lines[n]) < indent) break
      }
      return n - 1
    }
    # Bound ordinary HTML by its blank-line/container boundary. Raw-text tags,
    # declarations, processing instructions and CDATA have explicit terminators.
    # This is an ambiguity envelope, not a complete HTML/Markdown parser.
    function html_region_end(first, s, terminator, n) {
      s = tolower(lines[first]); sub(/^ ? ? ?/, "", s)
      if (s ~ /^<(pre|script|style|textarea)([ \t>]|$)/) terminator = "</(pre|script|style|textarea)>"
      else if (s ~ /^<\?/) terminator = "\\?>"
      else if (s ~ /^<!\[cdata\[/) terminator = "\\]\\]>"
      else if (s ~ /^<![a-z]/) terminator = ">"
      for (n = first; n <= NR; n++) {
        if (quotes[n] != quotes[first]) return n - 1
        if (!terminator && lines[n] ~ /^[ \t]*$/) return n - 1
        if (terminator && tolower(lines[n]) ~ terminator) return n
      }
      return NR
    }
    {
      if (NR > 100000) { unsupported(NR, "scanner line limit reached (100000)"); invalid_input = 1; exit }
      s = $0; sub(/\r$/, "", s)
      controls = s; gsub(/\t/, "", controls)
      if (!invalid_input && controls ~ /[[:cntrl:]]/) { unsupported(NR, "control bytes in import input"); invalid_input = 1 }
      # The lexer uses byte-oriented ASCII whitespace. Do not silently miss
      # JavaScript/Markdown token boundaries written with Unicode whitespace.
      if (s ~ /\302\240|\341\232\200|\342\200[\200-\212\250\251\257]|\342\201\237|\343\200\200|\357\273\277/) {
        unicode_line = NR
      }
      if (index(s, long_ticks) || (ENVIRON["MEMORY_IMPORT_PROFILE"] == "claude" && index(s, long_tildes)))
        long_delimiter_line = NR
      raw_lines[NR] = s
      quote = 0
      if (ENVIRON["MEMORY_IMPORT_PROFILE"] == "claude") {
        while (match(s, /^ ? ? ?> ?/)) { s = substr(s, RLENGTH + 1); quote++ }
      }
      lines[NR] = s; quotes[NR] = quote
      starts[NR] = size + 1
      size += length(s) + 1
      if (index(s, "@")) possible_import = 1
    }
    END {
      if (invalid_input || !possible_import) exit
      if (unicode_line) { unsupported(unicode_line, "Unicode whitespace requires unsupported token/container parsing"); exit }
      if (long_delimiter_line) { unsupported(long_delimiter_line, "delimiter run exceeds supported scanner work bound (128)"); exit }
      text = join_lines(1, NR)
      claude = ENVIRON["MEMORY_IMPORT_PROFILE"] == "claude"
      starts[NR + 1] = size + 1
      next_barrier = size + 1
      for (n = NR; n > 0; n--) {
        if (n < NR && quotes[n] != quotes[n + 1]) next_barrier = starts[n + 1]
        barrier[n] = next_barrier
        if (lines[n] ~ /^[ \t]*$/ || opens_fence(lines[n])) next_barrier = starts[n]
      }
      reset_fence(); line_number = 1; p = 1; edges = 0; list_context = 0
      while (p <= size) {
        while (line_number < NR && p >= starts[line_number + 1]) line_number++
        FNR = line_number
        if (claude && p == starts[line_number]) {
          # Container-looking text INSIDE a flat fence is literal. Only a
          # fence opened inside a quote ends when that quote container ends.
          if (fence_marker != "" && fence_quote == 0) {
            fenced(raw_lines[line_number]); p = starts[line_number + 1]; continue
          }
          if (fence_marker != "" && quotes[line_number] != fence_quote) reset_fence()
          if (fenced(lines[line_number])) {
            fence_quote = quotes[line_number]; p = starts[line_number + 1]; continue
          }
          if (lines[line_number] ~ /^ ? ? ?([-+*]|[0-9]+[.)])[ \t]+/) {
            list_context = 1
            candidate = lines[line_number]
            sub(/^ ? ? ?([-+*]|[0-9]+[.)])[ \t]+/, "", candidate)
            if (opens_fence(candidate)) {
              list_prefix = substr(lines[line_number], 1, length(lines[line_number]) - length(candidate))
              gsub(/[^ \t]/, " ", list_prefix)
              list_indent = indentation(list_prefix)
              region_end = list_region_end(line_number, list_indent)
              candidate_line = region_candidate(line_number, region_end)
              if (candidate_line) unsupported(candidate_line, "fence on list-marker line requires container parsing")
              p = starts[region_end + 1]; continue
            }
          } else if (lines[line_number] ~ /^[^ \t]/) list_context = 0
          if (lines[line_number] ~ /^(    |\t)/) {
            if (list_context) {
              region_end = list_region_end(line_number, 4)
              candidate_line = region_candidate(line_number, region_end)
              if (candidate_line) unsupported(candidate_line, "indented list import requires container parsing")
              p = starts[region_end + 1]; continue
            }
            p = starts[line_number + 1]; continue
          }
          if (lines[line_number] ~ /^ ? ? ?<[A-Za-z!?\/]/ && lines[line_number] !~ /^ ? ? ?<!--/) {
            region_end = html_region_end(line_number)
            candidate_line = region_candidate(line_number, region_end)
            if (candidate_line) unsupported(candidate_line, "raw HTML import context is not modeled")
            p = starts[region_end + 1]; continue
          }
        }
        line_text = lines[line_number] "\n"; column = p - starts[line_number] + 1
        c = substr(line_text, column, 1)
        # Skip plain prose in chunks, so multi-megabyte non-import text does
        # not require a per-character interpreter loop.
        if (c !~ /[@`\\<\n]/) {
          hit = match(substr(line_text, column), /[@`\\<\n]/)
          if (!hit) break
          p += hit - 1; continue
        }
        if (claude && c == "<" && substr(line_text, column, 4) == "<!--") {
          close_at = index(substr(text, p + 4), "-->")
          if (!close_at) {
            candidate_line = region_candidate(line_number, NR, p)
            if (candidate_line) unsupported(candidate_line, "unclosed HTML comment with possible imports")
            break
          }
          p += close_at + 6; continue
        }
        if (claude && c == "\\") { p += 2; continue }
        if (c == "`") {
          width = run_at(p)
          end = span_end(p, width, claude ? barrier[line_number] : size + 1, !claude)
          if (end) { p = end; continue }
          p += width; continue
        }
        if (!import_start(line_text, column)) { p++; continue }
        q = column + match(substr(line_text, column + 1), /[ \t\r\n]/)
        target = substr(line_text, column + 1, q - column - 1)
        if (claude) sub(/#.*/, "", target)
        edges++
        if (edges > ENVIRON["MEMORY_IMPORT_EDGES"] + 0) {
          unsupported(line_number, "import edge scan limit reached"); break
        }
        if (length(target) > 4096) unsupported(line_number, "import path exceeds supported scanner length (4096)")
        else if (target ~ /[[:cntrl:]\\`]/) unsupported(line_number, "unsupported import path characters")
        else if (target != "") print "I\t" line_number "\t" target
        p = starts[line_number] + q - 1
      }
    }
  ' "$1"
}

# Test overrides may lower, never raise or disable, the production work bounds.
bounded_limit() {
  local name="$1" value="$2" ceiling="$3"
  [[ "$value" =~ ^[0-9]{1,8}$ ]] || die "$name must be an integer from 1 to $ceiling"
  value=$((10#$value))
  [[ "$value" -gt 0 && "$value" -le "$ceiling" ]] || die "$name must be an integer from 1 to $ceiling"
  printf '%s' "$value"
}
max_import_edges="$(bounded_limit AGENT_VAULT_IMPORT_MAX_EDGES "${AGENT_VAULT_IMPORT_MAX_EDGES-10000}" 10000)"
max_import_file_bytes="$(bounded_limit AGENT_VAULT_IMPORT_MAX_FILE_BYTES "${AGENT_VAULT_IMPORT_MAX_FILE_BYTES-4194304}" 4194304)"
max_import_chain_bytes="$(bounded_limit AGENT_VAULT_IMPORT_MAX_CHAIN_BYTES "${AGENT_VAULT_IMPORT_MAX_CHAIN_BYTES-16777216}" 16777216)"

declare -A IMPORT_INCOMPLETE=() IMPORT_ID=() IMPORT_PHYSICAL=() IMPORT_SIZE=()
import_diag_clients=() import_diag_paths=() import_diag_statuses=() import_diag_notes=()
import_diagnostic() {
  import_diag_clients+=("$1")
  import_diag_paths+=("$2")
  import_diag_statuses+=("$3")
  import_diag_notes+=("$4")
  if [[ "$3" == INCOMPLETE || "$3" == UNSUPPORTED ]]; then IMPORT_INCOMPLETE["$1"]=1; fi
}

if stat -c '%d:%i' "$repo" >/dev/null 2>&1; then
  import_stat_style=gnu
else
  import_stat_style=bsd
fi
import_identity() {
  if [[ "$import_stat_style" == gnu ]]; then stat -c '%d:%i' "$1"; else stat -f '%d:%i' "$1"; fi
}

# Resolve directory AND leaf symlinks without GNU realpath/readlink flags.
# Relative link targets are walked component by component before applying '..'.
# No final file is opened until containment has been established. This is a
# read-only snapshot check, not protection against hostile concurrent FS swaps.
resolve_import_path() {
  local remaining="$1" component next link links=0 physical="/"
  [[ "$remaining" == /* ]] || remaining="$repo/$remaining"
  remaining="${remaining#/}"
  IMPORT_PATH_STATE=ok
  IMPORT_PATH=""
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
    if [[ ! -d "$physical" || ! -x "$physical" ]]; then
      if [[ "$physical" != "$repo" && "$physical" != "$repo/"* ]]; then
        IMPORT_PATH_STATE=EXTERNAL
        return
      fi
      die "cannot traverse import directory: $physical"
    fi
    next="${physical%/}/$component"
    if [[ -L "$next" ]]; then
      links=$((links + 1))
      if [[ "$links" -gt 40 ]]; then
        IMPORT_PATH_STATE=UNSUPPORTED
        return
      fi
      link="$(readlink "$next" && printf '.')" || die "cannot read import symlink: $next"
      link="${link%$'\n.'}"
      if [[ "$link" == *$'\n'* || "$link" == *$'\r'* || "$link" == *$'\t'* ]]; then
        IMPORT_PATH_STATE=UNSUPPORTED
        return
      fi
      if [[ "$link" == /* ]]; then
        physical="/"
        link="${link#/}"
      fi
      remaining="$link${remaining:+/$remaining}"
    elif [[ ! -e "$next" ]]; then
      if [[ "$next" == "$repo/"* ]]; then IMPORT_PATH_STATE=MISSING; else IMPORT_PATH_STATE=EXTERNAL; fi
      return
    else
      physical="$next"
      if [[ -n "$remaining" && ! -d "$physical" ]]; then
        if [[ "$physical" == "$repo" || "$physical" == "$repo/"* ]]; then IMPORT_PATH_STATE=UNSUPPORTED; else IMPORT_PATH_STATE=EXTERNAL; fi
        return
      fi
    fi
  done
  if [[ "$physical" != "$repo" && "$physical" != "$repo/"* ]]; then
    IMPORT_PATH_STATE=EXTERNAL
    return
  fi
  if [[ ! -f "$physical" ]]; then
    IMPORT_PATH_STATE=UNSUPPORTED
    return
  fi
  [[ -r "$physical" ]] || die "cannot read imported file: $physical"
  IMPORT_PATH="$physical"
}

CHAIN_RESULT=()
resolve_chain() {
  local client="$1" entry="$2" limit="$3" cursor=0 depth rel target source line kind resolved key identity bytes parsed
  local edges=0 scanned=0 previous canonical text_bytes
  local -a queue_paths=("$entry") queue_depths=(0) queue_sources=("entry point")
  local -A seen=() sizes=() parse_cache=()
  CHAIN_RESULT=()
  [[ -e "$repo/$entry" || -L "$repo/$entry" ]] || return 0
  seen["$entry"]=1
  while [[ "$cursor" -lt "${#queue_paths[@]}" ]]; do
    rel="${queue_paths[$cursor]}"
    depth="${queue_depths[$cursor]}"
    source="${queue_sources[$cursor]}"
    cursor=$((cursor + 1))
    resolve_import_path "$rel"
    if [[ "$IMPORT_PATH_STATE" != ok ]]; then
      import_diagnostic "$client" "$rel" "$IMPORT_PATH_STATE" "$source; target excluded ($IMPORT_PATH_STATE)"
      continue
    fi
    canonical="$IMPORT_PATH"
    identity="$(import_identity "$canonical")" || die "cannot identify imported file: $rel"
    if [[ -z "${sizes[$identity]+present}" ]]; then
      bytes="$(wc -c <"$canonical")" || die "cannot measure imported file: $rel"
      bytes="${bytes//[[:space:]]/}"
      [[ "$bytes" =~ ^[0-9]+$ ]] || die "invalid imported file size: $rel"
      sizes["$identity"]="$bytes"
    fi
    bytes="${sizes[$identity]}"
    key="$client:$rel"
    IMPORT_ID["$key"]="$identity"
    IMPORT_PHYSICAL["$key"]="$canonical"
    IMPORT_SIZE["$key"]="$bytes"
    CHAIN_RESULT+=("$rel")
    if [[ "$depth" -eq "$limit" ]]; then
      import_diagnostic "$client" "$rel" DEPTH "included at client depth $limit; imports not expanded"
      continue
    fi
    if [[ -z "${parse_cache[$identity]+present}" ]]; then
      if [[ "$bytes" -gt "$max_import_file_bytes" || "$((scanned + bytes))" -gt "$max_import_chain_bytes" ]]; then
        import_diagnostic "$client" "$rel" INCOMPLETE "scanner byte limit reached (file $max_import_file_bytes; chain $max_import_chain_bytes)"
        parse_cache["$identity"]=$'U\t1\tpreviously reached scanner byte limit'
        continue
      fi
      scanned=$((scanned + bytes))
      # BSD awk can silently truncate records at NUL. Detect that before the
      # text parser so binary input never looks like a complete empty scan.
      text_bytes="$(LC_ALL=C tr -d '\000' <"$canonical" | wc -c)" || die "cannot inspect imported file: $rel"
      text_bytes="${text_bytes//[[:space:]]/}"
      if [[ "$text_bytes" != "$bytes" ]]; then
        import_diagnostic "$client" "$rel" UNSUPPORTED "control bytes or changing content in import input"
        parse_cache["$identity"]=$'U\t1\tcontrol bytes or changing content in import input'
        continue
      fi
      parsed="$(scan_imports "$canonical" "$client")" || die "import scanner/read failed: $client $rel"
      # Detect disappearance/replacement during scanning, not as optional absence.
      previous="$(import_identity "$canonical")" || die "import disappeared during scanning: $rel"
      [[ "$previous" == "$identity" ]] || die "import changed identity during scanning: $rel"
      parse_cache["$identity"]="$parsed"
    fi
    parsed="${parse_cache[$identity]}"
    while IFS=$'\t' read -r kind line target; do
      [[ -n "$kind" ]] || continue
      if [[ "$kind" == U ]]; then
        import_diagnostic "$client" "$rel" UNSUPPORTED "$rel:$line; $target"
        continue
      fi
      [[ "$kind" == I && "$line" =~ ^[0-9]+$ && -n "$target" ]] || die "malformed import scanner result: $rel"
      edges=$((edges + 1))
      if [[ "$edges" -gt "$max_import_edges" ]]; then
        import_diagnostic "$client" "$rel" INCOMPLETE "import edge limit reached ($max_import_edges)"
        return 0
      fi
      source="$rel:$line"
      case "$target" in
        '~'* | *://*)
          import_diagnostic "$client" "$target" EXTERNAL "$source; excluded from repo-local measurement; not opened"
          continue
          ;;
        /*)
          resolved="/$(normalize_relpath "$target")"
          # Keep an absolute alias context until physically resolved: /tmp and
          # /private/tmp, for example, can name the same in-scope directory.
          [[ "$resolved" != "$repo/"* ]] || resolved="${resolved#"$repo/"}"
          ;;
        *)
          if [[ "$rel" == */* ]]; then target="${rel%/*}/$target"; fi
          resolved="$(normalize_relpath "$target")"
          [[ "$target" != /* ]] || resolved="/$resolved"
          ;;
      esac
      if [[ "$resolved" == .. || "$resolved" == ../* ]]; then
        resolved="/$(normalize_relpath "$repo/$resolved")"
      fi
      if [[ -z "$resolved" ]]; then
        import_diagnostic "$client" . UNSUPPORTED "$source; import names the repository directory, not a regular file"
        continue
      fi
      # BFS queues a logical path only at its minimum depth. Physical identity
      # deduplicates bytes/parser work, NOT the directory used for child imports.
      [[ -z "${seen[$resolved]+present}" ]] || continue
      seen["$resolved"]=1
      queue_paths+=("$resolved")
      queue_depths+=("$((depth + 1))")
      queue_sources+=("$source")
    done <<<"$parsed"
  done
}

resolve_chain claude CLAUDE.md 4
claude_files=("${CHAIN_RESULT[@]}")
resolve_chain gemini GEMINI.md "$gemini_import_depth"
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
    # BSD find has no -printf; strip the leading "./" so paths stay
    # repo-relative for exception matching and display parity with git ls-files.
    (cd "$repo" && find . -name AGENTS.md -not -path '*/.git/*' 2>/dev/null | sed 's|^\./||' | sort -u)
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
declare -A COUNTED_IMPORT_OVER=()
# Per-bucket sum of bytes of files that are a documented per-file exception AND
# over the per-file budget. The @-chain budget is checked NET of these, so an
# approved oversized file does not consume the chain budget while the chain
# budget keeps applying to all non-excepted always-on content.
declare -A BUCKET_EXCEPTED=()

byte_count() {
  wc -c <"$1" | tr -d '[:space:]'
}

emit_row() {
  local bucket="$1" rel="$2" status="$3" bytes="$4" note="$5"
  # Keep even diagnostic fields single-line and TSV-safe; never interpret data.
  rel="${rel//\\/\\\\}"
  rel="${rel//$'\t'/\\t}"
  rel="${rel//$'\n'/\\n}"
  rel="${rel//$'\r'/\\r}"
  note="${note//\\/\\\\}"
  note="${note//$'\t'/\\t}"
  note="${note//$'\n'/\\n}"
  note="${note//$'\r'/\\r}"
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
  local rel abs bytes status note identity key current_identity alias occurrence=0
  local -A measured=() group_bytes=() group_except=()
  total_ref=0

  for rel in "$@"; do
    abs="$repo/$rel"
    # Preserve the existing explicit-list accounting for AGENTS/protocol reads.
    # Physical grouping is only part of the two import bucket contracts.
    occurrence=$((occurrence + 1))
    identity="$occurrence"
    if [[ "$bucket" == claude || "$bucket" == gemini ]]; then
      key="$bucket:$rel"
      abs="${IMPORT_PHYSICAL[$key]}"
      identity="${IMPORT_ID[$key]}"
      [[ ! -L "$abs" && -f "$abs" && -r "$abs" ]] || die "import disappeared or changed before measurement: $rel"
      current_identity="$(import_identity "$abs")" || die "cannot identify import before measurement: $rel"
      [[ "$current_identity" == "$identity" ]] || die "import changed identity before measurement: $rel"
    fi
    if [[ ! -f "$abs" ]]; then
      emit_row "$bucket" "$rel" "MISSING" "-" "(optional file absent)"
      continue
    fi
    alias=""
    if [[ -n "${measured[$identity]+present}" ]]; then
      bytes="${group_bytes[$identity]}"
      alias="alias of ${measured[$identity]}; source bytes counted once"
    else
      bytes="$(byte_count "$abs")" || die "cannot measure file: $rel"
      if [[ "$bucket" == claude || "$bucket" == gemini ]]; then
        [[ "$bytes" == "${IMPORT_SIZE[$key]}" ]] || die "import changed size before measurement: $rel"
      fi
      total_ref=$((total_ref + bytes))
      measured["$identity"]="$rel"
      group_bytes["$identity"]="$bytes"
      group_except["$identity"]=1
    fi
    note=""
    status="ok"
    if [[ "$bytes" -gt "$file_budget" ]]; then
      if [[ -n "${EXCEPTION_REASON[$rel]:-}" ]]; then
        status="EXCEPT"
        note="over file budget; documented: ${EXCEPTION_REASON[$rel]}"
      else
        group_except["$identity"]=0
        status="OVER"
        note="over file budget ($file_budget bytes)"
        if [[ -z "${COUNTED_OVER[$rel]:-}" ]]; then
          COUNTED_OVER["$rel"]=1
          if [[ "$bucket" != claude && "$bucket" != gemini ]] || [[ -z "${COUNTED_IMPORT_OVER[$identity]+present}" ]]; then
            violations=$((violations + 1))
          fi
          if [[ "$bucket" == claude || "$bucket" == gemini ]]; then COUNTED_IMPORT_OVER["$identity"]=1; fi
        fi
      fi
    fi
    [[ -z "$alias" ]] || note="${note:+$note; }$alias"
    emit_row "$bucket" "$rel" "$status" "$bytes" "$note"
  done
  # A path-specific exception never silently extends to another alias. Subtract
  # one physical source only when every reached logical alias is excepted.
  for identity in "${!group_bytes[@]}"; do
    if [[ "${group_bytes[$identity]}" -gt "$file_budget" && "${group_except[$identity]}" == 1 ]]; then
      BUCKET_EXCEPTED["$bucket"]=$((${BUCKET_EXCEPTED[$bucket]:-0} + group_bytes[$identity]))
    fi
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
  echo "Scope: repo-local selected-entry-point source bytes, not full client context."
  echo "Profiles: Claude documented/2.1.236 (depth 4); Gemini 0.58.0 tree (depth $gemini_import_depth)."
  echo "Scanner limits: $max_import_edges edges; $max_import_file_bytes bytes/file; $max_import_chain_bytes bytes/chain."
  echo "Scanner shape bounds: 100000 lines/file; delimiter run 128; import path 4096 bytes."
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

for ((diag_index = 0; diag_index < ${#import_diag_clients[@]}; diag_index++)); do
  emit_row IMPORT "${import_diag_clients[$diag_index]}:${import_diag_paths[$diag_index]}" \
    "${import_diag_statuses[$diag_index]}" - "${import_diag_notes[$diag_index]}"
done

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

# The @-chain budget is checked NET of documented per-file exceptions: an
# approved oversized file (an EXCEPT above) is subtracted from its chain total,
# so the chain budget keeps governing all non-excepted always-on content and a
# new non-excepted import still fails strict mode.
claude_excepted="${BUCKET_EXCEPTED[claude]:-0}"
gemini_excepted="${BUCKET_EXCEPTED[gemini]:-0}"
claude_net=$((claude_total - claude_excepted))
gemini_net=$((gemini_total - gemini_excepted))

claude_status="ok"
gemini_status="ok"
chain_over="false"
[[ "$claude_net" -gt "$chain_budget" ]] && {
  claude_status="OVER"
  chain_over="true"
}
[[ "$gemini_net" -gt "$chain_budget" ]] && {
  gemini_status="OVER"
  chain_over="true"
}
[[ "$chain_over" == "true" ]] && violations=$((violations + 1))

# Legacy @chain exception / chain_exception= config is still parsed for backward
# compatibility (no error) but no longer suppresses chain overage -- the blanket
# @chain exception was unbounded. Express an approved residual via per-file
# exceptions (subtracted from the net above) or a configured chain_budget.
chain_deprecation_note=""
[[ -n "$chain_exception_reason" ]] && chain_deprecation_note="deprecated: @chain / chain_exception no longer suppresses chain overage; use per-file exceptions"

build_chain_note() {
  local exc_bytes="$1" net_bytes="$2" note_text=""
  [[ "$exc_bytes" -gt 0 ]] && note_text="net ${net_bytes} B after ${exc_bytes} B excepted, vs ${chain_budget} budget"
  [[ -n "$chain_deprecation_note" ]] && note_text="${note_text:+$note_text; }$chain_deprecation_note"
  printf '%s' "$note_text"
}
claude_note="$(build_chain_note "$claude_excepted" "$claude_net")"
gemini_note="$(build_chain_note "$gemini_excepted" "$gemini_net")"

claude_note="${claude_note:+$claude_note; }repo-local unique source bytes; Claude documented/2.1.236 depth=4; limits=$max_import_edges/$max_import_file_bytes/$max_import_chain_bytes; lines=100000/delimiter=128/path=4096"
gemini_note="${gemini_note:+$gemini_note; }repo-local unique source bytes; Gemini 0.58.0 tree depth=$gemini_import_depth; limits=$max_import_edges/$max_import_file_bytes/$max_import_chain_bytes; lines=100000/delimiter=128/path=4096"
incomplete_count=0
if [[ -n "${IMPORT_INCOMPLETE[claude]:-}" ]]; then
  claude_note+="; partial analysis; known net=$claude_net ($claude_status)"
  claude_status=INCOMPLETE
  incomplete_count=$((incomplete_count + 1))
fi
if [[ -n "${IMPORT_INCOMPLETE[gemini]:-}" ]]; then
  gemini_note+="; partial analysis; known net=$gemini_net ($gemini_status)"
  gemini_status=INCOMPLETE
  incomplete_count=$((incomplete_count + 1))
fi

agents_status="info"

if [[ "$format" == "tsv" ]]; then
  printf 'TOTAL\tclaude_chain\t%s\t%s\t%s\n' "$claude_status" "$claude_total" "$claude_note"
  printf 'TOTAL\tgemini_chain\t%s\t%s\t%s\n' "$gemini_status" "$gemini_total" "$gemini_note"
  printf 'TOTAL\tagents\t%s\t%s\t\n' "$agents_status" "$agents_total"
  printf 'TOTAL\tprotocol\tinfo\t%s\t\n' "$protocol_total"
else
  echo
  echo "Totals (per @-chain budget: $chain_budget bytes; Codex AGENTS total is informational):"
  printf '  %-7s %-30s %10s\n' "$claude_status" "Claude @-chain total" "$claude_total"
  printf '  %-7s %-30s %10s\n' "$gemini_status" "Gemini @-chain total" "$gemini_total"
  printf '  %-7s %-30s %10s\n' "$agents_status" "Codex AGENTS total" "$agents_total"
  printf '  %-7s %-30s %10s\n' "info" "protocol-read total" "$protocol_total"
  [[ -n "$claude_note" ]] && echo "  Claude @-chain: $claude_note"
  [[ -n "$gemini_note" ]] && echo "  Gemini @-chain: $gemini_note"
  echo
  if [[ "$incomplete_count" -gt 0 ]]; then
    echo "INCOMPLETE: $incomplete_count import chain(s); cannot establish the in-scope budget."
  elif [[ "$violations" -eq 0 ]]; then
    echo "Within budget for the declared repo-local scope (no non-excepted overages; external content excluded)."
  fi
  if [[ "$violations" -gt 0 ]]; then
    echo "$violations non-excepted overage(s) found."
    echo "Relocate historical/low-frequency content to docs/ (leave a pointer), or"
    echo "record an intentional overage in an exceptions file with a reason."
  fi
fi

if [[ "$strict" == "true" && ("$violations" -gt 0 || "$incomplete_count" -gt 0) ]]; then
  exit 1
fi
exit 0

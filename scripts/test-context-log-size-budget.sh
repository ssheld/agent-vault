#!/usr/bin/env bash

# Issue #145, PR A: checker/config contract. Byte-mode compaction follows in PR B.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
checker="$repo_root/scaffold/root/scripts/check-memory-budget.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/context-log-budget-test.XXXXXX")"
tmp_root="$(cd "$tmp_root" && pwd -P)"
trap 'rm -rf "$tmp_root"' EXIT
project="$tmp_root/project"
mkdir -p "$project/agent-vault" "$project/custom"
config="$project/agent-vault/memory-budget.config"
log="$project/agent-vault/context-log.md"
passed=0

fail() {
  printf 'FAIL: %s\n%s\n' "$1" "${output:-}" >&2
  exit 1
}
check() {
  "$@" || fail "$*"
  passed=$((passed + 1))
}
contains() { [[ "$output" == *"$1"* ]]; }
absent() { [[ "$output" != *"$1"* ]]; }
run() {
  local expected="$1" rc=0
  shift
  output="$(bash "$checker" --repo "$project" "$@" 2>&1)" || rc=$?
  check test "$rc" -eq "$expected"
}
size_file() { head -c "$2" /dev/zero | tr '\0' x >"$1"; }
row() { contains "$(printf '%s\t%s\t%s\t%s\t' "$@")"; }

# A clean non-Git fixture also represents the hook's materialized index.
size_file "$log" 50000
run 0 --strict --format tsv
check row protocol agent-vault/context-log.md ok 50000
check contains 'built-in defaults'
check contains '60000'
check contains '30000'
check bash -c 'printf "%s\n" "$1" | awk -F "\t" "NF != 5 { bad = 1 } END { exit bad }"' budget-tsv "$output"

for size in 39999 40000 40001 59999 60000 60001; do
  size_file "$log" "$size"
  expected=0 status=ok
  if [[ "$size" -gt 60000 ]]; then
    expected=1
    status=OVER
  fi
  run "$expected" --strict --format tsv
  check row protocol agent-vault/context-log.md "$status" "$size"
done
run 0
check contains 'over context-log budget'

# Other protocol reads, including a same-named unrelated file, keep 40 KB.
size_file "$log" 50000
size_file "$project/agent-vault/plan.md" 40001
size_file "$project/custom/context-log.md" 50000
run 1 --strict --format tsv --protocol-read 'agent-vault/context-log.md agent-vault/plan.md custom/context-log.md'
check row protocol agent-vault/plan.md OVER 40001
check row protocol custom/context-log.md OVER 50000
size_file "$project/agent-vault/plan.md" 1

# Loading role, not physical identity: import aliases retain the generic budget.
printf '@agent-vault/context-log.md @alias.md\n' >"$project/CLAUDE.md"
printf '@agent-vault/context-log.md\n' >"$project/GEMINI.md"
ln -s agent-vault/context-log.md "$project/alias.md"
run 1 --strict --format tsv
check row claude agent-vault/context-log.md OVER 50000
check row claude alias.md OVER 50000
check row gemini agent-vault/context-log.md OVER 50000
check row protocol agent-vault/context-log.md ok 50000
run 1 --strict --format tsv --protocol-read 'agent-vault/context-log.md alias.md'
check row protocol alias.md OVER 50000
check row protocol agent-vault/context-log.md ok 50000
printf 'agent-vault/context-log.md\tintentional import\n' >"$project/exceptions.tsv"
run 1 --strict --exceptions exceptions.tsv --chain-budget 1000 --format tsv
check row claude alias.md OVER 50000
printf 'alias.md\tintentional alias\n' >>"$project/exceptions.tsv"
run 0 --strict --exceptions exceptions.tsv --chain-budget 1000 --format tsv
check row claude agent-vault/context-log.md EXCEPT 50000
check row protocol agent-vault/context-log.md ok 50000
run 1 --strict --file-budget 60000 --chain-budget 1000 --exceptions exceptions.tsv
check contains '@-chain total'
# Stop importing before the isolated protocol/config cases.
printf 'no imports\n' >"$project/CLAUDE.md"
printf 'no imports\n' >"$project/GEMINI.md"

# Config surface lands complete before byte-mode compaction.
printf 'context_log_budget=55000\ncontext_log_target=25000\n' >"$config"
run 0 --strict
check contains "Config: $config"
check contains '55000'
check contains '25000'
run 1 --strict --context-log-budget 45000
check contains '45000'
run 0 --strict --context-log-budget 65000 --context-log-target 35000
check contains '65000'
check contains '35000'
size_file "$log" 55001
run 1 --strict
size_file "$log" 55000
run 0 --strict
printf 'context_log_budget=70000\ncontext_log_target=35000\n' >"$project/explicit.config"
run 0 --strict --config "$project/explicit.config"
check contains "Config: $project/explicit.config"

# Literal custom designation is normalized, but does not alter discovery.
printf 'context_log_path=./custom//context-log.md\nprotocol_read=custom/context-log.md\n' >"$config"
run 0 --strict --format tsv
check row protocol custom/context-log.md ok 50000
check absent 'not in effective protocol_read'
run 2 --strict --protocol-read agent-vault/plan.md
check contains 'not in effective protocol_read'
check absent "$(printf 'protocol\tcustom/context-log.md\t')"

# An explicit uncovered designation is a config error before any misleading
# overage on the canonical log. Pin both 50 KB files from the review repro.
mkdir -p "$project/docs"
size_file "$project/docs/log.md" 50000
size_file "$log" 50000
printf 'context_log_path=docs/log.md\n' >"$config"
for format in text tsv; do
  run 2 --format "$format"
  check contains "context_log_path 'docs/log.md' is not in effective protocol_read"
  check contains 'include it in protocol_read'
  check absent 'over file budget'
  run 2 --strict --format "$format"
  check contains "context_log_path 'docs/log.md' is not in effective protocol_read"
  check absent 'over file budget'
done
# Explicitly choosing the default path is still an assertion of coverage.
printf 'context_log_path=agent-vault/context-log.md\nprotocol_read=agent-vault/plan.md\n' >"$config"
run 2 --strict
check contains 'not in effective protocol_read'
# Narrowed sets remain supported when the designation comes from defaults.
printf 'protocol_read=agent-vault/plan.md\n' >"$config"
run 0 --strict
check contains 'not in effective protocol_read'
run 0 --strict --format tsv
check contains 'not in effective protocol_read'
run 2 --strict --context-log-path agent-vault/context-log.md
check contains 'not in effective protocol_read'
printf 'protocol_read=./agent-vault//context-log.md\n' >"$config"
size_file "$log" 55000
run 0 --strict --format tsv
check row protocol ./agent-vault//context-log.md ok 55000
check absent 'not in effective protocol_read'

# The designation has the same CLI > selected config > default precedence.
run 0 --strict --context-log-path ./custom//context-log.md --protocol-read custom/context-log.md --format tsv
check row protocol custom/context-log.md ok 50000
check contains 'context_log_path=custom/context-log.md'
run 2 --context-log-path custom/context-log.md
check contains 'not in effective protocol_read'
printf 'context_log_path=docs/log.md\n' >"$project/path.config"
run 0 --strict --config "$project/path.config" --context-log-path agent-vault/context-log.md --format tsv
check row protocol agent-vault/context-log.md ok 55000
check contains 'context_log_path=agent-vault/context-log.md'
run 0 --strict --context-log-path docs/log.md --context-log-path agent-vault/context-log.md
run 2 --context-log-path agent-vault/context-log.md --context-log-path docs/log.md

# A generic override is independent and gets an informational migration note.
printf 'file_budget=20000\n' >"$config"
run 0 --strict
check contains 'set context_log_budget explicitly'
run 0 --strict --context-log-budget 60000
check absent 'set context_log_budget explicitly'
printf 'file_budget=20000\ncontext_log_budget=60000\n' >"$config"
run 0 --strict
check absent 'set context_log_budget explicitly'
printf '' >"$config"
run 0 --strict --file-budget 20000
check contains 'set context_log_budget explicitly'

# All four byte settings use decimal, retain their individual zero rules, and
# reject hostile/overflow values before Bash arithmetic sees them.
for key in file_budget chain_budget context_log_budget context_log_target; do
  flag="--${key//_/-}"
  case "$key" in
    context_log_budget) good=060008 ;;
    context_log_target) good=030009 ;;
    *) good=040008 ;;
  esac
  printf '%s=%s\n' "$key" "$good" >"$config"
  run 0 --strict
  check contains "$((10#$good))"
  for value in '' -1 +1 1.5 1e3 '1+2' '1 # comment' 2147483648 999999999999999999999999; do
    printf '%s=%s\n' "$key" "$value" >"$config"
    run 2
    check contains "$key"
    # Invalid supplied config is not concealed by a valid CLI override.
    run 2 "$flag" "$good"
    printf '' >"$config"
    run 2 "$flag" "$value"
    check contains "$key"
  done
  printf '%s=2147483647\n' "$key" >"$config"
  if [[ "$key" == context_log_target ]]; then
    run 2
    check contains 'less than context_log_budget'
  else
    run 0 --strict
  fi
  printf '%s=0000\n' "$key" >"$config"
  case "$key" in
    context_log_*) run 2 ;;
    *) run 1 --strict ;;
  esac
done
printf 'context_log_budget=30000\ncontext_log_target=30000\n' >"$config"
run 2
check contains 'less than context_log_budget'
printf 'context_log_budget=30000\n' >"$config"
run 2
run 0 --context-log-budget 60000
printf 'context_log_target=30001\n' >"$config"
run 2 --context-log-budget 30000
printf 'file_budget=060000\r\nfile_budget=040000\r\ncontext_log_budget=060000\r\ncontext_log_target=030000' >"$config"
run 0 --strict
check contains 'Per-file: 40000 bytes'
printf 'file_budget=000000000000000000000000040000\n' >"$config"
run 0 --strict
check contains 'Per-file: 40000 bytes'

# Designations are relative literal paths, not expansions or traversal.
for path in '' /absolute ../log.md custom/../log.md 'has space.md' . $'bad\033path'; do
  printf 'context_log_path=%s\n' "$path" >"$config"
  run 2
  check contains context_log_path
  # Invalid supplied paths cannot be hidden by a later valid override.
  run 2 --context-log-path agent-vault/context-log.md
  printf '' >"$config"
  run 2 --context-log-path "$path"
  check contains context_log_path
  run 2 --context-log-path "$path" --context-log-path agent-vault/context-log.md
done
printf 'file_budget=$(touch %s/executed)\n' "$tmp_root" >"$config"
run 2
check test ! -e "$tmp_root/executed"
printf 'bogus_key=1\n' >"$config"
run 2
check contains 'unknown config key'
run 2 --config "$project/missing.config"
run 2 --config "$project/custom"
run 2 --config ''
for flag in --file-budget --chain-budget --context-log-budget --context-log-target --context-log-path; do
  run 2 "$flag"
done

# Selecting a config in a different working directory remains explicit.
printf 'context_log_budget=65000\n' >"$project/explicit.config"
pushd "$project/custom" >/dev/null
run 0 --strict --config ../explicit.config
popd >/dev/null
check contains 'Config: ../explicit.config'

# A partially readable selected config cannot silently use defaults or overrides.
printf 'context_log_budget=65000\n' >"$config"
mkdir -p "$tmp_root/bin"
cat >"$tmp_root/bin/cat" <<'EOF'
#!/usr/bin/env bash
if [[ "$#" -eq 2 && "$1" == -- && "$2" == "$FAIL_CONFIG" ]]; then
  printf 'context_log_budget=65000\n'
  exit 1
fi
exec "$REAL_CAT" "$@"
EOF
chmod +x "$tmp_root/bin/cat"
REAL_CAT="$(command -v cat)" FAIL_CONFIG="$config" PATH="$tmp_root/bin:$PATH" run 2 --context-log-budget 70000
check contains 'cannot read config file'
mv "$config" "$project/saved.config"
ln -s missing-config "$config"
# These default-location entries used to be ignored; both report modes now
# reject them instead of silently falling back to built-in defaults.
run 2
check contains 'readable regular file'
run 2 --strict
check contains 'readable regular file'
rm "$config"
mkdir "$config"
run 2
check contains 'readable regular file'
run 2 --strict
check contains 'readable regular file'
rmdir "$config"
mv "$project/saved.config" "$config"

# Protocol-only exceptions use their own effective limit; import behavior above
# is unaffected, even when the same log receives an exception in both buckets.
size_file "$log" 65001
printf 'agent-vault/context-log.md\tintentional protocol overage\n' >"$project/exceptions.tsv"
run 0 --strict --exceptions exceptions.tsv --format tsv
check row protocol agent-vault/context-log.md EXCEPT 65001
size_file "$log" 65000
run 0 --strict --exceptions exceptions.tsv --format tsv
check row protocol agent-vault/context-log.md ok 65000

# UTF-8 paths/content and literal '#' survive the config reader. Count bytes,
# not characters, without changing the established protocol-list grammar.
printf 'context_log_path=custom/café#log.md\nprotocol_read=custom/café#log.md\n' >"$config"
awk 'BEGIN { for (i = 0; i < 20000; i++) printf "é" }' >"$project/custom/café#log.md"
run 0 --strict --format tsv
check row protocol 'custom/café#log.md' ok 40000
check absent 'not in effective protocol_read'
# Missing designated files remain visible and optional, not silently added.
printf 'context_log_path=custom/missing.md\nprotocol_read=custom/missing.md\n' >"$config"
run 0 --strict --format tsv
check row protocol custom/missing.md MISSING -
check absent 'not in effective protocol_read'

printf 'Context-log size budget checks passed (%s assertions).\n' "$passed"

#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
compactor="$repo_root/scaffold/root/scripts/compact-context-log.sh"
checker="$repo_root/scaffold/root/scripts/check-memory-budget.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/byte-retention-test.XXXXXX")"
tmp_root="$(cd "$tmp_root" && pwd -P)"
trap 'rm -rf "$tmp_root"' EXIT
# shellcheck source=scripts/lib/fixed-test-clock.sh
source "$repo_root/scripts/lib/fixed-test-clock.sh"
install_fixed_test_clock "$tmp_root/clock"
passed=0
fail() {
  printf 'FAIL: %s\n%s\n' "$*" "${output:-}" >&2
  exit 1
}
check() {
  "$@" || fail "$*"
  passed=$((passed + 1))
}
contains() { [[ "$output" == *"$1"* ]]; }
absent() { [[ "$output" != *"$1"* ]]; }
bytes() { wc -c <"$1" | tr -d '[:space:]'; }
run() {
  local expected="$1" rc=0
  shift
  output="$("$compactor" "$@" 2>&1)" || rc=$?
  check test "$rc" -eq "$expected"
}
make_log() {
  local path="$1" count="${2:-5}" size="${3:-1500}" i
  mkdir -p "${path%/*}"
  printf '# Context Log\n\n## Usage Rules\n- Newest first.\n\n## Current Snapshot\n- Active branch: main\n\n## Entries\n\n' >"$path"
  for ((i = 1; i <= count; i++)); do
    printf '### 2026-09-06 12:%02d local - codex - entry %d\n' "$((50 - i))" "$i" >>"$path"
    head -c "$size" /dev/zero | tr '\0' x >>"$path"
    printf '\n\n' >>"$path"
  done
}
args() { common=("$d/log.md" --archive "$d/archive.md" --manifest "$d/manifest.md" --rollover-id test-id --require-top-entry 'entry 1'); }

# Shared standalone source and resolved state, including explicit designation.
for tool in "$checker" "$compactor"; do
  name="${tool##*/}"
  awk '/^# BEGIN memory budget config$/ { active=1 } active { print } /^# END memory budget config$/ { active=0; count++ } END { if (count != 1 || active) exit 1 }' "$tool" >"$tmp_root/$name.config"
done
check cmp -s "$tmp_root/check-memory-budget.sh.config" "$tmp_root/compact-context-log.sh.config"
for config in '' 'context_log_path=./custom//log.md' 'context_log_budget=060000
context_log_target=030000
file_budget=040000'; do
  printf '%s\n' "$config" >"$tmp_root/config"
  for tool in check-memory-budget.sh compact-context-log.sh; do
    bash -c 'die() { exit 2; }; source "$1"; read_memory_budget_config "$2"; resolve_context_log_budget; printf "%s|%s|%s|%s\n" "$context_log_budget" "$context_log_target" "$context_log_path" "$context_log_path_explicit"' test "$tmp_root/$tool.config" "$tmp_root/config" >"$tmp_root/$tool.state"
  done
  check cmp -s "$tmp_root/check-memory-budget.sh.state" "$tmp_root/compact-context-log.sh.state"
done

d="$tmp_root/modes"
make_log "$d/log.md"
args
cp "$d/log.md" "$d/before"
run 0 "${common[@]}" --to-budget
check contains 'built-in defaults'
check contains 'Nothing to roll over (byte mode)'
check cmp -s "$d/log.md" "$d/before"
check test ! -e "$d/archive.md"
for flag in --ignore-trigger --allow-target-overage; do
  run 2 "${common[@]}" --keep 2 "$flag"
  run 2 "$d/log.md" --recover "$flag"
done
run 2 "${common[@]}" --keep 2 --to-budget
run 2 "${common[@]}" --keep '' --to-budget
run 2 "${common[@]}" --context-log-target 3000
run 2 "${common[@]}" --to-budget --context-log-budget 3000 --context-log-target 3000

# Use the established count renderer as an independent small-fixture oracle.
# Exercise rendered bytes, not a second implementation of the prefix formula.
for variant in ordinary crlf suffix existing out-of-order same-minute explicit blank-lines multi-blank-lines unicode-blank long-topic fences; do
  seed="$tmp_root/seed-$variant"
  make_log "$seed/log.md"
  extra=()
  case "$variant" in
    crlf)
      sed 's/$/\r/' "$seed/log.md" >"$seed/crlf"
      mv "$seed/crlf" "$seed/log.md"
      ;;
    suffix) printf '## Appendix\nMémoire — suffix without final newline' >>"$seed/log.md" ;;
    existing | out-of-order | same-minute)
      make_log "$seed/archive.md" 1 180
      sed -n '/^### /,$p' "$seed/archive.md" | sed 's/entry 1/existing archive/' >"$seed/archive.next"
      mv "$seed/archive.next" "$seed/archive.md"
      if [[ "$variant" == out-of-order ]]; then
        sed 's/2026-09-06/2027-01-01/' "$seed/archive.md" >"$seed/archive.next"
        mv "$seed/archive.next" "$seed/archive.md"
      elif [[ "$variant" == same-minute ]]; then
        sed -E 's/12:[0-9][0-9]/12:00/' "$seed/log.md" >"$seed/log.next"
        mv "$seed/log.next" "$seed/log.md"
        sed 's/12:49/12:00/' "$seed/archive.md" >"$seed/archive.next"
        mv "$seed/archive.next" "$seed/archive.md"
      fi
      ;;
    explicit) extra=(--boundary 'through mémoire `entry`' --anchors 'entry') ;;
    blank-lines)
      sed 's/^$/   /' "$seed/log.md" >"$seed/log.next"
      mv "$seed/log.next" "$seed/log.md"
      ;;
    multi-blank-lines)
      awk '{ print; if ($0 == "") print "\n" }' "$seed/log.md" >"$seed/log.next"
      mv "$seed/log.next" "$seed/log.md"
      ;;
    unicode-blank)
      sed 's/^$/ /' "$seed/log.md" >"$seed/log.next"
      mv "$seed/log.next" "$seed/log.md"
      ;;
    long-topic)
      awk '/ - entry 3$/ { printf "%s ", $0; for(i=0;i<4096;i++) printf "é"; print ""; next } { print }' "$seed/log.md" >"$seed/log.next"
      mv "$seed/log.next" "$seed/log.md"
      ;;
    fences)
      awk '/^## Current Snapshot$/ { print; print "~~~~md\n## Current Snapshot\n- Context-log rollover: quoted\n~~~~"; next } { print }' "$seed/log.md" >"$seed/log.next"
      mv "$seed/log.next" "$seed/log.md"
      ;;
  esac
  sizes=()
  for keep in 1 2 3 4; do
    d="$tmp_root/oracle-$variant-$keep"
    mkdir -p "$d"
    cp "$seed/"* "$d/"
    args
    run 0 "${common[@]}" --keep "$keep" "${extra[@]}"
    sizes[$keep]="$(bytes "$d/log.md")"
    if [[ "$variant" == explicit && "$keep" -gt 1 ]]; then
      check test "${sizes[$keep]}" -ge "${sizes[$((keep - 1))]}"
    fi
  done
  for target in "${sizes[2]}" "$((${sizes[2]} - 1))"; do
    expected=0
    for keep in 1 2 3 4; do
      if [[ "${sizes[$keep]}" -le "$target" ]]; then expected="$keep"; fi
    done
    d="$tmp_root/byte-$variant-$target"
    mkdir -p "$d"
    cp "$seed/"* "$d/"
    args
    cp "$d/log.md" "$d/before"
    run 0 "${common[@]}" --to-budget --ignore-trigger --context-log-target "$target" "${extra[@]}" --dry-run
    check cmp -s "$d/log.md" "$d/before"
    check test ! -e "$d/manifest.md"
    run 0 "${common[@]}" --to-budget --ignore-trigger --context-log-target "$target" "${extra[@]}"
    check contains "kept $expected,"
    check contains "final=${sizes[$expected]}"
    for name in log archive manifest; do
      check cmp -s "$d/$name.md" "$tmp_root/oracle-$variant-$expected/$name.md"
    done
  done
done

# Exact trigger boundaries and write gates are independent of target selection.
d="$tmp_root/threshold"
make_log "$d/log.md"
args
input="$(bytes "$d/log.md")"
for trigger in "$input" "$((input + 1))"; do
  run 0 "${common[@]}" --to-budget --context-log-budget "$trigger" --context-log-target 3000
  check contains 'Nothing to roll over'
  check test ! -e "$d/archive.md"
done
run 0 "${common[@]}" --to-budget --context-log-budget "$((input - 1))" --context-log-target 3000 --dry-run
check contains 'kept 1, archived 4'
check test ! -e "$d/archive.md"
run 0 "${common[@]}" --to-budget --context-log-target 500 --allow-target-overage
check contains 'Nothing to roll over'
check test ! -e "$d/archive.md"
run 1 "$d/log.md" --to-budget --ignore-trigger --context-log-target 3000 --archive "$d/archive.md" --manifest "$d/manifest.md"
check contains 'gate-required session entry'
printf '\n~~~\nunclosed live tail\n' >>"$d/log.md"
run 1 "${common[@]}" --to-budget
check test ! -e "$d/archive.md"

# Infeasible targets refuse without output parents, even quiet. Best effort is
# explicit, reducing, and bounded by trigger; it cannot rescue every refusal.
d="$tmp_root/refusal"
make_log "$d/log.md"
args
common=("$d/log.md" --archive "$d/history/archive.md" --manifest "$d/meta/manifest.md" --require-top-entry 'entry 1')
cp "$d/log.md" "$d/before"
run 1 "${common[@]}" --to-budget --ignore-trigger --context-log-target 500 --quiet
check contains 'best achievable'
check contains 'mandatory header/snapshot/newest/suffix'
check cmp -s "$d/log.md" "$d/before"
check test ! -e "$d/history"
check test ! -e "$d/meta"
run 1 "${common[@]}" --to-budget --context-log-budget 1000 --context-log-target 500 --allow-target-overage --quiet
check test ! -e "$d/history"
run 0 "${common[@]}" --to-budget --ignore-trigger --context-log-target 500 --allow-target-overage --quiet
check contains 'target missed'
check test "$(bytes "$d/log.md")" -lt "$(bytes "$d/before")"
check test "$(bytes "$d/log.md")" -gt 500

# Overage chooses closest to target, not the largest prefix below trigger.
d="$tmp_root/overage-prefix"
mkdir -p "$d"
cp "$tmp_root/seed-ordinary/log.md" "$d/log.md"
args
larger_bytes="$(bytes "$tmp_root/oracle-ordinary-4/log.md")"
smallest_bytes="$(bytes "$tmp_root/oracle-ordinary-1/log.md")"
check test "$larger_bytes" -gt "$((smallest_bytes * 3))"
check test "$larger_bytes" -lt 60000
run 0 "${common[@]}" --to-budget --ignore-trigger --context-log-target "$((smallest_bytes - 1))" --allow-target-overage --quiet
check contains 'retains 1 entries'
for name in log archive manifest; do
  check cmp -s "$d/$name.md" "$tmp_root/oracle-ordinary-1/$name.md"
done

# Validate checker-only config settings before both byte no-ops and writes.
# An invalid supplied value cannot be hidden by a later valid setting or CLI.
d="$tmp_root/depth-config"
make_log "$d/log.md"
args
cp "$d/log.md" "$d/before"
for value in '' not-a-number 65 99 -1 1.5 000 '1+2' 99999999999999999999 '$(touch never)'; do
  for trailing in '' 'gemini_import_depth=5'; do
    printf 'gemini_import_depth=%s\n%s\n' "$value" "$trailing" >"$d/config"
    for early in false true; do
      extra=()
      if [[ "$early" == true ]]; then extra=(--ignore-trigger --context-log-target 3000); fi
      run 2 "${common[@]}" --to-budget --config "$d/config" "${extra[@]}"
      check contains 'gemini_import_depth must be an integer from 0 to 64'
      check cmp -s "$d/log.md" "$d/before"
      check test ! -e "$d/archive.md"
      check test ! -e "$d/manifest.md"
      check test ! -e "$d/.agent-vault-rollover-log.md"
    done
    for override in false true; do
      extra=()
      if [[ "$override" == true ]]; then extra=(--gemini-import-depth 5); fi
      rc=0
      output="$(bash "$checker" --repo "$d" --config "$d/config" "${extra[@]}" 2>&1)" || rc=$?
      check test "$rc" -eq 2
      check contains 'gemini_import_depth must be an integer from 0 to 64'
    done
  done
done
for value in 0 00 08 64; do
  printf 'gemini_import_depth=%s\n' "$value" >"$d/config"
  run 0 "${common[@]}" --to-budget --config "$d/config" --ignore-trigger --context-log-target 3000 --dry-run
  check contains 'kept 1, archived 4'
  rc=0
  output="$(bash "$checker" --repo "$d" --config "$d/config" 2>&1)" || rc=$?
  check test "$rc" -eq 0
  check contains "tree depth=$((10#$value))"
done

# Config comes from the log location, not cwd; repository config beats adjacent.
d="$tmp_root/config-repo"
make_log "$d/custom/log.md"
git -C "$d" init -q
mkdir -p "$d/agent-vault"
printf 'context_log_budget=60000\ncontext_log_target=030000\ncontext_log_path=uncovered.md\n' >"$d/agent-vault/memory-budget.config"
printf 'context_log_budget=50000\n' >"$d/custom/memory-budget.config"
common=("$d/custom/log.md" --archive "$d/archive.md" --manifest "$d/manifest.md")
pushd / >/dev/null
run 0 "${common[@]}" --to-budget
popd >/dev/null
check contains "Config: $d/agent-vault/memory-budget.config"
check contains 'trigger=60000'
check contains 'positional log is authoritative'
run 0 "${common[@]}" --to-budget --config "$d/custom/memory-budget.config" --context-log-budget 65000
check contains 'trigger=65000'
rm "$d/agent-vault/memory-budget.config"
run 0 "${common[@]}" --to-budget
check contains 'adjacent fallback'
check contains 'does not read this location automatically'
check contains 'trigger=50000'
mkdir "$d/agent-vault/memory-budget.config"
run 2 "${common[@]}" --to-budget
check contains 'readable regular file'
# Count/recovery do not even parse the invalid default configuration.
run 0 "${common[@]}" --keep 99
run 0 "$d/custom/log.md" --recover
rmdir "$d/agent-vault/memory-budget.config"
for value in '' 0 -1 1.5 2147483648 '$(touch never)'; do
  printf 'context_log_target=%s\n' "$value" >"$d/agent-vault/memory-budget.config"
  run 2 "${common[@]}" --to-budget --context-log-target 3000
done

run 2 "${common[@]}" --to-budget --config "$d/missing.config"
run 2 "${common[@]}" --to-budget --config
run 2 "${common[@]}" --to-budget --config ''
run 2 "${common[@]}" --keep 2 --config "$d/custom/memory-budget.config"
run 2 "$d/custom/log.md" --recover --config "$d/custom/memory-budget.config"
# A selected config must be read completely, even on an otherwise safe no-op.
read_bin="$tmp_root/read-bin"
mkdir -p "$read_bin"
cat >"$read_bin/cat" <<'EOF'
#!/usr/bin/env bash
if [[ "$#" -eq 2 && "$1" == -- && "$2" == "$BYTE_READ_CONFIG" ]]; then
  printf 'context_log_target=30000\n'
  exit 1
fi
exec "$BYTE_READ_CAT" "$@"
EOF
chmod +x "$read_bin/cat"
BYTE_READ_CAT="$(command -v cat)" BYTE_READ_CONFIG="$d/custom/memory-budget.config" PATH="$read_bin:$PATH" run 2 "${common[@]}" --to-budget --config "$d/custom/memory-budget.config"
check contains 'cannot read config file'

# Linked worktrees resolve their own repository config, never primary or cwd.
printf 'context_log_budget=61000\n' >"$d/agent-vault/memory-budget.config"
git -C "$d" -c user.name=Test -c user.email=test@example.invalid add .
git -C "$d" -c user.name=Test -c user.email=test@example.invalid commit -qm seed
git -C "$d" worktree add -qb linked "$tmp_root/linked"
printf 'context_log_budget=62000\n' >"$tmp_root/linked/agent-vault/memory-budget.config"
run 0 "$tmp_root/linked/custom/log.md" --to-budget --archive "$tmp_root/linked/archive.md" --manifest "$tmp_root/linked/manifest.md"
check contains 'trigger=62000'
pushd "$d/custom" >/dev/null
run 0 "${common[@]}" --to-budget --config memory-budget.config
popd >/dev/null
check contains 'Config: memory-budget.config'
check contains 'trigger=50000'

# Mandatory snapshot/suffix/newest contents cannot be truncated to meet target.
for mandatory in snapshot suffix newest only-entry; do
  d="$tmp_root/mandatory-$mandatory"
  make_log "$d/log.md" 5 8000
  args
  case "$mandatory" in
    snapshot)
      awk '/^## Current Snapshot$/ { print; for(i=0;i<33000;i++) printf "s"; print ""; next } { print }' "$d/log.md" >"$d/next"
      mv "$d/next" "$d/log.md"
      ;;
    suffix)
      printf '## Appendix\n' >>"$d/log.md"
      head -c 33000 /dev/zero | tr '\0' s >>"$d/log.md"
      ;;
    newest)
      awk '/^### / && !done { print; for(i=0;i<33000;i++) printf "s"; print ""; done=1; next } { print }' "$d/log.md" >"$d/next"
      mv "$d/next" "$d/log.md"
      ;;
    only-entry) make_log "$d/log.md" 1 70000 ;;
  esac
  cp "$d/log.md" "$d/before"
  run 1 "${common[@]}" --to-budget --quiet
  check contains 'cannot meet target'
  check cmp -s "$d/log.md" "$d/before"
  check test ! -e "$d/archive.md"
done

# Recovery consumes recorded bytes even after ambient config becomes invalid.
fault_bin="$tmp_root/fault-bin"
mkdir -p "$fault_bin"
real_mv="$(command -v mv)"
cat >"$fault_bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${@: -1}" == "$BYTE_TEST_DEST" ]]; then
  if [[ "$BYTE_TEST_FAULT" == after ]]; then "$BYTE_TEST_MV" "$@"; fi
  exit 73
fi
exec "$BYTE_TEST_MV" "$@"
EOF
chmod +x "$fault_bin/mv"
for fault in before after; do
  for role in archive manifest log; do
    d="$tmp_root/recovery-$fault-$role"
    make_log "$d/log.md" 5 16000
    args
    cp "$d/log.md" "$d/before"
    run 0 "${common[@]}" --to-budget
    for name in log archive manifest; do cp "$d/$name.md" "$d/expected-$name"; done
    cp "$d/before" "$d/log.md"
    rm "$d/archive.md" "$d/manifest.md"
    PATH="$fault_bin:$PATH" BYTE_TEST_MV="$real_mv" BYTE_TEST_DEST="$d/$role.md" BYTE_TEST_FAULT="$fault" run 3 "${common[@]}" --to-budget
    printf 'context_log_path=../invalid\ncontext_log_target=0\n' >"$d/memory-budget.config"
    run 0 "$d/log.md" --recover --dry-run
    run 2 "$d/log.md" --recover --to-budget
    run 0 "$d/log.md" --recover
    for name in log archive manifest; do check cmp -s "$d/$name.md" "$d/expected-$name"; done
    check test ! -e "$d/.agent-vault-rollover-log.md"
  done
done

printf 'Byte-retention checks passed (%s assertions).\n' "$passed"

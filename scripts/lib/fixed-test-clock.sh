#!/usr/bin/env bash
# Installer and shared contract checks for the companion fixed-test-date.sh.
# Keep this directly under scripts/lib: check-style.sh only finds direct children.
# The allowlist covers these suites and their children, not every repo script:
# scripts/measure-agent-memory-load.sh uses the unsupported +%Y%m%d%H%M%S.
# The fixed backup stamp does not provide uniqueness: use separate repo fixtures
# for distinct backup generations. Git timestamps and file mtimes are not frozen.

FIXED_TEST_CLOCK_DAY='2026-09-06'
FIXED_TEST_CLOCK_MINUTE='2026-09-06 12:00'
FIXED_TEST_CLOCK_STAMP='20260906-120000'
# Capture the source location now, before a caller can change directories.
fixed_test_clock_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1

install_fixed_test_clock() {
  local clock_bin="$1"
  mkdir -p "$clock_bin" || return 1
  clock_bin="$(cd "$clock_bin" && pwd -P)" || return 1
  install -m 0755 "$fixed_test_clock_lib_dir/fixed-test-date.sh" "$clock_bin/date" || return 1
  # Deliberately inherited by the suite's child commands; the caller's cleanup
  # trap owns clock_bin. Sourcing this library alone does not change PATH.
  export PATH="$clock_bin:$PATH"
}

fixed_test_clock_fail() {
  printf 'FAIL: fixed test clock: %s\n' "$*" >&2
  exit 1
}

assert_fixed_test_clock_output() {
  local expected="$1" format="$2" actual
  actual="$(date "$format")" || fixed_test_clock_fail "date [$format] failed"
  [[ "$actual" == "$expected" ]] ||
    fixed_test_clock_fail "date [$format]: expected [$expected], got [$actual]"
  actual="$(bash -c 'date "$1"' bash "$format")" ||
    fixed_test_clock_fail "child date [$format] failed"
  [[ "$actual" == "$expected" ]] ||
    fixed_test_clock_fail "child date [$format]: expected [$expected], got [$actual]"
}

assert_clock_rejects() {
  local clock_bin="$1" expected_diagnostic="$2"
  shift 2
  local rc=0 diagnostic
  date "$@" >"$clock_bin/rejected.stdout" 2>"$clock_bin/rejected.stderr" || rc=$?
  [[ "$rc" -eq 2 ]] ||
    fixed_test_clock_fail "date [$*]: expected exit 2, got $rc"
  [[ ! -s "$clock_bin/rejected.stdout" ]] ||
    fixed_test_clock_fail "rejected date [$*] wrote to stdout"
  diagnostic="$(cat "$clock_bin/rejected.stderr")"
  [[ "$diagnostic" == *"$expected_diagnostic"* ]] ||
    fixed_test_clock_fail "date [$*]: missing diagnostic [$expected_diagnostic], got [$diagnostic]"
  [[ "$diagnostic" == *"argc=$#; args=[$*]"* ]] ||
    fixed_test_clock_fail "date [$*]: missing argument count/values in [$diagnostic]"
}

assert_fixed_test_clock() {
  local clock_bin resolved
  clock_bin="$(cd "$1" && pwd -P)" || fixed_test_clock_fail "cannot resolve clock directory: $1"
  resolved="$(command -v date)" || fixed_test_clock_fail "date is missing from PATH"
  [[ "$resolved" == "$clock_bin/date" ]] ||
    fixed_test_clock_fail "expected PATH to select $clock_bin/date, got $resolved"
  resolved="$(bash -c 'command -v date')" || fixed_test_clock_fail "child date is missing from PATH"
  [[ "$resolved" == "$clock_bin/date" ]] ||
    fixed_test_clock_fail "expected child PATH to select $clock_bin/date, got $resolved"

  assert_fixed_test_clock_output "$FIXED_TEST_CLOCK_DAY" '+%Y-%m-%d'
  assert_fixed_test_clock_output "$FIXED_TEST_CLOCK_MINUTE" '+%Y-%m-%d %H:%M'
  assert_fixed_test_clock_output "$FIXED_TEST_CLOCK_STAMP" '+%Y%m%d-%H%M%S'

  assert_clock_rejects "$clock_bin" 'Unsupported fixed test clock date format' '+%F'
  assert_clock_rejects "$clock_bin" 'Fixed test clock expects one date format argument'
  assert_clock_rejects "$clock_bin" 'Fixed test clock expects one date format argument' '+%Y-%m-%d' extra
  assert_clock_rejects "$clock_bin" 'Fixed test clock expects one date format argument' -u '+%Y-%m-%d'
  echo 'Fixed test clock contract checks passed.'
}

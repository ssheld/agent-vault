#!/usr/bin/env bash

set -euo pipefail

# Contract for the shared "entry timestamps" awk block: the three carriers hold
# it byte for byte, and its conversions are correct on this platform's awk. CI
# runs this on Ubuntu and macOS so both awk implementations execute the table.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-entry-timestamps-test.XXXXXX")"
tmp_root="$(cd "$tmp_root" && pwd -P)"
trap 'rm -rf "$tmp_root"' EXIT
passed=0
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
check() {
  "$@" || fail "assertion: $*"
  passed=$((passed + 1))
}

# Extract only the repo-owned static block; never source an input document.
# Keep malformed/missing/duplicate markers from making parity pass vacuously.
extract_block() {
  awk '
    /^# BEGIN entry timestamps$/ { begins++; active = 1 }
    active { print }
    /^# END entry timestamps$/ { ends++; if (!active) bad = 1; active = 0 }
    END { if (begins != 1 || ends != 1 || active || bad) exit 1 }
  ' "$1"
}
carriers=(
  "scaffold/agent-vault/_assets/hooks/pre-commit"
  "scaffold/root/scripts/compact-context-log.sh"
  "scaffold/root/scripts/check-context-log-rollover.sh"
)
for carrier in "${carriers[@]}"; do
  name="$(basename "$carrier" .sh)"
  extract_block "$repo_root/$carrier" >"$tmp_root/$name.block" || fail "invalid entry-timestamp markers: $carrier"
  check cmp -s "$tmp_root/pre-commit.block" "$tmp_root/$name.block"
done
for damage in missing duplicate reversed; do
  case "$damage" in
    missing) sed '/^# END entry timestamps$/d' "$tmp_root/pre-commit.block" >"$tmp_root/bad-block" ;;
    duplicate) cat "$tmp_root/pre-commit.block" "$tmp_root/pre-commit.block" >"$tmp_root/bad-block" ;;
    reversed) printf '# END entry timestamps\n# BEGIN entry timestamps\n' >"$tmp_root/bad-block" ;;
  esac
  if extract_block "$tmp_root/bad-block" >/dev/null; then fail "damaged block accepted: $damage"; fi
  passed=$((passed + 1))
done
# A carrier that drifts by one byte must fail parity.
sed 's/total > 840/total > 841/' "$tmp_root/pre-commit.block" >"$tmp_root/drifted.block"
if cmp -s "$tmp_root/pre-commit.block" "$tmp_root/drifted.block"; then fail "drift fixture did not change the block"; fi
passed=$((passed + 1))

# shellcheck source=/dev/null
source "$tmp_root/pre-commit.block"

# heading | sort key | earliest possible UTC minute | latest possible UTC minute
# The numeric rows were cross-checked against GNU `date -u -d`.
cat >"$tmp_root/cases" <<'CASES'
2026-11-01 01:15 -0500 - a - end of daylight saving, after|2026-11-01 06:15|2026-11-01 06:15|2026-11-01 06:15
2026-11-01 01:45 -0400 - a - end of daylight saving, before|2026-11-01 05:45|2026-11-01 05:45|2026-11-01 05:45
2026-03-08 03:10 -0400 - a - start of daylight saving, after|2026-03-08 07:10|2026-03-08 07:10|2026-03-08 07:10
2026-03-08 01:50 -0500 - a - start of daylight saving, before|2026-03-08 06:50|2026-03-08 06:50|2026-03-08 06:50
2025-12-31 23:00 -1200 - a - forward across a year|2026-01-01 11:00|2026-01-01 11:00|2026-01-01 11:00
2026-01-01 00:30 +1400 - a - back across a year|2025-12-31 10:30|2025-12-31 10:30|2025-12-31 10:30
2028-02-29 23:30 -0100 - a - forward off a leap day|2028-03-01 00:30|2028-03-01 00:30|2028-03-01 00:30
2028-03-01 00:15 +0100 - a - back onto a leap day|2028-02-29 23:15|2028-02-29 23:15|2028-02-29 23:15
2027-03-01 00:15 +0100 - a - back into a common February|2027-02-28 23:15|2027-02-28 23:15|2027-02-28 23:15
2100-03-01 00:00 +0001 - a - century year is not a leap year|2100-02-28 23:59|2100-02-28 23:59|2100-02-28 23:59
2000-03-01 00:00 +0001 - a - year divisible by 400 is|2000-02-29 23:59|2000-02-29 23:59|2000-02-29 23:59
2026-05-01 00:10 +0100 - a - back into a 30-day month|2026-04-30 23:10|2026-04-30 23:10|2026-04-30 23:10
2026-04-30 23:50 -0100 - a - forward out of a 30-day month|2026-05-01 00:50|2026-05-01 00:50|2026-05-01 00:50
2026-06-10 10:00 +05 - a - two-digit form|2026-06-10 05:00|2026-06-10 05:00|2026-06-10 05:00
2026-06-10 10:00 +0500 - a - same instant, four digits|2026-06-10 05:00|2026-06-10 05:00|2026-06-10 05:00
2026-06-10 10:00 +0545 - a - minutes|2026-06-10 04:15|2026-06-10 04:15|2026-06-10 04:15
2026-06-10 10:00 +0000 - a - zero|2026-06-10 10:00|2026-06-10 10:00|2026-06-10 10:00
2026-06-10 10:00 -0000 - a - negative zero|2026-06-10 10:00|2026-06-10 10:00|2026-06-10 10:00
2026-06-10 10:00 -1200 - a - lowest usable offset|2026-06-10 22:00|2026-06-10 22:00|2026-06-10 22:00
2026-06-10 10:00 +1400 - a - highest usable offset|2026-06-09 20:00|2026-06-09 20:00|2026-06-09 20:00
2026-06-10 10:00 -1201 - a - below the range|2026-06-10 10:00|2026-06-09 20:00|2026-06-10 22:00
2026-06-10 10:00 +1401 - a - above the range|2026-06-10 10:00|2026-06-09 20:00|2026-06-10 22:00
2026-06-10 10:00 -1400 - a - negative fourteen|2026-06-10 10:00|2026-06-09 20:00|2026-06-10 22:00
2026-06-10 10:00 +0560 - a - minutes above 59|2026-06-10 10:00|2026-06-09 20:00|2026-06-10 22:00
2026-06-10 10:00 +15 - a - two-digit form above the range|2026-06-10 10:00|2026-06-09 20:00|2026-06-10 22:00
2026-06-10 10:00 local - a - local|2026-06-10 10:00|2026-06-09 20:00|2026-06-10 22:00
2026-06-10 10:00 EDT - a - abbreviation|2026-06-10 10:00|2026-06-09 20:00|2026-06-10 22:00
2026-01-01 05:00 local - a - unknown range back across a year|2026-01-01 05:00|2025-12-31 15:00|2026-01-01 17:00
2026-12-31 13:00 ChST - a - unknown range forward across a year|2026-12-31 13:00|2026-12-30 23:00|2027-01-01 01:00
2026-13-40 25:61 +0100 - a - not a real minute|2026-13-40 25:61|2026-13-40 25:61|2026-13-40 25:61
2026-02-30 10:00 local - a - not a real day|2026-02-30 10:00|2026-02-30 10:00|2026-02-30 10:00
CASES
# Assigned by the verified repo-owned block above.
# shellcheck disable=SC2154
table_output="$(awk -F '|' "$entry_timestamps"'
  {
    key = entry_key($1); low = entry_bound($1, -1); high = entry_bound($1, 1)
    if (key != $2 || low != $3 || high != $4) {
      bad++
      printf "%s: got %s|%s|%s, want %s|%s|%s\n", $1, key, low, high, $2, $3, $4
    }
  }
  END { printf "rows %d bad %d\n", NR, bad + 0 }
' "$tmp_root/cases")" || fail "conversion table could not run: $table_output"
[[ "$table_output" == "rows 31 bad 0" ]] || fail "conversion table: $table_output"
passed=$((passed + 31))

echo "entry timestamp regression checks passed ($passed assertions)."

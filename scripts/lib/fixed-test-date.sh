#!/usr/bin/env bash
# Fake date executable installed by fixed-test-clock.sh for regression suites.
# Keep this directly under scripts/lib: check-style.sh only finds direct children.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'Fixed test clock expects one date format argument (argc=%s; args=[%s]).\n' "$#" "$*" >&2
  exit 2
fi

fixed_instant='2026-09-06 12:00:00'
day="${fixed_instant%% *}"
time_of_day="${fixed_instant#* }"
case "$1" in
  '+%Y-%m-%d') printf '%s\n' "$day" ;;
  '+%Y-%m-%d %H:%M') printf '%s\n' "${fixed_instant%:*}" ;;
  '+%Y%m%d-%H%M%S') printf '%s-%s\n' "${day//-/}" "${time_of_day//:/}" ;;
  *)
    printf 'Unsupported fixed test clock date format (argc=%s; args=[%s]).\n' "$#" "$*" >&2
    exit 2
    ;;
esac

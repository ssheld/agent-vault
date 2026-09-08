#!/usr/bin/env bash
# Fixed BEFORE measurement: docs/context-log-growth-workload.md.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
compactor="$repo_root/scaffold/root/scripts/compact-context-log.sh"
checker="$repo_root/scaffold/root/scripts/check-memory-budget.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/context-growth-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT
# shellcheck source=scripts/lib/fixed-test-clock.sh
source "$repo_root/scripts/lib/fixed-test-clock.sh"
install_fixed_test_clock "$tmp_root/clock"
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
bytes() { wc -c <"$1" | tr -d '[:space:]'; }
# Bodies in these fixtures contain no Markdown structural syntax. Comparing
# nonblank entry lines proves whole body/order/uniqueness, ignoring separators.
entries() { awk 'FNR==1 { active=0 } /^### / { active=1 } active && NF { print }' "$@"; }
printf 'workload\ttrigger\trollovers\trefusals\tmedian_interval\tretained_bytes\tretained_entries\theadroom_bytes\n'
for workload in normal burst oversized; do
  for trigger in 40000 60000; do
    d="$tmp_root/$workload-$trigger"
    mkdir -p "$d/agent-vault"
    log="$d/agent-vault/context-log.md"
    archive="$d/archive.md"
    manifest="$d/manifest.md"
    printf 'context_log_budget=%s\ncontext_log_target=30000\n' "$trigger" >"$d/agent-vault/memory-budget.config"
    printf '# Context Log\n\n## Usage Rules\n- Newest first.\n\n## Current Snapshot\n- Active: growth fixture\n\n## Entries\n\n### 2026-09-06 12:00 local - codex - session 0000\ninitial\n' >"$log"
    entries "$log" >"$d/expected"
    : >"$d/intervals"
    : >"$d/retained"
    last=0 rollovers=0 refusals=0
    for ((session = 1; session <= 96; session++)); do
      size=$((2048 + (session * 97) % 1024))
      if [[ "$workload" == burst && $((session % 12)) -eq 0 ]]; then size=16000; fi
      if [[ "$workload" == oversized && $((session % 24)) -eq 0 ]]; then size=35000; fi
      printf '### 2026-09-06 12:00 local - codex - session %04d\n' "$session" >"$d/entry"
      if [[ $((session % 2)) -eq 0 ]]; then
        awk -v n="$size" 'BEGIN { for (i=0; i<int(n/2); i++) printf "é"; if (n%2) printf "x" }' >>"$d/entry"
      else
        head -c "$size" /dev/zero | tr '\0' x >>"$d/entry"
      fi
      printf '\n\n' >>"$d/entry"
      awk '/^### / && !done { while ((getline line < entry) > 0) print line; close(entry); done=1 } { print }' entry="$d/entry" "$log" >"$d/next"
      mv "$d/next" "$log"
      {
        entries "$d/entry"
        cat "$d/expected"
      } >"$d/next"
      mv "$d/next" "$d/expected"
      before="$(bytes "$log")"
      rc=0
      "$checker" --repo "$d" --strict --format tsv >"$d/check" || rc=$?
      if [[ "$before" -le "$trigger" ]]; then
        [[ "$rc" -eq 0 ]] || fail 'checker warned below trigger'
      else
        [[ "$rc" -eq 1 ]] || fail 'checker missed over-trigger log'
        cp "$log" "$d/before-log"
        for name in archive manifest; do
          if [[ -e "$d/$name.md" ]]; then cp "$d/$name.md" "$d/before-$name"; fi
        done
        rc=0
        "$compactor" "$log" --to-budget --archive "$archive" --manifest "$manifest" --require-top-entry session >"$d/output" 2>&1 || rc=$?
        if [[ "$rc" -eq 1 ]]; then
          refusals=$((refusals + 1))
          cmp -s "$log" "$d/before-log" || fail 'refusal changed live log'
          for name in archive manifest; do
            if [[ -e "$d/before-$name" ]]; then
              cmp -s "$d/$name.md" "$d/before-$name" || fail "refusal changed $name"
            else
              [[ ! -e "$d/$name.md" ]] || fail "refusal created $name"
            fi
          done
        elif [[ "$rc" -eq 0 ]]; then
          retained="$(bytes "$log")"
          [[ "$retained" -le 30000 ]] || fail 'strict rollover exceeded target'
          if [[ "$last" -ne 0 ]]; then echo "$((session - last))" >>"$d/intervals"; fi
          last="$session"
          rollovers=$((rollovers + 1))
          count="$(awk '/^### / { n++ } END { print n }' "$log")"
          printf '%s %s %s\n' "$retained" "$count" "$((trigger - retained))" >>"$d/retained"
        else
          cat "$d/output" >&2
          fail "unexpected compactor status $rc"
        fi
      fi
      if [[ -e "$archive" ]]; then entries "$log" "$archive" >"$d/actual"; else entries "$log" >"$d/actual"; fi
      cmp -s "$d/expected" "$d/actual" || fail "entry content/order/uniqueness changed at $workload/$trigger/$session"
      [[ "$(awk '/^- Active: growth fixture$/ { n++ } END { print n }' "$log")" == 1 ]] || fail 'snapshot changed'
    done
    median="$(sort -n "$d/intervals" | awk '{ a[NR]=$1 } END { if (!NR) exit 1; if (NR%2) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2 }')"
    ranges="$(awk 'NR==1 { for(i=1;i<=3;i++) lo[i]=hi[i]=$i } { for(i=1;i<=3;i++) { if($i<lo[i])lo[i]=$i; if($i>hi[i])hi[i]=$i } } END { printf "%s-%s\t%s-%s\t%s-%s",lo[1],hi[1],lo[2],hi[2],lo[3],hi[3] }' "$d/retained")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$workload" "$trigger" "$rollovers" "$refusals" "$median" "$ranges"
    if [[ "$workload" == normal ]]; then
      [[ "$refusals" -eq 0 ]] || fail 'normal workload has target refusals'
      if [[ "$trigger" == 40000 ]]; then control_median="$median"; else
        awk -v control="$control_median" -v trial="$median" 'BEGIN { exit !(trial>control) }' || fail '60k failed normal median improvement criterion'
      fi
    fi
  done
done
echo 'Growth contract passed: exact entry preservation, strict target, and normal median improvement.'

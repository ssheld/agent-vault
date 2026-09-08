#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
compactor="$repo_root/scaffold/root/scripts/compact-context-log.sh"
checker="$repo_root/scaffold/root/scripts/check-context-log-rollover.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-fences-test.XXXXXX")"
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
run() {
  rc=0
  output="$("$@" 2>&1)" || rc=$?
}
expect_rc() {
  [[ "$rc" == "$1" ]] || fail "expected exit $1, got $rc: $output"
  passed=$((passed + 1))
}

make_log() {
  cat >"$1" <<'EOF'
# Context Log

## Usage Rules
- Newest entry at top.

## Current Snapshot
- Active branch: `main`

## Entries

### 2026-06-03 09:00 local - codex - rollover session
- Bookkeeping.

### 2026-06-02 10:00 local - codex - feature work
- Implemented X.

### 2026-06-01 10:00 local - codex - older work
- Older body.
EOF
}

rollover() {
  run "$compactor" "$d/log.md" --keep "$1" --archive "$d/archive.md" --manifest "$d/manifest.md" \
    --rollover-id "$2" --require-top-entry 'rollover session' "${@:3}"
}

# Whole-live closure is an authoring gate, including a would-be no-op and suffix.
for marker in '`' '~'; do
  for location in header snapshot kept moved suffix; do
    d="$tmp_root/strict-$location-$marker"
    mkdir "$d"
    make_log "$d/base"
    case "$location" in
      header) at='^# Context Log$' ;;
      snapshot) at='^- Active branch:' ;;
      kept) at='^- Bookkeeping' ;;
      moved) at='^- Implemented' ;;
      suffix) at='never-matches' ;;
    esac
    FENCE_MARKER="$marker" awk -v at="$at" '
      { print }
      $0 ~ at { print ENVIRON["FENCE_MARKER"] ENVIRON["FENCE_MARKER"] ENVIRON["FENCE_MARKER"] "md" }
      END { if (at == "never-matches") print "## Appendix\n" ENVIRON["FENCE_MARKER"] ENVIRON["FENCE_MARKER"] ENVIRON["FENCE_MARKER"] "\nExample through EOF." }
    ' "$d/base" >"$d/log.md"
    cp "$d/log.md" "$d/before"
    run "$checker" "$d/log.md" --quiet
    expect_rc 1
    check test "${output#*unterminated fence in live}" != "$output"
    rollover 1 strict --allow-stale-archive-metadata --adopt-manual-rollover --allow-missing-top-entry
    expect_rc 1
    check test "${output#*unterminated fence in live}" != "$output"
    for keep in 1 99; do
      for mode in --quiet --dry-run; do
        rollover "$keep" strict "$mode"
        expect_rc 1
        check test "${output#*unterminated fence in live}" != "$output"
        check test "${output#*opening line}" != "$output"
        check test "${output#*bug in the rollover}" = "$output"
        check cmp -s "$d/before" "$d/log.md"
        check test ! -e "$d/archive.md"
        check test ! -e "$d/manifest.md"
        check test -z "$(find "$d" -name '.agent-vault-rollover-*' -print)"
      done
    done
  done
done

# The exact #157 regression: a shorter delimiter must not expose a quoted H2.
d="$tmp_root/mixed"
mkdir "$d"
make_log "$d/base"
awk '/^- Bookkeeping/ { print "````md\n```\n## Example section\n```\n````" } { print }' "$d/base" >"$d/log.md"
rollover 1 mixed
expect_rc 0
check test -f "$d/archive.md"
check test "${output#*archived 2}" != "$output"
check test "${output#*outside the Entries}" = "$output"
run "$checker" "$d/log.md" --manifest "$d/manifest.md"
expect_rc 0

# Neither insertion path may put newly generated structure inside a fence.
for role in archive manifest; do
  for contents in empty hidden; do
    d="$tmp_root/header-$role-$contents"
    mkdir "$d"
    make_log "$d/log.md"
    printf '# Historical %s\n\n```md\nUnclosed header example.\n' "$role" >"$d/$role.md"
    if [[ "$contents" == hidden ]]; then
      if [[ "$role" == archive ]]; then
        printf '\n### 2026-05-01 10:00 local - codex - hidden history\n- Body.\n' >>"$d/$role.md"
      else
        printf '\n## rollover: quoted-example\n- boundary: sample\n' >>"$d/$role.md"
      fi
    fi
    cp "$d/log.md" "$d/log.before"
    cp "$d/$role.md" "$d/history.before"
    rollover 99 header-no-op --quiet
    expect_rc 0
    check test "${output#*Warning: unterminated fence in $role}" != "$output"
    for mode in --dry-run --quiet --allow-stale-archive-metadata; do
      rollover 1 refused "$mode"
      expect_rc 1
      check cmp -s "$d/log.before" "$d/log.md"
      check cmp -s "$d/history.before" "$d/$role.md"
      check test -z "$(find "$d" -name '.agent-vault-rollover-*' -print)"
      if [[ "$role" == archive ]]; then check test ! -e "$d/manifest.md"; else check test ! -e "$d/archive.md"; fi
    done
  done
done

# Adoption is not permission to insert a first record into an unclosed example.
d="$tmp_root/adoption-header"
mkdir "$d"
make_log "$d/base"
awk '/^## Current Snapshot/ { print; print "- Context-log rollover: `manual` — boundary: historical"; next } { print }' "$d/base" >"$d/log.md"
printf '# Manifest\n\n~~~md\nUnclosed example.\n' >"$d/manifest.md"
for role in log manifest; do cp "$d/$role.md" "$d/$role.before"; done
rollover 1 adoption --adopt-manual-rollover
expect_rc 1
check test "${output#*unsafe insertion}" != "$output"
for role in log manifest; do check cmp -s "$d/$role.before" "$d/$role.md"; done
check test ! -e "$d/archive.md"
check test -z "$(find "$d" -name '.agent-vault-rollover-*' -print)"

# Extract only the repo-owned static block; never source an input document.
# Keep malformed/missing/duplicate markers from making parity pass vacuously.
extract_fences() {
  awk '
    /^# BEGIN markdown fences$/ { begins++; active = 1 }
    active { print }
    /^# END markdown fences$/ { ends++; if (!active) bad = 1; active = 0 }
    END { if (begins != 1 || ends != 1 || active || bad) exit 1 }
  ' "$1"
}
for helper in check-context-log-rollover compact-context-log check-lessons-archive check-memory-budget; do
  extract_fences "$repo_root/scaffold/root/scripts/$helper.sh" >"$tmp_root/$helper.block" || fail "invalid fence markers: $helper"
  check cmp -s "$tmp_root/check-context-log-rollover.block" "$tmp_root/$helper.block"
done
for damage in missing duplicate reversed; do
  case "$damage" in
    missing) sed '/^# END markdown fences$/d' "$tmp_root/check-context-log-rollover.block" >"$tmp_root/bad-block" ;;
    duplicate) cat "$tmp_root/check-context-log-rollover.block" "$tmp_root/check-context-log-rollover.block" >"$tmp_root/bad-block" ;;
    reversed) printf '# END markdown fences\n# BEGIN markdown fences\n' >"$tmp_root/bad-block" ;;
  esac
  run extract_fences "$tmp_root/bad-block"
  expect_rc 1
done
# shellcheck source=/dev/null
source "$tmp_root/check-context-log-rollover.block"
primitive() {
  # Assigned by the verified repo-owned block above.
  # shellcheck disable=SC2154
  awk "$markdown_fences"'
    { if (!fenced($0)) print $0 }
    END { if (fence_marker != "") print "open:" fence_line }
  ' "$@"
}
for marker in '`' '~'; do
  for length in 3 4 8; do
    fence=""
    for ((i = 0; i < length; i++)); do fence+="$marker"; done
    shorter="${fence%?}"
    for indent in "" " " "   "; do
      for suffix in "" $'\t'; do
        printf '%s%s info\n%s\n~~~not-a-close\n%s trailing\n## Hidden\n%s%s%s\nvisible\n' \
          "$indent" "$fence" "$shorter" "$fence" "$indent" "$fence" "$suffix" >"$tmp_root/primitive.md"
        check test "$(primitive "$tmp_root/primitive.md")" = visible
        # A longer matching closer is valid too; CRLF affects recognition only.
        printf '%s%s\r\n## Hidden\r\n%s%s%s\r\nvisible' "$indent" "$fence" "$indent" "$fence" "$marker" >"$tmp_root/primitive.md"
        check test "$(primitive "$tmp_root/primitive.md")" = visible
      done
    done
  done
done
for opener in '    ```' $'\t~~~' '``' '```bad`info'; do
  printf '%s\nvisible\n' "$opener" >"$tmp_root/primitive.md"
  check test "$(primitive "$tmp_root/primitive.md")" = "$opener"$'\nvisible'
done
printf '~~~info with `backticks`\nhidden\n~~~\nvisible\n' >"$tmp_root/primitive.md"
check test "$(primitive "$tmp_root/primitive.md")" = visible
printf '```\nhidden\n~~~\n' >"$tmp_root/primitive.md"
check test "$(primitive "$tmp_root/primitive.md")" = open:1
: >"$tmp_root/empty.md"
printf 'visible\n' >"$tmp_root/visible.md"
check test "$(primitive "$tmp_root/primitive.md" "$tmp_root/empty.md" "$tmp_root/visible.md")" = visible

# One adversarial example, placed in every structural consumer. Fixed expected
# counts and byte comparisons are independent of the production fence scanner.
cat >"$tmp_root/example.md" <<'EOF'
````md
```
~~~opposite
```` trailing-content
## Current Snapshot
- Latest handoff:
- Context-log rollover: `fake` — boundary: fake
## Usage Rules
## Entries
## rollover: 2026-06-03-999
- archive_file: nonexistent.md
- archive_path_base: invalid
- boundary: fake
- newest_archived: fake
- oldest_archived: fake
### 2099-01-01 00:00 local - example - fake entry
## Next Prompt
CONFLICT_MARKER_EXAMPLE
## relocation manifest example
quoted-anchor-only
```
````
EOF
sed 's/^CONFLICT_MARKER_EXAMPLE$/<<<<<<< conflict example/' "$tmp_root/example.md" >"$tmp_root/example.next"
mv "$tmp_root/example.next" "$tmp_root/example.md"
insert_example() {
  FENCE_EXAMPLE="$tmp_root/example.md" awk -v at="$2" '
    $0 ~ at { while ((getline example < ENVIRON["FENCE_EXAMPLE"]) > 0) print example; close(ENVIRON["FENCE_EXAMPLE"]) }
    { print }
  ' "$1"
}
real_date="$(command -v date)"
mkdir "$tmp_root/clock"
cat >"$tmp_root/clock/date" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == +%Y-%m-%d ]]; then printf '2026-06-03\n'; else exec "$FENCE_REAL_DATE" "$@"; fi
EOF
chmod +x "$tmp_root/clock/date"
for placement in header snapshot kept moved archive-header archive-body manifest-header manifest-body appendix crlf; do
  d="$tmp_root/consumer-$placement"
  mkdir "$d"
  make_log "$d/base"
  cp "$d/base" "$d/log.md"
  case "$placement" in
    header) insert_example "$d/base" '^## Current Snapshot' >"$d/log.md" ;;
    snapshot) insert_example "$d/base" '^- Active branch' >"$d/log.md" ;;
    kept) insert_example "$d/base" '^- Bookkeeping' >"$d/log.md" ;;
    moved) insert_example "$d/base" '^- Implemented' >"$d/log.md" ;;
    archive-header | archive-body)
      printf '# Context Log Archive\n\n### 2026-05-01 10:00 local - codex - historical entry\n- Historical body.\n' >"$d/archive.base"
      if [[ "$placement" == archive-header ]]; then at='^### '; else at='^- Historical'; fi
      insert_example "$d/archive.base" "$at" >"$d/archive.md"
      ;;
    manifest-header | manifest-body)
      printf '# Context Log Rollover Manifest\n\n' >"$d/manifest.md"
      cat "$tmp_root/example.md" >>"$d/manifest.md"
      ;;
    appendix)
      printf '\n## Appendix\n' >"$d/suffix"
      cat "$tmp_root/example.md" >>"$d/suffix"
      printf 'unchanged final line' >>"$d/suffix"
      cat "$d/suffix" >>"$d/log.md"
      ;;
    crlf)
      insert_example "$d/base" '^- Implemented' | awk '{ printf "%s\r\n", $0 }' >"$d/log.md"
      ;;
  esac
  # Empty id requests default sequencing. The fake high sequence must not count.
  PATH="$tmp_root/clock:$PATH" FENCE_REAL_DATE="$real_date" rollover 2 ""
  expect_rc 0
  check test "${output#*archived 1}" != "$output"
  check test "${output#*id 2026-06-03-1;}" != "$output"
  if [[ "$placement" == manifest-body ]]; then
    cp "$d/manifest.md" "$d/manifest.base"
    insert_example "$d/manifest.base" '^- archive_file:' >"$d/manifest.md"
  fi
  PATH="$tmp_root/clock:$PATH" FENCE_REAL_DATE="$real_date" rollover 1 ""
  expect_rc 0
  check test "${output#*archived 1}" != "$output"
  check test "${output#*id 2026-06-03-2;}" != "$output"
  run "$checker" "$d/log.md" --manifest "$d/manifest.md"
  expect_rc 0
  case "$placement" in
    moved | archive-header | archive-body | crlf) example_file="$d/archive.md" ;;
    manifest-header | manifest-body) example_file="$d/manifest.md" ;;
    *) example_file="$d/log.md" ;;
  esac
  # Match the full example block, including markers and all apparent structure.
  FENCE_EXAMPLE="$tmp_root/example.md" FENCE_CRLF="$placement" awk '
    BEGIN { while ((getline line < ENVIRON["FENCE_EXAMPLE"]) > 0) want = want line (ENVIRON["FENCE_CRLF"] == "crlf" ? "\r\n" : "\n") }
    { actual = actual $0 "\n" }
    END { exit !index(actual, want) }
  ' "$example_file" || fail "example bytes changed: $placement"
  passed=$((passed + 1))
  if [[ "$placement" == appendix ]]; then
    tail -c "$(wc -c <"$d/suffix" | tr -d ' ')" "$d/log.md" >"$d/suffix.after"
    check cmp -s "$d/suffix" "$d/suffix.after"
  fi
  if [[ "$placement" == archive-header || "$placement" == archive-body ]]; then
    sed 's/^- anchors:.*/- anchors: quoted-anchor-only/' "$d/manifest.md" >"$d/anchors.md"
    run "$checker" "$d/log.md" --manifest "$d/anchors.md"
    expect_rc 0
  fi
done

# Live EOF closure refuses; safe historical tails warn without being rewritten.
for location in live archive manifest; do
  d="$tmp_root/tail-$location"
  mkdir "$d"
  make_log "$d/log.md"
  rollover 2 tail-first
  expect_rc 0
  if [[ "$location" == live ]]; then file="$d/log.md"; else file="$d/$location.md"; fi
  printf '\n```md\nHistorical example through EOF.\n' >>"$file"
  cp "$file" "$d/tail.before"
  run "$checker" "$d/log.md" --manifest "$d/manifest.md"
  if [[ "$location" == live ]]; then
    expect_rc 1
    rollover 1 tail-second
    expect_rc 1
    check test "${output#*unterminated fence in live}" != "$output"
    check cmp -s "$file" "$d/tail.before"
    rollover 99 no-op
    expect_rc 1
  else
    expect_rc 0
    check test "$(printf '%s\n' "$output" | grep -c 'Warning: unterminated fence')" = 1
    for mode in --quiet --dry-run; do
      rollover 99 tail-no-op "$mode"
      expect_rc 0
      check test "${output#*Warning: unterminated fence in $location}" != "$output"
      rollover 1 tail-preview --dry-run "$mode"
      expect_rc 0
      check test "${output#*generated after-image opening line}" != "$output"
      check cmp -s "$file" "$d/tail.before"
    done
    rollover 1 tail-second
    expect_rc 0
    check test "${output#*Warning: unterminated fence in $location}" != "$output"
    run "$checker" "$d/log.md" --manifest "$d/manifest.md" --quiet
    expect_rc 0
    check test "${output#*Warning: unterminated fence in $location}" != "$output"
    awk 'show { print; exit } /^```md$/ { print; show = 1 }' "$file" >"$d/tail.after"
    awk 'show { print; exit } /^```md$/ { print; show = 1 }' "$d/tail.before" >"$d/tail.expected"
    check cmp -s "$d/tail.expected" "$d/tail.after"
  fi
done
# Even an EOF-terminated moved entry destined for an empty archive now refuses.
d="$tmp_root/new-archive-tail"
mkdir "$d"
make_log "$d/log.md"
printf '\n~~~\nHistorical example through EOF.\n' >>"$d/log.md"
rollover 1 tail
expect_rc 1
check test ! -e "$d/archive.md"
check test ! -e "$d/manifest.md"

# Quoted body bytes participate in complete-entry overlap, and fence state must
# reset between the live log and archive. Keep the appendix closed so this
# fixture still exercises overlap detection, not the earlier live-closure gate.
for body in same different; do
  d="$tmp_root/overlap-$body"
  mkdir "$d"
  make_log "$d/base"
  insert_example "$d/base" '^- Implemented' >"$d/log.md"
  sed -n '/^### 2026-06-02 /,/^### 2026-06-01 /p' "$d/log.md" | sed '$d' >"$d/archive.md"
  if [[ "$body" == different ]]; then
    sed 's/quoted-anchor-only/different quoted body/' "$d/archive.md" >"$d/archive.next"
    mv "$d/archive.next" "$d/archive.md"
  fi
  printf '\n## Appendix\n```\nExample body.\n```\n' >>"$d/log.md"
  rollover 1 overlap
  if [[ "$body" == same ]]; then
    expect_rc 3
    check test "${output#*entry overlap}" != "$output"
  else
    expect_rc 0
  fi
done

# Let the real parser produce plausible output, then fail. Every affected
# consumer must check the producer status before using even a complete-looking
# result. Test-specific matching never evaluates input as a command.
real_awk="$(command -v awk)"
mkdir "$tmp_root/fault"
cat >"$tmp_root/fault/awk" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  if [[ "$argument" == *"$FENCE_FAIL_MATCH"* ]]; then
    "$FENCE_REAL_AWK" "$@"
    echo 'injected fence parser failure after output' >&2
    exit 71
  fi
done
exec "$FENCE_REAL_AWK" "$@"
EOF
chmod +x "$tmp_root/fault/awk"
d="$tmp_root/failures"
mkdir "$d"
make_log "$d/log.md"
rollover 2 fixture
expect_rc 0
for target in 'print fence_line' 'snap + 0' 'val == ""' 'tolower(line) !~ /superseded/' 'seen_entry = 1' \
  'if (seen) { done = 1;' 'bi = index(tolower(line)' 'newest_found + 0' 'Next Prompt[' 'function normalize(s)'; do
  PATH="$tmp_root/fault:$PATH" FENCE_REAL_AWK="$real_awk" FENCE_FAIL_MATCH="$target" \
    run "$checker" "$d/log.md" --manifest "$d/manifest.md" --quiet
  expect_rc 2
  check test "${output#*injected fence parser failure}" != "$output"
done
for role in log archive manifest; do cp "$d/$role.md" "$d/$role.before"; done
for target in 'snap + 0' 'overlap = heading' 'print "consistent"' 'print (end ?' \
  'if (!seen) print NR' 'in_fm' 'print fence_line' 'max_h, min_h' \
  'print max + 1' 'ENVIRON["ROLLOVER_POINTER"]'; do
  for mode in --dry-run --quiet; do
    PATH="$tmp_root/fault:$PATH" FENCE_REAL_AWK="$real_awk" FENCE_FAIL_MATCH="$target" rollover 1 "" "$mode"
    expect_rc 2
    for role in log archive manifest; do check cmp -s "$d/$role.before" "$d/$role.md"; done
    check test -z "$(find "$d" -name '.agent-vault-rollover-*' -print)"
  done
done
PATH="$tmp_root/fault:$PATH" FENCE_REAL_AWK="$real_awk" FENCE_FAIL_MATCH='print "consistent"' rollover 99 no-op
expect_rc 2

# A recovery read failure must leave both outputs and the journal/stages intact.
real_mv="$(command -v mv)"
cat >"$tmp_root/fault/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "${@: -1}" == "$FENCE_STOP_DEST" ]]; then exit 73; fi
exec "$FENCE_REAL_MV" "$@"
EOF
chmod +x "$tmp_root/fault/mv"
d="$tmp_root/recovery-read-failure"
mkdir "$d"
make_log "$d/log.md"
PATH="$tmp_root/fault:$PATH" FENCE_REAL_AWK="$real_awk" FENCE_FAIL_MATCH=never-match-this-program \
  FENCE_REAL_MV="$real_mv" FENCE_STOP_DEST="$d/archive.md" rollover 1 recorded
expect_rc 3
# Author a legacy closure-only after-image in this disposable fixture. Runtime
# recovery must not rewrite the staged payload or its recorded fingerprint.
record=()
while IFS= read -r -d '' field; do record+=("$field"); done <"$d/.agent-vault-rollover-log.md/record"
payload="${record[16]}/log.md"
printf '\n~~~md\nRecorded live example through EOF.\n' >>"$payload"
digest="$(shasum -a 256 "$payload")"
record[15]="${digest%% *}"
printf '%s\0' "${record[@]}" >"$d/.agent-vault-rollover-log.md/record"
before="$(find "$d" -type f -exec shasum -a 256 {} \; | sort)"
for target in 'print fence_line' 'if (seen) { done = 1;'; do
  for mode in --dry-run --quiet; do
    PATH="$tmp_root/fault:$PATH" FENCE_REAL_AWK="$real_awk" FENCE_FAIL_MATCH="$target" \
      run "$compactor" "$d/log.md" --recover "$mode"
    expect_rc 3
    check test "${output#*injected fence parser failure}" != "$output"
    check test "$(find "$d" -type f -exec shasum -a 256 {} \; | sort)" = "$before"
  done
done
run "$compactor" "$d/log.md" --recover
expect_rc 0
check test "${output#*Warning: unterminated fence in live}" != "$output"
check test -z "$(find "$d" -name '.agent-vault-rollover-*' -print)"

# Dynamic field values stay data when the static awk program is composed.
d="$tmp_root/literal-boundary"
mkdir "$d"
make_log "$d/log.md"
rollover 1 literal --boundary 'literal \n and \t text'
expect_rc 0
check grep -Fq -- '- boundary: literal \n and \t text' "$d/manifest.md"
check grep -Fq -- 'boundary: literal \n and \t text' "$d/log.md"
run "$checker" "$d/log.md" --manifest "$d/manifest.md"
expect_rc 0

echo "Markdown fence regression checks passed: $passed assertions."

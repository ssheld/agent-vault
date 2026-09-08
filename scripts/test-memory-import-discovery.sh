#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
checker="$repo_root/scaffold/root/scripts/check-memory-budget.sh"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-imports-test.XXXXXX")"
scratch="$(cd "$scratch" && pwd -P)"
trap 'rm -rf "$scratch"' EXIT
pass=0
fail() {
  echo "FAIL imports: $*" >&2
  printf '%s\n' "${output:-}" >&2
  exit 1
}
check() {
  "$@" || fail "$*"
  pass=$((pass + 1))
}
run() {
  rc=0
  output="$("$checker" --repo "$d" --format tsv "$@" 2>&1)" || rc=$?
}
has() {
  [[ "$output" == *"$1"* ]] || fail "missing $1"
  pass=$((pass + 1))
}
lacks() {
  [[ "$output" != *"$1"* ]] || fail "unexpected $1"
  pass=$((pass + 1))
}
paths() { printf '%s\n' "$output" | awk -F'\t' -v b="$1" '$1 == b && $3 != "MISSING" {print $2}'; }
total() { printf '%s\n' "$output" | awk -F'\t' -v b="$1" '$1 == "TOTAL" && $2 == b {print $4}'; }
bytes() { wc -c <"$1" | tr -d '[:space:]'; }
fresh() {
  d="$scratch/$1"
  mkdir -p "$d"
}
large() { head -c 2000 /dev/zero | tr '\0' x; }

# Assert the recorded live-client fixture as an exact file set.
fresh contracts
cp -R "$repo_root/scripts/fixtures/memory-imports/claude/." "$d/"
run --strict
check test "$rc" = 0
check test "$(paths claude)" = "$(printf '%s\n' CLAUDE.md positive.md inline-a.md inline-b.md depth/one.md depth/two.md depth/three.md depth/four.md)"
lacks INCOMPLETE
has $'IMPORT\tclaude:depth/four.md\tDEPTH'
cp "$d/CLAUDE.md" "$d/GEMINI.md"
run --strict
check test "$rc" = 0
check test "$(paths gemini)" = "$(printf '%s\n' GEMINI.md positive.md inline-a.md inline-b.md comment-inline.md comment-block.md tilde.md depth/one.md depth/two.md depth/three.md depth/four.md depth/five.md)"
lacks $'\tcode-single.md\t'
lacks $'\tfenced.md\t'
run --gemini-import-depth 0 --strict
check test "$(paths gemini)" = GEMINI.md
run --gemini-import-depth 4
check test "$(paths gemini | tail -1)" = depth/four.md
mkdir "$d/agent-vault"
printf 'gemini_import_depth=0\n' >"$d/agent-vault/memory-budget.config"
run
check test "$(paths gemini)" = GEMINI.md
run --gemini-import-depth 1
check test "$(paths gemini | tail -1)" = depth/one.md
for invalid in -1 65 999999999999999999999 '1+1' ''; do
  run --gemini-import-depth "$invalid"
  check test "$rc" = 2
done

# Count the boundary file, not its imports. Client stopping is complete.
for client in claude gemini; do
  fresh "boundary-$client"
  if [[ "$client" == claude ]]; then
    entry=CLAUDE.md
    boundary=4
  else
    entry=GEMINI.md
    boundary=5
  fi
  printf '@f1.md\n' >"$d/$entry"
  for ((i = 1; i <= 6; i++)); do printf '@f%s.md\n' "$((i + 1))" >"$d/f$i.md"; done
  large >>"$d/f$((boundary + 1)).md"
  run --strict --file-budget 1000
  check test "$rc" = 0
  lacks INCOMPLETE
  large >>"$d/f$boundary.md"
  run --strict --file-budget 1000
  check test "$rc" = 1
  has $'\tOVER\t'
  lacks INCOMPLETE
done

# BFS handles the deep-first/shallow-later diamond without hiding descendants.
fresh bfs
mkdir "$d/deep"
printf '@deep/a.md @shared.md\n' >"$d/CLAUDE.md"
printf '@b.md\n' >"$d/deep/a.md"
printf '@c.md\n' >"$d/deep/b.md"
printf '@../shared.md\n' >"$d/deep/c.md"
printf '@oversized.md @CLAUDE.md\n' >"$d/shared.md"
large >"$d/oversized.md"
run --strict --file-budget 1000
check test "$rc" = 1
has $'claude\toversized.md\tOVER\t2000'
check test "$(paths claude | sort | uniq -d)" = ''
lacks INCOMPLETE

# Physical accounting must not suppress either logical expansion context.
fresh aliases
mkdir "$d/source" "$d/alias"
printf '@source/rules.md @alias/rules.md\n' >"$d/CLAUDE.md"
printf '@./child.md\n' >"$d/source/rules.md"
printf 'source child\n' >"$d/source/child.md"
printf 'alias child\n' >"$d/alias/child.md"
ln -s ../source/rules.md "$d/alias/rules.md"
run --strict
check test "$rc" = 0
has $'claude\tsource/child.md\t'
has $'claude\talias/child.md\t'
expected=$(($(bytes "$d/CLAUDE.md") + $(bytes "$d/source/rules.md") + $(bytes "$d/source/child.md") + $(bytes "$d/alias/child.md")))
check test "$(total claude_chain)" = "$expected"
has 'source bytes counted once'
large >>"$d/source/rules.md"
printf 'source/rules.md\tone alias only\n' >"$d/exceptions.tsv"
run --strict --file-budget 1000 --chain-budget 1000 --exceptions exceptions.tsv
check test "$rc" = 1
printf 'alias/rules.md\tsecond alias too\n' >>"$d/exceptions.tsv"
run --strict --file-budget 1000 --chain-budget 1000 --exceptions exceptions.tsv
check test "$rc" = 0
has "after $(bytes "$d/source/rules.md") B excepted"
# Hard links share accounting identity; separate buckets do not share totals.
ln "$d/source/rules.md" "$d/hard.md"
printf '@source/rules.md @hard.md\n' >"$d/CLAUDE.md"
printf '@source/rules.md\n' >"$d/GEMINI.md"
printf 'root child\n' >"$d/child.md"
run
expected=$(($(bytes "$d/CLAUDE.md") + $(bytes "$d/source/rules.md") + $(bytes "$d/source/child.md") + $(bytes "$d/child.md")))
check test "$(total claude_chain)" = "$expected"

# Container-looking example lines must not reset an outer flat fence.
fresh quoted_fences
cat >"$d/CLAUDE.md" <<'EOF'
~~~md
> ~~~
> @hidden.md
~~~
@visible.md

> ~~~
> @hidden.md
> ~~~
@after-quote.md
EOF
printf 'visible\n' >"$d/visible.md"
printf 'after\n' >"$d/after-quote.md"
large >"$d/hidden.md"
run --strict --file-budget 1000
check test "$rc" = 0
check test "$(paths claude)" = "$(printf '%s\n' CLAUDE.md visible.md after-quote.md)"
# Complete EOF fences do not adopt the rollover live-closure refusal policy.
printf '\n~~~\n@hidden.md\n' >>"$d/CLAUDE.md"
run --strict --file-budget 1000
check test "$rc" = 0
lacks INCOMPLETE

fresh spans_comments
# A quoted heredoc plus a marker replacement keeps literal backticks out of
# shell interpretation while preserving the exact multi-line fixture.
cat >"$d/source" <<'EOF'
<!-- @hidden.md --> @visible.md
Before TTliteral T @hidden.md
still literalTT after.
T<!--T @after.md
An unmatched T @unmatched.md
EOF
tr T '\140' <"$d/source" >"$d/CLAUDE.md"
for f in visible after unmatched; do printf 'present\n' >"$d/$f.md"; done
large >"$d/hidden.md"
run --strict --file-budget 1000
check test "$rc" = 0
check test "$(paths claude)" = "$(printf '%s\n' CLAUDE.md visible.md after.md unmatched.md)"
printf '@visible.md\r\n@after.md' >"$d/CLAUDE.md"
run --strict
check test "$rc" = 0
has $'claude\tafter.md\t'
printf 'See @./visible.md#anchor a@hidden.md (@hidden.md) \\@hidden.md\n' >"$d/CLAUDE.md"
run --strict
check test "$rc" = 0
check test "$(paths claude)" = "$(printf '%s\n' CLAUDE.md visible.md)"
printf 'An unmatched \140\n@visible.md\n> \140\n' >"$d/CLAUDE.md"
run --strict
check test "$rc" = 0
has $'claude\tvisible.md\t'

# Large multiline source with a late import exercises bounded line-oriented
# scanning. Assert the result, not wall-clock timing (CI machines differ).
fresh large_multiline
awk 'BEGIN { for (i=0;i<50000;i++) print "A normal line of prose with no imports and an ordinary amount of source content." }' >"$d/CLAUDE.md"
printf '@small.md\n' >>"$d/CLAUDE.md"
printf 'small\n' >"$d/small.md"
run --strict --file-budget 5000000 --chain-budget 5000000
check test "$rc" = 0
check test "$(paths claude)" = "$(printf '%s\n' CLAUDE.md small.md)"
lacks INCOMPLETE

fresh paths
mkdir "$d/sub"
printf 'ok\n' >"$d/..notes.md"
printf 'accent é\n' >"$d/café.md"
printf '@./sub/../..notes.md @./café.md @./sub//../..notes.md\n' >"$d/CLAUDE.md"
run --strict
check test "$rc" = 0
has $'claude\t..notes.md\t'
has $'claude\tcafé.md\t'
check test "$(paths claude | sort | uniq -d)" = ''
printf '@%s/café.md\n' "$d" >"$d/CLAUDE.md"
run --strict
check test "$rc" = 0
has $'claude\tcafé.md\t'
ln -s "$d" "$scratch/absolute-alias"
printf '@%s/absolute-alias/café.md\n' "$scratch" >"$d/CLAUDE.md"
run --strict
check test "$rc" = 0
lacks EXTERNAL
has "/absolute-alias/café.md"
ln -s ../paths "$d/directory-alias"
printf '@directory-alias/café.md\n' >"$d/CLAUDE.md"
run --strict
check test "$rc" = 0
has $'claude\tdirectory-alias/café.md\t'
printf '@. @./\n' >"$d/CLAUDE.md"
run --strict
check test "$rc" = 1
has UNSUPPORTED
printf '@absent.md\n' >"$d/CLAUDE.md"
run --strict
check test "$rc" = 0
has $'IMPORT\tclaude:absent.md\tMISSING'
has 'CLAUDE.md:1'
# An outside file can contain imports; none of its content may be scanned.
printf '@unread-outside.md\n' >"$scratch/external.md"
printf '@%s/external.md @~/.claude/private.md @https://example.invalid/file\n' "$scratch" >"$d/CLAUDE.md"
run --strict
check test "$rc" = 0
has EXTERNAL
lacks unread-outside
lacks INCOMPLETE
printf '@%s/external.md/not-a-directory @../external.md\n' "$scratch" >"$d/CLAUDE.md"
run --strict
check test "$rc" = 0
has EXTERNAL
lacks INCOMPLETE
ln -s "$scratch/external.md" "$d/external-link.md"
printf '@external-link.md\n' >"$d/CLAUDE.md"
run --strict
check test "$rc" = 0
has EXTERNAL
ln -s broken-target "$d/broken.md"
printf '@broken.md\n' >"$d/CLAUDE.md"
run --strict
check test "$rc" = 0
has MISSING
ln -s loop2.md "$d/loop1.md"
ln -s loop1.md "$d/loop2.md"
printf '@loop1.md\n' >"$d/CLAUDE.md"
run --strict
check test "$rc" = 1
has UNSUPPORTED
has INCOMPLETE
mkfifo "$d/pipe"
printf '@pipe @sub\n' >"$d/CLAUDE.md"
run --strict
check test "$rc" = 1
has UNSUPPORTED

# Literal shell-looking filenames are data, never expressions to evaluate.
fresh literal_paths
printf 'present\n' >"$d/evil[\$(touch marker)].md"
printf '@./evil[$(touch marker)].md\n' >"$d/CLAUDE.md"
# Spaces end import tokens; no shell command or filename glob expansion occurs.
run --strict
check test "$rc" = 0
check test ! -e "$d/marker"
printf 'present\n' >"$d/literal[\$USER].md"
printf '@./literal[$USER].md\n' >"$d/CLAUDE.md"
run --strict
check test "$rc" = 0
has $'claude\tliteral[$USER].md\t'
printf '\000@hidden.md\n' >"$d/CLAUDE.md"
run --strict
check test "$rc" = 1
has 'control bytes'
printf 'See\302\240@large.md\n' >"$d/GEMINI.md"
printf 'plain\n' >"$d/CLAUDE.md"
run --strict
check test "$rc" = 1
has 'Unicode whitespace'

# The pinned Gemini backtick matcher accepts a closing prefix of a longer run.
fresh gemini_ticks
printf 'See \140\140 @hidden.md \140\140\140 @visible.md\n' >"$d/GEMINI.md"
printf 'present\n' >"$d/visible.md"
large >"$d/hidden.md"
run --strict --file-budget 1000
check test "$rc" = 0
check test "$(paths gemini)" = "$(printf '%s\n' GEMINI.md visible.md)"
printf 'See ' >"$d/GEMINI.md"
head -c 129 /dev/zero | tr '\0' '\140' >>"$d/GEMINI.md"
printf ' @visible.md\n' >>"$d/GEMINI.md"
run --strict
check test "$rc" = 1
has 'delimiter run exceeds'
cp "$d/GEMINI.md" "$d/CLAUDE.md"
run --strict
check test "$rc" = 1
has $'TOTAL\tclaude_chain\tINCOMPLETE'
fresh scanner_shapes
awk 'BEGIN {for(i=0;i<100001;i++) print ""}' >"$d/CLAUDE.md"
run --strict
check test "$rc" = 1
has 'line limit reached'
printf '@./' >"$d/CLAUDE.md"
head -c 4097 /dev/zero | tr '\0' x >>"$d/CLAUDE.md"
run --strict
check test "$rc" = 1
has 'path exceeds'

# Tiny fixtures force each work limit; overrides cannot disable/raise bounds.
fresh limits
printf '@a.md @b.md\n' >"$d/CLAUDE.md"
printf 'a\n' >"$d/a.md"
printf 'b\n' >"$d/b.md"
AGENT_VAULT_IMPORT_MAX_EDGES=2 run --strict
check test "$rc" = 0
lacks INCOMPLETE
AGENT_VAULT_IMPORT_MAX_EDGES=1 run --strict
check test "$rc" = 1
has INCOMPLETE
AGENT_VAULT_IMPORT_MAX_FILE_BYTES=1 run --strict
check test "$rc" = 1
has INCOMPLETE
AGENT_VAULT_IMPORT_MAX_CHAIN_BYTES=14 run --strict
check test "$rc" = 1
has INCOMPLETE
AGENT_VAULT_IMPORT_MAX_CHAIN_BYTES=14 run
check test "$rc" = 0
has INCOMPLETE
for invalid in 0 -1 10001 '1+1' 99999999999999; do
  AGENT_VAULT_IMPORT_MAX_EDGES="$invalid" run
  check test "$rc" = 2
done
large >"$d/a.md"
AGENT_VAULT_IMPORT_MAX_FILE_BYTES=100 run --strict --file-budget 1000
check test "$rc" = 1
has $'claude\ta.md\tOVER\t2000'
has $'TOTAL\tclaude_chain\tINCOMPLETE'
printf 'a.md\tapproved overage\n' >"$d/exceptions.tsv"
AGENT_VAULT_IMPORT_MAX_FILE_BYTES=100 run --strict --file-budget 1000 --exceptions exceptions.tsv
check test "$rc" = 1
has INCOMPLETE
rc=0
output="$(AGENT_VAULT_IMPORT_MAX_FILE_BYTES=100 "$checker" --repo "$d" 2>&1)" || rc=$?
check test "$rc" = 0
lacks 'Within budget'
has 'cannot establish'

# Scanner errors are not swallowed as an empty list, in either mode.
real_awk="$(command -v awk)"
mkdir "$scratch/bin"
cat >"$scratch/bin/awk" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${MEMORY_IMPORT_PROFILE:-}" ]]; then exit 42; fi
exec "$IMPORT_TEST_REAL_AWK" "$@"
EOF
chmod +x "$scratch/bin/awk"
IMPORT_TEST_REAL_AWK="$real_awk" PATH="$scratch/bin:$PATH" run
check test "$rc" = 2
has 'import scanner/read failed'
IMPORT_TEST_REAL_AWK="$real_awk" PATH="$scratch/bin:$PATH" run --strict
check test "$rc" = 2
has 'import scanner/read failed'
# A real read failure is also operational, not optional absence.
real_wc="$(command -v wc)"
cat >"$scratch/bin/wc" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -c ]]; then exit 43; fi
exec "$IMPORT_TEST_REAL_WC" "$@"
EOF
chmod +x "$scratch/bin/wc"
IMPORT_TEST_REAL_WC="$real_wc" PATH="$scratch/bin:$PATH" run --strict
check test "$rc" = 2
has 'cannot measure imported file'
rm "$scratch/bin/wc"
printf '<div>\n@a.md\n</div>\n' >"$d/CLAUDE.md"
run --strict
check test "$rc" = 1
has UNSUPPORTED
# Literal tabs in diagnostic notes cannot corrupt the five-column TSV schema.
printf '@a.md\n' >"$d/CLAUDE.md"
printf 'a.md\treason\twith-tab\n' >"$d/exceptions.tsv"
run --strict --file-budget 1000 --exceptions exceptions.tsv
check test "$rc" = 0
check test "$(printf '%s\n' "$output" | awk -F'\t' 'NF != 5 {print NR}')" = ''

# Explicit AGENTS/protocol lists retain their pre-existing per-entry accounting.
fresh legacy_lists
printf 'policy\n' >"$d/AGENTS.md"
run --agents 'AGENTS.md AGENTS.md' --protocol-read 'AGENTS.md AGENTS.md'
check test "$rc" = 0
check test "$(total agents)" = "$(($(bytes "$d/AGENTS.md") * 2))"
check test "$(total protocol)" = "$(($(bytes "$d/AGENTS.md") * 2))"

# No incomplete findings AND policy actually included: do not pass vacuously.
fresh actual_vault_wrapper
cp "$repo_root/scaffold/agent-vault/CLAUDE.md" "$d/CLAUDE.md"
cp "$repo_root/scaffold/agent-vault/shared-rules.md" "$d/shared-rules.md"
cp "$repo_root/scaffold/agent-vault/project-context.md" "$d/project-context.md"
cp "$repo_root/scaffold/agent-vault/project-commands.md" "$d/project-commands.md"
# The actual @./lessons.md target is deliberately absent, not synthesized.
run --strict
check test "$rc" = 0
has $'claude\tshared-rules.md\t'
has $'IMPORT\tclaude:lessons.md\tMISSING'
lacks INCOMPLETE
d="$repo_root"
run
lacks INCOMPLETE
lacks UNSUPPORTED
has $'claude\tscaffold/agent-vault/review-policy.md\t'
has $'gemini\tscaffold/agent-vault/review-policy.md\t'
fresh agents_example
cp "$repo_root/scaffold/root/AGENTS.md" "$d/rules.md"
printf '@rules.md\n' >"$d/CLAUDE.md"
run --strict
check test "$rc" = 0
lacks IMPORT
check test "$(paths claude)" = "$(printf '%s\n' CLAUDE.md rules.md)"
printf 'Memory import discovery regression checks passed (%s assertions).\n' "$pass"

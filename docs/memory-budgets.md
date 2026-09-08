# Memory Size Budgets & Compaction

agent-vault project memory is loaded into the model on every session. The
Claude/Gemini `@`-import chain (`CLAUDE.md`/`GEMINI.md` and the files they
import) is concatenated into context at launch and re-injected after every
compaction, so its size is a permanent per-turn cost. As a project matures
these files grow unbounded, and an oversized standing context both costs tokens
and degrades task quality (the model has a finite attention budget; recall
drops as input grows).

This page documents the budget/compaction capability: the policy agents follow,
the checkers that validate it, and the conventions for relocating content out
of the always-on tier without losing it.

The agent-facing policy lives in `scaffold/agent-vault/shared-rules.md` (and its
`scaffold/agent-vault/AGENTS.md` mirror) under **Memory Size Budgets &
Compaction**. This page is the operator/maintainer reference.

## The three budget buckets

Memory is not one pool. Agents load it differently, so the budget report
separates three buckets:

| Bucket | What it is | How it loads |
| --- | --- | --- |
| Claude `@`-chain | `CLAUDE.md` plus everything it `@`-imports, transitively | Auto-loaded into every Claude session |
| Gemini `@`-chain | `GEMINI.md` plus everything it `@`-imports, transitively | Auto-loaded into every Gemini session (reported and budgeted **separately** from the Claude chain — a session loads one, not the union) |
| Codex `AGENTS` chain | all `AGENTS.md` files in the repo (discovered, including nested package/module ones) | Codex concatenates them along the working-directory ancestry up to its own `project_doc_max_bytes` cap (32 KiB by default); reported as **informational** (the per-file budget still flags an individual oversized `AGENTS.md`) |
| Protocol-read files | Files the session-start rules tell agents to read (`context-log.md`, `plan.md`, etc.) | Read when an agent follows the protocol; not auto-imported |

Keeping the buckets separate matters because the same file can be cheap in one
agent and expensive in another, and because the `@`-chain is the only bucket
paid unconditionally every turn.

## `check-memory-budget.sh`

Reports the three buckets for a project and flags files/buckets over budget.

```bash
scripts/check-memory-budget.sh [--repo <path>]
scripts/check-memory-budget.sh --repo <path> --strict           # exit 1 on overage
scripts/check-memory-budget.sh --repo <path> --format tsv       # machine-readable
scripts/check-memory-budget.sh --repo <path> --config <file>    # per-repo budget config
scripts/check-memory-budget.sh --repo <path> --exceptions exceptions.tsv
scripts/check-memory-budget.sh --repo <path> --context-log-budget 60000 --context-log-target 30000
```

Design choices that matter:

- **Auto-discovery, not a hard-coded file set.** The Claude and Gemini chains
  are resolved separately by following `@`-imports from `CLAUDE.md` and
  `GEMINI.md` (a session loads one chain, not the union), and the Codex bucket
  discovers every `AGENTS.md` in the repo (in a git repo: tracked or present,
  honoring `.gitignore`; in a non-git directory: a plain filesystem walk that
  does not consult `.gitignore`), including nested ones, so the report reflects
  what an agent actually loads rather than assuming one project's layout.
- **Tolerant of missing files.** Absent optional files are reported as
  `MISSING` and skipped; they never make the check fail.
- **Warn, do not block, by default.** A plain run reports and warns but exits
  `0`, so it can never block an unrelated commit on a mature repo. Pass
  `--strict` to exit `1` on a non-excepted overage or incomplete in-scope import
  analysis (for example in a dedicated
  CI check), once a project has been brought within budget.
- **Documented exceptions, per file and chain.** A file may legitimately stay
  over its per-file budget when shrinking it further would mean deleting a live
  invariant. Record it in an exceptions file (one `path<TAB>reason` line per
  entry); the report prints the reason and the file is not a strict violation.
  The `@`-chain total is checked **net of** these per-file exceptions: an
  excepted file still loads into context, but it is subtracted from the chain
  total, so an approved oversized file does not consume the chain budget while
  the chain budget keeps governing all non-excepted always-on content. (The
  legacy reserved `@chain` path / `chain_exception=` config is still parsed but
  **deprecated** — it was unbounded and no longer suppresses chain overage;
  express an approved residual via per-file exceptions or a configured
  `chain_budget`.)

### Import discovery contract

The import buckets measure **repo-local unique source bytes from the selected
root CLAUDE.md and GEMINI.md**, not every instruction a client might load.
[Versioned fixtures and probe provenance](../scripts/fixtures/memory-imports/README.md)
record the official references and observed Claude Code 2.1.236 behavior.

- **Claude:** four hops, with the root at depth zero. Recognize ordinary
  whitespace-delimited imports, including several on a line. Ignore tested
  closed HTML comments, matched backtick spans (including multiline spans),
  flat backtick/tilde fences, and indented code. Simple blockquote fences are
  supported. A fragment suffix such as `@rules.md#section` selects the source
  file for byte measurement. An unmatched inline backtick does not hide the
  remainder; an unclosed fence extends to EOF without the rollover helper's
  separate live-closure refusal.
- **Gemini:** pinned v0.58.0 **tree** behavior, default five hops. Its released
  token/code-region rules differ from the documentation: paired backtick
  regions are excluded, but tilde fences and HTML comments are not. Tokens
  begin at whitespace boundaries, start with a dot/slash/ASCII letter, and run
  to whitespace. Claude's fragment stripping does not apply to Gemini.
- At the client boundary, include the file's bytes but do not expand its imports.
  `DEPTH` explains this complete client-imposed stop. Breadth-first discovery
  terminates cycles and repeated logical references without hiding shorter paths.
- Complex raw HTML, fences on list-marker lines, ambiguous deeply indented
  list imports, control bytes, Unicode whitespace, and unsupported path escapes
  are `UNSUPPORTED`, not guessed complete. Delimiter runs longer than 128 have
  an explicit scanner work bound. Ordinary punctuation is not opportunistically
  removed to make a different filename exist. This is not a full Markdown parser.

Container diagnostics require an import candidate **inside the affected
region**, after escape/comment/matched-span exclusions; an email address or an
unrelated later import is not sufficient. Ordinary HTML regions end at blank
lines or their enclosing quote boundary; raw-text HTML, declarations, processing
instructions, and CDATA use their explicit terminators. These bounds follow
the [CommonMark HTML block envelopes](https://spec.commonmark.org/0.31.2/#html-blocks),
without claiming full client HTML parsing. List guards inspect only the
affected indented continuation, not later dedented paragraphs or sibling items.
For an unsupported container, move real imports into ordinary top-level prose;
use supported flat fences or matched code spans for examples.

Bare names such as `@Override` and `@octocat` are valid extensionless import
candidates, not automatic mention exemptions. Missing ordinary imports remain
advisory, but a genuine candidate in an unsupported container remains incomplete.

Relative imports resolve from the **logical importing path**, not the shell's
working directory or a symlink target's directory. Containment checks resolve
directory and leaf symlinks, with a 40-link bound, before opening an imported
file. External/home/URL targets are `EXTERNAL`: listed, excluded, and never read
as memory content. Path resolution can inspect directory/symlink metadata
outside the root, but never opens outside file contents. Missing imports are
visible `MISSING` diagnostics; non-regular or unresolvable in-scope targets
cannot yield a complete strict result.

One physical file (device/inode identity) contributes bytes once per client
chain, including symlink/hard-link aliases. Each logical import context still
expands independently. Alias rows show their actual size with a counted-once
note: **do not sum alias rows** to reconstruct totals. Path-keyed exceptions
do not silently spread to aliases: an oversized physical source is subtracted
only if **every reached logical alias in that client bucket** has an exception.
The checker assumes a stable filesystem snapshot; it is not a security boundary
against hostile concurrent filesystem replacement.

Raw source bytes include import syntax, Markdown, and comments a client may
strip. Repeated client expansion and client-added wrapper/error text are not
reconstructed. This is not an exact prompt-byte or token estimate.
Additional entry points (`.claude/CLAUDE.md`, `CLAUDE.local.md`, `.claude/rules/`,
ancestor/user/managed memory, other Gemini roots) and Gemini flat mode are
outside this issue's scope. AGENTS/protocol-read discovery remains unchanged.

#### Reporting and strict-mode upgrade behavior

`update-project.sh` refreshes the managed checker in place. This release adds
a **new strict failure class** for incomplete in-scope import analysis.
Downstream custom CI/scripts using `--strict` may fail where an older checker
silently passed. Fresh-scaffold and current-repository chains are regression-
gated against unexpected incomplete results. Non-strict runs remain advisory;
the shipped pre-commit warning remains non-blocking, even on operational errors.

| Condition | Report | Default exit | Strict exit |
| --- | --- | --- | --- |
| Complete, within budget | Scoped success summary | 0 | 0 |
| Non-excepted file/chain overage | `OVER` | 0 | 1 |
| Optional or explicitly imported file absent | `MISSING`, with origin for imports | 0 | 0 |
| Known outside target | `EXTERNAL`, excluded | 0 | 0 |
| Cycle or client-depth stopping | Deduplicated traversal / `DEPTH` | 0 | 0 |
| Unsupported in-scope syntax or checker work bound | Diagnostic and chain `INCOMPLETE` | 0 | 1 |
| Invalid configuration, read/scanner failure, observed replacement/disappearance | Actionable error | 2 | 2 |

I/O/usage errors take precedence. An incomplete chain never receives a
“Within budget” summary, even if its known subtotal is small. Known overages
remain visible alongside incompleteness; exceptions cannot waive an incomplete scan.

TSV retains five columns: bucket, path, status, bytes, note. Existing bucket and
`TOTAL` identifiers are retained; `IMPORT` rows hold client-qualified diagnostics,
`-` for unmeasured bytes, and origin notes. Total notes contain the effective
profile and bounds; incomplete totals label known net bytes and overages.
Diagnostic tabs/newlines/backslashes are escaped. Consumers must inspect exit
status and completeness, not infer success from a small numeric total.

#### Depth and scanner limits

`--gemini-import-depth N` / `gemini_import_depth=N` follows CLI > config > default
5 precedence. Values are integers 0–64; zero includes only the entry point.
This models a caller-selected Gemini tree depth, without changing client settings.
The checker does not read or merge global client configuration.

Independent scanner ceilings: 10,000 edges, 4 MiB per parsed file, and 16 MiB of
distinct parsed source bytes per client chain. These are checker work limits,
not presumed client loading thresholds. Accepted file bytes can still be
measured/reported when an import scan is refused. Boundary files need no scan.
Representation bounds additionally limit each parsed file to 100,000 lines,
backtick runs (and Claude tilde runs) to 128 characters, and each import target
to 4,096 bytes. These prevent pathological string/array work within the byte
ceilings; exceeding a bound is incomplete analysis, not a client-imposed stop.

`AGENT_VAULT_IMPORT_MAX_EDGES`, `AGENT_VAULT_IMPORT_MAX_FILE_BYTES`, and
`AGENT_VAULT_IMPORT_MAX_CHAIN_BYTES` may only **lower** their respective positive
production ceilings. They enable small deterministic tests, never disable or
raise a bound. Effective limits are always reported.

The hook measures a temporary checkout of the index. An absolute import/symlink
into the real worktree can therefore become `EXTERNAL` there even when a direct
worktree check includes it. The hook never retargets such paths or falls back to
unstaged content. It displays exclusions even on checker exit zero, explaining
potentially lower staged totals. The existing staged-memory trigger and
independent suppression flag are unchanged.

## Budgets and per-repo configuration

Defaults: general per-file budget **40000 bytes**, designated context-log
protocol-read budget **60000 bytes**, and per `@`-chain total budget
**120000 bytes** (each chain budgeted separately). Sizes are measured in bytes
(`wc -c`) for portability; for the mostly-ASCII memory files this tracks
characters closely and is conservative for multibyte content. The per-file
default mirrors the threshold at which Claude Code warns that a memory file is
large enough to hurt performance, so a file over it is over a real signal. The
`@`-chain default is a softer "standing context is getting heavy" line
(~33K tokens) and is the more project-dependent of the two. The Codex AGENTS
total is informational (Codex enforces its own `project_doc_max_bytes` cap, and
a fresh scaffold already exceeds the 32 KiB default).

These are starting points, not law. Budgets resolve at three levels, highest
priority first: **CLI flag** (`--file-budget`, `--chain-budget`,
`--context-log-budget`, `--context-log-target`) > **committed
config file** > **built-in default**. A repo records its own budget once in
`agent-vault/memory-budget.config` (read automatically when present) so the
choice is durable and discoverable rather than re-typed per invocation:

```
# agent-vault/memory-budget.config -- all keys optional; full-line comments only.
# The parser keeps each value literal (the text after '='), so values may
# contain '#'. This block is runnable as-is; each commented override below is a
# complete key=value with no trailing text, so uncommenting one stays valid.
file_budget=40000
chain_budget=120000
# Protocol-read context log only; import/AGENTS rows keep file_budget:
context_log_budget=60000
# Accepted and validated now; byte-based compaction is not implemented yet:
context_log_target=30000
context_log_path=agent-vault/context-log.md
# Modeled Gemini tree import depth (does not change client settings):
# gemini_import_depth=5
# Override the bucket-3 (protocol-read) file set:
# protocol_read=agent-vault/context-log.md agent-vault/plan.md
# Pin the AGENTS.md set (the default discovers every AGENTS.md):
# agents=discover
# Point at a path<TAB>reason file of per-file documented overages (create it first;
# excepted files are subtracted from the @-chain total):
# exceptions=agent-vault/memory-budget.exceptions.tsv
```

### Context-log allowance and current implementation stage

The designated log gets its own threshold **only in the protocol-read bucket**.
A 50,000-byte `agent-vault/context-log.md` passes there, while a 50,000-byte
`plan.md`, an archive, or another file named `context-log.md` still exceeds the
general default. The threshold is exclusive: 60,000 bytes is within budget;
60,001 bytes is over. This is a storage/rollover allowance, not permission to
read the whole log at session start. Keep the bounded snapshot/recent-entry reads.

If a client imports the log, its import row still uses `file_budget` and its
bytes still contribute to the import chain. A protocol `ok` row and an import
`OVER` row for the same file describe different loading roles, not a contradiction.
Import deduplication and alias-specific exception subtraction are unchanged:
an excepted 50 KB imported log remains excepted under a 40 KB general limit,
even though its protocol row is now within 60 KB. Protocol-only exceptions use
the context-log threshold. Exceptions remain keyed by the displayed path.

`context_log_path` is a literal repo-relative designation in `protocol_read`,
not an extra discovery source. It resolves independently as
`--context-log-path` > selected config > built-in default, just like the byte
settings. `./` and repeated `/` normalize for designation
matching; absolute paths, `..` components, whitespace/control characters, and
empty/dot-only designations are rejected. Physical aliases are not matched.
The existing protocol list is whitespace-separated, so paths containing
whitespace cannot be designated. A custom layout configures both:

```ini
context_log_path=memory/live-log.md
protocol_read=memory/live-log.md agent-vault/plan.md
```

An explicit designation from config or `--context-log-path` must belong to the
effective `protocol_read` set. Otherwise the checker exits 2 in both ordinary
and strict modes, naming the designation and explaining how to include or change
it, before producing unrelated file overages. This also applies when explicitly
choosing the canonical path, or when a CLI `--protocol-read` override excludes
the configured designation. For a one-off narrowed check, supply a matching
`--context-log-path` or use a config without an explicit designation.

If only the **built-in default** designation is excluded by a narrowed protocol
set, the report notes that its protocol size is not checked. This remains
informational, even under `--strict`, preserving existing narrowed file sets.
A designated path included in the set but absent on disk receives the existing
`MISSING` row instead.
No file is automatically imported or added to session-start reads.

```bash
scripts/check-memory-budget.sh --repo . --context-log-path memory/live-log.md \
  --protocol-read 'memory/live-log.md agent-vault/plan.md' --strict
```

The checker reports the selected config source (or `built-in defaults`),
effective budgets, and the designation. TSV keeps its existing five columns
and bucket/status identifiers; config, target, coverage, and migration metadata
appear in the `TOTAL` / `protocol` note. The target is a **reserved retention
setting**: it is accepted and validated alongside the threshold so projects
can adopt the complete config surface before the compactor learns byte-based
retention. `compact-context-log.sh` still requires `--keep N`, reads no budget
config, and does not enforce the target. Preview count-based rollover with
`--dry-run`; no hook or upgrade runs compaction automatically.

The proposed 60,000/30,000 defaults are trial values, not benchmark conclusions.
Byte-based selection, its growth measurements, and operator flags will follow
in the second PR for [#145](https://github.com/ssheld/agent-vault/issues/145).

### Validation and upgrade behavior

All four byte settings accept decimal integers up to **2,147,483,647**.
`file_budget` and `chain_budget` allow zero; both context values must be positive,
and the effective target must be strictly less than the effective threshold.
Lowering the threshold below the default target requires setting a smaller target
too. Leading zeroes are decimal (`040000` means 40,000), not octal. Empty values,
signs, fractions, expressions, and excessive values are errors before arithmetic.
Every supplied byte value is validated, including config values overridden by CLI
flags; valid duplicate settings retain last-occurrence-wins behavior.

Values are literal data, never sourced or evaluated. Full-line comments, CRLF,
and files without a final newline are supported. An unknown key, a selected
non-regular/unreadable config, or a failed config read exits 2 in both ordinary
and strict modes. A malformed selected config never silently falls back to
defaults. The checker automatically looks only at
`<repo>/agent-vault/memory-budget.config`; another location needs `--config`.
Relative explicit config paths remain relative to the invocation directory.

Default-config discovery is intentionally stricter on upgrade: a directory,
dangling symlink, or other non-regular entry at
`agent-vault/memory-budget.config` was previously ignored in favor of defaults
but now exits 2. Remove an unintended entry or replace it with a readable regular
config file. A genuinely absent default config still uses built-in defaults.

Upgrade the managed checker **before adding the new keys**: older checkers reject
them, including `context_log_target`, as unknown-key errors. Both context byte
keys and the path designation are supported together in this release. New numeric
validation can reject previously accepted malformed or oversized settings, and
leading-zero values now have their intended decimal meaning. Documented in-range
plain decimal budgets retain their values; the generic zero settings still work.

`--file-budget` no longer controls the designated log's protocol allowance. If a
project explicitly sets the generic budget but leaves the context budget at its
default, direct reports include an informational note identifying the new key.
Set `context_log_budget` explicitly to preserve a tighter log limit. A CLI
`--context-log-budget` override suppresses this migration note too. These
informational notes neither cause strict failures nor trigger a new recurring
pre-commit warning, and no "already warned" state or rewritten config is stored.

Bootstrap/update propagate the managed checker without creating or rewriting
budget configs, exceptions, logs, or archives for this feature. Managed refreshes
can affect custom strict CI through the documented config/threshold changes;
the shipped hook continues to report checker errors without blocking commits.

## `check-context-log-rollover.sh`

`context-log.md` is append-only and grows fastest. The supported pattern is to
keep one live snapshot plus a recent-entries window and roll older entries into
a dated archive (`agent-vault/context/archive/context-log-YYYY.md`). This
checker validates the result of such a rollover. It is a **checker only** — it
never edits, moves, or rewrites the log.

```bash
scripts/check-context-log-rollover.sh <context-log-file>
scripts/check-context-log-rollover.sh <context-log-file> --archive <archive-file>
scripts/check-context-log-rollover.sh <context-log-file> --manifest <manifest-file>
scripts/check-context-log-rollover.sh <context-log-file> --archive <archive-file> --manifest <manifest-file>
```

Live-file checks:

- exactly one `## Current Snapshot` (catches a stale duplicate snapshot left
  behind by an incomplete rollover — the failure mode where an agent reads
  months-old state as current);
- exactly one `## Usage Rules` and one `## Entries` (a second occurrence signals
  an un-rolled lower half);
- no leftover Git conflict markers;
- if the snapshot declares a latest-handoff pointer, it is non-empty
  (conditional — a project that does not use handoff pointers is fine).

Archive checks (explicit `--archive` or resolved through `--manifest`): every
archived `## Current Snapshot` must be labeled superseded, so it cannot read as
active. Dated headings above the first canonical entry and noncanonical dated
headings of depth 1–3 are rejected; nested dated subheadings inside entries are
allowed.

The checker keys on the named section headings, so it tolerates mixed entry
heading styles (`### YYYY-MM-DD ...`, compact `## YYYY-MM-DD ...`, em-dash
variants) that a real matured log accumulates.

### Fence syntax and EOF behavior

Every structural scan in the rollover checker and compactor uses the same
delimiter rules, including snapshot/handoff pointers, archive boundaries,
manifest fields, record insertion, and default-ID sequencing. Fenced examples
never supply active headings, fields, or rollover IDs. Anchor searches remain
raw-content searches and may match inside examples.

The supported flat subset follows the delimiter rules in
[CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/#fenced-code-blocks):
an opener has at least three identical backticks or tildes with zero to three
leading spaces. Only the same marker with an equal or longer run, zero to three
leading spaces, and a spaces/tabs-only suffix closes it. Opposite markers,
shorter runs, and apparent closers with trailing content stay inside the block.
Backtick info strings cannot contain backticks; tilde info strings may.
Four-space/tab-indented markers are not fences in this subset; list/blockquote
containers and HTML-comment parsing are not added to the context-log helpers.
Recognition tolerates CRLF without stripping carriage returns from stored bodies.

An unclosed fence deterministically extends to EOF; this is a complete parse,
not a read/parser failure. The caller applies a separate closure policy:

| Operation | Unclosed live fence | Unclosed archive/manifest fence |
| --- | --- | --- |
| Ordinary checker | Finding, exit 1 | Warning; other findings still fail |
| Ordinary compactor, including no-op and dry-run | Refusal, exit 1, outputs unchanged | Warning; unsafe insertion still refuses |
| Explicit ready recovery, including dry-run | Warning for otherwise valid recorded outputs | Warning for otherwise valid recorded outputs |

The live gate covers the **whole file**, including an untouched trailing suffix.
It runs before entry counting, session gates, and no-op success. This intentional
authoring safeguard prevents a preserved unclosed suffix from failing generated
output validation with a misleading “bug in the rollover” message. No metadata,
adoption, or session-gate override bypasses closure. New rollovers cannot move
an unclosed live entry even into a previously absent archive.

Historical warnings identify the source role/path and opening line and survive
`--quiet`, including successful validation and recovery previews. Generated or
recorded after-image line numbers are labeled as such. Each checker invocation
reports an EOF condition once per file, not once per structural scan; a compactor
can report it again when validating a later image. Warnings do not certify that
the text after an opener was intended as an example, and never excuse hidden
required records/boundaries or inconsistent pointers. Only the supplied files and
the effective archive selected by the existing resolution rules are inspected;
the checker does not crawl every old record's archive.

Actual read/awk failures exit 2 during checking or ordinary preparation, and
partial results must not authorize success. Pending-transaction failures retain
exit 3 and the existing recovery safeguards.

### Safe insertion around historical fences

A write-producing rollover or dry-run refuses (exit 1, outputs unchanged) if an
unclosed archive/manifest header would enclose new entries or a generated record.
It also refuses to put an unclosed moved batch before existing archived entries.
These are structural-preservation checks, not optional lint: neither
`--allow-stale-archive-metadata` nor `--adopt-manual-rollover` bypasses them.
The diagnostic identifies the source and opening line; batch-relative lines are
explicitly labeled. An existing unclosed historical tail can remain unchanged
when the new batch/record is inserted outside it. No automatic closer is added.
A read-only check or no-op can warn and succeed on a header-only historical file
when no current requirement demands a visible record/entry; this does not promise
that a later insertion will be safe. The compactor checks existing manifest EOF
state even on no-ops without validating an old record against a newly selected
annual archive, preserving rotation and manual-adoption behavior.

Older helpers could write manifest records inside an unclosed header while
reporting success. The corrected checker does not promote those fenced records
to active history: a live pointer with no visible record fails validation.
Back up the files, inspect version history and the intended example boundaries,
and manually reconcile them; do not use adoption merely to bypass this state.

### Layer-2 rollover assertions (`--manifest`)

The structural checks above catch a botched *shape*; they cannot catch a
rollover whose **durable description is stale**. The failure mode (seen on the
first real downstream rollover) is *cite-then-mutate*: the archive boundary and
kept/archived counts are finalized, then the gate-required session entry is
added — so the live pointer cites a boundary that is no longer the newest entry
actually moved into the archive. `--manifest` makes that mismatch mechanical by
comparing the pointer's *claim* to the manifest, and the manifest to archive
*reality*.

A rollover **manifest** is the parsed source of truth — one record per rollover,
newest first, at `agent-vault/context/archive/context-log-manifest.md`:

```md
## rollover: 2026-05-29-1
- archive_file: context-log-2026.md
- archive_path_base: manifest
- boundary: through PR-A net-of-excepted (recent-window top before rollover)
- newest_archived: 2026-05-29 17:00 local - claude - PR-A net-of-excepted shipped
- oldest_archived: 2026-01-04 09:00 local - bootstrap - initial project setup
- kept: 5
- archived: 142
- anchors: net-of-excepted; rollover policy guard
```

The live `## Current Snapshot` keeps a human-readable pointer that carries a
stable link (`rollover_id` + the boundary text) back to that record:

```md
- Context-log rollover: `2026-05-29-1` — boundary: through PR-A net-of-excepted (recent-window top before rollover)
```

All fields except the compatibility marker `archive_path_base` are **required**
(`kept` / `archived` must be non-negative integers). New records always include
the marker; when supplied it must appear once and equal `manifest`. The
`*_archived` values are the entry heading text with the leading `#`s removed.
With `--manifest`, the checker parses the newest manifest record and asserts:

- the record carries every required field, so it matches the compactor's contract
  (a manifest missing `kept`/`archived`/`anchors` is rejected, not silently
  accepted);
- the live pointer references that record's id and repeats its `boundary`
  verbatim (a stale or absent pointer is flagged);
- `newest_archived` / `oldest_archived` **exactly match** the entry the checker
  independently selects as newest / oldest. Entry timestamps normalize to
  `YYYY-MM-DD HH:MM`; among entries sharing a minute the archive's newest-at-top
  order breaks the tie (top-most is newest, bottom-most is oldest), so naming a
  wrong same-minute heading is caught — not just an older timestamp (the
  cite-then-mutate catch);
- every nonempty normalized `anchor` appears on an archive line, with at least
  one such anchor required. Both sides remove backticks/asterisks and collapse
  and trim whitespace; matching remains case-sensitive, literal, and line-local.
  Underscores, links, and other punctuation stay literal. This is lightweight
  normalization, not Markdown rendering (`foo` can match `f*oo*`); prefer
  distinctive anchors. Raw archived text and exact boundary comparisons do not
  change;
- no orphaned top-level `Next Prompt` heading survives in the archive (it must
  stay nested under its archived entry, never read as an active instruction).

`--manifest` is opt-in: without it, only the structural and explicit archive
checks run. The counts are validated as integers but **not** reconciled against
live/archive entry totals — a single archive accumulates many rollovers, so
`archived` is a per-rollover figure, not the archive's row count; count self-consistency is
left to the `compact-context-log.sh` compactor that emits them.

### Archive paths and legacy migration

The newest record selects the path convention; older records are preserved.
All resolved archives receive the same structural and Layer-2 checks.

| Input | Archive selection |
| --- | --- |
| Explicit `--archive` | Use that file; its basename must match the record. |
| Absolute `archive_file` | Use that exact path; no basename fallback. |
| Relative path with `archive_path_base: manifest` | Resolve from the manifest's directory; no fallback, even if a same-named file exists beside it. |
| Relative path without the marker | Deprecated legacy behavior: use its basename beside the manifest, with a warning even under `--quiet`. Never try manifest-relative semantics first. |

An empty, duplicate, or unsupported marker is an error, even with `--archive`.
The explicit override is useful for staging/recovery, but a matching basename
and passing content checks do **not** establish original destination identity.
Legacy lookup provides compatibility, not identity validation either.

New compactor records use paths relative to the **final manifest directory**,
computed from canonical destinations, not temporary stages or the invocation
directory. For separate `metadata/manifest.md` and `history/archive.md` outputs:

```md
- archive_file: ../history/archive.md
- archive_path_base: manifest
```

These paths survive moving the whole directory tree with its relative layout
intact. Do not relocate destinations while a recovery transaction is pending.

Update **both** installed rollover helpers together using `update-project.sh`;
inspect its output for locally customized/unmanaged helpers that were skipped.
Older checkers tolerate the new field but do not implement manifest-relative
lookup: nested paths still require explicit `--archive`. An older writer can
prepend a new unmarked record while retaining older marked records.

To migrate without waiting for another write-producing rollover:

1. Back up the manifest and identify the intended archive from version control,
   prior commands, or backups. Do not infer identity from a matching basename.
2. In the newest record only, replace `archive_file` with the verified path
   relative to that manifest's directory and add `archive_path_base: manifest`.
   For a verified adjacent archive, the warning prints the exact replacement
   fields. Do not merely add the marker to an old repo-relative path.
3. Run the checker with `--manifest` and **without** `--archive` to verify strict
   lookup, then review the diff. Historical records need not be rewritten.

Legacy lookup is deprecated but remains supported in this release. Its removal
requires a separately approved breaking change with migration guidance, not a
calendar deadline or an assumption that every project has rolled over again.
No-ops and dormant projects do not acquire a new record automatically.

## `compact-context-log.sh`

Automates the context-log rollover the checker validates. It keeps the single
`## Current Snapshot` plus the newest `--keep` entries, moves older entries into
the dated archive (newest-at-top), writes the live `Context-log rollover`
pointer, and prepends a record to the manifest. Prose memory files
(`project-context.md`, `lessons.md`, …) deliberately stay agent-driven and are
out of scope.

Only canonical entries inside `## Entries` participate in counting, the newest
entry gate, selection, and the live-side overlap safety check. That section ends
at the next real H1/H2 heading (`#` or `##`) or EOF; headings inside the supported
backtick/tilde fences do not terminate it. The suffix from the terminating
heading onward stays live byte-for-byte, including CRLF and a missing final
newline. Pointer rewriting happens before this untouched suffix is appended.

Canonical-looking headings beyond that boundary produce a count-and-line-number
warning, including on no-op/dry-run and with `--quiet`. They are not silently
reclassified as live entries. If a mid-log `## Notes` unintentionally stranded
later entries, fix the section structure before rolling over. A top-level
`Next Prompt` (or `Suggested Next Prompt`) after Entries still blocks a
write-producing rollover; keep prompts nested under their entries.

For logs compacted by an older helper, inspect prior archives and version-control
history for non-entry sections accidentally moved out of the live log. Preserve
backups and restore intended sections manually after verifying their original
placement. This fix does not automatically relocate historical content.

```bash
scripts/compact-context-log.sh agent-vault/context-log.md --keep 20 \
  --archive agent-vault/context/archive/context-log-2026.md \
  --manifest agent-vault/context/archive/context-log-manifest.md \
  --require-top-entry "rollover" --dry-run
```

Rollover is recoverable, not an atomic three-file transaction:

- **It does not invent the gate-required entry.** Add the rollover session entry
  first (the metadata gate), then run the compactor. A write-producing rollover
  **refuses by default** unless the newest entry is asserted with
  `--require-top-entry <str>` (it aborts, exit 1, no writes, if that marker is
  not the newest heading); `--allow-missing-top-entry` is the explicit escape
  hatch. Refusing by default — not only when the flag happens to be passed — is
  what keeps the cite-then-mutate workflow closed.
- **Counts and boundary are finalized after that entry is in place**, from the
  live file as it stands, so they cannot describe a pre-entry state.
- **Prepare all outputs before replacing any.** Validate destination types,
  parent paths, and distinct identities; reject final-component symlinks, special
  files, hard-link aliases, and file/parent collisions. Build from temporary input
  snapshots, self-validate with `check-context-log-rollover.sh --manifest`, and
  stage all three replacements before publishing a recovery record. Recheck the
  original fingerprints before committing. Preparation failures leave the three
  outputs unchanged, although new parent directories may remain.
- **Each file is replaced by an atomic destination-local rename** of a complete
  staged file, in archive → manifest → live-log order. The stages are private
  subdirectories of the destination directories, on their respective filesystems.
  An interruption can leave a mixture of old/new outputs; the persisted record
  and remaining staged files allow explicit roll-forward without duplicating
  entries or issuing a second rollover ID.
- **One writer for the whole destination set.** Do not run compaction, recovery,
  or an editor concurrently against these files. There is no cross-process lock,
  simultaneous three-path visibility, or power-loss/network-filesystem durability
  guarantee. Stop the original process and any children before recovery.

`--rollover-id`, `--boundary`, and `--anchors` default to a dated id (the next
same-day sequence is the max existing suffix + 1, never a re-used gap) and values
derived from the moved entries; pass them to override. Ordinary `--dry-run`
builds and validates using temporary scratch, but creates no destination parents,
stages, or persistent recovery record. A healthy no-op also leaves no persistent
artifacts. Paths with spaces and shell metacharacters are supported; newline/CR
paths are rejected because the Markdown metadata format cannot represent them.
SHA-256 uses the platform's `sha256sum` or `shasum`. Existing output mode bits
are preserved; new outputs are owner-only (`0600`). Newly created directories use
a private umask. As with the prior rename-based writer, this does not preserve
inode identity or explicitly copy ownership, ACLs, or extended attributes.

### Adopting a previously manual rollover

A manually rolled-over log may have a live rollover pointer and archived entries
but no compactor manifest. A missing, empty, or header-only manifest now receives
a distinct diagnostic. First confirm the `--archive` and `--manifest` paths: if a
manifest already exists elsewhere, select it; if it was accidentally deleted,
restore it rather than treating its loss as first-time adoption.

When the history really was maintained manually, ordinary `--dry-run` can preview
the next rollover without changing any outputs. A write requires the one-time
`--adopt-manual-rollover` acknowledgement:

```bash
scripts/compact-context-log.sh agent-vault/context-log.md --keep 20 \
  --archive agent-vault/context/archive/context-log-2026.md \
  --manifest agent-vault/context/archive/context-log-manifest.md \
  --require-top-entry "rollover" --adopt-manual-rollover --dry-run
```

Inspect the preview, then remove `--dry-run` to apply it. The first automated
rollover preserves existing archived entries, writes a new manifest record, and
replaces the live pointer. It does not invent retrospective records for earlier
manual rollovers; a no-op does not create a manifest or change the pointer. Remove
`--adopt-manual-rollover` from later commands: it is only valid when a live pointer
exists and the supplied manifest has no records. Pending transactions, entry
overlap, mismatched **existing** manifest records, and the session-entry gate still
refuse as before. This option cannot be combined with `--recover`, and does not
override the separate archive-header metadata check.

### Recovery and failure handling

**Before upgrading helpers, finish or reconcile pending transactions.** Update
the rollover checker and compactor together. A ready transaction is checked
using its entire effective after-image set under the corrected delimiter rules.
If fences hide the required manifest record or cited archive boundaries, or a
parser fails, recovery refuses with exit 3 before further writes, retaining the
journal and stages. An otherwise valid EOF-terminated historical tail warns
but does not block recovery.

**Recovery completes recorded bytes; it does not author a new rollover.** Explicit
`--recover` also downgrades only the live EOF-closure finding to a warning, using
the same policy before replacement **and after installation**. It does not trust
an older helper's validation or infer its version: all current structural checks
and recorded fingerprints still apply. An unclosed before-image alone does not
invalidate a sound after-image. This works for staged/partially installed results
and when all outputs are installed but the journal is still `ready`.

A successful recovery can therefore leave a live log that ordinary checking
rejects. After the transaction and cleanup complete, inspect and explicitly close
the intended live fence as a separate edit, then run the ordinary checker and
preview the next rollover. No historical-helper download/downgrade is needed.
Committed cleanup does not validate later user edits, including new open fences;
recovery with no record only reports that absence and does not validate documents.

Never edit staged payloads or their recorded fingerprints to force validation,
and do not delete recovery data to enable a fresh rollover.

```bash
scripts/compact-context-log.sh agent-vault/context-log.md --recover --dry-run
scripts/compact-context-log.sh agent-vault/context-log.md --recover
```

Recovery takes the original destinations and validated replacement bytes from the
record. Do not pass `--keep`, destination paths, or other generation options with
`--recover`. Before any recovery write, every output must match its recorded
before/after fingerprint and expected type/permissions; the complete effective
result must pass the checker under the recovery-only closure policy above.
Already-installed files are skipped, unchanged originals are replaced, and
diverged files or damaged/missing required stages
cause refusal without recovery writes. Fix the underlying IO problem before
retrying recovery. Interrupted recovery is itself retryable.

A committed record permits cleanup only, never replay over later edits. An empty
transaction directory may be residue from a **completed rollover** whose final
cleanup was interrupted after the record was removed; all intended output bytes
may already be installed. It can also indicate interrupted setup or a deleted
ready record. The diagnostic names the completed-rollover possibility, but an
empty directory alone cannot distinguish these causes: manual confirmation is
still required, including the checker and exact-once entry checks described below.
The record also carried the original archive/manifest paths: checking newly
supplied paths cannot establish that the **original** outputs were untouched.
For example, an archive-only partial write and a deleted record leave an empty
journal; selecting a new, absent archive and manifest would pass the content
floor while the old archive still duplicates live entries. Therefore neither
ordinary invocation nor `--recover` automatically clears an empty journal.

Stop the original writer and its children, preserve recovery data, identify the
original destinations, and reconcile them as described below. Only after those
outputs are confirmed consistent may a **confirmed-empty** transaction directory
be removed with `rmdir` (not recursive deletion). Then preview the original command
with `--dry-run` before any fresh write. With no transaction directory at all,
`--recover` reports that there is no record; the ordinary command's `--dry-run`
checks only the destinations it is given, not unknown paths from an earlier run.

Recovery data lives in a reserved `.agent-vault-rollover-*` namespace:

- Beside the live log: `.agent-vault-rollover-<log-basename>/record`, a private,
  bounded, versioned data record (never sourced/evaluated as shell). It contains
  destination identities, before/after SHA-256 fingerprints, permissions, stage
  references, the chosen ID, and ready/committed state—not original-file backups.
- Beside each output: `.agent-vault-rollover-stage.<random>/<output-basename>`.
  Staging directories are private, even when an existing output has shared-read
  permissions. A successful rename consumes that output's staged file.

Bootstrap/update adds narrow ignore rules for these directories. **Ignored does
not mean disposable:** do not run cleanup such as `git clean -fdx`, move the
destinations, or remove recovery data while a transaction is pending. Successful
completion removes only recorded artifacts; unexpected extra files are retained
for inspection. Unreferenced stages left by termination before record publication
may be removed manually after confirming no compactor/recovery process is active.

If a record was deleted, or a partial rollover predates this recovery mechanism,
the ordinary invocation still checks for complete-entry overlap between live log
and archive and for inconsistent manifest/live-pointer metadata, before a fresh
write or no-op. It compares entry bodies, not just headings, and ignores only
trailing blank separators. Recognizable inconsistencies require manual
reconciliation; this fallback never reconstructs an ID or resumes automatically.
Healthy later rollovers with no overlap continue normally. Deliberately identical
entries are ambiguous and also require reconciliation. Removing the record *and*
editing away evidence is outside this detection guarantee.

For manual reconciliation, preserve copies of all three outputs and remaining
recovery data first. Establish whether the archived batch/manifest record was
already applied, retain each intended entry exactly once, reconcile the live
pointer with the manifest, and run the checker with explicit `--archive` and
`--manifest`. Do not clear a pending record merely to bypass a refusal. When
starting a different manifest, reconcile its relationship to the live pointer
explicitly. Selecting a new annual archive with the existing consistent manifest
is supported.

| Status | Meaning | Next action |
| --- | --- | --- |
| `0` | Successful rollover/recovery or healthy no-op; validated dry-run also uses `0` | Continue; a dry-run has not applied its plan. |
| `1` | Gate or self-validation refusal; outputs unchanged | Fix the input/gate. |
| `2` | Usage or preparation IO error before output replacement | Fix arguments/IO, then retry. |
| `3` | Pending/partial operation, failed recovery/cleanup, recognizable inconsistency, or manifest-adoption decision required | Follow the diagnostic: recover, reconcile, or verify manual history before opting into adoption. |

Handled HUP/INT/TERM retain `129`/`130`/`143` with recovery guidance when a record
is pending. An uncatchable kill cannot print a diagnostic; the next invocation
detects its surviving record or recognizable partial output state.

## `check-lessons-archive.sh`

When `lessons.md` is compacted, each archived lesson must be **classified** so it
is not silently lost (the #116 AC5 requirement). The canonical home for the
archive and its classification manifest is alongside the context-log archive:

- archive: `agent-vault/context/archive/lessons-archive.md`
- manifest: `agent-vault/context/archive/lessons-manifest.md`

One manifest record per archived lesson, keyed by the lesson's archived heading:

```md
## lesson: Avoid SC2178 local-var name collisions across functions
- classification: retained-as-quick-rule
- quick_rule: Watch SC2178/SC2128 from local-var name collisions

## lesson: Old workaround for the pre-2025 hook bug
- classification: covered-by-a-named-always-on-rule
- covered_by: Always use real date timestamps in durable memory
```

```bash
scripts/check-lessons-archive.sh <manifest>
scripts/check-lessons-archive.sh <manifest> --strict       # require sources + completeness
scripts/check-lessons-archive.sh <manifest> --rules <file> # add a live-rule source

# Outside the canonical layout, supply the archive and live rules explicitly:
scripts/check-lessons-archive.sh <manifest> --strict --archive <archive> --rules <rules>
```

The flat manifest format uses ATX headings (the `#` prefix) at the start of a
line. Only a `## lesson:` heading supplies a record's key; a body `- key:` field
cannot change it. Unrecognized fields are ignored. Other level-1 and level-2
ATX headings end the record, including bare `#` and `##` headings. Deeper
headings stay within the record, and the next `## lesson:` starts a new one.
Underlined (setext) section headings are not supported; use `#`/`##` sections.
Archive `###` headings and manifest field bullets may have zero to three
leading spaces. Four-space or tab-indented code does not supply headings or
fields.

Each recognized field (`classification`, `covered_by`, `quick_rule`) may appear
only once per record. Repeated fields produce a finding, with the first value
retained for diagnostics. A repeated classification cannot count toward the
classified total or satisfy strict completeness.

Both inputs ignore fenced content and HTML comment blocks before interpreting
headings or fields. Sample records and fields inside those blocks cannot classify
lessons, change a real record, or end it with a section heading. An HTML comment
block starts with `<!--` after zero to three leading spaces and ends with the
physical line containing the first `-->`, following the
[CommonMark HTML-block rules](https://spec.commonmark.org/0.31.2/#html-blocks).
The entire closing line is ignored:
`<!-- example --> ## lesson: sample` supplies no record, and a second comment
opener on that line does not start another block. Comments do not nest. Fence
markers inside a comment and comment markers inside a fence are inert.

Four-space or tab-indented comment markers do not open a block. Inline comments
are unsupported and remain literal text in headings and field values; they are
not guaranteed to produce a finding. Identical inline comments in a manifest key
and archive heading still match as raw text. Use fenced code blocks for reference
examples. A comment block cannot wrap example content containing `-->`: that
first terminator closes it even inside a nested-looking example. Setext section
boundaries remain a separate follow-up in [#155](https://github.com/ssheld/agent-vault/issues/155).
Fence delimiter rules follow
[CommonMark](https://spec.commonmark.org/0.31.2/#fenced-code-blocks):
at least three backticks or tildes, with zero to three leading spaces; a closer
uses the same marker, at least the opening length, and only spaces/tabs after
it. Opening info strings are allowed, but a backtick fence's info string cannot
contain backticks. CRLF and files without a final newline are accepted.
**The checker additionally requires closure** of fences and comment blocks,
although CommonMark allows these blocks to continue to EOF. An unterminated
fence or HTML comment produces a finding with its source path and opening line.
Only absence checks that search the incomplete input are skipped: manifest
lesson presence needs a complete archive, while
strict classification completeness needs a complete manifest. Known keys from
the other input still support checks even if that input ends in an open block.
Local record validation also continues.

The checker validates that every record declares exactly one of the three classes
(`retained-as-quick-rule`, `covered-by-a-named-always-on-rule`, `archival-only`),
that keys are unique, and that a `covered-by-a-named-always-on-rule` record names
a non-empty `covered_by` rule that still appears in a live always-on file. An
optional non-empty `quick_rule` on a `retained-as-quick-rule` record is
liveness-checked the same way, so a retained lesson whose one-liner was dropped
is caught. Concatenated class names are invalid. A missing or invalid class
does not count toward the classified total or satisfy strict completeness; in
strict mode an archived lesson with an invalid class reports both the authoring
error and the resulting classification gap. Advisory mode reports only the
classification error.

Rule liveness uses **case-sensitive, literal substring matching on eligible
physical lines**. Prose, headings, bullets, and ordinary inline code are eligible;
fenced examples and four-space/tab-indented lines are excluded. For a rule
expressed only as code or a deeply indented list item, add a descriptive prose
heading outside the excluded content and reference that heading. Matching never
joins lines, files, or fragments around a comment. Use distinctive rule text.

Rules sources share the fence markers, length checks, info-string restrictions,
and EOF diagnostics described above. They additionally recognize repeated
blockquote and list prefixes: `>`, `-`/`+`/`*`, and one-to-nine-digit ordered
markers ending in `.` or `)`. Each prefix permits up to three leading spaces;
quote markers permit one following space and list markers use one to four.
Tabs are expanded to four-column stops for delimiter recognition only. Closing
fences must retain each quote prefix and each list's content indentation, followed
by the normal zero-to-three-space closing fence. A sibling list item or container
end does not implicitly close a fence: an explicit closing fence is required.
Fence markers after ordinary prose are literal. At the start of a line or after
recognized quote/list prefixes, they can open a fence and require a matching
closer. For example, ````- Wrap examples in ``` fences```` is ordinary prose.
The text ````- ``` opens a fenced block```` starts a fence. Put descriptive prose
before delimiter mentions when explaining fence syntax.

HTML comments in rules sources can start anywhere outside excluded code, unlike
the manifest/archive block-only contract. Only the prefix before the first
`<!--` is eligible on its opening line. Content through the whole closing line
is excluded; additional comments in that discarded suffix still carry state onto
later lines. Fences inside comments and comments inside fences stay inert.
This is deliberately conservative filtering, not a full Markdown parser: even
when a list interrupts a paragraph and Markdown would display the comment-like
text, the checker excludes it through `-->`. Literal markers in inline code and
backslash-escaped HTML comment markers also participate; use entity spelling
when describing those markers. A complete comment never invalidates unrelated
matches elsewhere in the source.

When references need checking, every resolved source is scanned once, including
sources after an earlier match. Repeated identical resolved paths are deduplicated.
Reference strings are supplied as data, preserving quotes, tabs, backslashes,
and metacharacters. Temporary reference data is private and removed on exit.

| Rules-source state | Result |
| --- | --- |
| All sources complete; eligible occurrence found | Reference resolves. |
| All sources complete; no eligible occurrence | Per-reference “not found” finding, including comment-only, fence-only, and empty files. |
| No source resolves | Existing skipped-check finding with the expected path and remediation. |
| Any source has an unterminated fence/comment | Source/opening-line finding; discard that source's matches, even if another source matches. |
| No match in complete sources and at least one incomplete source | Per-reference skipped/unverifiable finding; no global absence claim. |
| Any required source has a read/parser execution failure | Exit 2 in all modes, even after another source matches; partial producer output is discarded. |

Independent manifest/archive checks continue when sources have findings.
Records requiring no reference check do not cause rules contents to be scanned;
explicitly named missing paths remain usage errors.

The canonical `<manifest-dir>/../../lessons.md` is always a source when present
and repeatable `--rules` **adds** more (e.g. `shared-rules.md`) rather than
replacing it. Empty `--rules` arguments are ignored; an existing empty file
counts as a source but cannot satisfy a non-empty reference. The archive
defaults to `lessons-archive.md` next to the manifest. Repeated `--archive` flags
select the **last value**, but every nonempty supplied path must exist, even
when a later value selects another archive. A final `--archive ""` uses the
canonical default, including the usual skipped-check finding if it is absent.

The checker **warns by default** (exit 0), including when implicit sources are
unavailable. It reports which archive or rule-liveness checks were skipped,
the expected paths, and how to supply the missing sources. No run with findings
produces `check passed`. This preserves useful manifest-only validation.
`--quiet` suppresses advisory warnings and success output.

**Strict mode** exits 1 on any finding, always reporting failures even with
`--quiet`. It requires an archive even for an empty manifest, since it must
establish that every archived lesson (a `###` heading outside fences) has a
manifest record with a valid classification.
A live rules source is required for a non-empty `covered_by` or `quick_rule`
reference on its matching classification. `archival-only` records and retained
records with an omitted or empty `quick_rule` need no rules source. Missing
required sources are findings, so other validation problems are still reported.
When the archive parses completely, both modes check that each distinct
manifest key names a lesson present in it. When the manifest parses completely,
strict mode additionally checks that each recognized archive heading is
classified. Usage errors, explicitly named missing files, and manifest/archive
parser execution or read failures exit 2
in either mode, even with `--quiet` or another valid source available. A failed
parser's empty or partial output cannot produce success.

## Compaction conventions

When a file is over budget:

1. **Relocate, never delete.** Move historical, closed, superseded, or
   low-frequency content into a load-on-demand file under `docs/` (or a dated
   archive) and leave a one-line pointer that names the destination, a grep
   anchor (e.g. issue numbers), and a "read when ..." trigger. Nothing leaves
   the repo; it only stops loading every turn.
2. **Keep the rule, archive the story.** When archiving a still-applicable rule
   or lesson, keep its one-line rule in the always-on file and move the full
   write-up to the archive.
3. **Preserve active invariants.** Do not archive current runtime behavior as if
   it were closed-issue history. When a narrative file cannot reach its budget
   without deleting a live invariant, keep it within reason and record the
   documented exception instead.
4. **Classify archived lessons.** Move archived `lessons.md` write-ups into
   `agent-vault/context/archive/lessons-archive.md` and record each one in
   `agent-vault/context/archive/lessons-manifest.md` as retained-as-quick-rule,
   covered-by-a-named-always-on-rule, or archival-only with low recurrence risk.
   Validate with `scripts/check-lessons-archive.sh` (see above).

## Installation

`new-project.sh` seeds the memory checkers (`check-memory-budget.sh`,
`check-context-log-rollover.sh`, `check-lessons-archive.sh`) and the
`compact-context-log.sh` compactor into a generated project's `scripts/`, and
`update-project.sh` keeps them in sync (they carry an `agent-vault-managed`
marker, like the worktree helpers). The scaffolded pre-commit hook runs two
**non-blocking** warnings against the **staged** content (never blocking a
commit):

- `scripts/check-memory-budget.sh` when memory files are staged -- surfaces any
  over-budget bucket/file (silence with `AGENT_VAULT_SKIP_MEMORY_BUDGET=1`);
- `scripts/check-context-log-rollover.sh` when `agent-vault/context-log.md` is
  staged -- surfaces a stale duplicate `## Current Snapshot`, leftover conflict
  markers, an empty handoff pointer, or an unclosed live fence (silence with
  `AGENT_VAULT_SKIP_ROLLOVER_CHECK=1`).

The budget warning materializes the staged index to measure the full `@`-chain;
the rollover warning reads only the single staged `context-log.md` blob via
`git show`.

In the agent-vault template repo itself the checkers live at
`scaffold/root/scripts/`; the commands above assume a generated project where
they have been seeded to `scripts/`.

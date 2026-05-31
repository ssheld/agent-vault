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
  `--strict` to exit `1` on a non-excepted overage (for example in a dedicated
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

## Budgets and per-repo configuration

Defaults: per-file budget **40000 bytes** and per `@`-chain total budget
**120000 bytes** (each chain budgeted separately). Sizes are measured in bytes
(`wc -c`) for portability; for the mostly-ASCII memory files this tracks
characters closely and is conservative for multibyte content. The per-file
default mirrors the threshold at which Claude Code warns that a memory file is
large enough to hurt performance, so a file over it is over a real signal. The
`@`-chain default is a softer "standing context is getting heavy" line
(~33K tokens) and is the more project-dependent of the two. The Codex AGENTS
total is informational (Codex enforces its own `project_doc_max_bytes` cap, and
a fresh scaffold already exceeds the 32 KiB default).

Both are starting points, not law. Budgets resolve at three levels, highest
priority first: **CLI flag** (`--file-budget` / `--chain-budget`) > **committed
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
# Override the bucket-3 (protocol-read) file set:
# protocol_read=agent-vault/context-log.md agent-vault/plan.md
# Pin the AGENTS.md set (the default discovers every AGENTS.md):
# agents=discover
# Point at a path<TAB>reason file of per-file documented overages (create it first;
# excepted files are subtracted from the @-chain total):
# exceptions=agent-vault/memory-budget.exceptions.tsv
```

## `check-context-log-rollover.sh`

`context-log.md` is append-only and grows fastest. The supported pattern is to
keep one live snapshot plus a recent-entries window and roll older entries into
a dated archive (`agent-vault/context/archive/context-log-YYYY.md`). This
checker validates the result of such a rollover. It is a **checker only** — it
never edits, moves, or rewrites the log.

```bash
scripts/check-context-log-rollover.sh <context-log-file>
scripts/check-context-log-rollover.sh <context-log-file> --archive <archive-file>
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

Archive checks (`--archive`): every archived `## Current Snapshot` must be
labeled superseded, so it cannot read as active.

The checker keys on the named section headings, so it tolerates mixed entry
heading styles (`### YYYY-MM-DD ...`, compact `## YYYY-MM-DD ...`, em-dash
variants) that a real matured log accumulates.

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
- archive_file: agent-vault/context/archive/context-log-2026.md
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

All fields are **required** (`kept` / `archived` must be non-negative integers);
the `*_archived` values are the entry heading text with the leading `#`s
removed. With `--manifest`, the checker parses the newest manifest record and
asserts:

- the record carries every field, so it matches the contract PR-B1 will emit
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
- every `anchor` appears in the archive (the moved content really landed —
  prefer distinctive anchor phrases, since the match is a literal substring);
- no orphaned top-level `Next Prompt` heading survives in the archive (it must
  stay nested under its archived entry, never read as an active instruction).

`--manifest` is opt-in and back-compatible: without it, only the structural and
`--archive` checks run. The archive is located from `--archive` when given, else
resolved next to the manifest by the record's `archive_file` basename. The
counts are validated as integers but **not** reconciled against live/archive
entry totals — a single archive accumulates many rollovers, so `archived` is a
per-rollover figure, not the archive's row count; count self-consistency is
left to the PR-B1 compactor that emits them.

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
4. **Classify archived lessons.** Each archived `lessons.md` entry should be
   retained as a quick-rule, covered by a named always-on rule, or
   archival-only with low recurrence risk.

## Installation

`new-project.sh` seeds both checkers into a generated project's `scripts/`, and
`update-project.sh` keeps them in sync (they carry an `agent-vault-managed`
marker, like the worktree helpers). The scaffolded pre-commit hook runs
`scripts/check-memory-budget.sh` as a **non-blocking** warning when memory files
are staged -- it surfaces any over-budget bucket/file but never blocks a commit
(silence it with `AGENT_VAULT_SKIP_MEMORY_BUDGET=1`).

In the agent-vault template repo itself the checkers live at
`scaffold/root/scripts/`; the commands above assume a generated project where
they have been seeded to `scripts/`.

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
| Claude/Gemini `@`-chain | `CLAUDE.md`/`GEMINI.md` plus everything they `@`-import, transitively | Auto-loaded into every session; the always-on cost |
| Codex `AGENTS` chain | all `AGENTS.md` files in the repo (discovered, including nested package/module ones) | Codex concatenates them along the working-directory ancestry up to its own `project_doc_max_bytes` cap (32 KiB by default), dropping the most specific files first when over |
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

- **Auto-discovery, not a hard-coded file set.** The `@`-chain is resolved by
  following `@`-imports from `CLAUDE.md`/`GEMINI.md`, and the Codex bucket
  discovers every `AGENTS.md` in the repo (tracked or present, respecting
  `.gitignore`), including nested ones, so the report reflects what an agent
  actually loads rather than assuming one project's layout.
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
  An excepted file still counts toward the `@`-chain total (it still loads into
  context), so an intentional chain-total overage is documented separately with
  the reserved path `@chain` (or `chain_exception` in the config).

## Budgets and per-repo configuration

Defaults: per-file budget **40000 characters** and `@`-chain total budget
**120000 characters**. The per-file default is not arbitrary -- it mirrors the
threshold at which Claude Code warns that a memory file is large enough to hurt
performance, so a file over it is over a real signal. The `@`-chain default is a
softer "standing context is getting heavy" line (~33K tokens) and is the more
project-dependent of the two.

Both are starting points, not law. Budgets resolve at three levels, highest
priority first: **CLI flag** (`--file-budget` / `--chain-budget`) > **committed
config file** > **built-in default**. A repo records its own budget once in
`agent-vault/memory-budget.config` (read automatically when present) so the
choice is durable and discoverable rather than re-typed per invocation:

```
# agent-vault/memory-budget.config -- all keys optional.
# Comments must be on their own line ('#' at the start). Inline trailing
# comments are NOT stripped: a key's value is the literal text after '=' (so
# values may safely contain '#').
file_budget=40000
chain_budget=120000
# protocol_read overrides the bucket-3 file set:
protocol_read=agent-vault/context-log.md agent-vault/plan.md
# agents: "discover" (default) finds every AGENTS.md, or give an explicit list:
agents=discover
# exceptions points at a path<TAB>reason file of per-file documented overages:
exceptions=agent-vault/memory-budget.exceptions.tsv
# chain_exception documents an intentional @-chain total overage:
chain_exception=intentional total overage during migration X
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

## Scope note

This capability ships the policy, the two checkers, their tests, and CI
registration. Wiring the budget check into a generated project's pre-commit
hook (which requires scaffolding the checker into projects) is intentionally a
follow-up so the detection/validation foundation can land focused first.

# Session Start Load Contract

This document records how generated `agent-vault` projects make startup
instructions and durable memory visible to common coding agents.

## Purpose

Generated projects use several agent entrypoints because Codex, Claude, Gemini,
Grok Build, and other tools do not load Markdown instructions the same way.
This contract keeps the scaffold explicit about which files are force-loaded by
the host and which files still depend on an agent following the session-start
protocol.

The current policy is intentionally conservative: use native import mechanisms
where they exist, keep project-owned memory in `agent-vault/`, and defer
generated composition until host-by-host behavior is measured more fully.

See `docs/session-start-load-measurements.md` for the current evidence record.

## Generated Entrypoints

| Agent surface | Generated entrypoint | Current load behavior |
| --- | --- | --- |
| Codex | root `AGENTS.md` | Codex loads `AGENTS.md` files along the current working-directory ancestry. A normal repo-root launch receives root `AGENTS.md`, not nested `agent-vault/AGENTS.md`. |
| Cursor CLI | root `AGENTS.md`; `.cursor/rules/agent-vault.mdc` | Cursor documents that the CLI reads project-root `AGENTS.md` and `CLAUDE.md` and applies them alongside `.cursor/rules` ([Cursor CLI rules](https://cursor.com/docs/cli/using)). The managed Cursor rule is an always-applied project rule shim so Cursor IDE and CLI surface the Agent Vault startup path through Cursor's native rules system ([Cursor project rules](https://cursor.com/docs/rules)). |
| Claude Code | root `CLAUDE.md` | Root wrapper imports `agent-vault/CLAUDE.md`; `agent-vault/CLAUDE.md` imports shared workflow files. |
| Gemini CLI | root `GEMINI.md` | Root wrapper imports `agent-vault/GEMINI.md`; `agent-vault/GEMINI.md` imports shared workflow files. |
| Grok Build | root `AGENTS.md` | Grok documents `AGENTS.md` family discovery from cwd to repo root and Claude-compatible instruction-file discovery, including `CLAUDE.md` ([xAI docs](https://docs.x.ai/build/features/skills-plugins-marketplaces)). For generated projects, root `AGENTS.md` is canonical for Grok. `CLAUDE.md` may also be discovered, but Claude-style `@` import expansion is unmeasured and not relied on. On overlap, `AGENTS.md` is authoritative. Local startup and protocol-read measurements are pending. |

## File Categories

| Category | Files | Contract |
| --- | --- | --- |
| Force-loaded or imported workflow | `agent-vault/CLAUDE.md`, `agent-vault/GEMINI.md`, their imported files | Use native imports where the host supports them. |
| Cursor native rule shim | `.cursor/rules/agent-vault.mdc` | Keep this small and always applied. It points Cursor back to root `AGENTS.md` and the Agent Vault files instead of duplicating the full workflow. |
| `AGENTS.md` root startup instructions | root `AGENTS.md` | Keep concise instructions that must be visible when Codex, Cursor, or Grok starts from the repo root. |
| Session-start protocol reads | `agent-vault/README.md`, `context-log.md`, `plan.md`, `coding-standards.md`, `project-context.md`, `project-commands.md`, `open-questions.md`, `decision-log.md`, `lessons.md` | Agents are instructed to read these at session start or when relevant. |
| Runtime project memory | `agent-vault/context-log.md`, `agent-vault/lessons.md`, daily notes, handoffs, decision records | Seed missing files, but do not overwrite project-owned content during normal updates. |
| Referenced archives | older daily notes, older handoffs, detailed decision records | Read when the current task or current index points to them. |

The session-start `context-log.md` read is bounded: agents read its Current
Snapshot and recent entries, and consult `agent-vault/context/archive/` only
when researching older or closed work. Keeping the always-on and protocol-read
tiers within budget is covered by [memory-budgets.md](memory-budgets.md).

## Current Measurement Summary

Issue [#105](https://github.com/ssheld/agent-vault/issues/105) is the evidence
track for broader session-start loading behavior.

As of 2026-05-03 for measured agents and 2026-05-28 for Cursor documentation:

- Codex `codex debug prompt-input` showed no sentinel content from the measured
  canonical memory files when launched from a generated repo root or from
  `agent-vault/`. This confirms only that those file contents were absent from
  startup prompt input; it does not measure later protocol reads.
- A controlled `codex exec --json --ephemeral` run from a generated repo root
  read all 9 measured canonical files by command execution during session
  start. This is protocol-read evidence, not startup-context evidence.
- Claude Code did not expose resolved `CLAUDE.md` import content through the
  tested debug/output paths. Claude startup/import measurement therefore needs
  indirect token-delta evidence plus behavioral recall and JSONL tool traces.
- A controlled Claude Code fresh-start run read 6 of the 9 measured files by
  JSONL-visible `Read` tool calls: `README.md`, `context-log.md`, `plan.md`,
  `coding-standards.md`, `open-questions.md`, and `decision-log.md`.
- A tool-disabled Claude Code recall probe answered the expected sentinels for
  `project-context.md`, `project-commands.md`, and `lessons.md`, and returned
  `UNKNOWN` for the other 6 measured files. This supports the current split:
  those 3 files are visible through Claude's import path, while the other 6 are
  protocol-read dependent.
- The outside-fixture control for Codex was sentinel-free, as expected.
- Cursor CLI load behavior is documented by Cursor but not yet covered by a
  local agent-vault measurement run.

Do not treat these findings as a reason to force-load additional files yet.
They narrow what is known and show that both Claude and Codex can follow the
current protocol in controlled fresh-start runs. Repeated task-type coverage and
post-`/clear` traces are still needed before #103 changes generated-project
behavior.

## Current `lessons.md` Decision

For issue #102, the accepted implementation path is Option A:

- `agent-vault/CLAUDE.md` imports `@./lessons.md`.
- `agent-vault/GEMINI.md` imports `@./lessons.md`.
- root `AGENTS.md` directly tells Codex to read `agent-vault/lessons.md` at session start.
- `agent-vault/lessons.md` remains project-owned runtime memory and is not
  mirrored or generated into root `AGENTS.md`.

This gives Claude and Gemini native import-based loading while reducing Codex
indirection from root `AGENTS.md` to `lessons.md`.

## Accepted Residual Risk

Codex remains protocol-dependent for `agent-vault/lessons.md`. The root
`AGENTS.md` instruction is visible at startup, but Codex must still execute the
instruction and read the separate file. This does not fully close the failure
mode where an agent skips session-start reads.

That risk is accepted for #102 because generated composition would add a new
sync surface across `scripts/new-project.sh`, `scripts/update-project.sh`,
managed root wrappers, backup behavior, dry-run behavior, and drift checks. The
larger decision belongs in #103 after #105 establishes which misses are real,
agent-specific, and material. Follow-up options include:

- generated root `AGENTS.md` composition from `agent-vault/lessons.md`
- a bounded startup lesson digest
- a full lesson mirror
- a skill or search workflow for long lesson archives
- a host-by-host load contract for other always-on files

## Update Script Implications

`scripts/new-project.sh` and `scripts/update-project.sh` currently treat
`agent-vault/lessons.md` as project-owned memory:

- `new-project.sh` copies the scaffold placeholder into new projects.
- `update-project.sh` seeds `agent-vault/lessons.md` only when it is missing.
- normal updates must not overwrite accumulated project lessons.

If generated composition is adopted later, the implementation needs a dedicated
render step rather than raw file copying:

1. Read the scaffold root `AGENTS.md` template.
2. Read the target project's current `agent-vault/lessons.md`.
3. Render a managed generated block or digest into the root `AGENTS.md` output.
4. Preserve existing backup, dry-run, symlink, and managed-marker behavior.
5. Add tests that prove the rendered root `AGENTS.md` stays in sync with the
   project-owned source.

Until that mechanism exists, do not duplicate `lessons.md` content manually into
root `AGENTS.md`.

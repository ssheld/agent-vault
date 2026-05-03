# Session Start Load Contract

This document records how generated `agent-vault` projects make startup
instructions and durable memory visible to common coding agents.

## Purpose

Generated projects use several agent entrypoints because Codex, Claude, Gemini,
and other tools do not load Markdown instructions the same way. This contract
keeps the scaffold explicit about which files are force-loaded by the host and
which files still depend on an agent following the session-start protocol.

The current policy is intentionally conservative: use native import mechanisms
where they exist, keep project-owned memory in `agent-vault/`, and defer
generated composition until the host-by-host behavior is specified more fully.

## Generated Entrypoints

| Agent surface | Generated entrypoint | Current load behavior |
| --- | --- | --- |
| Codex | root `AGENTS.md` | Codex loads `AGENTS.md` files along the current working-directory ancestry. A normal repo-root launch receives root `AGENTS.md`, not nested `agent-vault/AGENTS.md`. |
| Claude Code | root `CLAUDE.md` | Root wrapper imports `agent-vault/CLAUDE.md`; `agent-vault/CLAUDE.md` imports shared workflow files. |
| Gemini CLI | root `GEMINI.md` | Root wrapper imports `agent-vault/GEMINI.md`; `agent-vault/GEMINI.md` imports shared workflow files. |

## File Categories

| Category | Files | Contract |
| --- | --- | --- |
| Force-loaded or imported workflow | `agent-vault/CLAUDE.md`, `agent-vault/GEMINI.md`, their imported files | Use native imports where the host supports them. |
| Codex root startup instructions | root `AGENTS.md` | Keep concise instructions that must be visible when Codex starts from the repo root. |
| Session-start protocol reads | `agent-vault/README.md`, `context-log.md`, `plan.md`, `coding-standards.md`, `project-context.md`, `project-commands.md`, `open-questions.md`, `decision-log.md`, `lessons.md` | Agents are instructed to read these at session start or when relevant. |
| Runtime project memory | `agent-vault/context-log.md`, `agent-vault/lessons.md`, daily notes, handoffs, decision records | Seed missing files, but do not overwrite project-owned content during normal updates. |
| Referenced archives | older daily notes, older handoffs, detailed decision records | Read when the current task or current index points to them. |

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
larger decision belongs in #103, where the project can decide whether to add:

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

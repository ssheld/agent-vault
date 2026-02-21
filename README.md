# Agent Vault Template

Public template repository for generating a per-project `agent-vault/` folder.

## What This Is
This repo is a reusable scaffold for teams using AI coding agents (for example Codex, Claude, and Gemini CLI) and Obsidian.

It gives each code repository a standard `agent-vault/` directory with Markdown files for:
- shared context
- handoffs between sessions/agents
- open questions and decisions
- project plan and coding standards

## Problem It Solves
When multiple agents (or humans + agents) collaborate, context often gets lost between sessions. Typical failures are:
- repeated rediscovery of decisions
- unclear handoffs
- stale docs compared to implementation
- no consistent place for unresolved questions

This template standardizes where that context lives and how it is updated.

## Obsidian Fit
The generated vault is plain Markdown and works directly in Obsidian.
- Open your project repo as an Obsidian vault.
- Use `agent-vault/` as the project memory area.
- Keep code in normal source folders and context in `agent-vault/`.

## Workflow
1. Clone this template repo once:
   - `git clone https://github.com/ssheld/agent-vault.git`
2. For a new project repo, run:
   - `./scripts/new-project.sh <project-name> <repo-path>`
   - Example: `./scripts/new-project.sh auto-ai ~/workspaces/auto-ai`
   - Optional migration mode (for existing root policy files):
     - `./scripts/new-project.sh <project-name> <repo-path> --migrate-existing-root-md`
3. For an existing project repo, run:
   - `./scripts/update-project.sh <repo-path> --dry-run`
   - `./scripts/update-project.sh <repo-path>`
   - Example: `./scripts/update-project.sh ~/workspaces/harrier`
4. Commit generated or updated files in the target project repo.

This repo should stay template-only. Do not store project-specific session logs here.

## Template Source
- Runtime scaffold copied into projects lives at:
  - `scaffold/agent-vault/`
- Root wrapper templates copied into project repos live at:
  - `scaffold/root/`

If you want changes to propagate to future projects, edit files under `scaffold/agent-vault/` and `scaffold/root/`.

## Updating Existing Repos
`update-project.sh` updates these managed policy files:
- Always managed:
  - `<repo>/agent-vault/AGENTS.md`
  - `<repo>/agent-vault/CLAUDE.md`
  - `<repo>/agent-vault/GEMINI.md`
- Root wrappers (managed only when the root file has the `agent-vault-managed` marker):
  - `<repo>/AGENTS.md`
  - `<repo>/CLAUDE.md`
  - `<repo>/GEMINI.md`

If an existing root policy file does not have the managed marker, `update-project.sh` leaves it unchanged and reports a skip notice.

When a managed file changes, the script backs up the previous version under:
- `<repo>/agent-vault/context/updates/<timestamp>/...`

Both scripts also ensure root `.gitignore` includes Obsidian-safe ignore entries (added only when missing):
- `.obsidian/workspace.json`
- `.obsidian/app.json`
- `.obsidian/appearance.json`
- `.obsidian/workspace-mobile.json`
- `.obsidian/cache/`
- `.obsidian/backup/`
- `.obsidian/plugins/*/data.json`

## Migrating Existing Root Policy Files
When running `new-project.sh` with `--migrate-existing-root-md`:
- Existing root policy files are backed up under `agent-vault/context/updates/<timestamp>/`.
- Existing root content is appended into the corresponding `agent-vault/*.md` policy file under a `Migrated Legacy ...` section.
- Root wrappers from `scaffold/root/` are then written to:
  - `<repo>/AGENTS.md`
  - `<repo>/CLAUDE.md`
  - `<repo>/GEMINI.md`

Without this flag, `new-project.sh` leaves pre-existing root files unchanged and prints a notice.

## Generated Structure
`new-project.sh` creates `<repo-path>/agent-vault/` with:
- `AGENTS.md`, `CLAUDE.md`, and `GEMINI.md` (policy files)
- `README.md`
- `context-log.md`
- `plan.md`
- `coding-standards.md`
- `decision-log.md`
- `open-questions.md`
- `handoff.md`
- `context/`, `design-log/`, `decisions/`, `_assets/`
- `Templates/` (copied from template source)

It also creates project-root wrappers when missing:
- `<repo-path>/AGENTS.md` -> contains PR review guidance for Codex GitHub reviews and points workflow execution to `agent-vault/AGENTS.md`
- `<repo-path>/CLAUDE.md` -> points to `agent-vault/CLAUDE.md`
- `<repo-path>/GEMINI.md` -> imports `agent-vault/GEMINI.md`

If root files already exist, the script leaves them unchanged unless `--migrate-existing-root-md` is provided.

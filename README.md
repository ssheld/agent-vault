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
2. For each project repo, run:
   - `./scripts/new-project.sh <project-name> <repo-path>`
   - Example: `./scripts/new-project.sh auto-ai ~/workspaces/auto-ai`
3. Commit generated files in the target project repo.

This repo should stay template-only. Do not store project-specific session logs here.

## Template Source
- Runtime scaffold copied into projects lives at:
  - `scaffold/agent-vault/`

If you want changes to propagate to future projects, edit files under `scaffold/agent-vault/`.

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
- `<repo-path>/AGENTS.md` -> points to `agent-vault/AGENTS.md`
- `<repo-path>/CLAUDE.md` -> points to `agent-vault/CLAUDE.md`
- `<repo-path>/GEMINI.md` -> imports `agent-vault/GEMINI.md`

If root files already exist, the script leaves them unchanged and prints a notice.

# Agent Vault Template

Public template repository for generating per-project `agent-vault/` folders.

## Workflow
1. Clone this repo once:
   - `~/workspaces/agent-vault`
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
- `AGENTS.md` and `CLAUDE.md` (full policy files)
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

If root files already exist, the script leaves them unchanged and prints a notice.

# CLAUDE.md

## Shared Context
- Canonical handoff memory is per-project:
  - `01_Projects/<project-slug>/context-log.md`
- Before starting: read the newest entry.
- Before finishing: append a new top entry using the same schema.
- Also read:
  - `01_Projects/<project-slug>/plan.md`
  - `01_Projects/<project-slug>/coding-standards.md`
  - recent entries in `01_Projects/<project-slug>/design-log/`
  - recent entries in `01_Projects/<project-slug>/context/handoffs/`

## Project Discovery
- If project notes are missing, initialize with:
  - `./scripts/new-project.sh <project-name> <repo-path>`

## Required Entry Fields
- `Goal`
- `State`
- `Decisions`
- `Open Questions`
- `Next Prompt`
- `References`

## Session Logging
- Add a short session note in `design-log/` for each meaningful work unit.
- Add a handoff note in `context/handoffs/` when switching sessions/agents.

# Vault Home

## Quick Actions
- Create project notes: `./scripts/new-project.sh <project-name> <repo-path>`
- Open active projects in `01_Projects/`
- Capture quick notes in `00_Inbox/`

## Core Areas
- [[00_Inbox/README]]
- [[01_Projects/README]]
- [[02_Knowledge/README]]
- [[03_Decisions/README]]
- [[04_Operations/README]]
- [[99_Archive/README]]

## Multi-Agent Standard
- Treat `01_Projects/<project-slug>/context-log.md` as canonical shared memory.
- Add session summaries under `01_Projects/<project-slug>/design-log/`.
- Add agent transfer notes under `01_Projects/<project-slug>/context/handoffs/`.
- Require every context-log handoff to include Goal, State, Decisions, Open Questions, Next Prompt, References.

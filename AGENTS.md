# AGENTS.md

## Shared Context
- Canonical handoff memory is per-project:
  - `01_Projects/<project-slug>/context-log.md`
- At the start of work: read the latest entry in that file.
- At the end of work: append a new top entry using the project template.
- For project execution context, also read:
  - `01_Projects/<project-slug>/plan.md`
  - `01_Projects/<project-slug>/coding-standards.md`
  - recent files in `01_Projects/<project-slug>/design-log/`
  - recent files in `01_Projects/<project-slug>/context/handoffs/`

## Project Discovery
- If a project slug is not provided, infer it from the current task or ask.
- If project notes do not exist, create them with:
  - `./scripts/new-project.sh <project-name> <repo-path>`

## Handoff Standard
- Keep entries concise, factual, and implementation-focused.
- For each meaningful session:
  - add a `design-log` entry
  - add a handoff note when switching agents/sessions
- Always include:
  - `Goal`
  - `State`
  - `Decisions`
  - `Open Questions`
  - `Next Prompt`
  - `References`

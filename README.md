# Obsidian Multi-Agent Vault Template

Reusable baseline vault for software projects that use multiple coding agents
(for example Codex + Claude Code) with consistent handoffs.

## Design Goals
- Keep project context portable across tools.
- Support both high-level memory and session-level handoffs.
- Keep defaults lightweight and Git-friendly.

## Vault Structure
- `00_Inbox/` quick capture
- `01_Projects/` one folder per software project
- `02_Knowledge/` durable technical notes
- `03_Decisions/` cross-project architecture/product decisions
- `04_Operations/` runbooks and process docs
- `90_Templates/` reusable note templates
- `99_Archive/` inactive/closed material

## Per-Project Standard
Each project under `01_Projects/<slug>/` should include:
- `context-log.md` canonical shared memory across agents
- `design-log/` chronological session summaries
- `context/handoffs/` handoff notes between sessions/agents
- `context/scratchpad.md` temporary working memory
- `plan.md` roadmap, phases, and milestones
- `coding-standards.md` project-specific implementation standards
- `decisions/` one note per significant decision

## Quick Start
1. Open this folder as an Obsidian vault.
2. Create a project area:
   - `./scripts/new-project.sh <project-name> <repo-path>`
3. Ask each agent to read:
   - `01_Projects/<slug>/README.md`
   - `01_Projects/<slug>/context-log.md`
   - `01_Projects/<slug>/plan.md`
   - `01_Projects/<slug>/coding-standards.md`
4. For every meaningful session:
   - Update `context-log.md`
   - Add an entry in `design-log/`
   - Add a note in `context/handoffs/` when switching agents

## Obsidian and Claude Settings
- `.obsidian/` in this template is intentionally minimal.
- Personal Obsidian settings and plugin-heavy setups are optional and should be layered on top.
- `.claude/` skills or memory files are optional and not required for baseline use.

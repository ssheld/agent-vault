---
type: context-log
project: __PROJECT_SLUG__
last_updated: __DATE__
---

# Context Log

## Usage Rules
- Newest entry at top.
- Entry headings must start with `YYYY-MM-DD HH:MM local - <agent> - <topic>`.
- Keep entries short and concrete.
- Reference files and PRs instead of pasting long diffs.
- Prefer repo-relative paths where possible.
- Pair each major update with a design-log entry.
- Add a handoff note when switching agents or ending a session.
- Reference the active handoff note or decision record when one changes current work.
- Review-only / external-feedback exception: if the session only posted external review feedback that did not converge into project state, the `Session End - Required` exception in `agent-vault/shared-rules.md` applies — record a one-line thread pointer only if future agents need it; otherwise skip the entry.

## Current Snapshot
- Project: __PROJECT_NAME__
- Primary goal: Deliver milestones with clear scope, verification, and reliable handoffs.
- Current status: Baseline project memory scaffold is initialized; project-specific priorities should be refined next.
- Active branch: `__ACTIVE_BRANCH__`
- Last updated: __DATE__

## Entries

### __DATETIME__ local - bootstrap - initial project setup
#### Goal
Create a standardized project note set for multi-agent development.

#### State
- Created project workspace in `agent-vault/`.
- Added project home, context log, plan, coding standards, and open questions.
- Added baseline project context and command reference files for agent session start.
- Added session tracking via `agent-vault/daily/`, `agent-vault/design-log/`, `agent-vault/context/handoffs/`, and `agent-vault/context/scratchpad.md`.

#### Decisions
- Use this context log as the canonical cross-agent memory for this project.
- Keep session artifacts separate from canonical memory for easier scanning.

#### Open Questions
- None yet.

#### Next Prompt
"Read `agent-vault/context-log.md` and continue the current implementation task."

#### References
- `agent-vault/README.md`
- `agent-vault/context-log.md`
- `agent-vault/plan.md`
- `agent-vault/coding-standards.md`
- `agent-vault/project-context.md`
- `agent-vault/project-commands.md`
- `agent-vault/decision-log.md`

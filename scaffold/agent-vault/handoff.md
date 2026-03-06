# Agent Handoff

Use this when switching between agents or pausing with meaningful unfinished work.

## Required Artifacts
- Update `agent-vault/context-log.md` with Goal, State, Decisions, Open Questions, Next Prompt, and References.
- Create a handoff note in `agent-vault/context/handoffs/` using the Handoff Note template.
- Add a design-log entry in `agent-vault/design-log/`.
- If the session was substantive, update today's note in `agent-vault/daily/`.
- If a durable decision was made, update `agent-vault/decision-log.md` and `agent-vault/decisions/`.

## Suggested Next Prompt
```
You are continuing work on __PROJECT_NAME__.
Start with the core files:
- agent-vault/README.md
- agent-vault/context-log.md
- agent-vault/plan.md
- agent-vault/coding-standards.md

Then:
- skim `agent-vault/open-questions.md` for blockers relevant to this task
- skim `agent-vault/decision-log.md` for active decisions relevant to this task
- read the handoff note or decision record referenced by the latest `agent-vault/context-log.md` entry
- read today's note in `agent-vault/daily/` if it exists
- read recent `agent-vault/design-log/` notes if more implementation context is needed

Task:
<what needs to be done now>

Constraints:
<technical, product, and timeline constraints>

Before finishing:
- Update context-log with Goal, State, Decisions, Open Questions, Next Prompt, References.
- Update today's daily note if this is substantive work.
- Add a design-log entry in agent-vault/design-log/.
- If you made a durable decision, update decision-log and `agent-vault/decisions/`.
- If handing off again, add a note in agent-vault/context/handoffs/ with a Suggested Next Prompt.
```

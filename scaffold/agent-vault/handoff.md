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
Start with:
- agent-vault/README.md
- agent-vault/context-log.md
- agent-vault/plan.md
- agent-vault/coding-standards.md
- agent-vault/open-questions.md
- agent-vault/decision-log.md

If `agent-vault/context-log.md` references a handoff note or decision record, read those next.
Read today's note in `agent-vault/daily/` if it exists.

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

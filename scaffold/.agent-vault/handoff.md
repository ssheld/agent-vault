# Agent Handoff

Use this when switching between agents.

## Prompt
```
You are continuing work on __PROJECT_NAME__.
Read these files first:
- .agent-vault/README.md
- .agent-vault/context-log.md
- .agent-vault/plan.md
- .agent-vault/coding-standards.md
- .agent-vault/open-questions.md

Task:
<what needs to be done now>

Constraints:
<technical, product, and timeline constraints>

Before finishing:
- Update context-log with Goal, State, Decisions, Open Questions, Next Prompt, References.
- Add a design-log entry in .agent-vault/design-log/.
- If handing off, add a note in .agent-vault/context/handoffs/.
```

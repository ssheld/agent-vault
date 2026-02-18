---
type: handoff-prompt
project:
---

# Agent Handoff Prompt

Use this prompt when switching between agents:

```
You are continuing work on <project>.
Read these files first:
- agent-vault/README.md
- agent-vault/context-log.md
- agent-vault/plan.md
- agent-vault/coding-standards.md
- agent-vault/open-questions.md

Task:
<what needs to be done now>

Constraints:
<technical, product, and timeline constraints>

Before finishing:
- Update context-log with Goal, State, Decisions, Open Questions, Next Prompt, References.
- Add a design-log entry under agent-vault/design-log/.
- If handing off, add a handoff note under agent-vault/context/handoffs/.
```

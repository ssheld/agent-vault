---
type: handoff-prompt
project:
---

# Agent Handoff Prompt

Use this prompt when switching between agents:

```
You are continuing work on <project>.
Read these files first:
- 01_Projects/<project>/README.md
- 01_Projects/<project>/context-log.md
- 01_Projects/<project>/plan.md
- 01_Projects/<project>/coding-standards.md
- 01_Projects/<project>/open-questions.md

Task:
<what needs to be done now>

Constraints:
<technical, product, and timeline constraints>

Before finishing:
- Update context-log with Goal, State, Decisions, Open Questions, Next Prompt, References.
- Add a design-log entry under 01_Projects/<project>/design-log/.
- If handing off, add a handoff note under 01_Projects/<project>/context/handoffs/.
```

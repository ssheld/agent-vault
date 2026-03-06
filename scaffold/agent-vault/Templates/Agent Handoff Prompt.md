---
type: handoff-prompt
project:
source_handoff:
---

# Agent Handoff Prompt

Use this only when a human explicitly wants a copy-paste prompt for another agent.

The canonical handoff remains the latest `context-log.md` entry plus the handoff note in `agent-vault/context/handoffs/`.

## Prompt

```text
You are continuing work on <project>.
Start with:
- agent-vault/README.md
- agent-vault/context-log.md
- agent-vault/plan.md
- agent-vault/coding-standards.md
- agent-vault/open-questions.md
- agent-vault/decision-log.md

Then read:
- agent-vault/context/handoffs/<latest-note>.md
- agent-vault/daily/<today>.md (if it exists)

Task:
<what needs to be done now>

Constraints:
<technical, product, and timeline constraints>

Before finishing:
- Update context-log with Goal, State, Decisions, Open Questions, Next Prompt, References.
- Update today's daily note if this is substantive work.
- Add a design-log entry under agent-vault/design-log/.
- If you made a durable decision, update decision-log and `agent-vault/decisions/`.
- If you are handing off again, add a handoff note with Suggested Next Prompt.
```

---
type: handoff-prompt
project:
source_handoff:
---

# Agent Handoff Prompt

Use this only when a human explicitly wants a copy-paste prompt for another agent.

The canonical handoff remains the latest `context-log.md` entry plus the handoff note in `agent-vault/context/handoffs/`.

## How To Use
- Start from the canonical prompt in `agent-vault/handoff.md`.
- Tailor it using `source_handoff`, the current task, the active constraints, and any additional files the next agent should read.
- Keep the handoff note and latest `context-log.md` entry as the source of truth.

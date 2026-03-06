# GEMINI.md

## Purpose
This repository holds reusable scaffold files for `agent-vault/`.

## Rules
- Edit `scaffold/agent-vault/` for defaults used in future project initialization.
- Do not store project-specific context in this repository.

## Target Project Usage
In generated project vaults:
- `agent-vault/Templates/` is template source only. Instantiated notes belong in canonical runtime files under `agent-vault/`.
- Start substantive work by reading `agent-vault/README.md`, `agent-vault/context-log.md`, `agent-vault/plan.md`, and `agent-vault/coding-standards.md`.
- Skim `agent-vault/open-questions.md` for blockers and `agent-vault/decision-log.md` for active decisions relevant to the task.
- Use `agent-vault/context-log.md` as canonical cross-session memory.
- Use `agent-vault/daily/`, `agent-vault/design-log/`, `agent-vault/context/handoffs/`, and `agent-vault/decisions/` for runtime artifacts when the workflow calls for them.

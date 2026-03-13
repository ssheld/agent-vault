# Agent-Vault Hooks

Tracked git hook assets for generated projects live here.

## Install

Enable the tracked hooks for the current clone:

```bash
git config core.hooksPath agent-vault/_assets/hooks
```

## Current Hook

- `pre-commit`
  - Blocks commits with substantive staged changes unless the staged diff also includes:
    - `agent-vault/context-log.md`
    - one note under `agent-vault/daily/`
    - one note under `agent-vault/design-log/`
  - This is a baseline gate only. Conditional artifacts such as `open-questions.md`, decision records, handoff notes, and `lessons.md` still depend on the actual session outcome.

## Intentional Bypass

For a truly trivial one-off change that should not update project memory, bypass explicitly:

```bash
AGENT_VAULT_SKIP_METADATA_GATE=1 git commit ...
```

Use that escape hatch sparingly and explain the skip in the task summary or commit context.

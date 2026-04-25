# Agent-Vault Hooks

Tracked git hook assets for generated projects live here.

## Install

Enable the tracked hooks for the current clone:

```bash
git config core.hooksPath agent-vault/_assets/hooks
```

## Current Hooks

- `pre-commit`
  - Blocks commits with substantive staged changes unless the staged diff also includes:
    - `agent-vault/context-log.md`
    - one note under `agent-vault/daily/`
    - one note under `agent-vault/design-log/`
  - Rejects staged `agent-vault/` path changes when the generated `agent-vault/`
    directory or shared runtime metadata classifier is missing.
  - Validates staged `agent-vault/context-log.md` content:
    - entry headings must use `YYYY-MM-DD HH:MM local - <agent> - <topic>`
    - entries must remain newest-first
    - frontmatter and Current Snapshot `Last updated` must match the top entry date
  - This is a baseline gate only. Conditional artifacts such as `open-questions.md`, decision records, handoff notes, and `lessons.md` still depend on the actual session outcome.
- `pre-push`
  - Inert by default.
  - When explicitly enabled with local repo config, blocks direct pushes to `main` unless every pushed path is runtime `agent-vault` metadata.
  - Rejects direct deletion of `main`, first-time creation of `main`, and non-fast-forward pushes.
  - Rejects `main` pushes when the generated `agent-vault/` directory or shared
    runtime metadata classifier is missing.
  - Uses the same runtime metadata classifier as `pre-commit`.

## Optional Direct Push to Main for Runtime Metadata

Direct push to `main` is allowed for recording history, not changing behavior. Enable the narrow post-merge metadata shortcut only in repos that intentionally want it:

```bash
git config --local agent-vault.allowMetadataOnlyMainPush true
```

The shortcut allows only runtime metadata files:

- `agent-vault/context-log.md`
- `agent-vault/open-questions.md`
- `agent-vault/decision-log.md`
- `agent-vault/lessons.md`
- notes under `agent-vault/daily/`, excluding `README.md`
- notes under `agent-vault/design-log/`, excluding `README.md` and `bootstrap.md`
- notes under `agent-vault/context/handoffs/`, excluding `README.md`
- decision records under `agent-vault/decisions/`, excluding `README.md`

Everything else still requires the normal PR flow, including source code, config, scripts, root docs, `agent-vault/README.md`, `plan.md`, `coding-standards.md`, `project-context.md`, `project-commands.md`, `handoff.md`, policy files, templates, and hook assets.

Rollback:

```bash
git config --local --unset agent-vault.allowMetadataOnlyMainPush
```

## Intentional Bypass

For a truly trivial one-off change that should not update project memory, bypass explicitly:

```bash
AGENT_VAULT_SKIP_METADATA_GATE=1 git commit ...
```

Use that escape hatch sparingly and explain the skip in the task summary or commit context.

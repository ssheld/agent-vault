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
  - Emits a **non-blocking** memory-budget warning when the staged commit touches
    memory files (`agent-vault/`, `CLAUDE.md`, `GEMINI.md`, or any `AGENTS.md`)
    and `scripts/check-memory-budget.sh` is installed. It measures the **staged**
    content (the index, not the working tree), surfaces over-budget files/chains,
    incomplete import analysis, external scope exclusions, and checker errors,
    and always exits `0` — the budget is advisory and never
    blocks a commit. It runs even when `AGENT_VAULT_SKIP_METADATA_GATE=1` is set;
    silence it independently with `AGENT_VAULT_SKIP_MEMORY_BUDGET=1`.
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

The same explicit-bypass expectation applies when a review-only session (external
feedback only, nothing converged into project state) needs to commit a genuinely
trivial change: use the bypass and state the review-only skip in the task summary,
per the `Session End - Required` exception in `agent-vault/shared-rules.md`.

The non-blocking memory-budget warning is independent of the metadata gate.
The checker uses the staged `agent-vault/memory-budget.config`, including when
only that config is staged. The designated context log's protocol-read allowance
defaults to 60,000 bytes; imported logs and other memory files still use the
40,000-byte general default. `context_log_budget`, `context_log_target`, and
`context_log_path` are accepted together. The 30,000-byte target is enforced only
by explicit `compact-context-log.sh --to-budget`; `--keep N` stays count-based.
Upgrade the checker
before adding these keys; an older checker rejects unknown keys. No hook compacts
files or rewrites configuration. An explicit `context_log_path` outside the
effective `protocol_read` set is a configuration error; the hook prints that
diagnostic without blocking the commit. Excluding only the built-in default
remains informational. Informational migration/default-coverage notes are
available in direct reports and do not trigger additional hook warnings.

The managed checker now fails `--strict` for incomplete **in-scope** import
analysis as well as overages; `update-project.sh` refreshes that behavior in
place. This can affect custom downstream CI/scripts, but the shipped hook
continues to catch checker failures and never blocks a commit for its budget.

The checker measures unique source bytes from the selected repo-local root
chains, not every client instruction or exact expanded prompt. Known external
imports are advisory exclusions, not incomplete analysis. Exclusions remain
visible even when the checker exits zero. An absolute import or symlink into
the worktree may be outside the hook's temporary index checkout, so its staged
total can be lower than a direct worktree check. The hook never retargets those
paths or reads unstaged content as a fallback; the exclusion explains the gap.
An unchanged external target is reported again on later memory-touching commits.
This deliberately keeps the scope gap visible; there is no separate external-only
acknowledgement or suppression mechanism in the current contract.

Silence it on its own (it never blocks a commit either way):

```bash
AGENT_VAULT_SKIP_MEMORY_BUDGET=1 git commit ...
```

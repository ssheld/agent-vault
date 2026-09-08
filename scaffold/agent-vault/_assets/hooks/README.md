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
    and `scripts/check-memory-budget.sh` is executable. It measures the **staged**
    content (the index, not the working tree), surfaces over-budget files/chains,
    incomplete import analysis, external scope exclusions, and checker errors,
    and never blocks a commit. It runs even when `AGENT_VAULT_SKIP_METADATA_GATE=1` is set;
    silence it independently with `AGENT_VAULT_SKIP_MEMORY_BUDGET=1`.
  - Emits a **non-blocking** structural rollover warning when
    `agent-vault/context-log.md` is staged and
    `scripts/check-context-log-rollover.sh` is executable. It checks that single
    **staged blob** for duplicate snapshots, conflict markers, empty handoff
    pointers, and unclosed fences. A staged deletion has no blob to check and
    emits no rollover warning. Silence it with `AGENT_VAULT_SKIP_ROLLOVER_CHECK=1`.
- `pre-push`
  - Inert by default.
  - When explicitly enabled with local repo config, blocks direct pushes to `main` unless every pushed path is runtime `agent-vault` metadata.
  - Rejects direct deletion of `main`, first-time creation of `main`, and non-fast-forward pushes.
  - Rejects pushes whose ancestry or complete per-commit file inspection cannot
    be verified, including unavailable remote commits and Git inspection errors.
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

The gate distinguishes a verified non-fast-forward update from an operational
Git failure. When the advertised remote `main` commit is unavailable locally,
fetch `main` from the push destination and retry. The diagnostic offers a fetch
command only for a recognized configured remote name; destination URLs are never
printed because they can contain credentials. The hook does not fetch for you.
Other ancestry, commit-enumeration, parent-lookup, or file-inspection errors also
stop the push and report the Git exit status. If fetching does not resolve the
error, inspect local Git errors and repository objects before retrying. A PR
does not repair an incomplete local inspection. Every pushed commit is checked,
including intermediate changes that were later reverted.

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

Both staged warnings run independently of the metadata gate, including when
`AGENT_VAULT_SKIP_METADATA_GATE=1` is set. Silencing either warning leaves the
other enabled and does not bypass metadata enforcement. Neither warning
automatically compacts files or changes the index.

With partial staging, a working-tree check can disagree with the warning.
Inspect the index with `git diff --cached -- agent-vault/context-log.md` or
`git show :agent-vault/context-log.md`; stage any intended fix before retrying.
The budget warning measures the staged index, while the structural rollover
warning checks only the staged context-log blob.

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

Silence the budget warning on its own:

```bash
AGENT_VAULT_SKIP_MEMORY_BUDGET=1 git commit ...
```

Silence the structural rollover warning on its own:

```bash
AGENT_VAULT_SKIP_ROLLOVER_CHECK=1 git commit ...
```

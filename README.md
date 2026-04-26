# Agent Vault Template

Public template repository for generating a per-project `agent-vault/` folder.

## License
MIT. See `LICENSE`.

## What This Is
This repo is a reusable scaffold for teams using AI coding agents (for example Codex, Claude, and Gemini CLI) and Obsidian.

It gives each code repository a standard `agent-vault/` directory with Markdown files for:
- shared context
- handoffs between sessions/agents
- open questions and decisions
- project plan and coding standards

Generated vaults are intended to preserve human control over material trade-offs, not just record decisions after an agent already chose a path.

## Problem It Solves
When multiple agents (or humans + agents) collaborate, context often gets lost between sessions. Typical failures are:
- repeated rediscovery of decisions
- unclear handoffs
- stale docs compared to implementation
- no consistent place for unresolved questions
- agents silently making architecture or workflow trade-offs that should stay owner-controlled

This template standardizes where that context lives and how it is updated.

## Obsidian Fit
The generated vault is plain Markdown and works directly in Obsidian.
- Open your project repo as an Obsidian vault.
- Use `agent-vault/` as the project memory area.
- Keep code in normal source folders and context in `agent-vault/`.

## Workflow
1. Clone this template repo once:
   - `git clone https://github.com/ssheld/agent-vault.git`
2. For a new project repo, run:
   - `./scripts/new-project.sh <project-name> <repo-path>`
   - Example: `./scripts/new-project.sh auto-ai ~/workspaces/auto-ai`
   - Optional migration mode (for existing root policy files):
     - `./scripts/new-project.sh <project-name> <repo-path> --migrate-existing-root-md`
3. For an existing project repo, run:
   - `./scripts/update-project.sh <repo-path> --dry-run`
   - `./scripts/update-project.sh <repo-path>`
   - Optional template refresh:
     - `./scripts/update-project.sh <repo-path> --dry-run --sync-templates`
     - `./scripts/update-project.sh <repo-path> --sync-templates`
   - Optional coding-standards refresh:
     - `./scripts/update-project.sh <repo-path> --dry-run --sync-coding-standards`
     - `./scripts/update-project.sh <repo-path> --sync-coding-standards`
   - Example: `./scripts/update-project.sh ~/workspaces/harrier`
   - To migrate unmanaged root wrappers to managed versions:
     - `./scripts/update-project.sh <repo-path> --migrate-root`
   - To migrate unmanaged root worktree helper scripts to managed versions:
     - `./scripts/update-project.sh <repo-path> --migrate-root-scripts`
4. `new-project.sh` and `update-project.sh` automatically enable the tracked metadata hook in the current clone when `core.hooksPath` is not already customized.
5. For additional clones, or when you want to opt into the tracked hook manually:
   - `git -C <repo-path> config core.hooksPath agent-vault/_assets/hooks`
6. Commit generated or updated files in the target project repo.

Generated workflows also expect:
- accepted decision records to preserve owner approval provenance in the file before they are used as an automatic Human Decision Gate bypass
- same-session daily/context/design-log notes to avoid leaving immediate publication mechanics (`git commit`, `git push`, PR creation) in future-tense carry-forward text unless those actions will truly remain unfinished

This repo should stay template-only. Do not store project-specific session logs here.

## Template Source
- Runtime scaffold copied into projects lives at:
  - `scaffold/agent-vault/`
- Project-root scaffold copied into project repos lives at:
  - `scaffold/root/`
  - including optional helper scripts under `scaffold/root/scripts/` and
    runbooks under `scaffold/root/docs/runbooks/`

If you want changes to propagate to future projects, edit files under `scaffold/agent-vault/` and `scaffold/root/`.

## Policy Mirror Drift Checks
This repository intentionally keeps three mirrored policy blocks for compatibility:
- `AGENTS.md` mirrors the review section from `scaffold/agent-vault/review-policy.md` (with a repo-local path alias normalization in the check).
- `scaffold/root/AGENTS.md` mirrors the review section from `scaffold/agent-vault/review-policy.md`.
- `scaffold/agent-vault/AGENTS.md` mirrors shared workflow rules from `scaffold/agent-vault/shared-rules.md`.
- Each check compares its mirrored block from the start heading through EOF, covering all mirrored top-level sections.
- Root `CLAUDE.md` and `GEMINI.md` in this template repo are lightweight repo-local helper docs and are not drift-checked.
- `scaffold/root/CLAUDE.md` and `scaffold/root/GEMINI.md` remain thin wrappers over `agent-vault/*.md` plus `review-policy.md`; no additional drift enforcement is added for them.

To prevent accidental drift, run:
- `bash scripts/check-policy-mirrors.sh`

CI also enforces this via `.github/workflows/policy-mirror-check.yml` on pull requests and pushes to `main`.

## Style Checks
Run shell style/static checks before pull requests that touch scripts, generated
root helper scripts, or tracked hook assets:
- `bash scripts/check-style.sh`

The command checks the tracked shell surface with:
- `bash -n` syntax validation
- `shellcheck --severity=warning -x`
- `shfmt -i 2 -ci -d`

For local formatting, run:
- `bash scripts/check-style.sh --fix`

Local runs require ShellCheck and shfmt. On macOS, install them with:
- `brew install shellcheck shfmt`

CI installs pinned release binaries instead of relying on runner image versions:
- ShellCheck `v0.11.0`
- shfmt `v3.13.1`

CI runs the same command via `.github/workflows/style-check.yml`.

## Scaffold Regression Checks
Run the scaffold regression scripts locally when changing bootstrap, sync, or tracked hook behavior:
- `bash scripts/test-gitignore-management.sh`
- `bash scripts/test-coding-standards-sync.sh`
- `bash scripts/test-decision-template-sync.sh`
- `bash scripts/test-session-metadata-hook.sh`
- `bash scripts/test-main-push-gate.sh`
- `bash scripts/test-new-worktree.sh`
- `bash scripts/test-remove-worktree.sh`
- `bash scripts/test-worktree-helper-sync.sh`

CI also runs these checks via `.github/workflows/scaffold-regression-checks.yml`.

## Updating Existing Repos
`update-project.sh` updates these managed scaffold files:
- Always managed:
  - `<repo>/agent-vault/shared-rules.md`
  - `<repo>/agent-vault/review-policy.md`
  - `<repo>/agent-vault/AGENTS.md`
  - `<repo>/agent-vault/CLAUDE.md`
  - `<repo>/agent-vault/GEMINI.md`
  - `<repo>/agent-vault/handoff.md`
  - `<repo>/agent-vault/_assets/hooks/README.md`
  - `<repo>/agent-vault/_assets/hooks/lib/runtime-note.sh`
  - `<repo>/agent-vault/_assets/hooks/pre-commit`
  - `<repo>/agent-vault/_assets/hooks/pre-push`
  - `<repo>/agent-vault/design-log/README.md`
  - `<repo>/agent-vault/context/handoffs/README.md`
  - `<repo>/agent-vault/decisions/README.md`
  - `<repo>/agent-vault/daily/README.md`
  - `<repo>/agent-vault/Templates/Decision Record.md`
- Root wrappers (managed only when the root file has the `agent-vault-managed` marker):
  - `<repo>/AGENTS.md`
  - `<repo>/CLAUDE.md`
  - `<repo>/GEMINI.md`
- Root helper scripts (managed only when the script has the `agent-vault-managed`
  marker, or when created by `update-project.sh` because it was missing):
  - `<repo>/scripts/new-worktree.sh`
  - `<repo>/scripts/remove-worktree.sh`
- Seeded if missing:
  - `<repo>/.github/pull_request_template.md`
  - `<repo>/docs/design.md`
  - `<repo>/docs/runbooks/parallel-agent-worktrees.md`
  - `<repo>/agent-vault/project-context.md`
  - `<repo>/agent-vault/project-commands.md`
  - `<repo>/agent-vault/lessons.md`

`<repo>/agent-vault/coding-standards.md` remains project-owned by default. `update-project.sh` does not replace it unless you explicitly pass `--sync-coding-standards`.

If an existing root policy file does not have the managed marker, `update-project.sh` leaves it unchanged and reports a skip notice suggesting `--migrate-root`.
If an existing root worktree helper script does not have the managed marker,
`update-project.sh` leaves it unchanged and reports a skip notice suggesting
`--migrate-root-scripts`.

Template refresh is opt-in:
- `./scripts/update-project.sh <repo-path> --sync-templates` updates `agent-vault/Templates/` from the scaffold and backs up replaced files under `agent-vault/context/updates/<timestamp>/`.
- Without `--sync-templates`, project-local template customizations are left alone except for policy-critical templates that are always managed (`agent-vault/Templates/Decision Record.md`).

Coding standards refresh is also opt-in:
- `./scripts/update-project.sh <repo-path> --sync-coding-standards` replaces `agent-vault/coding-standards.md` with the scaffold version and backs up the previous file under `agent-vault/context/updates/<timestamp>/`.
- Without `--sync-coding-standards`, the script leaves project-owned coding standards untouched and reports when they differ from the scaffold.

### Migrating Root Wrappers (`--migrate-root`)
When running `update-project.sh` with `--migrate-root`, unmanaged root wrappers (those missing the `agent-vault-managed` marker) are backed up and replaced with the current scaffold versions. This is useful for workspaces created before root wrapper management was introduced.

### Migrating Root Worktree Helpers (`--migrate-root-scripts`)
Generated projects include optional helpers for creating and removing
issue-scoped Git worktrees:

- `<repo>/scripts/new-worktree.sh`
- `<repo>/scripts/remove-worktree.sh`

When running `update-project.sh` normally, missing helper scripts are created
from the scaffold and executable permissions are enforced. Existing helper
scripts with the managed marker are updated from the scaffold. Existing helper
scripts without the marker are skipped unless you pass
`--migrate-root-scripts`, which backs up and replaces them with the managed
versions.

The default worktree location is a repo-local ignored directory named
`.worktrees/`. A writing agent can run the setup helper from the original
checkout, but generated instructions require the agent to switch to the printed
worktree path before making code edits, either by launching from that directory
or by using that path for all subsequent file operations. Users can override the
root with `--root` or `AGENT_VAULT_WORKTREE_ROOT`.

Generated guidance also treats post-merge cleanup as the standard cleanup point
because issue branches usually map to pull requests. Before deleting a local
branch, agents must verify the PR is merged or get explicit owner confirmation;
otherwise they should remove only the worktree, keep the branch, and report what
was skipped. The full cleanup recipe lives in
`<repo>/docs/runbooks/parallel-agent-worktrees.md`.

When a managed file changes, the script backs up the previous version under:
- `<repo>/agent-vault/context/updates/<timestamp>/...`

Generated projects auto-enable the tracked metadata gate in the clone where `new-project.sh` or `update-project.sh` runs, unless `core.hooksPath` is already set to something else. Additional clones can enable it with:
- `git -C <repo-path> config core.hooksPath agent-vault/_assets/hooks`

The tracked `pre-commit` hook enforces the baseline session artifacts and validates staged `agent-vault/context-log.md` ordering/freshness so newer entries do not get appended below stale headers. The tracked `pre-push` hook is inert by default; repos may opt into a narrow direct-push-to-`main` shortcut for runtime `agent-vault` metadata only:
- `git -C <repo-path> config --local agent-vault.allowMetadataOnlyMainPush true`

That shortcut allows recording history after PR merges while keeping source code, config, scripts, root docs, policy files, templates, hook assets, and durable project docs such as `agent-vault/README.md`, `plan.md`, `coding-standards.md`, `project-context.md`, `project-commands.md`, and `handoff.md` on the PR path.
When syncing older generated repos, `update-project.sh` now auto-migrates recognized legacy `agent-vault/context-log.md` layouts into the validator-compatible top-level `## Current Snapshot` / `## Entries` shape before syncing the stricter hook. If the layout is not recognized, the script leaves the file unchanged and prints a manual-remediation warning instead of guessing.

Both scripts also ensure root `.gitignore` includes managed local-only ignore entries (added only when missing):
- `.obsidian/workspace.json`
- `.obsidian/app.json`
- `.obsidian/appearance.json`
- `.obsidian/workspace-mobile.json`
- `.obsidian/cache/`
- `.obsidian/backup/`
- `.obsidian/plugins/*/data.json`
- `/agent-vault/context/updates/`
- `/.worktrees/`

## Migrating Existing Root Policy Files
When running `new-project.sh` with `--migrate-existing-root-md`:
- Existing root policy files are backed up under `agent-vault/context/updates/<timestamp>/`.
- Existing root content is appended into the corresponding `agent-vault/*.md` policy file under a `Migrated Legacy ...` section.
- Root wrappers from `scaffold/root/` are then written to:
  - `<repo>/AGENTS.md`
  - `<repo>/CLAUDE.md`
  - `<repo>/GEMINI.md`
- The `CLAUDE.md` and `GEMINI.md` root wrappers include `agent-vault/CLAUDE.md` and `agent-vault/GEMINI.md` so migrated legacy guidance remains part of root entrypoint context.

Without this flag, `new-project.sh` leaves pre-existing root files unchanged and prints a notice.

## Design Docs and Diagrams
Generated projects get a starter `docs/design.md` that uses Mermaid fenced code blocks as the default diagram format.
- GitHub renders Mermaid in Markdown natively.
- Obsidian renders Mermaid in Markdown natively.
- No Mermaid-specific install is required for agents to create or update the diagrams.
- Add Mermaid CLI, separate `.mmd` files, or rendered SVG/PNG artifacts only if a specific project later needs validation or exported assets.

## Generated Structure
`new-project.sh` creates `<repo-path>/agent-vault/` with:
- `shared-rules.md` (single source of truth for implementation rules)
- `review-policy.md` (single source of truth for PR review guidelines, including required format for responding to review feedback)
- `AGENTS.md`, `CLAUDE.md`, and `GEMINI.md` (policy files; `agent-vault/CLAUDE.md` and `agent-vault/GEMINI.md` import `shared-rules.md`, `project-context.md`, and `project-commands.md`; root wrappers import `review-policy.md`; and `AGENTS.md` inlines review guidance)
- Compatibility note: `AGENTS.md` files intentionally inline mirrored policy content for Codex review-path compatibility; this duplication is expected, but mirrored files should stay synchronized.
- `README.md`
- `context-log.md`
- `plan.md`
- `coding-standards.md`
- `project-context.md`
- `project-commands.md`
- `decision-log.md`
- `open-questions.md`
- `lessons.md`
- `handoff.md`
- `daily/`, `context/`, `design-log/`, `decisions/`, `_assets/` (including the optional tracked hooks under `agent-vault/_assets/hooks/`)
- `Templates/` (copied from template source; instantiated notes belong outside this folder)

It also creates project-root files when missing:
- `<repo-path>/AGENTS.md` -> contains PR review guidance (inline) for Codex GitHub reviews and points workflow execution to `agent-vault/AGENTS.md`
- `<repo-path>/CLAUDE.md` -> imports `agent-vault/CLAUDE.md` and `agent-vault/review-policy.md`
- `<repo-path>/GEMINI.md` -> imports `agent-vault/GEMINI.md` and `agent-vault/review-policy.md`
- `<repo-path>/docs/design.md` -> starter architecture/design document with embedded Mermaid diagrams
- `<repo-path>/docs/runbooks/parallel-agent-worktrees.md` -> optional workflow for one issue-scoped Git worktree per writing agent
- `<repo-path>/.github/pull_request_template.md` -> standardized agent PR body template
- `<repo-path>/scripts/new-worktree.sh` and `<repo-path>/scripts/remove-worktree.sh` -> managed helpers for parallel-agent Git worktree setup and cleanup
- Bootstrap behavior: `new-project.sh` hydrates project metadata placeholders (`repo_reference`, active branch, dates) in the baseline `agent-vault/` docs, seeds non-empty baseline content in `agent-vault/README.md`, `plan.md`, `coding-standards.md`, and `context-log.md`, copies structured starter templates for `project-context.md` and `project-commands.md`, and copies scaffold helper docs such as `agent-vault/design-log/README.md` plus `docs/design.md`.

If root files already exist, the script leaves them unchanged unless `--migrate-existing-root-md` is provided.

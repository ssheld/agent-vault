# Parallel Agent Worktrees

## Purpose
Use one issue-scoped Git worktree per writing agent so multiple agents can work
from the same repository without editing the same checkout or branch.

The core rule is:

- one issue
- one branch
- one worktree
- one writing agent

Terminal multiplexers are optional and intentionally not part of this workflow.
The helpers only create or remove Git worktrees.

## Why Worktrees
Use Git worktrees when you want to:

- work on multiple issues from the same repository clone
- keep each issue on its own branch and directory
- avoid branch switching churn in one checkout
- keep agents from editing the same working tree

Do not point multiple writing agents at the same checkout.

## Agent Start Contract
When a user asks an agent to implement or start work on a numbered issue, the
agent should create or reuse the issue worktree before making code edits:

1. Derive a short slug from the issue title when possible.
2. Run `./scripts/new-worktree.sh --agent <agent> --issue <number> --slug <slug>`
   from the main checkout.
3. Switch to the printed worktree path before code edits, either by launching
   from that directory or by using that path for all subsequent file operations.
4. Avoid editing the main checkout unless the user explicitly asks not to use a
   worktree or the work is clearly non-implementation work.

## Create A Worktree
From the main checkout:

```bash
./scripts/new-worktree.sh --agent codex --issue 123 --slug feature-slice
```

Other agent examples:

```bash
./scripts/new-worktree.sh --agent claude --issue 124 --slug review-cleanup
./scripts/new-worktree.sh --agent gemini --issue 125 --slug docs-followup
```

By default the helper creates repo-local worktrees under:

```text
.worktrees/
```

For a repository named `example-app`, the layout is:

```text
example-app/                                      # main checkout
example-app/.worktrees/codex-123-feature-slice/   # issue worktree
example-app/.worktrees/claude-124-review-cleanup/ # issue worktree
example-app/.worktrees/gemini-125-docs-followup/  # issue worktree
```

The helper creates:

- a branch named like `codex/123-feature-slice`
- a worktree directory named like `codex-123-feature-slice`

Then it prints the `cd` command and a best-effort launch hint such as `codex`,
`claude`, or `gemini`.

## Custom Worktree Root
Use `--root` to place worktrees somewhere else:

```bash
./scripts/new-worktree.sh \
  --agent codex \
  --issue 126 \
  --slug api-refactor \
  --root ../custom-worktrees
```

Relative `--root` paths are resolved from the main checkout, not your current
directory. `--root` overrides the `AGENT_VAULT_WORKTREE_ROOT` environment
variable, which overrides the default `.worktrees/` root:

```bash
AGENT_VAULT_WORKTREE_ROOT=../custom-worktrees \
  ./scripts/new-worktree.sh --agent codex --issue 126 --slug api-refactor
```

## Repo-Local Worktree Notes
Git handles nested worktrees under `.worktrees/<name>/` cleanly; each nested
worktree has a `.git` file that points back to Git's worktree metadata.
Generated `.gitignore` management keeps `/.worktrees/` ignored so the main
checkout's status stays clean.

Tools that do not honor `.gitignore` may still traverse repo-local worktree
contents. `rg` respects `.gitignore` by default.

## Agent Sandbox Permissions
It is fine for an agent launched from the original checkout to run the setup
helper:

```bash
./scripts/new-worktree.sh --agent codex --issue 123 --slug feature-slice
```

For actual writing work, switch to the generated worktree first:

```bash
cd .worktrees/codex-123-feature-slice
codex
```

Use the same pattern for other agents:

```bash
cd .worktrees/claude-124-review-cleanup
claude

cd .worktrees/gemini-125-docs-followup
gemini
```

Many agent clients treat the launch directory as the active writable workspace.
If the agent cannot relaunch from the worktree, use the printed path for all
subsequent file operations before making code edits.

## Recommended Workflow

### 1. Create the worktree

```bash
./scripts/new-worktree.sh --agent codex --issue 123 --slug feature-slice
```

### 2. Enter the new directory

```bash
cd .worktrees/codex-123-feature-slice
```

### 3. Launch the writing agent

```bash
codex
```

### 4. Run issue-local checks from that worktree
Run the relevant project commands from `agent-vault/project-commands.md`.

## Cleanup After Merge Or Completion
Post-merge cleanup is the standard cleanup point because the issue branch
usually maps to the pull request.

Before deleting the branch, verify the PR is merged:

```bash
gh pr view codex/123-feature-slice --json state,mergedAt
```

Only proceed with branch deletion when the PR is merged, or when the owner
explicitly confirms that unmerged work is abandoned and the branch can be
deleted. `OPEN`, `CLOSED` without `mergedAt`, missing PRs, stale activity, and
unclear context all use the safe default: remove the worktree if appropriate,
keep the branch, and report what was skipped.

From the main checkout or another directory outside the target worktree:

```bash
git fetch
git checkout main
git pull
./scripts/remove-worktree.sh --branch codex/123-feature-slice --delete-branch
```

If the project uses a non-`main` integration branch, use that project default
instead.

For done-but-unmerged work, remove only the worktree unless the owner confirms
branch deletion:

```bash
./scripts/remove-worktree.sh --branch codex/123-feature-slice
```

The cleanup helper refuses to remove a worktree containing the current working
directory. If your current directory is inside the target worktree, switch to
the main checkout or another safe directory before running cleanup.

Treat helper refusal as a safety signal. If cleanup is blocked by the current
working directory, a branch/path mismatch, or a shared `.venv` editable install
that still points inside the target worktree, report the remaining cleanup step
instead of forcing through.

Do not run `--force` autonomously. It is a user-confirmed escape hatch for an
intentionally disposable dirty worktree, not part of normal cleanup.

## Existing Project Command Snippet
For existing projects whose `agent-vault/project-commands.md` predates these
helpers, copy this section into that file if you want the workflow listed with
the project commands:

```md
## Parallel Worktree Commands

\`\`\`bash
# Create one issue-scoped worktree for Codex
./scripts/new-worktree.sh --agent codex --issue 123 --slug feature-slice

# Create one issue-scoped worktree for Claude
./scripts/new-worktree.sh --agent claude --issue 124 --slug review-cleanup

# Create one issue-scoped worktree for Gemini
./scripts/new-worktree.sh --agent gemini --issue 125 --slug docs-followup

# After merge, remove the worktree from the main checkout or another safe cwd
./scripts/remove-worktree.sh --branch codex/123-feature-slice --delete-branch
\`\`\`

See `docs/runbooks/parallel-agent-worktrees.md` for the full worktree workflow,
including branch-deletion guardrails and cleanup for done-but-unmerged work.
```

## Notes
- The create helper is idempotent for the same agent, issue, and slug. If the
  worktree already exists, it prints the existing path instead of creating a
  duplicate.
- Existing sibling or custom worktree roots keep working with `--root` or
  `AGENT_VAULT_WORKTREE_ROOT`; no automatic relocation is attempted.
- The remove helper checks whether the main checkout's `.venv` has an editable
  install path pointing inside the target worktree. If so, it refuses removal so
  local tools do not keep importing from a deleted path.
- Parallel branches often conflict in `agent-vault/context-log.md`,
  same-day daily notes, and nearby design-log notes. Resolve those conflicts by
  keeping all valid entries and preserving the ordering rules from
  `agent-vault/AGENTS.md`.

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

## Requirements

The two worktree helpers require Git 2.36+ and Bash 3.2+. They reject unsupported
Git before changing directories, branches, or worktrees. Upgrade Git and ensure
the supported executable is first on `PATH`. Git 2.36 added the NUL-delimited
worktree listing used to preserve paths containing newlines.
[Git 2.36 release notes](https://github.com/git/git/blob/v2.36.0/Documentation/RelNotes/2.36.0.txt)

The primary checkout must be available and non-bare. Bare-only layouts and
inconsistent registry identities are unsupported. The helpers verify the
primary checkout reported by Git instead of inferring it from a `.git` parent.
If a separate-metadata layout reports its metadata directory as the primary
checkout, the helpers refuse it; restore a conventional primary-checkout layout
or repair the repository metadata before retrying.

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
./scripts/new-worktree.sh --agent grok --issue 126 --slug grok-build-support
```

By default the helper creates repo-local worktrees under:

```text
.worktrees/
```

For a repository named `example-app`, the layout is:

```text
example-app/                                        # main checkout
example-app/.worktrees/codex-123-feature-slice/     # issue worktree
example-app/.worktrees/claude-124-review-cleanup/   # issue worktree
example-app/.worktrees/gemini-125-docs-followup/    # issue worktree
example-app/.worktrees/grok-126-grok-build-support/ # issue worktree
```

The helper creates:

- a branch named like `codex/123-feature-slice`
- a worktree directory named like `codex-123-feature-slice`

Then it prints the `cd` command and a best-effort launch hint such as `codex`,
`claude`, `gemini`, or `grok`.

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

The same rules apply when invoking a helper copy inside a linked worktree. The
helper prints `Primary: ...` and creates a sibling under the primary checkout
by default. A custom root inside a linked worktree is refused, including
symlink aliases. Reuse also refuses existing unsafe layouts. Preserve their
contents and arrange separate cleanup or relocation; the helper does not
automatically move existing worktrees.

## Repo-Local Worktree Notes
Sibling linked worktrees under the primary checkout's `.worktrees/<name>/`
directory are supported; each has a `.git` file pointing to Git's metadata.
Do not put one linked worktree inside another: ignored inner contents can be
deleted when the outer directory is removed.
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

cd .worktrees/grok-126-grok-build-support
grok
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

### Registered Descendants

Removal refuses a target containing any other registered worktree, including
dirty, detached, locked, or missing descendants. This protection also applies
with `--force`. Preserve the inner worktree's contents and handle its cleanup
or relocation separately before removing the outer worktree.

For a missing descendant, first confirm whether it was deleted, moved, or is
temporarily unavailable (for example, an unmounted drive). Restore access or
repair its registration as appropriate. For confirmed obsolete records, preview
`git worktree prune --dry-run --verbose`, inspect all proposed removals, then
prune and retry when appropriate. The helper does not automatically prune a
descendant record to bypass this guard.

Both helpers automatically prune a requested stale record only when no other
registered worktree is missing or marked prunable by Git. Pruning is
repository-wide: an unrelated cleanup must not silently discard another
worktree's containment evidence. This also covers existing directories with
missing worktree metadata, not just missing directories. Investigate and
restore/repair those records, or deliberately preview and inspect the proposed
prune before proceeding. Ordinary single-stale-record recovery remains supported.

The registry is checked again immediately before removal. This is not an atomic
guarantee against concurrent raw Git worktree commands or filesystem changes;
complete manual worktree creation, moves, and repairs before cleanup.

### Protected Branches

All branch-deletion paths protect these exact local branch names:

- `main` and `master`.
- The branch attached to the actual primary checkout, if attached.
- Defaults named by locally recorded `refs/remotes/<remote>/HEAD` references.
- Additional names in repeatable local `agentVault.protectedBranch` settings.

For example:

```bash
git config --local --add agentVault.protectedBranch develop
git config --local --add agentVault.protectedBranch release/stable
```

Configuration values are literal branch names, not patterns. Remote-HEAD
metadata may be absent or stale; a repository with no remotes relies on the
other protection sources. Additional integration branches should be configured
explicitly. Cleanup performs no network calls.

Neither `--force` nor `--delete-branch` overrides protection. Ordinary approved
disposable-branch deletion remains supported when no worktree is registered or
after its obsolete worktree record is pruned.

To deliberately retire a protected branch (for example, a vestigial `master`
after a default-branch rename), obtain owner confirmation, inspect the branch
tip and any commits unique to it, and verify that the commits to retain are
reachable from a retained branch or tag. Then perform the specifically approved
branch deletion directly with Git from the primary checkout. Do not use manual
deletion to bypass an unexplained safety refusal.

Existing projects keep their local runbooks during scaffold updates. The
helper's refusal messages and `--help` therefore include the essential owner
confirmation and commit-preservation requirements independently of this file.

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

# Create one issue-scoped worktree for Grok Build
./scripts/new-worktree.sh --agent grok --issue 126 --slug grok-build-support

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

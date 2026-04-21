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

By default the helper creates sibling worktrees under:

```text
../<repo-name>-wt/
```

For a repository named `example-app`, the layout is:

```text
example-app/                                  # main checkout
example-app-wt/codex-123-feature-slice/       # issue worktree
example-app-wt/claude-124-review-cleanup/     # issue worktree
example-app-wt/gemini-125-docs-followup/      # issue worktree
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

Relative `--root` paths are resolved from the main checkout.

## Agent Sandbox Permissions
It is fine for an agent launched from the original checkout to run the setup
helper:

```bash
./scripts/new-worktree.sh --agent codex --issue 123 --slug feature-slice
```

For actual writing work, launch a new agent session from inside the generated
worktree:

```bash
cd ../example-app-wt/codex-123-feature-slice
codex
```

Use the same pattern for other agents:

```bash
cd ../example-app-wt/claude-124-review-cleanup
claude

cd ../example-app-wt/gemini-125-docs-followup
gemini
```

Many agent clients treat the launch directory as the active writable workspace.
If an agent launched from the main checkout edits a sibling worktree, the client
may ask for extra approval prompts or deny writes. If your client supports
trusted or writable roots, you can trust the sibling worktree root, but launching
inside the assigned worktree is the default path.

## Recommended Workflow

### 1. Create the worktree

```bash
./scripts/new-worktree.sh --agent codex --issue 123 --slug feature-slice
```

### 2. Enter the new directory

```bash
cd ../example-app-wt/codex-123-feature-slice
```

### 3. Launch the writing agent

```bash
codex
```

### 4. Run issue-local checks from that worktree
Run the relevant project commands from `agent-vault/project-commands.md`.

### 5. After merge, remove the worktree from a safe directory
From the main checkout or another directory outside the target worktree:

```bash
./scripts/remove-worktree.sh --branch codex/123-feature-slice --delete-branch
```

The cleanup helper refuses to remove a worktree containing the current working
directory. This avoids leaving an agent session pointed at a deleted directory.

Only use `--delete-branch` after the issue branch is merged or no longer needed.
Add `--force` only when you intentionally want to remove a dirty disposable
worktree.

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
```

## Notes
- The create helper is idempotent for the same agent, issue, and slug. If the
  worktree already exists, it prints the existing path instead of creating a
  duplicate.
- The remove helper checks whether the main checkout's `.venv` has an editable
  install path pointing inside the target worktree. If so, it refuses removal so
  local tools do not keep importing from a deleted path.
- Parallel branches often conflict in `agent-vault/context-log.md`,
  same-day daily notes, and nearby design-log notes. Resolve those conflicts by
  keeping all valid entries and preserving the ordering rules from
  `agent-vault/AGENTS.md`.

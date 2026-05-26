# Project Commands

Use this file for the setup, test, development, and operational commands that
agents should rely on in this repository. Prefer repo-relative commands and
update this file when the canonical workflow changes.

## Setup

```bash
# Add setup commands here.
```

## Test Commands

```bash
# Add test commands here.
```

## Development / Run Commands

```bash
# Add local development or runtime commands here.
```

## Parallel Worktree Commands

```bash
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
```

The helper creates repo-local worktrees under `.worktrees/` by default. Launch
the writing agent from inside the generated worktree, or use that path for all
subsequent edits. Keep the main checkout for integration, review, and cleanup.
See `docs/runbooks/parallel-agent-worktrees.md` for the full worktree workflow,
including branch-deletion guardrails and cleanup for done-but-unmerged work.

## Release / Operations Commands

```bash
# Add deploy, migration, or operational commands here when relevant.
```

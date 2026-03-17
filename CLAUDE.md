# CLAUDE.md

## Purpose
This repository holds reusable scaffold files for `agent-vault/`.

## Rules
- Edit `scaffold/agent-vault/` for defaults used in future project initialization.
- Do not store project-specific context in this repository.
- Generate project context only via `scripts/new-project.sh`.
- When updating generated-project behavior, modify scaffold files and script templates together.

## PR Authoring
- For agent-authored pull requests in generated projects, follow `scaffold/agent-vault/AGENTS.md` section `PR Authoring Standards`.
- Use `.github/pull_request_template.md` when present.

## GitHub Post Attribution
- For GitHub issues, issue comments, and non-review PR conversation comments, begin the body with:

```md
> 🤖 **Post by {Model Name}** · via {Client Tool}
```

- Use your actual model name/version when known. If the exact version is unavailable, use the best identifier you have.
- If the post is specifically PR review feedback or a PR review-feedback response, use the review-policy format instead.
- Never present GitHub posts as if they are the human account owner's personal opinion.
- Prefer repo-relative paths or GitHub links over local filesystem paths in GitHub posts.

@scaffold/agent-vault/review-policy.md

## Target Project Usage
In generated project vaults:
- `agent-vault/Templates/` is template source only. Instantiated notes belong in canonical runtime files under `agent-vault/`.
- Start substantive work by reading `agent-vault/README.md`, `agent-vault/context-log.md`, `agent-vault/plan.md`, and `agent-vault/coding-standards.md`.
- Skim `agent-vault/open-questions.md` for blockers and `agent-vault/decision-log.md` for active decisions relevant to the task.
- Use `agent-vault/context-log.md` as canonical cross-session memory.
- Use `agent-vault/daily/`, `agent-vault/design-log/`, `agent-vault/context/handoffs/`, and `agent-vault/decisions/` for runtime artifacts when the workflow calls for them.

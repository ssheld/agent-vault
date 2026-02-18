# CLAUDE.md - House Rules for Claude Agents in this Repository

## Core Principles
- Treat documentation as source code: code and docs must always stay in sync.
- Never propose or commit changes that break documentation consistency.
- When asked to implement, refactor, or add a feature, always follow the Pre-Commit Checklist below before finalizing edits or commits.

## Code Style
- Prefer TypeScript over JavaScript.
- Use meaningful variable names and avoid abbreviations.
- Add comments only when the "why" is not obvious from the code.

## Git
- Write concise commit messages in imperative mood.
- Keep commits atomic: one logical change per commit.

## Session Start - Required
- Read `agent-vault/context-log.md`.
- Read `agent-vault/plan.md`.
- Read `agent-vault/coding-standards.md`.
- Read recent notes in `agent-vault/design-log/`.
- Read recent notes in `agent-vault/context/handoffs/`.

## Session End - Required
- Update `agent-vault/context-log.md`.
- Add a session note in `agent-vault/design-log/`.
- Update `agent-vault/open-questions.md` when unresolved items exist.
- If handing off, add a note in `agent-vault/context/handoffs/`.

## Pre-Commit Checklist - MUST follow before every commit or patch application
Before considering any change complete and before running git commit:

1. Architecture / Design Document Check
- Read `docs/design.md` (or the project's main architecture/design document if named differently).
- Determine whether the proposed changes modify, add to, or invalidate any component, layer, data flow, boundary, interface, or architectural invariant described there.
- If yes: automatically propose and apply the corresponding updates to `docs/design.md` so it accurately reflects the new reality.
- If no: explicitly state in your reasoning: "No impact on docs/design.md detected."

2. README.md / User-Facing Documentation Check
- Scan the diff for changes to:
  - CLI commands or usage examples
  - Setup or installation instructions
  - Required environment variables
  - API endpoints, request/response shapes, authentication flows
  - Project folder structure or important file locations
- If any of the above are affected: propose and apply corresponding updates to `README.md` (or `CONTRIBUTING.md` / `docs/usage.md` if more appropriate).
- Keep changes concise, clear, and professionally formatted.

3. Hard Rule - Documentation MUST be consistent
- Do not finalize, commit, or present a patch until both checks above are complete and documentation files are updated if needed.
- If documentation updates are required but blocked (missing info, ambiguity), ask for clarification instead of proceeding.
- In the final response or patch summary, include one of these statements:
  - "Documentation is consistent - design.md and README.md were checked and need no changes."
  - "Updated docs/design.md to reflect new [component/flow]."
  - "Updated README.md: added/edited [specific section]."

## Additional Guardrails
- Prefer explicit diffs over whole-file rewrites when updating docs.
- Use the same tone and markdown style already present in the docs files.
- If running in full-auto mode, still pause and show documentation-related diffs separately for review unless `--ask-for-approval=never` is explicitly set.

These rules override any conflicting default behaviors.

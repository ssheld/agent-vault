<!-- This file is managed by agent-vault. Do not edit in target projects. -->

## Compatibility Note
- `agent-vault/AGENTS.md` intentionally mirrors this file for Codex compatibility.
- `agent-vault/CLAUDE.md` and `agent-vault/GEMINI.md` import this file directly.
- Treat duplication as intentional; treat content drift as a defect.

## PR Feedback Response
- When posting a PR comment that addresses reviewer feedback, follow `agent-vault/review-policy.md` under `Responding to Review Feedback`.
- Map every finding to a status (`Resolved`, `Partially Resolved`, or `Not Changed`) with concrete evidence.
- If pushing back, explain technical rationale and risk/tradeoff explicitly.

## Core Principles
- Treat documentation as source code: code and docs must always stay in sync.
- Never propose or commit changes that break documentation consistency.
- When asked to implement, refactor, or add a feature, always follow the Pre-Commit Checklist below before finalizing edits or commits.
- Find root causes. No temporary fixes or workarounds unless explicitly agreed with the user and tracked in `agent-vault/open-questions.md`.
- For non-trivial tasks (3+ steps or architectural decisions), outline a plan before implementing. Use `agent-vault/plan.md` for milestone-level planning. If implementation diverges significantly from the plan, stop and re-plan.

## Code Style
- Prefer TypeScript over JavaScript.
- Use meaningful variable names and avoid abbreviations.
- Add comments only when the "why" is not obvious from the code.

## Git
- Write concise commit messages in imperative mood.
- Keep commits atomic: one logical change per commit.

## PR Authoring Standards
- When creating a pull request, include a complete PR body; do not open with a one-line summary only.
- Use an imperative, outcome-focused title that reflects the actual change scope.
- Keep PR scope coherent; split unrelated work into separate PRs.
- Prefer opening as draft until validation is complete, unless the user asks otherwise.
- PR body must include:
  - Summary of problem and approach.
  - Files/areas changed with concise rationale.
  - Validation evidence (commands run and outcomes).
  - Risks, rollback considerations, and any residual gaps.
  - Explicit docs consistency note (`design.md`/`README.md` updated or no impact).
- If tests/checks were not run, explicitly state why and what remains unverified.
- If the PR addresses review feedback, include itemized mapping per `review-policy.md` (`Responding to Review Feedback`).

## Session Start - Required
- Read `agent-vault/context-log.md`.
- Read `agent-vault/plan.md`.
- Read `agent-vault/coding-standards.md`.
- Read `agent-vault/README.md`.
- Read recent notes in `agent-vault/design-log/`.
- Read recent notes in `agent-vault/context/handoffs/`.
- Read `agent-vault/lessons.md` (if it exists).
- After completing the reads above, confirm by listing which files were read and briefly summarize the current project state (active plan, recent decisions, open questions).

## Session End - Required
- Update `agent-vault/context-log.md`.
- Add a session note in `agent-vault/design-log/`.
- Update `agent-vault/open-questions.md` when unresolved items exist.
- If handing off, add a note in `agent-vault/context/handoffs/`.
- If the user corrected a mistake during this session, add an entry to `agent-vault/lessons.md` describing the mistake pattern and a preventive rule.

## Completion Verification - MUST follow before marking any task done
Before reporting a task as finished:
1. Prove it works: run relevant tests, check logs, or demonstrate the changed behavior.
2. Diff against the base branch to confirm only intended changes are included.
3. Ask yourself: "Would a senior engineer approve this?" If not, fix it first.
4. If verification is not possible (no test suite, no runnable environment), explicitly state what was checked and what remains unverified.

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

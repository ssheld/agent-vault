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

## Artifact Locations and Naming
- `agent-vault/Templates/` is template source only. Do not store completed project notes there.
- Canonical always-on files:
  - `agent-vault/README.md` - project home
  - `agent-vault/plan.md` - milestone plan
  - `agent-vault/coding-standards.md` - project conventions
  - `agent-vault/context-log.md` - canonical cross-session memory
  - `agent-vault/open-questions.md` - unresolved questions
  - `agent-vault/decision-log.md` - decision index
  - `agent-vault/lessons.md` - recurring mistake-prevention rules
- Canonical runtime note locations:
  - `agent-vault/daily/YYYY-MM-DD.md` - one daily note per local day
  - `agent-vault/design-log/YYYY-MM-DD-HHMM-<topic>.md` - one session note per substantive work session
  - `agent-vault/context/handoffs/YYYY-MM-DD-HHMM-<from>-to-<to>-<topic>.md` - handoff note when transferring work
  - `agent-vault/decisions/DEC-###-<slug>.md` - decision record
- `agent-vault/context/scratchpad.md` is temporary working memory only. Move lasting information into canonical files before finishing.

## Template Usage Rules
- Use the bootstrap files in place. Do not create duplicate `README.md`, `plan.md`, `coding-standards.md`, `context-log.md`, `open-questions.md`, or `decision-log.md` notes elsewhere.
- Create or update `agent-vault/daily/YYYY-MM-DD.md` on the first substantive work session of each local day. Reuse the same file for later sessions that day. Skip daily notes for trivial one-off requests.
- Add a design-log note for every substantive work session.
- When a durable decision is made about architecture, workflow, API shape, data model, deployment, or tool policy, create a decision record in `agent-vault/decisions/` and add it to `agent-vault/decision-log.md`.
- When handing off or pausing with meaningful unfinished work, create a handoff note in `agent-vault/context/handoffs/`, include a `Suggested Next Prompt`, and reference that note from `agent-vault/context-log.md`.
- Use the standalone handoff prompt template only when a human explicitly asks for a copy-paste prompt. Otherwise keep the prompt inside the handoff note and the latest `context-log.md` entry.
- Use `agent-vault/context/scratchpad.md` only for temporary notes. Move durable state, decisions, and open questions into canonical files before finishing.

## Design Docs and Diagrams
- `docs/design.md` is the default architecture and design document unless the project clearly uses a different canonical path.
- Prefer Mermaid fenced code blocks embedded directly in Markdown for architecture, workflow, and data-flow diagrams.
- Keep diagrams grounded in code and documented behavior. Do not invent services, queues, APIs, or responsibilities that are not present or explicitly planned.
- Keep diagrams concise and readable: short labels, clear edges, and no unnecessary node sprawl unless the task explicitly needs a larger diagram.
- Default to embedded Mermaid in Markdown. Do not introduce separate `.mmd` sources, generated SVG/PNG artifacts, or Mermaid-specific build steps unless the project already uses them or the user asks for them.

## Research and Citations
When performing research or writing research-oriented documentation (design-log notes, decision records, open questions, or any artifact that references external tools, APIs, libraries, or concepts):

### Citation Requirements
- Include a source URL for every factual claim drawn from external documentation, blog posts, official references, or community sources.
- Format citations inline as `[description](URL)`. For documents with many references, also collect them in a **Sources** section at the bottom.
- When a URL is unavailable (e.g., information comes from training data rather than a fetched page), state the source explicitly (e.g., "per the Express.js v4 documentation" or "based on the AWS SDK v3 API reference") so the reader can verify independently.
- Never present external claims without attribution. If you cannot cite a source, say so.

### Write for a Context-Free Reader
- Assume the reader has no prior familiarity with the specific tools, APIs, libraries, or features being discussed.
- On first mention of any external API, library, service, or domain-specific concept, include a one-sentence explanation of what it is and what it does.
- Do not assume familiarity with version-specific features, configuration options, or behavioral nuances. State the version and explain the relevant behavior.
- Spell out acronyms on first use unless they are universally understood in software engineering (e.g., HTTP, JSON, SQL are fine; CDK, ECS, SWR need expansion).

### Research Document Structure
- Lead with a brief summary of the research question and the conclusion before diving into details.
- Organize findings by theme or option, not by the order they were discovered.
- When comparing alternatives, use a table or side-by-side format with clear evaluation criteria.

## Session Start - Required
- Read the core files before substantive work:
  - `agent-vault/README.md`
  - `agent-vault/context-log.md`
  - `agent-vault/plan.md`
  - `agent-vault/coding-standards.md`
- Skim `agent-vault/open-questions.md` for active blockers relevant to the task.
- Skim `agent-vault/decision-log.md` for active decisions relevant to the task.
- Read `agent-vault/lessons.md` (if it exists).
- When continuing existing work or taking on a substantive task, expand context with:
  - the most recent 3 notes in `agent-vault/design-log/`
  - the handoff note referenced by the latest `agent-vault/context-log.md` entry, or the most recent note in `agent-vault/context/handoffs/` when no note is referenced
  - today's note in `agent-vault/daily/` if it exists
  - the decision records referenced by `agent-vault/decision-log.md`, or the most recent 1-3 accepted or proposed decision records when no records are referenced and they appear relevant
- For trivial one-off tasks, a lighter session start is acceptable: core files plus any directly referenced handoff or decision artifact.
- After completing the reads above, confirm by listing which files were read and briefly summarize the current project state (active plan, recent decisions, open questions, current handoff state).

## Session End - Required
- Update `agent-vault/context-log.md`.
- Create or update today's note in `agent-vault/daily/` when the session was substantive.
- Add a session note in `agent-vault/design-log/`.
- Update `agent-vault/open-questions.md` when unresolved items exist.
- If a durable decision was made, create or update the corresponding decision record and `agent-vault/decision-log.md`.
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
- When diagrams are needed or updated, prefer Mermaid blocks in the Markdown document rather than screenshots or external image assets unless the project already uses another documented approach.
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

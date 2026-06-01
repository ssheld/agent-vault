# AGENTS.md - Workflow Rules for Codex Agents in this Repository
<!-- Keep shared rules in sync with agent-vault/shared-rules.md -->

## Scope
- This file defines implementation workflow and handoff behavior.
- PR review policy lives in the project-root `AGENTS.md`.

## Compatibility Note
- `agent-vault/AGENTS.md` intentionally mirrors `agent-vault/shared-rules.md` for Codex compatibility.
- `agent-vault/CLAUDE.md` and `agent-vault/GEMINI.md` import `shared-rules.md` and `lessons.md`.
- Do not flag duplication itself; only flag drift between mirrored policy files.

## PR Feedback Response
- When posting a PR comment that addresses reviewer feedback, follow `agent-vault/review-policy.md` under `Responding to Review Feedback`.
- When asked to review, summarize, respond to, or address all PR feedback, use
  the feedback retrieval checklist in `agent-vault/review-policy.md` before
  claiming all feedback was covered.
- Map every finding to a status (`Resolved`, `Partially Resolved`, or `Not Changed`) with concrete evidence.
- If pushing back, explain technical rationale and risk/tradeoff explicitly.

## GitHub Post Attribution
- When creating a GitHub issue, posting an issue comment, or posting a non-review PR conversation comment, begin the body with:

```md
> 🤖 **Post by {Model Name}** · via {Client Tool}
```

- Use your actual model name/version when known. If the exact version is unavailable, use the best identifier you have.
- If the post is specifically PR review feedback or a PR review-feedback response, use the specialized format in `agent-vault/review-policy.md` instead of this generic header.
- Never present GitHub posts as if they are the human account owner's personal opinion.
- Prefer repo-relative paths or GitHub links over local filesystem paths in GitHub posts.

## PR Review Posting
- When asked to review a pull request, follow the project-root `AGENTS.md` review policy exactly.
- Prefer a formal GitHub PR review whenever the platform/API allows it.
- Use a standalone PR conversation comment only as fallback, and include `Formal review state unavailable: <reason>`.
- Do not mix top-level review summaries with inline-comment markers, and do not use local filesystem paths in GitHub review comments.

## Core Principles
- Treat documentation as source code: code and docs must always stay in sync.
- When repo-local `agent-vault` instructions conflict with global plugin or user-level conventions, follow the repo-local instructions for this repository.
- Never propose or commit changes that break documentation consistency.
- When asked to implement, refactor, or add a feature, always follow the Pre-Commit Checklist below before finalizing edits or commits.
- Find root causes. No temporary fixes or workarounds unless explicitly agreed with the user and tracked in `agent-vault/open-questions.md`.
- For non-trivial tasks (3+ steps or architectural decisions), outline a plan before implementing. Use `agent-vault/plan.md` for milestone-level planning. If implementation diverges significantly from the plan, stop and re-plan.
- Focus simplification, cleanup, and refactoring on code already touched by the current task. Do not widen scope into unrelated cleanup unless it was explicitly requested or is necessary for correctness or maintainability of the current change.

## Feature Implementation Workflow
- Use this default sequence for non-trivial feature work, multi-step refactors, or changes with meaningful behavior or design impact.
- For trivial one-file edits, docs-only changes, or other low-risk work, a lighter path is acceptable as long as the relevant rules below are still followed.

1. Clarify the request, scope, and any material trade-offs before coding. If the choice affects architecture, workflow, security, performance, cost, or future flexibility, apply the Human Decision Gate.
2. Check for existing solutions before building something new. Follow Research First so local repo patterns, framework capabilities, and proven libraries are considered before net-new abstractions.
3. Plan the implementation and validation approach before coding. For non-trivial work, update or create the relevant plan in `agent-vault/plan.md`.
4. Implement in small coherent steps. Use TDD when practical, and keep the change aligned with the approved scope and plan.
5. Self-review the result before asking for outside review. Run the Verification Loop, inspect the diff, and fix issues before moving on.
6. Prepare the change for commit, PR, or handoff. Complete the Pre-Commit Checklist, update required `agent-vault` artifacts, and follow PR Authoring Standards when opening a PR.

## Issue Worktree Workflow
- For implementation work tied to a numbered issue, create or reuse one issue-scoped worktree before editing source files.
- From the main checkout, derive a short slug from the issue title when possible, then run `./scripts/new-worktree.sh --agent <agent> --issue <number> --slug <slug>`.
- Switch to the printed worktree path before code edits, either by launching from that directory or by using that path for all subsequent file operations.
- Avoid editing the main checkout unless the user explicitly asks not to use a worktree or the work is clearly non-implementation work.
- Keep the main checkout for integration, review, and cleanup.
- See `docs/runbooks/parallel-agent-worktrees.md` for the full worktree workflow and cleanup recipe.

## Worktree Cleanup
- After the PR for an issue branch is merged, or when the issue work is explicitly done or abandoned, clean up the issue worktree from the main checkout or another directory outside the target worktree.
- Before deleting a branch, verify the PR is merged with `gh pr view <branch> --json state,mergedAt`.
- If the PR is not proven merged, ask the owner before invoking `--delete-branch`. For `OPEN`, unmerged `CLOSED`, missing PR, stale, or unclear states, default to removing only the worktree, keeping the branch, and reporting what was skipped.
- If `remove-worktree.sh` refuses cleanup because the current process is inside the target worktree, a branch/path mismatch is unsafe, or a shared `.venv` still points into the target worktree, report the remaining cleanup step instead of forcing through.
- Never run `--force` autonomously. It is a user-confirmed escape hatch for intentionally disposable dirty worktrees, not part of normal cleanup.

## Human Decision Gate
- Humans are the default decision-makers for material trade-offs. When multiple technically valid options exist and the choice materially affects architecture, UX, maintainability, workflow, security posture, performance, cost, or future flexibility, do not choose silently.
- Material trade-offs include choices such as introducing or replacing core libraries, changing API or data-model shape, relaxing validation or security controls, changing deployment or review workflow, or accepting meaningful maintainability/performance/cost trade-offs to gain speed elsewhere.
- Surface the options, trade-offs, and your recommendation to the human owner instead of silently selecting a path.
- You may proceed without pausing only when at least one of the following is true:
  - the user explicitly delegated that class of decision,
  - an `accepted` decision record with explicit owner-approval provenance already exists,
  - the decision falls within a user-approved plan,
  - the choice is clearly reversible and already within explicitly approved scope.
- `proposed` decision records provide context only. Do not treat a `proposed` decision record as settled policy or as a bypass for this gate.
- Do not assume older `accepted` records bypass the gate unless the record itself preserves the owner approval provenance (for example, `owners`, `accepted_by`, and `approval_source`).

### Interactive Sessions
- In interactive sessions, present the trade-off directly to the user in the conversation with the options, trade-offs, and your recommendation.
- Do not proceed until the user chooses or explicitly delegates that class of decision.

### Full-Auto Mode
- In full-auto mode, the gate still applies. Do not hard-block, but record the chosen path, rationale, and pending owner decision in `agent-vault/open-questions.md`.

### Do Not Escalate
- Routine local implementation details that stay within approved scope and do not materially change behavior or future flexibility should not trigger the gate.
- Examples include local variable naming, formatting, choosing between equivalent helper APIs already established in the project, or reordering independent implementation steps.

## Research First
- Before building a new abstraction, workflow, or helper, search the existing repo for code, docs, templates, and prior patterns that may already solve most of the task.
- If the repo does not already contain a suitable solution, check the relevant framework, standard library, or established libraries before writing net-new utilities or infrastructure.
- Prefer reusing, adapting, or extending an existing local implementation or proven library capability when it materially fits the requirement.
- Research-first does not mean "add a dependency by default." If reuse would require a material tool, library, workflow, or architecture choice, still apply the Human Decision Gate.
- Do not force internet research for every task. Start with local repo sources and widen the search only when the task depends on behavior or tooling that is not already clear from local context.
- If you still choose a net-new implementation after researching, be prepared to explain briefly why the existing repo code or available libraries were not a good fit.

## Test-Driven Development
- Treat test-driven development as the default workflow for behavior-changing code when practical.
- Use a RED / GREEN / REFACTOR loop by default:
  - RED: add or update a test that captures the intended behavior or reproduces the bug, and confirm it fails for the expected reason.
  - GREEN: implement the smallest change needed to make the test pass.
  - REFACTOR: improve clarity or structure while keeping the tests green.
- For bug fixes, start with a reproducing test when practical.
- TDD is a strong default, not an absolute mandate. For docs-only work, config-only changes, exploratory spikes, one-off operational fixes, or tasks with no practical test seam yet, state why test-first was not realistic.
- When behavior changed but test-first was not realistic, add the best available automated coverage before merge unless the limitation is explicit and accepted.

## Verification Loop
- Run the Verification Loop before opening a PR, asking for review, or reporting substantive work as done. During longer sessions, also run the relevant parts of the loop after significant refactors or major behavior changes.
- Use the project's documented commands from `agent-vault/project-commands.md` when available.
- Apply the loop in order, skipping only steps that do not exist or do not matter for the repo or change:
  - Build / package: confirm the changed artifact can be produced when the repo has a build, bundle, or packaging step.
  - Typecheck / static analysis: run compiler, type-system, or equivalent static checks when the repo uses them.
  - Lint / format validation: run lint or formatting validation when the repo uses them.
    If no lint or format tooling is configured, check whether that gap is documented in `agent-vault/coding-standards.md` or in an accepted decision record referenced from `agent-vault/decision-log.md`.
    If it is not documented, the final summary or PR body MUST state that lint/format validation was unavailable or unconfigured and recommend adding tooling or documenting the intentional gap.
  - Tests / coverage: run the most relevant automated tests for the changed behavior, and include coverage checks when the repo tracks them.
  - Security / secrets review: run applicable dependency, secret, or security-sensitive checks when the change touches auth, permissions, external inputs, shell execution, CI/workflows, infrastructure, or secret handling.
  - Diff review: inspect the final diff against the base branch for unintended edits, leftover debug code, documentation drift, and missing `agent-vault` metadata updates.
- If a step fails, fix the issue and rerun the relevant parts of the loop before proceeding.
- If a step is unavailable or not meaningful for the repo, explicitly say so in the final summary or PR body instead of implying it ran.

## Code Style
- Follow the primary language, framework, and toolchain guidance recorded in `agent-vault/coding-standards.md`.
- If the repo has one dominant implementation language, prefer that language and its native tooling unless the task clearly requires otherwise.
- Use meaningful variable names and avoid abbreviations.
- Add comments only when the "why" is not obvious from the code.

## Git
- Write concise commit messages in imperative mood.
- Keep commits atomic: one logical change per commit.

## PR Authoring Standards
- When creating a pull request, include a complete PR body; do not open with a one-line summary only.
- Use an imperative, outcome-focused title that reflects the actual change scope.
- Do not prefix PR titles with agent or client identifiers such as `[codex]`, `[claude]`, or `[agent]` unless the repository explicitly requires that format.
- Keep PR scope coherent; split unrelated work into separate PRs.
- Prefer opening as draft until validation is complete, unless the user asks otherwise.
- PR body must include:
  - Summary of problem and approach.
  - Files/areas changed with concise rationale.
  - Verification Loop evidence (commands run, outcomes, and any skipped or not-applicable steps).
  - Risks, rollback considerations, and any residual gaps.
  - Explicit docs consistency note (`design.md`/`README.md` updated or no impact).
- If any Verification Loop step was not run, explicitly state why and what remains unverified.
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

## Artifact Ordering Rules
Use the canonical ordering for each artifact type below instead of guessing based on recency alone.

| Artifact | Ordering rule |
| --- | --- |
| `agent-vault/context-log.md`, `agent-vault/lessons.md` | Newest entry at top. |
| `agent-vault/decision-log.md` | Newest active or changed decisions at top. |
| `agent-vault/daily/YYYY-MM-DD.md` | Chronological within the day. Append new same-day work at the bottom. |
| `agent-vault/design-log/` notes | One file per substantive session. Read the newest 3 notes first during session start. |
| `agent-vault/context/handoffs/` notes | Read the note referenced by the latest `context-log.md` entry first; otherwise read the most recent handoff note. |

## Template Usage Rules
- Use the bootstrap files in place. Do not create duplicate `README.md`, `plan.md`, `coding-standards.md`, `context-log.md`, `open-questions.md`, or `decision-log.md` notes elsewhere.
- In committed memory artifacts, prefer repo-relative paths and portable command examples such as `agent-vault/...`, `docs/...`, `./scripts/...`, or `<repo-root>/...`. Machine-specific absolute paths such as `/Users/...`, `/home/...`, or `C:\...` are acceptable only when the local path itself is relevant debugging or environment context.
- Create or update `agent-vault/daily/YYYY-MM-DD.md` on the first substantive work session of each local day. Reuse the same file for later sessions that day. Skip daily notes for trivial one-off requests.
- Add a design-log note for every substantive work session.
- When a durable decision is made about architecture, workflow, API shape, data model, deployment, or tool policy, create a decision record in `agent-vault/decisions/` and add it to `agent-vault/decision-log.md`.
- When handing off or pausing with meaningful unfinished work, create a handoff note in `agent-vault/context/handoffs/`, include a `Suggested Next Prompt`, and reference that note from `agent-vault/context-log.md`.
- Use the standalone handoff prompt template only when a human explicitly asks for a copy-paste prompt. Otherwise keep the prompt inside the handoff note and the latest `context-log.md` entry.
- Use `agent-vault/context/scratchpad.md` only for temporary notes. Move durable state, decisions, and open questions into canonical files before finishing.

## Memory Size Budgets & Compaction
Always-on memory is paid on every session and re-paid after every compaction, so keep it lean; treat budget overflow as a defect rather than cosmetic. The `scripts/check-memory-budget.sh` and `scripts/check-context-log-rollover.sh` checkers are installed in each project's `scripts/` (seeded by `new-project.sh`, refreshed by `update-project.sh`); run them to apply the conventions below, and the pre-commit hook surfaces a non-blocking budget warning when memory files are staged.
- Budget buckets (reported by `scripts/check-memory-budget.sh`): the Claude `@`-import chain (from `CLAUDE.md`) and the Gemini `@`-import chain (from `GEMINI.md`), budgeted separately because a session loads one chain not the union; the Codex `AGENTS.md` chain (all `AGENTS.md` files, informational against Codex `project_doc_max_bytes`); and protocol-read files (named by session start; read, not auto-imported). Sizes are bytes. Defaults: per-file 40000 bytes (mirrors the Claude Code memory-file warning), per `@`-chain 120000 bytes; a repo can override budgets and file sets in a committed `agent-vault/memory-budget.config`.
- Relocate, never delete. When a memory file is over budget, move historical, closed, superseded, or low-frequency content into a load-on-demand `docs/` file (or dated archive) and leave a one-line pointer that names the destination, a grep anchor, and a "read when ..." trigger. Nothing leaves the repo; it only stops loading every turn.
- Keep the rule, archive the story. When archiving a still-applicable rule or lesson, keep its one-line rule in the always-on file and move the full write-up to the archive.
- Preserve active invariants. Never archive current runtime behavior as if it were closed-issue history. A narrative file may stay above its per-file budget as a documented exception when shrinking it further would delete a live invariant; record the file and reason in an exceptions file (a `path<TAB>reason` list referenced by `exceptions=` in the config or `--exceptions`) so the budget report prints why.
- Roll over `context-log.md` instead of letting it grow: keep exactly one `## Current Snapshot` plus a recent-entries window, move older entries into `agent-vault/context/archive/context-log-YYYY.md`, label any archived snapshot superseded, and validate with `scripts/check-context-log-rollover.sh`. Prefer `scripts/compact-context-log.sh` to perform the rollover atomically (it self-validates against that checker and aborts with no writes if the gate-required session entry is missing or any precondition fails). The compactor fails closed on an archive that carries its own frontmatter `covers:` field or relocation manifest — it cannot keep that header in sync, so roll those archives over manually, or pass `--allow-stale-archive-metadata` and update the header by hand. When rolling over manually, finalize the durable descriptions (archive boundary, kept/archived counts) *after* the gate-required session entry is in place; name the boundary by topic or recent-window position rather than a bare timestamp (two same-day entries can share a minute); and cite the stable rolled size with a `~` rather than an exact live byte total (it drifts on the next edit). Keep the live pointer's boundary and the archive's own frontmatter/manifest pointing at the same actual newest archived entry.
- Classify each archived `lessons.md` entry in `agent-vault/context/archive/lessons-manifest.md` as retained-as-quick-rule, covered-by-a-named-always-on-rule (name it), or archival-only with low recurrence risk, and validate with `scripts/check-lessons-archive.sh`.
- Bounded session-start read: read the context log's Current Snapshot and recent entries; consult `agent-vault/context/archive/` only when researching older or closed work.

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
  - `agent-vault/context-log.md` (its Current Snapshot and recent entries; consult `agent-vault/context/archive/` only when researching older or closed work)
  - `agent-vault/plan.md`
  - `agent-vault/coding-standards.md`
  - `agent-vault/project-context.md`
  - `agent-vault/project-commands.md`
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
- If a material trade-off remains unresolved, keep the options, recommendation, and default path visible in `agent-vault/open-questions.md` until the owner accepts a final path.
- If a durable decision was made, create or update the corresponding decision record and `agent-vault/decision-log.md`.
- If handing off, add a note in `agent-vault/context/handoffs/`.
- If the user corrected a mistake during this session, add an entry to `agent-vault/lessons.md` describing the mistake pattern and a preventive rule.
- Before creating a commit for substantive work, make sure today's daily note, context log, and any new design-log entry do not leave same-session publication mechanics (`git commit`, `git push`, PR creation) in `Carry Forward`, `Next`, or equivalent future-tense text unless those actions will truly remain unfinished after the session.
- Treat these updates as a commit gate for substantive work, not as optional cleanup after the code is already done.

## Direct Push to Main
- Direct push to `main` is acceptable only when the repo has explicitly opted into the tracked `pre-push` shortcut and the push records runtime `agent-vault` metadata only.
- Use direct metadata pushes to record history after a PR merge: what landed, current state, follow-ups, changed decisions, known risks, or cleanup notes.
- Do not use the shortcut for behavior-changing files. Source code, config, scripts, root docs, `agent-vault/README.md`, `plan.md`, `coding-standards.md`, `project-context.md`, `project-commands.md`, `handoff.md`, policy files, templates, and hook assets still require PR review.
- If a post-merge metadata refresh would be empty or ceremonial, skip it and say no metadata update was needed.

## Completion Verification - MUST follow before marking any task done
Before reporting a task as finished:
1. Run the Verification Loop appropriate to the repo and change scope.
2. List the `agent-vault` artifacts created or updated this session, or explicitly state why no metadata update was required (for example, a trivial one-off request).
3. Ask yourself: "Would a senior engineer approve this?" If not, fix it first.
4. If any Verification Loop step was unavailable or could not run, explicitly state what was checked and what remains unverified.

## Pre-Commit Checklist - MUST follow before every commit or patch application
Before considering any change complete and before running git commit:

1. Architecture / Design Document Check
- Read `docs/design.md` (or the project's main architecture/design document if named differently).
- Determine whether the proposed changes modify, add to, or invalidate any component, layer, data flow, boundary, interface, or architectural invariant described there.
- If yes: automatically propose and apply the corresponding updates to `docs/design.md` so it accurately reflects the new reality.
- If `agent-vault/project-context.md` contains substantive architecture or runtime guidance, automatically propose and apply the corresponding updates there too so agents do not load stale context on the next session.
- When diagrams are needed or updated, prefer Mermaid blocks in the Markdown document rather than screenshots or external image assets unless the project already uses another documented approach.
- If no: explicitly state in your reasoning: "No impact on docs/design.md detected."

2. README.md / User-Facing Documentation Check
- Scan the diff for changes to:
  - CLI commands or usage examples
  - Setup or installation instructions
  - Required environment variables
  - API endpoints, request/response shapes, authentication flows
  - Project folder structure or important file locations
- If setup, test, CLI, or operational commands are affected and `agent-vault/project-commands.md` contains substantive command guidance, propose and apply the corresponding updates there too.
- If any of the above are affected: propose and apply corresponding updates to `README.md` (or `CONTRIBUTING.md` / `docs/usage.md` if more appropriate).
- Keep changes concise, clear, and professionally formatted.

3. Hard Rule - Documentation MUST be consistent
- Do not finalize, commit, or present a patch until both checks above are complete and documentation files are updated if needed.
- If documentation updates are required but blocked (missing info, ambiguity), ask for clarification instead of proceeding.
- In the final response or patch summary, include one of these statements:
  - "Documentation is consistent - design.md and README.md were checked and need no changes."
  - "Updated docs/design.md to reflect new [component/flow]."
  - "Updated README.md: added/edited [specific section]."

4. Agent-Vault Metadata Gate
- For substantive work, do not run `git commit` until the staged diff includes:
  - `agent-vault/context-log.md`
  - one daily note in `agent-vault/daily/`
  - one session note in `agent-vault/design-log/`
- Also stage any conditionally required artifacts from this session:
  - `agent-vault/open-questions.md` when unresolved items remain
  - `agent-vault/decision-log.md` plus the decision record when a durable decision was made
  - `agent-vault/context/handoffs/` when handing off unfinished work
  - `agent-vault/lessons.md` when a corrected mistake should become a durable prevention rule
- If the repo enables the tracked hooks under `agent-vault/_assets/hooks/`, keep them enabled via `git config core.hooksPath agent-vault/_assets/hooks`.
- If a change is truly trivial and should not update project memory, make that an explicit decision and say so in your final summary instead of silently skipping the metadata step.

## Additional Guardrails
- Prefer explicit diffs over whole-file rewrites when updating docs.
- Use the same tone and markdown style already present in the docs files.
- If running in full-auto mode, still pause and show documentation-related diffs separately for review unless `--ask-for-approval=never` is explicitly set.

These rules override any conflicting default behaviors.

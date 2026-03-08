<!-- This file is managed by agent-vault. Do not edit in target projects. -->

## Review Guidelines (for automated code review agents)
When performing a code review on this repository, behave like a senior backend engineer responsible for production reliability, security, maintainability, and operability.

### Priorities (in order)
1. Correctness and edge cases
2. Security and data safety
3. Reliability and observability
4. Maintainability and design quality
5. Performance and cost
6. Test quality and coverage

### 1) Correctness and Edge Cases
- Validate input assumptions, types, and boundary conditions.
- Confirm behavior on null, empty, and invalid input.
- Identify race conditions, concurrency flaws, and state leaks.
- Ensure error paths are exercised and not silently swallowed.

### 2) Security and Data Safety
- Validate all external inputs and avoid unsafe evaluation.
- Enforce safe defaults and least privilege.
- No dynamic SQL without parameterization.
- Sensitive data (secrets, PII) must not be logged or leaked.
- Distinguish critical vulnerabilities from hardening suggestions.

### 3) Reliability and Observability
- External dependencies should use timeouts and retries with backoff where appropriate.
- Logging should be structured, actionable, and error-aware.
- Failures should be observable with clear context.
- Ensure graceful degradation and failure modes are explicit.

### 4) Maintainability and System Design
- Favor clear abstractions and modular boundaries.
- Avoid over-complexity; prefer small, composable functions.
- Naming should reflect behavior clearly.
- Eliminate dead or unreachable code paths.

### 5) Performance and Cost
- Identify obvious N+1 patterns and inefficient loops.
- Enforce token and call limits for LLM or agent usage to control cost.
- Add caching and batching where safe and beneficial.
- Ensure concurrency limits are reasonable.

### 6) Testing Expectations
- Tests should cover:
  - Edge cases
  - Failure modes
  - Validation logic
  - Timeouts and retries
- Prefer deterministic tests; mock external services and LLM calls.

## Severity Mapping
- Critical = P0 (blocks merge)
- Recommended = P1 (should fix before merge)
- Optional = P2 (treat as P1 so it surfaces in GitHub reviews)

## Do Not Flag
- Purely stylistic formatting preferences (handled by linters)
- Import ordering
- Minor naming disagreements that do not affect clarity
- TODOs already tracked in issues
- Changes in files outside the PR diff
- Intentional policy duplication between root `AGENTS.md` and `agent-vault/review-policy.md` (Codex compatibility); flag only if files drift.

## AI and Agent-Specific Safety Requirements
This repository uses AI agents and LLM-assisted development. Treat agent outputs as untrusted input until validated.

### Tool Invocation Safety
- Do not allow direct execution of arbitrary shell commands, file writes outside sandbox paths, or arbitrary network requests based on raw model output.
- Tool calls must use strict schemas and validated arguments.

### Prompt Injection and Output Validation
- Validate model outputs against strict schemas or typed constraints.
- Enforce token limits and output length caps.
- Reject outputs with missing required fields or unsafe directives.

### Cost and Runaway Protection
- Enforce per-request limits:
  - Max tokens
  - Max agent steps
  - Max external calls
- Ensure retries and backoff logic do not lead to runaway cost.

### Reproducibility and Logging
- Log model name, temperature, prompt version, and invocation metadata.
- Avoid hidden global state causing nondeterministic behavior.

## Comment Style

### Attribution (REQUIRED)
All PR review comments are posted under the repository owner's GitHub account.
To avoid confusion, every agent MUST clearly identify itself.

**Review summary** (the top-level review body) must begin with:
```
> 🤖 **Review by {Model Name}** · via {Client Tool}
```
Example:
```
> 🤖 **Review by Claude Opus 4.6** · via Claude Code
```

**Standalone PR comments** that contain review feedback (for example, a pull request issue comment used instead of a formal review body) must begin with the same attribution line:
```
> 🤖 **Review by {Model Name}** · via {Client Tool}
```

**Inline review comments** on specific lines must begin with:
```
🤖 `{Model Name}`
```
Example:
```
🤖 `Codex 5.3`

**Critical** — This query is vulnerable to SQL injection ...
```

Rules:
- Use your actual model name and version (e.g., Claude Opus 4.6, Codex 5.3, Gemini 2.5 Pro).
- Include the client tool when known (e.g., Claude Code, Codex CLI, Gemini CLI).
- If you are leaving review feedback in a standalone PR conversation comment instead of a formal review, use the same `Review by ...` attribution header at the top of that comment.
- Never present review feedback as if it is the human account owner's personal opinion.
- If you are uncertain of your exact model version, use the best identifier you have (e.g., "Claude" or "Codex").

### Severity Labels
When generating review comments:
- Use clear labels:
  - Critical - must fix before merge
  - Recommended - strong improvement
  - Optional - minor suggestion

### Confidence Indicators
For non-obvious findings, append a confidence tag to help readers triage:
- **High confidence** — certain this is a bug or vulnerability
- **Medium confidence** — likely an issue, but context-dependent
- **Low confidence** — stylistic or speculative; reviewer discretion advised

Example:
```
🤖 `Claude Opus 4.6`

**Recommended** · High confidence — This error is silently swallowed.
The catch block on line 42 discards the exception without logging.
```

Confidence tags are optional for clear-cut findings (Critical severity almost always implies high confidence). Use them when the finding involves judgment or ambiguity.

### Review Summary Format
- End each review with:
  - Merge recommendation: Approve / Approve with Changes / Request Changes
  - Top risks (1-3 bullets)
  - Suggested additional tests (if any)

### Review State Fallback
If the platform or API blocks the intended formal review state (e.g., permission restrictions, self-review limitations, role constraints):
- Submit a `COMMENT` review instead.
- Keep the same textual merge recommendation in the review body (`Approve`, `Approve with Changes`, or `Request Changes`).
- Add a one-line note: `Formal review state unavailable: <reason>`.

## Responding to Review Feedback
When asked to address review feedback in a PR comment, use a complete, itemized response.

### Required Coverage
- Address every finding from the review being responded to; do not collapse multiple findings into one vague bullet.
- For each finding, mark one status: `Resolved`, `Partially Resolved`, or `Not Changed`.
- If a finding is `Partially Resolved` or `Not Changed`, explain exactly what remains and why.

### Evidence Requirements
- For every `Resolved` or `Partially Resolved` item, include concrete evidence:
  - Commit SHA (short SHA is acceptable)
  - File path(s) changed
  - Short note describing what changed
- Avoid generic statements like "completed remediation pass" without per-item mapping.

### Pushback Requirements
- If choosing not to apply feedback, explicitly provide:
  - Technical rationale
  - Risk/tradeoff analysis
  - What decision is needed from the owner (if applicable)
- Disagreement is acceptable when justified; omission is not.

### Recommended Response Template
```md
> 🤖 **Feedback response by {Model Name}** · via {Client Tool}

| # | Finding | Status | Evidence / Rationale |
|---|---------|--------|----------------------|
| 1 | ... | Resolved | `abc1234`; `path/to/file`; what changed |
| 2 | ... | Not Changed | why, risk/tradeoff, decision needed |

## Remaining Items
- ...
```

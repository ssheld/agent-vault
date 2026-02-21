# AGENTS.md
<!-- agent-vault-managed: root-wrapper; file=AGENTS.md -->

## Scope
- These review guidelines apply only when performing pull request code review.
- For implementation workflow, handoffs, and shared project memory, also follow `agent-vault/AGENTS.md`.

## Local Agent Workflow
Project agent rules are defined in `agent-vault/AGENTS.md`.
Read that file before making changes.

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
When generating review comments:
- Use clear labels:
  - Critical - must fix before merge
  - Recommended - strong improvement
  - Optional - minor suggestion
- End each review with:
  - Merge recommendation: Approve / Approve with Changes / Request Changes
  - Top risks (1-3 bullets)
  - Suggested additional tests (if any)

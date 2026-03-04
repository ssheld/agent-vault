# Coding Standards

## Scope Note
- This repository may begin in a planning-first state before application code exists.
- During planning-first work, test expectations focus on documentation consistency and command-level verification.
- Once application code exists, full behavior-level tests become required for changed paths.

## Core Principles
- Prefer simple, testable designs.
- Keep changes minimal and coherent.
- Preserve backward compatibility unless explicitly planned.

## Language and Framework Conventions
- Naming:
  - Use explicit, domain-oriented names over abbreviations.
  - Match terms used in `plan.md`, `README.md`, and user-facing docs.
- Error handling:
  - Prefer explicit failure states over silent fallbacks.
  - Document any temporary workaround and track it in `open-questions.md`.
- Logging:
  - Keep logs actionable, structured when possible, and include failure context.
  - Record meaningful workflow/architecture changes in `context-log.md`.
- Performance expectations:
  - Prioritize correctness and maintainability first.
  - Add explicit performance budgets once critical paths are identified.

## Testing Standards
- Required test levels:
  - Planning-first phase: documentation consistency checks and command-level validation.
  - Implementation phase: unit/integration/smoke tests appropriate to changed behavior.
- Minimum coverage expectations:
  - Add automated tests for each behavior change once code exists.
  - Keep critical-path regressions covered before merge.
- Required regression tests:
  - This section applies once application code exists.
  - Any changed user-facing flow.
  - Any changed integration boundary (API, DB, queue, or external provider).
  - Error handling and retry behavior for new failure modes.

## Review Checklist
- [ ] Matches project architecture and naming conventions.
- [ ] Includes tests for changed behavior (or explicitly documents why not yet applicable in planning-only work).
- [ ] Updates docs/context when behavior changes.
- [ ] No unrelated changes.

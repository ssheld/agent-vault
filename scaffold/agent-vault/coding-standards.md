# Coding Standards

## Scope Note
- This repository may begin in a planning-first state before application code exists.
- During planning-first work, test expectations focus on documentation consistency and command-level verification.
- Once application code exists, full behavior-level tests become required for changed paths.

## Core Principles
- Prefer simple, testable designs.
- Keep changes minimal and coherent.
- Preserve backward compatibility unless explicitly planned.

## Readability Defaults
- Until the project records stricter or different preferences here, treat the following as the default readability baseline.
- Prefer explicit, readable structure over compact or clever code when the compact version is harder to follow.
- Avoid high-density control flow such as nested ternaries when a clearer alternative exists.
- Remove comments that only restate what the code already makes obvious.
- Keep useful abstractions, but remove accidental or redundant ones when doing so clarifies the code without widening scope.

## Language and Framework Conventions
- Primary language/runtime:
  - Record the repo's default implementation language(s) and major runtime/toolchain here.
  - Agents should treat this as the source of truth when choosing languages, frameworks, and tooling for new code.
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
- Default workflow:
  - For behavior-changing code, follow RED / GREEN / REFACTOR when practical.
  - For bug fixes, start with a reproducing test when practical.
  - If test-first is not realistic for the task, document why and add the best available automated coverage before merge when behavior changed.
- Required test levels:
  - Planning-first phase: documentation consistency checks and command-level validation.
  - Implementation phase: unit/integration/smoke tests appropriate to changed behavior.
- Minimum coverage expectations:
  - Add automated tests for each behavior change once code exists.
  - Keep critical-path regressions covered before merge.
  - Set project-specific numeric coverage targets here when needed.
  - If the repo has practical automated coverage tooling and no project-specific threshold is recorded here, use `>=80%` coverage as the default floor.
  - If numeric coverage is not meaningful for the repo or toolchain, document the alternative expectation explicitly and treat meaningful automated coverage of changed behavior as required.
- Required regression tests:
  - This section applies once application code exists.
  - Any changed user-facing flow.
  - Any changed integration boundary (API, DB, queue, or external provider).
  - Error handling and retry behavior for new failure modes.

## Review Checklist
- [ ] Matches project architecture and naming conventions.
- [ ] Keeps code readable without relying on dense or clever control flow.
- [ ] Includes tests for changed behavior (or explicitly documents why test-first or automated coverage was not yet practical).
- [ ] Updates docs/context when behavior changes.
- [ ] No unrelated changes.

---
type: coding-standards
project:
last_updated:
---

# Coding Standards

## Core Principles
- Prefer simple, testable designs.
- Keep changes minimal and coherent.
- Preserve backward compatibility unless explicitly planned.

## Readability Defaults
- Set project-specific readability preferences here. Until you replace them, the scaffold assumes:
  - prefer explicit, readable structure over compact or clever code when the compact version is harder to follow
  - avoid high-density control flow such as nested ternaries when a clearer alternative exists
  - remove comments that only restate what the code already makes obvious
  - keep useful abstractions, but remove accidental or redundant ones when doing so clarifies the code without widening scope

## Language and Framework Conventions
- Naming:
- Error handling:
- Logging:
- Performance expectations:

## Testing Standards
- Required test levels:
- Minimum coverage expectations:
- Required regression tests:

## Review Checklist
- [ ] Matches project architecture and naming conventions.
- [ ] Keeps code readable without relying on dense or clever control flow.
- [ ] Includes tests for changed behavior.
- [ ] Updates docs/context when behavior changes.
- [ ] No secrets, generated noise, or unrelated changes.

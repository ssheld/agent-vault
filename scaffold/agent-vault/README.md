---
type: project-home
project: __PROJECT_SLUG__
repo_reference: __REPO_REFERENCE__
status: active
owner: tbd
last_updated: __DATE__
---

# __PROJECT_NAME__

## Objective
Deliver project milestones with clear scope, verifiable outcomes, and reliable handoffs across sessions.

## Success Criteria
- Milestone 1 scope and exit criteria are documented in `agent-vault/plan.md`.
- Current priorities and session state are current in `agent-vault/context-log.md`.
- Active decisions and open questions are current in `agent-vault/decision-log.md` and `agent-vault/open-questions.md`.
- Material trade-offs are either owner-approved or explicitly tracked as pending decisions.
- Architecture and key flows are current in `docs/design.md`.
- Completion checks are defined before implementation starts.

## Scope
- In scope:
  - Planning and implementation work tracked in this repository.
  - Documentation updates needed to keep behavior and design artifacts aligned.
  - Surfacing material trade-offs to a human owner before they become durable project policy.
- Out of scope:
  - Project memory stored outside `agent-vault/`.
  - Untracked process changes without decision/open-question updates.

## Decision Gate
- Humans are the default decision-makers for material trade-offs involving architecture, UX, workflow, security, performance, cost, maintainability, or future flexibility.
- Pending owner decisions belong in `agent-vault/open-questions.md`.
- `proposed` decision records remain non-binding until the owner explicitly accepts them.
- `accepted` decision records should preserve approval provenance in the file (`owners`, `accepted_by`, and `approval_source`) before future sessions treat them as a gate bypass.

## Links
- Repo: __REPO_REFERENCE__
- Board: TBD
- Docs: `docs/design.md`, `agent-vault/plan.md`, `agent-vault/context-log.md`, `agent-vault/open-questions.md`, `agent-vault/decision-log.md`

## Active Work
- Current focus: Define milestone scope and begin implementation backlog.
- Current branch: `__ACTIVE_BRANCH__`
- Next milestone: Milestone 1 - Baseline setup and first deliverable.

## Working Files
- Design doc: `docs/design.md`
- Plan: `agent-vault/plan.md`
- Coding standards: `agent-vault/coding-standards.md`
- Project context: `agent-vault/project-context.md`
- Project commands: `agent-vault/project-commands.md`
- Context log: `agent-vault/context-log.md`
- Open questions: `agent-vault/open-questions.md`
- Decision log: `agent-vault/decision-log.md`
- Daily notes folder: `agent-vault/daily/`
- Design log folder: `agent-vault/design-log/`
- Handoffs folder: `agent-vault/context/handoffs/`

#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 <project-name> [repo-path]"
  echo "Example: $0 payments-api /Users/you/workspaces/payments-api"
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

project_name="$1"
repo_path="${2:-}"

slug="$(echo "$project_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-_')"
if [[ -z "$slug" ]]; then
  echo "Error: project slug is empty after normalization."
  exit 1
fi

project_dir="01_Projects/$slug"
if [[ -e "$project_dir" ]]; then
  echo "Error: project directory already exists: $project_dir"
  exit 1
fi

mkdir -p \
  "$project_dir/_assets" \
  "$project_dir/context/handoffs" \
  "$project_dir/design-log" \
  "$project_dir/decisions"

touch "$project_dir/_assets/.gitkeep"
touch "$project_dir/context/handoffs/.gitkeep"
touch "$project_dir/design-log/.gitkeep"
touch "$project_dir/decisions/.gitkeep"

today="$(date '+%Y-%m-%d')"
now="$(date '+%Y-%m-%d %H:%M')"

cat > "$project_dir/README.md" <<EOF
---
type: project-home
project: $slug
repo_path: $repo_path
status: active
owner:
last_updated: $today
---

# $project_name

## Objective

## Success Criteria

## Scope
- In scope:
- Out of scope:

## Links
- Repo: $repo_path
- Board:
- Docs:

## Active Work
- Current focus:
- Current branch:
- Next milestone:

## Working Files
- Plan: \`plan.md\`
- Coding standards: \`coding-standards.md\`
- Context log: \`context-log.md\`
- Design log folder: \`design-log/\`
- Handoffs folder: \`context/handoffs/\`
EOF

cat > "$project_dir/context-log.md" <<EOF
---
type: context-log
project: $slug
last_updated: $today
---

# Context Log

## Usage Rules
- Newest entry at top.
- Keep entries short and concrete.
- Reference files and PRs instead of pasting long diffs.
- Pair each major update with a design-log entry.
- Add a handoff note when switching agents or ending a session.

## Current Snapshot
- Project: $project_name
- Primary goal:
- Current status:
- Active branch:
- Last updated: $today

## Entries

### $now local - bootstrap - initial project setup
#### Goal
Create a standardized project note set for multi-agent development.

#### State
- Created project workspace in \`01_Projects/$slug/\`.
- Added project home, context log, plan, coding standards, and open questions.
- Added session tracking via \`design-log/\`, \`context/handoffs/\`, and \`context/scratchpad.md\`.

#### Decisions
- Use this context log as the canonical cross-agent memory for this project.
- Keep session artifacts separate from canonical memory for easier scanning.

#### Open Questions
- None yet.

#### Next Prompt
"Read \`01_Projects/$slug/context-log.md\` and continue the current implementation task."

#### References
- \`01_Projects/$slug/README.md\`
- \`01_Projects/$slug/context-log.md\`
- \`01_Projects/$slug/plan.md\`
- \`01_Projects/$slug/coding-standards.md\`
EOF

cat > "$project_dir/decision-log.md" <<EOF
# Decision Log

Use one note per decision in \`decisions/\` and keep this file as an index.

## Index
- DEC-001 -
- DEC-002 -
EOF

cat > "$project_dir/open-questions.md" <<EOF
# Open Questions

## Blocking
- [ ] Question:
  - Why it matters:
  - Owner:
  - Due:

## Non-Blocking
- [ ] Question:
  - Why it matters:
  - Owner:
  - Due:
EOF

cat > "$project_dir/plan.md" <<EOF
# Project Plan

## Objective

## Milestones
1. Milestone:
   - Exit criteria:
   - Target date:
2. Milestone:
   - Exit criteria:
   - Target date:

## Active Phase
- Current phase:
- Focus this week:

## Risks and Dependencies
- Risk:
  - Impact:
  - Mitigation:

## Next 3 Tasks
1.
2.
3.
EOF

cat > "$project_dir/coding-standards.md" <<EOF
# Coding Standards

## Core Principles
- Prefer simple, testable designs.
- Keep changes minimal and coherent.
- Preserve backward compatibility unless explicitly planned.

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
- [ ] Includes tests for changed behavior.
- [ ] Updates docs/context when behavior changes.
- [ ] No unrelated changes.
EOF

cat > "$project_dir/context/scratchpad.md" <<EOF
# Scratchpad

Working memory for temporary notes. Move lasting information into:
- \`context-log.md\`
- \`design-log/\`
- \`decisions/\`
- \`open-questions.md\`
EOF

cat > "$project_dir/design-log/README.md" <<EOF
# Design Log

Add one short note per meaningful work session.

Suggested filename:
- \`$today-<topic>.md\`
EOF

cat > "$project_dir/context/handoffs/README.md" <<EOF
# Handoffs

Use this folder for agent-to-agent handoff notes.

Suggested filename:
- \`$today-<from>-to-<to>-<topic>.md\`
EOF

cat > "$project_dir/decisions/README.md" <<EOF
# Decisions

Use one note per significant decision.

Suggested filename:
- \`DEC-001-<title>.md\`
EOF

cat > "$project_dir/design-log/$today-bootstrap.md" <<EOF
# $today - bootstrap

## Agent
bootstrap

## Scope
Project notes initialization.

## What Was Done
- Created baseline project memory and workflow files.

## Why
- Ensure consistent handoffs across multiple agents.

## Open Issues
- Fill initial milestones in \`plan.md\`.
- Fill initial standards in \`coding-standards.md\`.
EOF

cat > "$project_dir/handoff.md" <<EOF
# Agent Handoff

Use this when switching between agents.

## Prompt
\`\`\`
You are continuing work on $project_name.
Read these files first:
- 01_Projects/$slug/README.md
- 01_Projects/$slug/context-log.md
- 01_Projects/$slug/plan.md
- 01_Projects/$slug/coding-standards.md
- 01_Projects/$slug/open-questions.md

Task:
<what needs to be done now>

Constraints:
<technical, product, and timeline constraints>

Before finishing:
- Update context-log with Goal, State, Decisions, Open Questions, Next Prompt, References.
- Add a design-log entry in 01_Projects/$slug/design-log/.
- If handing off, add a note in 01_Projects/$slug/context/handoffs/.
\`\`\`
EOF

echo "Created project notes at: $project_dir"

#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 <project-name> <repo-path>"
  echo "Example: $0 payments-api ~/workspaces/payments-api"
}

if [[ $# -ne 2 ]]; then
  usage
  exit 1
fi

project_name="$1"
repo_path_input="$2"

expand_path() {
  local p="$1"
  case "$p" in
    "~")
      printf '%s\n' "$HOME"
      ;;
    "~/"*)
      printf '%s/%s\n' "$HOME" "${p#~/}"
      ;;
    "/~/"*)
      # Common typo: /~/path should usually be ~/path.
      printf '%s/%s\n' "$HOME" "${p#/~/}"
      ;;
    *)
      printf '%s\n' "$p"
      ;;
  esac
}

repo_path="$(expand_path "$repo_path_input")"
if [[ "$repo_path_input" == /~/* ]]; then
  echo "Warning: interpreted '$repo_path_input' as '$repo_path'." >&2
fi

if [[ ! -d "$repo_path" ]]; then
  echo "Error: repo path does not exist: $repo_path"
  exit 1
fi

canonical_repo_path="$(cd "$repo_path" && pwd -P)"
project_dir="$canonical_repo_path/agent-vault"

if [[ -e "$project_dir" ]]; then
  echo "Error: destination already exists: $project_dir"
  exit 1
fi

slug="$(echo "$project_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-_')"
if [[ -z "$slug" ]]; then
  echo "Error: project slug is empty after normalization."
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
template_root="$(cd "$script_dir/.." && pwd -P)"
scaffold_dir="$template_root/scaffold/agent-vault"

if [[ ! -d "$scaffold_dir" ]]; then
  echo "Error: scaffold source not found: $scaffold_dir"
  exit 1
fi

cp -R "$scaffold_dir" "$project_dir"

today="$(date '+%Y-%m-%d')"
now="$(date '+%Y-%m-%d %H:%M')"

export PROJECT_NAME="$project_name"
export PROJECT_SLUG="$slug"
export REPO_PATH="$canonical_repo_path"
export TODAY="$today"
export NOW="$now"

while IFS= read -r -d '' file; do
  if [[ "$(basename "$file")" == ".gitkeep" ]]; then
    continue
  fi

  perl -0pi -e 's/__PROJECT_NAME__/$ENV{PROJECT_NAME}/g; s/__PROJECT_SLUG__/$ENV{PROJECT_SLUG}/g; s/__REPO_PATH__/$ENV{REPO_PATH}/g; s/__DATE__/$ENV{TODAY}/g; s/__DATETIME__/$ENV{NOW}/g;' "$file"
done < <(find "$project_dir" -type f -print0)

root_agents="$canonical_repo_path/AGENTS.md"
if [[ -e "$root_agents" ]]; then
  echo "Notice: $root_agents already exists; left unchanged." >&2
else
  cat > "$root_agents" <<'AGENTS_EOF'
# AGENTS.md

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
AGENTS_EOF
fi

root_claude="$canonical_repo_path/CLAUDE.md"
if [[ -e "$root_claude" ]]; then
  echo "Notice: $root_claude already exists; left unchanged." >&2
else
  cat > "$root_claude" <<'CLAUDE_EOF'
# CLAUDE.md

Project agent rules are defined in `agent-vault/CLAUDE.md`.
Read that file before making changes.
CLAUDE_EOF
fi

root_gemini="$canonical_repo_path/GEMINI.md"
if [[ -e "$root_gemini" ]]; then
  echo "Notice: $root_gemini already exists; left unchanged." >&2
else
  cat > "$root_gemini" <<'GEMINI_EOF'
# GEMINI.md

Project agent rules are imported from `agent-vault/GEMINI.md`.

@./agent-vault/GEMINI.md
GEMINI_EOF
fi

echo "Created project notes at: $project_dir"

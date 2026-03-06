# Design

This document is the default architecture and workflow reference for the project.
Keep it aligned with the current codebase.
Prefer Mermaid blocks embedded directly in Markdown so GitHub and Obsidian render diagrams without extra tooling.

## System Overview
- Replace the example sections below with the project's actual components, boundaries, and flows.
- Keep diagrams short and grounded in implemented behavior or explicitly planned work.

## Architecture
```mermaid
flowchart LR
  Client[Client] --> Entry[Entrypoint]
  Entry --> Core[Core Service]
  Core --> Store[(Primary Store)]
```

## Main Workflow
```mermaid
sequenceDiagram
  participant User
  participant App
  participant Store

  User->>App: Start request
  App->>Store: Read or write state
  Store-->>App: Return result
  App-->>User: Respond
```

## Data Flow
```mermaid
flowchart TD
  Input[Input] --> Process[Processing]
  Process --> State[(State)]
  Process --> Output[Output]
```

## Key Components
- Entrypoint:
- Core Service:
- Storage:

## Invariants
- Document the rules that should stay true even as implementation changes.

## Open Questions
- Track design uncertainties here or link to deeper docs when needed.

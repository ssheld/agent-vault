# Decisions

Use this folder for durable decisions that future work must honor.

Create a decision record when the project commits to an architecture, workflow, API, data model, deployment, or tool policy choice.
- Use `agent-vault/decision-log.md` as the primary index for discovery.
- Other docs may reference a decision when context is useful, but the decision log remains the canonical starting point.
- Suggested statuses: `proposed`, `accepted`, `superseded`, `deprecated`.
- `proposed` means an agent or human has recorded the decision, but owner review is still pending. It is not binding.
- `accepted` means the owner explicitly approved the decision. It is binding for future work and a valid human decision gate bypass only when the record preserves that approval provenance.
- Only explicit owner approval should transition a record from `proposed` to `accepted`, and accepted records should record approver/owners plus approval context or source in the file.

Suggested filename:
- `DEC-001-<slug>.md`

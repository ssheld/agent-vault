# Context-log growth experiment contract

This contract is fixed before running the Part B measurements for #145. Results
belong in `docs/memory-budgets.md`; do not tune the workload after seeing them.

Compare triggers 40,000 and 60,000 with target 30,000, identical initial log and
96 newest-first session entries per stream. Use the shared fixed test clock,
four-digit session IDs, and ASCII/UTF-8 body text. Body byte lengths are:

- Normal: `2048 + (session * 97) % 1024`.
- Burst: normal, except every twelfth session has 16,000 body bytes.
- Oversized: normal, except every twenty-fourth session has 35,000 body bytes.

These arithmetic sequences are deterministic (no random seed or external data).
Check after each append, invoke ordinary strict `--to-budget` on overage, and
continue appending after a no-write refusal. Never enable target overage in the
measurement. Also exercise a separate 33,000-byte snapshot fixture to demonstrate
mandatory-content infeasibility; it is not part of the normal workload.

Primary outcome: median additional session entries between successive successful
rollovers, excluding initial fill. Also report rollover/refusal counts, retained
byte and entry-count ranges, and min/max bytes of headroom to the next trigger.
Separate all three streams; exceptional refusals must not disappear into a
normal-workload aggregate.

Acceptance: the normal 60k/30k stream improves the median interval over 40k/30k
without target refusals. Every successful strict rollover must finish within
target, preserve each complete entry exactly once across live/archive history,
and preserve the snapshot and ordering. Refusals leave all outputs unchanged.
If the normal workload fails this bar, investigate the implementation/defaults
rather than redefining the workload. Synthetic evidence supports trial defaults,
not a claim that these values are optimal for real projects.

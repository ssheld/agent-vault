# Memory import contracts

This is deterministic checker test data, not project memory or instructions.
The regression suite copies the fixture into a temporary project. It must not
invoke clients or use the network.

## Claude baseline

Documentation retrieved 2026-09-08:
https://code.claude.com/docs/en/memory#import-additional-files

> Imported files can recursively import other files, with a maximum depth of four hops.
> Import parsing skips Markdown code spans and fenced code blocks.

Root depth is zero; files at depths 0–4 contribute bytes, but depth-four files
are not expanded. This supersedes the five-hop wording in issue #140.

Empirical probe: Claude Code **2.1.236**, 2026-09-08. In an isolated temporary
directory, with only project settings enabled, empty tools and MCP server sets,
no session persistence, and a one-turn/$0.01 guard, run the built-in `/context`
command in print/stream-json mode. Read the structured
`context_usage.memory_files[].path` list, not a model's recollection.
The successful command reports zero API duration, zero turns, and zero cost.
An `InstructionsLoaded` audit hook was configured, but the short-lived
`/context` invocation did not yield its asynchronous log; the structured
context inventory is the observation used here. A preliminary plain-prompt
probe with settings sources disabled did not load project memory and is not
contract evidence.

Command shape (run only deliberately, not by CI):

```sh
claude -p --max-budget-usd 0.01 --max-turns 1 --tools "" \
  --setting-sources project --strict-mcp-config \
  --mcp-config '{"mcpServers":{}}' --no-session-persistence --no-chrome \
  --output-format stream-json --verbose "/context"
```

For `claude/CLAUDE.md`, the observed included set is:

- `CLAUDE.md`
- `positive.md`, `inline-a.md`, `inline-b.md`
- `depth/one.md`, `depth/two.md`, `depth/three.md`, `depth/four.md`

Existing comment, code-span, fenced-example, and deeper targets were absent.
The inline and block HTML comment probes establish import exclusion for those
cases, not the client's internal processing order.

Additional isolated probes observed: imports in ordinary list/blockquote prose
load; indented code and fenced list/blockquote examples do not; an unmatched
inline backtick does not hide a following import; an HTML comment's closing-line
suffix may contain an active import; `@./hash.md#anchor` loads `hash.md`.
A trailing comma/period is not opportunistically removed, and parenthesis/
bracket-prefixed, backslash-escaped, and quoted-space references did not load
the corresponding punctuation-free targets. Unverified complex containers or
other syntax remain explicit scanner limitations, not inferred client behavior.

## Gemini baseline

Gemini CLI **v0.58.0**, commit
`ac9431c9e2290d68af31a77614ff2fddb2391ca3`, audited 2026-09-08:

- [Processor](https://github.com/google-gemini/gemini-cli/blob/ac9431c9e2290d68af31a77614ff2fddb2391ca3/packages/core/src/utils/memoryImportProcessor.ts)
- [Default tree format](https://github.com/google-gemini/gemini-cli/blob/ac9431c9e2290d68af31a77614ff2fddb2391ca3/packages/core/src/config/config.ts)
- [Documentation](https://geminicli.com/docs/reference/memport/)

Use the released tree processor, not an idealized Markdown parser: its tokens
start at a whitespace boundary, begin with a dot, slash, or ASCII letter, and
continue to whitespace. Its code-region matcher uses paired backtick runs;
tilde fences and HTML comments are not equivalent exclusions. The documentation's
`marked` claim differs from this source. Tree depth defaults to five: count
depth-five files without expanding them. Flat mode is not modeled.

These profiles describe selected root-entry import discovery and unique source
bytes, not the full client memory hierarchy or exact expanded-prompt size.

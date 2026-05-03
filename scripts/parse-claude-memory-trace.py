#!/usr/bin/env python3
"""Parse a Claude Code session JSONL trace and emit per-file memory-load evidence.

Reads a sentinel-manifest TSV (file column defines the universe of measured files)
and a Claude Code JSONL session trace, then emits a TSV with one row per
(agent_type, subagent_type, session_phase, file) cell observed in the trace.

Tool-read evidence is collected from `Read`, `Grep`, and `Bash` tool_use entries
on the main agent. The `/clear` boundary is detected from a user-role message
whose text contains the literal `<command-name>/clear</command-name>`.

Subagent observability gap (empirically verified across 44 local sessions):

- The current Claude Code JSONL records `Agent` tool invocations in the main
  agent's stream but does NOT record the subagent's internal tool calls.
- The field `isSidechain` is `false` or absent on every entry observed; no
  current entries surface as `isSidechain: true`.
- The Agent tool's `tool_result` contains only the subagent's final synthesized
  response, not its tool-call trace.

As a result, this parser can record that a subagent of a given `subagent_type`
was invoked, but cannot observe what files that subagent read. Subagent rows
are emitted with `tool_read=false`, `read_confidence=none`, and an explicit
note documenting the visibility gap. Future Claude Code versions that surface
sidechain tool calls would let this parser populate subagent reads via the
`isSidechain` branch already present in the code.

This parser intentionally does not infer auto-loaded startup context from the
JSONL: that information is not present.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
from collections import OrderedDict
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

CLEAR_MARKER = "<command-name>/clear</command-name>"
AGENT_TOOL_NAME = "Agent"

OUTPUT_COLUMNS = (
    "agent",
    "agent_type",
    "subagent_type",
    "session_phase",
    "cwd",
    "file",
    "tool_read",
    "read_confidence",
    "read_evidence",
    "first_read_event_index",
    "first_read_uuid",
    "notes",
)

BASH_HIGH_CONFIDENCE_COMMANDS = (
    "cat",
    "head",
    "tail",
    "less",
    "more",
    "bat",
    "nl",
)
BASH_MEDIUM_CONFIDENCE_COMMANDS = (
    "grep",
    "rg",
    "egrep",
    "fgrep",
    "awk",
    "sed",
    "sort",
    "uniq",
    "wc",
)
BASH_READ_LIKE_COMMANDS = BASH_HIGH_CONFIDENCE_COMMANDS + BASH_MEDIUM_CONFIDENCE_COMMANDS


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Emit a per-file memory-load evidence TSV from a Claude Code session "
            "JSONL trace and a sentinel manifest."
        )
    )
    parser.add_argument(
        "--jsonl",
        type=Path,
        help="Path to the Claude Code session JSONL file.",
    )
    parser.add_argument(
        "--session-id",
        help=(
            "Session id to resolve under ~/.claude/projects/<encoded-cwd>/<id>.jsonl. "
            "Requires --cwd."
        ),
    )
    parser.add_argument(
        "--cwd",
        type=Path,
        help="Cwd used when resolving --session-id. Required with --session-id.",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        required=True,
        help="Path to sentinel-manifest.tsv emitted by measure-agent-memory-load.sh.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Write TSV to this path instead of stdout.",
    )
    return parser.parse_args(argv)


def resolve_jsonl_path(session_id: str, cwd: Path) -> Path:
    encoded_cwd = str(cwd.resolve()).replace("/", "-")
    base = Path.home() / ".claude" / "projects" / encoded_cwd
    return base / f"{session_id}.jsonl"


def load_manifest(path: Path) -> List[str]:
    files: List[str] = []
    with path.open() as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        if reader.fieldnames is None or "file" not in reader.fieldnames:
            raise ValueError(
                f"manifest {path} must have a 'file' column; got {reader.fieldnames!r}"
            )
        for row in reader:
            file_path = (row.get("file") or "").strip()
            if file_path:
                files.append(file_path)
    return files


def load_jsonl(path: Path) -> List[dict]:
    entries: List[dict] = []
    with path.open() as fh:
        for line_num, line in enumerate(fh, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError as exc:
                raise ValueError(
                    f"{path}:{line_num}: invalid JSON: {exc}"
                ) from exc
    return entries


def collect_text(content: object) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        chunks: List[str] = []
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "text":
                chunks.append(block.get("text", "") or "")
        return "\n".join(chunks)
    return ""


def is_clear_marker(entry: dict) -> bool:
    if entry.get("type") != "user":
        return False
    message = entry.get("message", {}) or {}
    text = collect_text(message.get("content"))
    return CLEAR_MARKER in text


def iter_tool_uses(entry: dict) -> Iterable[dict]:
    if entry.get("type") != "assistant":
        return
    message = entry.get("message", {}) or {}
    content = message.get("content")
    if not isinstance(content, list):
        return
    for block in content:
        if isinstance(block, dict) and block.get("type") == "tool_use":
            yield block


def split_bash_command_head(command: str) -> Optional[str]:
    """Return the leading binary name of a Bash command, if it can be identified."""

    stripped = command.strip()
    if not stripped:
        return None
    while stripped.startswith(("(", "{")):
        stripped = stripped[1:].lstrip()
    head_match = re.match(r"([A-Za-z0-9_./-]+)", stripped)
    if not head_match:
        return None
    head = head_match.group(1)
    head = head.rsplit("/", 1)[-1]
    return head


def normalize_to_repo_relative(token: str, entry_cwd: Optional[str]) -> str:
    """Convert an absolute path under entry_cwd to repo-relative form when possible."""

    if not token or not entry_cwd or not os.path.isabs(token):
        return token
    try:
        rel = os.path.relpath(token, entry_cwd)
    except ValueError:
        return token
    if rel.startswith(".."):
        return token
    return rel


def candidate_token_forms(token: str, entry_cwd: Optional[str]) -> List[str]:
    forms = [token]
    normalized = normalize_to_repo_relative(token, entry_cwd)
    if normalized != token:
        forms.append(normalized)
    return forms


def file_referenced_in_token(
    token: str, file_path: str, entry_cwd: Optional[str] = None
) -> bool:
    """Return True if a Bash word references the file path (exact or basename)."""

    candidates = (file_path, "./" + file_path, os.path.basename(file_path))
    for form in candidate_token_forms(token, entry_cwd):
        for cand in candidates:
            if not cand:
                continue
            if form == cand:
                return True
            if form.endswith(cand):
                stripped = form[: -len(cand)]
                if stripped in ("", "/", "./"):
                    return True
    return False


def parse_cd_prefix(
    command: str, entry_cwd: Optional[str]
) -> Tuple[Optional[str], str]:
    """If command starts with `cd <target> && rest`, return (effective_cwd, rest).

    Returns (None, command) when no leading cd prefix is detected. `effective_cwd`
    is resolved against entry_cwd when the cd target is relative, so subsequent
    classification can match relative file arguments correctly.
    """

    match = re.match(r"^\s*cd\s+([^\s&;]+)\s*&&\s*(.+)$", command, re.DOTALL)
    if not match:
        return None, command
    cd_target = match.group(1).strip("\"'")
    rest = match.group(2)
    if os.path.isabs(cd_target):
        effective_cwd = cd_target
    elif entry_cwd:
        effective_cwd = os.path.normpath(os.path.join(entry_cwd, cd_target))
    else:
        effective_cwd = cd_target
    return effective_cwd, rest


def classify_bash_for_file(
    command: str, file_path: str, entry_cwd: Optional[str] = None
) -> Tuple[str, str]:
    """Classify how strongly a Bash command reads `file_path`.

    Returns (read_confidence, read_evidence).
    Confidence levels: 'high', 'medium', 'low_path_mention_only', 'none'.
    """

    if not command or not file_path:
        return ("none", "")

    cd_target, effective_command = parse_cd_prefix(command, entry_cwd)
    effective_cwd = cd_target if cd_target else entry_cwd

    basename = os.path.basename(file_path)
    if (
        file_path not in effective_command
        and basename not in effective_command
        and (
            not effective_cwd
            or os.path.join(effective_cwd, file_path) not in effective_command
        )
    ):
        return ("none", "")

    head = split_bash_command_head(effective_command)
    if head is None:
        return ("low_path_mention_only", f"Bash: path mention in '{command[:60]}'")

    tokens = re.findall(r"[^\s'\"`]+|\"[^\"]*\"|'[^']*'", effective_command)
    references = any(
        file_referenced_in_token(tok.strip("\"'"), file_path, effective_cwd)
        for tok in tokens
    )

    if head in BASH_HIGH_CONFIDENCE_COMMANDS and references:
        return ("high", f"Bash: {head} <file>")
    if head in BASH_MEDIUM_CONFIDENCE_COMMANDS and references:
        return ("medium", f"Bash: {head} <file>")
    if head in BASH_READ_LIKE_COMMANDS:
        return (
            "low_path_mention_only",
            f"Bash: {head} command mentions <file> but no clear file argument",
        )
    return ("low_path_mention_only", f"Bash: '{head}' command mentions <file>")


def grep_targets_file(
    input_obj: dict, file_path: str, entry_cwd: Optional[str] = None
) -> bool:
    path_arg = (input_obj.get("path") or "").strip()
    glob_arg = (input_obj.get("glob") or "").strip()
    if path_arg:
        candidate_paths = candidate_token_forms(path_arg, entry_cwd)
        for candidate in candidate_paths:
            cleaned = candidate.rstrip("/")
            if not cleaned:
                continue
            if cleaned == file_path:
                return True
            if cleaned == os.path.dirname(file_path):
                return True
            if file_path.startswith(cleaned + "/"):
                return True
    if glob_arg:
        if file_path.endswith(glob_arg.lstrip("*")):
            return True
    return False


def classify_grep_for_file(
    input_obj: dict, file_path: str, entry_cwd: Optional[str] = None
) -> Tuple[str, str]:
    if grep_targets_file(input_obj, file_path, entry_cwd):
        return ("high", "Grep tool scoped to <file> or its directory")
    pattern = (input_obj.get("pattern") or "").strip()
    if pattern and file_path in pattern:
        return ("medium", "Grep pattern mentions <file>")
    return ("none", "")


def classify_read_for_file(
    input_obj: dict, file_path: str, entry_cwd: Optional[str] = None
) -> Tuple[str, str]:
    candidate = (input_obj.get("file_path") or "").strip()
    if not candidate:
        return ("none", "")
    forms = candidate_token_forms(candidate, entry_cwd)
    for form in forms:
        if form == file_path or form.endswith("/" + file_path):
            return ("high", "Read tool")
    if os.path.basename(candidate) == os.path.basename(file_path):
        return ("medium", "Read tool: basename match")
    return ("none", "")


def classify_tool_use_for_file(
    tool_use: dict, file_path: str, entry_cwd: Optional[str] = None
) -> Tuple[str, str]:
    name = tool_use.get("name") or ""
    input_obj = tool_use.get("input") or {}
    if not isinstance(input_obj, dict):
        return ("none", "")
    if name == "Read":
        return classify_read_for_file(input_obj, file_path, entry_cwd)
    if name == "Grep":
        return classify_grep_for_file(input_obj, file_path, entry_cwd)
    if name == "Bash":
        command = input_obj.get("command") or ""
        return classify_bash_for_file(command, file_path, entry_cwd)
    return ("none", "")


CONFIDENCE_RANK = {
    "none": 0,
    "low_path_mention_only": 1,
    "medium": 2,
    "high": 3,
}


def confidence_implies_tool_read(confidence: str) -> bool:
    return confidence in ("high", "medium")


def collect_agent_invocations(
    entries: Sequence[dict], phase_for_uuid: Dict[str, str]
) -> List[dict]:
    """Return main-agent Agent tool invocations with subagent_type and phase."""

    invocations: List[dict] = []
    for index, entry in enumerate(entries):
        if entry.get("isSidechain"):
            continue
        for tool_use in iter_tool_uses(entry):
            if tool_use.get("name") != AGENT_TOOL_NAME:
                continue
            input_obj = tool_use.get("input") or {}
            sub_type = "unknown"
            if isinstance(input_obj, dict):
                sub_type = (input_obj.get("subagent_type") or "unknown").strip() or "unknown"
            uuid = entry.get("uuid", "")
            phase = phase_for_uuid.get(uuid, "fresh_start")
            invocations.append(
                {
                    "subagent_type": sub_type,
                    "event_index": index,
                    "uuid": uuid,
                    "tool_uuid": tool_use.get("id", ""),
                    "session_phase": phase,
                }
            )
    return invocations


class TaskAttribution:
    """Attribute sidechain tool_uses to a spawning Agent invocation.

    Walks parentUuid chains to find the nearest Agent tool_use uuid in the main
    agent stream. Provided for forward compatibility with future Claude Code
    versions that surface sidechain tool calls; current versions emit no
    `isSidechain: true` entries (see module docstring).
    """

    def __init__(self, entries: Sequence[dict]) -> None:
        self.parent_of: Dict[str, Optional[str]] = {}
        self.task_subagent_type: Dict[str, str] = {}
        for entry in entries:
            uuid = entry.get("uuid")
            if uuid:
                self.parent_of[uuid] = entry.get("parentUuid")
            if entry.get("isSidechain"):
                continue
            for tool_use in iter_tool_uses(entry):
                if tool_use.get("name") != AGENT_TOOL_NAME:
                    continue
                input_obj = tool_use.get("input") or {}
                sub_type = "unknown"
                if isinstance(input_obj, dict):
                    sub_type = (
                        input_obj.get("subagent_type") or "unknown"
                    ).strip() or "unknown"
                tool_uuid = tool_use.get("id") or ""
                if tool_uuid:
                    self.task_subagent_type[tool_uuid] = sub_type
                if uuid:
                    self.task_subagent_type[uuid] = sub_type

    def attribute(self, sidechain_entry: dict) -> str:
        seen = set()
        cursor = sidechain_entry.get("parentUuid")
        hops = 0
        while cursor and cursor not in seen and hops < 1000:
            if cursor in self.task_subagent_type:
                return self.task_subagent_type[cursor]
            seen.add(cursor)
            cursor = self.parent_of.get(cursor)
            hops += 1
        return "unknown"


def determine_session_phase(entries: Sequence[dict]) -> Dict[str, str]:
    """Map each entry uuid to fresh_start or post_clear based on /clear markers."""

    phase_for_uuid: Dict[str, str] = {}
    current_phase = "fresh_start"
    for entry in entries:
        if is_clear_marker(entry):
            current_phase = "post_clear"
        uuid = entry.get("uuid")
        if uuid:
            phase_for_uuid[uuid] = current_phase
    return phase_for_uuid


def has_clear_boundary(entries: Sequence[dict]) -> bool:
    return any(is_clear_marker(entry) for entry in entries)


def collect_reads(
    entries: Sequence[dict],
    manifest_files: Sequence[str],
    phase_for_uuid: Dict[str, str],
) -> List[dict]:
    """Return one record per (entry, manifest_file) where evidence > none."""

    attribution = TaskAttribution(entries)
    records: List[dict] = []
    for index, entry in enumerate(entries):
        uuid = entry.get("uuid") or ""
        is_sidechain = bool(entry.get("isSidechain"))
        cwd = entry.get("cwd") or "unknown"
        entry_cwd = entry.get("cwd") or None
        for tool_use in iter_tool_uses(entry):
            for file_path in manifest_files:
                confidence, evidence = classify_tool_use_for_file(
                    tool_use, file_path, entry_cwd
                )
                if confidence == "none":
                    continue
                if is_sidechain:
                    agent_type = "subagent"
                    subagent_type = attribution.attribute(entry)
                else:
                    agent_type = "main"
                    subagent_type = ""
                records.append(
                    {
                        "agent_type": agent_type,
                        "subagent_type": subagent_type,
                        "session_phase": phase_for_uuid.get(uuid, "unknown"),
                        "cwd": cwd,
                        "file": file_path,
                        "confidence": confidence,
                        "evidence": evidence,
                        "event_index": index,
                        "uuid": uuid,
                    }
                )
    return records


def collect_observed_cells(
    entries: Sequence[dict],
    records: Sequence[dict],
    agent_invocations: Sequence[dict],
) -> List[Tuple[str, str, str]]:
    """Return ordered list of (agent_type, subagent_type, session_phase) cells.

    Main-agent cells are emitted for each phase actually traversed in the trace
    (fresh_start always; post_clear only when a /clear marker was observed).
    Subagent cells are emitted only for (subagent_type, phase) pairs that were
    actually observed: the subagent must have been invoked (or surfaced a
    sidechain tool call, for forward compatibility) in that phase.
    """

    cells: "OrderedDict[Tuple[str, str, str], None]" = OrderedDict()
    saw_clear = has_clear_boundary(entries)

    cells[("main", "", "fresh_start")] = None
    if saw_clear:
        cells[("main", "", "post_clear")] = None

    observed_subagent_phases: "OrderedDict[Tuple[str, str], None]" = OrderedDict()
    for invocation in agent_invocations:
        key = (invocation["subagent_type"], invocation["session_phase"])
        observed_subagent_phases[key] = None
    for record in records:
        if record["agent_type"] != "subagent":
            continue
        key = (record["subagent_type"], record["session_phase"])
        observed_subagent_phases[key] = None

    for sub_type, phase in observed_subagent_phases:
        cells[("subagent", sub_type, phase)] = None

    return list(cells.keys())


def select_strongest_record(
    records: Sequence[dict],
) -> Dict[Tuple[str, str, str, str], dict]:
    """Pick the highest-confidence read per cell, tiebreaking by earliest index."""

    strongest: Dict[Tuple[str, str, str, str], dict] = {}
    for record in records:
        key = (
            record["agent_type"],
            record["subagent_type"],
            record["session_phase"],
            record["file"],
        )
        existing = strongest.get(key)
        if existing is None:
            strongest[key] = record
            continue
        cur_rank = CONFIDENCE_RANK[record["confidence"]]
        old_rank = CONFIDENCE_RANK[existing["confidence"]]
        if cur_rank > old_rank:
            strongest[key] = record
        elif cur_rank == old_rank and record["event_index"] < existing["event_index"]:
            strongest[key] = record
    return strongest


def select_earliest_record(
    records: Sequence[dict],
) -> Dict[Tuple[str, str, str, str], dict]:
    """Pick the earliest read per cell regardless of confidence."""

    earliest: Dict[Tuple[str, str, str, str], dict] = {}
    for record in records:
        key = (
            record["agent_type"],
            record["subagent_type"],
            record["session_phase"],
            record["file"],
        )
        existing = earliest.get(key)
        if existing is None or record["event_index"] < existing["event_index"]:
            earliest[key] = record
    return earliest


def build_rows(
    records: Sequence[dict],
    cells: Sequence[Tuple[str, str, str]],
    manifest_files: Sequence[str],
    saw_clear_boundary: bool,
) -> List[Dict[str, str]]:
    strongest = select_strongest_record(records)
    earliest = select_earliest_record(records)
    rows: List[Dict[str, str]] = []

    for agent_type, subagent_type, session_phase in cells:
        for file_path in manifest_files:
            key = (agent_type, subagent_type, session_phase, file_path)
            strong_record = strongest.get(key)
            first_record = earliest.get(key)
            confidence = strong_record["confidence"] if strong_record else "none"
            evidence = strong_record["evidence"] if strong_record else ""
            tool_read = (
                "true" if confidence_implies_tool_read(confidence) else "false"
            )
            event_index = str(first_record["event_index"]) if first_record else ""
            uuid = first_record["uuid"] if first_record else ""
            cwd = strong_record["cwd"] if strong_record else ""
            notes_parts: List[str] = []
            if agent_type == "subagent":
                notes_parts.append(
                    "subagent internal tool calls are not visible in the main "
                    "JSONL; rows reflect Agent invocation only"
                )
            if (
                agent_type == "main"
                and session_phase == "post_clear"
                and not saw_clear_boundary
            ):
                notes_parts.append("no /clear boundary observed in trace")
            rows.append(
                {
                    "agent": "claude",
                    "agent_type": agent_type,
                    "subagent_type": subagent_type,
                    "session_phase": session_phase,
                    "cwd": cwd,
                    "file": file_path,
                    "tool_read": tool_read,
                    "read_confidence": confidence,
                    "read_evidence": evidence,
                    "first_read_event_index": event_index,
                    "first_read_uuid": uuid,
                    "notes": "; ".join(notes_parts),
                }
            )
    return rows


def write_tsv(rows: Sequence[Dict[str, str]], stream) -> None:
    writer = csv.DictWriter(
        stream,
        fieldnames=list(OUTPUT_COLUMNS),
        delimiter="\t",
        lineterminator="\n",
        extrasaction="ignore",
    )
    writer.writeheader()
    writer.writerows(rows)


def resolve_input_path(args: argparse.Namespace) -> Path:
    if args.jsonl:
        return args.jsonl
    if args.session_id and args.cwd:
        candidate = resolve_jsonl_path(args.session_id, args.cwd)
        if not candidate.is_file():
            raise SystemExit(
                f"could not resolve session id '{args.session_id}' under cwd "
                f"'{args.cwd}': expected file at {candidate}. Pass --jsonl explicitly."
            )
        return candidate
    raise SystemExit("either --jsonl or both --session-id and --cwd are required")


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    jsonl_path = resolve_input_path(args)
    if not jsonl_path.is_file():
        raise SystemExit(f"jsonl path does not exist: {jsonl_path}")
    if not args.manifest.is_file():
        raise SystemExit(f"manifest path does not exist: {args.manifest}")

    manifest_files = load_manifest(args.manifest)
    entries = load_jsonl(jsonl_path)
    phase_for_uuid = determine_session_phase(entries)
    records = collect_reads(entries, manifest_files, phase_for_uuid)
    agent_invocations = collect_agent_invocations(entries, phase_for_uuid)
    cells = collect_observed_cells(entries, records, agent_invocations)
    saw_clear = has_clear_boundary(entries)
    rows = build_rows(records, cells, manifest_files, saw_clear)

    if args.output:
        with args.output.open("w") as fh:
            write_tsv(rows, fh)
    else:
        write_tsv(rows, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())

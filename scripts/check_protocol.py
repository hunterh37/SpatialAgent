#!/usr/bin/env python3
"""Schema drift check.

`packages/AgentProtocol/schema/protocol.schema.json` is the source of truth
(docs/architecture.md 3a). Neither language owns the protocol, so this script asserts that
both hand-maintained mirrors carry every message type and every field the schema declares.

It is the cheap half of the codegen story: it cannot write the types for you, but it does
make a schema change that skips one language fail in CI rather than on a headset.

    python3 scripts/check_protocol.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "packages" / "AgentProtocol" / "schema" / "protocol.schema.json"
SWIFT = ROOT / "packages" / "Sources" / "AgentProtocol" / "Generated" / "WireTypes.swift"
PYTHON = ROOT / "services" / "agentd" / "agentd" / "protocol.py"


def message_fields(definition: dict) -> dict[str, set[str]]:
    """{ messageType: {field, ...} } for a ClientMessage/ServerEvent oneOf definition."""
    out: dict[str, set[str]] = {}
    for variant in definition["oneOf"]:
        props = variant["properties"]
        name = props["type"]["const"]
        out[name] = {k for k in props if k != "type"}
    return out


def check(
    language: str, source: str, expected: dict[str, set[str]], quoted: set[str]
) -> list[str]:
    """`quoted` names appear on the wire as a literal `"type"` discriminator; the rest are
    object definitions and only have to exist as a declared type."""
    problems = []
    for name, fields in expected.items():
        present = f'"{name}"' in source if name in quoted else re.search(
            rf"\b{re.escape(name)}\b", source
        )
        if not present:
            problems.append(f"{language}: '{name}' is missing")
            continue
        for field in fields:
            if not re.search(rf"\b{re.escape(field)}\b", source):
                problems.append(f"{language}: '{name}' field '{field}' is missing")
    return problems


def main() -> int:
    schema = json.loads(SCHEMA.read_text())
    definitions = schema["definitions"]

    expected: dict[str, set[str]] = {}
    expected.update(message_fields(definitions["ClientMessage"]))
    expected.update(message_fields(definitions["ServerEvent"]))
    quoted = set(expected)
    # Shared object definitions have to exist in both languages too.
    for name in (
        "Capabilities",
        "Device",
        "CharacterDirective",
        "MapPlace",
        "MapObjectRef",
        "MapRuleRef",
        "MapActivityRef",
        "SceneSnapshot",
    ):
        expected[name] = set(definitions[name]["properties"])

    problems: list[str] = []
    problems += check("swift", SWIFT.read_text(), expected, quoted)
    problems += check("python", PYTHON.read_text(), expected, quoted)

    for problem in problems:
        print(problem, file=sys.stderr)

    if problems:
        print(f"\n{len(problems)} drift(s) against {SCHEMA.relative_to(ROOT)}", file=sys.stderr)
        return 1

    types = len(expected)
    print(f"protocol ok: {types} definitions present in Swift and Python")
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""Rescuing a tool call a small model typed instead of called.

Sub-3B models emit `forget_about_user(query="the coffee thing")` as *prose* often enough that
a demo cannot rely on the function-calling path alone. The user then watches the bird narrate
an action it never took, which is the single worst failure this project can have: it looks
like memory working and is memory doing nothing.

So a reply that is entirely a tool invocation is treated as one. The rules are tight on
purpose, because the opposite failure — acting on a sentence that merely mentioned a tool —
is worse than not acting:

- The whole reply, trimmed, has to be the call. A call mentioned inside a sentence is speech.
- The name has to be a registered tool.
- Only one call is rescued per reply.

This is the same lesson as `directives_for`: infer as little as possible, and only where the
inference is checkable.
"""

from __future__ import annotations

import ast
import json
import re
from typing import Any

#: `name(...)` and nothing else. DOTALL so a model that wrapped an argument list over two
#: lines is still matched; anchored so a mention inside prose is not.
_CALL = re.compile(r"^\s*`?(?P<name>[a-z_][a-z0-9_]*)\s*\((?P<args>.*)\)`?\s*\.?\s*$", re.DOTALL)
_KWARG = re.compile(r"(?P<key>[a-z_][a-z0-9_]*)\s*=\s*(?P<value>.+)", re.DOTALL)


def extract_call(reply: str, known: set[str] | list[str]) -> tuple[str, dict[str, Any]] | None:
    """The tool call a reply *is*, or None if the reply is speech."""
    match = _CALL.match(reply or "")
    if match is None:
        return None
    name = match.group("name")
    if name not in set(known):
        return None
    return name, _parse_args(match.group("args"))


def _parse_args(raw: str) -> dict[str, Any]:
    raw = raw.strip()
    if not raw:
        return {}
    # A model that emitted JSON is taken at its word before anything is guessed.
    if raw.startswith("{"):
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            parsed = None
        if isinstance(parsed, dict):
            return parsed

    args: dict[str, Any] = {}
    for part in _split(raw):
        kwarg = _KWARG.match(part.strip())
        if kwarg is None:
            continue
        args[kwarg.group("key")] = _literal(kwarg.group("value").strip())
    return args


def _split(raw: str) -> list[str]:
    """Split on commas that are not inside quotes or brackets."""
    out: list[str] = []
    depth = 0
    quote: str | None = None
    current: list[str] = []
    for ch in raw:
        if quote:
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            out.append("".join(current))
            current = []
            continue
        current.append(ch)
    if current:
        out.append("".join(current))
    return out


def _literal(value: str) -> Any:
    try:
        # literal_eval and not eval: the input is model output, and a rescued tool call must
        # not be able to run anything.
        return ast.literal_eval(value)
    except (ValueError, SyntaxError):
        return value.strip().strip("\"'")

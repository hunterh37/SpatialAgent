"""Text -> symbolic character intent.

The model emits language; this module maps it onto places the client already told us about.
A place the client never sent can never be produced, which is what makes hallucinated
navigation structurally impossible rather than merely unlikely (spec/05-scene.md).
"""

from __future__ import annotations

import re

from .protocol import CharacterDirective, SceneSnapshot

_GO_PATTERNS = (
    r"\b(?:walk|go|head|move|heading|going|walking)\b[^.!?]*?\bto\b\s+the\s+(?P<place>[a-z ]+)",
    r"\bover\s+to\s+the\s+(?P<place>[a-z ]+)",
)


def directives_for(text: str, scene: SceneSnapshot) -> list[CharacterDirective]:
    """Extract walkTo intents from partial or complete model output.

    Safe to call on every streamed token: it is idempotent, and the caller dedupes.
    """
    if not scene.places:
        return []

    lowered = text.lower()
    found: list[CharacterDirective] = []
    seen: set[str] = set()

    for pattern in _GO_PATTERNS:
        for match in re.finditer(pattern, lowered):
            candidate = match.group("place").strip()
            place = _match_place(candidate, scene)
            if place and place not in seen:
                seen.add(place)
                found.append(CharacterDirective(kind="walkTo", place=place, target="place"))

    return found


def _match_place(candidate: str, scene: SceneSnapshot) -> str | None:
    """Longest known place name contained in the candidate span."""
    best: str | None = None
    for place in scene.places:
        name = place.name.lower()
        if name in candidate and (best is None or len(name) > len(best)):
            best = place.name
    return best

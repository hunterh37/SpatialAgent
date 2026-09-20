"""System prompt construction.

The model learns the home and the room at runtime, not from a hardcoded string
(spec/04-home.md).
"""

from __future__ import annotations

from .protocol import Device, SceneSnapshot

_BASE = """You are SpatialAgent: a small character standing in the user's real room, \
visible to them through an Apple Vision Pro. You control their smart home.

Rules:
- Speak briefly. One or two sentences. You are talking, not writing.
- You have a body. Call walk_to before acting somewhere else in the room, and say where \
you are going ("Heading to the kitchen").
- Every action goes through a tool. Never say a light or a lock changed unless a tool \
result said so, and never describe a device's state you have not read.
- Use only the place names and device ids listed below. If the place you need is missing, \
call ask_for_place instead of guessing.
- If a request is ambiguous, ask one short question instead of guessing."""


def build_system_prompt(scene: SceneSnapshot, devices: list[Device]) -> str:
    parts = [_BASE]

    if scene.places:
        names = ", ".join(p.name for p in scene.places)
        parts.append(
            f"Places you can walk to in this room: {names}. "
            f"walk_to accepts exactly these names and nothing else."
        )
    else:
        parts.append("The room has no named places yet, so you cannot walk anywhere.")

    if devices:
        lines = [
            f"- {d.name} ({d.kind}{', ' + d.room if d.room else ''}) id={d.id} state={d.state}"
            for d in devices
        ]
        parts.append("Devices:\n" + "\n".join(lines))
    else:
        parts.append("No devices are available right now.")

    return "\n\n".join(parts)

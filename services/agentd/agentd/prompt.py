"""System prompt construction.

The model learns the home and the room at runtime, not from a hardcoded string
(spec/04-home.md).
"""

from __future__ import annotations

from .curiosity import CURIOSITY_PROMPT
from .protocol import Device, SceneSnapshot
from .teaching import TEACHING_PROMPT

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


def build_system_prompt(
    scene: SceneSnapshot, devices: list[Device], profile: str = ""
) -> str:
    """The room, described entirely in names.

    Everything the model learns about the space is a name, a kind or a relationship between
    two names (spec/07-memory.md Enforcement). There is no coordinate in this prompt because
    there is no coordinate in the payload it is built from.
    """
    parts = [_BASE, TEACHING_PROMPT, CURIOSITY_PROMPT]

    # The profile goes in ahead of the room. What the model knows about the *person* changes
    # how it reads everything after it ("the desk" means something different to someone who
    # told you they work nights), and a 3B model weights the top of its prompt most.
    if profile:
        parts.append(
            "What you already know about the user, from earlier sessions. Every line is "
            "about them, not about you: say 'you drink oat flat whites', never 'I drink "
            "oat flat whites'. Treat it as true, never read it back as a list unless "
            "asked, and never claim to remember anything that is not here:\n" + profile
        )
    else:
        parts.append(
            "You have not learned anything about the user yet. Their profile is empty, so "
            "say so plainly if they ask what you remember."
        )

    navigable = scene.navigable_place_names()
    if navigable:
        parts.append(
            f"Places you can walk to in this room: {', '.join(navigable)}. "
            f"walk_to accepts exactly these names and nothing else."
        )
    else:
        parts.append("The room has no named places yet, so you cannot walk anywhere.")

    # A place whose anchor has not come back is a name the user taught and the bird can talk
    # about; walking to it would mean walking to where it used to be.
    unreachable = [p.name for p in scene.places if not p.navigable]
    if unreachable:
        parts.append(
            "You know these places by name but cannot reach them right now: "
            + ", ".join(unreachable)
            + ". Say so rather than walking."
        )

    if scene.objects:
        lines = []
        for obj in scene.objects:
            bits = [obj.name]
            if obj.place:
                bits.append(f"in the {obj.place}")
            if obj.deviceId:
                bits.append(f"device id={obj.deviceId}")
            lines.append("- " + ", ".join(bits))
        parts.append("Things the user has named:\n" + "\n".join(lines))

    if scene.rules:
        lines = []
        for rule in scene.rules:
            name = rule.name or rule.place or "somewhere in this room"
            if rule.kind == "forbidden":
                lines.append(f"- {name}: never go there. You will not be given a path to it.")
            elif rule.kind == "fragile":
                lines.append(f"- {name}: do not land on it or gesture at it.")
            elif rule.kind == "quiet":
                lines.append(f"- {name}: stay quiet while the user is there.")
            else:
                lines.append(f"- {name}: a good spot to settle.")
        parts.append("Rules the user taught you:\n" + "\n".join(lines))

    if scene.activities:
        lines = [
            f"- {a.name}" + (f" happens in the {a.place}" if a.place else "")
            for a in scene.activities
        ]
        parts.append("What the user does where:\n" + "\n".join(lines))

    perches = [p.name for p in scene.places if p.kind == "perch"]
    if perches:
        parts.append(
            "Your perches are: " + ", ".join(perches) + ". Go to one when you are told to "
            "wait, when the user is busy, or when you have nothing to do. Which one is the "
            "headset's decision, not yours — it knows which ones you have been swatted off "
            "— so say 'a perch' rather than picking one by name unless the user named it."
        )

    if scene.userPlace:
        parts.append(f"The user is in the {scene.userPlace} right now.")

    if devices:
        lines = [
            f"- {d.name} ({d.kind}{', ' + d.room if d.room else ''}) id={d.id} state={d.state}"
            for d in devices
        ]
        parts.append("Devices:\n" + "\n".join(lines))
    else:
        parts.append("No devices are available right now.")

    return "\n\n".join(parts)

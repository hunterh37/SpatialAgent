"""Teaching acts (spec/07-memory.md Teaching).

Five tools, one per act, so the model *states* the teaching act instead of the client
regexing prose for it. This is the same lesson as `walk_to` in phase 2.1: inferring intent
from a sentence is unreliable, and a missed teaching act is worse than a missed walk — the
user said something to the bird, watched it do nothing, and lost a name they meant to keep.

The server never learns where any of this landed. It emits the act and the name; the client
resolves the held gaze target, writes the record, and answers with a tool result. That split
is what keeps coordinates off the server while still letting the model drive the act
(docs/architecture.md 3b).
"""

from __future__ import annotations

from typing import Any

from .tools.registry import Tool, ToolRegistry

NAME_PLACE = "name_place"
NAME_OBJECT = "name_object"
FORBID_REGION = "forbid_region"
NAME_ACTIVITY = "name_activity"
CORRECT_NAME = "correct_name"

TEACHING_TOOLS = frozenset(
    {NAME_PLACE, NAME_OBJECT, FORBID_REGION, NAME_ACTIVITY, CORRECT_NAME}
)

#: What the client is expected to have looked at for each act. Carried in the tool result
#: for logging only; the server never receives the target itself.
ACT_EXPECTS_GAZE = TEACHING_TOOLS


def teaching_tools() -> list[Tool]:
    """The five acts, as tools.

    Every one is `safe`: naming something is not a destructive home action, and putting a
    confirmation dialog in front of "this is my desk" would make teaching cost more than it
    is worth. `forbid_region` is safe for the same reason — it *adds* a restriction.
    """
    return [
        Tool(
            name=NAME_PLACE,
            description=(
                "The user just named a place they are looking at, e.g. 'this is my "
                "workspace'. Call this with the name they said. You do not need to know "
                "where it is; the headset resolves what they were looking at."
            ),
            safety="safe",
            parameters={"name": {"type": "string", "required": True}},
        ),
        Tool(
            name=NAME_OBJECT,
            description=(
                "The user just named a thing they are looking at, e.g. 'this is the coffee "
                "machine'. Pass the name they said, and a device id if one of the listed "
                "devices is obviously the same thing."
            ),
            safety="safe",
            parameters={
                "name": {"type": "string", "required": True},
                "device_id": {"type": "string"},
            },
        ),
        Tool(
            name=FORBID_REGION,
            description=(
                "The user told you to stay away from what they are looking at, e.g. "
                "'don't go here' or 'don't touch this'. Use hard=true for 'don't go', "
                "hard=false for 'be careful around'."
            ),
            safety="safe",
            parameters={
                "name": {"type": "string"},
                "hard": {"type": "boolean"},
            },
        ),
        Tool(
            name=NAME_ACTIVITY,
            description=(
                "The user said what they do somewhere, e.g. 'this is where I brainstorm'. "
                "Pass the activity, not the place: 'brainstorming'."
            ),
            safety="safe",
            parameters={"name": {"type": "string", "required": True}},
        ),
        Tool(
            name=CORRECT_NAME,
            description=(
                "The user is correcting a name you just used or just learned, e.g. "
                "'no, that's the kitchen'. Pass the corrected name."
            ),
            safety="safe",
            parameters={"name": {"type": "string", "required": True}},
        ),
    ]


def register(registry: ToolRegistry) -> ToolRegistry:
    for tool in teaching_tools():
        registry.add(tool)
    return registry


def clean_name(raw: Any) -> str:
    """The name the user said, tidied but not rewritten.

    Small models like to hand back "this is my workspace" whole, or wrap the name in
    quotes, or prefix it with an article. The name is spoken back to the user as
    confirmation, so it has to be the thing they said and not a sentence — but it is never
    re-spelled or title-cased, because correcting the user's own name for their own room is
    not the bird's job.
    """
    text = str(raw or "").strip().strip("\"'").strip()
    if not text:
        return ""
    lowered = text.lower()
    # Only the deictic opener comes off. "my workspace" keeps its "my": it is the user's
    # name for their own room and rewriting it is not the bird's job.
    for prefix in ("this is ", "that is ", "that's ", "here is ", "this here is "):
        if lowered.startswith(prefix):
            text = text[len(prefix) :].strip()
            lowered = text.lower()
            break
    for prefix in ("where i ", "where we "):
        if lowered.startswith(prefix):
            text = text[len(prefix) :].strip()
            break
    return text.rstrip(".!").strip()


def hardness(args: dict[str, Any]) -> bool:
    """A rule taught with "don't" is hard (spec/07-memory.md Rules), so the default is hard.

    The model has to say so explicitly to get a soft rule, rather than a soft rule being
    what happens when it says nothing.
    """
    value = args.get("hard")
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() not in {"false", "no", "off", "0"}
    return True


#: Appended to the system prompt. Teaching is the highest-risk path in the product (PRD 9),
#: and the failure mode is the model narrating the act instead of calling the tool.
TEACHING_PROMPT = """\
The user can teach you their room by looking at something and speaking. When they do, call \
the matching tool immediately and say the name back to them in your reply so they can catch \
a mis-hearing:
- "this is my workspace" -> name_place(name="my workspace")
- "this is the coffee machine" -> name_object(name="the coffee machine")
- "don't go here" / "don't touch this" -> forbid_region(hard=true)
- "this is where I brainstorm" -> name_activity(name="brainstorming")
- "no, that's the kitchen" -> correct_name(name="the kitchen")
Never answer a teaching sentence with words alone, and never ask where the thing is: the \
headset already knows what they were looking at."""

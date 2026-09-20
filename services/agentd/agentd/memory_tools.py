"""Profile memory as a tool surface.

Memory is a set of tools rather than something the session does behind the model's back, for
the same reason walking is (`walk_to`, phase 2.1): a change to the user's memory that nobody
declared is a change nobody can audit. Every write here appears in the transcript as a tool
call with its arguments, and lands in a file the user can open.

All of these are `safe`. Putting a confirmation dialog in front of "remember that I drink oat
milk" would cost more than the fact is worth — but note that `forget_about_user` is safe too,
and that is a deliberate call: the user asking to be forgotten should never be made to
confirm being forgotten.
"""

from __future__ import annotations

from .tools.registry import Tool, ToolRegistry

REMEMBER = "remember_about_user"
RECALL = "recall_about_user"
FORGET = "forget_about_user"
UPDATE = "update_about_user"
ASK_ABOUT = "ask_about_user"
SET_PERCH = "set_home_perch"

MEMORY_TOOLS = frozenset({REMEMBER, RECALL, FORGET, UPDATE, ASK_ABOUT, SET_PERCH})

_SLOTS = (
    "identity, routine, preference, diet, people, place_meaning, project, boundary, misc"
)


def memory_tools() -> list[Tool]:
    return [
        Tool(
            name=REMEMBER,
            description=(
                "Store one thing you now know about the user, as a short sentence in their "
                "own words. Call this whenever they state a preference, a habit, a "
                "boundary, or a fact about themselves — including as an aside. "
                f"slot is one of: {_SLOTS}."
            ),
            safety="safe",
            parameters={
                "text": {"type": "string", "required": True},
                "slot": {"type": "string"},
                "place": {"type": "string"},
            },
        ),
        Tool(
            name=RECALL,
            description=(
                "Look up what you remember about the user before answering anything about "
                "them, their habits or their preferences. Returns matching facts with ids."
            ),
            safety="safe",
            parameters={"query": {"type": "string", "required": True}},
        ),
        Tool(
            name=FORGET,
            description=(
                "Drop what you remember about something, e.g. 'forget what I said about "
                "coffee'. Pass what they described, not an id, unless you have one."
            ),
            safety="safe",
            parameters={"query": {"type": "string", "required": True}},
        ),
        Tool(
            name=UPDATE,
            description=(
                "Correct a fact you already remember. Get the fact_id from "
                f"{RECALL} first. Use this rather than remembering a second, "
                "contradictory fact."
            ),
            safety="safe",
            parameters={
                "fact_id": {"type": "string", "required": True},
                "text": {"type": "string", "required": True},
            },
        ),
        Tool(
            name=ASK_ABOUT,
            description=(
                "Get one question to ask the user about themselves. Use it in a lull, or "
                "when they invite you to ask. Ask exactly the question it returns, once, "
                "then store their answer with " + REMEMBER + "."
            ),
            safety="safe",
        ),
        Tool(
            name=SET_PERCH,
            description=(
                "The user told you where you should wait or sit, e.g. 'this is your perch' "
                "or 'wait on the shelf'. Pass the place name if they said one; otherwise "
                "leave it out and the headset uses what they are looking at."
            ),
            safety="safe",
            parameters={"place": {"type": "string"}},
        ),
    ]


def register(registry: ToolRegistry) -> ToolRegistry:
    for tool in memory_tools():
        registry.add(tool)
    return registry

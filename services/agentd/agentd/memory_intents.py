"""Utterances that are unambiguously memory operations, handled before the model runs.

Same argument as `directives_for`, applied to memory: a 1.7B model asked to both converse and
call the right tool will sometimes do only the first, and "remember that I drink oat milk" →
"Sure, I'll remember that!" → nothing written is the failure that makes a memory product look
like a party trick.

So the handful of phrasings that can only mean one thing are matched here and executed
outright. The model still speaks the reply — it is handed the tool result and answers from it
— but whether the memory changed no longer depends on the model choosing to call anything.

Deliberately narrow. Every pattern is anchored at the start of the utterance and requires an
explicit verb; anything conversational ("I think I'll remember that trip forever") falls
through to the model, where a missed call costs nothing.
"""

from __future__ import annotations

import re

from .memory_tools import ASK_ABOUT, FORGET, RECALL, REMEMBER

#: (pattern, tool, argument name). The first group, when present, is the argument.
_PATTERNS: tuple[tuple[re.Pattern[str], str, str | None], ...] = (
    (re.compile(r"^(?:please\s+)?(?:remember|note|keep in mind)(?:\s+that)?\s+(.+)$", re.IGNORECASE),
     REMEMBER, "text"),
    (re.compile(r"^(?:please\s+)?forget(?:\s+(?:what|everything))?"
                r"(?:\s+i\s+(?:said|told you))?(?:\s+about)?\s+(.+)$", re.IGNORECASE),
     FORGET, "query"),
    (re.compile(r"^what (?:do|can) you (?:remember|know)(?: about)?\s*(.*)$", re.IGNORECASE),
     RECALL, "query"),
    (re.compile(r"^(?:ask me (?:something|a question)|what do you want to know)"
                r"(?:\s+about\s+(?:me|myself))?\??$", re.IGNORECASE),
     ASK_ABOUT, None),
)

#: A crude slot guess for the shortcut path. The model picks the slot when it calls the tool
#: itself; when the shortcut fires there is nobody to ask, and everything landing in `misc`
#: makes the profile unreadable at exactly the moment it is projected on a wall.
_SLOT_HINTS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"\b(drink|eat|coffee|tea|milk|allerg|vegan|vegetarian|food)\b", re.IGNORECASE),
     "diet"),
    (re.compile(r"\b(wake|sleep|morning|evening|every day|weekday|weekend|standup|at \d)\b",
                re.IGNORECASE), "routine"),
    (re.compile(r"\b(don'?t|never|do not|stay (?:away|off)|quiet|leave me)\b", re.IGNORECASE),
     "boundary"),
    (re.compile(r"\b(wife|husband|partner|kid|son|daughter|cat|dog|roommate|flatmate)\b",
                re.IGNORECASE), "people"),
    (re.compile(r"\b(working on|building|project|shipping|deadline)\b", re.IGNORECASE),
     "project"),
    (re.compile(r"\b(my name is|call me|i am a|i'?m a|i work as)\b", re.IGNORECASE), "identity"),
    (re.compile(r"\b(like|love|hate|prefer|rather|favou?rite)\b", re.IGNORECASE), "preference"),
)


def slot_for(text: str) -> str:
    for pattern, slot in _SLOT_HINTS:
        if pattern.search(text or ""):
            return slot
    return "misc"


#: "remember to call mum" is a reminder, not a fact about the person. Storing it would put a
#: task into the identity profile, where it would be read back forever as something true.
_NOT_A_FACT = re.compile(r"^to\s+", re.IGNORECASE)


def intent_for(text: str) -> tuple[str, dict[str, str]] | None:
    """The memory tool this utterance plainly is, or None to let the model decide."""
    stripped = (text or "").strip()
    if not stripped:
        return None
    for pattern, tool, key in _PATTERNS:
        match = pattern.match(stripped)
        if match is None:
            continue
        if key is None:
            return tool, {}
        argument = (match.group(1) or "").strip().rstrip("?.!").strip()
        if tool == REMEMBER and (not argument or _NOT_A_FACT.match(argument)):
            return None
        if tool == FORGET and not argument:
            return None
        if tool == REMEMBER:
            return tool, {key: argument, "slot": slot_for(argument)}
        return tool, {key: argument or stripped}
    return None

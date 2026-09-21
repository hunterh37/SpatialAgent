"""The phrasings that can only mean one thing, and the ones that cannot."""

from __future__ import annotations

import pytest

from agentd.memory_intents import intent_for
from agentd.memory_tools import ASK_ABOUT, FORGET, RECALL, REMEMBER


@pytest.mark.parametrize(
    "text,tool,args",
    [
        ("remember that I drink oat flat whites", REMEMBER,
         {"text": "I drink oat flat whites", "slot": "diet"}),
        ("Please remember I hate mornings", REMEMBER,
         {"text": "I hate mornings", "slot": "preference"}),
        ("forget what I said about coffee", FORGET, {"query": "coffee"}),
        ("forget the cat thing", FORGET, {"query": "the cat thing"}),
        ("what do you remember about me?", RECALL, {"query": "me"}),
        ("what do you know about my routine", RECALL, {"query": "my routine"}),
        ("ask me something about myself", ASK_ABOUT, {}),
        ("ask me a question", ASK_ABOUT, {}),
    ],
)
def test_plain_memory_utterances(text, tool, args):
    assert intent_for(text) == (tool, args)


@pytest.mark.parametrize(
    "text",
    [
        "remember to call mum",          # a task, not a fact about the person
        "I'll never forget that trip",   # not a request
        "turn on the desk lamp",
        "what do you see?",
        "",
    ],
)
def test_everything_else_goes_to_the_model(text):
    assert intent_for(text) is None


@pytest.mark.parametrize(
    "text,slot",
    [
        ("remember I drink oat milk", "diet"),
        ("remember my standup is at 9:30 every weekday", "routine"),
        ("remember never to land on the plant", "boundary"),
        ("remember my cat is called Pixel", "people"),
        ("remember I am a designer", "identity"),
        ("remember the bins go out Tuesday", "misc"),
    ],
)
def test_the_shortcut_guesses_a_readable_slot(text, slot):
    """A profile that is all `misc` is a profile nobody can read at a glance."""
    assert intent_for(text)[1]["slot"] == slot

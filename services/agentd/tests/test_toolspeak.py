"""Only a reply that *is* a tool call is rescued. Everything else is speech."""

from __future__ import annotations

import pytest

from agentd.toolspeak import extract_call

KNOWN = {"forget_about_user", "remember_about_user", "set_light"}


@pytest.mark.parametrize(
    "reply,expected",
    [
        ('forget_about_user(query="the coffee thing")',
         ("forget_about_user", {"query": "the coffee thing"})),
        ("  remember_about_user(text='no shellfish', slot='diet')  ",
         ("remember_about_user", {"text": "no shellfish", "slot": "diet"})),
        ('set_light({"device_id": "light.desk", "on": true})',
         ("set_light", {"device_id": "light.desk", "on": True})),
        ("`set_light(device_id=light.desk, on=True)`",
         ("set_light", {"device_id": "light.desk", "on": True})),
    ],
)
def test_a_reply_that_is_a_call(reply, expected):
    assert extract_call(reply, KNOWN) == expected


@pytest.mark.parametrize(
    "reply",
    [
        "Sure — I'll call forget_about_user(query='coffee') for you.",  # mentioned, not made
        "unknown_tool(query='coffee')",                                  # not a tool
        "Okay, forgetting that.",                                        # ordinary speech
        "",
    ],
)
def test_speech_is_left_alone(reply):
    assert extract_call(reply, KNOWN) is None

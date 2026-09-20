from __future__ import annotations

from agentd.directives import directives_for
from mocks.scenario import Scenario


def test_walk_intent_resolves_to_known_place() -> None:
    scenario = Scenario.load("apartment")
    found = directives_for("Sure, heading to the kitchen now.", scenario.scene)
    assert [d.place for d in found] == ["kitchen"]
    assert found[0].kind == "walkTo"


def test_unknown_place_is_never_emitted() -> None:
    scenario = Scenario.load("apartment")
    assert directives_for("I'll walk to the basement.", scenario.scene) == []


def test_empty_room_produces_no_navigation() -> None:
    scenario = Scenario.load("empty_room")
    assert directives_for("Walking to the kitchen.", scenario.scene) == []


def test_partial_stream_text_is_safe() -> None:
    scenario = Scenario.load("apartment")
    # Called on every token; must not raise or emit on incomplete spans.
    assert directives_for("Sure, heading to the ki", scenario.scene) == []

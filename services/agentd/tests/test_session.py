"""The agent loop, headless. This is the test non-Mac contributors live in."""

from __future__ import annotations

from agentd.adapters.base import Chunk
from agentd.adapters.echo import EchoAdapter
from agentd.protocol import Directive, Token, ToolCall, UtteranceEnd
from agentd.session import Session
from agentd.tools import default_registry
from mocks.scenario import Scenario


async def _collect(session: Session, text: str) -> list:
    return [e async for e in session.handle_utterance("u1", text)]


async def test_character_reacts_before_model_output() -> None:
    session = Session(EchoAdapter(), default_registry())
    events = await _collect(session, "hi")
    # First two events are directives, emitted before the adapter is consulted (PRD 6).
    assert isinstance(events[0], Directive)
    assert events[0].directive.kind == "lookAt"
    assert events[1].directive.emotion == "thinking"


async def test_utterance_streams_tokens_and_closes() -> None:
    session = Session(EchoAdapter(), default_registry())
    events = await _collect(session, "hello there")
    assert any(isinstance(e, Token) for e in events)
    assert isinstance(events[-2], UtteranceEnd)
    assert events[-1].directive.kind == "idle"


async def test_walk_directive_emitted_mid_stream() -> None:
    scenario = Scenario.load("apartment")
    adapter = EchoAdapter(scripted=[
        Chunk(text="Sure, "), Chunk(text="heading to the "), Chunk(text="kitchen now."),
        Chunk(done=True),
    ])
    session = Session(adapter, default_registry())
    session.update_scene(scenario.scene)

    events = await _collect(session, "turn off the kitchen lights")
    walks = [e for e in events if isinstance(e, Directive) and e.directive.kind == "walkTo"]
    assert [w.directive.place for w in walks] == ["kitchen"]

    # The walk must arrive before the utterance ends, not after.
    assert events.index(walks[0]) < next(
        i for i, e in enumerate(events) if isinstance(e, UtteranceEnd)
    )


async def test_walk_directive_not_repeated() -> None:
    scenario = Scenario.load("apartment")
    adapter = EchoAdapter(scripted=[
        Chunk(text="Going to the kitchen. "), Chunk(text="Now at the kitchen."), Chunk(done=True),
    ])
    session = Session(adapter, default_registry())
    session.update_scene(scenario.scene)
    events = await _collect(session, "kitchen please")
    walks = [e for e in events if isinstance(e, Directive) and e.directive.kind == "walkTo"]
    assert len(walks) == 1


async def test_tool_call_carries_server_asserted_safety() -> None:
    adapter = EchoAdapter(scripted=[
        Chunk(tool_calls=[{"function": {"name": "set_lock", "arguments": {"locked": False}}}]),
        Chunk(done=True),
    ])
    session = Session(adapter, default_registry())
    calls = [e for e in await _collect(session, "unlock the door") if isinstance(e, ToolCall)]
    assert len(calls) == 1
    assert calls[0].safety == "unsafe"


async def test_scene_and_devices_reach_the_prompt() -> None:
    scenario = Scenario.load("apartment")
    session = Session(EchoAdapter(), default_registry())
    session.update_scene(scenario.scene)
    session.update_devices(scenario.devices)

    from agentd.prompt import build_system_prompt

    prompt = build_system_prompt(session.scene, session.devices)
    assert "kitchen" in prompt
    assert "light.kitchen" in prompt


async def test_empty_room_prompt_states_no_places() -> None:
    from agentd.prompt import build_system_prompt

    scenario = Scenario.load("empty_room")
    prompt = build_system_prompt(scenario.scene, scenario.devices)
    assert "no named places" in prompt

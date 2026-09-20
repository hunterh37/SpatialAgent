"""The agent loop, headless. This is the test non-Mac contributors live in."""

from __future__ import annotations

import asyncio

from agentd.adapters.base import Chunk
from agentd.adapters.echo import EchoAdapter
from agentd.executors import ClientExecutor, ServerExecutor
from agentd.protocol import Directive, RequestPlace, Token, ToolCall, UtteranceEnd
from agentd.session import Session
from agentd.tools import default_registry
from mocks.mock_home import MockHome
from mocks.scenario import Scenario

# No client is attached in these tests, so a client-executed call must fail fast rather
# than sit on the production timeout.
FAST_CLIENT = 0.05


async def _collect(session: Session, text: str, is_final: bool = True) -> list:
    return [e async for e in session.handle_utterance("u1", text, is_final)]


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
    session = Session(adapter, default_registry(), ClientExecutor(timeout=FAST_CLIENT))
    calls = [e for e in await _collect(session, "unlock the door") if isinstance(e, ToolCall)]
    assert len(calls) == 1
    assert calls[0].safety == "unsafe"
    assert calls[0].executedBy == "client"


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


# --- server-side execution (docs/middle-layer-todo.md 1) ----------------------


def _lock_session(home: MockHome, extra: list[Chunk] | None = None) -> Session:
    adapter = EchoAdapter(scripted=[
        Chunk(tool_calls=[{"function": {"name": "set_lock", "arguments": {
            "device_id": "lock.front", "locked": False}}}]),
        *(extra or []),
        Chunk(done=True),
    ])
    return Session(
        adapter, default_registry(), ServerExecutor(home, timeout=1.0, confirm_timeout=1.0)
    )


async def test_server_executed_unsafe_tool_waits_for_approval() -> None:
    """The client half of this contract is
    AgentSessionTests.testServerAssertedSafeOnALockStillRequiresConfirmation."""
    home = MockHome(Scenario.load("apartment").devices)
    session = _lock_session(home)

    async def approve() -> None:
        for _ in range(100):
            await asyncio.sleep(0.01)
            call = next((c for c in session._pending_names), None)
            if call and session.resolve_confirmation(call, True):
                return

    task = asyncio.create_task(approve())
    events = await _collect(session, "unlock the front door")
    await task

    call = next(e for e in events if isinstance(e, ToolCall))
    assert call.executedBy == "server"
    assert call.safety == "unsafe"
    assert home.devices["lock.front"].state["locked"] is False


async def test_server_never_executes_unsafe_without_approval() -> None:
    home = MockHome(Scenario.load("apartment").devices)
    session = _lock_session(home)
    await _collect(session, "unlock the front door")  # nobody approves; the wait times out
    assert home.devices["lock.front"].state["locked"] is True
    assert home.calls == []


async def test_declined_confirmation_does_not_execute() -> None:
    home = MockHome(Scenario.load("apartment").devices)
    session = _lock_session(home)

    async def decline() -> None:
        for _ in range(100):
            await asyncio.sleep(0.01)
            call = next((c for c in session._pending_names), None)
            if call and session.resolve_confirmation(call, False):
                return

    task = asyncio.create_task(decline())
    await _collect(session, "unlock the front door")
    await task
    assert home.devices["lock.front"].state["locked"] is True
    assert home.calls == []


async def test_safe_tool_executes_server_side_without_approval() -> None:
    home = MockHome(Scenario.load("apartment").devices)
    adapter = EchoAdapter(scripted=[
        Chunk(tool_calls=[{"function": {"name": "set_light", "arguments": {
            "device_id": "light.desk", "on": True, "brightness": 40}}}]),
        Chunk(done=True),
    ])
    session = Session(adapter, default_registry(), ServerExecutor(home, timeout=1.0))
    await _collect(session, "desk lamp on")
    assert home.devices["light.desk"].state == {"on": True, "brightness": 40}


async def test_tool_result_reaches_the_next_model_round() -> None:
    home = MockHome(Scenario.load("apartment").devices)
    adapter = EchoAdapter(scripted=[
        Chunk(tool_calls=[{"function": {"name": "get_device_state", "arguments": {
            "device_id": "light.kitchen"}}}]),
        Chunk(done=True),
    ])
    session = Session(adapter, default_registry(), ServerExecutor(home, timeout=1.0))
    await _collect(session, "is the kitchen light on")
    tool_messages = [m for m in session.history if m["role"] == "tool"]
    assert tool_messages and "light.kitchen" in tool_messages[0]["content"]


async def test_executed_tool_updates_the_device_snapshot() -> None:
    scenario = Scenario.load("apartment")
    home = MockHome(scenario.devices)
    adapter = EchoAdapter(scripted=[
        Chunk(tool_calls=[{"function": {"name": "set_light", "arguments": {
            "device_id": "light.kitchen", "on": False}}}]),
        Chunk(done=True),
    ])
    session = Session(adapter, default_registry(), ServerExecutor(home, timeout=1.0))
    session.update_devices([d.model_copy(deep=True) for d in scenario.devices])
    await _collect(session, "kitchen light off")
    kitchen = next(d for d in session.devices if d.id == "light.kitchen")
    assert kitchen.state["on"] is False


# --- requestPlace (todo 3) ----------------------------------------------------


async def test_unknown_place_is_asked_for_in_character() -> None:
    adapter = EchoAdapter(scripted=[
        Chunk(tool_calls=[{"function": {"name": "ask_for_place",
                                        "arguments": {"name": "garage"}}}]),
        Chunk(done=True),
    ])
    session = Session(adapter, default_registry())
    events = await _collect(session, "go to the garage")
    asks = [e for e in events if isinstance(e, RequestPlace)]
    assert len(asks) == 1
    assert asks[0].name == "garage"


async def test_place_is_only_asked_for_once() -> None:
    def session_with(name: str) -> Session:
        return Session(
            EchoAdapter(scripted=[
                Chunk(tool_calls=[{"function": {"name": "ask_for_place",
                                                "arguments": {"name": name}}}]),
                Chunk(done=True),
            ]),
            default_registry(),
        )

    session = session_with("garage")
    await _collect(session, "go to the garage")
    session.adapter = session_with("garage").adapter
    events = await _collect(session, "go to the garage again")
    assert [e for e in events if isinstance(e, RequestPlace)] == []


async def test_known_place_is_never_asked_for() -> None:
    adapter = EchoAdapter(scripted=[
        Chunk(tool_calls=[{"function": {"name": "ask_for_place",
                                        "arguments": {"name": "kitchen"}}}]),
        Chunk(done=True),
    ])
    session = Session(adapter, default_registry())
    session.update_scene(Scenario.load("apartment").scene)
    events = await _collect(session, "go to the kitchen")
    assert [e for e in events if isinstance(e, RequestPlace)] == []


# --- partial transcripts (todo 7) --------------------------------------------


async def test_partial_transcript_moves_the_character_but_not_the_model() -> None:
    session = Session(EchoAdapter(), default_registry())
    events = await _collect(session, "turn off the", is_final=False)
    assert all(isinstance(e, Directive) for e in events)
    assert not any(isinstance(e, Token) for e in events)
    assert session.history == []


# --- ambient (todo 2) ---------------------------------------------------------


async def test_device_change_becomes_an_ambient_event() -> None:
    scenario = Scenario.load("apartment")
    session = Session(EchoAdapter(), default_registry())
    session.update_devices([d.model_copy(deep=True) for d in scenario.devices])

    after = [d.model_copy(deep=True) for d in scenario.devices]
    next(d for d in after if d.id == "sensor.doorbell").state["ringing"] = True

    events = session.update_devices(after)
    assert len(events) == 1
    assert events[0].kind == "doorbell"
    assert events[0].interrupt == "now"


async def test_first_device_snapshot_is_not_ambient() -> None:
    scenario = Scenario.load("apartment")
    session = Session(EchoAdapter(), default_registry())
    assert session.update_devices(scenario.devices) == []


async def test_reasoning_traces_are_never_spoken() -> None:
    adapter = EchoAdapter(scripted=[
        Chunk(text="<think>the kitchen "), Chunk(text="light is on</think>"),
        Chunk(text="Turning it off."), Chunk(done=True),
    ])
    session = Session(adapter, default_registry())
    events = await _collect(session, "kitchen light off")
    spoken = "".join(e.text for e in events if isinstance(e, Token))
    assert spoken == "Turning it off."
    assert "think" not in session.history[-1]["content"]


async def test_acting_on_a_device_walks_to_its_room() -> None:
    """A 3B model acts without narrating the walk; the character should still move."""
    scenario = Scenario.load("apartment")
    home = MockHome(scenario.devices)
    adapter = EchoAdapter(scripted=[
        Chunk(tool_calls=[{"function": {"name": "set_light", "arguments": {
            "device_id": "light.kitchen", "on": False}}}]),
        Chunk(done=True),
    ])
    session = Session(adapter, default_registry(), ServerExecutor(home, timeout=1.0))
    session.update_scene(scenario.scene)
    session.update_devices([d.model_copy(deep=True) for d in scenario.devices])

    events = await _collect(session, "kitchen light off")
    walks = [e for e in events if isinstance(e, Directive) and e.directive.kind == "walkTo"]
    assert [w.directive.place for w in walks] == ["kitchen"]
    # The walk is announced before the call it belongs to.
    assert events.index(walks[0]) < next(
        i for i, e in enumerate(events) if isinstance(e, ToolCall)
    )


async def test_device_in_a_room_with_no_named_place_does_not_walk() -> None:
    """light.desk lives in room 'office', which the apartment fixture never names."""
    scenario = Scenario.load("apartment")
    home = MockHome(scenario.devices)
    adapter = EchoAdapter(scripted=[
        Chunk(tool_calls=[{"function": {"name": "set_light", "arguments": {
            "device_id": "light.desk", "on": True}}}]),
        Chunk(done=True),
    ])
    session = Session(adapter, default_registry(), ServerExecutor(home, timeout=1.0))
    session.update_scene(scenario.scene)
    session.update_devices([d.model_copy(deep=True) for d in scenario.devices])

    events = await _collect(session, "desk lamp on")
    assert not [e for e in events if isinstance(e, Directive) and e.directive.kind == "walkTo"]


async def test_the_walk_is_not_repeated_for_a_second_call_in_the_same_room() -> None:
    scenario = Scenario.load("apartment")
    home = MockHome(scenario.devices)
    adapter = EchoAdapter(scripted=[
        Chunk(tool_calls=[
            {"function": {"name": "set_light", "arguments": {
                "device_id": "light.kitchen", "on": False}}},
            {"function": {"name": "get_device_state", "arguments": {
                "device_id": "light.kitchen"}}},
        ]),
        Chunk(done=True),
    ])
    session = Session(adapter, default_registry(), ServerExecutor(home, timeout=1.0))
    session.update_scene(scenario.scene)
    session.update_devices([d.model_copy(deep=True) for d in scenario.devices])

    events = await _collect(session, "kitchen light off then check it")
    walks = [e for e in events if isinstance(e, Directive) and e.directive.kind == "walkTo"]
    assert len(walks) == 1


# --- movement is a tool call, not a regex on prose --------------------------


def _walk_session(place: str, scene=True) -> Session:
    session = Session(
        EchoAdapter(scripted=[
            Chunk(tool_calls=[{"function": {"name": "walk_to",
                                            "arguments": {"place": place}}}]),
            Chunk(done=True),
        ]),
        default_registry(),
    )
    if scene:
        session.update_scene(Scenario.load("apartment").scene)
    return session


async def test_walk_to_tool_emits_a_directive() -> None:
    session = _walk_session("kitchen")
    events = await _collect(session, "go to the kitchen")
    walks = [e for e in events if isinstance(e, Directive) and e.directive.kind == "walkTo"]
    assert [w.directive.place for w in walks] == ["kitchen"]
    # It never reaches an executor: nothing in the home was asked to do anything.
    assert not [e for e in events if isinstance(e, ToolCall)]


async def test_walk_to_matches_a_place_name_case_insensitively() -> None:
    session = _walk_session("Front Door")
    events = await _collect(session, "go to the door")
    walks = [e for e in events if isinstance(e, Directive) and e.directive.kind == "walkTo"]
    assert [w.directive.place for w in walks] == ["front door"]


async def test_walk_to_an_invented_place_moves_nothing() -> None:
    """The failure mode this prevents is a character walking into a wall."""
    session = _walk_session("conservatory")
    events = await _collect(session, "go to the conservatory")
    assert not [e for e in events if isinstance(e, Directive) and e.directive.kind == "walkTo"]
    # The model is told what does exist, so its next turn can recover.
    tool_reply = next(m for m in session.history if m["role"] == "tool")
    assert "no such place" in tool_reply["content"]
    assert "kitchen" in tool_reply["content"]


async def test_look_at_defaults_to_the_user() -> None:
    session = Session(
        EchoAdapter(scripted=[
            Chunk(tool_calls=[{"function": {"name": "look_at", "arguments": {"target": "me"}}}]),
            Chunk(done=True),
        ]),
        default_registry(),
    )
    session.update_scene(Scenario.load("apartment").scene)
    events = await _collect(session, "look at me")
    looks = [
        e for e in events
        if isinstance(e, Directive) and e.directive.kind == "lookAt" and e.directive.target
    ]
    assert looks[-1].directive.target == "user"


async def test_look_at_a_known_place_targets_that_place() -> None:
    session = Session(
        EchoAdapter(scripted=[
            Chunk(tool_calls=[{"function": {"name": "look_at",
                                            "arguments": {"target": "couch"}}}]),
            Chunk(done=True),
        ]),
        default_registry(),
    )
    session.update_scene(Scenario.load("apartment").scene)
    events = await _collect(session, "look at the couch")
    place_looks = [
        e for e in events
        if isinstance(e, Directive) and e.directive.kind == "lookAt" and e.directive.place
    ]
    assert place_looks[0].directive.place == "couch"


async def test_the_server_waits_longer_for_a_human_than_for_a_machine() -> None:
    """The client's gate closes at 30s. If the server gave up at the same moment, a tap
    could land on a call it had already abandoned."""
    home = MockHome(Scenario.load("apartment").devices)
    executor = ServerExecutor(home, timeout=30.0)
    assert executor._confirm_timeout > executor._timeout

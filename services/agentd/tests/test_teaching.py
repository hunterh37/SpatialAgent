"""Teaching acts (spec/07-memory.md Teaching).

Teaching is the highest-risk path in the product (PRD 9), so every act is driven end to end
through the adapter: the model emits a tool call, the session turns it into a client-executed
`toolCall`, and the name that reaches the client is the name the user said.
"""

from __future__ import annotations

from typing import Any

from agentd.adapters.base import Chunk
from agentd.adapters.echo import EchoAdapter
from agentd.protocol import Directive, ToolCall
from agentd.session import Session
from agentd.teaching import (
    CORRECT_NAME,
    FORBID_REGION,
    NAME_ACTIVITY,
    NAME_OBJECT,
    NAME_PLACE,
    TEACHING_TOOLS,
    clean_name,
    hardness,
    teaching_tools,
)
from agentd.tools import default_registry


def call(tool: str, **args: Any) -> Chunk:
    return Chunk(tool_calls=[{"function": {"name": tool, "arguments": args}}])


async def drive(utterance: str, chunk: Chunk) -> list:
    session = Session(EchoAdapter(scripted=[chunk, Chunk(done=True)]), default_registry())
    return [e async for e in session.handle_utterance("u1", utterance)]


def teaching_calls(events: list) -> list[ToolCall]:
    return [e for e in events if isinstance(e, ToolCall) and e.name in TEACHING_TOOLS]


# --- the five acts ---------------------------------------------------------------------


async def test_naming_a_place_reaches_the_client_with_the_name() -> None:
    events = await drive("this is my workspace", call(NAME_PLACE, name="my workspace"))
    calls = teaching_calls(events)
    assert len(calls) == 1
    assert calls[0].name == NAME_PLACE
    assert calls[0].args["name"] == "my workspace"


async def test_naming_an_object_carries_a_device_binding_when_the_model_offers_one() -> None:
    events = await drive(
        "this is the coffee machine",
        call(NAME_OBJECT, name="the coffee machine", device_id="switch.coffee"),
    )
    calls = teaching_calls(events)
    assert calls[0].name == NAME_OBJECT
    assert calls[0].args["name"] == "the coffee machine"
    assert calls[0].args["device_id"] == "switch.coffee"


async def test_forbidding_a_region_defaults_to_hard() -> None:
    events = await drive("don't go here", call(FORBID_REGION))
    calls = teaching_calls(events)
    assert calls[0].name == FORBID_REGION
    assert calls[0].args["hard"] is True


async def test_forbidding_softly_is_possible_but_must_be_stated() -> None:
    events = await drive("be careful around this", call(FORBID_REGION, name="the vase", hard=False))
    calls = teaching_calls(events)
    assert calls[0].args["hard"] is False
    assert calls[0].args["name"] == "the vase"


async def test_naming_an_activity_reaches_the_client() -> None:
    events = await drive(
        "this is where I brainstorm", call(NAME_ACTIVITY, name="brainstorming")
    )
    calls = teaching_calls(events)
    assert calls[0].name == NAME_ACTIVITY
    assert calls[0].args["name"] == "brainstorming"


async def test_correcting_a_name_reaches_the_client() -> None:
    events = await drive("no, that's the kitchen", call(CORRECT_NAME, name="the kitchen"))
    calls = teaching_calls(events)
    assert calls[0].name == CORRECT_NAME
    assert calls[0].args["name"] == "the kitchen"


# --- what the client is handed -----------------------------------------------------------


async def test_every_act_is_client_executed_and_safe() -> None:
    for chunk, name in [
        (call(NAME_PLACE, name="desk"), NAME_PLACE),
        (call(NAME_OBJECT, name="kettle"), NAME_OBJECT),
        (call(FORBID_REGION), FORBID_REGION),
        (call(NAME_ACTIVITY, name="reading"), NAME_ACTIVITY),
        (call(CORRECT_NAME, name="kitchen"), CORRECT_NAME),
    ]:
        calls = teaching_calls(await drive("...", chunk))
        assert calls[0].executedBy == "client", name
        assert calls[0].safety == "safe", name


async def test_the_server_never_receives_or_sends_a_location() -> None:
    events = await drive("this is my desk", call(NAME_PLACE, name="my desk"))
    payload = teaching_calls(events)[0].args
    assert set(payload) == {"name"}


async def test_the_bird_looks_at_the_target_before_the_record_is_written() -> None:
    events = await drive("this is my desk", call(NAME_PLACE, name="my desk"))
    look = next(
        i for i, e in enumerate(events)
        if isinstance(e, Directive) and e.directive.kind == "lookAt" and e.directive.target == "place"
    )
    teach = next(i for i, e in enumerate(events) if isinstance(e, ToolCall))
    assert look < teach


async def test_an_act_with_no_name_asks_rather_than_writing_an_empty_record() -> None:
    events = await drive("this is my", call(NAME_PLACE, name="  "))
    assert teaching_calls(events) == []


async def test_forbidding_with_no_name_still_goes_through() -> None:
    # "don't go here" names nothing and is still a complete act.
    calls = teaching_calls(await drive("don't go here", call(FORBID_REGION)))
    assert calls[0].args.get("name") is None


# --- small-model hardening ---------------------------------------------------------------


def test_clean_name_strips_the_sentence_the_model_handed_back() -> None:
    assert clean_name("this is my workspace") == "my workspace"
    assert clean_name("This is the coffee machine") == "the coffee machine"
    assert clean_name('"the kitchen"') == "the kitchen"
    assert clean_name("that's the kitchen.") == "the kitchen"
    assert clean_name("where I brainstorm") == "brainstorm"
    assert clean_name("  ") == ""
    assert clean_name(None) == ""


def test_clean_name_does_not_rewrite_the_users_own_name() -> None:
    assert clean_name("Mum's chair") == "Mum's chair"
    assert clean_name("THE SHRINE") == "THE SHRINE"


def test_hardness_defaults_to_hard_and_accepts_string_booleans() -> None:
    assert hardness({}) is True
    assert hardness({"hard": False}) is False
    assert hardness({"hard": "false"}) is False
    assert hardness({"hard": "no"}) is False
    assert hardness({"hard": "true"}) is True


def test_all_five_acts_are_in_the_tool_surface() -> None:
    names = {t.name for t in teaching_tools()}
    assert names == TEACHING_TOOLS
    assert len(names) == 5


async def test_teaching_tools_are_offered_to_the_model() -> None:
    session = Session(EchoAdapter(), default_registry())
    assert TEACHING_TOOLS <= set(session.tools.names())


def test_the_prompt_tells_the_model_to_call_a_tool_not_narrate() -> None:
    from agentd.prompt import build_system_prompt
    from agentd.protocol import SceneSnapshot

    prompt = build_system_prompt(SceneSnapshot(places=[]), [])
    for tool in TEACHING_TOOLS:
        assert tool in prompt
    assert "Never answer a teaching sentence with words alone" in prompt


# --- disambiguation --------------------------------------------------------------------


def test_the_prompt_offers_exactly_two_answers_to_a_name_collision() -> None:
    from agentd.prompt import build_system_prompt
    from agentd.protocol import SceneSnapshot

    prompt = build_system_prompt(SceneSnapshot(places=[]), [])
    assert "exactly two answers" in prompt
    assert "Never overwrite a name they taught you without them choosing it." in prompt


async def test_a_correction_is_still_one_act_not_a_second_record() -> None:
    # The correction act carries only the corrected name; which record it re-targets is the
    # client's business, because the client is the only side that knows what was just taught.
    calls = teaching_calls(await drive("no, that's the kitchen", call(CORRECT_NAME, name="kitchen")))
    assert calls[0].name == CORRECT_NAME
    assert set(calls[0].args) == {"name"}

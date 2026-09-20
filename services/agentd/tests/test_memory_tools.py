"""Memory as a tool surface, driven through a session the way the model drives it."""

from __future__ import annotations

import pytest

from agentd.adapters import EchoAdapter
from agentd.memory_tools import ASK_ABOUT, FORGET, RECALL, REMEMBER, SET_PERCH, UPDATE
from agentd.profile import ProfileStore
from agentd.protocol import MapPlace, SceneSnapshot, ToolCall
from agentd.session import Session
from agentd.tools import default_registry


def session(tmp_path) -> Session:
    return Session(
        EchoAdapter(delay=0.0),
        default_registry(),
        profile=ProfileStore(tmp_path / "p.json"),
    )


async def dispatch(sess: Session, name: str, args: dict) -> list:
    return [event async for event in sess._dispatch("call-1", name, args)]


def test_every_memory_tool_is_offered_to_the_model(tmp_path):
    names = session(tmp_path).tools.names()
    for tool in (REMEMBER, RECALL, FORGET, UPDATE, ASK_ABOUT, SET_PERCH):
        assert tool in names


@pytest.mark.asyncio
async def test_remember_writes_a_durable_fact(tmp_path):
    sess = session(tmp_path)
    await dispatch(sess, REMEMBER, {"text": "drinks oat milk", "slot": "diet"})
    assert [f.text for f in ProfileStore(tmp_path / "p.json").facts] == ["drinks oat milk"]


@pytest.mark.asyncio
async def test_recall_reports_nothing_rather_than_inventing(tmp_path):
    sess = session(tmp_path)
    await dispatch(sess, RECALL, {"query": "favourite colour"})
    assert "nothing remembered" in sess.history[-1]["content"]


@pytest.mark.asyncio
async def test_forget_by_description(tmp_path):
    sess = session(tmp_path)
    sess.profile.remember("drinks oat flat whites", "diet")
    await dispatch(sess, FORGET, {"query": "flat whites"})
    assert len(sess.profile) == 0
    assert "drinks oat flat whites" in sess.history[-1]["content"]


@pytest.mark.asyncio
async def test_update_corrects_rather_than_duplicating(tmp_path):
    sess = session(tmp_path)
    fact = sess.profile.remember("drinks cow milk", "diet")
    await dispatch(sess, UPDATE, {"fact_id": fact.id, "text": "drinks oat milk"})
    assert len(sess.profile) == 1
    assert sess.profile.get(fact.id).text == "drinks oat milk"


@pytest.mark.asyncio
async def test_ask_about_user_hands_back_a_question(tmp_path):
    sess = session(tmp_path)
    await dispatch(sess, ASK_ABOUT, {})
    assert '"ask"' in sess.history[-1]["content"]
    assert sess.curiosity.open_question is not None


@pytest.mark.asyncio
async def test_the_perch_is_taught_on_the_client(tmp_path):
    """A perch is a place, so the coordinate stays on the headset like every other place."""
    sess = session(tmp_path)
    sess.update_scene(SceneSnapshot(places=[MapPlace(name="bookshelf")]))
    events = await dispatch(sess, SET_PERCH, {"place": "bookshelf"})
    calls = [e for e in events if isinstance(e, ToolCall)]
    assert calls and calls[0].executedBy == "client"
    assert calls[0].args == {"kind": "perch", "place": "bookshelf"}


@pytest.mark.asyncio
async def test_an_answer_to_an_open_question_is_banked(tmp_path):
    sess = session(tmp_path)
    question = sess.curiosity.next_question(force=True)
    async for _ in sess.handle_utterance("u1", "call me Hunter"):
        pass
    stored = [f for f in sess.profile.facts if f.question == question.key]
    assert stored and stored[0].text == "call me Hunter"


@pytest.mark.asyncio
async def test_a_refusal_is_not_stored_as_a_fact(tmp_path):
    sess = session(tmp_path)
    sess.curiosity.next_question(force=True)
    async for _ in sess.handle_utterance("u1", "not now"):
        pass
    assert len(sess.profile) == 0


def test_the_profile_reaches_the_prompt(tmp_path):
    sess = session(tmp_path)
    sess.profile.remember("has a cat called Pixel", "people")
    assert "Pixel" in sess._messages()[0]["content"]


def test_a_perch_place_is_named_in_the_prompt(tmp_path):
    sess = session(tmp_path)
    sess.update_scene(SceneSnapshot(places=[MapPlace(name="bookshelf", kind="perch")]))
    assert "Your perch is the bookshelf" in sess._messages()[0]["content"]

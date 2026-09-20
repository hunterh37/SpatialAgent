"""The question engine: asks once, asks about the room first, paces itself."""

from __future__ import annotations

from agentd.curiosity import MIN_QUIET, Curiosity
from agentd.profile import ProfileStore
from agentd.protocol import MapPlace, SceneSnapshot


def planner(tmp_path, gap: float = 0.0) -> Curiosity:
    return Curiosity(ProfileStore(tmp_path / "p.json"), min_gap=gap)


def test_room_questions_come_first(tmp_path):
    scene = SceneSnapshot(places=[MapPlace(name="desk")])
    question = planner(tmp_path).next_question(scene, force=True)
    assert question is not None and "desk" in question.text


def test_a_question_is_asked_once(tmp_path):
    curiosity = planner(tmp_path)
    first = curiosity.next_question(force=True)
    curiosity.drop()
    second = curiosity.next_question(force=True)
    assert first is not None and second is not None
    assert first.key != second.key


def test_an_answer_becomes_a_fact_in_the_right_slot(tmp_path):
    curiosity = planner(tmp_path)
    question = curiosity.next_question(force=True)
    curiosity.answer("call me Hunter")
    fact = curiosity.profile.facts[0]
    assert fact.text == "call me Hunter"
    assert fact.slot == question.slot
    assert fact.question == question.key


def test_it_will_not_interrupt(tmp_path):
    curiosity = planner(tmp_path)
    assert curiosity.next_question(quiet_for=MIN_QUIET - 1) is None


def test_one_open_question_at_a_time(tmp_path):
    curiosity = planner(tmp_path)
    assert curiosity.next_question() is not None
    assert curiosity.next_question() is None


def test_answered_questions_are_never_re_asked(tmp_path):
    curiosity = planner(tmp_path)
    asked = curiosity.next_question(force=True)
    curiosity.answer("call me Hunter")
    keys = {q.key for q in curiosity.remaining()}
    assert asked.key not in keys


def test_new_places_create_new_questions(tmp_path):
    curiosity = planner(tmp_path)
    before = len(curiosity.remaining())
    after = len(curiosity.remaining(SceneSnapshot(places=[MapPlace(name="loft")])))
    assert after > before

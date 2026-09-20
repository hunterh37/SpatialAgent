"""The profile store: the claims are durability, dedup, edit and portability."""

from __future__ import annotations

import json

from agentd.profile import Fact, ProfileStore


def test_survives_a_restart(tmp_path):
    path = tmp_path / "p.json"
    ProfileStore(path).remember("drinks oat milk", "diet")
    # A new store is a new process as far as this test is concerned.
    assert [f.text for f in ProfileStore(path).facts] == ["drinks oat milk"]


def test_remembering_twice_is_one_fact(tmp_path):
    store = ProfileStore(tmp_path / "p.json")
    first = store.remember("drinks oat milk", "diet")
    again = store.remember("Drinks oat milk.", "diet")
    assert first.id == again.id
    assert len(store) == 1


def test_correction_keeps_the_id(tmp_path):
    store = ProfileStore(tmp_path / "p.json")
    fact = store.remember("drinks cow milk", "diet")
    updated = store.update(fact.id, text="drinks oat milk")
    assert updated is not None and updated.id == fact.id
    assert updated.text == "drinks oat milk"
    assert len(store) == 1


def test_forget_by_description(tmp_path):
    store = ProfileStore(tmp_path / "p.json")
    store.remember("drinks oat flat whites", "diet")
    store.remember("works at a standing desk", "identity")
    dropped = store.forget_matching("coffee flat whites")
    assert [f.text for f in dropped] == ["drinks oat flat whites"]
    assert len(store) == 1


def test_search_is_scored_not_random(tmp_path):
    store = ProfileStore(tmp_path / "p.json")
    store.remember("has a cat called Pixel", "people")
    store.remember("likes warm lighting", "preference")
    hits = store.search("what is the cat called")
    assert hits and hits[0].text.startswith("has a cat")


def test_recall_leaves_a_trace(tmp_path):
    store = ProfileStore(tmp_path / "p.json")
    fact = store.remember("has a cat called Pixel", "people")
    store.search("cat")
    assert store.get(fact.id).uses == 1


def test_export_import_round_trips(tmp_path):
    source = ProfileStore(tmp_path / "a.json")
    source.remember("goes by Hunter", "identity")
    source.remember("no shellfish", "diet")

    target = ProfileStore(tmp_path / "b.json")
    added = target.import_facts(source.export())
    assert added == 2
    assert {f.id for f in target.facts} == {f.id for f in source.facts}


def test_import_does_not_duplicate(tmp_path):
    store = ProfileStore(tmp_path / "p.json")
    store.remember("goes by Hunter", "identity")
    assert store.import_facts(store.export()) == 0


def test_a_corrupt_file_does_not_stop_the_agent(tmp_path):
    path = tmp_path / "p.json"
    path.write_text("{not json")
    store = ProfileStore(path)
    assert len(store) == 0
    # The user's bytes are kept, not deleted.
    assert (tmp_path / "p.corrupt.json").exists()


def test_digest_is_grouped_and_capped(tmp_path):
    store = ProfileStore(tmp_path / "p.json")
    for i in range(30):
        store.remember(f"fact number {i}", "misc")
    digest = store.digest(limit=5)
    assert digest.startswith("misc:")
    assert digest.count("- ") == 5


def test_a_fact_needs_text():
    try:
        Fact.from_dict({"slot": "misc"})
    except ValueError:
        return
    raise AssertionError("an empty fact was accepted")


def test_file_is_plain_readable_json(tmp_path):
    path = tmp_path / "p.json"
    ProfileStore(path).remember("goes by Hunter", "identity")
    raw = json.loads(path.read_text())
    assert raw["facts"][0]["text"] == "goes by Hunter"
    assert raw["schema"] == 1

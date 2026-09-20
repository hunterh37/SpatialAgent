"""The abstracted map (spec/07-memory.md Enforcement).

`agentd` receives names, kinds and coarse relationships. It never receives coordinates,
camera frames or reconstructions. These tests hold that line at the type level, because the
privacy claim in PRD 8 is only as strong as the payload that carries it.
"""

from __future__ import annotations

import json

from agentd.prompt import build_system_prompt
from agentd.protocol import (
    Device,
    MapActivityRef,
    MapObjectRef,
    MapPlace,
    MapRuleRef,
    SceneSnapshot,
)


def taught_room() -> SceneSnapshot:
    return SceneSnapshot(
        places=[
            MapPlace(name="kitchen", kind="generic"),
            MapPlace(name="desk", kind="workspace"),
            MapPlace(name="the sill", kind="perch", navigable=False),
        ],
        objects=[
            MapObjectRef(name="coffee machine", deviceId="light.kitchen", place="kitchen"),
            MapObjectRef(name="the plant"),
        ],
        rules=[
            MapRuleRef(kind="forbidden", severity="hard", name="the shrine"),
            MapRuleRef(kind="fragile", severity="soft", name="the vase", place="desk"),
            MapRuleRef(kind="quiet", severity="soft", name="the study", place="desk"),
        ],
        activities=[MapActivityRef(name="brainstorming", place="desk")],
        userPlace="desk",
        floorArea=46.0,
    )


def test_prompt_describes_the_taught_room() -> None:
    prompt = build_system_prompt(taught_room(), [])

    # Places, by name, and only the ones it can actually reach.
    assert "kitchen" in prompt
    assert "desk" in prompt
    # Objects and their device bindings.
    assert "coffee machine" in prompt
    assert "light.kitchen" in prompt
    # Rules, as instructions rather than as data.
    assert "the shrine" in prompt
    assert "never go there" in prompt
    assert "the vase" in prompt
    # Activities and where the user is.
    assert "brainstorming" in prompt
    assert "The user is in the desk right now." in prompt


def test_unreachable_places_are_named_but_excluded_from_walk_to() -> None:
    prompt = build_system_prompt(taught_room(), [])
    walk_line = next(line for line in prompt.splitlines() if line.startswith("Places you can"))
    assert "the sill" not in walk_line
    assert "cannot reach them right now" in prompt
    assert "the sill" in prompt


def test_empty_map_says_so_rather_than_inventing_places() -> None:
    prompt = build_system_prompt(SceneSnapshot(places=[]), [])
    assert "no named places" in prompt


def test_devices_still_reach_the_prompt() -> None:
    device = Device(id="light.kitchen", name="Kitchen light", kind="light", room="kitchen")
    prompt = build_system_prompt(taught_room(), [device])
    assert "Kitchen light" in prompt


def _numbers_in(payload: object, path: str = "") -> list[str]:
    """Every numeric leaf in the payload, with its path."""
    found: list[str] = []
    if isinstance(payload, dict):
        for key, value in payload.items():
            found += _numbers_in(value, f"{path}.{key}")
    elif isinstance(payload, list):
        for index, value in enumerate(payload):
            found += _numbers_in(value, f"{path}[{index}]")
    elif isinstance(payload, bool):
        pass
    elif isinstance(payload, (int, float)):
        found.append(path)
    return found


def test_no_coordinate_field_exists_anywhere_in_the_abstracted_payload() -> None:
    payload = json.loads(taught_room().model_dump_json())
    numbers = _numbers_in(payload)
    # floorArea is the one number the server is allowed: it is a scalar about the room's
    # size, not a position in it, and the placement rules in spec 05 need it.
    assert numbers == [".floorArea"], numbers


def test_the_scene_type_has_nowhere_to_put_a_position() -> None:
    fields = set(SceneSnapshot.model_fields)
    assert fields == {"places", "objects", "rules", "activities", "userPlace", "floorArea"}
    for model in (MapPlace, MapObjectRef, MapRuleRef, MapActivityRef):
        for name, field in model.model_fields.items():
            assert "Vec3" not in str(field.annotation), f"{model.__name__}.{name}"

    schema = json.dumps(SceneSnapshot.model_json_schema())
    assert "position" not in schema
    assert "Vec3" not in schema


def test_navigable_place_names_excludes_unrelocalized_anchors() -> None:
    assert taught_room().navigable_place_names() == ["kitchen", "desk"]
    assert taught_room().has_place("KITCHEN")

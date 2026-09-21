from __future__ import annotations

from agentd.tools import default_registry
from mocks.mock_home import MockHome
from mocks.scenario import Scenario


def test_lock_is_unsafe_and_light_is_safe() -> None:
    tools = default_registry()
    assert tools.safety_of("set_lock") == "unsafe"
    assert tools.safety_of("set_light") == "safe"


def test_unknown_tool_fails_closed() -> None:
    assert default_registry().safety_of("rm_rf") == "unsafe"


def test_mock_home_mutates_state() -> None:
    scenario = Scenario.load("apartment")
    home = MockHome(scenario.devices)
    ok, _payload, error = home.execute("set_light", {"device_id": "light.kitchen", "on": False})
    assert ok and error is None
    assert home.devices["light.kitchen"].state["on"] is False


def test_mock_home_rejects_wrong_kind() -> None:
    scenario = Scenario.load("apartment")
    home = MockHome(scenario.devices)
    ok, _, error = home.execute("set_light", {"device_id": "lock.front", "on": True})
    assert not ok and error


def test_required_is_a_name_list_not_a_property_flag() -> None:
    """Ollama rejects `required: true` inside a property with a 400."""
    schema = default_registry().get("set_light").as_schema()
    params = schema["function"]["parameters"]
    assert params["required"] == ["device_id", "on"]
    assert all("required" not in spec for spec in params["properties"].values())


def test_every_tool_schema_is_wire_valid() -> None:
    for schema in default_registry().schemas():
        params = schema["function"]["parameters"]
        assert isinstance(params["required"], list)
        for spec in params["properties"].values():
            assert set(spec) <= {"type", "description", "enum", "items"}


def test_string_booleans_from_small_models_are_coerced() -> None:
    """A 3B model emits `"false"`. `bool("false")` is True — the opposite of the request."""
    tools = default_registry()
    args = tools.coerce("set_light", {"device_id": "light.kitchen", "on": "false",
                                      "brightness": "0"})
    assert args == {"device_id": "light.kitchen", "on": False, "brightness": 0}


def test_coercion_covers_every_boolean_spelling() -> None:
    tools = default_registry()
    for text, expected in (("true", True), ("False", False), ("on", True), ("0", False)):
        assert tools.coerce("set_lock", {"locked": text})["locked"] is expected


def test_unknown_tools_and_extra_keys_pass_through() -> None:
    tools = default_registry()
    assert tools.coerce("nonexistent", {"a": "1"}) == {"a": "1"}
    assert tools.coerce("set_light", {"mystery": "1"}) == {"mystery": "1"}

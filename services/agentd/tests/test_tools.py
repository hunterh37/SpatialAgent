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
    ok, payload, error = home.execute("set_light", {"device_id": "light.kitchen", "on": False})
    assert ok and error is None
    assert home.devices["light.kitchen"].state["on"] is False


def test_mock_home_rejects_wrong_kind() -> None:
    scenario = Scenario.load("apartment")
    home = MockHome(scenario.devices)
    ok, _, error = home.execute("set_light", {"device_id": "lock.front", "on": True})
    assert not ok and error

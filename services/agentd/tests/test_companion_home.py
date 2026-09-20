"""The Mac companion as a `HomeExecutor` (phase E).

Nothing in the agent loop changes when this backend lands, so these tests are about the
backend alone: what it does when the companion answers, refuses, or is not there at all.
"""

from __future__ import annotations

from typing import Any

import pytest

from agentd.adapters.echo import EchoAdapter
from agentd.executors import ServerExecutor
from agentd.home import CompanionHome, CompanionUnavailable
from agentd.protocol import Device
from agentd.session import Session
from agentd.tools import default_registry


class FakeCompanion:
    """Stands in for the Mac app."""

    def __init__(self, *, up: bool = True) -> None:
        self.up = up
        self.calls: list[tuple[str, str, dict[str, Any] | None]] = []
        self.devices = [
            {"id": "light.kitchen", "name": "Kitchen Ceiling", "kind": "light", "room": "Kitchen"}
        ]
        self.result: dict[str, Any] = {"ok": True, "payload": {"on": True}}

    def __call__(self, method: str, path: str, body: dict[str, Any] | None) -> Any:
        self.calls.append((method, path, body))
        if not self.up:
            raise CompanionUnavailable("not running")
        if path == "/devices":
            return self.devices
        if path == "/health":
            return {"ok": True}
        return self.result


def test_executing_a_tool_goes_to_the_companion() -> None:
    fake = FakeCompanion()
    home = CompanionHome(transport=fake)

    ok, payload, error = home.execute("set_light", {"device_id": "light.kitchen", "on": True})
    assert ok
    assert error is None
    assert payload == {"id": "light.kitchen", "state": {"on": True}}
    assert fake.calls[-1][:2] == ("POST", "/execute")
    assert fake.calls[-1][2] == {"tool": "set_light", "args": {"device_id": "light.kitchen", "on": True}}


def test_a_refusal_comes_back_as_a_failure_with_a_reason() -> None:
    fake = FakeCompanion()
    fake.result = {"ok": False, "error": "Front Door can't do light."}
    home = CompanionHome(transport=fake)

    ok, payload, error = home.execute("set_light", {"device_id": "lock.front", "on": True})
    assert not ok
    assert payload == {}
    assert error == "Front Door can't do light."


def test_a_missing_companion_fails_loudly_rather_than_silently_doing_nothing() -> None:
    home = CompanionHome(transport=FakeCompanion(up=False))
    ok, _, error = home.execute("set_light", {"device_id": "light.kitchen", "on": True})
    assert not ok
    assert error and "not running" in error
    assert not home.is_available()


def test_devices_are_parsed_into_the_abstract_model() -> None:
    home = CompanionHome(transport=FakeCompanion())
    devices = home.snapshot()
    assert [d.id for d in devices] == ["light.kitchen"]
    assert isinstance(devices[0], Device)


def test_one_unreadable_device_does_not_lose_the_others() -> None:
    fake = FakeCompanion()
    fake.devices = [{"nonsense": True}, fake.devices[0]]
    assert [d.id for d in CompanionHome(transport=fake).snapshot()] == ["light.kitchen"]


def test_the_last_good_snapshot_survives_the_companion_going_away() -> None:
    fake = FakeCompanion()
    home = CompanionHome(transport=fake)
    assert home.snapshot()
    fake.up = False
    assert [d.id for d in home.snapshot()] == ["light.kitchen"]


@pytest.mark.asyncio
async def test_the_agent_loop_does_not_change_when_this_backend_is_used() -> None:
    # The whole claim of the executor boundary: a session built on the companion behaves
    # like any other server-executed session.
    home = CompanionHome(transport=FakeCompanion())
    session = Session(EchoAdapter(), default_registry(), executor=ServerExecutor(home))
    assert session.executor.location == "server"
    assert [d.id for d in session.devices] == ["light.kitchen"]


def test_agentd_plugs_the_companion_in_through_the_environment(monkeypatch) -> None:
    from agentd.server import build_executor

    monkeypatch.setenv("AGENTD_HOME", "companion")
    executor = build_executor()
    assert executor.location == "server"
    assert isinstance(executor.home, CompanionHome)

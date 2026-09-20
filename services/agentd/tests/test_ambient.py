"""The rate limiter is the whole point: the client renders whatever it is sent."""

from __future__ import annotations

from agentd.ambient import AmbientBus, RateLimiter, diff_devices
from mocks.scenario import Scenario


class FakeClock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now


def test_same_source_is_cooled_down() -> None:
    clock = FakeClock()
    limiter = RateLimiter(per_source=8.0, global_interval=0.0001, burst=100, clock=clock)
    assert limiter.allow("light.kitchen")
    clock.now = 1.0
    assert not limiter.allow("light.kitchen")
    clock.now = 9.0
    assert limiter.allow("light.kitchen")


def test_a_flickering_group_cannot_flood() -> None:
    clock = FakeClock()
    limiter = RateLimiter(per_source=0.0, global_interval=1.5, burst=3, clock=clock)
    allowed = sum(limiter.allow(f"light.{i}") for i in range(20))
    assert allowed == 3


def test_interrupt_is_classified_by_kind_not_by_device() -> None:
    bus = AmbientBus()
    assert bus.classify("sensor.doorbell", "doorbell", "ring").interrupt == "now"
    assert bus.classify("light.kitchen", "stateChange", "on").interrupt == "silent"
    assert bus.classify("media.oven", "finished", "done").interrupt == "passing"


def test_dropped_event_is_not_queued() -> None:
    clock = FakeClock()
    bus = AmbientBus(RateLimiter(per_source=8.0, global_interval=0.0001, burst=100, clock=clock))
    assert bus.offer("sensor.doorbell", "doorbell", "ring") is not None
    assert bus.offer("sensor.doorbell", "doorbell", "ring again") is None
    assert len(bus.drain()) == 1


def test_diff_reports_only_what_changed() -> None:
    devices = Scenario.load("apartment").devices
    after = [d.model_copy(deep=True) for d in devices]
    next(d for d in after if d.id == "light.desk").state["on"] = True

    changes = diff_devices(devices, after)
    assert [c[0] for c in changes] == ["light.desk"]
    assert changes[0][1] == "stateChange"


def test_diff_of_identical_snapshots_is_empty() -> None:
    devices = Scenario.load("apartment").devices
    assert diff_devices(devices, [d.model_copy(deep=True) for d in devices]) == []

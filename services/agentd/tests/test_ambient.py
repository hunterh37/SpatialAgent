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


# --- the utterance quiet window (spec/07-memory.md Curiosity) ---------------------------


def test_nothing_unprompted_within_30s_of_the_user_speaking() -> None:
    clock = [1000.0]
    bus = AmbientBus(clock=lambda: clock[0])
    bus.note_utterance()

    clock[0] += 5
    assert bus.offer("light.kitchen", "stateChange", "Kitchen light: on.") is None

    clock[0] += 30
    assert bus.offer("light.kitchen", "stateChange", "Kitchen light: on.") is not None


def test_a_doorbell_does_not_wait_for_the_quiet_window() -> None:
    clock = [1000.0]
    bus = AmbientBus(clock=lambda: clock[0])
    bus.note_utterance()
    clock[0] += 1
    assert bus.offer("sensor.doorbell", "doorbell", "Someone is at the door.") is not None


def test_the_quiet_window_is_not_armed_before_anyone_speaks() -> None:
    bus = AmbientBus()
    assert not bus.in_utterance_quiet()
    assert bus.offer("light.kitchen", "stateChange", "Kitchen light: on.") is not None


# --- ambient sources beyond device diffs (phase E) --------------------------------------


def test_a_timer_fires_as_an_ambient_event() -> None:
    from agentd.ambient import TimerBus

    clock = [0.0]
    timers = TimerBus(clock=lambda: clock[0])
    source = timers.set("pasta", 300)
    assert timers.pending == [source]
    assert timers.due() == []

    clock[0] = 301
    fired = timers.due()
    assert fired == [(source, "finished", "Your pasta timer is up.")]
    # And it fires once.
    assert timers.due() == []
    assert timers.pending == []


def test_a_cancelled_timer_never_fires() -> None:
    from agentd.ambient import TimerBus

    clock = [0.0]
    timers = TimerBus(clock=lambda: clock[0])
    source = timers.set("pasta", 10)
    assert timers.cancel(source)
    clock[0] = 100
    assert timers.due() == []
    assert not timers.cancel(source)


def test_an_appliance_finishing_is_its_own_event() -> None:
    from agentd.ambient import appliance_completions, diff_devices
    from agentd.protocol import Device

    before = [Device(id="w1", name="washing machine", kind="other", state={"running": True})]
    after = [Device(id="w1", name="washing machine", kind="other", state={"running": False})]

    done = appliance_completions(before, after)
    assert done == [("w1", "finished", "The washing machine has finished.")]
    # And it is not also reported as a bare state change.
    assert diff_devices(before, after) == []


def test_an_appliance_starting_is_not_a_completion() -> None:
    from agentd.ambient import appliance_completions
    from agentd.protocol import Device

    before = [Device(id="w1", name="washing machine", kind="other", state={"running": False})]
    after = [Device(id="w1", name="washing machine", kind="other", state={"running": True})]
    assert appliance_completions(before, after) == []


def test_a_finished_event_does_not_wait_for_the_quiet_window() -> None:
    clock = [1000.0]
    bus = AmbientBus(clock=lambda: clock[0])
    bus.note_utterance()
    clock[0] += 1
    assert bus.offer("w1", "finished", "The washing machine has finished.") is not None

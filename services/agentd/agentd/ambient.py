"""Ambient events: the home speaking first.

PRD 4 names Ambient as one of the four loops, and it is the one that distinguishes the
character from a command line with legs. The server owns two things the client cannot:
classification of urgency, and the rate limiter. A light group that flickers must not
produce twenty events; the client renders whatever it is sent.
"""

from __future__ import annotations

import asyncio
import time
from collections.abc import Callable

from .protocol import AmbientEvent, AmbientInterrupt, AmbientKind, Device

# Per-source floor, and a global ceiling so a storm on many devices still cannot flood.
PER_SOURCE_INTERVAL = 8.0
GLOBAL_INTERVAL = 1.5
BURST = 3
# Nothing unprompted within 30s of the user speaking. The curiosity budget in
# spec/07-memory.md states this for questions, and it is true of every unprompted line for the
# same reason: talking over someone who just talked to you reads as not listening. The client
# holds the rest of the curiosity budget, because only the client knows what it would ask
# about; this is the half that belongs to whatever is being emitted from here.
UTTERANCE_QUIET = 30.0

_INTERRUPT_BY_KIND: dict[AmbientKind, AmbientInterrupt] = {
    "doorbell": "now",
    "finished": "passing",
    "sensor": "passing",
    "stateChange": "silent",
}


class RateLimiter:
    """Per-source cooldown plus a small global token bucket."""

    def __init__(
        self,
        per_source: float = PER_SOURCE_INTERVAL,
        global_interval: float = GLOBAL_INTERVAL,
        burst: int = BURST,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._per_source = per_source
        self._global_interval = global_interval
        self._burst = burst
        self._clock = clock
        self._last: dict[str, float] = {}
        self._tokens = float(burst)
        self._refilled = clock()

    def allow(self, source: str) -> bool:
        now = self._clock()

        last = self._last.get(source)
        if last is not None and now - last < self._per_source:
            return False

        self._tokens = min(
            float(self._burst),
            self._tokens + (now - self._refilled) / self._global_interval,
        )
        self._refilled = now
        if self._tokens < 1.0:
            return False

        self._tokens -= 1.0
        self._last[source] = now
        return True


class AmbientBus:
    """Accepts raw home changes, emits at most a sane trickle of classified events."""

    def __init__(
        self,
        limiter: RateLimiter | None = None,
        clock: Callable[[], float] = time.monotonic,
        utterance_quiet: float = UTTERANCE_QUIET,
    ) -> None:
        self._limiter = limiter or RateLimiter()
        self._queue: asyncio.Queue[AmbientEvent] = asyncio.Queue()
        self._clock = clock
        self._utterance_quiet = utterance_quiet
        self._last_utterance: float | None = None

    def note_utterance(self) -> None:
        """The user just said something. Called from the session on every final utterance."""
        self._last_utterance = self._clock()

    def in_utterance_quiet(self) -> bool:
        if self._last_utterance is None:
            return False
        return self._clock() - self._last_utterance < self._utterance_quiet

    def classify(
        self, source: str, kind: AmbientKind, text: str, interrupt: AmbientInterrupt | None = None
    ) -> AmbientEvent:
        return AmbientEvent(
            source=source,
            kind=kind,
            interrupt=interrupt or _INTERRUPT_BY_KIND.get(kind, "passing"),
            text=text,
        )

    def offer(
        self, source: str, kind: AmbientKind, text: str, interrupt: AmbientInterrupt | None = None
    ) -> AmbientEvent | None:
        """Rate-limited. Returns the event that was queued, or None if it was dropped."""
        # A `now` event is a doorbell, and a doorbell that waits 30 seconds is not a
        # doorbell. Everything else yields to the conversation.
        if (
            interrupt != "now"
            and _INTERRUPT_BY_KIND.get(kind) != "now"
            and kind != "finished"
            and self.in_utterance_quiet()
        ):
            return None
        if not self._limiter.allow(source):
            return None
        event = self.classify(source, kind, text, interrupt)
        self._queue.put_nowait(event)
        return event

    async def next(self) -> AmbientEvent:
        return await self._queue.get()

    def drain(self) -> list[AmbientEvent]:
        out: list[AmbientEvent] = []
        while not self._queue.empty():
            out.append(self._queue.get_nowait())
        return out


class TimerBus:
    """Timers the user set, as ambient events.

    Phase E: the home speaks first for more than device diffs. A timer is the smallest
    example that is unambiguously worth interrupting for — the user asked for this
    interruption, at this time, on purpose — which is why it is `now` rather than `passing`
    and why it is exempt from the utterance-quiet window in the same way a doorbell is.
    """

    def __init__(self, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self._timers: dict[str, tuple[float, str]] = {}

    def set(self, name: str, seconds: float) -> str:
        """Returns the source id the resulting ambient event will carry."""
        source = f"timer.{name.strip().lower().replace(' ', '_') or 'timer'}"
        self._timers[source] = (self._clock() + max(0.0, seconds), name)
        return source

    def cancel(self, source: str) -> bool:
        return self._timers.pop(source, None) is not None

    @property
    def pending(self) -> list[str]:
        return sorted(self._timers)

    def due(self) -> list[tuple[str, AmbientKind, str]]:
        """Fired timers, as `(source, kind, text)` — the same shape `diff_devices` returns,
        so the bus takes both without knowing which is which."""
        now = self._clock()
        fired = [(source, name) for source, (at, name) in self._timers.items() if at <= now]
        for source, _ in fired:
            self._timers.pop(source, None)
        return [(source, "finished", f"Your {name} timer is up.") for source, name in fired]


#: Devices whose "running -> not running" transition is an appliance finishing rather than a
#: state change nobody asked about. A washing machine that finishes is worth a sentence; a
#: light that turns off is not.
APPLIANCE_DONE_KEYS = ("running", "active", "washing", "drying", "cooking")


def appliance_completions(
    before: list[Device], after: list[Device]
) -> list[tuple[str, AmbientKind, str]]:
    """Appliances that just finished.

    Split out from `diff_devices` rather than folded into it because the interrupt level is
    different: a completion is `passing` and deserves a sentence, while the same device's
    other state changes are `silent`.
    """
    prior = {d.id: d for d in before}
    out: list[tuple[str, AmbientKind, str]] = []
    for device in after:
        old = prior.get(device.id)
        if old is None:
            continue
        for key in APPLIANCE_DONE_KEYS:
            was = bool(old.state.get(key))
            now = bool(device.state.get(key))
            if was and not now:
                out.append((device.id, "finished", f"The {device.name} has finished."))
                break
    return out


def diff_devices(before: list[Device], after: list[Device]) -> list[tuple[str, AmbientKind, str]]:
    """Turn two device snapshots into candidate ambient events.

    This is what makes `deviceStates` useful for more than the prompt: a doorbell that
    starts ringing becomes an event the character can react to unprompted.
    """
    prior = {d.id: d for d in before}
    events: list[tuple[str, AmbientKind, str]] = []

    for device in after:
        old = prior.get(device.id)
        if old is None or old.state == device.state:
            continue

        if device.kind == "sensor" and device.state.get("ringing") and not old.state.get("ringing"):
            events.append((device.id, "doorbell", f"{device.name} is ringing."))
            continue

        # An appliance finishing is its own event with its own interrupt level; it must not
        # also be reported as a state change.
        if any(
            bool(old.state.get(key)) and not bool(device.state.get(key))
            for key in APPLIANCE_DONE_KEYS
        ):
            continue

        changed = [k for k, v in device.state.items() if old.state.get(k) != v]
        detail = ", ".join(f"{k}={device.state[k]}" for k in changed)
        events.append((device.id, "stateChange", f"{device.name}: {detail}."))

    return events

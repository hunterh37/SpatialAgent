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

    def __init__(self, limiter: RateLimiter | None = None) -> None:
        self._limiter = limiter or RateLimiter()
        self._queue: asyncio.Queue[AmbientEvent] = asyncio.Queue()

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

        changed = [k for k, v in device.state.items() if old.state.get(k) != v]
        detail = ", ".join(f"{k}={device.state[k]}" for k in changed)
        events.append((device.id, "stateChange", f"{device.name}: {detail}."))

    return events

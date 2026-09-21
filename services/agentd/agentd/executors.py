"""Who fulfils a tool call.

Two implementations of one boundary:

- `ClientExecutor` forwards the call to the headset and waits for its `toolResult`. This is
  the phase-1 path and the one the mock headset drives.
- `ServerExecutor` runs the call on this machine (the Mac companion owns HomeKit, which is
  not in the visionOS SDK at all — docs/middle-layer-todo.md 1). The headset then only
  approves, and can never claim to have done something it did not do.

The safety property is the same in both and is enforced here, once: an `unsafe` tool is
never executed without an explicit approval carrying its callId. The server does not decide,
it executes (spec/04-home.md).
"""

from __future__ import annotations

import asyncio
import os
from dataclasses import dataclass
from typing import Any, Protocol

from .protocol import Executor, Safety

DEFAULT_TIMEOUT = float(os.environ.get("AGENTD_TOOL_TIMEOUT", "30"))
# A person has to read the prompt and decide. The client's own gate closes at 30s
# (ConfirmationGate.timeout); the server waits longer so a tap is never answered into a
# call the server has already abandoned.
DEFAULT_CONFIRM_TIMEOUT = float(os.environ.get("AGENTD_CONFIRM_TIMEOUT", "120"))


@dataclass
class Outcome:
    ok: bool
    payload: dict[str, Any]
    error: str | None = None


class HomeExecutor(Protocol):
    """A thing that can actually change the home. Implemented by mock_home and, on the Mac
    companion, by a HomeKit bridge."""

    def execute(self, name: str, args: dict[str, Any]) -> tuple[bool, dict[str, Any], str | None]:
        ...

    def snapshot(self) -> list[Any]:
        """Current devices, so the server can tell the client what it is holding."""
        ...


class PendingCalls:
    """Futures the socket reader resolves: one per outstanding callId."""

    def __init__(self) -> None:
        self._results: dict[str, asyncio.Future[Outcome]] = {}
        self._approvals: dict[str, asyncio.Future[bool]] = {}

    def expect_result(self, call_id: str) -> asyncio.Future[Outcome]:
        fut: asyncio.Future[Outcome] = asyncio.get_running_loop().create_future()
        self._results[call_id] = fut
        return fut

    def expect_approval(self, call_id: str) -> asyncio.Future[bool]:
        fut: asyncio.Future[bool] = asyncio.get_running_loop().create_future()
        self._approvals[call_id] = fut
        return fut

    def deliver_result(self, call_id: str, outcome: Outcome) -> bool:
        fut = self._results.pop(call_id, None)
        if fut is None or fut.done():
            return False
        fut.set_result(outcome)
        return True

    def deliver_approval(self, call_id: str, approved: bool) -> bool:
        fut = self._approvals.pop(call_id, None)
        if fut is None or fut.done():
            return False
        fut.set_result(approved)
        return True

    def cancel_all(self) -> None:
        for fut in (*self._results.values(), *self._approvals.values()):
            if not fut.done():
                fut.cancel()
        self._results.clear()
        self._approvals.clear()


class ToolExecutor(Protocol):
    location: Executor

    async def run(
        self, call_id: str, name: str, args: dict[str, Any], safety: Safety, pending: PendingCalls
    ) -> Outcome: ...


class ClientExecutor:
    """The headset executes and reports back. Confirmation is the client's own business."""

    location: Executor = "client"

    def __init__(self, timeout: float = DEFAULT_TIMEOUT) -> None:
        self._timeout = timeout

    async def run(
        self, call_id: str, name: str, args: dict[str, Any], safety: Safety, pending: PendingCalls
    ) -> Outcome:
        try:
            return await asyncio.wait_for(pending.expect_result(call_id), self._timeout)
        except TimeoutError:
            return Outcome(False, {}, "client did not answer in time")
        except asyncio.CancelledError:
            return Outcome(False, {}, "cancelled")


class ServerExecutor:
    """This machine executes. An unsafe tool waits for an approval that names its callId."""

    location: Executor = "server"

    def __init__(
        self,
        home: HomeExecutor,
        timeout: float = DEFAULT_TIMEOUT,
        confirm_timeout: float | None = None,
    ) -> None:
        self.home = home
        self._home = home
        self._timeout = timeout
        self._confirm_timeout = (
            confirm_timeout if confirm_timeout is not None else max(timeout, DEFAULT_CONFIRM_TIMEOUT)
        )

    def devices(self) -> list[Any]:
        snapshot = getattr(self._home, "snapshot", None)
        return list(snapshot()) if callable(snapshot) else []

    async def run(
        self, call_id: str, name: str, args: dict[str, Any], safety: Safety, pending: PendingCalls
    ) -> Outcome:
        if safety == "unsafe":
            try:
                approved = await asyncio.wait_for(
                    pending.expect_approval(call_id), self._confirm_timeout
                )
            except TimeoutError:
                return Outcome(False, {}, "confirmation timed out")
            except asyncio.CancelledError:
                return Outcome(False, {}, "cancelled")
            if not approved:
                return Outcome(False, {}, "user declined")

        ok, payload, error = await asyncio.to_thread(self._home.execute, name, args)
        return Outcome(ok, payload, error)

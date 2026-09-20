"""The Mac companion, as a `HomeExecutor`.

HomeKit is not in the visionOS SDK and `HMHomeManager` needs a real user session, so the app
that touches the home is a small Mac app rather than this process (docs/architecture.md 5,
docs/middle-layer-todo.md 1). This class is the other end of its loopback bridge.

Nothing in the agent loop changes when this lands: `ServerExecutor` already takes a
`HomeExecutor`, and this is one. That is exactly what the boundary bought.
"""

from __future__ import annotations

import json
import logging
import urllib.error
import urllib.request
from collections.abc import Callable
from typing import Any

from ..protocol import Device

log = logging.getLogger("agentd.home.companion")

DEFAULT_BASE_URL = "http://127.0.0.1:8790"
DEFAULT_TIMEOUT = 5.0


class CompanionUnavailable(RuntimeError):
    """The companion app is not running. Surfaced rather than swallowed: a home that silently
    does nothing is the failure mode the confirmation gate exists to prevent."""


class CompanionHome:
    """Executes home tools by asking the Mac companion.

    The transport is injectable so the whole thing is testable without a socket: the tests
    that matter here are about what happens when the companion is missing, slow, or answers
    with a failure, and none of those need a real server.
    """

    def __init__(
        self,
        base_url: str = DEFAULT_BASE_URL,
        timeout: float = DEFAULT_TIMEOUT,
        transport: Callable[[str, str, dict[str, Any] | None], dict[str, Any]] | None = None,
    ) -> None:
        self._base = base_url.rstrip("/")
        self._timeout = timeout
        self._transport = transport or self._http
        self._devices: list[Device] = []

    # --- HomeExecutor ------------------------------------------------------

    def execute(self, name: str, args: dict[str, Any]) -> tuple[bool, dict[str, Any], str | None]:
        try:
            result = self._transport("POST", "/execute", {"tool": name, "args": args})
        except CompanionUnavailable as error:
            # Named plainly so the character can say it: "I can't reach the home from here."
            return False, {}, str(error)

        ok = bool(result.get("ok"))
        payload = result.get("payload") or {}
        if not isinstance(payload, dict):
            payload = {}
        # A device id in the args plus the state it came back with is what lets the session
        # keep its snapshot honest without a second round trip.
        device_id = args.get("device_id")
        if ok and isinstance(device_id, str) and payload:
            payload = {"id": device_id, "state": payload}
        return ok, payload, None if ok else str(result.get("error") or "the home refused")

    def snapshot(self) -> list[Device]:
        """Current devices. Cached, because the prompt asks for this on every turn and the
        companion is a separate process — but never cached across a successful refresh."""
        try:
            raw = self._transport("GET", "/devices", None)
        except CompanionUnavailable as error:
            log.warning("companion unavailable: %s", error)
            return list(self._devices)
        devices = raw if isinstance(raw, list) else raw.get("devices", [])
        parsed: list[Device] = []
        for item in devices:
            try:
                parsed.append(Device.model_validate(item))
            except Exception:  # noqa: BLE001 - one bad device must not lose the rest
                log.warning("companion sent a device this build cannot read: %r", item)
        self._devices = parsed
        return list(parsed)

    # --- health ------------------------------------------------------------

    def is_available(self) -> bool:
        try:
            self._transport("GET", "/health", None)
        except CompanionUnavailable:
            return False
        return True

    # --- transport ---------------------------------------------------------

    def _http(self, method: str, path: str, body: dict[str, Any] | None) -> Any:
        url = f"{self._base}{path}"
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(
            url,
            data=data,
            method=method,
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=self._timeout) as response:
                return json.loads(response.read() or b"{}")
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise CompanionUnavailable(
                f"the Mac companion is not answering on {self._base}"
            ) from error
        except json.JSONDecodeError as error:
            raise CompanionUnavailable("the Mac companion sent something unreadable") from error

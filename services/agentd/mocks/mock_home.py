"""In-memory HomeBridge.

Implements the same tool surface as the real HomeKit bridge, with state tests can assert on.
"""

from __future__ import annotations

from typing import Any

from agentd.protocol import Device


class MockHome:
    def __init__(self, devices: list[Device]) -> None:
        self.devices = {d.id: d for d in devices}
        self.calls: list[tuple[str, dict[str, Any]]] = []

    def snapshot(self) -> list[Device]:
        return list(self.devices.values())

    def execute(self, name: str, args: dict[str, Any]) -> tuple[bool, dict[str, Any], str | None]:
        self.calls.append((name, args))
        handler = getattr(self, f"_{name}", None)
        if handler is None:
            return False, {}, f"unknown tool: {name}"
        return handler(args)

    # --- tools ---------------------------------------------------------

    def _list_devices(self, args: dict[str, Any]):
        return True, {"devices": [d.model_dump() for d in self.devices.values()]}, None

    def _get_device_state(self, args: dict[str, Any]):
        device = self.devices.get(args.get("device_id", ""))
        if device is None:
            return False, {}, "no such device"
        return True, {"id": device.id, "state": device.state}, None

    def _set_light(self, args: dict[str, Any]):
        device = self.devices.get(args.get("device_id", ""))
        if device is None or device.kind != "light":
            return False, {}, "no such light"
        device.state["on"] = bool(args.get("on"))
        if "brightness" in args:
            device.state["brightness"] = int(args["brightness"])
        return True, {"id": device.id, "state": device.state}, None

    def _set_lock(self, args: dict[str, Any]):
        device = self.devices.get(args.get("device_id", ""))
        if device is None or device.kind != "lock":
            return False, {}, "no such lock"
        device.state["locked"] = bool(args.get("locked"))
        return True, {"id": device.id, "state": device.state}, None

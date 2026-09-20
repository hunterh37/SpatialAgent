"""Bonjour advertisement.

Do not hardcode an IP; it changes and an evening goes with it (docs/architecture.md 2b).
The Mac publishes `_spatialagent._tcp`, the headset browses for it with NWBrowser. The
manual "enter IP" field stays as the fallback for conference Wi-Fi that blocks mDNS.

The visionOS side needs `NSBonjourServices` to list this exact type and
`NSLocalNetworkUsageDescription` to be present, or browsing silently returns nothing.
"""

from __future__ import annotations

import logging
import socket
from typing import Any

SERVICE_TYPE = "_spatialagent._tcp.local."

log = logging.getLogger("agentd.discovery")


def local_ip() -> str:
    """Best-effort LAN address. No packet is sent; connect() on UDP just picks a route."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("192.0.2.1", 9))  # TEST-NET-1, guaranteed unroutable
        return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        sock.close()


def service_properties(model: str, protocol_version: int, path: str = "/agent") -> dict[str, str]:
    return {"model": model, "protocolVersion": str(protocol_version), "path": path}


class Advertiser:
    """Registers the service for the process lifetime. A no-op if zeroconf is missing."""

    def __init__(self, port: int, model: str, protocol_version: int, name: str | None = None):
        self.port = port
        self.model = model
        self.protocol_version = protocol_version
        self.instance = name or f"agentd on {socket.gethostname().split('.')[0]}"
        self._zc: Any = None
        self._info: Any = None

    def start(self) -> bool:
        try:
            from zeroconf import ServiceInfo, Zeroconf
        except ImportError:
            log.warning("zeroconf not installed; discovery disabled, connect by IP")
            return False

        address = local_ip()
        self._info = ServiceInfo(
            SERVICE_TYPE,
            f"{self.instance}.{SERVICE_TYPE}",
            addresses=[socket.inet_aton(address)],
            port=self.port,
            properties=service_properties(self.model, self.protocol_version),
            server=f"{socket.gethostname().split('.')[0]}.local.",
        )
        try:
            self._zc = Zeroconf()
            self._zc.register_service(self._info)
        except OSError as exc:
            log.warning("could not advertise: %s", exc)
            self.stop()
            return False

        log.info("advertising %s at ws://%s:%d/agent", SERVICE_TYPE, address, self.port)
        return True

    def stop(self) -> None:
        if self._zc is not None:
            try:
                if self._info is not None:
                    self._zc.unregister_service(self._info)
            finally:
                self._zc.close()
        self._zc = None
        self._info = None

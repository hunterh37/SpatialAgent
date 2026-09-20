"""Scenario fixtures: the world state a headset would have sent."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import yaml

from agentd.protocol import Device, SceneSnapshot

SCENARIO_DIR = Path(__file__).parent / "scenarios"


@dataclass
class Scenario:
    name: str
    scene: SceneSnapshot
    devices: list[Device]

    @classmethod
    def load(cls, ref: str) -> "Scenario":
        path = Path(ref)
        if not path.exists():
            path = SCENARIO_DIR / (ref if ref.endswith(".yaml") else f"{ref}.yaml")
        raw = yaml.safe_load(path.read_text())
        # Validated against the same models as live traffic: a fixture cannot encode a
        # message shape the client would never send.
        return cls(
            name=raw.get("name", path.stem),
            scene=SceneSnapshot.model_validate(raw.get("scene") or {}),
            devices=[Device.model_validate(d) for d in raw.get("devices") or []],
        )

    @staticmethod
    def available() -> list[str]:
        return sorted(p.stem for p in SCENARIO_DIR.glob("*.yaml"))

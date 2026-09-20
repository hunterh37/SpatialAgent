"""Tool surface.

Safety is declared where a tool is defined and is never inferred by the model
(spec/04-home.md). The client enforces it independently; this is the server half.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from ..protocol import Safety

# Handled by the session itself, not by any executor: it asks the user a question.
ASK_FOR_PLACE = "ask_for_place"


@dataclass(frozen=True)
class Tool:
    name: str
    description: str
    safety: Safety
    parameters: dict[str, Any] = field(default_factory=dict)

    def as_schema(self) -> dict[str, Any]:
        """OpenAI/Ollama-compatible function definition."""
        return {
            "type": "function",
            "function": {
                "name": self.name,
                "description": self.description,
                "parameters": {
                    "type": "object",
                    "properties": self.parameters,
                    "required": [k for k, v in self.parameters.items() if v.get("required")],
                },
            },
        }


class ToolRegistry:
    def __init__(self, tools: list[Tool] | None = None) -> None:
        self._tools: dict[str, Tool] = {t.name: t for t in (tools or [])}

    def add(self, tool: Tool) -> None:
        self._tools[tool.name] = tool

    def get(self, name: str) -> Tool | None:
        return self._tools.get(name)

    def safety_of(self, name: str) -> Safety:
        tool = self._tools.get(name)
        # Unknown tools are treated as unsafe. Fail closed.
        return tool.safety if tool else "unsafe"

    def names(self) -> list[str]:
        return list(self._tools)

    def schemas(self) -> list[dict[str, Any]]:
        return [t.as_schema() for t in self._tools.values()]


def default_registry() -> ToolRegistry:
    """v0.1 tool surface (PRD 5)."""
    return ToolRegistry(
        [
            Tool(
                name="list_devices",
                description="List every smart-home device, with room and kind.",
                safety="safe",
            ),
            Tool(
                name="get_device_state",
                description="Read the current state of one device.",
                safety="safe",
                parameters={"device_id": {"type": "string", "required": True}},
            ),
            Tool(
                name="set_light",
                description="Turn a light on or off, optionally set brightness 0-100.",
                safety="safe",
                parameters={
                    "device_id": {"type": "string", "required": True},
                    "on": {"type": "boolean", "required": True},
                    "brightness": {"type": "integer"},
                },
            ),
            Tool(
                name=ASK_FOR_PLACE,
                description=(
                    "Ask the user to name a place in the room that you need but do not have, "
                    "e.g. 'kitchen'. Use this instead of guessing a location."
                ),
                safety="safe",
                parameters={"name": {"type": "string", "required": True}},
            ),
            Tool(
                name="set_lock",
                description="Lock or unlock a door. Requires user confirmation on device.",
                safety="unsafe",
                parameters={
                    "device_id": {"type": "string", "required": True},
                    "locked": {"type": "boolean", "required": True},
                },
            ),
        ]
    )

"""Tool surface.

Safety is declared where a tool is defined and is never inferred by the model
(spec/04-home.md). The client enforces it independently; this is the server half.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from ..protocol import Safety

# Handled by the session itself, not by any executor: these move or question the character
# rather than touching the home, so no HomeExecutor ever sees them.
ASK_FOR_PLACE = "ask_for_place"
WALK_TO = "walk_to"
LOOK_AT = "look_at"
CHARACTER_TOOLS = frozenset({ASK_FOR_PLACE, WALK_TO, LOOK_AT})

# Handled by the session too: a timer is an ambient source, not a home device.
SET_TIMER = "set_timer"


@dataclass(frozen=True)
class Tool:
    name: str
    description: str
    safety: Safety
    parameters: dict[str, Any] = field(default_factory=dict)

    def as_schema(self) -> dict[str, Any]:
        """OpenAI/Ollama-compatible function definition.

        `required` is declared per parameter here for readability, but JSON Schema puts it
        on the object as a list of names. Leaving it inside a property is a 400 from Ollama.
        """
        return {
            "type": "function",
            "function": {
                "name": self.name,
                "description": self.description,
                "parameters": {
                    "type": "object",
                    "properties": {
                        key: {k: v for k, v in spec.items() if k != "required"}
                        for key, spec in self.parameters.items()
                    },
                    "required": [k for k, v in self.parameters.items() if v.get("required")],
                },
            },
        }


_TRUE = {"true", "yes", "on", "1"}
_FALSE = {"false", "no", "off", "0"}


def coerce_value(value: Any, declared: str) -> Any:
    """A small model emits `"false"`, not `false`. `bool("false")` is True, which silently
    does the opposite of what the user asked, so arguments are coerced to the type the tool
    declared before anything executes."""
    if declared == "boolean":
        if isinstance(value, bool):
            return value
        if isinstance(value, str):
            lowered = value.strip().lower()
            if lowered in _TRUE:
                return True
            if lowered in _FALSE:
                return False
        if isinstance(value, (int, float)):
            return bool(value)
        return value
    if declared == "integer":
        try:
            return int(float(value))
        except (TypeError, ValueError):
            return value
    if declared == "number":
        try:
            return float(value)
        except (TypeError, ValueError):
            return value
    if declared == "string" and not isinstance(value, str):
        return str(value)
    return value


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

    def coerce(self, name: str, args: dict[str, Any]) -> dict[str, Any]:
        """Arguments as the tool declared them. Unknown tools and extra keys pass through."""
        tool = self._tools.get(name)
        if tool is None:
            return args
        return {
            key: coerce_value(value, tool.parameters.get(key, {}).get("type", ""))
            for key, value in args.items()
        }

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
                name=WALK_TO,
                description=(
                    "Walk your body to a named place in the room before acting there. "
                    "Only the places listed in the system prompt exist."
                ),
                safety="safe",
                parameters={"place": {"type": "string", "required": True}},
            ),
            Tool(
                name=LOOK_AT,
                description="Turn to look at the user, or at a named place.",
                safety="safe",
                parameters={"target": {"type": "string", "required": True}},
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
                name=SET_TIMER,
                description=(
                    "Set a timer the user asked for, in seconds. You will be told when it "
                    "is up; do not try to count time yourself."
                ),
                safety="safe",
                parameters={
                    "name": {"type": "string", "required": True},
                    "seconds": {"type": "number", "required": True},
                },
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

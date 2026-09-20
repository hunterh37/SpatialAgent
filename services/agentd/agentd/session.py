"""Session: conversation state + the agent loop.

State lives here, on the Mac, not on the headset (docs/architecture.md 8). A headset that
sleeps and reconnects resumes rather than restarts.
"""

from __future__ import annotations

import uuid
from collections.abc import AsyncIterator
from typing import Any

from .adapters.base import ModelAdapter
from .directives import directives_for
from .protocol import (
    CharacterDirective,
    Device,
    Directive,
    SceneSnapshot,
    ServerEvent,
    Token,
    ToolCall,
    ToolResult,
    UtteranceEnd,
)
from .prompt import build_system_prompt
from .tools import ToolRegistry

MAX_TURNS = 40


class Session:
    def __init__(self, adapter: ModelAdapter, tools: ToolRegistry) -> None:
        self.id = uuid.uuid4().hex[:12]
        self.adapter = adapter
        self.tools = tools
        self.scene = SceneSnapshot()
        self.devices: list[Device] = []
        self.history: list[dict[str, Any]] = []
        self._pending: dict[str, str] = {}

    # --- state fed by the client ------------------------------------------

    def update_scene(self, scene: SceneSnapshot) -> None:
        self.scene = scene

    def update_devices(self, devices: list[Device]) -> None:
        self.devices = devices

    def resolve_tool_result(self, result: ToolResult) -> None:
        name = self._pending.pop(result.callId, "unknown_tool")
        content = result.payload if result.ok else {"error": result.error or "failed"}
        self.history.append(
            {"role": "tool", "name": name, "content": _compact(content)}
        )

    # --- the loop ----------------------------------------------------------

    async def handle_utterance(self, utterance_id: str, text: str) -> AsyncIterator[ServerEvent]:
        """Stream events for one user utterance.

        Order matters: an acknowledging directive is emitted before the model is asked
        anything, so the character starts reacting inside the 400ms budget (PRD 6).
        """
        yield Directive(directive=CharacterDirective(kind="lookAt", target="user"))
        yield Directive(directive=CharacterDirective(kind="emote", emotion="thinking"))

        self.history.append({"role": "user", "content": text})
        self._trim()

        messages = [
            {"role": "system", "content": build_system_prompt(self.scene, self.devices)},
            *self.history,
        ]

        buffer: list[str] = []
        emitted_places: set[str] = set()

        async for chunk in self.adapter.stream(messages, self.tools.schemas()):
            if chunk.text:
                buffer.append(chunk.text)
                yield Token(utteranceId=utterance_id, text=chunk.text)

                # Walk as soon as a known place is mentioned, rather than after the
                # sentence completes. Motion overlapping speech is what reads as alive.
                for directive in directives_for("".join(buffer), self.scene):
                    if directive.place and directive.place not in emitted_places:
                        emitted_places.add(directive.place)
                        yield Directive(directive=directive)

            for call in chunk.tool_calls:
                fn = call.get("function", {})
                name = fn.get("name", "")
                call_id = uuid.uuid4().hex[:12]
                self._pending[call_id] = name
                yield ToolCall(
                    callId=call_id,
                    name=name,
                    args=_as_dict(fn.get("arguments")),
                    safety=self.tools.safety_of(name),
                )

        reply = "".join(buffer).strip()
        if reply:
            self.history.append({"role": "assistant", "content": reply})

        yield UtteranceEnd(utteranceId=utterance_id)
        yield Directive(directive=CharacterDirective(kind="idle"))

    # --- internals ---------------------------------------------------------

    def _trim(self) -> None:
        if len(self.history) > MAX_TURNS:
            self.history = self.history[-MAX_TURNS:]


def _as_dict(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        return value
    if isinstance(value, str):
        import json

        try:
            parsed = json.loads(value)
            return parsed if isinstance(parsed, dict) else {}
        except json.JSONDecodeError:
            return {}
    return {}


def _compact(value: Any) -> str:
    import json

    return json.dumps(value, separators=(",", ":"))

"""Session: conversation state + the agent loop.

State lives here, on the Mac, not on the headset (docs/architecture.md 8). A headset that
sleeps and reconnects resumes rather than restarts, which is why `SessionStore` outlives any
one socket.
"""

from __future__ import annotations

import json
import time
import uuid
from collections.abc import AsyncIterator
from typing import Any

from .adapters.base import ModelAdapter
from .ambient import AmbientBus, diff_devices
from .directives import directives_for
from .executors import ClientExecutor, Outcome, PendingCalls, ToolExecutor
from .prompt import build_system_prompt
from .protocol import (
    AmbientEvent,
    Capabilities,
    CharacterDirective,
    Device,
    Directive,
    RequestPlace,
    SceneSnapshot,
    ServerEvent,
    Token,
    ToolCall,
    ToolResult,
    UtteranceEnd,
)
from .thinking import ThinkingFilter
from .tools import ASK_FOR_PLACE, ToolRegistry

MAX_TURNS = 40
# A tool result has to go back through the model, or the character reports "done" without
# knowing what happened. Bounded so a looping model cannot spin forever.
MAX_TOOL_ROUNDS = 4
SESSION_TTL = 30 * 60.0


class Session:
    def __init__(
        self,
        adapter: ModelAdapter,
        tools: ToolRegistry,
        executor: ToolExecutor | None = None,
        session_id: str | None = None,
    ) -> None:
        self.id = session_id or uuid.uuid4().hex[:12]
        self.adapter = adapter
        self.tools = tools
        self.executor: ToolExecutor = executor or ClientExecutor()
        self.scene = SceneSnapshot()
        self.devices: list[Device] = []
        self.history: list[dict[str, Any]] = []
        self.pending = PendingCalls()
        self.ambient = AmbientBus()
        self.touched_at = time.monotonic()
        # Places the agent has already asked about, so it stops asking (todo 3).
        self.requested_places: set[str] = set()
        self._pending_names: dict[str, str] = {}

    def capabilities(self) -> Capabilities:
        return Capabilities(
            ambientEvents=True,
            toolExecution=self.executor.location,
            requestPlace=True,
            speechInput=False,
        )

    def touch(self) -> None:
        self.touched_at = time.monotonic()

    # --- state fed by the client ------------------------------------------

    def update_scene(self, scene: SceneSnapshot) -> None:
        self.scene = scene
        # A place that has since been named is no longer a place to ask about.
        self.requested_places -= {n.lower() for n in scene.place_names()}
        self.touch()

    def update_devices(self, devices: list[Device]) -> list[AmbientEvent]:
        """Returns the ambient events this snapshot earned, after rate limiting."""
        events: list[AmbientEvent] = []
        if self.devices:
            for source, kind, text in diff_devices(self.devices, devices):
                event = self.ambient.offer(source, kind, text)
                if event is not None:
                    events.append(event)
        self.devices = devices
        self.touch()
        return events

    def note_ambient(self, event: AmbientEvent) -> None:
        """Ambient events enter the transcript so the next reply knows they happened."""
        self.history.append({"role": "system", "content": f"[home] {event.text}"})
        self._trim()

    def resolve_tool_result(self, result: ToolResult) -> bool:
        """Client-executed path: the headset did the work and reported back."""
        outcome = Outcome(result.ok, result.payload, result.error)
        return self.pending.deliver_result(result.callId, outcome)

    def resolve_confirmation(self, call_id: str, approved: bool) -> bool:
        """Server-executed path: the headset only approves."""
        return self.pending.deliver_approval(call_id, approved)

    # --- the loop ----------------------------------------------------------

    async def handle_utterance(
        self, utterance_id: str, text: str, is_final: bool = True
    ) -> AsyncIterator[ServerEvent]:
        """Stream events for one user utterance.

        Order matters: an acknowledging directive is emitted before the model is asked
        anything, so the character starts reacting inside the 400ms budget (PRD 6).
        """
        self.touch()
        yield Directive(directive=CharacterDirective(kind="lookAt", target="user"))
        yield Directive(directive=CharacterDirective(kind="emote", emotion="thinking"))

        if not is_final:
            # Partial transcript: the character looks up, the model stays out of it.
            return

        self.history.append({"role": "user", "content": text})
        self._trim()

        emitted_places: set[str] = set()

        for _ in range(MAX_TOOL_ROUNDS):
            calls: list[tuple[str, str, dict[str, Any]]] = []
            buffer: list[str] = []
            # A reasoning model's scratchpad is not speech (agentd/thinking.py).
            thinking = ThinkingFilter()

            async for chunk in self.adapter.stream(self._messages(), self.tools.schemas()):
                spoken = thinking.feed(chunk.text) if chunk.text else ""
                if spoken:
                    buffer.append(spoken)
                    yield Token(utteranceId=utterance_id, text=spoken)

                    # Walk as soon as a known place is mentioned, rather than after the
                    # sentence completes. Motion overlapping speech is what reads as alive.
                    for directive in directives_for("".join(buffer), self.scene):
                        if directive.place and directive.place not in emitted_places:
                            emitted_places.add(directive.place)
                            yield Directive(directive=directive)

                for raw in chunk.tool_calls:
                    fn = raw.get("function", {})
                    calls.append(
                        (uuid.uuid4().hex[:12], fn.get("name", ""), _as_dict(fn.get("arguments")))
                    )

            tail = thinking.flush()
            if tail:
                buffer.append(tail)
                yield Token(utteranceId=utterance_id, text=tail)

            reply = "".join(buffer).strip()
            if reply:
                self.history.append({"role": "assistant", "content": reply})

            if not calls:
                break

            for call_id, name, args in calls:
                async for event in self._dispatch(call_id, name, args, emitted_places):
                    yield event

        yield UtteranceEnd(utteranceId=utterance_id)
        yield Directive(directive=CharacterDirective(kind="idle"))

    async def _dispatch(
        self,
        call_id: str,
        name: str,
        args: dict[str, Any],
        emitted_places: set[str] | None = None,
    ) -> AsyncIterator[ServerEvent]:
        """One tool call: announce it, get it fulfilled, write the result into history."""
        if name == ASK_FOR_PLACE:
            async for event in self._ask_for_place(args):
                yield event
            return

        safety = self.tools.safety_of(name)
        # Coerce before announcing: the client sees exactly the arguments that will run.
        args = self.tools.coerce(name, args)

        # A small model often acts without narrating the walk, so the character would stand
        # still while the lights change across the room. The device's own room is a place
        # the client already told us about, so this cannot invent a destination.
        place = self._place_for_device(args.get("device_id"))
        if place and (emitted_places is None or place not in emitted_places):
            if emitted_places is not None:
                emitted_places.add(place)
            yield Directive(
                directive=CharacterDirective(kind="walkTo", place=place, target="place")
            )

        self._pending_names[call_id] = name
        yield ToolCall(
            callId=call_id,
            name=name,
            args=args,
            safety=safety,
            executedBy=self.executor.location,
        )

        outcome = await self.executor.run(call_id, name, args, safety, self.pending)
        self._record(call_id, outcome)
        for device in _devices_in(outcome.payload):
            self._merge_device(device)

    async def _ask_for_place(self, args: dict[str, Any]) -> AsyncIterator[ServerEvent]:
        name = str(args.get("name", "")).strip()
        if not name:
            return
        if self.scene.has_place(name):
            self.history.append(
                {"role": "system", "content": f"[scene] '{name}' is already a known place."}
            )
            return
        if name.lower() in self.requested_places:
            self.history.append(
                {"role": "system", "content": f"[scene] already asked where '{name}' is."}
            )
            return

        self.requested_places.add(name.lower())
        prompt = f"Where's the {name}?"
        self.history.append({"role": "system", "content": f"[scene] asked the user: {prompt}"})
        yield RequestPlace(name=name, prompt=prompt)

    # --- internals ---------------------------------------------------------

    def _messages(self) -> list[dict[str, Any]]:
        return [
            {"role": "system", "content": build_system_prompt(self.scene, self.devices)},
            *self.history,
        ]

    def _record(self, call_id: str, outcome: Outcome) -> None:
        name = self._pending_names.pop(call_id, "unknown_tool")
        content = outcome.payload if outcome.ok else {"error": outcome.error or "failed"}
        self.history.append({"role": "tool", "name": name, "content": _compact(content)})
        self._trim()

    def _place_for_device(self, device_id: Any) -> str | None:
        """Device -> named place, resolved by room name only. Coordinates stay off the
        server (docs/architecture.md 3b)."""
        if not isinstance(device_id, str):
            return None
        device = next((d for d in self.devices if d.id == device_id), None)
        if device is None or not device.room:
            return None
        return next(
            (p.name for p in self.scene.places if p.name.lower() == device.room.lower()), None
        )

    def _merge_device(self, payload: dict[str, Any]) -> None:
        """Keep the prompt honest: a tool that changed a device updates our snapshot."""
        device_id = payload.get("id")
        state = payload.get("state")
        if not isinstance(device_id, str) or not isinstance(state, dict):
            return
        for device in self.devices:
            if device.id == device_id:
                device.state = state
                return

    def _trim(self) -> None:
        if len(self.history) > MAX_TURNS:
            self.history = self.history[-MAX_TURNS:]


class SessionStore:
    """Sessions outlive sockets, so a sleep/wake resumes the conversation (todo 6)."""

    def __init__(self, ttl: float = SESSION_TTL) -> None:
        self._sessions: dict[str, Session] = {}
        self._ttl = ttl

    def get(self, session_id: str | None) -> Session | None:
        if not session_id:
            return None
        self.evict_expired()
        return self._sessions.get(session_id)

    def put(self, session: Session) -> Session:
        self._sessions[session.id] = session
        return session

    def evict_expired(self) -> None:
        now = time.monotonic()
        for key in [k for k, s in self._sessions.items() if now - s.touched_at > self._ttl]:
            del self._sessions[key]

    def __len__(self) -> int:
        return len(self._sessions)


def _devices_in(payload: dict[str, Any]) -> list[dict[str, Any]]:
    if "id" in payload and "state" in payload:
        return [payload]
    devices = payload.get("devices")
    return [d for d in devices if isinstance(d, dict)] if isinstance(devices, list) else []


def _as_dict(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        return value
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
            return parsed if isinstance(parsed, dict) else {}
        except json.JSONDecodeError:
            return {}
    return {}


def _compact(value: Any) -> str:
    return json.dumps(value, separators=(",", ":"))

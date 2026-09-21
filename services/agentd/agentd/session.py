"""Session: conversation state + the agent loop.

State lives here, on the Mac, not on the headset (docs/architecture.md 8). A headset that
sleeps and reconnects resumes rather than restarts, which is why `SessionStore` outlives any
one socket.
"""

from __future__ import annotations

import json
import logging
import time
import uuid
from collections.abc import AsyncIterator
from typing import Any

from .adapters.base import ModelAdapter
from .ambient import AmbientBus, TimerBus, appliance_completions, diff_devices
from .curiosity import Curiosity
from .directives import directives_for
from .executors import ClientExecutor, Outcome, PendingCalls, ToolExecutor
from .memory_intents import intent_for
from .memory_tools import (
    ASK_ABOUT,
    FORGET,
    MEMORY_TOOLS,
    RECALL,
    REMEMBER,
    SET_PERCH,
    UPDATE,
)
from .memory_tools import register as register_memory
from .profile import ProfileStore
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
from .teaching import (
    FORBID_REGION,
    NAME_OBJECT,
    TEACHING_TOOLS,
    clean_name,
    hardness,
)
from .teaching import register as register_teaching
from .thinking import ThinkingFilter
from .tools import ASK_FOR_PLACE, LOOK_AT, SET_TIMER, WALK_TO, ToolRegistry
from .toolspeak import extract_call

log = logging.getLogger("agentd.session")

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
        profile: ProfileStore | None = None,
    ) -> None:
        self.id = session_id or uuid.uuid4().hex[:12]
        self.adapter = adapter
        # Teaching is part of the tool surface of every session: a session whose registry
        # was built before teaching existed would silently drop the acts.
        self.tools = register_memory(register_teaching(tools))
        # The profile outlives the session and the process. It is shared rather than owned:
        # two sessions on one machine are the same person, and a memory that only one of
        # them could see would be a memory the user cannot trust.
        self.profile = profile if profile is not None else ProfileStore()
        self.curiosity = Curiosity(self.profile)
        self.executor: ToolExecutor = executor or ClientExecutor()
        self.scene = SceneSnapshot()
        # A server-owned home is known before any client connects.
        self.devices: list[Device] = self.server_devices()
        self.history: list[dict[str, Any]] = []
        self.pending = PendingCalls()
        self.ambient = AmbientBus()
        # Ambient sources beyond device diffs (phase E): a timer the user asked for.
        self.timers = TimerBus()
        self.touched_at = time.monotonic()
        # Places the agent has already asked about, so it stops asking (todo 3).
        self.requested_places: set[str] = set()
        self._pending_names: dict[str, str] = {}

    def server_devices(self) -> list[Device]:
        """What this machine holds, when this machine is the one executing. Empty when the
        headset owns the home."""
        devices = getattr(self.executor, "devices", None)
        return list(devices()) if callable(devices) else []

    def adopt_server_devices(self) -> list[Device]:
        """Server-owned devices are the session's device list; the client has none to send."""
        devices = self.server_devices()
        if devices:
            self.devices = devices
        return devices

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
        """Returns the ambient events this snapshot earned, after rate limiting.

        When this machine owns the home, its own list is authoritative. A visionOS client
        has no HomeKit at all and sends an empty snapshot; taking that at face value wiped
        the devices out of the prompt and the model then had nothing it could act on.
        """
        if self.executor.location == "server" and self.server_devices():
            return []

        events: list[AmbientEvent] = []
        if self.devices:
            candidates = appliance_completions(self.devices, devices)
            candidates += diff_devices(self.devices, devices)
            for source, kind, text in candidates:
                event = self.ambient.offer(source, kind, text)
                if event is not None:
                    events.append(event)
        self.devices = devices
        self.touch()
        return events

    def due_timers(self) -> list[AmbientEvent]:
        """Timers that have come up since the last check. Polled rather than scheduled: the
        socket loop is already awake, and a timer that fires a second late is a timer."""
        out: list[AmbientEvent] = []
        for source, kind, text in self.timers.due():
            event = self.ambient.offer(source, kind, text)
            if event is not None:
                out.append(event)
        return out

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

        # Unprompted speech yields to the user for 30s (spec/07-memory.md Curiosity).
        self.ambient.note_utterance()

        # If the bird asked something and this is the reply, bank it here rather than hoping
        # the model calls remember_about_user. A 3B model drops that call often enough that
        # the answer would be lost, and an agent that asks a question and forgets the answer
        # is worse than one that never asked.
        banked = self._bank_answer(text)
        if banked:
            self.history.append(
                {"role": "system", "content": f"[memory] stored: {banked}"}
            )

        self.history.append({"role": "user", "content": text})
        self._trim()

        # An utterance that can only be a memory operation is executed before the model is
        # asked anything, so whether the memory changed does not depend on the model
        # choosing to call a tool (agentd/memory_intents.py). The model still speaks the
        # reply, from the tool result now sitting in its history.
        intent = intent_for(text)
        if intent is not None and not banked:
            self._memory_tool(*intent)

            # "Ask me something" is answered by the question engine, not by the model. A 1.7B
            # model handed a question in a tool result will sometimes paraphrase it into
            # something it already knows the answer to, which wastes the one question the
            # pacing rules allow.
            if intent[0] == ASK_ABOUT and self.curiosity.open_question is not None:
                question = self.curiosity.open_question.text
                self.history.append({"role": "assistant", "content": question})
                yield Token(utteranceId=utterance_id, text=question)
                yield UtteranceEnd(utteranceId=utterance_id)
                yield Directive(directive=CharacterDirective(kind="lookAt", target="user"))
                return

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

            # A small model that typed the call instead of making it. Only rescued when it
            # made no real call this round, so a model doing the right thing is never
            # second-guessed (agentd/toolspeak.py).
            if not calls and reply:
                typed = extract_call(reply, self.tools.names())
                if typed is not None:
                    name, args = typed
                    log.info("rescued typed tool call %s", name)
                    calls.append((uuid.uuid4().hex[:12], name, args))
                    reply = ""

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
        # Character tools move the body or ask a question. They never reach an executor,
        # and they are how movement becomes a decision the model states outright rather
        # than something inferred from its prose.
        if name == ASK_FOR_PLACE:
            async for event in self._ask_for_place(args):
                yield event
            return

        if name == WALK_TO:
            async for event in self._walk_to(args, emitted_places):
                yield event
            return

        if name == LOOK_AT:
            async for event in self._look_at(args):
                yield event
            return

        if name == SET_TIMER:
            label = str(args.get("name") or "").strip() or "timer"
            try:
                seconds = float(args.get("seconds") or 0)
            except (TypeError, ValueError):
                seconds = 0.0
            source = self.timers.set(label, seconds)
            self.history.append(
                {
                    "role": "tool",
                    "name": SET_TIMER,
                    "content": _compact({"timer": label, "seconds": seconds, "source": source}),
                }
            )
            return

        if name in MEMORY_TOOLS and name != SET_PERCH:
            self._memory_tool(name, args)
            return

        if name == SET_PERCH:
            # A perch is a *place with a kind*, so it is taught the same way every other
            # place is: the client resolves what the user is looking at and writes the
            # record. The server only says that the kind is `perch`.
            self._pending_names[call_id] = name
            payload: dict[str, Any] = {"kind": "perch"}
            place = str(args.get("place") or "").strip()
            known = self._known_place(place) if place else None
            if known:
                payload["place"] = known
            yield Directive(directive=CharacterDirective(kind="lookAt", target="place"))
            yield ToolCall(
                callId=call_id, name=name, args=payload, safety="safe", executedBy="client"
            )
            return

        if name in TEACHING_TOOLS:
            async for event in self._teach(call_id, name, args):
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
        # One line per action, because "the model did nothing" and "the model did the wrong
        # thing" look identical from outside.
        log.info("tool %s %s safety=%s by=%s", name, args, safety, self.executor.location)
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

    async def _walk_to(
        self, args: dict[str, Any], emitted_places: set[str] | None
    ) -> AsyncIterator[ServerEvent]:
        requested = str(args.get("place", "")).strip()
        place = self._known_place(requested)
        if place is None:
            # A place the client never sent cannot be walked to, whatever the model says.
            self.history.append(
                {
                    "role": "tool",
                    "name": WALK_TO,
                    "content": _compact(
                        {"error": f"no such place: {requested}",
                         "places": self.scene.place_names()}
                    ),
                }
            )
            return

        if emitted_places is not None:
            if place in emitted_places:
                return
            emitted_places.add(place)

        self.history.append(
            {"role": "tool", "name": WALK_TO, "content": _compact({"walking_to": place})}
        )
        log.info("walkTo %s", place)
        yield Directive(directive=CharacterDirective(kind="walkTo", place=place, target="place"))

    async def _look_at(self, args: dict[str, Any]) -> AsyncIterator[ServerEvent]:
        target = str(args.get("target", "user")).strip()
        place = self._known_place(target)
        directive = (
            CharacterDirective(kind="lookAt", place=place, target="place")
            if place
            else CharacterDirective(kind="lookAt", target="user")
        )
        self.history.append(
            {"role": "tool", "name": LOOK_AT, "content": _compact({"looking_at": place or "user"})}
        )
        yield Directive(directive=directive)

    async def _teach(
        self, call_id: str, name: str, args: dict[str, Any]
    ) -> AsyncIterator[ServerEvent]:
        """A teaching act, handed to the client to resolve against the held gaze target.

        The server contributes the act and the name and nothing else. It never learns where
        the user was looking, which is the whole reason teaching is a client-executed tool
        rather than something the server resolves and stores (spec/07-memory.md Enforcement).
        """
        spoken = clean_name(args.get("name"))
        payload: dict[str, Any] = {}
        if spoken:
            payload["name"] = spoken
        if name == FORBID_REGION:
            payload["hard"] = hardness(args)
        elif not spoken:
            # Every other act is a name; without one there is nothing to teach, and asking
            # beats writing an empty record.
            self.history.append(
                {
                    "role": "tool",
                    "name": name,
                    "content": _compact({"error": "no name was heard; ask the user to repeat"}),
                }
            )
            return
        if name == NAME_OBJECT and isinstance(args.get("device_id"), str):
            payload["device_id"] = args["device_id"]

        self._pending_names[call_id] = name
        log.info("teach %s %s", name, payload)
        # Look at it first: every act produces a visible reaction within 400ms, and the look
        # is the part that does not need the record to have been written yet.
        yield Directive(directive=CharacterDirective(kind="lookAt", target="place"))
        yield ToolCall(
            callId=call_id,
            name=name,
            args=payload,
            safety="safe",
            executedBy="client",
        )

    def _known_place(self, name: str) -> str | None:
        lowered = name.strip().lower()
        if not lowered:
            return None
        return next((p.name for p in self.scene.places if p.name.lower() == lowered), None)

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

    def _bank_answer(self, text: str) -> str | None:
        """The user's reply to an open curiosity question, stored verbatim.

        A reply that is plainly a refusal is not a fact about the person, and writing "no"
        into their profile as an identity claim is the kind of memory bug that makes a
        memory system untrustworthy."""
        if self.curiosity.open_question is None:
            return None
        stripped = text.strip().rstrip(".!?").lower()
        if stripped in {"no", "nope", "skip", "later", "not now", "pass", "none"}:
            self.curiosity.drop()
            return None
        fact_id = self.curiosity.answer(text)
        return text.strip() if fact_id else None

    def _memory_tool(self, name: str, args: dict[str, Any]) -> None:
        """Profile reads and writes. Server-executed, because the profile lives here."""
        result: dict[str, Any]
        if name == REMEMBER:
            text = str(args.get("text") or "").strip()
            if not text:
                result = {"error": "nothing to remember"}
            else:
                fact = self.profile.remember(
                    text=text,
                    slot=str(args.get("slot") or "misc"),
                    place=(str(args["place"]) if args.get("place") else None),
                )
                result = {"stored": fact.text, "fact_id": fact.id, "slot": fact.slot}
        elif name == RECALL:
            hits = self.profile.search(str(args.get("query") or ""))
            result = (
                {"facts": [{"id": f.id, "text": f.as_line(), "slot": f.slot} for f in hits]}
                if hits
                # An empty result is stated, because a model handed `{}` fills the silence
                # with a plausible memory the user never gave it.
                else {"facts": [], "note": "nothing remembered about that yet"}
            )
        elif name == FORGET:
            query = str(args.get("query") or "")
            fact = self.profile.get(query)
            dropped = [self.profile.forget(query)] if fact else self.profile.forget_matching(query)
            result = {"forgot": [f.text for f in dropped if f]} if dropped else {
                "forgot": [],
                "note": "nothing matched; say it back to the user rather than claiming it is gone",
            }
        elif name == UPDATE:
            fact = self.profile.update(
                str(args.get("fact_id") or ""), text=str(args.get("text") or "").strip() or None
            )
            result = {"updated": fact.text, "fact_id": fact.id} if fact else {
                "error": "no fact with that id; call recall_about_user first"
            }
        elif name == ASK_ABOUT:
            question = self.curiosity.next_question(self.scene, force=True)
            result = (
                {"ask": question.text, "about": question.slot}
                if question
                else {"note": "no new question right now; do not invent one"}
            )
        else:  # pragma: no cover - MEMORY_TOOLS is exhaustive
            result = {"error": f"unhandled memory tool {name}"}

        log.info("memory %s %s -> %s", name, args, result)
        self.history.append({"role": "tool", "name": name, "content": _compact(result)})
        self._trim()

    def _messages(self) -> list[dict[str, Any]]:
        return [
            {
                "role": "system",
                "content": build_system_prompt(
                    self.scene, self.devices, self.profile.digest()
                ),
            },
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

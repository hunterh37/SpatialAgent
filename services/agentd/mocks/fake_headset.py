#!/usr/bin/env python3
"""Pretend to be a Vision Pro.

Opens a real WebSocket to a real agentd, sends a real scene and real devices, and renders
what comes back. No Mac, no headset, no Xcode. See docs/architecture.md 6.

    python -m mocks.fake_headset --scenario apartment
    python -m mocks.fake_headset --scenario apartment --say "turn off the kitchen lights"
    python -m mocks.fake_headset --resume 4f1c2a9b0d3e   # sleep/wake, same conversation

Commands at the prompt: /devices, /ring (fire a doorbell), /place NAME, /look NAME (what the
user is staring at, which is what a teaching act resolves against), /map, /memory, /forget
TEXT, /quit.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import uuid
from typing import ClassVar

import websockets

from agentd.protocol import (
    PROTOCOL_VERSION,
    MapActivityRef,
    MapObjectRef,
    MapPlace,
    MapRuleRef,
)

from .mock_home import MockHome
from .scenario import Scenario

#: What the headset would be looking at when a teaching act lands. There is no gaze here, so
#: the demo declares it: `/look desk` before "this is where I work" makes the headless run
#: behave like the headset run instead of quietly guessing.
DEFAULT_GAZE = "the spot in front of you"

#: One scripted run of the whole memory story, for a demo with no hands free. Ordered so each
#: line depends on the one before it: teach, act on what was taught, then recall it.
DEMO_SCRIPT = [
    "this is your perch",
    "go to your perch",
    "this is where I do morning standup",
    "remember that I drink oat flat whites",
    "what do you remember about me?",
    "turn on the desk lamp",
    "ask me something about myself",
]

DIM = "\033[2m"
BOLD = "\033[1m"
CYAN = "\033[36m"
YELLOW = "\033[33m"
RED = "\033[31m"
RESET = "\033[0m"


class FakeMap:
    """The half of memory that lives on the headset, faked.

    The server never learns where anything is, so a teaching act only becomes a record if a
    client writes one (spec/07-memory.md Enforcement). Without this, a headless run could
    teach the bird a name and then find the name gone on the next scene update — which looks
    exactly like a broken memory system, and hid a real bug once.
    """

    KINDS: ClassVar[set[str]] = {
        "name_place", "name_object", "forbid_region", "name_activity",
        "correct_name", "set_home_perch",
    }

    def __init__(self, scene) -> None:
        self.scene = scene
        self.gaze = DEFAULT_GAZE
        self.last_named: str | None = None

    def handles(self, name: str) -> bool:
        return name in self.KINDS

    def execute(self, name: str, args: dict) -> tuple[bool, dict, str | None]:
        spoken = str(args.get("name") or "").strip()
        target = spoken or self.gaze

        if name == "set_home_perch":
            place = str(args.get("place") or "").strip() or self.gaze
            for existing in self.scene.places:
                # Exactly one perch: a second one would leave the bird with two homes and no
                # way to choose, which is a worse answer than moving the first.
                if existing.kind == "perch" and existing.name.lower() != place.lower():
                    existing.kind = "generic"
            self._upsert_place(place, kind="perch")
            self.last_named = place
            return True, {"perch": place, "anchored": True}, None

        if name == "name_place":
            self._upsert_place(target, kind=str(args.get("kind") or "generic"))
            self.last_named = target
            return True, {"place": target, "anchored": True}, None

        if name == "name_object":
            self.scene.objects = [o for o in self.scene.objects if o.name != target]
            self.scene.objects.append(
                MapObjectRef(name=target, deviceId=args.get("device_id"), place=None)
            )
            self.last_named = target
            return True, {"object": target, "anchored": True}, None

        if name == "forbid_region":
            hard = args.get("hard", True)
            self.scene.rules.append(
                MapRuleRef(
                    kind="forbidden",
                    severity="hard" if hard else "soft",
                    name=spoken or self.gaze,
                )
            )
            return True, {"rule": spoken or self.gaze, "hard": bool(hard)}, None

        if name == "name_activity":
            self.scene.activities.append(MapActivityRef(name=target, place=self.last_named))
            return True, {"activity": target, "place": self.last_named}, None

        # correct_name: the last thing named was wrong, so rename it rather than adding one.
        old = self.last_named
        for place in self.scene.places:
            if old and place.name == old:
                place.name = target
        self.last_named = target
        return True, {"renamed": old, "to": target}, None

    def _upsert_place(self, name: str, kind: str) -> None:
        for place in self.scene.places:
            if place.name.lower() == name.lower():
                place.kind = kind
                return
        self.scene.places.append(MapPlace(name=name, kind=kind, navigable=True))


def _fmt_directive(d: dict) -> str:
    kind = d.get("kind")
    detail = d.get("place") or d.get("target") or d.get("emotion") or ""
    return f"{kind}({detail})" if detail else str(kind)


async def run(
    url: str,
    scenario: Scenario,
    auto_confirm: bool,
    script: list[str],
    resume: str | None = None,
    timeout: float = 120.0,
) -> int:
    home = MockHome(scenario.devices)
    scene = scenario.scene
    fake_map = FakeMap(scene)
    session_id: str | None = resume

    async with websockets.connect(url) as ws:
        hello = {
            "type": "hello", "protocolVersion": PROTOCOL_VERSION, "client": "fake_headset",
        }
        if resume:
            hello["sessionId"] = resume
        await ws.send(json.dumps(hello))
        await ws.send(json.dumps({
            "type": "sceneUpdate", "scene": scene.model_dump(exclude_none=True),
        }))
        await ws.send(json.dumps({
            "type": "deviceStates",
            "devices": [d.model_dump() for d in home.snapshot()],
        }))

        async def push_devices() -> None:
            await ws.send(json.dumps({
                "type": "deviceStates",
                "devices": [d.model_dump() for d in home.snapshot()],
            }))

        async def push_scene() -> None:
            await ws.send(json.dumps({
                "type": "sceneUpdate", "scene": scene.model_dump(exclude_none=True),
            }))

        pending: list[str] = list(script)
        speaking = False
        turn_done = asyncio.Event()

        async def pump() -> None:
            nonlocal speaking, session_id
            async for raw in ws:
                event = json.loads(raw)
                kind = event.get("type")

                if kind == "ready":
                    session_id = event["sessionId"]
                    caps = event.get("capabilities", {})
                    state = "resumed" if event.get("resumed") else "new"
                    print(f"{DIM}connected · session {session_id} ({state}) · "
                          f"model {event['model']}{RESET}")
                    print(f"{DIM}tools execute: {caps.get('toolExecution', 'client')} · "
                          f"ambient: {caps.get('ambientEvents')} · "
                          f"keepalive < {caps.get('idleTimeoutSeconds')}s{RESET}")
                    print(f"{DIM}places: {', '.join(scene.place_names()) or 'none'}"
                          f"{RESET}\n")

                elif kind == "token":
                    if not speaking:
                        print(f"{BOLD}agent:{RESET} ", end="")
                        speaking = True
                    print(event["text"], end="", flush=True)

                elif kind == "utteranceEnd":
                    if speaking:
                        print()
                    speaking = False
                    turn_done.set()
                    print()

                elif kind == "characterDirective":
                    print(f"\n  {YELLOW}[character]{RESET} "
                          f"{_fmt_directive(event['directive'])}")
                    speaking = False

                elif kind == "ambientEvent":
                    print(f"\n  {CYAN}[ambient]{RESET} {event['kind']}/{event['interrupt']} "
                          f"{event['source']}: {event['text']}")
                    speaking = False

                elif kind == "requestPlace":
                    print(f"\n  {CYAN}[place]{RESET} agent asks: {event['prompt']}")
                    speaking = False

                elif kind == "toolCall":
                    name, args = event["name"], event.get("args", {})
                    unsafe = event["safety"] == "unsafe"
                    server_side = event.get("executedBy", "client") == "server"
                    print(f"\n  {YELLOW}[tool]{RESET} {name}({json.dumps(args)}) "
                          f"safety={event['safety']} by={event.get('executedBy', 'client')}")

                    approved = True
                    if unsafe and not auto_confirm:
                        answer = await asyncio.to_thread(
                            input, f"  {RED}confirm {name}? [y/N] {RESET}"
                        )
                        approved = answer.strip().lower() == "y"

                    if server_side:
                        # The server executes. This headset only answers the question it is
                        # good at answering: did a human approve?
                        await ws.send(json.dumps({
                            "type": "confirmationResult", "callId": event["callId"],
                            "approved": approved,
                        }))
                        print(f"  {DIM}-> approved={approved} (server executes){RESET}")
                        speaking = False
                        continue

                    if not approved:
                        await ws.send(json.dumps({
                            "type": "toolResult", "callId": event["callId"],
                            "ok": False, "error": "user cancelled",
                        }))
                        continue

                    if fake_map.handles(name):
                        ok, payload, error = fake_map.execute(name, args)
                        # The taught record only exists once the server sees it again.
                        await push_scene()
                    else:
                        ok, payload, error = home.execute(name, args)
                    print(f"  {DIM}-> ok={ok} {json.dumps(payload)[:120]}{RESET}")
                    await ws.send(json.dumps({
                        "type": "toolResult", "callId": event["callId"],
                        "ok": ok, "payload": payload, "error": error,
                    }))
                    speaking = False

                elif kind == "error":
                    print(f"\n  {RED}[error]{RESET} {event['code']}: {event['message']}")
                    turn_done.set()

        pump_task = asyncio.create_task(pump())

        try:
            while True:
                if pending:
                    text = pending.pop(0)
                    print(f"{BOLD}you:{RESET} {text}")
                else:
                    if script:
                        break
                    text = await asyncio.to_thread(input, f"{BOLD}you:{RESET} ")
                    if text.strip() in {"", "quit", "exit", "/quit"}:
                        break
                    command = text.strip()
                    if command == "/devices":
                        for d in home.snapshot():
                            print(f"  {d.id:16} {d.name:16} {d.state}")
                        continue
                    if command == "/ring":
                        # Ambient: the home speaks first, with nobody having said anything.
                        home.devices["sensor.doorbell"].state["ringing"] = True
                        await push_devices()
                        continue
                    if command in {"/memory", "/mem"}:
                        # The profile, as the model sees it. Printed from the same digest
                        # that goes into the system prompt, so there is no second version of
                        # the truth to drift.
                        from agentd.profile import ProfileStore

                        store = ProfileStore()
                        print(f"  {DIM}{store.path}{RESET}")
                        print(store.digest() or f"  {DIM}(nothing remembered yet){RESET}")
                        continue
                    if command.startswith("/forget "):
                        from agentd.profile import ProfileStore

                        store = ProfileStore()
                        dropped = store.forget_matching(command.removeprefix("/forget ").strip())
                        print(f"  {DIM}forgot: {[f.text for f in dropped] or 'nothing'}{RESET}")
                        continue
                    if command.startswith("/look "):
                        fake_map.gaze = command.removeprefix("/look ").strip()
                        print(f"  {DIM}looking at '{fake_map.gaze}'{RESET}")
                        continue
                    if command == "/map":
                        print(f"  places: {[(p.name, p.kind) for p in scene.places]}")
                        print(f"  objects: {[o.name for o in scene.objects]}")
                        print(f"  rules: {[(r.kind, r.name) for r in scene.rules]}")
                        print(f"  activities: {[a.name for a in scene.activities]}")
                        continue
                    if command.startswith("/place "):
                        name = command.removeprefix("/place ").strip()
                        # The wire map is names only, so a fake place is a name and a kind.
                        scene.places.append(MapPlace(name=name))
                        await push_scene()
                        print(f"  {DIM}named '{name}'{RESET}")
                        continue

                turn_done.clear()
                await ws.send(json.dumps({
                    "type": "userUtterance", "id": uuid.uuid4().hex[:8], "text": text,
                }))
                if script:
                    # Wait for the turn rather than guessing: a cold local model can take
                    # tens of seconds to load before the first token.
                    try:
                        await asyncio.wait_for(turn_done.wait(), timeout)
                    except TimeoutError:
                        print(f"\n  {RED}[timeout]{RESET} no utteranceEnd within {timeout}s")
        except (KeyboardInterrupt, EOFError):
            pass
        finally:
            pump_task.cancel()

    print(f"\n{DIM}final device state:{RESET}")
    for d in home.snapshot():
        print(f"  {d.id:16} {d.state}")
    if session_id:
        print(f"{DIM}resume with: --resume {session_id}{RESET}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="fake_headset")
    parser.add_argument("--url", default="ws://127.0.0.1:8787/agent")
    parser.add_argument("--scenario", default="apartment")
    parser.add_argument("--say", action="append", default=[],
                        help="scripted utterance; repeatable, exits when done")
    parser.add_argument("--yes", action="store_true", help="auto-confirm unsafe tools")
    parser.add_argument("--resume", help="sessionId from an earlier run; resumes the transcript")
    parser.add_argument("--timeout", type=float, default=120.0,
                        help="seconds a scripted turn waits for utteranceEnd")
    parser.add_argument("--list-scenarios", action="store_true")
    parser.add_argument("--demo", action="store_true",
                        help="run the scripted memory demo end to end")
    args = parser.parse_args()

    if args.list_scenarios:
        print("\n".join(Scenario.available()))
        return 0

    scenario = Scenario.load(args.scenario)
    script = args.say or (DEMO_SCRIPT if args.demo else [])
    return asyncio.run(
        run(args.url, scenario, args.yes or args.demo, script, args.resume, args.timeout)
    )


if __name__ == "__main__":
    sys.exit(main())

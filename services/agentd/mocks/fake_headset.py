#!/usr/bin/env python3
"""Pretend to be a Vision Pro.

Opens a real WebSocket to a real agentd, sends a real scene and real devices, and renders
what comes back. No Mac, no headset, no Xcode. See docs/architecture.md 6.

    python -m mocks.fake_headset --scenario apartment
    python -m mocks.fake_headset --scenario apartment --say "turn off the kitchen lights"
    python -m mocks.fake_headset --resume 4f1c2a9b0d3e   # sleep/wake, same conversation

Commands at the prompt: /devices, /ring (fire a doorbell), /place NAME, /quit.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import uuid

import websockets

from agentd.protocol import PROTOCOL_VERSION, NamedPlace, Vec3

from .mock_home import MockHome
from .scenario import Scenario

DIM = "\033[2m"
BOLD = "\033[1m"
CYAN = "\033[36m"
YELLOW = "\033[33m"
RED = "\033[31m"
RESET = "\033[0m"


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
) -> int:
    home = MockHome(scenario.devices)
    scene = scenario.scene
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

                    ok, payload, error = home.execute(name, args)
                    print(f"  {DIM}-> ok={ok} {json.dumps(payload)[:120]}{RESET}")
                    await ws.send(json.dumps({
                        "type": "toolResult", "callId": event["callId"],
                        "ok": ok, "payload": payload, "error": error,
                    }))
                    speaking = False

                elif kind == "error":
                    print(f"\n  {RED}[error]{RESET} {event['code']}: {event['message']}")

        pump_task = asyncio.create_task(pump())

        try:
            while True:
                if pending:
                    text = pending.pop(0)
                    print(f"{BOLD}you:{RESET} {text}")
                else:
                    if script:
                        await asyncio.sleep(0.5)
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
                    if command.startswith("/place "):
                        name = command.removeprefix("/place ").strip()
                        scene.places.append(NamedPlace(
                            name=name, position=Vec3(x=0.0, y=0.0, z=-1.0), radius=0.5
                        ))
                        await push_scene()
                        print(f"  {DIM}named '{name}'{RESET}")
                        continue

                await ws.send(json.dumps({
                    "type": "userUtterance", "id": uuid.uuid4().hex[:8], "text": text,
                }))
                await asyncio.sleep(0.3 if pending else 0.0)
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
    parser.add_argument("--list-scenarios", action="store_true")
    args = parser.parse_args()

    if args.list_scenarios:
        print("\n".join(Scenario.available()))
        return 0

    scenario = Scenario.load(args.scenario)
    return asyncio.run(run(args.url, scenario, args.yes, args.say, args.resume))


if __name__ == "__main__":
    sys.exit(main())

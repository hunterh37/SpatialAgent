"""One example of every message, in both directions.

The drift check in `scripts/check_protocol.py` proves a field name exists in both languages.
It cannot prove the two sides agree about what the bytes mean. This corpus can: Python emits
it, Swift decodes every entry and re-encodes it, and each side asserts on the other's output.

A new message type without an entry here fails `test_every_message_type_has_an_example`,
so the corpus cannot quietly fall behind the schema.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .protocol import (
    PROTOCOL_VERSION,
    AmbientEvent,
    Capabilities,
    CharacterDirective,
    ConfirmationResult,
    Device,
    DeviceStates,
    Directive,
    Error,
    Hello,
    HomeDevices,
    MapObjectRef,
    MapPlace,
    MapRuleRef,
    Ping,
    Pong,
    Ready,
    RequestPlace,
    SceneSnapshot,
    SceneUpdate,
    Token,
    ToolCall,
    ToolResult,
    UserUtterance,
    UtteranceEnd,
)

CORPUS_PATH = (
    Path(__file__).resolve().parents[3]
    / "packages"
    / "AgentProtocol"
    / "conformance"
    / "corpus.json"
)

_KITCHEN = MapPlace(name="kitchen", kind="generic", navigable=True)
_LIGHT = Device(
    id="light.kitchen",
    name="Kitchen Lights",
    room="kitchen",
    kind="light",
    state={"on": True, "brightness": 80},
    capabilities=["on_off", "brightness"],
)


def client_messages() -> list[Any]:
    return [
        Hello(protocolVersion=PROTOCOL_VERSION, client="visionOS 2.0"),
        Hello(protocolVersion=PROTOCOL_VERSION, client="visionOS 2.0", sessionId="s-resume"),
        UserUtterance(id="u1", text="turn off the kitchen lights"),
        UserUtterance(id="u2", text="turn off the", isFinal=False),
        SceneUpdate(
            scene=SceneSnapshot(
                places=[_KITCHEN],
                objects=[MapObjectRef(name="coffee machine", deviceId="dev-1", place="kitchen")],
                rules=[MapRuleRef(kind="forbidden", severity="hard", name="the shrine")],
                userPlace="kitchen",
                floorArea=46.0,
            )
        ),
        DeviceStates(devices=[_LIGHT]),
        ToolResult(callId="c1", ok=True, payload={"id": "light.kitchen", "state": {"on": False}}),
        ToolResult(callId="c2", ok=False, error="user_cancelled"),
        ConfirmationResult(callId="c3", approved=True),
        Ping(),
    ]


def server_events() -> list[Any]:
    return [
        Ready(
            sessionId="s1",
            model="ollama/llama3.2:3b",
            capabilities=Capabilities(ambientEvents=True, toolExecution="server"),
            resumed=True,
        ),
        Token(utteranceId="u1", text="Heading "),
        UtteranceEnd(utteranceId="u1"),
        Directive(directive=CharacterDirective(kind="walkTo", place="kitchen", target="place")),
        Directive(directive=CharacterDirective(kind="lookAt", target="user")),
        Directive(directive=CharacterDirective(kind="emote", emotion="thinking")),
        Directive(directive=CharacterDirective(kind="point", deviceId="light.kitchen",
                                               target="device")),
        Directive(directive=CharacterDirective(kind="gesture")),
        Directive(directive=CharacterDirective(kind="idle")),
        ToolCall(
            callId="c1",
            name="set_light",
            args={"device_id": "light.kitchen", "on": False},
            safety="safe",
            executedBy="client",
        ),
        ToolCall(callId="c2", name="set_lock", args={"locked": False}, safety="unsafe",
                 executedBy="server"),
        HomeDevices(devices=[_LIGHT]),
        AmbientEvent(
            source="sensor.doorbell", kind="doorbell", interrupt="now",
            text="Someone is at the door.",
        ),
        RequestPlace(name="kitchen", prompt="Where's the kitchen?"),
        Error(code="agent_error", message="the model went away"),
        Pong(),
    ]


def build() -> dict[str, list[dict[str, Any]]]:
    return {
        "clientMessages": [json.loads(m.model_dump_json()) for m in client_messages()],
        "serverEvents": [json.loads(e.model_dump_json()) for e in server_events()],
    }


def write(path: Path | None = None) -> Path:
    target = path or CORPUS_PATH
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(build(), indent=2, sort_keys=True) + "\n")
    return target


if __name__ == "__main__":
    print(write())

"""Wire types.

Mirrors packages/AgentProtocol/schema/protocol.schema.json, which is the source of truth.
Phase 1 keeps these hand-written but schema-validated by tests; codegen replaces this file
in phase 2 (see docs/architecture.md 3a).
"""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field

PROTOCOL_VERSION = 1


class Vec3(BaseModel):
    x: float
    y: float
    z: float


class NamedPlace(BaseModel):
    name: str
    position: Vec3
    radius: float = 0.5


class SceneSnapshot(BaseModel):
    places: list[NamedPlace] = Field(default_factory=list)
    floorArea: float | None = None
    userPosition: Vec3 | None = None

    def place_names(self) -> list[str]:
        return [p.name for p in self.places]

    def has_place(self, name: str) -> bool:
        return any(p.name.lower() == name.lower() for p in self.places)


DeviceKind = Literal["light", "lock", "thermostat", "cover", "sensor", "scene", "media", "other"]
Safety = Literal["safe", "unsafe"]
DirectiveKind = Literal["walkTo", "lookAt", "point", "emote", "gesture", "idle"]


class Device(BaseModel):
    id: str
    name: str
    room: str | None = None
    kind: DeviceKind = "other"
    state: dict[str, Any] = Field(default_factory=dict)
    capabilities: list[str] = Field(default_factory=list)


class CharacterDirective(BaseModel):
    kind: DirectiveKind
    place: str | None = None
    target: Literal["user", "place", "device"] | None = None
    deviceId: str | None = None
    emotion: Literal["neutral", "confused", "happy", "concerned", "thinking"] | None = None


# --- client -> server -------------------------------------------------------


class Hello(BaseModel):
    type: Literal["hello"] = "hello"
    protocolVersion: int
    client: str


class UserUtterance(BaseModel):
    type: Literal["userUtterance"] = "userUtterance"
    id: str
    text: str


class SceneUpdate(BaseModel):
    type: Literal["sceneUpdate"] = "sceneUpdate"
    scene: SceneSnapshot


class DeviceStates(BaseModel):
    type: Literal["deviceStates"] = "deviceStates"
    devices: list[Device]


class ToolResult(BaseModel):
    type: Literal["toolResult"] = "toolResult"
    callId: str
    ok: bool
    payload: dict[str, Any] = Field(default_factory=dict)
    error: str | None = None


class Ping(BaseModel):
    type: Literal["ping"] = "ping"


ClientMessage = Hello | UserUtterance | SceneUpdate | DeviceStates | ToolResult | Ping

_CLIENT_TYPES: dict[str, type[BaseModel]] = {
    "hello": Hello,
    "userUtterance": UserUtterance,
    "sceneUpdate": SceneUpdate,
    "deviceStates": DeviceStates,
    "toolResult": ToolResult,
    "ping": Ping,
}


def parse_client_message(raw: dict[str, Any]) -> ClientMessage:
    """Validate at the socket boundary. Unknown types raise; callers ignore rather than die."""
    kind = raw.get("type")
    model = _CLIENT_TYPES.get(kind)
    if model is None:
        raise ValueError(f"unknown client message type: {kind!r}")
    return model.model_validate(raw)


# --- server -> client -------------------------------------------------------


class Ready(BaseModel):
    type: Literal["ready"] = "ready"
    sessionId: str
    protocolVersion: int = PROTOCOL_VERSION
    model: str


class Token(BaseModel):
    type: Literal["token"] = "token"
    utteranceId: str
    text: str


class UtteranceEnd(BaseModel):
    type: Literal["utteranceEnd"] = "utteranceEnd"
    utteranceId: str


class Directive(BaseModel):
    type: Literal["characterDirective"] = "characterDirective"
    directive: CharacterDirective


class ToolCall(BaseModel):
    type: Literal["toolCall"] = "toolCall"
    callId: str
    name: str
    args: dict[str, Any] = Field(default_factory=dict)
    safety: Safety


class Error(BaseModel):
    type: Literal["error"] = "error"
    code: str
    message: str


class Pong(BaseModel):
    type: Literal["pong"] = "pong"


ServerEvent = Ready | Token | UtteranceEnd | Directive | ToolCall | Error | Pong

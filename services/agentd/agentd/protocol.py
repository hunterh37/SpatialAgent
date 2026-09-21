"""Wire types.

Mirrors packages/AgentProtocol/schema/protocol.schema.json, which is the source of truth.
Phase 1 keeps these hand-written but schema-validated by tests; codegen replaces this file
in phase 2 (see docs/architecture.md 3a).
"""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field

PROTOCOL_VERSION = 1


class MapPlace(BaseModel):
    """A taught place, by name only.

    Coordinates never leave the client (spec/07-memory.md Enforcement), so there is nowhere
    in this model to put one. That is the privacy claim expressed as a type rather than as a
    promise.
    """

    name: str
    kind: Literal["generic", "workspace", "surface", "floor", "perch"] = "generic"
    navigable: bool = True


class MapObjectRef(BaseModel):
    name: str
    deviceId: str | None = None
    place: str | None = None


class MapRuleRef(BaseModel):
    kind: Literal["forbidden", "quiet", "perch", "fragile"]
    severity: Literal["hard", "soft"]
    name: str | None = None
    place: str | None = None


class MapActivityRef(BaseModel):
    name: str
    place: str | None = None


class SceneSnapshot(BaseModel):
    """The abstracted map: names, kinds and coarse relationships."""

    places: list[MapPlace] = Field(default_factory=list)
    objects: list[MapObjectRef] = Field(default_factory=list)
    rules: list[MapRuleRef] = Field(default_factory=list)
    activities: list[MapActivityRef] = Field(default_factory=list)
    userPlace: str | None = None
    floorArea: float | None = None

    def place_names(self) -> list[str]:
        return [p.name for p in self.places]

    def has_place(self, name: str) -> bool:
        return any(p.name.lower() == name.lower() for p in self.places)

    def navigable_place_names(self) -> list[str]:
        """Places the bird can actually reach: an un-relocalized anchor is a name it can
        talk about but not walk to."""
        return [p.name for p in self.places if p.navigable]


DeviceKind = Literal["light", "lock", "thermostat", "cover", "sensor", "scene", "media", "other"]
Safety = Literal["safe", "unsafe"]
DirectiveKind = Literal["walkTo", "lookAt", "point", "emote", "gesture", "idle"]
Executor = Literal["client", "server"]
AmbientKind = Literal["doorbell", "finished", "sensor", "stateChange"]
AmbientInterrupt = Literal["now", "passing", "silent"]


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
    # Absent means "new session". Present means "resume this one" — the client stores the id
    # it got from `ready` and offers it back after sleep/wake (spec/03-protocol.md).
    sessionId: str | None = None


class UserUtterance(BaseModel):
    type: Literal["userUtterance"] = "userUtterance"
    id: str
    text: str
    # False for a partial speech transcript. The character may begin reacting to a
    # half-finished sentence, but the model is not asked until the sentence lands.
    isFinal: bool = True


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


class ConfirmationResult(BaseModel):
    """The client approved or refused an unsafe call. It does not claim to have executed it.

    When the server owns execution, this is the client's entire job for a tool: asking a
    human (docs/middle-layer-todo.md 1).
    """

    type: Literal["confirmationResult"] = "confirmationResult"
    callId: str
    approved: bool


class Ping(BaseModel):
    type: Literal["ping"] = "ping"


ClientMessage = (
    Hello | UserUtterance | SceneUpdate | DeviceStates | ToolResult | ConfirmationResult | Ping
)

_CLIENT_TYPES: dict[str, type[BaseModel]] = {
    "hello": Hello,
    "userUtterance": UserUtterance,
    "sceneUpdate": SceneUpdate,
    "deviceStates": DeviceStates,
    "toolResult": ToolResult,
    "confirmationResult": ConfirmationResult,
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


class Capabilities(BaseModel):
    """What this server can do. The client reads it rather than discovering by failure."""

    ambientEvents: bool = True
    toolExecution: Executor = "client"
    requestPlace: bool = True
    speechInput: bool = False
    idleTimeoutSeconds: float = 30.0


class Ready(BaseModel):
    type: Literal["ready"] = "ready"
    sessionId: str
    protocolVersion: int = PROTOCOL_VERSION
    model: str
    capabilities: Capabilities = Field(default_factory=lambda: Capabilities())
    resumed: bool = False


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
    # "server": the client only approves; it must never report having acted itself.
    executedBy: Executor = "client"


class HomeDevices(BaseModel):
    """The server's device list, pushed downward.

    `deviceStates` only ever goes client -> server, which is right when the headset owns the
    home. When the Mac owns it — HomeKit is not in the visionOS SDK — the client has nothing
    to read, and needs this to name a device in a confirmation prompt.
    """

    type: Literal["homeDevices"] = "homeDevices"
    devices: list[Device] = Field(default_factory=list)


class AmbientEvent(BaseModel):
    """The home speaking first. PRD 4's fourth loop.

    `interrupt` is server-asserted and coarse: the client decides the rendering, but it
    should not be inferring urgency from a device id.
    """

    type: Literal["ambientEvent"] = "ambientEvent"
    source: str
    kind: AmbientKind
    interrupt: AmbientInterrupt
    text: str


class RequestPlace(BaseModel):
    """Ask the user to name a place, in character, instead of failing with unknownPlace."""

    type: Literal["requestPlace"] = "requestPlace"
    name: str
    prompt: str


class Error(BaseModel):
    type: Literal["error"] = "error"
    code: str
    message: str


class Pong(BaseModel):
    type: Literal["pong"] = "pong"


ServerEvent = (
    Ready | Token | UtteranceEnd | Directive | ToolCall | HomeDevices | AmbientEvent
    | RequestPlace | Error | Pong
)

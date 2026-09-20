"""The wire types must agree with the schema. This is the phase-1 stand-in for codegen."""

from __future__ import annotations

import json
import typing
from pathlib import Path

import jsonschema
import pytest

from agentd.protocol import (
    PROTOCOL_VERSION,
    AmbientEvent,
    Capabilities,
    ConfirmationResult,
    Device,
    Hello,
    Ready,
    RequestPlace,
    ToolCall,
    UserUtterance,
    parse_client_message,
)
from agentd.protocol import ServerEvent as ServerEventUnion

SCHEMA_PATH = (
    Path(__file__).parents[3] / "packages" / "AgentProtocol" / "schema" / "protocol.schema.json"
)


@pytest.fixture(scope="module")
def schema() -> dict:
    return json.loads(SCHEMA_PATH.read_text())


def _validate(schema: dict, definition: str, payload: dict) -> None:
    jsonschema.validate(
        payload,
        {**schema, "$ref": f"#/definitions/{definition}"},
    )


def test_client_messages_match_schema(schema: dict) -> None:
    messages = [
        Hello(protocolVersion=PROTOCOL_VERSION, client="test"),
        UserUtterance(id="u1", text="hello"),
    ]
    for message in messages:
        _validate(schema, "ClientMessage", json.loads(message.model_dump_json()))


def test_server_events_match_schema(schema: dict) -> None:
    events = [
        Ready(sessionId="s1", model="echo"),
        ToolCall(callId="c1", name="set_light", args={"on": True}, safety="safe"),
    ]
    for event in events:
        _validate(schema, "ServerEvent", json.loads(event.model_dump_json()))


def test_device_matches_schema(schema: dict) -> None:
    device = Device(id="light.kitchen", name="Kitchen", kind="light", state={"on": True})
    _validate(schema, "Device", json.loads(device.model_dump_json()))


def test_unknown_message_type_rejected() -> None:
    with pytest.raises(ValueError):
        parse_client_message({"type": "nonsense"})


def test_new_client_messages_match_schema(schema: dict) -> None:
    messages = [
        Hello(protocolVersion=PROTOCOL_VERSION, client="test", sessionId="s1"),
        UserUtterance(id="u1", text="turn off the", isFinal=False),
        ConfirmationResult(callId="c1", approved=True),
    ]
    for message in messages:
        _validate(schema, "ClientMessage", json.loads(message.model_dump_json()))


def test_new_server_events_match_schema(schema: dict) -> None:
    events = [
        Ready(sessionId="s1", model="echo", capabilities=Capabilities(), resumed=True),
        AmbientEvent(source="sensor.doorbell", kind="doorbell", interrupt="now", text="ring"),
        RequestPlace(name="kitchen", prompt="Where's the kitchen?"),
        ToolCall(callId="c1", name="set_lock", safety="unsafe", executedBy="server"),
    ]
    for event in events:
        _validate(schema, "ServerEvent", json.loads(event.model_dump_json()))


def test_every_schema_message_type_exists_in_python(schema: dict) -> None:
    """Drift guard: a type added to the schema must reach this language."""
    from agentd.protocol import _CLIENT_TYPES

    declared = set(schema["definitions"]["ClientMessage"]["properties"]["type"]["enum"])
    assert declared == set(_CLIENT_TYPES)

    server_declared = set(schema["definitions"]["ServerEvent"]["properties"]["type"]["enum"])
    implemented = {
        model.model_fields["type"].default for model in typing.get_args(ServerEventUnion)
    }
    assert server_declared == implemented


def test_capabilities_fields_match_schema(schema: dict) -> None:
    declared = set(schema["definitions"]["Capabilities"]["properties"])
    assert declared == set(Capabilities.model_fields)

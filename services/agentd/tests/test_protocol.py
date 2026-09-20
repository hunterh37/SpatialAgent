"""The wire types must agree with the schema. This is the phase-1 stand-in for codegen."""

from __future__ import annotations

import json
from pathlib import Path

import jsonschema
import pytest

from agentd.protocol import (
    PROTOCOL_VERSION,
    Device,
    Hello,
    Ready,
    ToolCall,
    UserUtterance,
    parse_client_message,
)

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

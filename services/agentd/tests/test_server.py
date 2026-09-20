from __future__ import annotations

import json

from fastapi.testclient import TestClient

from agentd.adapters.echo import EchoAdapter
from agentd.protocol import PROTOCOL_VERSION
from agentd.server import create_app


def _client() -> TestClient:
    return TestClient(create_app(EchoAdapter()))


def test_health() -> None:
    body = _client().get("/health").json()
    assert body["ok"] is True
    assert body["protocolVersion"] == PROTOCOL_VERSION


def test_hello_gets_ready() -> None:
    with _client().websocket_connect("/agent") as ws:
        ws.send_text(json.dumps(
            {"type": "hello", "protocolVersion": PROTOCOL_VERSION, "client": "test"}
        ))
        assert ws.receive_json()["type"] == "ready"


def test_version_mismatch_closes_socket() -> None:
    with _client().websocket_connect("/agent") as ws:
        ws.send_text(json.dumps({"type": "hello", "protocolVersion": 999, "client": "test"}))
        event = ws.receive_json()
        assert event["type"] == "error"
        assert event["code"] == "protocol_version_mismatch"


def test_unknown_message_is_ignored_not_fatal() -> None:
    with _client().websocket_connect("/agent") as ws:
        ws.send_text(json.dumps({"type": "from_the_future", "data": 1}))
        ws.send_text(json.dumps({"type": "ping"}))
        assert ws.receive_json()["type"] == "pong"


def test_full_utterance_round_trip() -> None:
    with _client().websocket_connect("/agent") as ws:
        ws.send_text(json.dumps(
            {"type": "hello", "protocolVersion": PROTOCOL_VERSION, "client": "test"}
        ))
        ws.receive_json()
        ws.send_text(json.dumps({"type": "userUtterance", "id": "u1", "text": "hello"}))

        kinds = []
        while True:
            event = ws.receive_json()
            kinds.append(event["type"])
            if event["type"] == "characterDirective" and event["directive"]["kind"] == "idle":
                break
        assert "token" in kinds
        assert "utteranceEnd" in kinds

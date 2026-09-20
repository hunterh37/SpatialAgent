from __future__ import annotations

import json

from fastapi.testclient import TestClient

from agentd.adapters.base import Chunk
from agentd.adapters.echo import EchoAdapter
from agentd.executors import ServerExecutor
from agentd.protocol import PROTOCOL_VERSION
from agentd.server import create_app
from mocks.mock_home import MockHome
from mocks.scenario import Scenario


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


def _hello(ws, session_id: str | None = None) -> dict:
    payload = {"type": "hello", "protocolVersion": PROTOCOL_VERSION, "client": "test"}
    if session_id:
        payload["sessionId"] = session_id
    ws.send_text(json.dumps(payload))
    return ws.receive_json()


def _drain_until(ws, kind: str, limit: int = 40) -> list[dict]:
    events = []
    for _ in range(limit):
        event = ws.receive_json()
        events.append(event)
        if event["type"] == kind:
            return events
    raise AssertionError(f"never saw {kind}: {[e['type'] for e in events]}")


def test_ready_states_capabilities() -> None:
    with _client().websocket_connect("/agent") as ws:
        caps = _hello(ws)["capabilities"]
        assert caps["toolExecution"] in {"client", "server"}
        assert caps["ambientEvents"] is True
        assert caps["idleTimeoutSeconds"] > 0


def test_reconnect_resumes_the_same_session() -> None:
    app = create_app(EchoAdapter())
    client = TestClient(app)

    with client.websocket_connect("/agent") as ws:
        ready = _hello(ws)
        session_id = ready["sessionId"]
        assert ready["resumed"] is False
        ws.send_text(json.dumps({"type": "userUtterance", "id": "u1", "text": "remember pears"}))
        _drain_until(ws, "utteranceEnd")

    # Sleep/wake: a new socket, the same conversation.
    with client.websocket_connect("/agent") as ws:
        ready = _hello(ws, session_id)
        assert ready["resumed"] is True
        assert ready["sessionId"] == session_id

    session = app.state.sessions.get(session_id)
    assert any(m["content"] == "remember pears" for m in session.history)


def test_unknown_session_id_starts_a_new_session() -> None:
    with _client().websocket_connect("/agent") as ws:
        assert _hello(ws, "nosuchsession")["resumed"] is False


def test_ping_works_before_hello() -> None:
    with _client().websocket_connect("/agent") as ws:
        ws.send_text(json.dumps({"type": "ping"}))
        assert ws.receive_json()["type"] == "pong"


def test_conversation_requires_hello() -> None:
    with _client().websocket_connect("/agent") as ws:
        ws.send_text(json.dumps({"type": "userUtterance", "id": "u1", "text": "hi"}))
        assert ws.receive_json()["code"] == "hello_required"


def test_device_change_pushes_an_ambient_event() -> None:
    scenario = Scenario.load("apartment")
    with _client().websocket_connect("/agent") as ws:
        _hello(ws)
        ws.send_text(json.dumps(
            {"type": "deviceStates", "devices": [d.model_dump() for d in scenario.devices]}
        ))

        after = [d.model_copy(deep=True) for d in scenario.devices]
        next(d for d in after if d.id == "sensor.doorbell").state["ringing"] = True
        ws.send_text(json.dumps(
            {"type": "deviceStates", "devices": [d.model_dump() for d in after]}
        ))

        event = ws.receive_json()
        assert event["type"] == "ambientEvent"
        assert event["kind"] == "doorbell"
        assert event["interrupt"] == "now"


def test_tool_call_is_fulfilled_by_the_client() -> None:
    adapter = EchoAdapter(scripted=[
        Chunk(tool_calls=[{"function": {"name": "set_light", "arguments": {
            "device_id": "light.desk", "on": True}}}]),
        Chunk(done=True),
    ])
    with TestClient(create_app(adapter)).websocket_connect("/agent") as ws:
        _hello(ws)
        ws.send_text(json.dumps({"type": "userUtterance", "id": "u1", "text": "desk lamp on"}))

        call = _drain_until(ws, "toolCall")[-1]
        assert call["executedBy"] == "client"
        ws.send_text(json.dumps({
            "type": "toolResult", "callId": call["callId"], "ok": True,
            "payload": {"id": "light.desk", "state": {"on": True}},
        }))
        _drain_until(ws, "utteranceEnd")


def test_server_side_execution_takes_only_a_confirmation() -> None:
    home = MockHome(Scenario.load("apartment").devices)
    adapter = EchoAdapter(scripted=[
        Chunk(tool_calls=[{"function": {"name": "set_lock", "arguments": {
            "device_id": "lock.front", "locked": False}}}]),
        Chunk(done=True),
    ])
    app = create_app(adapter, ServerExecutor(home, timeout=5.0))
    with TestClient(app).websocket_connect("/agent") as ws:
        _hello(ws)
        ws.send_text(json.dumps({"type": "userUtterance", "id": "u1", "text": "unlock the door"}))

        call = _drain_until(ws, "toolCall")[-1]
        assert call["executedBy"] == "server"
        assert call["safety"] == "unsafe"
        assert home.devices["lock.front"].state["locked"] is True  # not yet

        ws.send_text(json.dumps({
            "type": "confirmationResult", "callId": call["callId"], "approved": True,
        }))
        _drain_until(ws, "utteranceEnd")
        assert home.devices["lock.front"].state["locked"] is False

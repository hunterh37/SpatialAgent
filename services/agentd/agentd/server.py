"""WebSocket server. One persistent socket per headset; messages multiplexed by `type`."""

from __future__ import annotations

import json
import logging
import os

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from pydantic import ValidationError

from .adapters import EchoAdapter, ModelAdapter, OllamaAdapter
from .protocol import (
    PROTOCOL_VERSION,
    DeviceStates,
    Error,
    Hello,
    Ping,
    Pong,
    Ready,
    SceneUpdate,
    ServerEvent,
    ToolResult,
    UserUtterance,
    parse_client_message,
)
from .session import Session
from .tools import default_registry

log = logging.getLogger("agentd")


def build_adapter() -> ModelAdapter:
    backend = os.environ.get("AGENTD_BACKEND", "ollama")
    if backend == "echo":
        return EchoAdapter(delay=float(os.environ.get("AGENTD_ECHO_DELAY", "0.02")))
    return OllamaAdapter(
        model=os.environ.get("AGENTD_MODEL", "llama3.2"),
        base_url=os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434"),
    )


def create_app(adapter: ModelAdapter | None = None) -> FastAPI:
    app = FastAPI(title="agentd", version="0.1.0")
    adapter = adapter or build_adapter()
    tools = default_registry()

    @app.get("/health")
    async def health() -> dict[str, object]:
        return {"ok": True, "model": adapter.name, "protocolVersion": PROTOCOL_VERSION}

    @app.websocket("/agent")
    async def agent(ws: WebSocket) -> None:
        await ws.accept()
        session = Session(adapter, tools)
        log.info("session %s opened", session.id)

        async def send(event: ServerEvent) -> None:
            await ws.send_text(event.model_dump_json())

        try:
            while True:
                raw = await ws.receive_text()
                try:
                    message = parse_client_message(json.loads(raw))
                except (ValueError, ValidationError) as exc:
                    # Unknown types are ignored, not fatal: forward compatibility
                    # (spec/03-protocol.md).
                    log.warning("dropped message: %s", exc)
                    continue

                if isinstance(message, Hello):
                    if message.protocolVersion != PROTOCOL_VERSION:
                        await send(
                            Error(
                                code="protocol_version_mismatch",
                                message=(
                                    f"server speaks v{PROTOCOL_VERSION}, "
                                    f"client sent v{message.protocolVersion}"
                                ),
                            )
                        )
                        await ws.close(code=1002)
                        return
                    await send(Ready(sessionId=session.id, model=adapter.name))

                elif isinstance(message, SceneUpdate):
                    session.update_scene(message.scene)

                elif isinstance(message, DeviceStates):
                    session.update_devices(message.devices)

                elif isinstance(message, ToolResult):
                    session.resolve_tool_result(message)

                elif isinstance(message, Ping):
                    await send(Pong())

                elif isinstance(message, UserUtterance):
                    try:
                        async for event in session.handle_utterance(message.id, message.text):
                            await send(event)
                    except Exception as exc:  # surfaced in character, never a silent no-op
                        log.exception("utterance failed")
                        await send(Error(code="agent_error", message=str(exc)))

        except WebSocketDisconnect:
            log.info("session %s closed", session.id)




    return app

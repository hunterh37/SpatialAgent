"""WebSocket server. One persistent socket per headset; messages multiplexed by `type`.

Reads and writes run as separate tasks over one outbound queue, because the server has to be
able to speak unprompted: an ambient event arrives from the home, not from a request
(PRD 4). A read/reply loop structurally cannot do that.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from pydantic import ValidationError

from .adapters import EchoAdapter, ModelAdapter, OllamaAdapter, OpenAICompatAdapter
from .executors import ClientExecutor, ServerExecutor, ToolExecutor
from .profile import ProfileStore
from .protocol import (
    PROTOCOL_VERSION,
    ConfirmationResult,
    DeviceStates,
    Error,
    Hello,
    HomeDevices,
    Ping,
    Pong,
    Ready,
    SceneUpdate,
    ServerEvent,
    ToolResult,
    UserUtterance,
    parse_client_message,
)
from .session import Session, SessionStore
from .tools import default_registry

log = logging.getLogger("agentd")


# Small enough to sit in memory on a laptop and still call tools reliably. Anything
# smaller stops emitting well-formed tool calls, which is the floor for this project.
DEFAULT_MODEL = "llama3.2:3b"


def build_adapter() -> ModelAdapter:
    backend = os.environ.get("AGENTD_BACKEND", "ollama")
    if backend == "echo":
        return EchoAdapter(delay=float(os.environ.get("AGENTD_ECHO_DELAY", "0.02")))
    temperature = float(os.environ.get("AGENTD_TEMPERATURE", "0.2"))
    if backend in {"openai", "openai-compat", "llamacpp", "lmstudio", "vllm"}:
        return OpenAICompatAdapter(
            model=os.environ.get("AGENTD_MODEL", "local-model"),
            base_url=os.environ.get("OPENAI_BASE_URL", "http://127.0.0.1:1234/v1"),
            api_key=os.environ.get("OPENAI_API_KEY", "not-needed"),
            temperature=temperature,
        )
    return OllamaAdapter(
        model=os.environ.get("AGENTD_MODEL", DEFAULT_MODEL),
        base_url=os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434"),
        temperature=temperature,
    )


def build_executor() -> ToolExecutor:
    """`AGENTD_HOME=companion|mock` executes here; the default leaves execution to the client.

    HomeKit is absent from the visionOS SDK, so the shipping answer is a macOS companion
    plugged in here as another `HomeExecutor` (docs/middle-layer-todo.md 1).
    """
    mode = os.environ.get("AGENTD_HOME", "client")
    if mode == "companion":
        # The Mac app owns HomeKit authorization and the execution; this process owns the
        # decision. Plugged in here and nowhere else, which is what the executor boundary
        # bought (docs/middle-layer-todo.md 1).
        from .home import CompanionHome

        return ServerExecutor(
            CompanionHome(os.environ.get("AGENTD_COMPANION_URL", "http://127.0.0.1:8790"))
        )
    if mode == "mock":
        from mocks.mock_home import MockHome
        from mocks.scenario import Scenario

        scenario = Scenario.load(os.environ.get("AGENTD_SCENARIO", "apartment"))
        return ServerExecutor(MockHome(scenario.devices))
    return ClientExecutor()


def create_app(
    adapter: ModelAdapter | None = None,
    executor: ToolExecutor | None = None,
) -> FastAPI:
    app = FastAPI(title="agentd", version="0.2.0")
    adapter = adapter or build_adapter()
    executor = executor or build_executor()
    tools = default_registry()
    store = SessionStore()
    # One profile per machine, shared by every session. "Editable, portable, inspectable"
    # only means anything if there is one place to edit, export and inspect.
    profile = ProfileStore()
    app.state.sessions = store
    app.state.profile = profile

    @app.get("/health")
    async def health() -> dict[str, object]:
        return {
            "ok": True,
            "model": adapter.name,
            "protocolVersion": PROTOCOL_VERSION,
            "toolExecution": executor.location,
            "sessions": len(store),
            "facts": len(profile),
            "profilePath": str(profile.path),
        }

    # --- memory as a resource the user owns -------------------------------
    # The profile is reachable over plain HTTP, not only through the model, because a memory
    # you can only change by asking an agent nicely is not a memory you own. curl is a
    # first-class client here (README: Inspecting memory).

    @app.get("/memory")
    async def list_memory(q: str | None = None) -> dict[str, object]:
        facts = profile.search(q) if q else sorted(
            profile.facts, key=lambda f: f.updated_at, reverse=True
        )
        return {"count": len(profile), "facts": [f.to_dict() for f in facts]}

    @app.post("/memory")
    async def add_memory(body: dict) -> dict[str, object]:
        try:
            fact = profile.remember(
                text=str(body.get("text", "")),
                slot=str(body.get("slot") or "misc"),
                source=str(body.get("source") or "user"),
                place=body.get("place"),
            )
        except ValueError as exc:
            return {"ok": False, "error": str(exc)}
        return {"ok": True, "fact": fact.to_dict()}

    @app.patch("/memory/{fact_id}")
    async def edit_memory(fact_id: str, body: dict) -> dict[str, object]:
        fact = profile.update(fact_id, **body)
        return {"ok": fact is not None, "fact": fact.to_dict() if fact else None}

    @app.delete("/memory/{fact_id}")
    async def delete_memory(fact_id: str) -> dict[str, object]:
        fact = profile.forget(fact_id)
        return {"ok": fact is not None, "forgot": fact.text if fact else None}

    @app.delete("/memory")
    async def wipe_memory() -> dict[str, object]:
        return {"ok": True, "forgot": profile.wipe()}

    @app.get("/memory/export")
    async def export_memory() -> dict[str, object]:
        return profile.export()

    @app.post("/memory/import")
    async def import_memory(body: dict, replace: bool = False) -> dict[str, object]:
        return {"ok": True, "added": profile.import_facts(body, replace=replace)}

    @app.websocket("/agent")
    async def agent(ws: WebSocket) -> None:
        await ws.accept()
        outbound: asyncio.Queue[ServerEvent] = asyncio.Queue()
        session: Session | None = None

        async def writer() -> None:
            while True:
                event = await outbound.get()
                await ws.send_text(event.model_dump_json())

        writer_task = asyncio.create_task(writer())

        def emit(event: ServerEvent) -> None:
            outbound.put_nowait(event)

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
                        # Sent directly, not queued: the socket closes on the next line.
                        await ws.send_text(
                            Error(
                                code="protocol_version_mismatch",
                                message=(
                                    f"server speaks v{PROTOCOL_VERSION}, "
                                    f"client sent v{message.protocolVersion}"
                                ),
                            ).model_dump_json()
                        )
                        await ws.close(code=1002)
                        return

                    resumed = store.get(message.sessionId)
                    session = resumed or store.put(
                        Session(
                            adapter,
                            tools,
                            executor,
                            session_id=message.sessionId or None,
                            profile=profile,
                        )
                    )
                    session.touch()
                    log.info(
                        "session %s %s (%s)",
                        session.id,
                        "resumed" if resumed else "opened",
                        message.client,
                    )
                    emit(
                        Ready(
                            sessionId=session.id,
                            model=adapter.name,
                            capabilities=session.capabilities(),
                            resumed=resumed is not None,
                        )
                    )
                    # When this machine owns the home, the client has no device list of its
                    # own — it needs ours to name a device in a confirmation prompt.
                    owned = session.adopt_server_devices()
                    if owned:
                        emit(HomeDevices(devices=owned))
                    continue

                if isinstance(message, Ping):
                    # Keepalive is not conversation: it works before hello.
                    emit(Pong())
                    continue

                if session is None:
                    emit(Error(code="hello_required", message="send hello before anything else"))
                    continue

                # Timers are the one ambient source with no external trigger, so they are
                # checked wherever the loop is already awake.
                for fired in session.due_timers():
                    session.note_ambient(fired)
                    emit(fired)

                if isinstance(message, SceneUpdate):
                    session.update_scene(message.scene)

                elif isinstance(message, DeviceStates):
                    for event in session.update_devices(message.devices):
                        session.note_ambient(event)
                        emit(event)

                elif isinstance(message, ToolResult):
                    if not session.resolve_tool_result(message):
                        log.warning("toolResult for unknown call %s", message.callId)

                elif isinstance(message, ConfirmationResult):
                    if not session.resolve_confirmation(message.callId, message.approved):
                        log.warning("confirmation for unknown call %s", message.callId)

                elif isinstance(message, UserUtterance):
                    # A turn runs concurrently with reading, so a toolResult or a
                    # confirmation sent mid-turn can actually arrive.
                    asyncio.create_task(_run_turn(session, message, emit))

        except WebSocketDisconnect:
            if session is not None:
                log.info("session %s socket closed (state kept for resume)", session.id)
        finally:
            writer_task.cancel()
            if session is not None:
                session.pending.cancel_all()

    return app


async def _run_turn(session: Session, message: UserUtterance, emit) -> None:
    try:
        async for event in session.handle_utterance(message.id, message.text, message.isFinal):
            emit(event)
    except asyncio.CancelledError:
        raise
    except Exception as exc:  # surfaced in character, never a silent no-op
        log.exception("utterance failed")
        emit(Error(code="agent_error", message=str(exc)))

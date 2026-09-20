"""Adapters are the only place that knows what a model is. Both real ones parse streams."""

from __future__ import annotations

import json

import httpx
import pytest

from agentd.adapters import Chunk, EchoAdapter, OllamaAdapter, OpenAICompatAdapter


def _transport(lines: list[str]) -> httpx.MockTransport:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content="\n".join(lines).encode())

    return httpx.MockTransport(handler)


async def _collect(adapter, monkeypatch, lines: list[str]) -> list[Chunk]:
    transport = _transport(lines)
    original = httpx.AsyncClient

    def patched(*args, **kwargs):
        kwargs["transport"] = transport
        return original(*args, **kwargs)

    monkeypatch.setattr(httpx, "AsyncClient", patched)
    return [chunk async for chunk in adapter.stream([{"role": "user", "content": "hi"}])]


async def test_echo_scripted_run_is_one_shot() -> None:
    adapter = EchoAdapter(scripted=[Chunk(text="once")])
    first = [c async for c in adapter.stream([])]
    second = [c async for c in adapter.stream([])]
    assert [c.text for c in first] == ["once"]
    assert second == []


async def test_ollama_stream_yields_text_and_done(monkeypatch: pytest.MonkeyPatch) -> None:
    lines = [
        json.dumps({"message": {"content": "On "}, "done": False}),
        json.dumps({"message": {"content": "it."}, "done": True}),
    ]
    chunks = await _collect(OllamaAdapter(model="test"), monkeypatch, lines)
    assert "".join(c.text for c in chunks) == "On it."
    assert chunks[-1].done


async def test_openai_compat_reassembles_split_tool_calls(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Arguments arrive in fragments; a half-parsed call would be a hallucinated action."""
    lines = [
        'data: ' + json.dumps({"choices": [{"delta": {"tool_calls": [
            {"index": 0, "function": {"name": "set_", "arguments": '{"device_id"'}}]}}]}),
        'data: ' + json.dumps({"choices": [{"delta": {"tool_calls": [
            {"index": 0, "function": {"name": "light", "arguments": ': "light.desk"}'}}]}}]}),
        'data: ' + json.dumps({"choices": [{"delta": {}, "finish_reason": "tool_calls"}]}),
        "data: [DONE]",
    ]
    chunks = await _collect(OpenAICompatAdapter(model="test"), monkeypatch, lines)
    calls = [c for chunk in chunks for c in chunk.tool_calls]
    assert len(calls) == 1
    assert calls[0]["function"]["name"] == "set_light"
    assert json.loads(calls[0]["function"]["arguments"]) == {"device_id": "light.desk"}


async def test_openai_compat_streams_text(monkeypatch: pytest.MonkeyPatch) -> None:
    lines = [
        'data: ' + json.dumps({"choices": [{"delta": {"content": "On "}}]}),
        'data: ' + json.dumps({"choices": [{"delta": {"content": "it."},
                                            "finish_reason": "stop"}]}),
        "data: [DONE]",
    ]
    chunks = await _collect(OpenAICompatAdapter(model="test"), monkeypatch, lines)
    assert "".join(c.text for c in chunks) == "On it."


async def test_ollama_asks_for_low_temperature(monkeypatch: pytest.MonkeyPatch) -> None:
    """A controller that samples creatively describes the action instead of calling it."""
    sent: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        sent.update(json.loads(request.content))
        return httpx.Response(200, content=json.dumps({"message": {"content": "ok"},
                                                       "done": True}).encode())

    transport = httpx.MockTransport(handler)
    original = httpx.AsyncClient
    monkeypatch.setattr(
        httpx, "AsyncClient", lambda *a, **k: original(*a, **{**k, "transport": transport})
    )
    adapter = OllamaAdapter(model="test")
    _ = [c async for c in adapter.stream([{"role": "user", "content": "hi"}])]
    assert sent["options"]["temperature"] == 0.2

"""OpenAI-compatible /v1/chat/completions adapter.

Covers llama.cpp's server, LM Studio, vLLM and text-generation-webui, which all speak this
shape. Having a second real backend is the proof that the boundary in adapters/base.py
actually holds: the headset never learns which model is running (docs/architecture.md 2d).
"""

from __future__ import annotations

import json
from collections.abc import AsyncIterator
from typing import Any

import httpx

from .base import Chunk


class OpenAICompatAdapter:
    name = "openai-compat"

    def __init__(
        self,
        model: str = "local-model",
        base_url: str = "http://127.0.0.1:1234/v1",
        api_key: str = "not-needed",
        timeout: float = 120.0,
    ) -> None:
        self.model = model
        self.name = f"openai-compat/{model}"
        self._base_url = base_url.rstrip("/")
        self._api_key = api_key
        self._timeout = timeout

    async def stream(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
    ) -> AsyncIterator[Chunk]:
        body: dict[str, Any] = {
            "model": self.model,
            "messages": [_sanitize(m) for m in messages],
            "stream": True,
        }
        if tools:
            body["tools"] = tools

        headers = {"Authorization": f"Bearer {self._api_key}"}
        # Tool calls arrive in fragments across deltas and are only complete at the end.
        partial: dict[int, dict[str, Any]] = {}

        async with (
            httpx.AsyncClient(timeout=self._timeout) as client,
            client.stream(
                "POST", f"{self._base_url}/chat/completions", json=body, headers=headers
            ) as resp,
        ):
            resp.raise_for_status()
            async for line in resp.aiter_lines():
                if not line.startswith("data:"):
                    continue
                data = line.removeprefix("data:").strip()
                if data in {"", "[DONE]"}:
                    continue

                choice = (json.loads(data).get("choices") or [{}])[0]
                delta = choice.get("delta") or {}

                for fragment in delta.get("tool_calls") or []:
                    slot = partial.setdefault(
                        fragment.get("index", 0), {"function": {"name": "", "arguments": ""}}
                    )
                    fn = fragment.get("function") or {}
                    slot["function"]["name"] += fn.get("name") or ""
                    slot["function"]["arguments"] += fn.get("arguments") or ""

                text = delta.get("content") or ""
                finished = choice.get("finish_reason") is not None
                calls = list(partial.values()) if finished else []
                if finished:
                    partial = {}

                if text or calls or finished:
                    yield Chunk(text=text, tool_calls=calls, done=finished)


def _sanitize(message: dict[str, Any]) -> dict[str, Any]:
    """Our transcript carries `name` on tool messages; keep only what the API accepts."""
    allowed = {"role", "content", "name", "tool_calls", "tool_call_id"}
    return {k: v for k, v in message.items() if k in allowed}

"""Ollama adapter. Streams /api/chat so the character reacts on first token, not last."""

from __future__ import annotations

import json
from collections.abc import AsyncIterator
from typing import Any

import httpx

from .base import Chunk


class OllamaAdapter:
    name = "ollama"

    def __init__(
        self,
        model: str = "llama3.2",
        base_url: str = "http://127.0.0.1:11434",
        timeout: float = 120.0,
    ) -> None:
        self.model = model
        self.name = f"ollama/{model}"
        self._base_url = base_url.rstrip("/")
        self._timeout = timeout

    async def stream(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
    ) -> AsyncIterator[Chunk]:
        body: dict[str, Any] = {"model": self.model, "messages": messages, "stream": True}
        if tools:
            body["tools"] = tools

        async with httpx.AsyncClient(timeout=self._timeout) as client:
            async with client.stream("POST", f"{self._base_url}/api/chat", json=body) as resp:
                resp.raise_for_status()
                async for line in resp.aiter_lines():
                    if not line.strip():
                        continue
                    payload = json.loads(line)
                    message = payload.get("message") or {}
                    yield Chunk(
                        text=message.get("content", ""),
                        tool_calls=message.get("tool_calls", []) or [],
                        done=bool(payload.get("done")),
                    )

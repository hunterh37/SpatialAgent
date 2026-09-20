"""Deterministic adapter. No model, no network — the substrate for CI and mocks."""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from typing import Any

from .base import Chunk


class EchoAdapter:
    name = "echo"

    def __init__(self, delay: float = 0.0, scripted: list[Chunk] | None = None) -> None:
        self._delay = delay
        self._scripted = scripted

    async def stream(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
    ) -> AsyncIterator[Chunk]:
        if self._scripted is not None:
            for chunk in self._scripted:
                if self._delay:
                    await asyncio.sleep(self._delay)
                yield chunk
            return

        last = next(
            (m["content"] for m in reversed(messages) if m.get("role") == "user"),
            "",
        )
        for word in f"echo: {last}".split():
            if self._delay:
                await asyncio.sleep(self._delay)
            yield Chunk(text=word + " ")
        yield Chunk(done=True)

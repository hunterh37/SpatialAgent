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
            # One-shot. A second round (after a tool result) gets nothing further to say,
            # which is what ends the loop rather than replaying the same tool call forever.
            scripted, self._scripted = self._scripted, []
            for chunk in scripted:
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

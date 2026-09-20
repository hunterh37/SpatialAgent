"""Model adapter boundary.

The headset never learns which model is running. Swapping Ollama for vLLM or llama.cpp
touches this package only (docs/architecture.md 2d).
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from typing import Any, Protocol


@dataclass
class Chunk:
    """One streamed unit from a model: text, or a tool call, or both."""

    text: str = ""
    tool_calls: list[dict[str, Any]] = field(default_factory=list)
    done: bool = False


class ModelAdapter(Protocol):
    name: str

    def stream(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
    ) -> AsyncIterator[Chunk]: ...

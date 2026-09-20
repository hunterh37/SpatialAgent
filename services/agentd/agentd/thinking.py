"""Strip reasoning traces out of the spoken stream.

Small reasoning models (qwen3 and friends) inline a `<think>...</think>` block before the
answer. Ollama exposes it separately in some versions and inside `content` in others, and
the character must never say its own scratchpad out loud. This filter runs over the token
stream, so it has to work on fragments that split a tag in half.
"""

from __future__ import annotations

OPEN = "<think>"
CLOSE = "</think>"
# The longest prefix of either tag that a fragment might end on.
_HOLD = max(len(OPEN), len(CLOSE)) - 1


class ThinkingFilter:
    """Feed it streamed fragments, get back only what the character should say."""

    def __init__(self) -> None:
        self._buffer = ""
        self._inside = False

    def feed(self, text: str) -> str:
        self._buffer += text
        out: list[str] = []

        while self._buffer:
            if self._inside:
                index = self._buffer.find(CLOSE)
                if index == -1:
                    self._buffer = self._keep_tail(CLOSE)
                    break
                self._buffer = self._buffer[index + len(CLOSE) :]
                self._inside = False
                continue

            index = self._buffer.find(OPEN)
            if index == -1:
                emit = self._buffer
                self._buffer = self._keep_tail(OPEN)
                emit = emit[: len(emit) - len(self._buffer)]
                if emit:
                    out.append(emit)
                break

            if index:
                out.append(self._buffer[:index])
            self._buffer = self._buffer[index + len(OPEN) :]
            self._inside = True

        return "".join(out)

    def flush(self) -> str:
        """Whatever is left once the stream ends; a partial tag was never a tag."""
        rest = "" if self._inside else self._buffer
        self._buffer = ""
        self._inside = False
        return rest

    def _keep_tail(self, tag: str) -> str:
        """Hold back the bytes that could still turn out to be the start of `tag`."""
        for size in range(min(_HOLD, len(self._buffer)), 0, -1):
            if tag.startswith(self._buffer[-size:]):
                return self._buffer[-size:]
        return ""

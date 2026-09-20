"""The character must never say its own scratchpad out loud."""

from __future__ import annotations

from agentd.thinking import ThinkingFilter


def _stream(fragments: list[str]) -> str:
    f = ThinkingFilter()
    return "".join(f.feed(x) for x in fragments) + f.flush()


def test_whole_block_is_removed() -> None:
    assert _stream(["<think>weighing options</think>On it."]) == "On it."


def test_tag_split_across_fragments() -> None:
    assert _stream(["<th", "ink>hmm</thi", "nk>", "Done."]) == "Done."


def test_text_without_tags_passes_through_unchanged() -> None:
    assert _stream(["Heading ", "to the ", "kitchen."]) == "Heading to the kitchen."


def test_unterminated_block_is_never_spoken() -> None:
    assert _stream(["<think>still reasoning when the stream died"]) == ""


def test_a_lone_angle_bracket_is_not_a_tag() -> None:
    assert _stream(["1 < 2 and 3 > 2"]) == "1 < 2 and 3 > 2"


def test_text_around_a_block_survives() -> None:
    assert _stream(["Sure. <think>x</think>Kitchen light is off."]) == (
        "Sure. Kitchen light is off."
    )

"""The corpus must stay complete, valid, and committed.

Swift decodes this file (packages/Tests/AgentProtocolTests/ConformanceTests.swift). If it
drifts from what the server really emits, the Swift side is testing a fiction.
"""

from __future__ import annotations

import json
from pathlib import Path

import jsonschema
import pytest

from agentd.conformance import CORPUS_PATH, build, client_messages, server_events
from agentd.protocol import _CLIENT_TYPES, parse_client_message

SCHEMA_PATH = (
    Path(__file__).parents[3] / "packages" / "AgentProtocol" / "schema" / "protocol.schema.json"
)


@pytest.fixture(scope="module")
def schema() -> dict:
    return json.loads(SCHEMA_PATH.read_text())


def test_committed_corpus_is_current() -> None:
    """`make protocol` regenerates it; CI fails if someone skipped that step."""
    assert CORPUS_PATH.exists(), "run: python -m agentd.conformance"
    on_disk = json.loads(CORPUS_PATH.read_text())
    assert on_disk == build(), "corpus is stale — run `make protocol`"


def test_every_client_message_type_has_an_example() -> None:
    covered = {m.type for m in client_messages()}
    assert covered == set(_CLIENT_TYPES)


def test_every_server_event_type_has_an_example(schema: dict) -> None:
    declared = set(schema["definitions"]["ServerEvent"]["properties"]["type"]["enum"])
    assert {e.type for e in server_events()} == declared


def test_every_directive_kind_has_an_example(schema: dict) -> None:
    kinds = {
        e.directive.kind for e in server_events() if e.type == "characterDirective"
    }
    assert kinds == set(schema["definitions"]["DirectiveKind"]["enum"])


def test_corpus_validates_against_the_schema(schema: dict) -> None:
    corpus = build()
    for definition, entries in (
        ("ClientMessage", corpus["clientMessages"]),
        ("ServerEvent", corpus["serverEvents"]),
    ):
        for entry in entries:
            jsonschema.validate(entry, {**schema, "$ref": f"#/definitions/{definition}"})


def test_python_parses_every_client_message_in_the_corpus() -> None:
    """The corpus is what Swift will send back; the socket boundary must accept all of it."""
    for entry in build()["clientMessages"]:
        parsed = parse_client_message(entry)
        assert parsed.type == entry["type"]

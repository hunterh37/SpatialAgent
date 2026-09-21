"""Durable user profile: the half of memory the room cannot hold.

The semantic map on the headset remembers *where* things are. Nothing remembered *who the
user is* — that lived in `Session.history` and died with the process (spec/07-memory.md
Persistence). This store is the other half: facts about the person, written to one JSON file
the user can open, edit in a text editor, delete a line from, or hand to another agent.

Three properties are deliberate, and they are the hackathon claim:
- **Inspectable.** One file, one flat list, plain English `text`. No embeddings, no opaque
  blob. `GET /memory` returns exactly what the model is told.
- **Editable.** Every fact has a stable id; `update` and `forget` are ordinary operations,
  exposed as tools to the model *and* as HTTP to the user. Forgetting is not a special case.
- **Portable.** `export()`/`import_facts()` round-trip the whole profile as JSON, so the
  profile is the user's and not the app's.

Coordinates never appear here, same as everywhere else on the server: a fact is a sentence
and at most the *name* of a place it is about.
"""

from __future__ import annotations

import json
import os
import re
import time
import uuid
from collections.abc import Iterable
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1

#: Slots exist so the curiosity engine can tell "asked and answered" from "never asked", and
#: so a digest can be grouped into something a small model reads without drowning. They are a
#: soft vocabulary: `remember_about_user` accepts any slot, and unknown ones sort last.
SLOTS: tuple[str, ...] = (
    "identity",      # name, pronouns, what they do
    "routine",       # when they work, sleep, eat
    "preference",    # likes, dislikes, how they want the bird to behave
    "diet",          # food and drink, allergies
    "people",        # who else is in the home
    "place_meaning", # what a taught place means to them
    "project",       # what they are working on
    "boundary",      # what the bird must not do
    "misc",
)

def default_path() -> Path:
    """Read at construction, not at import, so a test (or a second demo persona) can point
    `AGENTD_PROFILE` somewhere else without having imported this module too early."""
    return Path(
        os.environ.get("AGENTD_PROFILE", Path.home() / ".spatialagent" / "profile.json")
    )


def _now() -> float:
    return time.time()


@dataclass
class Fact:
    """One remembered thing, in the user's own words where possible.

    `source` is provenance, not decoration: a fact the user stated outright and a fact the
    bird inferred from a device event are not equally trustworthy, and the user deserves to
    see which is which when they open the file.
    """

    text: str
    slot: str = "misc"
    id: str = field(default_factory=lambda: uuid.uuid4().hex[:10])
    source: str = "user"           # user | inferred | seed
    confidence: float = 1.0
    place: str | None = None       # the *name* of a place this is about, never a position
    created_at: float = field(default_factory=_now)
    updated_at: float = field(default_factory=_now)
    used_at: float | None = None
    uses: int = 0
    question: str | None = None    # the curiosity question this answered, if any

    def as_line(self) -> str:
        """How the model sees it. Short, because it is one of many in a system prompt."""
        suffix = f" (about the {self.place})" if self.place else ""
        return f"{self.text}{suffix}"

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> Fact:
        known = {k: v for k, v in raw.items() if k in cls.__dataclass_fields__}
        text = str(known.pop("text", "")).strip()
        if not text:
            raise ValueError("a fact with no text is not a fact")
        return cls(text=text, **known)


def normalize(text: str) -> str:
    return re.sub(r"[^a-z0-9 ]+", "", str(text or "").lower()).strip()


class ProfileStore:
    """The profile, on disk, loaded once and written on every change.

    Writes are synchronous and whole-file. The profile is tens of facts, not thousands, and
    a hackathon demo that loses the last thing the user taught because a write was batched is
    worse than any amount of write amplification. The write is atomic (temp + replace) so a
    crash mid-demo cannot leave a half-written file behind.
    """

    def __init__(self, path: Path | str | None = None, autosave: bool = True) -> None:
        self.path = Path(path) if path is not None else default_path()
        self.autosave = autosave
        self.facts: list[Fact] = []
        self.asked: dict[str, float] = {}  # question key -> when it was last asked
        self.load()

    # --- disk -------------------------------------------------------------

    def load(self) -> None:
        if not self.path.exists():
            return
        try:
            raw = json.loads(self.path.read_text())
        except (json.JSONDecodeError, OSError):
            # A corrupt profile is not a reason to refuse to run. It is renamed rather than
            # deleted, because it is the user's data and may be recoverable by hand.
            try:
                self.path.replace(self.path.with_suffix(".corrupt.json"))
            except OSError:
                pass
            return
        self.facts = []
        for item in raw.get("facts", []):
            try:
                self.facts.append(Fact.from_dict(item))
            except (ValueError, TypeError):
                continue
        asked = raw.get("asked")
        self.asked = {str(k): float(v) for k, v in asked.items()} if isinstance(asked, dict) else {}

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "schema": SCHEMA_VERSION,
            "savedAt": _now(),
            "facts": [f.to_dict() for f in self.facts],
            "asked": self.asked,
        }
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, indent=2, sort_keys=False))
        tmp.replace(self.path)

    def _touch_disk(self) -> None:
        if self.autosave:
            self.save()

    # --- crud -------------------------------------------------------------

    def remember(
        self,
        text: str,
        slot: str = "misc",
        source: str = "user",
        place: str | None = None,
        confidence: float = 1.0,
        question: str | None = None,
    ) -> Fact:
        """Add a fact, or refresh the one that already says this.

        Dedup is on normalized text rather than an id, because a small model asked to
        remember the same thing twice generates two ids for one fact and the user then sees
        their profile fill with duplicates of "I drink oat milk".
        """
        text = str(text or "").strip().rstrip(".").strip()
        if not text:
            raise ValueError("nothing to remember")
        key = normalize(text)
        for existing in self.facts:
            if normalize(existing.text) == key:
                existing.updated_at = _now()
                existing.confidence = max(existing.confidence, confidence)
                if place:
                    existing.place = place
                self._touch_disk()
                return existing
        fact = Fact(
            text=text,
            slot=slot if slot in SLOTS else "misc",
            source=source,
            place=place,
            confidence=confidence,
            question=question,
        )
        self.facts.append(fact)
        self._touch_disk()
        return fact

    def get(self, fact_id: str) -> Fact | None:
        return next((f for f in self.facts if f.id == fact_id), None)

    def update(self, fact_id: str, **changes: Any) -> Fact | None:
        """Correct a fact in place, keeping its id so a correction is not a new memory."""
        fact = self.get(fact_id)
        if fact is None:
            return None
        for key in ("text", "slot", "place", "source", "confidence"):
            if key in changes and changes[key] is not None:
                setattr(fact, key, changes[key])
        fact.updated_at = _now()
        self._touch_disk()
        return fact

    def forget(self, fact_id: str) -> Fact | None:
        fact = self.get(fact_id)
        if fact is None:
            return None
        self.facts.remove(fact)
        self._touch_disk()
        return fact

    def forget_matching(self, query: str) -> list[Fact]:
        """Forget by description, because the user says "forget the coffee thing", not an id."""
        hits = self.search(query)
        for fact in hits:
            if fact in self.facts:
                self.facts.remove(fact)
        if hits:
            self._touch_disk()
        return hits

    def wipe(self) -> int:
        count = len(self.facts)
        self.facts = []
        self.asked = {}
        self._touch_disk()
        return count

    # --- reading ----------------------------------------------------------

    def search(self, query: str, limit: int = 8) -> list[Fact]:
        """Token-overlap search. Deliberately dumb and deliberately explainable.

        An embedding index would rank better and would make "why did it remember that?"
        unanswerable. Ranking is: shared words first, then slot-name match, then recency.
        """
        terms = [t for t in normalize(query).split() if len(t) > 2]
        if not terms:
            return sorted(self.facts, key=lambda f: f.updated_at, reverse=True)[:limit]
        scored: list[tuple[float, Fact]] = []
        for fact in self.facts:
            words = set(normalize(fact.text).split())
            overlap = sum(1 for t in terms if t in words)
            if fact.slot in terms or (fact.place and normalize(fact.place) in normalize(query)):
                overlap += 1
            if overlap:
                scored.append((overlap + fact.updated_at / 1e12, fact))
        scored.sort(key=lambda pair: pair[0], reverse=True)
        hits = [f for _, f in scored[:limit]]
        self.mark_used(hits)
        return hits

    def by_slot(self, slot: str) -> list[Fact]:
        return [f for f in self.facts if f.slot == slot]

    def mark_used(self, facts: Iterable[Fact]) -> None:
        """Usage is recorded so the user can see which memories actually do anything.

        A fact never recalled in a month is a fact worth offering to delete; that is only
        visible if recall leaves a trace.
        """
        stamp = _now()
        touched = False
        for fact in facts:
            fact.used_at = stamp
            fact.uses += 1
            touched = True
        if touched:
            self._touch_disk()

    def digest(self, limit: int = 24) -> str:
        """The profile as the system prompt sees it: grouped, capped, newest first.

        Capped because everything in here competes with the room description for a 3B
        model's attention, and an unbounded profile silently pushes the device list out.
        """
        if not self.facts:
            return ""
        ordered = sorted(self.facts, key=lambda f: f.updated_at, reverse=True)[:limit]
        groups: dict[str, list[Fact]] = {}
        for fact in ordered:
            groups.setdefault(fact.slot, []).append(fact)
        lines: list[str] = []
        for slot in SLOTS:
            if slot not in groups:
                continue
            lines.append(f"{slot}:")
            lines.extend(f"  - {f.as_line()}" for f in groups[slot])
        for slot, items in groups.items():
            if slot in SLOTS:
                continue
            lines.append(f"{slot}:")
            lines.extend(f"  - {f.as_line()}" for f in items)
        return "\n".join(lines)

    # --- portability ------------------------------------------------------

    def export(self) -> dict[str, Any]:
        return {
            "schema": SCHEMA_VERSION,
            "exportedAt": _now(),
            "facts": [f.to_dict() for f in self.facts],
            "asked": self.asked,
        }

    def import_facts(self, payload: dict[str, Any], replace: bool = False) -> int:
        """Merge (or replace with) another profile. Ids survive so a round-trip is lossless."""
        if replace:
            self.facts = []
            self.asked = {}
        added = 0
        for item in payload.get("facts", []) or []:
            try:
                fact = Fact.from_dict(item)
            except (ValueError, TypeError):
                continue
            if any(normalize(f.text) == normalize(fact.text) for f in self.facts):
                continue
            self.facts.append(fact)
            added += 1
        asked = payload.get("asked")
        if isinstance(asked, dict):
            self.asked.update({str(k): float(v) for k, v in asked.items()})
        self._touch_disk()
        return added

    # --- curiosity bookkeeping -------------------------------------------

    def note_asked(self, key: str) -> None:
        self.asked[key] = _now()
        self._touch_disk()

    def was_asked(self, key: str) -> bool:
        return key in self.asked

    def answered_keys(self) -> set[str]:
        return {f.question for f in self.facts if f.question}

    def __len__(self) -> int:
        return len(self.facts)

"""The endless question engine: how the profile fills itself.

A memory system the user has to seed by hand is a memory system nobody seeds. The bird earns
its profile by asking — but an agent that asks whenever it can is an interrogation, so the
rules here are mostly rules about *not* asking (spec/07-memory.md Curiosity):

- One open question at a time, and never while the user is mid-task.
- A question is asked once. Asked-and-ignored counts as asked; the bank is large enough that
  re-asking is never necessary.
- Room questions beat generic ones, because "what do you do at the desk?" is a question only
  an agent standing in your room could ask, and that is the whole product.
- The bank is not a fixed list: `SEEDS` is a template set, and every taught place generates
  its own questions, so the supply grows as the room does.

`CuriosityPlanner` in Swift owns the *budget* on the client (how often the bird may speak
unprompted). This owns *what to ask* and the record of what has been asked.
"""

from __future__ import annotations

import time
from dataclasses import dataclass

from .profile import ProfileStore
from .protocol import SceneSnapshot


@dataclass(frozen=True)
class Question:
    """`key` is the dedup identity, not the text: rephrasing must not re-ask."""

    key: str
    text: str
    slot: str
    place: str | None = None


#: Generic questions, ordered roughly by how natural they are to ask early. `slot` decides
#: where the answer lands in the profile, which is what makes the answer usable later.
SEEDS: tuple[Question, ...] = (
    Question("name", "What should I call you?", "identity"),
    Question("work", "What do you do most days?", "identity"),
    Question("wake", "When does your day usually start?", "routine"),
    Question("focus", "When are you heads-down and not to be interrupted?", "boundary"),
    Question("drink", "What do you drink in the morning?", "diet"),
    Question("food_avoid", "Anything you don't eat?", "diet"),
    Question("household", "Is it just you here, or do you share the place?", "people"),
    Question("pets", "Any pets I should know about?", "people"),
    Question("music", "What do you put on while you work?", "preference"),
    Question("noise", "Do you want me chatty, or quiet unless you ask?", "preference"),
    Question("project", "What are you working on right now?", "project"),
    Question("lighting", "How do you like the lights in the evening?", "preference"),
    Question("weekend", "Do weekends look different from weekdays for you?", "routine"),
    Question("sleep", "When do you usually wind down?", "routine"),
    Question("guests", "Does anyone else come by often?", "people"),
    Question("perch_pref", "Where would you rather I wait when you're busy?", "preference"),
)

#: One template per taught place, filled in with the name the user chose. This is where the
#: supply becomes endless: every landmark placed in the setup flow adds questions.
PLACE_TEMPLATES: tuple[tuple[str, str, str], ...] = (
    ("use", "What do you use the {place} for?", "place_meaning"),
    ("when", "When are you usually at the {place}?", "routine"),
    ("care", "Is there anything at the {place} I should stay off?", "boundary"),
)

#: The user gets 30s of silence after speaking before an unprompted question is allowed; a
#: question that lands on top of the user's own sentence reads as not listening.
MIN_QUIET = 30.0
#: And a floor between questions, so a quiet user is not drained of answers in one minute.
MIN_GAP = 120.0


class Curiosity:
    def __init__(self, profile: ProfileStore, min_gap: float = MIN_GAP) -> None:
        self.profile = profile
        self.min_gap = min_gap
        self._last_asked = 0.0
        self._open: Question | None = None

    # --- supply -----------------------------------------------------------

    def bank(self, scene: SceneSnapshot | None = None) -> list[Question]:
        """Every question that could be asked right now, room questions first."""
        out: list[Question] = []
        for place in (scene.places if scene else []):
            for suffix, template, slot in PLACE_TEMPLATES:
                out.append(
                    Question(
                        key=f"place:{place.name.lower()}:{suffix}",
                        text=template.format(place=place.name),
                        slot=slot,
                        place=place.name,
                    )
                )
        out.extend(SEEDS)
        return out

    def remaining(self, scene: SceneSnapshot | None = None) -> list[Question]:
        answered = self.profile.answered_keys()
        return [
            q
            for q in self.bank(scene)
            if q.key not in answered and not self.profile.was_asked(q.key)
        ]

    # --- demand -----------------------------------------------------------

    def next_question(
        self, scene: SceneSnapshot | None = None, quiet_for: float | None = None, force: bool = False
    ) -> Question | None:
        """The question to ask, or None if now is not the time.

        `force` is the user asking outright ("ask me something"), which bypasses the pacing
        but never the asked-once rule: being invited to ask is not permission to repeat.
        """
        if self._open is not None and not force:
            return None
        now = time.monotonic()
        if not force:
            if quiet_for is not None and quiet_for < MIN_QUIET:
                return None
            if now - self._last_asked < self.min_gap:
                return None
        pending = self.remaining(scene)
        if not pending:
            return None
        question = pending[0]
        self._open = question
        self._last_asked = now
        self.profile.note_asked(question.key)
        return question

    def answer(self, text: str, question: Question | None = None) -> str | None:
        """Bank an answer against the open question. Returns the new fact id, if any.

        The answer is stored as a sentence rather than a key/value pair because the model
        reads it back as prose and because the user reading `profile.json` should see
        something they recognise saying.
        """
        target = question or self._open
        if target is None:
            return None
        text = str(text or "").strip()
        self._open = None
        if not text:
            return None
        fact = self.profile.remember(
            text=text,
            slot=target.slot,
            source="user",
            place=target.place,
            question=target.key,
        )
        return fact.id

    def drop(self) -> None:
        """The user changed the subject. The question stays asked; it is not re-asked."""
        self._open = None

    @property
    def open_question(self) -> Question | None:
        return self._open


#: Appended to the system prompt whenever a profile exists or could exist.
CURIOSITY_PROMPT = """\
You keep a memory of the user across sessions. Use these tools, never prose, to change it:
- remember_about_user(text, slot) when they tell you something true about themselves, their \
routine, their preferences or their boundaries. Store it as a short sentence in their words.
- recall_about_user(query) before answering anything about what you know, like them, or \
their habits. Never guess at a memory; look it up.
- forget_about_user(query) when they ask you to forget something. Say what you dropped.
- update_about_user(fact_id, text) when they correct something you already remember. \
Correcting is not the same as remembering a second, contradictory thing.
- ask_about_user() when there is a lull and you want to know them better. It picks the \
question; ask exactly the question it gives you, once, and then bank the answer with \
remember_about_user. Never ask two questions in a row."""

# Spec 02 — Interaction

## Addressing
v0.1: text field. v0.2+: gaze at the character plus speech. The character must show it is
being addressed *before* the utterance ends — it turns on gaze acquisition, not on parse.

## Response rendering
Tokens stream into a speech bubble anchored above the character, billboarded to the user,
never occluded by the character itself. The bubble appears on first token. If no token
arrives within 1.5s, the character stays in `thinking` and the bubble shows motion — it never
shows an empty box.

## Ambiguity
When a request is under-specified, the character asks a single, short clarifying question
from where it stands. It does not walk first and ask later, and it does not guess on an
action that changes device state.

## Confirmation
Any tool classified `unsafe` (spec 04) routes through a confirmation ornament: the action in
plain language, the target device, Confirm and Cancel. It is modal to the action, not to the
app — the user can keep talking. Default is Cancel. Timeout cancels.

Confirmation is never skippable by a setting, a phrase, or a "trust this agent" toggle.

## Failure
Every failure is spoken in character and leaves the system recoverable by talking. No error
dialogs, no codes, no silent no-ops. A disconnected server is stated plainly ("I can't reach
the Mac") rather than manifesting as a frozen character.

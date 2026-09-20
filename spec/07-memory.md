# Spec 07 — Semantic map, teaching, and learned behavior

The map is the product (PRD §5). This document defines what is stored, how it is taught, how
it is enforced, and how it changes behavior.

## Model

One store, five layers over a geometric base. Everything but geometry is user-authored.

```
Geometry     floor planes, obstacles, reachable surface        from ARKit, no semantics
Place        name, anchor, radius, kind                        "my workspace"
Object       name, point, optional deviceId, optional place    "the coffee machine"
Rule         region, kind, severity                            "don't go here"
Activity     name, place, observed time-of-day bands           "where I brainstorm"
Episode      timestamp, place, kind, summary                   append-only history
```

Identity: a stable UUID plus a lowercased name key. Name collisions are a correction, not a
second record — teaching a name that already exists updates the existing record and the bird
says so.

Anchoring: every spatial record holds a `WorldTrackingProvider` anchor UUID plus a cached
transform. The anchor is authoritative; the cached transform is what makes the map usable
before relocalization completes. A record whose anchor never relocalizes is shown as
"somewhere in this room" and is not navigable.

## Rules

`Rule.kind` is a closed set, because each one is code, not prompt text:

`forbidden` — subtracted from the navmesh. The bird cannot path into it or be placed in it.
Enforced geometrically, so a model that decides to go there simply gets no path.
`quiet` — suppresses ambient speech and curiosity questions while the user is inside it.
`perch` — a preferred resting spot; raises idle-settle weight nearby.
`fragile` — allowed to path near, never to land on or gesture at. A softer `forbidden`.

Severity is `hard` or `soft`. Hard rules are geometric constraints. Soft rules are behavior
weights. A rule taught with "don't" is always hard. This distinction is stated to the user in
plain language on capture: "I won't go there at all" vs "I'll keep out of the way."

## Teaching

Five acts. All are one sentence, all are gaze-plus-speech, all produce visible acknowledgement
from the bird within 400ms.

| Act | Utterance shape | Result |
|---|---|---|
| Name a place | "this is my workspace" | `Place` at the gaze hit, radius from surface extent |
| Name an object | "this is the coffee machine" | `Object` at the gaze hit, device binding offered |
| Forbid | "don't go here" / "don't touch this" | `Rule(forbidden, hard)` over the region |
| Describe an activity | "this is where I brainstorm" | `Activity` bound to the containing or new place |
| Correct | "no, that's the kitchen" | Rename or re-target the most recent referent |

### Capture

The target is the gaze raycast hit against the scene mesh at the moment the utterance begins,
not when it ends — the user is already looking away by the end of the sentence. The hit is
held from utterance start and reused for the whole act.

Radius comes from the geometry, not a constant: a surface hit adopts the plane's extent
clamped to 0.3–2.0m; a floor hit adopts 1.0m; an object hit adopts the mesh cluster bounds
plus 10cm.

If gaze has no valid hit, the bird asks rather than guessing, and the act stays open for one
follow-up turn: "I didn't catch where — look at it and say that again?"

### Acknowledgement

Teaching that produces only a toast is a failed teaching act (PRD §7). Every act, in order:
the bird looks at the target immediately, hops to it if reachable, plays the matching
expression (`curious` for naming, `scolded` for forbidding, `happy` for a correction accepted),
and says the name back. Saying the name back is the confirmation channel — it is how a
mis-transcribed name gets caught in the same breath.

### Disambiguation

Naming inside an existing place's radius asks once, and the answers are exactly two: rename
the existing place, or nest a new object within it. Silent overwriting of a taught record is
prohibited; the user spent effort on it.

## Enforcement

The client owns the map. `agentd` receives an abstracted view — names, kinds, coarse
relationships, the containing place of the user — and never coordinates, camera frames, or
reconstructions (`docs/architecture.md` §3b, PRD §8).

Because of that, every spatial resolution is client-side. The model emits `walkTo("kitchen")`
and `DirectiveResolver` resolves it against the map and the navmesh; an unknown name produces
a clarifying question and an unreachable target produces a spoken failure. Neither produces
motion.

Forbidden zones are subtracted from the navmesh at rebuild time. This is the only acceptable
enforcement: a hard rule expressed as a prompt instruction is a rule that gets violated on a
bad sample, and one violation of "don't touch this" costs the user's trust permanently.

## Curiosity

The bird asks about what it does not know. Candidates are ranked by: proximity to the user's
current attention, how often it has been near an unnamed region, devices with no spatial
binding, and places with no activity attached.

The budget is hard and is a product requirement, not a tuning knob (PRD §9): at most one
question per 10 minutes, at most 4 per session, never within 30s of a user utterance, never
while the user is inside a `quiet` rule, and never twice about the same candidate. A declined
or ignored question suppresses that candidate for 7 days. Two ignores in a session stops
questions for the rest of it.

A question is always asked from next to the thing, looking at it. "What's this?" from across
the room is unanswerable and is therefore not a question, it is noise.

## Learned behavior

The map changes what the bird does when nobody asked it anything:

Presence follows the map — it prefers `perch` regions and the place the user most often
occupies at this time of day, rather than the nearest legal floor point.

Activities change its response to the user. In a place tagged with an activity, during that
activity's observed time band, the bird settles and goes quiet instead of following. This is
the payoff for "this is where I brainstorm" and it must be observable within a few sessions
or the feature is not earning its complexity.

Ambient events route through the map. A doorbell sends it to the object named "door" if one
exists, and to the user if one does not.

Affinity accumulates: teaching acts, successful actions, and time in-session raise it; ignored
questions and cancelled actions lower it slightly. It biases idle weights, proximity, and
expression baseline. It is never shown as a number and there is no way to grind it.

## Inspection and forgetting

Every record is visible in a map inspector: name, kind, when taught, how often used, and a
spatial highlight when selected. Every record is individually deletable, and deletion is
immediate and complete — including from episodes.

"Forget everything" exists, is one action, and re-hatches the bird in the same room with no
names. A map that cannot be audited or erased is not something to put a door lock behind.

## Persistence

Map records persist across sessions in on-device storage keyed by room, with anchors
re-resolved on launch. `agentd` holds only the abstracted view for the life of the session
and forgets on restart, which stays correct: coordinates never land on the server.

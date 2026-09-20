# Spec 01 — Character

## Presence rules (non-negotiable)
- Feet contact a detected floor plane at all times. Never mid-air, never clipping geometry.
- Never spawns or paths inside a mesh-occupied volume.
- Scale is fixed and human-referenced: ~45cm tall, reading as a small figure in the room,
  not a life-size person. Life-size is uncanny at conversational distance in a real room.
- Resting position is at least 1.0m from the user, outside arm's reach.

## State machine
```
idle ─▶ turning ─▶ walking ─▶ arriving ─▶ idle
  │                                        ▲
  ├─▶ listening ─▶ thinking ─▶ speaking ───┤
  └─▶ gesturing ───────────────────────────┘
```
Every transition crossfades (0.2–0.3s). No hard cuts. `thinking` must be enterable within
400ms of an utterance ending, before the model has produced anything.

## Locomotion
Speed derives from the walk clip's root motion; the clip drives the transform, not the
reverse. A fixed speed plus a chosen clip is what produces foot-sliding.

Paths come from the navmesh in spec 05 and are clamped to reachable floor. An unreachable
`walkTo` fails to `idle` plus a spoken acknowledgement — it never partially walks toward a
wall.

## Directives
The agent emits intent, never animation names or coordinates:
`walkTo(anchor)`, `lookAt(target)`, `point(at:)`, `emote(kind)`, `gesture(kind)`.
`CharacterKit` resolves intent into clips and transforms. A model emitting raw coordinates
is a protocol violation, not a feature.

## Budget
Skeleton ≤ 80 joints. One skinned mesh. USDZ with baked animation libraries, driven by
`AnimationPlaybackController`. The character is one part of a 90fps budget shared with scene
mesh and passthrough.

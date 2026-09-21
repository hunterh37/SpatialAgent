# Spec 06 — Avatar (the bird)

Supersedes `01-character.md` for anything body-related. The state machine in 01 stands; this
document says what has the states.

## What it is

A small round bird assembled from RealityKit primitive meshes in one entity hierarchy, with
no skinned mesh, no imported rig, and no baked animation clips. Everything moves by
transform: procedural animation on a per-frame update, driven by the same
`CharacterStateMachine`.

Primitives are a budget decision and a style decision at once. The budget: ~15 `ModelEntity`s
with flat-shaded materials cost effectively nothing next to scene mesh and passthrough, and
a transform-driven rig has no skinning cost and no asset pipeline. The style: low-poly with
hard normals and a limited palette reads as intentional and charming at 25cm, where a
mid-fidelity bird reads as a bad bird.

## Proportions

Height 22cm at the crown, standing. Smaller than the 45cm figure in spec 01 — it is a bird,
and the rule it must satisfy is "reads as a small creature on your desk," not "reads as a
person."

Ratios, which are the whole of whether it is cute:

| Part | Size | Rule |
|---|---|---|
| Body | 11cm sphere, scaled (1.0, 0.92, 0.95) | The largest single element. Roundness is non-negotiable. |
| Head | 8cm sphere | ~0.72 of body diameter. A big head is the single strongest cuteness lever. |
| Eyes | 2.6cm spheres | ~0.33 of head diameter, which is enormous and correct. |
| Beak | cone, 2.2cm long, 1.8cm base | Short and blunt. A long beak reads as a crow and kills it. |
| Wings | 2 flattened ellipsoids, 6cm | Sit low on the body, rest slightly out from it, never folded flat. |
| Feet | 2 rounded boxes, 3cm | Visible, planted, slightly oversized. |
| Tail | flattened wedge, 5cm | Small. It is a counterweight for the head, visually and in the animation. |
| Crest | 3 small cones | Optional per color variant. Reads emotion at a distance better than the face does. |

Head sits forward of body center by ~1cm and high; the neck is implied, not modeled. Eyes sit
forward and wide, with ~0.6 of an eye-diameter between them. The body's lowest point is at
the floor plane minus foot height, and that is what the presence rule checks.

## Hierarchy

```
BirdRoot                 yaw, world position, path following
└── Bob                  vertical bob + lean, driven by locomotion phase
    ├── Body
    │   ├── WingL / WingR    flap, tuck, point
    │   ├── FootL / FootR    step phase
    │   └── Tail             counterweight + wag
    └── Head              head lag, look-at, tilt
        ├── EyeL / EyeR       pupil offset, blink scale
        ├── Beak              open amount
        ├── BrowL / BrowR     rotation + height
        └── Crest             lean + spread
```

The split matters: `BirdRoot` owns navigation, `Bob` owns everything that makes walking look
like walking, and `Head` owns attention. Attention must be independent of locomotion so the
bird can watch you while hopping away.

## Face

The face carries the emotion and it is four parameters, not a texture atlas. Textures were
rejected: swapping a face texture cannot ease, and everything here needs to ease.

**Eyes.** Pupils are separate small spheres offset on the eye surface toward the look target,
clamped so they never leave the sclera. Pupil scale itself is expressive — dilate 1.15x for
happy and curious, contract 0.85x for alert. Blink is a Y-scale of the eye sphere to 0.08 over
90ms and back over 110ms, never symmetric in timing. Spontaneous blinks every 3–6s with jitter;
a double blink on surprise; no blinking at all while `thinking` reads as concentration.

**Brows.** Two small rounded boxes above the eyes, with rotation and height. Brows do more
expressive work than anything else on the face: inner-up is concern, outer-down is
determination, both-up is surprise. Held at neutral they must be barely visible.

**Beak.** Opens on a hinge at the base, 0–22°, driven by speech amplitude while `speaking`
and by a small idle chirp otherwise. Beak open with no speech is uncanny; it closes within
120ms of the last token.

**Crest.** Perks forward when curious, flattens back when uncertain or scolded, spreads on
surprise. It is the emotional read that survives from across the room.

### Expressions

Named blends over the four parameters, crossfaded, never snapped:

`neutral` · `curious` (head tilt 12°, crest forward, pupils dilated, one brow up) ·
`happy` (eyes squint to 0.6 Y-scale, beak slightly open, body bob faster) ·
`thinking` (look up and away, no blink, crest half-flat, slow head drift) ·
`confused` (head tilt 18° opposite the look target, brows asymmetric) ·
`alert` (pupils contract, crest up, body raised, dead still) ·
`sad` (head down, crest flat, brows inner-up, bob slow and shallow) ·
`excited` (rapid small hops, wings half-out, crest spread, quick blinks) ·
`scolded` (head low, body shrunk 6%, wings tucked, looks away then back).

`scolded` exists because forbidding a region must feel like it landed on a creature.

## Locomotion

Birds hop. Hopping is also the cheapest convincing procedural locomotion there is, which is
a rare alignment of taste and budget.

One hop is a ballistic arc: 0.34s, peak height 4cm, horizontal distance 9cm. Foot contact
happens at the start and end of the arc and nowhere in between, which makes foot-sliding
structurally impossible — the feet only move while airborne. Body squashes to (1.08, 0.88)
for 60ms at landing and eases back over 140ms; anticipation squashes the opposite way for
80ms before takeoff. That squash is the difference between alive and mechanical and it is
worth more than any other 200 lines in the renderer.

Wings give a small out-and-back on takeoff. The tail counter-rotates against the head. The
head holds its look target through the whole arc with damped lag, so it bobs independently.

Long distances play a short glide: three fast wingbeats, a shallow arc 2–3 hops long, landing
with a two-footed skid. Used only above ~1.5m of path remaining so it does not look twitchy.

Speed derives from hop cadence, and the path comes from the navmesh (spec 05), clamped to
reachable floor and to the forbidden-zone subtraction (spec 07). An unreachable `walkTo`
fails to `idle` with a spoken line; it never partially hops toward a wall.

## Idle

Never static. A weighted idle pool with a 4–9s timer: look around, preen a wing, head tilt,
shuffle-turn in place, single small hop, stretch both wings, scratch with one foot, settle
lower and blink slowly. Weights shift with mood and with how long the user has been quiet.
A breathing cycle runs underneath everything at 0.25Hz with 2% body scale — it must never
fully stop while the bird is alive.

## Attention

The head look-at is the primary tell that it is a creature and not a puppet. Head yaw is
limited to ±75° from body forward, pitch ±40°; beyond that the body turns to follow after a
short delay, which is what produces the characteristic bird double-take. Damped with a spring,
never linear, with a deliberate 80–140ms lag behind the target so the head trails the eyes.

Eyes lead the head, head leads the body. Reversing that order is the single most common way
a character reads as dead.

## Mapping to agent state

| State | Body |
|---|---|
| `idle` | Idle pool, breathing, occasional look at user. |
| `listening` | Turns to the user, head tilt, crest forward, blinking slows. |
| `thinking` | Look up and away, crest half-flat, slow drift, no blink. Entered within 400ms. |
| `speaking` | Beak driven by amplitude, small head bobs on emphasis, wings gesture on stress. |
| `walking` | Hop cycle, head holds its look target. |
| `gesturing` | Point = one wing extended toward the target plus head aligned to it. |
| `arriving` | A settle: one small shuffle, wing fold, blink. |

## Variants

One mesh, several palettes, chosen at hatch and changeable: body color, belly color, beak and
foot color, crest presence and shape. Three to five presets, no editor. Variants are for
attachment, not customization.

## Budget

≤15 `ModelEntity`s, ≤3 materials, no textures, no skinning, no imported animation. All motion
is transform updates inside a single `SceneEvents.Update` subscription with a measured cost
budget of 0.4ms/frame on-device. Everything is generated at runtime from `MeshResource`
primitives, so there is no art pipeline and no asset to keep in sync.

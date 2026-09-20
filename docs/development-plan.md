# Development plan

Build order from the landed foundation to the PRD v2 feature set. Each phase names the files
it touches, what "done" means, and the test that proves it. Phases are sequenced so every one
ends with something runnable on the headset — no phase leaves the app in a state that cannot
be demoed.

Conventions: Swift packages live in `packages/Sources/<Module>`, their tests in
`packages/Tests/<Module>Tests`, Python in `services/agentd/agentd`. `make test` must stay green
at the end of every phase. Protocol changes go through `packages/AgentProtocol/schema/` and
`make protocol` first, never into one language by hand.

---

## Phase A — The bird (spec/06-avatar.md)

Replaces the placeholder capsule with the actual creature. No protocol change, no server
change; entirely `CharacterKit`. This phase is the largest single lift in the plan and most of
it is tuning, not architecture.

### A1 — Rig assembly

New: `packages/Sources/CharacterKit/Bird/BirdRig.swift`, `BirdProportions.swift`,
`BirdPalette.swift`.

`BirdRig` builds the hierarchy in spec 06 from `MeshResource` primitives and holds a named
reference to every joint entity. `BirdProportions` is a struct of every measurement in the
spec table, defaulted to the spec values, so proportions are tunable in one place and
testable — the ratios are the cuteness and they need to be adjustable without hunting through
construction code. `BirdPalette` is 3 materials and the 3–5 variants.

Done: the bird renders standing on the floor, correct proportions, correct height (22cm),
lowest point exactly on the floor plane, ≤15 entities, ≤3 materials.

Test: `BirdRigTests` asserts entity count, material count, that head diameter is 0.70–0.75 of
body diameter, eye diameter is 0.30–0.36 of head, and that the computed bounds bottom is at
y=0 within 1mm.

Status: done — `BirdRig`/`BirdProportions`/`BirdPalette` landed, 15 model entities, 3 materials,
crown 22cm via uniform normalization (the spec's part sizes stand 17.9cm), `BirdRigTests` green.

### A2 — Procedural motion core

New: `Bird/BirdAnimator.swift`, `Bird/Spring.swift`, `Bird/Easing.swift`.

The per-frame driver. A damped spring type used for everything that follows a target, easing
curves, a breathing cycle, and the squash-and-stretch primitive. Everything downstream is
composed from these four, which is why they come before any named animation.

Done: breathing runs, squash-and-stretch can be triggered and eases correctly, springs are
stable at 90fps and at 30fps without overshoot divergence.

Test: `BirdAnimatorTests` steps the spring at both frame rates and asserts convergence with
no oscillation past tolerance; asserts breathing amplitude stays within 2% body scale.

Status: done — `Spring`/`AngularSpring` (substepped, stable and equal at 30 and 90fps), `Easing`,
`Squash` (1.08/0.88, 60ms hold, 140ms release) and `BirdAnimator` breathing at 0.25Hz/2%.

### A3 — Hop locomotion

New: `Bird/HopController.swift`. Modifies `CharacterEntity` to delegate path following.

Ballistic arc per spec: 0.34s, 4cm peak, 9cm distance, anticipation squash before takeoff,
landing squash on contact, feet stationary except while airborne, wings out-and-back, tail
counter-rotation. Path still comes from `NavMesh`.

Done: the bird crosses a room by hopping and the feet never slide. Foot-sliding is the single
most visible failure in the spec and it gets checked by eye on-device, not only in a test.

Test: `HopControllerTests` samples foot world position every frame across a full path and
asserts horizontal foot movement is zero on every frame where that foot is grounded.

Status: done — `HopController` (0.34s/4cm/9cm arc, anticipation crouch on `Body` not `Bob`,
glide above 1.5m), `CharacterEntity` delegates path following; zero grounded foot slide at 90
and 30fps.

### A4 — Face and expressions

New: `Bird/FaceController.swift`, `Bird/Expression.swift`.

The four face parameters (pupils, brows, beak, crest), blink scheduling with asymmetric
timing, and the nine named expressions as blends that crossfade rather than snap. Beak opens
on speech amplitude and closes within 120ms of the last token.

Done: every named expression is reachable and visually distinct at 1.5m; blinks read as
natural; no beak movement without speech.

Test: `ExpressionTests` asserts every case of the expression enum produces a distinct
parameter vector, that crossfade never snaps (no parameter moves more than its per-frame
limit), and that beak closes within 120ms of the last token event.

Status: done — `Expression` (9 blends over an 11-parameter face vector), `FaceController`
(250ms crossfade, asymmetric 90/110ms blink with jitter, no blink while thinking, double blink
on alert, beak driven by tokens and shut 120ms after the last one).

### A5 — Attention

New: `Bird/AttentionController.swift`.

Eyes lead head leads body, with the 80–140ms lag, ±75° head yaw and ±40° pitch limits, and
the body-turn double-take past the limit. Attention is independent of locomotion so the bird
can watch the user while hopping away.

Done: the bird tracks the user continuously, including mid-hop, and does the double-take when
the user walks behind it.

Test: `AttentionTests` asserts head yaw never exceeds the limit, that body yaw follows after
the delay when it would, and that head target tracking continues while a hop path is active.

Status: done — `AttentionController`: three springs (eyes 42, head 14, body 7), head lag
measured at ~110ms inside the 80–140ms window, ±75°/±40° clamps, 220ms double-take delay,
tracking asserted mid-hop.

### A6 — Idle behavior pool

New: `Bird/IdlePool.swift`.

Weighted pool on a 4–9s timer with the eight behaviors in spec 06, weights shifting with mood
and user silence. Never static.

Done: two minutes of observation with no input never repeats the same behavior twice in a row
and never sits still.

Test: `IdlePoolTests` runs 1000 selections and asserts no immediate repeats, that every
behavior is reachable, and that weight shifts change the distribution in the stated direction.

Status: done — `IdlePool`: 8 behaviors, 4–9s timer, no-immediate-repeat by construction,
mood/silence shifts monotonic and floored so nothing becomes unreachable at the extremes.

### A7 — State mapping and integration

Modifies: `CharacterEntity.swift`, `ImmersiveView.swift`.

Wires `CharacterStateMachine` states to the bird's body per the spec 06 table, retires the
capsule and the `AnimationResource` indexing path, and confirms the 400ms `thinking` budget is
met by the procedural entry.

Done: `make live-app` drives the bird through the full loop in the simulator. Frame cost of
the bird's update measured under 0.4ms on-device.

Test: existing `CharacterTests` updated; `LiveIntegrationTests` asserts a visible body change
within 400ms of `utteranceEnded`.

Status: done — `CharacterEntity` rebuilt on `BirdRig` (capsule, USDZ load and
`AnimationResource` indexing removed), state table wired, `BirdIntegrationTests` plus a live
400ms body-change test. On-device frame cost still to be measured on the headset.

---

## Phase B — Semantic map foundation (spec/07-memory.md)

The store and its enforcement, before any teaching UI. Built first so that teaching in phase C
has somewhere to write and so the navmesh constraint is proven before a user can author one.

### B1 — The store

New: `packages/Sources/SpatialMemory/` — `SemanticMap.swift`, `Place.swift`, `MapObject.swift`,
`Rule.swift`, `Activity.swift`, `Episode.swift`, `MapStore.swift`.

New module rather than an extension of `SceneUnderstanding`, because the map is user data with
a persistence and privacy story and the scene module is derived sensor data. `NamedPlaceStore`
is absorbed here and its call sites migrate; `PlaceRecord` becomes `Place` with the added
fields.

Done: all six record types, stable identity, name-collision-is-a-correction semantics, codable
persistence keyed by room, individual deletion, and a complete wipe.

Test: `SpatialMemoryTests` covers round-trip persistence, collision handling, deletion
completeness including episodes, and that a wipe leaves no residue.

### B2 — Anchor binding

New: `SpatialMemory/AnchorBinding.swift`. Modifies `SceneProvider.swift`.

Every spatial record holds a `WorldTrackingProvider` anchor UUID plus a cached transform.
Relocalization updates the cache; a record that never relocalizes is flagged non-navigable
rather than used at a stale position.

Done: taught places survive quit-and-relaunch in the same room and land in the same physical
spot.

Test: `AnchorBindingTests` with a mocked provider covers relocalize-updates-cache, and
never-relocalized-is-non-navigable.

### B3 — Forbidden zones in the navmesh

Modifies: `SceneUnderstanding/NavMesh.swift`.

Hard `forbidden` rules are subtracted from the walkable surface at rebuild time, alongside the
existing obstacle margin. `fragile` becomes a landing/gesture exclusion, not a path exclusion.

Done: no path can be produced that enters a forbidden region, from any start, to any goal,
including a goal inside the region.

Test: `NavMeshTests` gains a property test: for 10k random start/goal pairs against a map with
forbidden regions, zero returned path vertices fall inside any forbidden polygon. This is the
test that makes the spec 07 enforcement claim true rather than aspirational.

### B4 — Abstracted view to the server

Modifies: `packages/AgentProtocol/schema/protocol.schema.json`, `AgentKit/AgentSession.swift`,
`agentd/session.py`, `agentd/prompt.py`.

`sceneUpdate` carries the abstracted map: place names and kinds, object names and their
device bindings, rule kinds, activity names, and the user's containing place. No coordinates.
Run `make protocol` first.

Done: the model's prompt describes the room in names, and `scripts/check_protocol.py` passes.

Test: `ConformanceTests` plus `test_prompt_describes_the_taught_room`; a Python test asserts no
numeric coordinate field exists anywhere in the abstracted payload.

---

## Phase C — Teaching (spec/07-memory.md §Teaching)

The highest-risk path in the product (PRD §9) and therefore the most tested.

### C1 — Gaze capture

New: `packages/Sources/SceneUnderstanding/GazeTarget.swift`.

Raycast against the scene mesh, held from utterance *start*, with the extent-derived radius
rules. Returns hit, surface extent, and a classification of floor vs surface vs object
cluster.

Done: looking at a desk and speaking captures the desk's extent, not a point.

Test: `GazeTargetTests` against a synthetic mesh asserts radius derivation per surface class
and that the held target is the utterance-start target, not the end one.

### C2 — Teaching intent recognition

New: `services/agentd/agentd/teaching.py`. Modifies `session.py`, `directives.py`, schema.

Five server-side tools — `name_place`, `name_object`, `forbid_region`, `name_activity`,
`correct_name` — so the model states the teaching act rather than the client regexing prose.
The same lesson as `walk_to` in phase 2.1: inferring intent from prose is unreliable.

The client resolves each to the held gaze target and writes the record. The server never sees
where it landed.

Done: all five acts fire against a real local model with the small-model hardening already in
`prompt.py`.

Test: `test_teaching.py` drives each utterance shape through the adapter and asserts the right
tool with the right name; `make live` covers it end to end.

### C3 — Acknowledgement choreography

New: `packages/Sources/CharacterKit/Bird/TeachingResponse.swift`.

Look at target immediately, hop to it when reachable, matching expression per act, say the
name back. The name-back is the correction channel for mis-transcription and is not optional.

Done: every act produces motion within 400ms and a spoken name-back.

Test: `TeachingResponseTests` asserts the motion-within-400ms property for all five acts and
that `forbid` plays `scolded`.

### C4 — Disambiguation and correction

Modifies: `teaching.py`, `SemanticMap.swift`.

Naming inside an existing radius asks once with exactly two answers: rename, or nest. Silent
overwrite is prohibited. `correct_name` re-targets the most recent referent.

Done: no taught record is ever lost without the user choosing it.

Test: `SpatialMemoryTests.testTeachingInsideAnExistingPlaceNeverSilentlyOverwrites`.

### C5 — Map inspector

New: `apps/SpatialAgent/Sources/MapInspectorView.swift`, `DesignSystem/MapRow.swift`.

Every record listed with name, kind, taught-at, use count, spatial highlight on selection,
per-row delete, and a single "forget everything" that re-hatches in place.

Done: a user can see and erase everything the bird knows.

Test: covered in `AppFlowUITests`.

---

## Phase D — Learned behavior

Where the map starts paying for itself. Ordered so the visible payoff (presence, activities)
lands before the subtle one (affinity).

### D1 — Map-driven presence

Modifies: `SceneUnderstanding/Placement.swift`.

Placement prefers `perch` regions and the user's usual place for this time of day over the
nearest legal floor point, while keeping every spec 05 placement constraint.

Test: `PlacementTests` asserts perch preference and that all hard constraints still hold when
the preferred spot is illegal.

### D2 — Activity inference and response

New: `SpatialMemory/ActivityInference.swift`.

Observed time-of-day bands per activity, and the behavior switch: inside an activity's place
during its band, settle and go quiet rather than follow.

Test: `ActivityInferenceTests` asserts band formation from episodes and the follow-vs-settle
switch.

### D3 — Curiosity

New: `SpatialMemory/CuriosityPlanner.swift`. Modifies `agentd/ambient.py`.

Candidate ranking per spec 07 and the hard rate budget: 1 per 10 min, 4 per session, none
within 30s of a user utterance, none inside a `quiet` rule, never twice about a candidate,
7-day suppression on decline, stop for the session after two ignores.

The question is always asked from next to the thing while looking at it.

Test: `CuriosityPlannerTests` asserts every budget clause independently, including the
two-ignores stop. The budget is a product requirement (PRD §9), so each clause gets its own
test rather than one combined one.

### D4 — Deixis

Modifies: `CharacterKit/DirectiveResolver.swift`, `AgentKit/AgentSession.swift`.

Closes item 4 of `docs/middle-layer-todo.md`: objects carry device bindings and positions on
the client, so "turn *that* off" resolves through gaze plus the object table. Coordinates stay
off the server, which is why the binding lives in `SpatialMemory` and not on `Device`.

Test: `DirectiveResolverTests` covers gaze-resolved device reference and the ambiguous case
producing a question, not a guess.

### D5 — Mood and affinity

New: `Bird/Mood.swift`.

Affinity accumulates from teaching, successful actions, and session time; decays slightly on
ignored questions and cancelled actions. Biases idle weights, proximity, and expression
baseline. Never displayed as a number, no grind path.

Test: `MoodTests` asserts monotonic response to each input and that no public API exposes a
raw value.

---

## Phase E — Home depth

The macOS companion (item 1 of `docs/middle-layer-todo.md`): a macOS target linking
`HomeBridge`, owning `HMHomeManager` and Home authorization, implementing `HomeExecutor`.
Nothing in `agentd` changes when it lands — that is what the executor boundary bought.

Then ambient sources beyond device diffs (timers, appliance completion), and multi-room maps
keyed by relocalized room.

---

## Cross-cutting

**Performance.** The bird's per-frame cost is measured on-device at the end of phase A and
re-measured at the end of D. Budget 0.4ms. A phase that exceeds it does not close.

**Presence regressions.** The feet-on-floor and never-in-geometry properties get an assertion
in the update loop under debug builds, so a regression fails loudly in the simulator rather
than quietly on someone's head.

**Protocol.** Every schema change runs `make protocol` before either language is touched.

**Order rationale.** The bird comes first because the capsule makes every other feature
impossible to evaluate — teaching, curiosity and mood are all judged by how the creature
reacts, and a capsule has no reactions to judge. The map foundation comes before teaching
because a teaching act that writes nowhere is untestable, and enforcement comes before
authoring because a user must never be able to author a rule the system cannot keep.

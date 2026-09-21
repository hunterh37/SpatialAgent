# Demo runbook — "an agent that remembers your room and you"

Two memories, one bird. The **map** remembers the room — where he eats, drinks, gets petted,
finds his toys, sleeps, and what to stay off — and lives on the headset, coordinates never
leaving it. The **profile** remembers the person and lives in one JSON file on the Mac you can
open, edit, export and delete. The demo is the seam: an instruction that names no landmark
("you must be hungry") is answered out of the map, so teaching him changes what he *does*,
and both memories survive a restart.

## 0. Before the room is warm (2 min)

```bash
make serve                                   # agentd on :8787
cd services/agentd && .venv/bin/python -m mocks.seed_demo        # a plausible history
curl -s localhost:8787/memory | jq '.facts[].text'               # what it knows, in the open
```

`--wipe` empties it. Do that if you want to demo the profile being *earned* instead.

## 1. Place the landmarks (headset, 60s)

Open the app → **Landmarks**. Look at a spot, tap *Place here*, repeat. Each one is a
low-poly prop you can see and pinch-drag, not a debug sphere.

| Landmark | Kind | Prop | What it answers |
|---|---|---|---|
| red / blue / amber perch | `perch` | pole + crossbar, painted | "time to settle down" |
| food bowl | `food` | bowl + heaped seed | "you must be hungry" |
| water dish | `water` | shallow dish | "go get a drink" |
| petting spot | `comfort` | tufted cushion | "come get some pets" |
| toy basket | `toy` | basket + ball, bell, ring | "go find yourself a toy" |
| your desk | `workspace` | desk + monitor | scenery, and the lamp beat |
| plant | fragile rule | pot + leaves | the constraint the route dodges |

The three perches are identical except for colour, and that is the point: which one he
settles on is learned from where he has been swatted off, so the colour is the only way to
say out loud what he chose. Swat him off the red one twice and ask him to settle again.

The three perches are identical records at identical heights and differ only in paint. That
is deliberate: nothing about them can explain a preference, so when he stops using one the
only available explanation is memory. See §2b.

The five kinds in the middle column are the demo. `HabitMemory` resolves a **need** against
`PlaceKind`, never against a name, so the destination for "you must be hungry" comes out of
the map at speak time. Delete the bowl and the same chip says *"I don't know where I eat yet
— show me and I'll remember."* That is the line worth provoking on stage.

Each tap writes a real ARKit `WorldAnchor` plus a `Place` record through `MapStore`, so the
landmark is still there after a quit-and-relaunch.

## 1b. No Mac, no model (the understudy)

With nothing connected, the demo bar above the chips does the whole thing on-device:
**Set up demo room** writes all seven presets through `LandmarkPlacer` (world-anchored where
ARKit can, synthetically offset in the simulator), **Run of show** plays the beats back to
back, and every chip with a bird on it replays its scripted `CharacterDirective`s through the
same resolver a server directive takes. **Reset room** wipes map and anchors.

Connected, the chips go back to being plain utterances: the script is the understudy, and it
never stands in front of the model.

## 2. The run of show

Tap the preset chips; nothing is typed. Each beat reads what the beat before it wrote.

0. **Put up the perches** — one chip places all three, and he takes one.
1. **Teach where he eats** — "this is where you eat" → the bowl is anchored, he flies to it.
2. **Ask without naming it** — "you must be hungry" → the utterance contains no landmark.
   He looks up the `food` place, says *"the food bowl — that's where I eat"*, and goes. The
   visit is counted on the record.
3. **Add a constraint** — "don't go near the plant" → a fragile rule is subtracted from the
   navmesh; the next flight routes around it.
4. **Teach a second need** — "this is where I pet you" → the cushion is anchored.
5. **Ask for it** — "come get some pets" → resolves to the cushion, not the bowl.
6. **Ask what he knows** — "what have I taught you about this room?" → the sentence is built
   from `SemanticMap` when it is spoken, so it shortens after a reset.
7. **Hand him the decision** — "do what you think I want" → `HabitMemory.strongestNeed`
   picks the need itself, narrates the branch, then flies.

Tap the same need twice and the line changes: the second time he says how many times he has
been there. The count lives on the `Place` record, visible in **What I know**, which is worth
having open on the projector.

## 2b. The aversion: three perches and a hand (the new bit, 90s)

Tap **Go perch**. He picks one of the three — the red one, first time, because nothing yet
separates them — flies up onto the crossbar and stands there.

Now knock him off. A hand moving across him at swiping speed, within about 20cm, while he is
actually standing on a perch. He tumbles off, lands under it, and says so.

Tap **Go perch** again. He names the perch he is *not* using and why, then takes a different
one. Knock him off that one and the third is next. The counter is `Place.knockOffs`, visible
on the record in **What I know**, and drawn on the prop itself as a red band per knock — so
the audience can see the learning without reading a number.

What makes this a memory demo rather than a state machine:

- Nothing in the utterance names a perch. `PerchMemory.best` picks it, out of the map.
- One knock outweighs any number of successful visits: he does not go back to argue.
- It survives a relaunch, because the count is on the anchored record.
- **Forgive the swats** clears the counts without touching the perches, so it re-runs.

Things that deliberately do *not* cost him a perch: a slow hand reaching past him, a fast
hand that misses, a hand dropping straight down beside the perch. All three are in
`KnockDetectorTests` — a perch wrongly ruled out is a memory the user never taught.

## 3. The close: own the memory (45s)

```bash
curl -s localhost:8787/memory/export > mine.json      # portable
curl -s -X DELETE localhost:8787/memory/<id>          # forget one thing
curl -s -X POST localhost:8787/memory/import -d @mine.json -H 'content-type: application/json'
```

Then quit the app, relaunch, and tap "you must be hungry" — the bowl, its anchor and its
visit count are all still there. Editable, portable, inspectable, and the agent behaves
differently because of them.

## Running it with no headset

```bash
cd services/agentd
.venv/bin/python -m mocks.fake_headset --scenario demo_loft --demo   # the whole script
.venv/bin/python -m mocks.fake_headset --scenario demo_loft          # interactive
```

Interactive commands: `/look the food bowl` (what the user is staring at, which is what a teaching act
resolves against), `/map`, `/memory`, `/forget TEXT`, `/devices`, `/ring`.

## If something breaks on stage

- Model stalls → `AGENTD_BACKEND=echo make serve` still demoes the map, the landmarks and the
  HTTP memory surface; only the prose goes away.
- Headset will not relocalize → run the fake headset on `demo_loft`, which ships with the
  landmarks already placed.
- Profile looks wrong → it is one file: `~/.spatialagent/profile.json`. Edit it in front of
  the audience; that is a feature, not a repair.

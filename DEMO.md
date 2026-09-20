# Demo runbook — "an agent that remembers your room and you"

Two memories, one bird. The **map** remembers the room and lives on the headset (coordinates
never leave it). The **profile** remembers the person and lives in one JSON file on the Mac
that you can open, edit, export and delete. The demo is the seam between them: a landmark the
user placed changes what the agent *does*, and a fact the user said changes what it *says* —
and both survive a restart.

## 0. Before the room is warm (2 min)

```bash
make serve                                   # agentd on :8787
cd services/agentd && .venv/bin/python -m mocks.seed_demo        # a plausible history
curl -s localhost:8787/memory | jq '.facts[].text'               # what it knows, in the open
```

`--wipe` empties it. Do that if you want to demo the profile being *earned* instead.

## 1. Place the landmarks (headset, 60s)

Open the app → **Landmarks**. Look at a spot, tap *Place here*, repeat:

| Landmark | Kind | Why it is in the demo |
|---|---|---|
| bookshelf perch | `perch` | The only landmark that changes behaviour: the bird waits there. |
| desk | `workspace` | Anchors the activity ("morning standup") and the desk lamp. |
| couch | `surface` | Where the fragile rule lives. |
| kitchen | generic | A second room-scale destination, so walking is legible. |
| front door | generic | Ambient: the doorbell has somewhere to point. |

Each tap writes a real ARKit `WorldAnchor` plus a `Place` record through `MapStore`, so the
landmark is still there after a quit-and-relaunch. That is the line to say out loud.

## 2. The five beats

Tap the preset chips; nothing is typed.

1. **Teach** — "this is your perch" → the bird looks, the perch is written, it flies there.
2. **Obey what was taught** — "go to your perch" → it walks to a place that did not exist
   two minutes ago.
3. **Respect a boundary** — "don't go near the plant" → a hard rule is subtracted from the
   navmesh; ask it to go to the couch and watch it route around.
4. **Remember the person** — "remember I drink oat flat whites", then "what do you remember
   about me?" → recall, not invention. `curl localhost:8787/memory` on the projector shows
   the same words.
5. **Earn a memory** — "ask me something about myself" → it asks one question, banks the
   answer in the right slot, and never asks that question again.

## 3. The close: own the memory (45s)

```bash
curl -s localhost:8787/memory/export > mine.json      # portable
curl -s -X DELETE localhost:8787/memory/<id>          # forget one thing
curl -s -X POST localhost:8787/memory/import -d @mine.json -H 'content-type: application/json'
```

Then quit the app, relaunch, and ask "where's your perch?" — the landmark and the facts are
both still there. Editable, portable, inspectable, and the agent behaves differently because
of them.

## Running it with no headset

```bash
cd services/agentd
.venv/bin/python -m mocks.fake_headset --scenario demo_loft --demo   # the whole script
.venv/bin/python -m mocks.fake_headset --scenario demo_loft          # interactive
```

Interactive commands: `/look desk` (what the user is staring at, which is what a teaching act
resolves against), `/map`, `/memory`, `/forget TEXT`, `/devices`, `/ring`.

## If something breaks on stage

- Model stalls → `AGENTD_BACKEND=echo make serve` still demoes the map, the landmarks and the
  HTTP memory surface; only the prose goes away.
- Headset will not relocalize → run the fake headset on `demo_loft`, which ships with the
  landmarks already placed.
- Profile looks wrong → it is one file: `~/.spatialagent/profile.json`. Edit it in front of
  the audience; that is a feature, not a repair.

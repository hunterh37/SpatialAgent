# spec/

One document per surface. Each is narrow, versioned with the code, and precise enough to
implement from. Product intent lives in `/PRD.md`; system design lives in
`/docs/architecture.md`.

| File | Covers |
|---|---|
| `01-character.md` | Behavior, animation states, locomotion, presence rules |
| `02-interaction.md` | Addressing, input, speech bubbles, confirmation UX |
| `03-protocol.md` | Wire messages between headset and `agentd` |
| `04-home.md` | Device model, tool surface, safety classification |
| `05-scene.md` | ARKit anchors, navmesh, named places, placement rules |
| `06-avatar.md` | The bird: primitive rig, face, hop locomotion, expressions (supersedes 01 for body) |
| `07-memory.md` | Semantic map, teaching acts, rule enforcement, curiosity, learned behavior |

Changing a spec is a PR. If an implementation disagrees with a spec, one of the two is a bug
and the PR says which.

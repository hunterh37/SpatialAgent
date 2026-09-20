# SpatialAgent — Product Requirements

Status: draft · Owner: hunter@medvr.io · Platform: visionOS 2.0 + macOS companion

## 1. What it is

SpatialAgent puts a small animated character in your actual room on Vision Pro. It walks
across your real floor, looks at you when you speak, goes to the thing you are talking about,
and controls your smart home while you watch it happen.

The character is not a floating chat window with a face on it. It occupies space. When you
say "turn off the kitchen lights," it walks toward the kitchen, gestures, and the lights go
off — the physical act and the spatial motion are the same event.

The model runs on your own machine. A Mac on the same network serves it; nothing about your
home, your rooms, or your devices leaves the LAN.

## 2. Why

Voice assistants are disembodied and stateless. You talk at a speaker, get a chime, and have
no idea what the thing understood or whether it is working. Two failures follow from that:
you cannot tell *where* an ambiguous command landed ("the lights" — which lights?), and there
is nothing to direct attention at, so referring to things by pointing is impossible.

An agent with a body in the room fixes both. Ambiguity is resolved by looking at where it
walked. Reference is resolved by pointing at what you mean. Progress is legible because the
character visibly does something between request and result.

Running the model locally matters for a product whose entire input is a live map of your
home and a list of your door locks. Local is the default, not a privacy toggle.

## 3. Who it's for

Primary: Vision Pro owners with an existing HomeKit/Matter setup and a Mac — people already
running local models, who want something spatial to point them at.

Secondary: developers evaluating embodied-agent patterns; the repo is designed to be read.

Not for: people with no smart-home devices (the agent has nothing to do), or anyone without
a machine to serve a model from.

## 4. Core experience

Four loops, in the order the user encounters them:

**Presence.** The character exists in the room when the app opens. It stands on the floor,
not in mid-air, not inside furniture. It idles, looks around, and notices when you move. It
is there before you ask for anything. Failure here makes everything after it feel like a
demo.

**Address.** You look at it and speak. It turns to you, and a speech bubble streams its reply
token by token as the model produces it. Latency to first visible reaction must feel
immediate even when the full answer is slow.

**Action.** You ask for something. It walks to the relevant place, performs a gesture, and
the device state changes. If the request is ambiguous it asks, from wherever it is standing.
If the request is consequential — locks, garage, anything that cannot be undone from the
couch — it asks for confirmation before acting.

**Ambient.** It reacts to the home without being asked. Someone rings the doorbell and it
walks to the door and tells you. A load of laundry finishes and it mentions it in passing.
This is what separates it from a command line with legs.

## 5. Scope

### v0.1 — Vertical slice
One room. One character. Hardcoded room anchors. Local model via Ollama. Three tools: list
devices, read device state, toggle a light. Text input (no speech). Walk + idle + speak
animations only. Goal: the loop is real end to end, from typed request to a physical light
turning off, with the character walking there.

### v0.2 — Spatial
ARKit floor detection and a real navmesh, so `walkTo` works in a room the app has never seen.
Speech input. Named anchors the user places themselves ("this is the kitchen"). Gaze-based
addressing. Multi-room persistence across sessions.

### v0.3 — Agentic
Full tool set across HomeKit/Matter. Confirmation flow for unsafe actions. Ambient events
pushed from the home to the character. Multi-turn memory that survives reconnects. Pointing
and deixis: "turn *that* off" resolved by where you are looking.

### Explicitly out of scope
Cloud inference. Multi-user shared sessions. A character customization editor. Android or
Quest. Non-Apple smart-home ecosystems in v1. Any monetization surface.

## 6. Success criteria

The v0.1 bar is qualitative and worth naming precisely, because it is easy to ship something
that technically works and feels dead:

- The character never stands inside furniture or floats off the floor. Zero tolerance;
  one occurrence destroys presence for the rest of the session.
- Time from end of request to first character motion is under 400ms. It must react before
  it knows the answer, the way a person starts turning toward you mid-sentence.
- Foot contact matches locomotion. No sliding.
- A wrong or ambiguous command is always recoverable by saying so, without restarting.
- No unsafe device action ever executes without explicit confirmation. This one is binary.

For v0.2+: a first-time user in an unseen room reaches a successful device action within two
minutes, without instructions.

## 7. Constraints

90fps frame budget with a skinned character, real-time scene mesh, and a live socket.
Vision Pro cannot reach localhost, so the Mac must be discoverable on the LAN (see
`docs/architecture.md` §2). HomeKit authorization lives on-device. Model latency is whatever
the user's hardware gives — the character's behavior must degrade gracefully into "thinking"
rather than freezing.

## 8. Risks

The character looking cheap is the biggest product risk and it is mostly animation quality,
not code. Budget real time for locomotion polish.

The second is trust: an agent that takes a wrong physical action once will not be given a
second chance with a door lock. Confirmation gating is a product requirement, not a setting.

The third is the empty-handed case — if the home has few devices, there is nothing for the
agent to do and the character becomes a toy. Worth deciding early whether v1 requires a
minimum device count to be worth installing.

## 9. Specs

Detailed specs live in `spec/`. `docs/architecture.md` covers system design.

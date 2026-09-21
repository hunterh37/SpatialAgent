# SpatialAgent — Product Requirements

Status: v2 draft · Owner: hunter@medvr.io · Platform: visionOS 2.0 + macOS companion

## 1. What it is

SpatialAgent is a small bird that lives in your room on Vision Pro, does not understand the
room, and learns it from you.

It hatches knowing nothing. It hops around, bumps into the edges of what it can reach, looks
at things it has no name for, and asks. You teach it the way you would teach a pet with a
vocabulary: you look at a surface and say *"this is my desk."* You point and say *"that's the
coffee machine."* You say *"don't go here"* and it stops going there. You say *"this is where
I brainstorm"* and it starts showing up there when you are pacing and talking to yourself.

What accumulates is a semantic map of your space: named places, forbidden zones, objects tied
to devices, activities tied to regions, and a behavioral history of what happened where. The
bird's behavior is a function of that map, so the map is visible — you can tell what it knows
by watching where it goes.

Tamagotchi in the sense that it is a creature with a body and a mood that you invest in over
days. AI agent in the sense that it can actually act on your home. The novelty is that the
teaching and the acting are the same interface: everything it can do, it does somewhere.

The model runs on your own machine. A Mac on the LAN serves it. The map of your home never
leaves the network, and camera frames never leave the headset at all.

## 2. Why

Two problems, and one product solves both.

Assistants are disembodied and stateless. You talk at a speaker and cannot tell what it
understood, where an ambiguous command landed, or whether it is working. A creature with a
body in the room fixes that by construction: ambiguity is resolved by watching where it walks,
reference is resolved by pointing, and progress is legible because something visibly moves
between the request and the result.

Spatial computing has no reason to persist. Apps open, render, and close, and the room is the
same room the next day. A creature that remembers the room is the first thing on the platform
that is *worse* if you close it, because it accrues. Day 7 is not day 1 with more features —
it is the same bird in a room it now knows.

Locality is not a privacy toggle here. The input is a live semantic map of your home plus a
list of your door locks. There is no version of this that ships to a cloud.

## 3. Who it's for

Primary: Vision Pro owners who will put the headset on more than once a week and have a Mac
to serve a model from. A HomeKit/Matter setup makes the agent more capable but is no longer
required — the bird has something to do in an empty room now, because learning the room is
itself the activity.

Secondary: developers evaluating embodied-agent and spatial-memory patterns. The repo is
meant to be read.

Not for: people who want a hands-free assistant with no character, or anyone who wants it to
be useful in the first ninety seconds with zero teaching. The teaching *is* the product; a
version that arrives pre-knowing your house would be a worse one.

## 4. Core experience

Six loops, in the order the user meets them.

**Hatch.** First launch. The bird appears on the floor, small and low-poly and clearly alive,
in a room it has no names for. It knows only geometry — where the floor is and what is solid.
It looks at you, looks around, and is visibly uncertain. The first minute establishes that it
does not know anything yet, because that is what makes teaching feel like it lands.

**Presence.** It exists in the room whenever the app is open. It perches, preens, hops,
tracks you with its head, reacts when you move, investigates changes. It is never a static
prop waiting for input, and it is never mid-air or inside the couch. Failure here makes
everything after it read as a demo.

**Teaching.** You name things by looking and speaking. Five teaching acts, all one sentence:
naming a place ("this is my workspace"), naming an object and binding it to a device ("this
is the coffee machine"), forbidding a region ("don't go here"), describing an activity ("this
is where I brainstorm"), and correcting ("no, that's the kitchen"). Every one produces an
immediate, visible acknowledgement from the bird — it hops to the thing, looks at it, and
reacts. Teaching that produces only a toast notification is a failed teaching act.

**Curiosity.** It asks. When it sees a region it has been near many times with no name, or a
device it cannot place in space, it asks about it — in character, at most occasionally, and
never while you are mid-task. Being asked "what's this?" by something standing next to the
thing is the cheapest possible map-building interface, and it is also the thing that makes it
read as alive rather than as a form.

**Action.** You ask for something. It walks to the relevant place, does a gesture, and the
device state changes. Ambiguity gets one short clarifying question from where it stands.
Anything irreversible — locks, garage — gets an explicit confirmation before it acts, always,
with no setting that disables it.

**Ambient.** It reacts to the home and to the map without being asked. The doorbell rings and
it goes to the door. You have been in the brainstorm corner for twenty minutes and it settles
there quietly rather than following you. The laundry finishes and it mentions it. This is the
line between a creature and a command line with legs.

## 5. What it remembers

The semantic map is the product's real artifact, and it is four layers over one geometric
base:

Geometry, which it gets for free from ARKit — floor, walls, obstacles, reachable surface. No
teaching required and no semantics attached.

Places: user-named anchors with a radius. "My workspace," "the kitchen," "the reading chair."
The unit of navigation.

Objects: named points, optionally bound to a home device. "The coffee machine" is a position
*and* a switch, which is what makes *"turn that on"* resolvable by where you are looking.

Rules: constraints on behavior attached to regions. Forbidden zones ("don't touch this"),
quiet zones, perch preferences. Rules are hard constraints on pathing and behavior selection,
not prompt suggestions — a forbidden zone is subtracted from the navmesh, so it cannot be
violated by a model that decides to.

Activities and history: what the user does where, and what has happened there. "This is where
I brainstorm" plus the observation that it is 9pm and you are pacing is what changes the
bird's behavior from following to settling.

Everything in every layer is inspectable and editable by the user, and forgettable on demand.
A map you cannot audit is not something to put a door lock behind.

## 6. Scope

### v0.1 — Foundation (landed)
Character in the room over a navmesh, local model via `agentd`, WebSocket protocol, device
tools, confirmation gating, ambient events, resume-on-reconnect. Placeholder capsule body.

### v0.2 — The bird
The actual avatar: low-poly primitive-built bird, procedurally animated, with a face that
carries expression. Hop locomotion, idle behavior loops, look-at, emotional states driven by
agent state. This is the release where it stops being a capsule and starts being a creature.
See `spec/06-avatar.md`.

### v0.3 — Teaching
The five teaching acts, gaze-plus-speech capture, the semantic map store with persistence
across sessions, forbidden zones subtracted from the navmesh, a map inspector, and per-item
forgetting. See `spec/07-memory.md`.

### v0.4 — Learned behavior
Curiosity questions with a rate budget, activity inference, behavior selection driven by the
map, and object-to-device binding with deixis ("turn *that* off" resolved by gaze). Mood and
affinity that accumulate across sessions.

### v0.5 — Home depth
Full tool surface over the macOS companion, ambient sources beyond device diffs, multi-room
maps.

### Explicitly out of scope
Cloud inference. Shared multi-user sessions. A character customization editor beyond a color.
Non-Apple ecosystems. Any monetization surface. Any pre-seeded map of the user's home.

## 7. Success criteria

Presence, unchanged and non-negotiable: feet on a detected floor plane at all times, never
inside geometry, never mid-air. One occurrence destroys the illusion for the rest of the
session.

Reaction: under 400ms from end of utterance to first visible bird motion. It reacts before it
knows the answer, the way a person starts turning toward you mid-sentence.

Teaching: a first-time user teaches their first place within two minutes of hatching, with no
instructions beyond what the bird does. Every teaching act is acknowledged with motion, not
with text alone.

Learning is legible: after five teaching acts, a user asked what the bird knows can answer
correctly by watching it, without opening the inspector.

Safety is binary: no unsafe device action ever executes without explicit confirmation, and a
forbidden zone is never entered — not rarely, never, because it is a navmesh property rather
than a policy the model is asked to respect.

Retention, the honest bar for a Tamagotchi: a user who taught it something on day 1 opens it
again on day 3. If they do not, the memory is not paying for itself.

## 8. Constraints

90fps shared with scene mesh and passthrough. The bird is primitive-built and procedurally
animated specifically to leave that budget alone: no skinned mesh, no imported rig, ~15
primitives under one hierarchy.

Vision Pro cannot reach localhost, so the Mac must be LAN-discoverable (`docs/architecture.md`
§2). HomeKit authorization lives on the Mac companion.

Model latency is whatever the user's hardware gives. Behavior degrades into "thinking" —
visibly, in the body — never into a freeze.

The map is on-device. Abstracted place names and bounds may reach `agentd`; coordinates,
camera frames, and reconstructions do not.

## 9. Risks

The bird reading as cheap is the biggest product risk and it is animation quality, not code.
Primitives buy a frame budget, not charm; charm is easing curves, anticipation, squash, head
lag, and blink timing. Budget real time for it and judge it on the headset, not in a preview.

Teaching friction is the second. If naming a place takes more than one sentence or fails
silently, the map stays empty and every feature downstream of it is dead. The teaching path
gets the most testing of anything in v0.3.

Curiosity becoming nagging is third. An agent that asks "what's this?" four times an hour is
uninstalled. The rate budget is a product requirement, not a tuning parameter.

Trust is fourth and unchanged: one wrong physical action and nothing gets a second chance with
a door lock.

## 10. Specs

`spec/06-avatar.md` covers the bird. `spec/07-memory.md` covers the semantic map and teaching.
`docs/development-plan.md` is the build order. Existing specs 01–05 stand, with 01 superseded
by 06 for anything body-related.

# SpatialAgent Architecture

## 1. Target shape

```
SpatialAgent/
  apps/
    SpatialAgent/            visionOS app (thin: scenes, views, entry point only)
    SpatialAgentMac/         macOS companion (menu-bar app; hosts/bridges the local server)
  packages/
    AgentKit/                agent loop, tool-calling protocol, transcript state
    AgentTransport/          networking: discovery, WebSocket/HTTP client, reconnect, codecs
    AgentProtocol/           JSON Schema + generated Swift and Python wire types
    CharacterKit/            RealityKit entity, animation state machine, locomotion, gaze/IK
    SceneUnderstanding/      ARKit plane/mesh anchors -> navigable floor + placement rules
    HomeBridge/              HomeKit/Matter device model + intent execution
    DesignSystem/            shared SwiftUI components, ornaments, materials
  services/
    agentd/                  Python: agent loop, tool dispatch, model adapters
      mocks/                 fake headset CLI, scenario fixtures, mock smart home
      tests/                 pytest — runs headless on Linux CI
  docs/
```

Rule that keeps this maintainable: **`apps/` contains no logic.** Every behavior lives in a
package with its own tests and a `#Preview`/CLI harness that runs without a headset. The
visionOS simulator is the slowest feedback loop you have; keep it off the critical path.

`AgentProtocol` is the single most important package. It is pure Swift, no RealityKit, no
UIKit, no third-party deps, and both the visionOS app and the Mac companion depend on it.
That one constraint is what stops the client and server drifting apart.

## 2. The localhost connection — what you actually need

Four separate problems, often conflated:

### 2a. Transport
Vision Pro cannot reach `localhost`. It is a separate device on the LAN. So the Mac binds
`0.0.0.0:11434` (or your own port) and the headset connects to the Mac's LAN IP.

Use **WebSocket**, not plain HTTP. Reasons: the agent streams tokens; the character must
start its "thinking" animation on the first token, not after the last; and you need the
server to push events *to* the headset unprompted (smart-home state changed, long task
finished). A request/response API cannot do that. Keep one persistent socket, multiplex
message types over it by a `type` discriminator.

Framing: newline-delimited JSON or length-prefixed. Define it once in `AgentProtocol`.

### 2b. Discovery
Do not hardcode an IP. It will change and you will lose an evening to it. Publish a
Bonjour/mDNS service from the Mac (`NWListener` + `NWListener.Service(name:type:)`,
type `_spatialagent._tcp`), browse for it on visionOS with `NWBrowser`. The headset then
finds the Mac automatically on the same Wi-Fi. Keep a manual "enter IP" field as a fallback
for conference Wi-Fi with mDNS blocked — you will need it at a demo.

### 2c. ATS / TLS
visionOS enforces App Transport Security. A plain `ws://192.168.x.x` connection is blocked
by default. Two options:
- Dev: add an ATS exception (`NSAllowsLocalNetworking` in Info.plist) — covers local-network
  hostnames and is the right dev-time choice.
- Later: self-signed cert on the Mac, pinned in the client. Only worth it if this ships.

Also required: the `NSLocalNetworkUsageDescription` key and the Bonjour service type in
`NSBonjourServices`, or discovery silently returns nothing.

### 2d. Model serving
`agentd` sits between the headset and the model. **Do not let the headset talk to Ollama
directly.** The headset should never know which model is running. `agentd` owns: prompt
construction, tool/function definitions, conversation memory, retries, and translating model
output into your own `AgentEvent` types. Swapping Ollama for vLLM, llama.cpp, or a cloud API
then touches one file on the Mac and zero files in the app.

**`agentd` is Python.** This is settled, and the reason is contributor access, not
technology: a Python middle layer means teammates without a Mac can build, run, and test the
entire agent brain — prompting, tool dispatch, memory, model swapping — on Linux or Windows,
with no Xcode, no headset, and no Apple developer account. That is the majority of the
interesting logic in this project. Restricting it to Swift would gate it behind hardware.

Stack: FastAPI + `websockets`, calling Ollama's `/api/chat` with `stream: true`. `uv` for
dependency management. Roughly 200 lines to first token.

The cost of choosing Python is that the wire types are no longer shared by the compiler.
Section 3a is how that cost gets paid down.

## 3. Wire protocol

### 3a. Schema is the source of truth, not either language

With a Swift client and a Python server, nothing stops the two definitions of a message from
drifting until something fails at runtime on a headset — the worst place to debug.

So neither language owns the protocol. `packages/AgentProtocol/schema/*.json` (JSON Schema)
owns it, and both sides are generated from it:

```
packages/AgentProtocol/
  schema/               *.json          <- hand-edited, the only place a field is defined
  swift/                Generated/      <- codegen, committed, never hand-edited
  python/agent_protocol/ models.py      <- codegen (datamodel-code-generator -> pydantic)
```

`make protocol` regenerates both. CI fails if regenerating produces a diff, so a schema
change that skips codegen cannot merge. Committing the generated files matters: a Swift
contributor must be able to open the project and build without installing Python, and a
Python contributor without installing Swift.

Pydantic on the server side is worth it beyond codegen — it validates every inbound message
at the socket boundary, so a malformed `sceneUpdate` becomes a clear 400-style error rather
than a `KeyError` three layers into the agent loop.

### 3b. Message types

Two enums, both `Codable`, both in `AgentProtocol`:

```
ClientMessage   -> .hello(deviceInfo)
                   .userUtterance(text, id)
                   .sceneUpdate(anchors, roomBounds)
                   .deviceStates([HomeDeviceState])
                   .toolResult(callID, payload)
                   .ping

ServerEvent     -> .ready(sessionID, capabilities)
                   .token(String)                  // stream into a speech bubble
                   .utteranceEnd(id)
                   .characterDirective(CharacterDirective)
                   .toolCall(id, name, args)
                   .error(code, message)
```

`CharacterDirective` is the key design decision: the model does **not** emit animation
names or coordinates. It emits intent — `.walkTo(.namedAnchor("kitchen"))`, `.lookAt(.user)`,
`.emote(.confused)`, `.point(at:)`. `CharacterKit` resolves intent into a path, a blend tree,
and a transform. If the LLM ever emits raw coordinates, a hallucinated number puts your
character inside a wall.

## 4. Character layer

`CharacterKit` should be a state machine, not a pile of `if`s:
`idle -> turning -> walking -> arriving -> speaking -> gesturing -> idle`. Locomotion
consumes a navmesh derived from ARKit's floor planes in `SceneUnderstanding`; every
`walkTo` is clamped to reachable floor, so the worst failure is the character standing
still rather than walking through your couch.

Load the rig as USDZ with baked animation libraries, drive it via
`AnimationPlaybackController` with crossfades. Budget: one skinned character, keep the
skeleton under ~80 joints, and watch the 90fps frame budget — visionOS gives you far less
headroom than an M-series Mac suggests.

Foot-sliding is the thing that will make it look cheap. Match locomotion speed to the walk
clip's root motion rather than picking a speed and hoping.

## 5. Smart home

`HomeBridge` exposes an abstract `AgentTool` list to `agentd` at connect time, so the model
learns what it can control at runtime rather than from a hardcoded prompt. Execution can run
either on-device via HomeKit or on the Mac — on-device is simpler because HomeKit
authorization already lives with the user's session.

Make every tool call **confirmable**. A model that unlocks a door because of a
misheard word is the failure mode worth designing against from the start. Classify tools as
safe/unsafe; unsafe ones route through a confirmation ornament before execution.

## 6. The mock layer (how non-Mac contributors work)

This is infrastructure, not a nice-to-have. Without it, every change to the agent brain
needs a headset to verify, and most of the team is blocked. Build it in week one, before the
character work.

Three pieces live in `services/agentd/mocks/`:

**`fake_headset.py`** — a CLI that opens a real WebSocket to a real `agentd` and pretends to
be Vision Pro. It sends `hello`, then reads typed user input and sends `userUtterance`, and
renders whatever comes back: tokens print as they stream, `characterDirective` prints as
`[character] walkTo(kitchen)`, `toolCall` prints and prompts for a fake result. A contributor
on Windows can hold a full conversation with the agent and watch the character *logic* run
in a terminal. The headset becomes a renderer for behavior that was already verified.

**`scenarios/*.yaml`** — recorded and hand-written fixtures of the world state the headset
would send: room layouts with named anchors (`kitchen`, `desk`, `couch`), floor planes, and
smart-home device lists. `fake_headset.py --scenario apartment.yaml` boots the agent into a
plausible room. This is also what makes `walkTo` testable — the agent's navigation intent can
be asserted against a known floor plan with no ARKit involved.

**`mock_home.py`** — an in-memory `HomeBridge` implementing the same tool list as the real
HomeKit one, with state you can inspect. Tool calls mutate a dict, and tests assert on it.

Two rules keep the mock honest:

1. The mock talks to `agentd` over the **real socket, with the real schema**. It is not a
   function-call shortcut past the transport. A mock that bypasses the wire stops catching
   wire bugs, which are exactly the bugs that only appear on-device.
2. Every scenario fixture is generated *or* validated against the same JSON Schema as live
   traffic, so a fixture cannot encode a message shape the client would never send.

Pytest then runs the whole agent loop headless in CI on Linux: scenario in, assert on the
sequence of `ServerEvent`s out. Character behavior becomes a unit test.

Recording is worth adding early too — the visionOS app writes its session's raw frames to a
`.jsonl` file, and `fake_headset.py --replay session.jsonl` plays them back into `agentd`.
A bug seen once in the headset becomes a fixture that reproduces it on anyone's laptop.

## 7. Build order

1. `AgentProtocol` schema + codegen for both languages + `make protocol` + the CI diff check.
2. `agentd` echo server + `fake_headset.py`, then real streaming Ollama tokens through it.
3. visionOS app: Bonjour discovery, connect, print tokens into a window.
4. `CharacterKit` with a placeholder capsule, driven by hardcoded directives.
5. Swap capsule for the rigged USDZ.
6. `SceneUnderstanding` floor detection -> real `walkTo`.
7. `HomeBridge` with one read-only tool, then one write tool with confirmation.

Steps 1–2 are the whole platform for everyone without a headset, which is why they come
first. Steps 3–6 are the only ones that require a Mac.

## 8. Two things worth deciding early

**Where does conversation state live?** Recommendation: on the Mac, in `agentd`. The headset
becomes stateless and reconnects cleanly mid-conversation after the inevitable sleep/wake.

**How much logic is allowed on the headset?** As little as possible, and the test is
concrete: if a behavior cannot be exercised by `fake_headset.py`, it is in the wrong place.
Rendering, hand/gaze input, ARKit anchors and animation blending belong on-device. Anything
that decides *what the character does* belongs in Python, where the whole team can reach it.

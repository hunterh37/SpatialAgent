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
    AgentProtocol/           shared Codable wire types (imported by visionOS AND macOS)
    CharacterKit/            RealityKit entity, animation state machine, locomotion, gaze/IK
    SceneUnderstanding/      ARKit plane/mesh anchors -> navigable floor + placement rules
    HomeBridge/              HomeKit/Matter device model + intent execution
    DesignSystem/            shared SwiftUI components, ornaments, materials
  services/
    agentd/                  local server (Python or Swift) in front of Ollama/vLLM
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

Simplest viable `agentd`: FastAPI + a WebSocket endpoint, calling Ollama's `/api/chat` with
`stream: true`. Roughly 200 lines. Write it in Python unless you want the Mac companion to
be a single Swift binary, which is a real argument — one language, shared `AgentProtocol`
via SwiftPM, no venv to explain to a teammate.

## 3. Wire protocol sketch

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

## 6. Build order

1. `AgentProtocol` + `agentd` echo server + a CLI client. No headset involved.
2. Stream real Ollama tokens through it.
3. visionOS app: Bonjour discovery, connect, print tokens into a window.
4. `CharacterKit` with a placeholder capsule, driven by hardcoded directives.
5. Swap capsule for the rigged USDZ.
6. `SceneUnderstanding` floor detection -> real `walkTo`.
7. `HomeBridge` with one read-only tool, then one write tool with confirmation.

Steps 1–2 are testable in a terminal, which is where you want to spend the debugging time.

## 7. Two things worth deciding early

**Where does conversation state live?** Recommendation: on the Mac, in `agentd`. The headset
becomes stateless and reconnects cleanly mid-conversation after the inevitable sleep/wake.

**Swift or Python for `agentd`?** Python is faster to start and has the better model-serving
ecosystem. Swift gives you one language and a literally shared protocol type, so a wire
change becomes a compile error instead of a runtime surprise. For a project whose main risk
is client/server drift, that argument is stronger than it first looks.

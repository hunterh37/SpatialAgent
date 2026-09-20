# What the middle layer still has to do

Written from the visionOS side, after building it. Everything here is work in `agentd`,
`packages/AgentProtocol/schema/`, or the Mac companion — nothing in this document is a
visionOS task. Each item states what the client already does, what it needs back, and what
breaks today without it.

The client is built to the protocol as it stands, so `agentd` as it exists today will drive
it end to end. The items below are what the client cannot reach *past* v0.1.

---

## 1. HomeKit is not available on visionOS — execution has to move to the Mac

**Blocking. Decide this before any more home work lands on either side.**

`docs/architecture.md` §5 says execution should run on-device "because HomeKit authorization
already lives with the user's session." That is true on iOS and macOS. The HomeKit framework
is not in the visionOS SDK, so the on-device option does not exist. `HomeKitBridge.swift` is
written and compiled out behind `#if canImport(HomeKit) && !os(visionOS)` — it is ready for
the Mac companion target and dead on the headset.

The client therefore ships `RemoteHomeProvider`, which holds the device list and the
confirmation gate but cannot execute. Today a `toolCall` for a real device returns
`ok: false` with `unavailableOnPlatform`.

What the middle layer needs to add:

- **A HomeKit executor in the Mac companion.** `HomeBridge` compiles for macOS already; the
  companion links it, runs `HMHomeManager`, and owns the user's Home authorization.
- **A server-side tool dispatch path** that routes an approved `toolCall` to that executor
  and returns the result, rather than expecting the headset to fulfil it.
- **A protocol addition** to carry the split. The current `toolResult` assumes the client
  executed. Two options, and the second is better:
  - client forwards an `executeTool` message after confirmation; or
  - the server executes directly and the client sends only a `confirmationResult`
    (`callId`, `approved: Bool`). The headset then never claims to have done something it
    did not do, and the client's job narrows to exactly what it is good for: asking a human.
- **Preserve the safety property.** Whatever the shape, the rule from spec/04-home.md must
  survive: the Mac executes, it does not decide. The client already enforces its own safety
  table independently (`ToolSafety.effective`) and will refuse to approve an `unsafe` call
  without a tap; the server must not have a path that acts on an `unsafe` tool it has not
  received an approval for. `AgentSessionTests.testServerAssertedSafeOnALockStillRequiresConfirmation`
  is the client half of that contract — the server needs the matching test.

Alternative worth costing before committing: talk Matter directly from the headset over the
LAN and skip HomeKit entirely. It removes the Mac from the physical-action path, which is
the trust-simplest outcome, but it means implementing commissioning and the fabric, which is
a much larger job than a macOS executor.

---

## 2. Ambient events — the whole fourth loop is missing from the protocol

PRD §4 names **Ambient** as one of the four core loops, and spec/04-home.md describes home
state pushing to the character unprompted, rate-limited and classified by interrupt level.
The schema has no message for it. There is no way to express "the doorbell rang" — the
server can only speak when spoken to.

Needed in `packages/AgentProtocol/schema/protocol.schema.json`, as a new `ServerEvent`:

```
ambientEvent -> { source: deviceId, kind: "doorbell"|"finished"|"sensor"|"stateChange",
                  interrupt: "now"|"passing"|"silent", text: String }
```

`interrupt` must be server-asserted and coarse. The client decides the rendering — `now`
takes the character to the door mid-conversation, `passing` waits for the next idle, `silent`
only updates state — but it should not be inferring urgency from a device id.

Also needed on the server: the rate limiter. A light group that flickers must not produce
twenty events. The client will render what it is sent.

Until this exists, the app is Presence + Address + Action only, and the PRD's stated
difference from "a command line with legs" is unimplemented on both sides.

---

## 3. Named places have no persistence path through the server

spec/05-scene.md: the user names a place by looking and speaking, and it persists per room
across sessions. The client implements the storage half — `NamedPlaceStore` persists
`PlaceRecord`s, and `ARKitSceneProvider.anchorPlace` creates the `WorldAnchor` that keeps
them positionally valid across sessions.

The protocol only moves places *upward*, inside `sceneUpdate`. There is no way for the server
to acknowledge a place, and more importantly no way for it to ask for one. The natural
interaction — the user says "turn off the kitchen light", the model has no `kitchen` — has no
expression. Today the client answers that case itself with
`UnresolvedReason.unknownPlace`, which is a correct fallback but means the model never learns
the room.

Needed:

- A `ServerEvent` for requesting a place be named, e.g.
  `requestPlace -> { name: String, prompt: String }`, so the character can ask "where's the
  kitchen?" as part of a conversation rather than as a client-side error string.
- Server-side memory of which places it has seen, keyed by session, so it stops asking.

---

## 4. Deixis: devices have no positions, so `point` half-works

`CharacterDirective` can carry `point` with a `deviceId`, and the resolver handles it — but
`devicePositions` is passed empty from `AgentSession`, so any device-targeted `point` or
`walkTo` resolves to `unknownDevice`. Only place-targeted directives work.

This is a v0.3 item (PRD §5: "turn *that* off" resolved by where you are looking) but the
gap is in the schema today: `Device` has `room` (a string) and no position. A device is a
physical object in the room and the character needs to be able to walk to it and point at it.

Needed: either a position on `Device`, supplied by the client once the user has placed it,
or — cleaner, and consistent with §3 — a device→place association the client resolves
locally. The second keeps coordinates out of the server entirely, which is the rule in
docs/architecture.md §3b. Recommend the second.

---

## 5. The 400ms reaction budget needs a server-side half

PRD §6: time from end of request to first character motion under 400ms. The client meets
this unilaterally — `AgentSession.send` puts the character into `thinking` on send, before
anything is transmitted (`testCharacterEntersThinkingOnSendNotOnFirstToken`).

But the interesting version of this is the server reacting *before* the model answers: an
immediate `characterDirective(lookAt: .user)` or `emote(.thinking)` on receipt of
`userUtterance`, ahead of the first token. `directives.py` currently derives directives from
matched text, which means they arrive with or after the answer.

Needed: `agentd` emits an acknowledgement directive on `userUtterance` receipt, synchronously,
before the model adapter is called. Cheap to add, and it is the difference between a
character that starts turning toward you mid-sentence and one that waits politely for the
model.

---

## 6. Reconnect must actually resume, and nothing proves it does

spec/03-protocol.md: session state lives on the server, so a reconnect resumes rather than
restarts. The client implements the reconnect (`WebSocketAgentChannel`, exponential backoff
0.25s→8s) and on reconnect replays `hello`, the scene snapshot and the device snapshot.

What is missing is any way for the client to say *which* session it is resuming. `hello`
carries `protocolVersion` and `client` and nothing else, so the server cannot distinguish a
reconnect from a new headset, and after a sleep/wake the conversation silently restarts.

Needed:

- `hello` gains an optional `sessionId`. The client stores the one it got from `ready` and
  offers it back.
- `ready` states whether the session was resumed or created, so the character can behave
  correctly — picking up mid-thought versus greeting you again are different behaviours.
- A pytest that kills and reopens the socket mid-conversation and asserts the transcript
  survived. `fake_headset.py` is the right place to drive it.

---

## 7. Speech input (v0.2) is a client job, but the protocol needs one field

Not blocking now. When speech lands, `userUtterance` will want an `isFinal` flag so partial
transcripts can stream and the character can begin reacting to a half-finished sentence.
Flagging it here so the schema change happens once rather than twice.

---

## 8. Smaller items

- **Port.** `agentd` defaults to 8787 (`__main__.py`); the client's Bonjour fallback now
  matches. The Bonjour service itself is not published yet — `agentd` needs to advertise
  `_spatialagent._tcp` on that port, or discovery finds nothing and every connection is
  manual. This is the single highest-value small item in this document.
- **`ping`/`pong`.** The client never sends `ping`. The server should state an idle timeout
  in `ready.capabilities` so the client knows the keepalive interval instead of guessing.
- **`ready.capabilities`.** Named in docs/architecture.md §3b and spec/03-protocol.md but not
  in the schema — `ready` carries only `sessionId`, `protocolVersion`, `model`. The client
  needs it to know what the server can actually do (ambient events? tool execution? speech?)
  rather than discovering by failure.
- **Codegen.** `make protocol` does not exist. The Swift types in
  `packages/Sources/AgentProtocol/Generated/WireTypes.swift` are hand-maintained and held to
  the schema by `AgentProtocolTests` asserting field-name spelling. That is a stopgap; the
  CI diff check described in docs/architecture.md §3a is what actually prevents drift.
- **Tool result shape.** `set_light` returns the new state dict. Worth fixing in the registry
  whether every tool returns the resulting device state, so the character can report what
  actually happened rather than "done".

# What the middle layer still has to do

Written from the visionOS side, after building it. Everything here is work in `agentd`,
`packages/AgentProtocol/schema/`, or the Mac companion.

**Status: phase 2 landed.** Items 2–7 and most of 8 are implemented; each section below now
states what shipped and what is left. Item 1 is half done — the protocol split and the
executor boundary exist, the HomeKit executor does not, because it needs a macOS target.

---

## 1. HomeKit is not available on visionOS — execution has to move to the Mac

**Partly done. The remaining half needs a macOS app target, not a protocol change.**

Shipped:

- **The protocol split**, in the shape this document recommended. `toolCall` carries
  `executedBy: "client" | "server"`. When it is `server`, the client answers with
  `confirmationResult { callId, approved }` and never sends a `toolResult` — it does not
  claim to have acted, because it did not.
- **A server-side dispatch path**: `agentd/executors.py` defines one boundary with two
  implementations. `ClientExecutor` waits for the headset's `toolResult`; `ServerExecutor`
  runs the call here against any `HomeExecutor`. `AGENTD_HOME=mock` wires in
  `mocks/mock_home.py` today.
- **The safety property, enforced once.** `ServerExecutor` will not execute an `unsafe` tool
  without an approval naming its `callId`; a timeout and a refusal both mean no action.
  Tests: `test_server_never_executes_unsafe_without_approval`,
  `test_declined_confirmation_does_not_execute` — the server half this document asked for,
  matching `AgentSessionTests.testServerAssertedSafeOnALockStillRequiresConfirmation`. The
  client keeps its own independent safety table; stricter still wins.

Left:

- **The macOS companion itself.** `HomeBridge` compiles for macOS; something has to link it,
  run `HMHomeManager`, own the Home authorization, and implement `HomeExecutor`. Nothing
  else in `agentd` changes when it does — that is what the boundary bought.
- The Matter-direct-from-headset alternative is still uncosted and still looks larger than a
  macOS executor.

---

## 2. Ambient events — done

`ambientEvent { source, kind, interrupt, text }` is in the schema, in both languages, and in
the client (`AgentSession.lastAmbient`; `now` speaks immediately, `passing` waits for idle,
`silent` only updates state).

`agentd/ambient.py` owns the two things the client cannot: classification (`interrupt` is
derived from `kind`, never from a device id) and the rate limiter — an 8s per-source
cooldown plus a 3-token global bucket, so a flickering light group produces one event, not
twenty. `diff_devices` turns consecutive `deviceStates` snapshots into candidates, which is
what makes the doorbell reach the character unprompted. `fake_headset`'s `/ring` drives it.

Left: real sources beyond device diffs (timers, "the laundry finished"), which arrive with
the macOS companion.

---

## 3. Named places — done on the server side

`requestPlace { name, prompt }` exists, and the model reaches it through an `ask_for_place`
tool rather than by emitting a string: it asks in character ("Where's the kitchen?") instead
of the client answering itself with `unknownPlace`. The session remembers what it has asked
(`Session.requested_places`) and stops asking; naming the place clears the memory, because
`update_scene` drops any place that now exists.

Left: persistence across sessions is still client-side only (`NamedPlaceStore`). The server
forgets on restart, which is correct for now — coordinates stay off the server.

---

## 4. Deixis: devices have no positions — unchanged, still v0.3

Still open, and the recommendation stands: a device→place association resolved on the client,
not a position on `Device`, so coordinates stay out of the server (docs/architecture.md §3b).
`AgentSession` still passes `devicePositions: [:]`.

---

## 5. The 400ms reaction budget — done

`Session.handle_utterance` yields `lookAt(user)` and `emote(thinking)` before the adapter is
consulted. Test: `test_character_reacts_before_model_output`. Both halves now react on send
rather than on first token.

---

## 6. Reconnect resumes — done

`hello` carries an optional `sessionId`; `ready` carries `resumed`. `SessionStore` keeps the
transcript for 30 minutes past a dropped socket, so a sleep/wake continues the conversation.
`AgentConnection` stores the id from `ready` and offers it back on every reconnect, and a
resumed session picks up attention rather than greeting the user again.

Tests: `test_reconnect_resumes_the_same_session` kills and reopens the socket mid-conversation
and asserts the transcript survived; `fake_headset --resume <id>` drives the same path by hand.

---

## 7. Speech input — protocol half done

`userUtterance.isFinal` exists on both sides. A partial transcript moves the character and is
deliberately not sent to the model (`test_partial_transcript_moves_the_character_but_not_the_model`).
The client work is still to come; the schema change has happened once.

---

## 8. Smaller items

- **Bonjour — done.** `agentd/discovery.py` advertises `_spatialagent._tcp` on the serving
  port with `model`, `protocolVersion` and `path` in TXT. `--no-bonjour` disables it. The
  client's `Info.plist` already lists the matching `NSBonjourServices` entry.
- **`ping`/`pong` — done.** `ready.capabilities.idleTimeoutSeconds` states the interval, so
  the client stops guessing. `ping` is answered before `hello`, since a keepalive is not a
  conversation.
- **`ready.capabilities` — done.** Carries `ambientEvents`, `toolExecution`, `requestPlace`,
  `speechInput`, `idleTimeoutSeconds`. A `ready` without it decodes to conservative defaults,
  so a v0.1 server still connects.
- **Codegen — partly done.** `make protocol` exists and runs `scripts/check_protocol.py`,
  which fails if any message type or field in the schema is missing from either language.
  That catches drift; it still does not write the types. Real generation
  (datamodel-code-generator for Python, a Swift emitter) remains phase 3.
- **Tool result shape — done.** Every mutating tool returns `{id, state}`, and the session
  merges that back into its device snapshot so the prompt and the character report what
  actually happened rather than "done".

## New in phase 2, not requested here

- **The agent loop actually loops.** A tool result now goes back through the model (up to
  `MAX_TOOL_ROUNDS`), so the character can report what it found instead of narrating a call
  it never saw the answer to.
- **A second real backend.** `adapters/openai_compat.py` covers llama.cpp's server, LM
  Studio and vLLM, including tool calls reassembled from streamed fragments. Proof that the
  adapter boundary holds.
- **Concurrent turns.** The socket reader and the agent loop run as separate tasks over one
  outbound queue, which is what lets a `toolResult`, a confirmation, or an ambient push
  arrive mid-turn.

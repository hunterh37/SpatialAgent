# Spec 03 — Protocol

Authoritative schema: `packages/AgentProtocol/schema/*.json`. Swift and Python types are
generated from it and committed. Hand-edited generated files are a CI failure.

## Transport
Single persistent WebSocket, headset → Mac, discovered via Bonjour `_spatialagent._tcp`.
Newline-delimited JSON. Reconnect with exponential backoff; session state lives on the
server, so a reconnect resumes rather than restarts.

## Client → Server
| Message | Payload | Notes |
|---|---|---|
| `hello` | device info, protocol version | First frame. Version mismatch closes the socket with a stated reason. |
| `userUtterance` | text, id | |
| `sceneUpdate` | anchors, room bounds, named places | Throttled; sent on meaningful change, not per frame. |
| `deviceStates` | device state array | Full snapshot on connect, deltas after. |
| `toolResult` | callID, payload or error | |
| `ping` | — | |

## Server → Client
| Message | Payload | Notes |
|---|---|---|
| `ready` | sessionID, capabilities | |
| `token` | string | Streamed. |
| `utteranceEnd` | id | |
| `characterDirective` | directive (spec 01) | Symbolic intent only. |
| `toolCall` | id, name, args, safety | Safety class is server-asserted and client-enforced. |
| `error` | code, message | Human-readable; the character speaks it. |

## Rules
- Unknown message types are ignored, not fatal — forward compatibility.
- The server never sends coordinates, animation names, or device-specific identifiers the
  client did not first supply.
- Every message validates against schema at the boundary on both ends.

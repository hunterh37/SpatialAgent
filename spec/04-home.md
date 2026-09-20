# Spec 04 — Home

## Model
Devices are abstracted away from HomeKit specifics into `Device { id, name, room, kind,
state, capabilities }`. `agentd` never sees a HomeKit type. Swapping in Matter or a hub
touches `HomeBridge` only.

## Tool surface
Tools are published to `agentd` at connect time, not hardcoded in a prompt — the model
learns the home it is in at runtime.

v0.1: `list_devices`, `get_device_state`, `set_light`.
v0.3: full capability coverage across lights, locks, thermostats, covers, scenes, sensors.

## Safety classification
Every tool is `safe` or `unsafe`, declared where the tool is defined, never inferred by the
model.

- `safe` — reads, and writes trivially reversible from where the user is sitting: lights,
  scenes, media, thermostat within a bounded range.
- `unsafe` — locks, doors, garage, alarm arm/disarm, anything affecting site security, and
  any write the user cannot undo by speaking the opposite sentence.

`unsafe` requires the confirmation flow in spec 02. The client enforces this independently of
what the server asserts; a compromised or hallucinating server cannot unlock a door.

## Execution
On-device via HomeKit, because authorization already lives with the user's session. Results
return as `toolResult`. Failures are surfaced in character, with the device named.

## Ambient events
Home state changes push to the character unprompted (doorbell, appliance finished, sensor
trip). Rate-limited and classified by interrupt level — a doorbell interrupts, a light
changing elsewhere does not.

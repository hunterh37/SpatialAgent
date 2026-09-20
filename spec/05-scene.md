# Spec 05 — Scene

## Inputs
ARKit plane detection and scene mesh. Floor planes become walkable surface; everything else
is obstacle.

## Navmesh
Derived from floor planes minus obstacle footprint, with a margin of ~15cm so the character
never grazes furniture. Rebuilt on meaningful scene change, not per frame. All paths are
clamped to it — this is what makes hallucinated navigation impossible rather than merely
unlikely.

## Named places
The user names locations by looking and speaking ("this is the kitchen"). A named place is an
anchor plus a radius, persisted per room across sessions via `WorldTrackingProvider` anchors.

`walkTo("kitchen")` resolves through this table. An unknown name is a clarifying question,
never a guess.

## Placement
On launch the character is placed on the nearest reachable floor point that is ≥1.0m from the
user, in view, and not inside geometry. If no such point exists, the app says so rather than
placing the character badly.

## Privacy
Scene mesh and anchors are sent to `agentd` in abstracted form — planes, bounds, named
places — never camera frames or raw reconstructions. Nothing leaves the LAN.

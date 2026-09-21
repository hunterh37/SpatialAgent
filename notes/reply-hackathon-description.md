# Spatial Agent — 300-word description

Spatial Agent is a visionOS app in which Larry, a small autonomous bird, lives in your actual
room. He is not a floating chat window. He perches, flies real routes through your space, and
builds a memory of where things are — and that memory is the product.

Two memories run side by side. The **map** remembers the room: where Larry eats, drinks, gets
petted, finds his toys, sleeps, and what he must stay off. Each landmark you place writes a
real ARKit world anchor plus a `Place` record, so a food bowl set down today is still in the
same corner of the same room after a quit-and-relaunch. Those coordinates never leave the
headset. The **profile** remembers the person and lives in a single JSON file on a paired Mac
that you can open, edit, export, or delete — memory you can audit by hand.

The seam between the two is what makes the demo land. Say "this is where you eat," and the
bowl is anchored; Larry flies to it. Later, say "you must be hungry" — an instruction that
names no landmark at all. `HabitMemory` resolves the *need* against a `PlaceKind` rather than
a name, so the destination is looked up out of the map at speak time. Larry answers, "the food
bowl — that's where I eat," and goes. Delete the bowl and the same prompt honestly returns
"I don't know where I eat yet — show me and I'll remember." Teaching him changes what he does.

Routes respect the room's constraints: the plant is a fragile rule the flight path dodges.
Landmarks are low-poly props you can see and pinch-drag, not debug spheres.

It runs with no Mac and no model: an on-device director places the preset room and plays the
beats through the same resolver a live directive takes.

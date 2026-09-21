Spatial Agent is a visionOS app in which Larry, a small autonomous bird, lives in your actual room. He perches, flies real routes through your space, and builds a memory of where things are.

# SpatialAgent

visionOS monorepo.

```
apps/SpatialAgent   visionOS app target
packages/           shared Swift packages
docs/               documentation
```

## Build

```
xcodegen generate --spec apps/SpatialAgent/project.yml
open apps/SpatialAgent/SpatialAgent.xcodeproj
```

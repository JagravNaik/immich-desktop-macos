# Immich macOS (native SwiftUI scaffold)

This directory contains an initial, monorepo-first scaffold for a native SwiftUI macOS app.

## What's included

- `ImmichMacApp` executable target (SwiftUI app shell).
- Modular Swift packages for:
  - `ImmichCore`
  - `ImmichAPI`
  - `ImmichPersistence`
  - `ImmichMedia`
  - `ImmichSync`

## Run locally

```bash
cd desktop-macos
swift run ImmichMacApp
```

The starter app currently supports basic server connectivity against `/api/server-info` and serves as a foundation for timeline and upload milestones.

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

The starter app now opens with a server verification screen, then a password login screen that uses Immich's `/api/auth/login` flow. After sign-in it shows the authenticated macOS scaffold, which is still a foundation for timeline and upload milestones rather than a full remote library implementation.

## Build a macOS `.app` bundle

```bash
cd desktop-macos
./scripts/build-app.sh
```

The bundle is created at `.build/app/ImmichMacApp.app`.

Useful options:

```bash
./scripts/build-app.sh --open
./scripts/build-app.sh --debug
./scripts/build-app.sh --output /tmp/immich-macos
```

# Immich macOS (native SwiftUI app)

This directory contains the native SwiftUI macOS app that lives directly inside the Immich monorepo.

## What's included

- `ImmichMacApp` executable target for the macOS Photos-style client.
- Modular Swift packages for:
  - `ImmichCore`
  - `ImmichAPI`
  - `ImmichPersistence`
  - `ImmichMedia`
  - `ImmichSync`
- A packaged app build script that produces `ImmichMacApp.app`.

## Run locally

```bash
cd desktop-macos
swift run ImmichMacApp
```

The app opens with server verification and sign-in, then presents the native macOS library experience with timeline browsing, hero-style viewer transitions, keyboard navigation, editing tools, collections surfaces, management sheets, and desktop-specific polish built on the shared SwiftPM modules in this directory.

## Developer notes

- [Map browser implementation notes](./docs/map-browser.md)

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

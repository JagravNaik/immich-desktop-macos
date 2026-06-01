# Immich macOS

A native SwiftUI macOS client for [Immich](https://immich.app/), designed to feel close to Apple Photos while using your self-hosted Immich server as the backend.

This repository is the standalone macOS desktop app split out of the Immich monorepo history. It keeps the native client focused on macOS app work: SwiftUI views, Immich API integration, local state, media loading, upload/download flows, and desktop-specific polish.

## Status

This is an experimental native desktop client, not an official Immich release. It is useful for developing and testing a Photos-style macOS experience against an existing Immich server, but it does not replace the Immich web or mobile apps yet.

## Highlights

- Native SwiftUI app targeting macOS 14 and newer.
- Immich server verification plus password, API key, and OAuth sign-in paths.
- Keychain-backed credential storage for access tokens and API keys.
- Photos-style library browsing with timeline buckets, month/year sections, grid zoom, keyboard navigation, multi-select, context menus, and hero-style viewer transitions.
- Media type surfaces for videos, Live Photos, panoramas, screenshots, imports, favorites, and recently deleted assets.
- Albums, people, memories, pinned albums, and collection browsing backed by Immich APIs.
- Smart search and metadata search modes for filename, description, OCR, date filters, camera metadata, tags, people, and location fields.
- Native MapKit browser for geotagged assets, including clustered places, selected-place preview grids, and defensive viewport handling for invalid coordinates and antimeridian-spanning libraries.
- Viewer tools for playback, Live Photo peek/playback, panorama viewing, metadata inspection, download/export, sharing, favoriting, trashing, and tag editing.
- Core Image editing pipeline with adjustment, filter, crop, save, and export flows.
- Upload queue with progress tracking and WebSocket-driven library updates.
- Management sheets for API keys, tags, tag assignment, and admin users.
- SwiftPM test coverage for API encoding, search behavior, timeline/media indexing, map selection, album operations, favorite/trash flows, and app state regressions.

## Requirements

- macOS 14 or newer.
- Xcode 16 or a Swift 6 toolchain available on `PATH`.
- A reachable Immich server.
- An Immich account, API key, or OAuth configuration supported by your server.

For the packaged `.app` build script, macOS command line tools must also provide `sips`, `iconutil`, `plutil`, and `codesign`.

## Quick Start

Clone the repository and run the app directly with SwiftPM:

```bash
git clone https://github.com/JagravNaik/immich-desktop-macos.git
cd immich-desktop-macos
swift run ImmichMacApp
```

On first launch, enter your Immich server URL, verify the connection, and sign in. The app stores reusable credentials in Keychain and remembers lightweight app preferences in `UserDefaults`.

## Build

Run the full test suite:

```bash
swift test
```

Build the executable only:

```bash
swift build -c release --product ImmichMacApp
```

Build a macOS `.app` bundle:

```bash
./scripts/build-app.sh
```

Useful bundle options:

```bash
./scripts/build-app.sh --debug
./scripts/build-app.sh --release
./scripts/build-app.sh --open
./scripts/build-app.sh --output /tmp/immich-macos
```

The bundle is created at `.build/app/ImmichMacApp.app` unless `--output` is provided. The script signs with an ad hoc identity by default; set `CODESIGN_IDENTITY` to use a development certificate:

```bash
CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build-app.sh
```

Packaging note: the bundle script uses the Immich logo asset when it is available in either the standalone repo or original monorepo layout. If the logo is not present, it still produces a signed app bundle with the default macOS app icon.

## Repository Layout

```text
Sources/
  ImmichMacApp/        SwiftUI app, navigation, state, viewer, editing, map, and management UI
  ImmichAPI/           Immich REST client and request/response handling
  ImmichCore/          Shared models and value types
  ImmichMedia/         Thumbnail and media loading helpers
  ImmichPersistence/   Local persistence helpers
  ImmichSync/          Upload queue primitives
Tests/
  ImmichAPITests/      API request and encoding tests
  ImmichMacAppTests/   App state and feature behavior tests
docs/
  map-browser.md       Map browser implementation and safety notes
scripts/
  build-app.sh         SwiftPM-to-.app packaging script
```

## Architecture

The app is intentionally package-first. `Package.swift` defines one executable target, `ImmichMacApp`, plus smaller library targets for API, core models, persistence, media, and sync. This keeps UI work isolated while still making the non-UI pieces testable.

`AppState` is the main app coordinator. It owns connection state, authentication, timeline loading, collection loading, search, uploads, downloads, sidebar selection, viewer selection, editing state, and management sheet state.

`ImmichAPIClient` is the boundary to the Immich server. It normalizes server URLs, attaches the appropriate auth headers for token or API-key sessions, performs timeline/search/collection requests, and handles upload/download endpoints.

The UI is mostly SwiftUI, with narrow AppKit bridges where macOS-specific behavior is useful:

- `MapBrowserView` embeds MapKit and keeps map viewport updates safe.
- `AssetInfoPanelController` owns a floating AppKit-style info panel.
- `AuthenticatedVideoPlayer` and Live Photo helpers handle media playback details.
- The build script creates a conventional `.app` bundle around the SwiftPM executable.

## Feature Notes

### Library and Sidebar

The sidebar mirrors a Photos-style organization: Library, Map, Collections, Albums, People, Memories, Media Types, Imports, Favorites, and Recently Deleted. Library browsing supports months, years, and all-photos modes, plus filters for photos/videos and date captured/date added sorting.

### Search

Search supports Immich smart search and metadata-backed modes. The toolbar search field can apply filters such as date ranges, city/state/country, camera make/model, tags, people, and media metadata. Recent searches are saved locally.

### Media Types

Videos, Live Photos, panoramas, and screenshots are indexed into dedicated sidebar sections. Screenshots use the Immich metadata search path so common screenshot filenames and PNG assets are included.

### Editing

The editing sidebar provides adjustment, filter, and crop flows backed by a Core Image pipeline. Edited images can be saved back through Immich replacement APIs or exported locally.

### Map

The native map browser loads server map markers, clusters nearby assets into places, shows a place list and preview grid, and opens selected map assets in the same viewer flow as the library. See [docs/map-browser.md](./docs/map-browser.md) for implementation details.

### Management

The app includes desktop management surfaces for API keys, tags, tag assignment, and admin users. These are intended to make common server-side organization tasks available without switching to the web app.

## Development Workflow

Before opening a pull request or pushing a behavior change, run:

```bash
swift test
```

For UI or packaging changes, also run:

```bash
./scripts/build-app.sh --open
```

When changing the map browser, pay special attention to invalid coordinates, very dense clusters, and libraries that span the international date line. The existing tests cover the most important viewport and selection regressions.

## Known Gaps

- No notarized release artifacts are published yet.
- The app bundle script still needs the Immich logo asset/path cleaned up for fully standalone packaging.
- Feature parity with Apple Photos is a work in progress; this repo is the native macOS client foundation, not a complete clone yet.
- Server compatibility depends on the Immich APIs used by this client. If a server endpoint changes, the app may need matching client updates.
- There is no embedded Immich server. You must run or connect to Immich separately.

## Related Documentation

- [Immich project](https://immich.app/)
- [Map browser implementation notes](./docs/map-browser.md)

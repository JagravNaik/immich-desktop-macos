# Immich macOS

A native SwiftUI macOS client for [Immich](https://immich.app/), designed to feel close to Apple Photos while using your self-hosted Immich server as the backend.

This repository is the standalone macOS desktop app split out of the Immich monorepo history. It keeps the native client focused on macOS app work: SwiftUI views, Immich API integration, local state, media loading, upload/download flows, and desktop-specific polish.

## Status

This is an experimental native desktop client, not an official Immich release. It is useful for developing and testing a Photos-style macOS experience against an existing Immich server, but it does not replace the Immich web or mobile apps yet.

## Immich API Compatibility

The client request and response contracts are audited against the [Immich v3.3.1 OpenAPI specification](https://github.com/immich-app/immich/blob/v3.3.1/open-api/immich-openapi-specs.json). Immich server APIs can change between releases.
The timeline bucket summary returns date-only bucket IDs, while `GET /timeline/bucket` expects a UTC-midnight ISO-8601 timestamp (`YYYY-MM-DDT00:00:00.000Z`). The client normalizes those IDs before requesting assets. Immich marks both timeline endpoints internal; recheck them when upgrading the server.
API tests cover the normalized request and a response fixture with Immich v3.3.1 timeline fields. This change was not exercised against a live Immich server.
Favorite, location, caption, and capture-date updates use Immich v3 `PATCH /assets/:id`; tests verify the request method and payload. No live server mutation was performed.

## Photos Parity Status

This is a Photos-style Immich client, not a full Photos replacement. Current workflows include timeline browsing with a Recent Days mosaic grouped by local capture day, albums, people and memory collections with manual slideshow playback, a MapKit places browser with point selection and place search for asset locations, editable captions and capture dates, basic still-image editing/export, local video trimming to a new file, local-file import, and macOS system sharing.

Major gaps remain: Smart Albums; people/pet review, rename, and merge; Memory soundtrack and personalization; location removal (unsupported by Immich v3); broader video editing; full Photos/camera import and export controls; Shared Album membership/comments; per-item permanent deletion; non-destructive edit history; and verified keyboard/VoiceOver parity. Immich does not expose an iCloud Shared Photo Library equivalent.

## Highlights

- Native SwiftUI app targeting macOS 14 and newer.
- Immich server verification plus password, API key, and OAuth sign-in paths.
- Keychain-backed credential storage for access tokens and API keys.
- Photos-style library browsing with timeline buckets, month/year sections, grid zoom, keyboard navigation, multi-select, context menus, and hero-style viewer transitions.
- Albums, people, memories, pinned albums, and collection browsing backed by Immich APIs.
- Smart search and metadata search for filenames, descriptions, and OCR, with Immich date, camera, location, media-type, and favorite filters.
- Native MapKit browser for geotagged assets, including clustered places, selected-place preview grids, and defensive viewport handling for invalid coordinates and antimeridian-spanning libraries.
- Viewer tools for playback, Live Photo peek/playback, panorama viewing, metadata inspection, download/export, sharing, favoriting, trashing, and tag editing.
- Photos-style editor: Adjust (Light, Color, Black & White, White Balance, Curves, Levels, Definition, Selective Color, Noise Reduction, Sharpen, Vignette, Retouch, Red-eye, Histogram), Photos' nine filters, and Crop with straighten, aspect presets, and flip. It also has undo/redo, Copy/Paste Edits, and hold-M compare. Crop, rotate, and flip are saved to Immich as non-destructive edits. Other adjustments are saved as a new photo or exported.
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
./scripts/build-app.sh --release --universal   # one binary for Apple silicon and Intel
./scripts/build-app.sh --output /tmp/immich-macos
```

The bundle is created at `.build/app/ImmichMacApp.app` unless `--output` is provided. The script signs with an ad hoc identity by default; set `CODESIGN_IDENTITY` to use a development certificate:
The packaging script uses SwiftPM's reported binary path, so configured scratch paths are honored.

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

Search supports Immich smart search and metadata-backed filename, description, and OCR modes. Filters map to Immich v3 fields: date range, city/country, camera make/model, media type, and favorite. Recent searches are saved locally.

### Media Types

Videos, Live Photos, panoramas, and screenshots are indexed into dedicated sidebar sections. Screenshots use the Immich metadata search path so common screenshot filenames and PNG assets are included.

### Editing

The image editor mirrors Photos for macOS and renders with Core Image. Crop, rotate, and flip are stored as Immich v3 non-destructive edits (`/assets/{id}/edits`), so they stay revertible. Revert to Original removes them. Immich cannot store tonal or color adjustments on an original, so those edits are uploaded as a new photo dated like the original, or exported. The video trim tool still exports a separate local file. See [docs/photos-reverse-engineering.md](./docs/photos-reverse-engineering.md#part-3--image-editor).

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
- [Apple Photos reverse-engineering notes and parity ledger](./docs/photos-reverse-engineering.md)

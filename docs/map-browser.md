# Map Browser

This note covers the native macOS map browser added to `desktop-macos` and the guardrails around its viewport logic.

## What it does

- Adds a top-level `Map` destination to the macOS sidebar.
- Loads Immich map markers from the server and groups them into place clusters for display.
- Renders those groups in a native `MKMapView`.
- Lets the user select a place, browse every asset at that location, and open any asset in the existing viewer flow.

## Main pieces

- `SidebarView.swift`
  - Registers the `Map` destination in the sidebar.
- `MainContentView.swift`
  - Routes the `Map` destination to `MapBrowserView`.
- `MapBrowserView.swift`
  - Hosts the map, place list, selected-place preview strip, and viewport safety logic.
- `AppState.swift`
  - Loads markers, filters invalid coordinates, and resolves a selected place into full asset details.
- `AppStateTests.swift`
  - Covers map marker loading, place selection, invalid-coordinate filtering, and antimeridian viewport math.

## Why the viewport logic is defensive

During implementation, several crashes traced back to `MKMapView.setRegion(...)` while SwiftUI was still resizing the embedded AppKit map host. There were two root causes to guard against:

1. Invalid or unstable regions
   - Marker payloads with invalid coordinates should never reach the map.
   - Libraries that span the international date line need wrapped longitude math instead of a naive west/east bounding box.

2. Timing during layout
   - `MKMapView` can defer region work through its internal `MKWhenSized` path.
   - Calling `setRegion` while the SwiftUI host is still in a resize/layout cycle can trigger repeated layout work and exceptions.

## Current safety rules

- `AppState.loadMapMarkers()` filters out non-finite or out-of-range coordinates.
- `MapViewportBuilder` normalizes latitude, longitude, and span values before they are handed to MapKit.
- Longitude fitting uses the minimal wrapped arc so antimeridian-spanning libraries stay valid.
- `PlacesMapView.Coordinator` defers viewport application until the `MKMapView` is attached to a window and has a meaningful size.
- The coordinator applies `regionThatFits(...)` and a final sanitization step before calling `setRegion`.

## Testing guidance

When touching the map browser, rerun:

```bash
cd desktop-macos
swift test
./scripts/build-app.sh --open
```

The most important regressions to watch for are:

- pin selection showing only one asset instead of the full place set
- sluggish dragging caused by too many live map updates
- crashes triggered by viewport changes on large or globally distributed libraries

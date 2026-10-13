# Map Browser

This note covers the native macOS map browser added to `desktop-macos` and the guardrails around its viewport logic.

## What it does

- Adds a top-level `Map` destination to the macOS sidebar.
- Loads geotagged Immich assets from the server and groups nearby markers.
- Offers Map, Satellite, and Grid modes. Grid displays lazy thumbnail sections grouped by city/state/country, with coordinate-based regional groups when place names are missing.
- Provides place search, native MapKit zoom controls, click-to-select previews, and double-click-to-zoom behavior.
- Keeps a selected place's full asset grid available through `Show All`; `Show on Map` returns a grid location to the map.
- The asset inspector can add or change an asset's coordinates by tapping a point or searching for a place in a MapKit editor; it saves coordinates with Immich v3 `PATCH /assets/:id`. Immich's v3 update schema requires latitude and longitude together and does not provide a nullable coordinate field for removing a location.

## REA reference and limits

REA statically inspected Photos 12.0 at `/System/Applications/Photos.app/Contents/MacOS/Photos` (SHA-256 `5510074af9f8da245060098f05691f30815b1cd50af88f3e9406276005a66585`; Evidence `ev_78a1ba1fb3cb25bca9b3427e3de6301695be9610278cb2a861e98375db5bf690`). The binary imports MapKit, GeoKit, and GeoServices; MapKit symbols include map-point/coordinate and map-rect conversions plus annotation-view types. This supports MapKit-backed mapping, not a reconstruction of Photos' private map layout, grouping rules, gestures, or animations.
The REA session had no Ghidra, Hopper, or IDA provider binding, so function-level control flow and runtime map behavior were unavailable. No private Photos library data was accessed.
A later, deeper pass on macOS 27.0.1 documents Photos' Places pipeline, clustering constants, animation timings, and location menu in [photos-reverse-engineering.md](./photos-reverse-engineering.md).

Apple's [Photos guide to finding items by location](https://support.apple.com/guide/photos/find-photos-and-videos-by-location/pht4c00b8ddc/mac) documents map browsing and Map, Satellite, and Grid modes. This app implements those documented interactions with public MapKit APIs; it does not call Photos' private APIs.

## Main pieces

- `SidebarView.swift`
  - Registers the `Map` destination in the sidebar.
- `MainContentView.swift`
  - Routes the `Map` destination to `MapBrowserView`.
- `MapBrowserView.swift`
  - Hosts map styles, the grouped location grid, the selected-place preview strip, and viewport safety logic.
- `AssetInfoInspector.swift` and `AssetLocationEditor.swift`
  - Show location metadata and map, let the user choose a point, then save the coordinate through `AppState`.
- `ImmichAPIClient.swift`
  - Sends v3 location changes with `PATCH /assets/:id`.
- `AppState.swift`
  - Loads markers, filters invalid coordinates, and resolves a selected place into full asset details.
- `AppStateTests.swift` and `URLSessionImmichAPIClientTests.swift`
  - Cover map marker loading, place selection and grouping, invalid-coordinate filtering, antimeridian viewport math, and the v3 location update request/state transition.

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

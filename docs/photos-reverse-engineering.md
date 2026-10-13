# Apple Photos Reverse-Engineering Notes

Reference notes for rebuilding Apple Photos on an Immich backend. Each claim is labeled by evidence type:

- **REA**: produced by REA (`rea-agents` 6.4.0) and cited by Evidence ID.
- **Static**: observed with ordinary shell tools (`ipsw class-dump`, `ipsw … disass`, static `lldb memory read`) against shipped binaries. These are observations, not REA Evidence.
- **Inference**: an analyst conclusion drawn from names, structure, or constants. Treat it as a design hint, not as proven behavior.

No Photos process was launched and no Photos library data was read. Nothing here comes from runtime observation.

## Target

| Item | Value |
| --- | --- |
| App | `/System/Applications/Photos.app`, Photos 12.0 (911.0.134) |
| OS | macOS 27.0.1 (26A434), arm64e |
| Executable SHA-256 | `5510074af9f8da245060098f05691f30815b1cd50af88f3e9406276005a66585` |
| Frameworks with the shared UI | `PhotosUICore`, `PhotosSwiftUICore`, `PhotosUIFoundation`, `PhotosUIPrivate`, `GridZero`, `Tungsten`, `UXKit` (all in the dyld shared cache) |

### REA Evidence

| Evidence | What it covers |
| --- | --- |
| `ev_78a1ba1fb3cb25bca9b3427e3de6301695be9610278cb2a861e98375db5bf690` | `inspect_macho`: Photos load commands, linked frameworks, 4,500 imported symbols |
| `ev_1742ba789f99b6048583acc88a6319cc7b05187205ab5ac3e182bc37422b909f` | `inspect_plist`: Info.plist (URL schemes `photos`, `photos-navigation`, `cloudphoto`; principal nib `MainMenu`) |
| `ev_cff712367c8b04af034e023ed30d8e6d96cb6bb3551e178b332b166833436b6b` | `decode_interface_builder`: 64 bundle nibs, including `IPXMetadataPlacesViewController.nib` |
| `ev_38cf5fa0e8de3e32d22655344a06f85b7794414d684fb48ca17161fd3dfbfbcb` | `decode_interface_builder`: `MainMenu.nib` (687 objects, 188 connections; nib SHA-256 `51b45216…449a`) |
| `ev_cb1f0a5ee573eb2b450d5c94645cd02e1dcbe9073b108fdc4ef07dbc9c2027ba` | `IPXPlace.loctable` (Places strings) |
| `ev_70c2a8efee32c34367dda14acfe84bd3df3e848eca859358ceb5937796606e1a` | `IPXMain.loctable` (2,098 English app strings) |
| `ev_dd1f88479e0ac1b7a1f041025f774c5e29aa60a92245009ee0032a85410270fa` | PhotosUICore `LemonadeLocalizable.loctable` (676 strings: sidebar and collections) |
| `ev_284a155d70ae1adf204bfb735bf75d3dad25d093a4612e3d6a280221512dbbcc` | PhotosUICore `PhotosUICore.loctable` (3,034 strings) |
| `ev_7ffa813639180f9a4c15e6327114a4f3bc8bf92b1cfe75d9d985759a077df962` | PhotosUICore `PXSmartAlbumStrings.loctable` |

### Limits

- REA's only available deep provider, Hopper, did not finish loading the 21 MB executable within REA's fixed 120 s startup deadline. Ghidra and IDA are not configured. As a result, no REA pseudocode exists. Function-level facts below come from static arm64 disassembly of short methods.
- Shared-cache frameworks are not standalone files, so REA could not open them. They were inspected with `ipsw` against `/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e`.
- REA's IB graph omits `NSArray` nodes. The menu order in Part 2 follows ascending archive object IDs, which only approximates the real order.

---

## Part 1 — Places / Map

### Layering (Static)

```
Photos executable (Mac, IPX*)
  IPXPlacesTabBarController           Map | Satellite | Grid tabs
    IPXMapBrowserController           Places browser, Nearby Photos toggle, transitions to viewer
    grid tab: IPXPhotosGridViewControllerPlacesConfiguration
  IPXEditorialMapWidget               Map card in album/memory "details" pages ("%ld Photos Nearby")
  IPXMetadataPlacesViewController     Info-panel location field + IPXMapKitSuggester (MKLocalSearchCompleter)
  IPXMapViewController (+Configuration, IPXMapGroupAnnotation, IPXMapThumbnailStackAnnotationView,
                        IPXMapPinAnnotationView, IPXMapAnnotationUpdatePlan, _IPXMapCoalescingBuffer)
  IPXChange/Remove/ResetAssetLocationAction, IPXLocationBadge, IPXMapUtils
PhotosUICore (shared with iOS, PX*)
  PXPlacesMapViewController → PXPlacesMapController → PXPlacesMapView (MKMapView subclass)
  PXPlacesMapPipeline = layout + updatePlan + renderer + selectionHandler
    layouts:   PXPlacesMapThumbnailClusterLayout, PXPlacesMapGeometricClusterLayout
    plan:      PXPlacesMapInPlaceUpdatePlan / PXPlacesMapLayoutDiffer / PXPlacesMapLayoutChange
    renderers: PXPlacesMapThumbnailRenderer (+PXPlacesPopoverImageFactory), PXPlacesMapPinRenderer
  PXPlacesMapFetchResultController, PXPlacesStore, PXPlacesPhotoAssetsStore, PXPlacesImageCache
  PXPlacesMapThumbnailLocationCurator (wraps PNLocationCurationWrapper)
  PXChange/Remove/RevertAssetLocationAction, PXAnnotatedLocation
MapKit: MKMapView, MKStandardMapConfiguration, MKImageryMapConfiguration, MKLocalSearch(Completer), MKMapItem
```

Evidence for the MapKit layer is the import list in REA `ev_78a1…`: `MKMapView`, `MKStandardMapConfiguration`, `MKImageryMapConfiguration`, `MKLocalSearch`, `MKLocalSearchCompleter`, `MKMapItem`, `MKPinAnnotationView`, `MKMapRect*` math, `MKMetersPerMapPointAtLatitude`, `GEOCity`, and the PX classes listed above.

### User-visible strings (REA `ev_cb1f…`, `ev_70c2…`, `ev_dd1f…`)

| Key | English |
| --- | --- |
| `IPXMapBrowserControllerTitle`, `IPXPlaceBrowserTabLabel` | Places |
| `IPXPlaceBrowserTypeMapTitle` / `…SatelliteTitle` / `…GridTitle` | Map / Satellite / Grid |
| `IPXPlacePhotoCountFormatString` | 1 Photo / %ld Photos |
| `IPXPlaceShowPhotosString` | Show Photo / Show All Photos |
| `IPXMapBrowserSecondaryToolbar{Show,Hide}NearbyButton` | Show Nearby Photos / Hide Nearby Photos |
| `IPXEditorialMapWidgetNearbyFormat` | %ld Photo(s) Nearby |
| `IPXChangeAssetLocationActionKey` (+`_Progress`, `_ProgressUndo`) | Assign Location / Assigning Location… / Undoing Assign Location… |
| `IPXRemoveAssetLocationActionKey` | Hide Location / Hiding Location… |
| `IPXResetAssetLocationActionKey` | Revert to Original Location |
| `IPXAssignLocationTo{Photos,Videos,Items}MenuItemTitleFormat` | Assign Location to %lu Photo(s)/Video(s)/Item(s) |
| `IPXLocationBadgeTooltip` | Location Set |
| `PXCollectionMapCollectionTitle`, `LemonadeMap*Title` | Map (a collection, a section header, and a quick-access button) |
| nib placeholder `tvD-E4-QZk.placeholderString` | Unknown Location |

### Places rendering pipeline (Static; behavior labeled where inferred)

- **Data source contract** (`PXPlacesGeotaggedItemDataSource`): `allItems`, `numberOfItems`, `findItemsInMapRect:`, `minimalEncompassingMapRect`. An item (`PXPlacesGeotaggable`) is a coordinate plus `compareTo:`. *Inference:* the data source keeps a spatial index so a viewport query costs proportional to the visible items.
- **Thumbnail pipeline.** From the disassembly of `+[PXPlacesMapPipelineFactory thumbnailPipelineForDataSource:…]`:
  1. `size = [[PXPlacesPopoverImageFactory sharedInstance] backgroundImageSizeForType:popoverImageType usingTraitCollection:…]`
  2. `layout = [[PXPlacesMapThumbnailClusterLayout alloc] initWithDataSource:]`, then `setHorizontalClusteringDistancePixels:size.width` and `setVerticalClusteringDistancePixels:size.height`.
  3. `[PXPlacesMapInPlaceUpdatePlan new]`, the thumbnail renderer, `[PXPlacesMapPassthroughSelectionHandler new]`, and `-[PXPlacesMapPipeline initWithLayout:updatePlan:renderer:selectionHandler:]`.

  **Points cluster in screen space exactly when their thumbnails would overlap.** The cluster threshold is the thumbnail size, not a geographic distance.
- **Incremental layout.** `PXPlacesMapThumbnailClusterLayout` has `_viewPortChangeTypeFrom:to:`, `_handlePanToViewPort:`, `_handleZoomInToViewPort:`, `_handleZoomOutToViewPort:`, `_handlePitchChangeToViewPort:`, and a clustering pass with `primaryLayoutGeotaggables:` and `maskToMapRect:`. *Inference:*
  - A pan clusters only the newly exposed area and keeps existing clusters stable.
  - Zooming in splits clusters and zooming out merges them.
  - The "primary" item, chosen by `geotaggablesSortDescriptors`, stays the visible cover so thumbnails don't flicker.
- **Antimeridian.** `-[PXPlacesMapViewPort viewPortsBySplitingAt180thMerdian]` splits the visible rect at the antimeridian before clustering.
- **Diffed updates.** `PXPlacesMapUpdatePlanResult` exposes `annotationsToAddImmediately`, `annotationsToRemoveImmediately`, `annotationsToRemoveAfterAnimationHasStarted`, `annotationsToRemoveAfterAnimationHasEnded`, `annotationsToRedraw`, `annotationsWithUpdatedIndex`, and add/remove sets for overlays. `PXPlacesMapLayoutDiffer` relates each source item to its target item, which is how a cluster animates into its children and back.
- **Animation timing** (Static, `PXPlacesMapController`): `_defaultAnimationDuration` = **0.3 s**, `_fadeInAnimationDuration` = **0.15 s**. The fade-out constant was not decoded. Annotation z-position comes from `_zPositionForAnnotationIndex:`.
- **Threading and throttling.** The controller has separate dispatch queues for pipelines, data sources, and execution context; a `_uiUpdateTimer`; a `_pendingDataSourceChanges` table; and `pipelineExecutionAllowed` / `mapViewIsVisible` flags. *Inference:* layout runs off the main thread, changes are coalesced, and work pauses while the map is hidden.
- **Thumbnail annotation** (`PXPlacesMapThumbnailAnnotationView`): a count label with a background image and a selectable style. It shows a placeholder first (`_updatePlaceholderImageIfNeeded`), then fetches without network access, then with network access (`_fetchImageWithNetworkAccessAllowed:`). Fetch, creation, and selection each have their own operation queue. The cover photo comes from `PXPlacesMapThumbnailLocationCurator`, which uses Photos' on-device `PNLocationCurationWrapper`.
- **Focus and fit.** `_mapRectForGeotaggablesFromPipeline:fitAdjusted:`, `_ensureMinimumSize:`, and `+mapRectWithMapViewSize:centeredOnCoordinate:visibleDistance:`. `mapRectForNearbyQueriesFromRect:atScale:targetViewSize:` supplies the rect for the Nearby query.
- **Open in Maps.** `+[PXPlacesMapController launchMapsAtCoordinate:withTitle:completionHandler:]`.
- **Places browser** (`IPXMapBrowserController`): `_nearbyPhotosToggleButton`, `isPlacesHome` (library-wide versus collection-scoped), `initiallyVisibleMapRect`, `MKMapConfiguration` swapping (`_assignCurrentMapConfiguration`), `didSelectGeotaggableItems:fromMapView:`, `_fetchHydratedAssetsForPlacesAssets:`, and animated hero transitions to the viewer (`itemsForAnimatedTransitionWithOperation:`, `targetFrameForTransitionItem:imageRect:cornerRadius:`).
- **Grid tab** (`IPXPhotosGridViewControllerPlacesConfiguration`): own section header and footer classes, `shouldPositionGridInitiallyAtBottom`, count shown in the toolbar.

### Mac map view controller constants (Static, from `IPXMapViewControllerConfiguration` disassembly)

This controller backs the Info panel, editorial cards, and pin dragging.

| Setting | default | thumbnail stack (style 1) | pin (style 2) |
| --- | --- | --- | --- |
| `annotationCoalescingEnabled` | NO | YES | YES |
| `coalescingSize` (pt) | 0×0 | **200×200** | **80×80** |
| `effectiveLocationClampSize` (pt) | 0×0 | 25×20 | 30×30 |
| `minimalEdgeInsets` (t,l,b,r) | 36,9,4,21 | 45,50,45,50 | 36,9,4,21 |

Configuration-independent values:

- `mapPaddingScaleFactor` = 1.2
- `minimumHorizontalMapSpanInMeters` = 5000
- `horizontalMapSpanInMetersForStreetLevelLocations` = 300

Coalescing is grid-based. Each `IPXMapGroupAnnotation` owns a `coalescingMapRect` cell, and its pin sits at an `effectiveLocation` (the centroid), clamped to `effectiveLocationClampMapRect`. The update plan can coalesce fully or only inside the visible window (`_planForWindowedCoalescing…`). Each plan carries add, remove, remove-at-animation-start, remove-at-animation-end, and redraw sets, plus a `replaceAnnotation:withAnnotation:` operation that animates a stack splitting or merging. Pins can be dragged; the drop runs `IPXChangeAssetLocationAction`.

### Location editing (REA `ev_cff7…`, `ev_38cf…`)

- **Info-panel field** (`IPXMetadataPlacesViewController.nib`): a 280 pt-wide stack view (maximum height 264) containing:
  - a label container with an `IPXPlaceholderExpandingLayoutTextField` (placeholder "Unknown Location"; its delegate is the controller)
  - a search container
  - a cancelable progress indicator
  - an `IPXSuggestionsViewController` fed by `IPXMapKitSuggester` (completer and local suggestions)
- **Menu.** Image ▸ Location ▸ Copy Location (`a_copyLocation:`), Assign Location (`a_assignLocation:`), Hide Location (`a_removeLocation:`), Revert to Original Location (`a_revertToOriginalLocation:`). Assigning location in bulk names the item count and type. Every action is undoable and reports progress.
- **Grid badge.** View ▸ Metadata ▸ Location toggles `IPXLocationBadge` ("Location Set").

### Immich mapping (Immich v3.3.1 OpenAPI)

| Photos | Immich | Notes |
| --- | --- | --- |
| Library map points | `GET /map/markers` (`isFavorite`, `isArchived`, `withPartners`, `withSharedAlbums`, `fileCreatedAfter/Before`) | used |
| Album-scoped map | `GET /albums/{id}/map-markers` | available |
| Place names | `GET /map/reverse-geocode?lat&lon` → `{city,state,country}` | available |
| Assign Location to N items | `PUT /assets` with `ids`, `latitude`, `longitude` | available |
| Adjust Date and Time (time zone) | `PUT /assets` with `dateTimeRelative`, `timeZone` | available |
| Hide Location / Revert to Original Location | — | not possible: `latitude`/`longitude` are not nullable and there is no "original location" endpoint |
| Curated cover thumbnail | — | approximate: favorite, then rating, then newest |

---

## Part 2 — Whole-app structure

### Information architecture (REA `ev_dd1f…`)

Photos 12 ("Lemonade") lays the library out as reorderable collections. Each one has a sidebar quick-access button and a section header:

- Date (Days), Months, Pinned, Albums, From My Mac
- People & Pets (People / Pets / Groups), Memories, Favorite Memories, Featured Photos
- Map, Trips/Events (Featured), Shared Albums, Shared Albums Activity
- Media Types, Utilities, Suggestions, Wallpaper Suggestions, Documents, Photos Challenge

Utilities contains Imports, Duplicates, Hidden, Recently Deleted, Screenshots, Documents, Receipts, Handwriting, Illustrations, QR Codes, and Maps (the last being a content category, not the Map view). Search uses the placeholders "Search your library…" and "Search this collection…".

### Menu bar (REA `ev_38cf…`; order approximate)

- **Photos:** About, Settings (⌘,), Erase Deleted Items, Services, Hide/Hide Others/Show All, Quit.
- **File:**
  - New Album (⌘N), New Folder, New Smart Album… (⌥⌘N), New Shared Album (⌃⌘N), New Memory Movie (⌥⇧⌘N)
  - Edit Smart Album…, Import… (⌘I), Import without Review… (⌥⌘I)
  - Export ▸ Export Photos… (⌘E) / Unmodified Original (⌥⌘E) / Slideshow / GIF / Frame / Memory
  - Share…, Create, Print… (⌘P), Play Slideshow
  - Show in Album, Show in All Photos, Show Referenced File in Finder, Consolidate…, Close (⌘W)
- **Edit:** Undo/Redo, Cut/Copy/Paste, Select Moment, Select All, Deselect All (⌥⌘A), Search (⌘F), Font ▸, Spelling ▸.
- **Image:**
  - Adjust Date and Time…, Location ▸, Save to Library
  - Rotate Left (⌘R) / Rotate Right (⌥⌘R), Flip Horizontal/Vertical, Auto Enhance, Show/Hide Edit Tools
  - Copy/Paste Edits, Revert to Original, Turn On Live Photo, Edit Title
  - Go to Container, Open Viewer, Start/Stop Playback, Make Album Cover (⌘K), Make Poster Frame, Save Video Frame as Photo
  - Favorite (.), Set Star Rating (⌥0–⌥5, ⌥] / ⌥[)
  - Add to ▸, Add to Shared Album, Add to Recent Album (⌃⌘A), Edit With ▸, Reprocess RAW, Use RAW as Original
  - Merge Duplicates (⌃⌘M), Duplicate (⌘D), Duplicate from Original, Show/Hide Photo (⌘L), Delete Photo, Remove All from Album
- **View:**
  - Show/Hide Explore View (⌥E), Show Thumbnails, Show Comments, Show Histogram
  - Metadata ▸ (Titles, Keywords, Edited, File Type, Favorite, Referenced File, Location, Star Rating, In Shared Library)
  - Show Face Names, Show Hidden Photo Album, Show Recently Viewed & Shared
  - Sort ▸ (Name, Date Added/Modified, Oldest/Newest First, Custom; Ascending/Descending), Arrange ▸, Filter By
  - Aspect Ratio Grid (⌥T), Show Screenshots, Show Shared With You, Include Other People, as List / as Album Cover
  - Zoom (Z), Zoom In/Out (⌘+ / ⌘−), Show Sidebar (⌃⌘S), Enter Full Screen (⌃⌘F)
- **Window:** Minimize, Zoom, Info (⌘I), Keyword Manager (⌘K), Project Options, Bring All to Front.
- **Help:** About Photos & Privacy, Photos Help, Keyboard Shortcuts, Photos Quick Tour.

### Mac-specific surfaces (bundle nibs, REA `ev_cff7…`)

- Smart album editor: condition rows of combo box, date, flash, popup, and text field views.
- Keywords manager and keyword token field.
- Metadata editors for title, caption, date, filename, places, and keywords.
- Adjust Date/Time sheet with a `GEOCityPicker` for choosing the time zone.
- Export sheet, export-failure window, import duplicate panel, and import error panel.
- Slideshow settings (music, advanced) and slideshow export.
- Memories browser, print controllers, library chooser, library repair/upgrade, and the What's New and welcome screens.
- Settings: General, iCloud, Shared Library.
- Viewer overlays: comments and likes, faces, badges, Visual Intelligence.

### Immich feasibility for the remaining parity work

- **Supported by Immich v3.3.1:**
  - star rating and favorite (`PUT /assets`)
  - Keywords, mapped to Immich tags
  - Hidden, mapped to `visibility: hidden` or `locked`
  - Duplicates and Merge Duplicates (`/duplicates`, `/duplicates/resolve`)
  - stacks (`/stacks`)
  - people merge and reassign (`/people/{id}/merge`, `/people/{id}/reassign`)
  - memories, shared links, and partners
  - place browsing (`/search/places`, `/search/cities`)
  - Smart Albums, as saved client-side `/search/metadata` queries
- **Not possible:** iCloud Shared Library, Photos print and project extensions, "Hide/Revert Location", and replacing an original after an edit. Photos' on-device curation scores, used for cover choices and Featured Photos, have no Immich equivalent.

---

## Part 3 — Image editor

### Evidence (REA)

| Evidence | What it covers |
| --- | --- |
| `ev_8543c2bc235efe3821a55b8bfe7a4e36b1af16521124882c26efd9d2e46186ae` | `IPXCCAdjustment.loctable`: Adjust slider titles |
| `ev_c1acf9ebe7d1eab7d9ef5801c9a17f019ee536f39ce9720ce1c82cb80f024894` | `IPXAdjustmentStrings.loctable`: B&W `offset*` options, crop fields |
| `ev_3219bcb915b5b58f10923609b722826e129c263ef236a683c237b1007c1661d6` | `IPXEffect.loctable`: the nine filters |
| `ev_70c2a8efee32c34367dda14acfe84bd3df3e848eca859358ceb5937796606e1a` | `IPXMain.loctable`: tool names, crop aspects, white balance modes, curves/levels channels, instructions |

The Photos executable (Static class dump) has a controller for each Adjust brick: `IPXCCAdjustmentStackController` (Light, Color, B&W, Definition, Noise Reduction, Sharpen, Vignette), `IPXWhiteBalanceBrickController`, `IPXCurvesBrickController`, `IPXLevelsBrickController` (with `IPXLevelsHistogramView`), `IPXSelectiveColorBrickController`, `IPXRetouchBrickController`, and `IPXRedEyeBrickController`. It also has crop classes (`IPXCropView`, `IPXCropThirdsLayer`, `IPXCropDragCornerLayer`, `IPXCropStraightenButton`, `IPXCropAspectRatioPicker`), filter classes (`IPXEffectStackController`), and undo classes (`IPXEditAdjustmentUndoRedo`, `IPXEditOperationUndoRedo`).

### What Photos shows

- **Adjust**, in Photos' order:
  - Light: master slider, then Options — Brilliance, Exposure, Highlights, Shadows, Brightness, Contrast, Black Point.
  - Color: master, then Saturation, Vibrance, Cast.
  - Black & White: master, then Intensity, Neutrals, Tone, Grain.
  - Retouch: brush Size. "Click & drag over spots to remove. Option-click to choose the source area."
  - Red-eye: Auto, plus "Click each red-eye to correct."
  - White Balance: Neutral Gray, Skin Tone, or Temperature/Tint, with eyedroppers and Warmth/Tint.
  - Curves and Levels: channels RGB/Red/Green/Blue; Levels adds Luminance.
  - Definition, Selective Color (six hues plus a custom eyedropper hue), Noise Reduction (Amount), Sharpen (Intensity, Edges, Falloff), Vignette (Strength, Radius, Softness).
  - Histogram.
  - Each brick has an enable checkbox, Reset, and sometimes AUTO.
- **Black & White sliders are offsets.** The keys are named `offsetStrength`, `offsetNeutralGamma`, `offsetTone`, and `offsetGrain`. Options sliders add to the master slider rather than replacing it.
- **Filters:** Original, Vivid, Vivid Warm, Vivid Cool, Dramatic, Dramatic Warm, Dramatic Cool, Mono, Silvertone, Noir.
- **Crop:**
  - Straighten.
  - Aspect: Freeform, Original, Square, 16:9, 4:5, 5:7, 4:3, 3:5, 3:2, Custom, each with landscape/portrait.
  - Flip, Auto ("Automatically straighten and crop"), Reset.
  - Perspective Horizontal/Vertical.

### How the clone maps it

- `Editing/PhotoAdjustments.swift` holds the model.
- `Editing/PhotoEditRenderer.swift` renders it with Core Image:
  - Light tone, Curves, Levels, Selective Color, and Cast share one 32³ color cube.
  - Auto Enhance maps `autoAdjustmentFilters` onto the sliders.
  - Crop ▸ Auto uses Vision horizon detection.
- `Editing/PhotoEditGeometry.swift` handles geometry. Straighten zooms to the largest corner-free rectangle.
- **Saving:**
  - **Crop, rotate, and flip are saved as Immich non-destructive edits** (`PUT/GET/DELETE /assets/{id}/edits`, Immich v3.3.1). Revert to Original deletes them.
  - Grids and the viewer request `edited=true` renditions.
  - The editor always starts from the unedited original plus the saved edits.
- **Limits:**
  - Immich stores only crop, rotate, and mirror. Light, color, filter, spot fixes, and straighten are saved as a new uploaded photo, or exported.
  - Not implemented: Perspective, Custom aspect, Live Photo/video adjustments, Portrait/depth, Clean Up (generative), Styles, editing extensions, and "Save as Default" adjustment sets.
  - Slider responses are Core Image approximations of Photos' private PAImaging/NeutrinoCore pipeline. Master-slider weights are design estimates.
  - The `edits` crop is assumed to use pixels of the rotated and mirrored image. The edits API calls are unit-tested but untested against a live server.

## Part 4 — Motion, trackpad, and Live Photos

All values come from static disassembly of the Photos 12 executable. They are not REA Evidence, because Hopper couldn't start inside REA's deadline. Addresses refer to the arm64e slice.

### Timing

- **Standard duration.** `+[IPXAnimationUtilities standardDuration]` = `IPXAnimationStandardDuration` (0.25) × `animationDragCoefficient` (1.0). `IPXAnimationEditDuration` is also 0.25. The registered `IPXAnimationDragCoefficient` default of 10 is the slow-motion debug multiplier; `animationDragCoefficient` returns a hard-coded 1.0.
- **Timing curve.** `+[IPXAnimationUtilities mediaTimingFunction]` uses `kCAMediaTimingFunctionEaseInEaseOut`.
- **Grid ⇄ viewer.** `IPXAssetTransitionController` initializes `_duration` to 0.25 and uses an ease-in-ease-out timing function.

### Physics

- **Spring (`IPXSpringAnimation`).** Driven by a `CADisplayLink`:

  `x(t) = (x₀ + v₀·amplitude·t)·e^(−stiffness·t/period)`

  It stops when x < 1e-6. Defaults are amplitude 1, period 1, stiffness 1.
- **Elastic scroll (`IPXElasticScrollAnimator`).**
  - Spring: amplitude 0.31, period 1.6, stiffness 20, initial velocity 100.
  - Trackpad scroll events only (`isTrackpadScrollEvent`): past an edge, content moves 1/stiffness = 1/20 of the delta. Mouse wheels clamp.
  - Velocity is smoothed as 0.4·new + 0.6·previous.
  - When the gesture or momentum phase ends while out of bounds, the spring returns to the edge.
- **Elastic pan (`IPXElasticPanGestureAnimator`).**
  - Springs: amplitude 0.31, period 0.5, stiffness 20, one per axis.
  - Same 1/20 rubber band.
  - On release, it springs back if out of bounds. Otherwise, if speed ≥ 40, it coasts with a quartic ease-out:
    - `K = 1000·viewToContentRatio`
    - `D = sign(v)·K·(|v|/4K)^(4/3)`
    - `T = min((|D|/K)^(1/4), 2 s)`
    - `offset = D·(1−(1−t/T)⁴)`
  - Velocity samples closer than 2 ms apart are ignored.

### Live Photos

- **Player.** `IPXViewerMediaController` owns a public `PHLivePhotoView`. `_startPlayingLivePhotoMedia` calls `startPlaybackWithStyle:1` (full), and `stopPlayingLivePhotoMedia` calls `stopPlayback`.
- **Force Touch.** `-pressureChangeWithEvent:`:
  - At `stage == 2`, if not dragging and the asset has a video complement, it starts playback and sets `_aboveDeepPressureThreshold`.
  - At `stage <= 1`, it stops playback.
  - So a Live Photo plays only while deep-pressed.
- **LIVE badge.**
  - The badge (`IPXLivePhotoBadge`) is a vibrancy view with a glyph, a "LIVE" label, and a progress indicator. `IPXBadgeTrackingView` adds a tracking area and an `NSPressGestureRecognizer` with minimum duration 0.
  - The badge expands on mouse-over (`_showMouseOverBadges:`) and collapses after 3 s (`_hideMouseOverBadgesAfterDelay:3.0`).
  - *Inference:* hovering the badge plays the Live Photo (the controller has a `_canPlayLivePhotoOnMouseOver` ivar). The tracking-delegate callbacks weren't disassembled.

### How the clone uses this

- `Motion/PhotosMotion.swift` and `Motion/PhotosFrameDriver.swift` implement the spring, rubber band, momentum, and velocity tracker.
- `ImmichMotion.Curves.photosStandard` provides the timing. The hero transition, page swipe, and structural UI animations use it.
- **Zoomed viewer:**
  - Two-finger trackpad scroll rubber-bands, and springs back with the scroll spring when the gesture or momentum ends.
  - Click-drag rubber-bands, then coasts with quartic momentum or springs back with the pan spring.
  - *Approximation:* spring-back starts at zero velocity. Photos seeds it with the smoothed release velocity, and how that velocity is scaled wasn't fully decoded.
- **Live Photos:**
  - `LivePhotoStore` downloads the Immich still and its motion video and builds a `PHLivePhoto` (`PHLivePhoto.request(withResourceFileURLs:…)`).
  - `LivePhotoPlayerView` plays it with `PHLivePhotoView` `.full`, so the blur-in and the settle back to the still are Apple's own.
  - If the pair can't be combined, for example when content identifiers are missing after transcoding, the viewer falls back to playing the motion video.
  - The LIVE badge expands on movement and collapses after 3 s. Hovering it plays; press-and-hold plays while held.
  - A Force Touch at stage 2 plays, and dropping to stage ≤ 1 stops.
- **Not reproduced:**
  - Live Photo effects (Loop, Bounce, Long Exposure). Immich doesn't store the playback variation.
  - Live Photo key-photo choice.
  - Grid pinch-zoom tile animations (`IPXTilingViewTileAnimator`).
  - Editor animation contexts.

## Part 5 — Library zoom levels (Years, Months, Days, All Photos)

Static disassembly of PhotosUICore in the dyld shared cache. The strings come from REA Evidence for `PhotosUICore.loctable`: `PXCuratedLibrary{Years,Months,Days,AllPhotos}ZoomLevelButtonTitle`.

### Values (Mac, regular size class)

- **Card insets.** `PXCuratedLibraryCardSectionBodyLayoutSpec` sets 52 pt horizontal insets on the Mac idiom. Its skimming-hint gradient is black at 10% alpha.
- **Card spacing.** `spacingBetweenYearCards` is 36 pt in the regular size class; compact sizes use 10–30 pt depending on orientation. `spacingBetweenMonthCards` is 24 pt regular and 8–24 pt compact.
- **`PXCuratedLibrarySettings` defaults:**
  - Year card aspect: `aspectRatioForRegularYears` 1.5; compact portrait 1.333.
  - Corner radius: 10 pt for years and months, 0 for days.
  - Days: interitem spacing 2, spacing between days 5, lateral margin 0. Months lateral margin is 22 pt on the other idiom.
  - Header gradients are 120 pt tall; the years header fades out at a −20 pt offset.
  - `useWideModularLayoutInYears` is NO, and `forcedNumberOfYearsColumn` is 0.
- **Year cards (`PXYearCardSectionBodyLayoutSpec`).** `multiColumnAspectRatio` is 1.0 in the regular size class and 1.5 in compact landscape.
- **Year columns (`-[PXYearsLayoutGenerator updateContentSize:…]`).**
  - In landscape: 3 columns from 9 years, 2 columns from 4 years, otherwise 1.
  - In portrait: 2 columns above 5 years.
  - A single column is narrowed so its height is at most 0.8 × the view height.
- **Months (`PXMonthsLayoutGenerator`).**
  - A modular layout with weighted cards (`weight`, `enableMonthHeroPromotion`), 1.5 and 1.0 aspects, and 2/3 + 1/3 splits.
  - Year chapter headers float (`PXCuratedLibraryChapterHeaderLayoutSpec`).
- **Skimming.** Year and month cards skim on hover (`PXCuratedLibrarySkimmingController`, `enableSkimmingInYears`).

### In the clone

- `Views/CuratedLibraryLayout.swift` holds the decoded metrics and pure layout rules. `Views/CuratedLibraryViews.swift` holds the cards, the Years view, and the Months view.
- Days restyles the existing day mosaic with Photos' Days values and an inline date/place header.
- The picker now reads Years | Months | Days | All Photos. A year card zooms to Months at that year, and a month card zooms to Days at that month.
- **Approximations:**
  - Photos weights months with curation scores; the clone uses photo counts. Hero promotion needs at least 1.5× the next-busiest month in the row, which is a design choice.
  - Key photos: favorite still first, then the middle landscape still.
  - Titles: the most common places, else the month name.
  - Chapter header font size and spacing are estimates.
  - Photos also splits a month into separate event cards (moments). The clone shows one card per month.

## Parity ledger

This ledger tracks Photos' feature surface: the MainMenu.nib selectors, the Lemonade sidebar, and the bundle nibs. Status values:

- **Done**: implemented and covered by tests.
- **Partial**: some behavior is missing; the Notes column says what.
- **Todo**: Immich can support it, but it is not built yet.
- **Not possible**: Immich v3 has no backing for it.

### Library and sidebar

| Photos | Status | Notes |
| --- | --- | --- |
| Library: Years / Months / All Photos, Recent Days | Done | Timeline buckets |
| Albums, folders, pinned albums | Partial | Albums and pins exist. Folders: Todo (no Immich concept; would need client-side grouping) |
| People & Pets | Partial | Browse exists. Rename and merge (`/people/{id}/merge`) and hide: Todo |
| Memories | Partial | Browse and slideshow exist. Soundtracks and Memory Movie creation: Todo |
| Map (Places) | Partial | See Part 1. Nearby Photos and the editorial map card: Todo |
| Media Types: Videos, Live Photos, Panoramas, Screenshots | Done | |
| Utilities: Favorites, Imports, Recently Deleted | Done | |
| Utilities: Duplicates + Merge Duplicates | Done | `GET /duplicates`, `POST /duplicates/resolve`; keeps Immich's suggested copy |
| Utilities: Hidden | Done | `visibility: hidden` through bulk update and metadata search |
| Utilities: Documents, Receipts, Handwriting, Illustrations, QR Codes | Todo | Approximate with Immich smart search (CLIP) queries |
| Shared Albums, activity, comments | Todo | Immich shared albums and activity API |
| Smart Albums (New/Edit Smart Album…) | Todo | Save `/search/metadata` filter sets client-side; the condition editor follows IPXSmartAlbumCondition* |
| Featured Photos, Suggestions, Wallpaper | Not possible | Depends on Photos' on-device curation |
| iCloud Shared Library | Not possible | |

### Image menu

| Photos | Status | Notes |
| --- | --- | --- |
| Adjust Date and Time… | Done | Bulk `dateTimeRelative` and `timeZone` |
| Location ▸ Copy / Paste / Assign Location | Done | |
| Location ▸ Hide Location, Revert to Original Location | Not possible | |
| Set Star Rating ⌥0–⌥5, Increment/Decrement ⌥] / ⌥[ | Partial | Writes work. The timeline API carries no rating, so badges reflect only edits made in this session |
| Show/Hide Photo ⌘L | Done | |
| Favorite (.) | Partial | Favoriting exists; the "." shortcut is missing |
| Rotate ⌘R/⌥⌘R, Flip, Revert to Original | Done | Immich non-destructive edits; work from the grid or the editor |
| Show Edit Tools, Adjust/Filters/Crop editor, Auto Enhance ⌘E, Copy/Paste Edits ⇧⌘C/⇧⌘V, Undo/Redo | Done | See Part 3. Pixel adjustments are saved as a new photo |
| Make Album Cover ⌘K | Todo | `PATCH /albums/{id}` `albumThumbnailAssetId` |
| Duplicate ⌘D | Todo | `POST /assets/copy` |
| Delete Photo, Remove All from Album | Partial | Trash exists; "Remove All" is missing |
| Edit Title | Partial | Caption exists; title has no Immich field |
| Make Poster Frame, Save Video Frame as Photo | Todo | Local frame export, then upload |
| Reprocess RAW, Use RAW as Original, Edit With ▸ | Not possible / Todo | Edit With could export, open, and re-import |

### File, View, and Window menus

| Photos | Status | Notes |
| --- | --- | --- |
| Import… / Import without Review | Partial | Local file import exists; review UI is missing |
| Export ▸ Photos / Unmodified Original / GIF / Slideshow | Partial | Original download exists |
| New Album / New Shared Album / New Memory Movie | Partial | New Album only |
| Play Slideshow, Print | Todo | |
| View ▸ Metadata ▸ Favorite / Location / Star Rating badges | Done | `@AppStorage`-backed grid badges |
| View ▸ Metadata ▸ Titles, Keywords, Edited, File Type | Todo | |
| View ▸ Show Sidebar ⌃⌘S | Done | SwiftUI `SidebarCommands` |
| View ▸ Sort, Filter By, Aspect Ratio Grid ⌥T, Zoom | Partial | Sort, filter, and zoom exist; no menu items; aspect grid toggle missing |
| Window ▸ Keyword Manager ⌘K | Partial | Tags sheet exists and should be re-skinned as Keyword Manager |
| Window ▸ Info ⌘I | Partial | Inspector exists; check the shortcut |
| Settings: General / iCloud / Shared Library | Todo / Not possible | |

### Places-specific work still to do

1. Nearby Photos toggle and editorial map card, built on `GET /albums/{id}/map-markers` and `/map/markers`.
2. Undo for location assignment.
3. `MKStandardMapConfiguration`/`MKImageryMapConfiguration` and pitch.
4. Places grid tab: start at the newest items and show the count in the toolbar.

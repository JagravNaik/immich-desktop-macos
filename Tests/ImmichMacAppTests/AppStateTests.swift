import XCTest
import AVFoundation
import CoreVideo
@testable import ImmichMacApp
import ImmichAPI
import ImmichCore
import MapKit

@MainActor
private final class NoOpWebSocketService: ImmichWebSocketServicing {
  weak var delegate: (any ImmichWebSocketDelegate)?

  func connect(server: ImmichServer, userSession: UserSession) {}
  func disconnect() {}
}

final class AppStateTests: XCTestCase {
  private static let defaultsKeys = [
    "immich.serverURL",
    "immich.email",
    "immich.authMethod",
    "immich.photoGridScaleIndex",
    "immich.dismissedReleaseVersionsByServer",
  ]
  private static let keychainAccounts = [
    "immich.password",
    "immich.apiKey",
  ]

  private static let testKeychainService = "app.immich.desktop.macos.tests"

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
    KeychainHelper.testServiceOverride = Self.testKeychainService
    Self.resetPersistentState()
  }

  override func tearDown() {
    Self.resetPersistentState()
    KeychainHelper.testServiceOverride = nil
    super.tearDown()
  }

  @MainActor
  func testSelectedItemResolvesDetachedSearchAndScreenshotResults() {
    let appState = AppState(apiClient: MockImmichAPIClient(), webSocketService: NoOpWebSocketService())
    let searchResult = makePhotoItem(id: "search-result")
    appState.searchResults = [searchResult]
    appState.selectedItemID = searchResult.id
    XCTAssertEqual(appState.selectedItem?.id, searchResult.id)

    let screenshotResult = makePhotoItem(id: "screenshot-result")
    appState.searchResults = []
    appState.screenshotItems = [screenshotResult]
    appState.selectedItemID = screenshotResult.id
    XCTAssertEqual(appState.selectedItem?.id, screenshotResult.id)
  }

  @MainActor
  func testWebSocketAssetUpdateRefreshesSelectedSearchCopy() {
    let appState = AppState(apiClient: MockImmichAPIClient(), webSocketService: NoOpWebSocketService())
    let staleItem = makePhotoItem(id: "shared-asset")
    appState.libraryItems = [staleItem]
    appState.searchResults = [staleItem]
    appState.selectedItemID = staleItem.id

    appState.webSocketDidReceiveAssetUpdate(assetJSON: [
      "id": staleItem.id,
      "type": "IMAGE",
      "originalFileName": "updated.jpg",
      "fileCreatedAt": "2026-05-06T10:00:00.000Z",
      "createdAt": "2026-05-07T10:00:00.000Z",
      "isFavorite": true,
      "width": 3000,
      "height": 2000,
    ])

    XCTAssertEqual(appState.libraryItems.first?.title, "updated.jpg")
    XCTAssertTrue(appState.libraryItems.first?.isFavorite == true)
    XCTAssertEqual(appState.searchResults.first?.title, "updated.jpg")
    XCTAssertTrue(appState.searchResults.first?.isFavorite == true)
    XCTAssertEqual(appState.selectedItem?.title, "updated.jpg")
    XCTAssertTrue(appState.selectedItem?.isFavorite == true)
  }

  @MainActor
  func testToggleFavoriteUpdatesVisibleCollectionsAndSyncsServer() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)
    let item = makePhotoItem(id: "asset-1", isFavorite: false)

    appState.libraryItems = [item]
    appState.activeAlbumItems = [item]
    appState.activePersonItems = [item]
    appState.mapSelectionItems = [item]
    appState.activeMemoryItems = [item]
    appState.searchResults = [item]
    appState.screenshotItems = [item]
    appState.trashedItems = [item]
    appState.rebuildLibrarySections()

    appState.toggleFavorite(for: item.id)

    XCTAssertTrue(appState.libraryItems[0].isFavorite)
    XCTAssertTrue(appState.activeAlbumItems[0].isFavorite)
    XCTAssertTrue(appState.activePersonItems[0].isFavorite)
    XCTAssertTrue(appState.mapSelectionItems[0].isFavorite)
    XCTAssertTrue(appState.activeMemoryItems[0].isFavorite)
    XCTAssertTrue(appState.searchResults[0].isFavorite)
    XCTAssertTrue(appState.screenshotItems[0].isFavorite)
    XCTAssertTrue(appState.trashedItems[0].isFavorite)
    XCTAssertEqual(appState.favoritesCount, 1)

    try await eventually {
      let updates = await apiClient.recordedFavoriteUpdates()
      return updates == [FavoriteUpdate(assetID: item.id, isFavorite: true)]
    }
  }

  @MainActor
  func testUpdateAssetLocationUpdatesVisibleCopiesAndMapAfterServerSuccess() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)
    let item = makePhotoItem(id: "located-asset")

    appState.libraryItems = [item]
    appState.searchResults = [item]
    appState.mapSelectionItems = [item]
    appState.mapMarkers = [
      MapMarker(id: item.id, latitude: 1, longitude: 2, city: "Old City", country: "Old Country")
    ]
    appState.selectedMapMarkerID = item.id

    try await appState.updateAssetLocation(itemID: item.id, latitude: 37.7749, longitude: -122.4194)

    XCTAssertEqual(appState.libraryItems.first?.latitude, 37.7749)
    XCTAssertEqual(appState.libraryItems.first?.longitude, -122.4194)
    XCTAssertEqual(appState.searchResults.first?.latitude, 37.7749)
    XCTAssertEqual(appState.mapMarkers, [
      MapMarker(id: item.id, latitude: 37.7749, longitude: -122.4194, city: nil, country: nil)
    ])
    XCTAssertNil(appState.selectedMapMarkerID)
    XCTAssertTrue(appState.mapSelectionItems.isEmpty)
    let updates = await apiClient.recordedLocationUpdates()
    XCTAssertEqual(updates, [
      LocationUpdate(assetID: item.id, latitude: 37.7749, longitude: -122.4194)
    ])
  }

  @MainActor
  func testAssignLocationToSeveralItemsUsesBulkUpdateAndReverseGeocodedPlace() async throws {
    let apiClient = MockImmichAPIClient()
    await apiClient.setReverseGeocodeResult([ReverseGeocodePlace(city: "Paris", state: "Île-de-France", country: "France")])
    let appState = try await makeSignedInState(apiClient: apiClient)
    let first = makePhotoItem(id: "bulk-1")
    let second = makePhotoItem(id: "bulk-2")
    appState.libraryItems = [first, second]

    try await appState.assignLocation(itemIDs: [first.id, second.id, first.id], latitude: 48.8584, longitude: 2.2945)

    XCTAssertEqual(appState.libraryItems.map(\.latitude), [48.8584, 48.8584])
    XCTAssertEqual(Set(appState.mapMarkers), [
      MapMarker(id: first.id, latitude: 48.8584, longitude: 2.2945, city: "Paris", country: "France", state: "Île-de-France"),
      MapMarker(id: second.id, latitude: 48.8584, longitude: 2.2945, city: "Paris", country: "France", state: "Île-de-France"),
    ])
    let bulkUpdates = await apiClient.recordedBulkLocationUpdates()
    XCTAssertEqual(bulkUpdates, [BulkLocationUpdate(assetIDs: [first.id, second.id], latitude: 48.8584, longitude: 2.2945)])
    let singleUpdates = await apiClient.recordedLocationUpdates()
    XCTAssertTrue(singleUpdates.isEmpty)
  }

  @MainActor
  func testCopyAndPasteLocationAssignsCopiedCoordinate() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)
    var source = makePhotoItem(id: "source")
    source.latitude = 35.6586
    source.longitude = 139.7454
    let target = makePhotoItem(id: "target")
    appState.libraryItems = [source, target]

    XCTAssertFalse(appState.copyLocation(from: [target.id]))
    XCTAssertTrue(appState.copyLocation(from: [target.id, source.id]))
    try await appState.pasteLocation(to: [target.id])

    XCTAssertEqual(appState.libraryItems.last?.latitude, 35.6586)
    let updates = await apiClient.recordedLocationUpdates()
    XCTAssertEqual(updates, [LocationUpdate(assetID: target.id, latitude: 35.6586, longitude: 139.7454)])
  }

  @MainActor
  func testSetRatingSendsBulkUpdateAndUpdatesCopies() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)
    let item = makePhotoItem(id: "rated")
    appState.libraryItems = [item]

    try await appState.setRating(7, for: [item.id])
    XCTAssertEqual(appState.libraryItems.first?.rating, 5)
    try await appState.adjustRating(by: -1, for: [item.id])
    XCTAssertEqual(appState.libraryItems.first?.rating, 4)
    try await appState.setRating(nil, for: [item.id])
    XCTAssertNil(appState.libraryItems.first?.rating)

    let calls = await apiClient.recordedBulkAssetUpdates()
    XCTAssertEqual(calls.map(\.update.rating), [.stars(5), .stars(4), AssetBulkUpdate.Rating.none])
  }

  @MainActor
  func testHideMovesItemsToHiddenAndShowRestoresThem() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)
    let item = makePhotoItem(id: "secret")
    appState.libraryItems = [item, makePhotoItem(id: "public")]
    appState.selectedItemIDs = [item.id]

    XCTAssertTrue(appState.hideCommandHides([item.id]))
    try await appState.setHidden(true, for: [item.id])
    XCTAssertEqual(appState.libraryItems.map(\.id), ["public"])
    XCTAssertEqual(appState.hiddenItems.map(\.id), [item.id])
    XCTAssertTrue(appState.selectedItemIDs.isEmpty)
    XCTAssertFalse(appState.hideCommandHides([item.id]))

    try await appState.setHidden(false, for: [item.id])
    XCTAssertTrue(appState.hiddenItems.isEmpty)
    XCTAssertEqual(Set(appState.libraryItems.map(\.id)), [item.id, "public"])

    let calls = await apiClient.recordedBulkAssetUpdates()
    XCTAssertEqual(calls.map(\.update.visibility), ["hidden", "timeline"])
  }

  @MainActor
  func testAdjustDateTimeShiftsItemsBySameOffset() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)
    let item = makePhotoItem(id: "dated")
    appState.libraryItems = [item]

    try await appState.adjustDateTime(for: [item.id], offsetMinutes: 90, timeZone: TimeZone(identifier: "Asia/Tokyo"))

    XCTAssertEqual(appState.libraryItems.first?.date, item.date.addingTimeInterval(90 * 60))
    let calls = await apiClient.recordedBulkAssetUpdates()
    XCTAssertEqual(calls, [BulkAssetUpdateCall(
      assetIDs: [item.id],
      update: AssetBulkUpdate(dateTimeRelativeMinutes: 90, timeZone: "Asia/Tokyo")
    )])
  }

  @MainActor
  func testMergeDuplicatesKeepsSuggestedCopyAndRemovesOthers() async throws {
    let apiClient = MockImmichAPIClient()
    let keep = makeRemoteAsset(id: "keep")
    let extra = makeRemoteAsset(id: "extra")
    let group = DuplicateGroup(id: "dup-1", assets: [extra, keep], suggestedKeepAssetIDs: ["keep"])
    await apiClient.setDuplicates([group, DuplicateGroup(id: "single", assets: [keep], suggestedKeepAssetIDs: [])])
    let appState = try await makeSignedInState(apiClient: apiClient)
    appState.libraryItems = [makePhotoItem(id: "keep"), makePhotoItem(id: "extra")]

    await appState.loadDuplicates()
    XCTAssertEqual(appState.duplicateGroups.map(\.id), ["dup-1"])
    XCTAssertEqual(group.suggestedTrashAssetIDs, ["extra"])

    try await appState.mergeDuplicates(appState.duplicateGroups)
    XCTAssertTrue(appState.duplicateGroups.isEmpty)
    XCTAssertEqual(appState.libraryItems.map(\.id), ["keep"])
    let resolved = await apiClient.recordedResolvedDuplicateGroups()
    XCTAssertEqual(resolved.map(\.id), ["dup-1"])
  }

  @MainActor
  func testSavingGeometryEditsWritesImmichEditsAndRevertRemovesThem() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)
    let item = makePhotoItem(id: "editable")
    appState.libraryItems = [item]
    appState.selectedItemID = item.id
    let store = ThumbnailStore()
    let pipeline = PhotoEditingPipeline()
    let image = NSImage(size: NSSize(width: 40, height: 30))
    image.lockFocus(); NSColor.gray.setFill(); NSRect(x: 0, y: 0, width: 40, height: 30).fill(); image.unlockFocus()
    pipeline.beginSession(original: image, adjustments: .init())

    pipeline.rotateRight()
    let saved = try await appState.saveGeometryEdits(pipeline: pipeline, thumbnailStore: store)

    XCTAssertTrue(saved)
    XCTAssertFalse(pipeline.hasUnsavedChanges)
    XCTAssertEqual(store.revision(for: item), 1)
    let edits = await apiClient.recordedAssetEdits(for: item.id)
    XCTAssertEqual(edits, [.rotate(degrees: 90)])

    try await appState.revertSavedEdits(itemID: item.id, thumbnailStore: store)
    let afterRevert = await apiClient.recordedAssetEdits(for: item.id)
    XCTAssertNil(afterRevert)
  }

  @MainActor
  func testSavingPixelAdjustmentsRequiresANewPhoto() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)
    let item = makePhotoItem(id: "tonal")
    appState.libraryItems = [item]
    appState.selectedItemID = item.id
    let pipeline = PhotoEditingPipeline()
    pipeline.beginSession(original: NSImage(size: NSSize(width: 10, height: 10)), adjustments: .init())
    pipeline.adjustments.light.exposure = 0.3

    let saved = try await appState.saveGeometryEdits(pipeline: pipeline, thumbnailStore: ThumbnailStore())
    XCTAssertFalse(saved)
    XCTAssertEqual(AppState.saveStrategy(for: pipeline), .newPhoto)
    let edits = await apiClient.recordedAssetEdits(for: item.id)
    XCTAssertNil(edits)
  }

  @MainActor
  func testQuickRotateFromGridComposesWithSavedEdits() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)
    let item = makePhotoItem(id: "quick")
    appState.libraryItems = [item]
    let store = ThumbnailStore()

    try await appState.applyQuickGeometry(to: [item.id], thumbnailStore: store) { $0.rotated(by: 1) }
    try await appState.applyQuickGeometry(to: [item.id], thumbnailStore: store) { $0.rotated(by: 1) }
    try await appState.applyQuickGeometry(to: [item.id], thumbnailStore: store) { var g = $0; g.flipHorizontal.toggle(); return g }

    let edits = await apiClient.recordedAssetEdits(for: item.id)
    XCTAssertEqual(edits, [.rotate(degrees: 180), .mirror(axis: "horizontal")])
    XCTAssertEqual(store.revision(for: item), 3)
  }

  @MainActor
  func testBeginEditingFailsGracefullyForUndecodableOriginal() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)
    let item = makePhotoItem(id: "broken")
    appState.libraryItems = [item]
    appState.selectedItemID = item.id
    let pipeline = PhotoEditingPipeline()

    await appState.beginEditingSession(pipeline: pipeline, fallbackImage: nil)

    XCTAssertEqual(appState.editingSessionState, .failed("This photo format can’t be edited."))
    XCTAssertFalse(pipeline.isSourceLoaded)
  }

  @MainActor
  func testUpdateAssetLocationLeavesStateUnchangedAfterServerFailure() async throws {
    let apiClient = MockImmichAPIClient()
    await apiClient.setLocationUpdateError(TestError.expectedFailure)
    let appState = try await makeSignedInState(apiClient: apiClient)
    let item = makePhotoItem(id: "location-failure")
    appState.libraryItems = [item]

    do {
      try await appState.updateAssetLocation(itemID: item.id, latitude: 48.8566, longitude: 2.3522)
      XCTFail("Expected the location update to fail.")
    } catch TestError.expectedFailure {
      // State must not claim the uncommitted server change.
    }

    XCTAssertNil(appState.libraryItems.first?.latitude)
    XCTAssertNil(appState.libraryItems.first?.longitude)
    XCTAssertTrue(appState.mapMarkers.isEmpty)
  }

  @MainActor
  func testUpdateAssetDateTimeMovesVisibleCopiesToNewTimelineMonth() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)
    let item = makePhotoItem(id: "dated-asset")
    let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-04-15T12:30:00Z"))
    appState.libraryItems = [item]
    appState.searchResults = [item]
    appState.rebuildLibrarySections()

    try await appState.updateAssetDateTime(itemID: item.id, date: date)

    XCTAssertEqual(appState.libraryItems.first?.date, date)
    XCTAssertEqual(appState.searchResults.first?.date, date)
    XCTAssertEqual(appState.libraryItems.first?.timeBucketKey, "2026-04-01")
    XCTAssertEqual(appState.librarySections.map(\.id), ["2026-04-01"])
    let updates = await apiClient.recordedDateTimeUpdates()
    XCTAssertEqual(updates, [DateTimeUpdate(assetID: item.id, date: date)])
  }

  @MainActor
  func testUpdateAssetDateTimeLeavesStateUnchangedAfterServerFailure() async throws {
    let apiClient = MockImmichAPIClient()
    await apiClient.setDateTimeUpdateError(TestError.expectedFailure)
    let appState = try await makeSignedInState(apiClient: apiClient)
    let item = makePhotoItem(id: "date-failure")
    let originalDate = item.date
    let originalBucket = item.timeBucketKey
    appState.libraryItems = [item]

    do {
      try await appState.updateAssetDateTime(
        itemID: item.id,
        date: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-04-15T12:30:00Z"))
      )
      XCTFail("Expected the date update to fail.")
    } catch TestError.expectedFailure {
      // State must not claim the uncommitted server change.
    }

    XCTAssertEqual(appState.libraryItems.first?.date, originalDate)
    XCTAssertEqual(appState.libraryItems.first?.timeBucketKey, originalBucket)
  }

  @MainActor
  func testToggleFavoriteRevertsOptimisticUpdateAfterFailure() async throws {
    let apiClient = MockImmichAPIClient()
    await apiClient.setFavoriteError(TestError.expectedFailure)
    let appState = try await makeSignedInState(apiClient: apiClient)
    let item = makePhotoItem(id: "asset-2", isFavorite: false)

    appState.libraryItems = [item]
    appState.activeAlbumItems = [item]
    appState.activePersonItems = [item]
    appState.mapSelectionItems = [item]
    appState.activeMemoryItems = [item]
    appState.searchResults = [item]
    appState.screenshotItems = [item]
    appState.trashedItems = [item]
    appState.rebuildLibrarySections()

    appState.toggleFavorite(for: item.id)

    XCTAssertTrue(appState.libraryItems[0].isFavorite)

    try await eventually {
      appState.libraryItems.first?.isFavorite == false
        && appState.activeAlbumItems.first?.isFavorite == false
        && appState.activePersonItems.first?.isFavorite == false
        && appState.mapSelectionItems.first?.isFavorite == false
        && appState.activeMemoryItems.first?.isFavorite == false
        && appState.searchResults.first?.isFavorite == false
        && appState.screenshotItems.first?.isFavorite == false
        && appState.trashedItems.first?.isFavorite == false
        && appState.favoritesCount == 0
    }
  }

  @MainActor
  func testLoadMapMarkersAndSelectMapMarkerCreatesMapSelectionItems() async throws {
    let apiClient = MockImmichAPIClient()
    let marker = MapMarker(
      id: "asset-map-1",
      latitude: 40.7128,
      longitude: -74.0060,
      city: "New York",
      country: "United States"
    )
    let secondMarker = MapMarker(
      id: "asset-map-2",
      latitude: 40.7128,
      longitude: -74.0060,
      city: "New York",
      country: "United States"
    )
    await apiClient.setMapMarkersResult([marker, secondMarker])
    await apiClient.setAssetDetail(
      AssetDetail(
        id: marker.id,
        type: "IMAGE",
        originalFileName: "nyc.jpg",
        localDateTime: Date(timeIntervalSince1970: 1_700_100_000),
        fileCreatedAt: nil,
        width: 4000,
        height: 3000,
        fileSizeInByte: 2_048,
        isFavorite: true,
        durationMilliseconds: nil,
        livePhotoVideoId: nil,
        exif: ExifInfo(
          make: nil,
          model: nil,
          fNumber: nil,
          focalLength: nil,
          iso: nil,
          exposureTime: nil,
          lensModel: nil,
          city: "New York",
          state: "NY",
          country: "United States",
          latitude: marker.latitude,
          longitude: marker.longitude,
          description: nil,
          rating: nil,
          dateTimeOriginal: nil
        ),
        tags: []
      ),
      for: marker.id
    )
    await apiClient.setAssetDetail(
      AssetDetail(
        id: secondMarker.id,
        type: "VIDEO",
        originalFileName: "nyc-video.mov",
        localDateTime: Date(timeIntervalSince1970: 1_700_200_000),
        fileCreatedAt: nil,
        width: 1920,
        height: 1080,
        fileSizeInByte: 4_096,
        isFavorite: false,
        durationMilliseconds: 8_000,
        livePhotoVideoId: nil,
        exif: ExifInfo(
          make: nil,
          model: nil,
          fNumber: nil,
          focalLength: nil,
          iso: nil,
          exposureTime: nil,
          lensModel: nil,
          city: "New York",
          state: "NY",
          country: "United States",
          latitude: secondMarker.latitude,
          longitude: secondMarker.longitude,
          description: nil,
          rating: nil,
          dateTimeOriginal: nil
        ),
        tags: []
      ),
      for: secondMarker.id
    )

    let appState = try await makeSignedInState(apiClient: apiClient)

    let loadError = await appState.loadMapMarkers()
    XCTAssertNil(loadError)
    XCTAssertEqual(appState.mapMarkers, [marker, secondMarker])

    let selectionError = await appState.selectMapMarker(marker, markers: [marker, secondMarker])
    XCTAssertNil(selectionError)
    XCTAssertEqual(appState.selectedMapMarkerID, marker.id)
    XCTAssertEqual(appState.mapSelectionItems.map(\.id), [secondMarker.id, marker.id])
    XCTAssertEqual(appState.selectedItemID, secondMarker.id)
    XCTAssertEqual(appState.mapSelectionItems.last?.title, "nyc.jpg")
    XCTAssertEqual(appState.mapSelectionItems.last?.city, "New York")
    XCTAssertEqual(appState.mapSelectionItems.last?.country, "United States")
    XCTAssertEqual(appState.selectedItem?.id, secondMarker.id)
    XCTAssertTrue(appState.mapSelectionItems.last?.isFavorite == true)
    XCTAssertTrue(appState.mapSelectionItems.first?.isVideo == true)
  }

  @MainActor
  func testLoadMapMarkersDropsInvalidCoordinates() async throws {
    let apiClient = MockImmichAPIClient()
    let validMarker = MapMarker(
      id: "asset-map-valid",
      latitude: 37.7749,
      longitude: -122.4194,
      city: "San Francisco",
      country: "United States"
    )
    let invalidLatitudeMarker = MapMarker(
      id: "asset-map-invalid-lat",
      latitude: 120.0,
      longitude: -122.4194,
      city: "Somewhere",
      country: "United States"
    )
    let invalidLongitudeMarker = MapMarker(
      id: "asset-map-invalid-lon",
      latitude: 37.7749,
      longitude: 220.0,
      city: "Somewhere",
      country: "United States"
    )
    await apiClient.setMapMarkersResult([validMarker, invalidLatitudeMarker, invalidLongitudeMarker])

    let appState = try await makeSignedInState(apiClient: apiClient)

    let loadError = await appState.loadMapMarkers()

    XCTAssertNil(loadError)
    XCTAssertEqual(appState.mapMarkers, [validMarker])
  }

  func testMapViewportBuilderWrapsLongitudeAcrossAntimeridian() {
    let leftMarker = MapMarker(
      id: "asset-map-left",
      latitude: 37.0,
      longitude: 179.4,
      city: "Fiji",
      country: "Fiji"
    )
    let rightMarker = MapMarker(
      id: "asset-map-right",
      latitude: 38.0,
      longitude: -179.6,
      city: "Samoa",
      country: "Samoa"
    )

    let region = MapViewportBuilder.region(containing: [leftMarker, rightMarker])

    XCTAssertNotNil(region)
    XCTAssertLessThan(region?.span.longitudeDelta ?? .infinity, 10)
    XCTAssertGreaterThan(abs(region?.center.longitude ?? 0), 170)
  }

  func testMapPlaceGroupingNormalizesNamedPlacesAndSeparatesUnnamedAreas() {
    let markers = [
      MapMarker(
        id: "new-york-1",
        latitude: 40.7128,
        longitude: -74.0060,
        city: " New York ",
        country: "United States",
        state: "NY"
      ),
      MapMarker(
        id: "new-york-2",
        latitude: 40.7130,
        longitude: -74.0062,
        city: "new york",
        country: "united states",
        state: "ny"
      ),
      MapMarker(
        id: "albany",
        latitude: 42.6526,
        longitude: -73.7562,
        city: "Albany",
        country: "United States",
        state: "NY"
      ),
      MapMarker(
        id: "san-francisco-1",
        latitude: 37.7749,
        longitude: -122.4194,
        city: nil,
        country: "United States",
        state: "California"
      ),
      MapMarker(
        id: "san-francisco-2",
        latitude: 37.7750,
        longitude: -122.4200,
        city: nil,
        country: "United States",
        state: "California"
      ),
      MapMarker(
        id: "los-angeles",
        latitude: 34.05,
        longitude: -118.25,
        city: nil,
        country: "United States",
        state: "California"
      ),
    ]

    let groups = MapPlaceGrouping.groups(from: markers)

    XCTAssertEqual(groups.count, 4)

    let newYork = groups.first { $0.markers.contains(where: { $0.id == "new-york-1" }) }
    XCTAssertEqual(Set(newYork?.markers.map(\.id) ?? []), Set(["new-york-1", "new-york-2"]))
    XCTAssertEqual(newYork?.title, "New York, NY, United States")

    let sanFrancisco = groups.first { $0.markers.contains(where: { $0.id == "san-francisco-1" }) }
    XCTAssertEqual(Set(sanFrancisco?.markers.map(\.id) ?? []), Set(["san-francisco-1", "san-francisco-2"]))
    XCTAssertTrue(sanFrancisco?.title.contains("California, United States") == true)

    let losAngeles = groups.first { $0.markers.contains(where: { $0.id == "los-angeles" }) }
    XCTAssertEqual(losAngeles?.markers.map(\.id), ["los-angeles"])
  }

  @MainActor
  func testPhotoGridZoomClampsAtBoundsAndPersistsScaleIndex() {
    let appState = AppState(apiClient: MockImmichAPIClient())

    appState.photoGridScaleIndex = 0
    appState.zoomOutPhotoGrid()
    XCTAssertEqual(appState.photoGridScaleIndex, 0)
    XCTAssertFalse(appState.canZoomOutPhotoGrid)

    for _ in 0..<20 {
      appState.zoomInPhotoGrid()
    }

    XCTAssertEqual(appState.photoGridScaleIndex, 6)
    XCTAssertFalse(appState.canZoomInPhotoGrid)
    XCTAssertEqual(UserDefaults.standard.integer(forKey: "immich.photoGridScaleIndex"), 6)
  }

  @MainActor
  func testRefreshVersionAnnouncementShowsForMajorOrMinorUpdate() async throws {
    let apiClient = MockImmichAPIClient()
    await apiClient.setVersionCheckState(VersionCheckState(checkedAt: nil, releaseVersion: "v1.133.0"))
    let appState = try await makeSignedInState(apiClient: apiClient)

    await appState.refreshVersionAnnouncement()

    XCTAssertTrue(appState.showVersionAnnouncement)
    XCTAssertEqual(appState.availableReleaseServerVersion, "1.132.0")
    XCTAssertEqual(appState.availableReleaseVersion, "v1.133.0")
  }

  @MainActor
  func testSelectionAndArrowNavigationFollowFilteredItems() {
    let appState = AppState(apiClient: MockImmichAPIClient())
    appState.libraryItems = [
      makePhotoItem(id: "asset-1", isFavorite: false),
      makePhotoItem(id: "asset-2", isFavorite: true),
      makePhotoItem(id: "asset-3", isFavorite: true),
    ]
    appState.sidebarSelection = .favorites

    appState.selectNextItem()
    XCTAssertEqual(appState.selectedItemID, "asset-2")

    appState.selectNextItem()
    XCTAssertEqual(appState.selectedItemID, "asset-3")

    appState.selectNextItem()
    XCTAssertEqual(appState.selectedItemID, "asset-2")

    appState.selectPreviousItem()
    XCTAssertEqual(appState.selectedItemID, "asset-2")
  }

  @MainActor
  func testToggleMultiSelectClearsSelectionWhenModeTurnsOff() {
    let appState = AppState(apiClient: MockImmichAPIClient())

    appState.toggleMultiSelect()
    appState.selectedItemIDs = ["asset-1", "asset-2"]
    XCTAssertTrue(appState.isMultiSelectMode)

    appState.toggleMultiSelect()

    XCTAssertFalse(appState.isMultiSelectMode)
    XCTAssertTrue(appState.selectedItemIDs.isEmpty)
  }

  @MainActor
  func testHandlePressureChangeStartsLivePhotoPeekForHoveredLivePhoto() {
    let appState = AppState(apiClient: MockImmichAPIClient())
    let livePhoto = makePhotoItem(id: "live-1", livePhotoVideoID: "video-1")
    appState.libraryItems = [livePhoto]
    appState.hoveredItemID = livePhoto.id

    appState.handlePressureChange(stage: 2, pressure: 0.9)

    XCTAssertEqual(appState.selectedItemID, livePhoto.id)
    XCTAssertTrue(appState.isViewingPhoto)
    XCTAssertTrue(appState.isViewingLivePhoto)
    XCTAssertTrue(appState.isPeeking)
  }

  // MARK: - Auth Flow Tests

  @MainActor
  func testSignOutResetsStateToLoginPhase() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)

    XCTAssertEqual(appState.appPhase, .library)
    XCTAssertNotNil(appState.currentSession)

    appState.signOut()

    XCTAssertEqual(appState.appPhase, .login)
    XCTAssertNil(appState.currentSession)
    XCTAssertTrue(appState.libraryItems.isEmpty)
    XCTAssertTrue(appState.albums.isEmpty)
    XCTAssertFalse(appState.isOAuthSession)
    XCTAssertTrue(appState.passwordText.isEmpty)
    XCTAssertTrue(appState.apiKeyText.isEmpty)
    XCTAssertFalse(appState.showVersionAnnouncement)
  }

  @MainActor
  func testChangeServerResetsToServerSetupPhase() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)

    appState.changeServer()

    XCTAssertEqual(appState.appPhase, .serverSetup)
    XCTAssertNil(appState.currentSession)
    XCTAssertTrue(appState.serverURLText.isEmpty)
    XCTAssertTrue(appState.emailText.isEmpty)
    XCTAssertTrue(appState.passwordText.isEmpty)
    XCTAssertTrue(appState.apiKeyText.isEmpty)
    XCTAssertNil(appState.connectedServerVersion)
    XCTAssertNil(appState.connectedServerDisplayURL)
    XCTAssertEqual(appState.statusText, "Enter your Immich server URL to continue.")
  }

  @MainActor
  func testConnectWithInvalidURLSetsStatusText() async {
    let appState = AppState(apiClient: MockImmichAPIClient())
    appState.serverURLText = "not-a-url"

    await appState.connect()

    XCTAssertEqual(appState.statusText, "Invalid server URL")
  }

  @MainActor
  func testSignInWithEmptyEmailSetsStatusText() async {
    let appState = AppState(
      apiClient: MockImmichAPIClient(),
      webSocketService: NoOpWebSocketService()
    )
    appState.serverURLText = "https://demo.example"
    await appState.connect()

    appState.emailText = ""
    appState.passwordText = "password"
    await appState.signIn()

    XCTAssertEqual(appState.statusText, "Enter your email address.")
    XCTAssertEqual(appState.appPhase, .login)
  }

  @MainActor
  func testSignInWithEmptyPasswordSetsStatusText() async {
    let appState = AppState(
      apiClient: MockImmichAPIClient(),
      webSocketService: NoOpWebSocketService()
    )
    appState.serverURLText = "https://demo.example"
    await appState.connect()

    appState.emailText = "test@example.com"
    appState.passwordText = ""
    await appState.signIn()

    XCTAssertEqual(appState.statusText, "Enter your password.")
    XCTAssertEqual(appState.appPhase, .login)
  }

  @MainActor
  func testSignInWithEmptyAPIKeySetsStatusText() async {
    let appState = AppState(
      apiClient: MockImmichAPIClient(),
      webSocketService: NoOpWebSocketService()
    )
    appState.serverURLText = "https://demo.example"
    await appState.connect()

    appState.apiKeyText = ""
    await appState.signInWithAPIKey()

    XCTAssertEqual(appState.statusText, "Enter an API key.")
    XCTAssertEqual(appState.appPhase, .login)
  }

  @MainActor
  func testPasswordSignInSucceeds() async {
    let appState = AppState(
      apiClient: MockImmichAPIClient(),
      webSocketService: NoOpWebSocketService()
    )
    appState.serverURLText = "https://demo.example"
    await appState.connect()

    appState.emailText = "demo@immich.app"
    appState.passwordText = "demo"
    await appState.signIn()

    XCTAssertEqual(appState.appPhase, .library)
    XCTAssertEqual(appState.currentSession?.userEmail, "demo@immich.app")
    XCTAssertEqual(appState.currentSession?.userName, "Test User")
  }

  // MARK: - Trash & Restore Tests

  @MainActor
  func testTrashItemRemovesFromAllCollections() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)
    let item = makePhotoItem(id: "trash-1")

    appState.libraryItems = [item]
    appState.activeAlbumItems = [item]
    appState.activePersonItems = [item]
    appState.rebuildLibrarySections()

    appState.trashItem("trash-1")

    XCTAssertTrue(appState.libraryItems.isEmpty)
    XCTAssertTrue(appState.activeAlbumItems.isEmpty)
    XCTAssertTrue(appState.activePersonItems.isEmpty)
  }

  @MainActor
  func testTrashSelectedItemDeselectsIt() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)
    let item1 = makePhotoItem(id: "keep-1")
    let item2 = makePhotoItem(id: "trash-2")

    appState.libraryItems = [item1, item2]
    appState.selectedItemID = "trash-2"
    appState.isViewingPhoto = true

    appState.trashItem("trash-2")

    XCTAssertNotEqual(appState.selectedItemID, "trash-2")
    XCTAssertFalse(appState.isViewingPhoto)
  }

  @MainActor
  func testRestoreItemMovesFromTrashToLibrary() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)
    let item = makePhotoItem(id: "restore-1")

    appState.trashedItems = [item]
    appState.libraryItems = []

    appState.restoreItem("restore-1")

    XCTAssertTrue(appState.trashedItems.isEmpty)
    XCTAssertEqual(appState.libraryItems.count, 1)
    XCTAssertEqual(appState.libraryItems.first?.id, "restore-1")
  }

  @MainActor
  func testEmptyTrashRemovesDeletedItemsOnlyAfterServerSuccess() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)
    let deletedItem = makePhotoItem(id: "empty-trash-item")
    let retainedItem = makePhotoItem(id: "retained-item")
    appState.trashedItems = [deletedItem]
    appState.searchResults = [deletedItem, retainedItem]
    appState.selectedItemID = deletedItem.id
    appState.isViewingPhoto = true

    try await appState.emptyTrash()

    XCTAssertTrue(appState.trashedItems.isEmpty)
    XCTAssertEqual(appState.searchResults.map(\.id), ["retained-item"])
    XCTAssertNil(appState.selectedItemID)
    XCTAssertFalse(appState.isViewingPhoto)
    XCTAssertFalse(appState.isEmptyingTrash)
  }

  @MainActor
  func testEmptyTrashRetainsItemsWhenServerFails() async throws {
    let apiClient = MockImmichAPIClient()
    await apiClient.setEmptyTrashError(TestError.expectedFailure)
    let appState = try await makeSignedInState(apiClient: apiClient)
    let item = makePhotoItem(id: "failed-empty-trash-item")
    appState.trashedItems = [item]

    do {
      try await appState.emptyTrash()
      XCTFail("Expected empty-trash request to fail")
    } catch TestError.expectedFailure {
    } catch {
      XCTFail("Unexpected empty-trash error: \(error)")
    }

    XCTAssertEqual(appState.trashedItems.map(\.id), [item.id])
    XCTAssertFalse(appState.isEmptyingTrash)
  }

  // MARK: - Album CRUD Tests

  @MainActor
  func testCreateAlbumInsertsAtFront() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)

    await appState.createAlbum(name: "Test Album", description: "A test")

    XCTAssertEqual(appState.albums.count, 1)
    XCTAssertEqual(appState.albums.first?.albumName, "Test Album")
  }

  @MainActor
  func testDeleteAlbumRemovesAndUnpins() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)

    await appState.createAlbum(name: "To Delete")
    let albumID = appState.albums.first!.id
    appState.pinnedAlbumIDs.insert(albumID)

    await appState.deleteAlbum(albumID)

    XCTAssertTrue(appState.albums.isEmpty)
    XCTAssertFalse(appState.pinnedAlbumIDs.contains(albumID))
  }

  @MainActor
  func testDeleteActiveAlbumNavigatesToAllAlbums() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)

    await appState.createAlbum(name: "Active Album")
    let albumID = appState.albums.first!.id
    appState.activeAlbumID = albumID
    appState.sidebarSelection = .album(id: albumID)

    await appState.deleteAlbum(albumID)

    XCTAssertNil(appState.activeAlbumID)
    XCTAssertTrue(appState.activeAlbumItems.isEmpty)
    XCTAssertEqual(appState.sidebarSelection, .allAlbums)
  }

  @MainActor
  func testRenameAlbumUpdatesName() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)

    await appState.createAlbum(name: "Old Name")
    let albumID = appState.albums.first!.id

    await appState.renameAlbum(albumID, newName: "New Name")

    XCTAssertEqual(appState.albums.first?.albumName, "New Name")
  }

  // MARK: - Multi-Select Tests

  @MainActor
  func testToggleItemSelectionAddsAndRemoves() {
    let appState = AppState(apiClient: MockImmichAPIClient())

    appState.toggleItemSelection("item-1")
    XCTAssertTrue(appState.selectedItemIDs.contains("item-1"))

    appState.toggleItemSelection("item-1")
    XCTAssertFalse(appState.selectedItemIDs.contains("item-1"))
  }

  @MainActor
  func testSelectAllItemsSelectsAllFilteredItems() {
    let appState = AppState(apiClient: MockImmichAPIClient())
    appState.libraryItems = [
      makePhotoItem(id: "a"),
      makePhotoItem(id: "b"),
      makePhotoItem(id: "c"),
    ]
    appState.sidebarSelection = .library

    appState.selectAllItems()

    XCTAssertEqual(appState.selectedItemIDs, ["a", "b", "c"])
    XCTAssertTrue(appState.allItemsSelected)
  }

  @MainActor
  func testDeselectAllItemsClearsSelection() {
    let appState = AppState(apiClient: MockImmichAPIClient())
    appState.selectedItemIDs = ["a", "b"]

    appState.deselectAllItems()

    XCTAssertTrue(appState.selectedItemIDs.isEmpty)
  }

  @MainActor
  func testBatchTrashRemovesAndClearsSelection() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)
    let keep = makePhotoItem(id: "keep", isFavorite: true)
    let trashA = makePhotoItem(id: "trash-a", isFavorite: true, isVideo: true)
    let trashB = makePhotoItem(id: "trash-b")
    appState.libraryItems = [keep, trashA, trashB]
    appState.activeAlbumItems = [trashA, trashB]
    appState.activePersonItems = [trashA, trashB]
    appState.mapSelectionItems = [trashA, trashB]
    appState.activeMemoryItems = [trashA, trashB]
    appState.searchResults = [trashA, trashB]
    appState.screenshotItems = [trashA, trashB]
    appState.trashedItems = [trashA, trashB]
    appState.selectedItemIDs = ["trash-a", "trash-b"]
    appState.isMultiSelectMode = true

    appState.batchTrash()

    XCTAssertEqual(appState.libraryItems.map(\.id), ["keep"])
    XCTAssertEqual(appState.favoritesCount, 1)
    XCTAssertEqual(appState.videosCount, 0)
    XCTAssertTrue(appState.activeAlbumItems.isEmpty)
    XCTAssertTrue(appState.activePersonItems.isEmpty)
    XCTAssertTrue(appState.mapSelectionItems.isEmpty)
    XCTAssertTrue(appState.activeMemoryItems.isEmpty)
    XCTAssertTrue(appState.searchResults.isEmpty)
    XCTAssertTrue(appState.screenshotItems.isEmpty)
    XCTAssertTrue(appState.trashedItems.isEmpty)
    XCTAssertTrue(appState.selectedItemIDs.isEmpty)
  }

  @MainActor
  func testTrashItemRemovesMapAndSearchCopiesAndAdvancesViewer() async throws {
    let appState = try await makeSignedInState(apiClient: MockImmichAPIClient())
    let deletedItem = makePhotoItem(id: "map-delete")
    let nextItem = makePhotoItem(id: "map-next")
    appState.sidebarSelection = .map
    appState.mapSelectionItems = [deletedItem, nextItem]
    appState.searchResults = [deletedItem]
    appState.selectedItemID = deletedItem.id
    appState.selectedItemIDs = [deletedItem.id]
    appState.isViewingPhoto = true

    appState.trashItem(deletedItem.id)

    XCTAssertEqual(appState.mapSelectionItems.map(\.id), [nextItem.id])
    XCTAssertTrue(appState.searchResults.isEmpty)
    XCTAssertEqual(appState.selectedItemID, nextItem.id)
    XCTAssertEqual(appState.selectedItem?.id, nextItem.id)
    XCTAssertFalse(appState.isViewingPhoto)
    XCTAssertFalse(appState.selectedItemIDs.contains(deletedItem.id))
  }

  @MainActor
  func testSetItemSelectionAddAndRemove() {
    let appState = AppState(apiClient: MockImmichAPIClient())

    appState.setItemSelection("item-1", isSelected: true)
    XCTAssertTrue(appState.selectedItemIDs.contains("item-1"))

    appState.setItemSelection("item-1", isSelected: false)
    XCTAssertFalse(appState.selectedItemIDs.contains("item-1"))
  }

  // MARK: - Search State Tests

  @MainActor
  func testPerformSearchEmptyQueryClearsResults() {
    let appState = AppState(apiClient: MockImmichAPIClient())
    appState.searchResults = [makePhotoItem(id: "old-result")]
    appState.isSearching = true
    appState.searchTotalCount = 5

    appState.performSearch(query: "")

    XCTAssertTrue(appState.searchResults.isEmpty)
    XCTAssertFalse(appState.isSearching)
    XCTAssertEqual(appState.searchTotalCount, 0)
    XCTAssertNil(appState.searchError)
  }

  @MainActor
  func testFilterOnlySmartSearchUsesMetadataEndpoint() async throws {
    let apiClient = MockImmichAPIClient()
    await apiClient.setSearchResult(
      SearchResult(
        assets: [makeRemoteAsset(id: "favorite-filter-result")],
        totalCount: 1
      )
    )
    let appState = try await makeSignedInState(apiClient: apiClient)
    var filters = SearchFilters()
    filters.isFavorite = true
    appState.searchType = .smart
    appState.searchFilters = filters

    appState.performSearch(query: "")

    try await eventually(timeout: .seconds(2)) {
      let calls = await apiClient.recordedSearchCalls()
      return calls == [SearchCall(kind: "filename", query: "", page: nil)]
    }
    XCTAssertEqual(appState.searchResults.map(\.id), ["favorite-filter-result"])
    XCTAssertNil(appState.searchError)
  }

  @MainActor
  func testResetSearchStateClearsAll() {
    let appState = AppState(apiClient: MockImmichAPIClient())
    appState.searchResults = [makePhotoItem(id: "r")]
    appState.isSearching = true
    appState.searchTotalCount = 10
    appState.searchError = "Something"
    appState.searchNextPage = "next"

    appState.resetSearchState()

    XCTAssertTrue(appState.searchResults.isEmpty)
    XCTAssertFalse(appState.isSearching)
    XCTAssertEqual(appState.searchTotalCount, 0)
    XCTAssertNil(appState.searchError)
    XCTAssertNil(appState.searchNextPage)
  }
  @MainActor
  func testLoadMoreSearchResultsRequestsNextPageAndAppendsVisibleAssetsOnly() async throws {
    let apiClient = MockImmichAPIClient()
    await apiClient.setSearchResult(
      SearchResult(
        assets: [
          makeRemoteAsset(id: "page-2-visible", timeBucketKey: "2026-03-02"),
          makeRemoteAsset(id: "page-2-trashed", timeBucketKey: "2026-03-02", isTrashed: true),
        ],
        totalCount: 4,
        nextPage: nil
      )
    )
    let appState = try await makeSignedInState(apiClient: apiClient)
    appState.searchType = .smart
    appState.searchText = "mountain"
    appState.searchResults = [makePhotoItem(id: "page-1-visible")]
    appState.searchTotalCount = 3
    appState.searchNextPage = "2"

    await appState.loadMoreSearchResults()

    XCTAssertEqual(appState.searchResults.map(\.id), ["page-1-visible", "page-2-visible"])
    XCTAssertEqual(appState.searchTotalCount, 4)
    XCTAssertNil(appState.searchNextPage)
    let calls = await apiClient.recordedSearchCalls()
    XCTAssertEqual(calls, [SearchCall(kind: "smart", query: "mountain", page: "2")])
  }

  @MainActor
  func testSaveRecentSearchDeduplicatesAndCaps() {
    let appState = AppState(apiClient: MockImmichAPIClient())
    for i in 0..<12 {
      appState.saveRecentSearch("query-\(i)")
    }

    XCTAssertEqual(appState.recentSearches.count, 10)
    XCTAssertEqual(appState.recentSearches.first, "query-11")

    // Saving a duplicate moves it to front
    appState.saveRecentSearch("query-5")
    XCTAssertEqual(appState.recentSearches.first, "query-5")
    XCTAssertEqual(appState.recentSearches.count, 10)
  }

  @MainActor
  func testClearRecentSearchesRemovesAll() {
    let appState = AppState(apiClient: MockImmichAPIClient())
    appState.saveRecentSearch("test")
    XCTAssertFalse(appState.recentSearches.isEmpty)

    appState.clearRecentSearches()

    XCTAssertTrue(appState.recentSearches.isEmpty)
  }

  // MARK: - Library Section Tests

  @MainActor
  func testRebuildLibrarySectionsGroupsByTimeBucket() {
    let appState = AppState(apiClient: MockImmichAPIClient())
    appState.libraryItems = [
      makePhotoItem(id: "a", timeBucketKey: "2026-03-01"),
      makePhotoItem(id: "b", timeBucketKey: "2026-03-01"),
      makePhotoItem(id: "c", timeBucketKey: "2026-02-01"),
    ]

    appState.rebuildLibrarySections()

    XCTAssertEqual(appState.librarySections.count, 2)
    XCTAssertEqual(appState.librarySections.first?.id, "2026-03-01")
    XCTAssertEqual(appState.librarySections.first?.items.count, 2)
    XCTAssertEqual(appState.librarySections.last?.id, "2026-02-01")
    XCTAssertEqual(appState.librarySections.last?.items.count, 1)
  }

  @MainActor
  func testRecentDaySectionsGroupByLocalCaptureDayAndSortWithinDay() throws {
    let calendar = Calendar.current
    let morning = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 6, day: 2, hour: 9))
    )
    let evening = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 6, day: 2, hour: 18))
    )
    let previousDay = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 12))
    )
    var earlyItem = makePhotoItem(id: "early")
    earlyItem.date = morning
    var lateItem = makePhotoItem(id: "late")
    lateItem.date = evening
    var previousItem = makePhotoItem(id: "previous")
    previousItem.date = previousDay
    let appState = AppState(apiClient: MockImmichAPIClient())
    appState.sidebarSelection = .recentDays
    appState.libraryItems = [previousItem, earlyItem, lateItem]

    let sections = appState.visibleRecentDaySections

    XCTAssertEqual(sections.map { $0.items.map(\.id) }, [["late", "early"], ["previous"]])
    XCTAssertEqual(sections.map(\.itemCount), [2, 1])
    XCTAssertTrue(calendar.isDate(sections[0].items[0].date, inSameDayAs: evening))
  }

  // MARK: - Filtered Items Tests

  @MainActor
  func testFilteredItemsForFavorites() {
    let appState = AppState(apiClient: MockImmichAPIClient())
    appState.libraryItems = [
      makePhotoItem(id: "fav", isFavorite: true),
      makePhotoItem(id: "nope", isFavorite: false),
    ]
    appState.sidebarSelection = .favorites

    XCTAssertEqual(appState.filteredItems.count, 1)
    XCTAssertEqual(appState.filteredItems.first?.id, "fav")
  }

  @MainActor
  func testFilteredItemsForVideos() {
    let appState = AppState(apiClient: MockImmichAPIClient())
    appState.libraryItems = [
      makePhotoItem(id: "vid", isVideo: true),
      makePhotoItem(id: "photo"),
    ]
    appState.sidebarSelection = .videos

    XCTAssertEqual(appState.filteredItems.count, 1)
    XCTAssertEqual(appState.filteredItems.first?.id, "vid")
  }

  @MainActor
  func testMediaTypeSectionsLoadRemainingTimelineBuckets() async throws {
    let apiClient = MockImmichAPIClient()
    let bucketKeys = [
      "2026-07-01",
      "2026-06-01",
      "2026-05-01",
      "2026-04-01",
      "2026-03-01",
      "2026-02-01",
      "2026-01-01",
    ]
    let timelineBuckets = bucketKeys.map { TimelineBucketSummary(timeBucket: $0, count: $0 == "2026-01-01" ? 3 : 1) }
    var assetsByBucket: [String: [RemoteTimelineAsset]] = [:]

    for bucketKey in bucketKeys.dropLast() {
      assetsByBucket[bucketKey] = [makeRemoteAsset(id: "photo-\(bucketKey)", timeBucketKey: bucketKey, isImage: true)]
    }

    assetsByBucket["2026-01-01"] = [
      makeRemoteAsset(id: "video-1", timeBucketKey: "2026-01-01", isImage: false, durationMilliseconds: 5_000),
      makeRemoteAsset(id: "live-1", timeBucketKey: "2026-01-01", isImage: true, livePhotoVideoID: "motion-1"),
      makeRemoteAsset(id: "pano-1", timeBucketKey: "2026-01-01", isImage: true, ratio: 2.8),
    ]

    await apiClient.setTimelineData(buckets: timelineBuckets, assetsByBucket: assetsByBucket)
    let appState = try await makeSignedInState(apiClient: apiClient)

    XCTAssertEqual(appState.libraryItems.count, 6)

    appState.sidebarSelection = .videos
    XCTAssertTrue(appState.filteredItems.isEmpty)

    await appState.loadCompleteTimelineIfNeeded()

    appState.sidebarSelection = .videos
    XCTAssertEqual(appState.filteredItems.map(\.id), ["video-1"])

    appState.sidebarSelection = .livePhotos
    XCTAssertEqual(appState.filteredItems.map(\.id), ["live-1"])

    appState.sidebarSelection = .panoramas
    XCTAssertEqual(appState.filteredItems.map(\.id), ["pano-1"])

    appState.sidebarSelection = .videos
    await appState.refreshTimelineForCurrentSidebar()
    XCTAssertEqual(appState.libraryItems.count, 9)
    XCTAssertEqual(appState.filteredItems.map(\.id), ["video-1"])
  }

  @MainActor
  func testDateAddedSortLoadsRemainingTimelineBuckets() async throws {
    let apiClient = MockImmichAPIClient()
    let bucketKeys = [
      "2026-07-01",
      "2026-06-01",
      "2026-05-01",
      "2026-04-01",
      "2026-03-01",
      "2026-02-01",
      "2026-01-01",
    ]
    let timelineBuckets = bucketKeys.map { TimelineBucketSummary(timeBucket: $0, count: $0 == "2026-01-01" ? 3 : 1) }
    var assetsByBucket: [String: [RemoteTimelineAsset]] = [:]

    for bucketKey in bucketKeys.dropLast() {
      assetsByBucket[bucketKey] = [makeRemoteAsset(id: "photo-\(bucketKey)", timeBucketKey: bucketKey, isImage: true)]
    }

    assetsByBucket["2026-01-01"] = [
      makeRemoteAsset(id: "older-added-1", timeBucketKey: "2026-01-01", isImage: true),
      makeRemoteAsset(id: "older-added-2", timeBucketKey: "2026-01-01", isImage: true),
      makeRemoteAsset(id: "older-added-3", timeBucketKey: "2026-01-01", isImage: true),
    ]

    await apiClient.setTimelineData(buckets: timelineBuckets, assetsByBucket: assetsByBucket)
    let appState = try await makeSignedInState(apiClient: apiClient)

    XCTAssertEqual(appState.libraryItems.count, 6)

    appState.sidebarSelection = .library
    appState.setLibrarySortMode(.dateAdded)

    try await eventually {
      appState.libraryItems.count == 9
    }
  }

  @MainActor
  func testFilteredItemsForRecentlyDeleted() {
    let appState = AppState(apiClient: MockImmichAPIClient())
    appState.trashedItems = [makePhotoItem(id: "trashed")]
    appState.libraryItems = [makePhotoItem(id: "normal")]
    appState.sidebarSelection = .recentlyDeleted

    XCTAssertEqual(appState.filteredItems.count, 1)
    XCTAssertEqual(appState.filteredItems.first?.id, "trashed")
  }

  // MARK: - Version Announcement Tests

  @MainActor
  func testVersionAnnouncementHiddenForPatchOnlyUpdate() async throws {
    let apiClient = MockImmichAPIClient()
    await apiClient.setVersionCheckState(VersionCheckState(checkedAt: nil, releaseVersion: "v1.132.5"))
    let appState = try await makeSignedInState(apiClient: apiClient)

    await appState.refreshVersionAnnouncement()

    XCTAssertFalse(appState.showVersionAnnouncement)
  }

  @MainActor
  func testDismissVersionAnnouncementHidesAndClears() async throws {
    let apiClient = MockImmichAPIClient()
    await apiClient.setVersionCheckState(VersionCheckState(checkedAt: nil, releaseVersion: "v1.133.0"))
    let appState = try await makeSignedInState(apiClient: apiClient)
    await appState.refreshVersionAnnouncement()
    XCTAssertTrue(appState.showVersionAnnouncement)

    appState.dismissVersionAnnouncement()

    XCTAssertFalse(appState.showVersionAnnouncement)
    XCTAssertNil(appState.availableReleaseVersion)
  }

  // MARK: - Pinning Tests

  @MainActor
  func testTogglePinAlbumAddsAndRemoves() {
    let appState = AppState(apiClient: MockImmichAPIClient())

    appState.togglePinAlbum("album-1")
    XCTAssertTrue(appState.pinnedAlbumIDs.contains("album-1"))

    appState.togglePinAlbum("album-1")
    XCTAssertFalse(appState.pinnedAlbumIDs.contains("album-1"))
  }

  @MainActor
  func testPinnedAlbumsFiltersCorrectly() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)

    await appState.createAlbum(name: "Pinned Album")
    await appState.createAlbum(name: "Not Pinned")
    let pinnedID = appState.albums.first(where: { $0.albumName == "Pinned Album" })!.id

    appState.togglePinAlbum(pinnedID)

    XCTAssertEqual(appState.pinnedAlbums.count, 1)
    XCTAssertEqual(appState.pinnedAlbums.first?.albumName, "Pinned Album")
  }

  // MARK: - PhotoItem Computed Property Tests

  func testPhotoItemIsPanoramaWithEquirectangularProjection() {
    let item = AppState.PhotoItem(
      id: "pano-1", source: .remoteAsset(id: "pano-1"), title: "Panorama",
      date: Date(), isFavorite: false, isVideo: false, isImported: false,
      livePhotoVideoID: nil, latitude: nil, longitude: nil, durationText: nil,
      city: nil, country: nil, stackCount: nil, timeBucketKey: "2026-03-01",
      projectionType: "EQUIRECTANGULAR", aspectRatio: 1.5
    )
    XCTAssertTrue(item.isPanorama)
  }

  func testPhotoItemIsPanoramaWithWideAspectRatio() {
    let item = AppState.PhotoItem(
      id: "wide-1", source: .remoteAsset(id: "wide-1"), title: "Wide",
      date: Date(), isFavorite: false, isVideo: false, isImported: false,
      livePhotoVideoID: nil, latitude: nil, longitude: nil, durationText: nil,
      city: nil, country: nil, stackCount: nil, timeBucketKey: "2026-03-01",
      projectionType: nil, aspectRatio: 2.5
    )
    XCTAssertTrue(item.isPanorama)
  }

  func testPhotoItemIsNotPanoramaForWideVideo() {
    let item = AppState.PhotoItem(
      id: "vid-wide", source: .remoteAsset(id: "vid-wide"), title: "Wide Video",
      date: Date(), isFavorite: false, isVideo: true, isImported: false,
      livePhotoVideoID: nil, latitude: nil, longitude: nil, durationText: "0:30",
      city: nil, country: nil, stackCount: nil, timeBucketKey: "2026-03-01",
      projectionType: nil, aspectRatio: 2.5
    )
    XCTAssertFalse(item.isPanorama)
  }

  @MainActor
  func testPhotoItemTimeLabelFormatsImmichMillisecondDurations() {
    let shortVideo = AppState.makePhotoItem(
      from: makeRemoteAsset(id: "duration-short", isImage: false, durationMilliseconds: 65_000),
      timeBucket: "2026-03-01"
    )
    XCTAssertEqual(shortVideo.timeLabel, "1:05")

    let longVideo = AppState.makePhotoItem(
      from: makeRemoteAsset(id: "duration-long", isImage: false, durationMilliseconds: 3_723_000),
      timeBucket: "2026-03-01"
    )
    XCTAssertEqual(longVideo.timeLabel, "1:02:03")
  }

  func testPhotoItemTimeLabelReturnsVideoDuration() {
    let video = makePhotoItem(id: "vid-1", isVideo: true)
    XCTAssertEqual(video.timeLabel, "0:03")

    let photo = makePhotoItem(id: "photo-1")
    XCTAssertEqual(photo.timeLabel, "")
  }

  func testPhotoItemGridAspectRatioFallbackForNaN() {
    let item = AppState.PhotoItem(
      id: "bad", source: .remoteAsset(id: "bad"), title: "Bad",
      date: Date(), isFavorite: false, isVideo: false, isImported: false,
      livePhotoVideoID: nil, latitude: nil, longitude: nil, durationText: nil,
      city: nil, country: nil, stackCount: nil, timeBucketKey: "2026-03-01",
      projectionType: nil, aspectRatio: .nan
    )
    XCTAssertEqual(item.gridAspectRatio, 1)
  }

  func testPhotoItemIsLivePhotoWhenVideoIDPresent() {
    let live = makePhotoItem(id: "live", livePhotoVideoID: "vid")
    XCTAssertTrue(live.isLivePhoto)

    let normal = makePhotoItem(id: "normal")
    XCTAssertFalse(normal.isLivePhoto)
  }

  // MARK: - Empty / Status Text Tests

  @MainActor
  func testEmptyStateTitleForSearchWithNoResults() {
    let appState = AppState(apiClient: MockImmichAPIClient())
    appState.searchText = "missing"
    appState.sidebarSelection = .library

    XCTAssertEqual(appState.emptyStateTitle, "No Results")
  }

  @MainActor
  func testEmptyStateTitleForEmptyTrash() {
    let appState = AppState(apiClient: MockImmichAPIClient())
    appState.sidebarSelection = .recentlyDeleted

    XCTAssertEqual(appState.emptyStateTitle, "Trash is empty")
  }

  // MARK: - Upload Metadata Tests

  @MainActor
  func testVideoImportPassesDurationMillisecondsToImmichUpload() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("mov")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try await makeTestVideo(at: fileURL)

    let mediaDuration = try await AVURLAsset(url: fileURL).load(.duration)
    XCTAssertGreaterThan(mediaDuration.seconds, 0)
    let expectedMilliseconds = Int((mediaDuration.seconds * 1000).rounded())
    appState.importFiles([fileURL])

    try await eventually(timeout: .seconds(5)) {
      let durations = await apiClient.recordedUploadDurations()
      return durations.count == 1
    }
    let durations = await apiClient.recordedUploadDurations()
    XCTAssertEqual(durations.count, 1)
    XCTAssertEqual(durations[0], expectedMilliseconds)
  }
  // MARK: - Helpers

  @MainActor
  private func makeSignedInState(apiClient: MockImmichAPIClient) async throws -> AppState {
    let appState = AppState(apiClient: apiClient, webSocketService: NoOpWebSocketService())
    appState.serverURLText = "https://demo.example"

    await appState.connect()
    XCTAssertEqual(appState.appPhase, .login)

    appState.apiKeyText = "test-api-key"
    await appState.signInWithAPIKey()

    XCTAssertEqual(appState.appPhase, .library)
    return appState
  }

  @MainActor
  private func makeTestVideo(at url: URL) async throws {
    let width = 16
    let height = 16
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
      ]
    )
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
      ]
    )
    guard writer.canAdd(input) else { throw TestError.expectedFailure }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? TestError.expectedFailure }
    writer.startSession(atSourceTime: .zero)
    guard let pool = adaptor.pixelBufferPool else { throw TestError.expectedFailure }

    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
    guard status == kCVReturnSuccess, let pixelBuffer else { throw TestError.expectedFailure }
    if CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess {
      if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
        baseAddress.initializeMemory(
          as: UInt8.self,
          repeating: 0,
          count: CVPixelBufferGetDataSize(pixelBuffer)
        )
      }
      CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }

    for frame in [0, 30] {
      while !input.isReadyForMoreMediaData {
        guard writer.status != .failed else { throw writer.error ?? TestError.expectedFailure }
        try await Task.sleep(for: .milliseconds(1))
      }
      let presentationTime = CMTime(value: Int64(frame), timescale: 30)
      guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
        throw writer.error ?? TestError.expectedFailure
      }
    }
    input.markAsFinished()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      writer.finishWriting { continuation.resume() }
    }
    guard writer.status == .completed else { throw writer.error ?? TestError.expectedFailure }
  }

  private func makePhotoItem(
    id: String,
    isFavorite: Bool = false,
    isVideo: Bool = false,
    livePhotoVideoID: String? = nil,
    timeBucketKey: String = "2026-03-01"
  ) -> AppState.PhotoItem {
    AppState.PhotoItem(
      id: id,
      source: .remoteAsset(id: id),
      title: id,
      date: Date(timeIntervalSince1970: 1_700_000_000),
      isFavorite: isFavorite,
      isVideo: isVideo,
      isImported: false,
      livePhotoVideoID: livePhotoVideoID,
      latitude: nil,
      longitude: nil,
      durationText: isVideo ? "0:03" : nil,
      city: nil,
      country: nil,
      stackCount: nil,
      timeBucketKey: timeBucketKey,
      projectionType: nil,
      aspectRatio: 1.5
    )
  }

  private func makeRemoteAsset(
    id: String,
    timeBucketKey: String = "2026-03-01",
    isTrashed: Bool = false,
    isImage: Bool = true,
    livePhotoVideoID: String? = nil,
    projectionType: String? = nil,
    ratio: Double = 1.3,
    durationMilliseconds: Int? = nil
  ) -> RemoteTimelineAsset {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let createdAt = formatter.date(from: "\(timeBucketKey)T12:00:00Z") ?? Date(timeIntervalSince1970: 1_700_000_000)
    return RemoteTimelineAsset(
      id: id,
      city: nil,
      country: nil,
      createdAt: createdAt,
      durationMilliseconds: durationMilliseconds,
      isFavorite: false,
      isImage: isImage,
      isTrashed: isTrashed,
      latitude: nil,
      longitude: nil,
      livePhotoVideoID: livePhotoVideoID,
      ownerID: "user-1",
      projectionType: projectionType,
      ratio: ratio,
      stackChildrenCount: nil,
      thumbhash: nil,
      visibility: "timeline"
    )
  }

  private static func resetPersistentState() {
    for key in defaultsKeys {
      UserDefaults.standard.removeObject(forKey: key)
    }
    for account in keychainAccounts {
      try? KeychainHelper.delete(account: account)
    }
  }

  @MainActor
  private func eventually(
    timeout: Duration = .seconds(1),
    pollInterval: Duration = .milliseconds(20),
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @escaping @MainActor () async -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while await !condition() {
      if clock.now >= deadline {
        XCTFail("Timed out waiting for condition", file: file, line: line)
        return
      }
      try await Task.sleep(for: pollInterval)
    }
  }
}

private enum TestError: Error {
  case expectedFailure
}

private struct FavoriteUpdate: Equatable {
  let assetID: String
  let isFavorite: Bool
}

private struct LocationUpdate: Equatable, Sendable {
  let assetID: String
  let latitude: Double
  let longitude: Double
}

private struct BulkLocationUpdate: Equatable, Sendable {
  let assetIDs: [String]
  let latitude: Double
  let longitude: Double
}

private struct BulkAssetUpdateCall: Equatable, Sendable {
  let assetIDs: [String]
  let update: AssetBulkUpdate
}

private struct DateTimeUpdate: Equatable, Sendable {
  let assetID: String
  let date: Date
}
private struct SearchCall: Equatable, Sendable {
  let kind: String
  let query: String
  let page: String?
}

private actor MockImmichAPIClient: ImmichAPIClient {
  private var timelineBucketsResponse: [TimelineBucketSummary] = []
  private var timelineAssetsByBucket: [String: [RemoteTimelineAsset]] = [:]
  private var mapMarkersResponse: [MapMarker] = []
  private var assetDetailsByID: [String: AssetDetail] = [:]
  private var favoriteUpdates: [FavoriteUpdate] = []
  private var favoriteError: Error?
  private var locationUpdates: [LocationUpdate] = []
  private var locationUpdateError: Error?
  private var bulkLocationUpdates: [BulkLocationUpdate] = []
  private var reverseGeocodeResponse: [ReverseGeocodePlace] = []
  private var bulkAssetUpdates: [BulkAssetUpdateCall] = []
  private var hiddenAssetsResponse: [RemoteTimelineAsset] = []
  private var duplicatesResponse: [DuplicateGroup] = []
  private var resolvedDuplicateGroups: [DuplicateGroup] = []
  private var assetEditsByID: [String: [AssetEditAction]] = [:]

  func recordedAssetEdits(for assetID: String) -> [AssetEditAction]? {
    assetEditsByID[assetID]
  }
  private var dateTimeUpdates: [DateTimeUpdate] = []
  private var dateTimeUpdateError: Error?
  private var emptyTrashError: Error?
  private var versionCheckState = VersionCheckState(checkedAt: nil, releaseVersion: nil)
  private var searchResult = SearchResult(assets: [], totalCount: 0)
  private var searchCalls: [SearchCall] = []
  private var uploadedDurations: [Int?] = []

  func setTimelineData(buckets: [TimelineBucketSummary], assetsByBucket: [String: [RemoteTimelineAsset]]) {
    timelineBucketsResponse = buckets
    timelineAssetsByBucket = assetsByBucket
  }

  func setMapMarkersResult(_ markers: [MapMarker]) {
    mapMarkersResponse = markers
  }

  func setAssetDetail(_ detail: AssetDetail, for assetID: String) {
    assetDetailsByID[assetID] = detail
  }

  func setFavoriteError(_ error: Error?) {
    favoriteError = error
  }
  func setLocationUpdateError(_ error: Error?) {
    locationUpdateError = error
  }
  func setDateTimeUpdateError(_ error: Error?) {
    dateTimeUpdateError = error
  }
  func setEmptyTrashError(_ error: Error?) {
    emptyTrashError = error
  }

  func setVersionCheckState(_ state: VersionCheckState) {
    versionCheckState = state
  }

  func recordedFavoriteUpdates() -> [FavoriteUpdate] {
    favoriteUpdates
  }

  func recordedLocationUpdates() -> [LocationUpdate] {
    locationUpdates
  }
  func recordedBulkLocationUpdates() -> [BulkLocationUpdate] {
    bulkLocationUpdates
  }
  func setReverseGeocodeResult(_ places: [ReverseGeocodePlace]) {
    reverseGeocodeResponse = places
  }
  func recordedBulkAssetUpdates() -> [BulkAssetUpdateCall] {
    bulkAssetUpdates
  }
  func setDuplicates(_ groups: [DuplicateGroup]) {
    duplicatesResponse = groups
  }
  func recordedResolvedDuplicateGroups() -> [DuplicateGroup] {
    resolvedDuplicateGroups
  }
  func recordedDateTimeUpdates() -> [DateTimeUpdate] {
    dateTimeUpdates
  }
  func setSearchResult(_ result: SearchResult) {
    searchResult = result
  }

  func recordedSearchCalls() -> [SearchCall] {
    searchCalls
  }
  func recordedUploadDurations() -> [Int?] {
    uploadedDurations
  }


  func fetchServerInfo(server: ImmichServer, apiKey: String?) async throws -> ServerInfo {
    ServerInfo(version: "1.132.0")
  }

  func fetchVersionCheckState(server: ImmichServer, session: UserSession) async throws -> VersionCheckState {
    versionCheckState
  }

  func fetchLoginConfiguration(server: ImmichServer) async throws -> ServerLoginConfiguration {
    ServerLoginConfiguration(
      loginPageMessage: "",
      oauthButtonText: "OAuth",
      passwordLoginEnabled: true,
      oauthEnabled: false
    )
  }

  func login(server: ImmichServer, email: String, password: String) async throws -> UserSession {
    UserSession(
      accessToken: "access-token",
      isAdmin: false,
      shouldChangePassword: false,
      userEmail: email,
      userID: "user-1",
      userName: "Test User"
    )
  }

  func loginWithAPIKey(server: ImmichServer, apiKey: String) async throws -> UserSession {
    UserSession(
      apiKey: apiKey,
      isAdmin: true,
      shouldChangePassword: false,
      userEmail: "tester@example.com",
      userID: "user-1",
      userName: "API Tester"
    )
  }

  func resumeSession(server: ImmichServer, accessToken: String) async throws -> UserSession {
    UserSession(
      accessToken: accessToken,
      isAdmin: false,
      shouldChangePassword: false,
      userEmail: "tester@example.com",
      userID: "user-1",
      userName: "Resumed User"
    )
  }

  func fetchTimelineBuckets(server: ImmichServer, session: UserSession) async throws -> [TimelineBucketSummary] {
    timelineBucketsResponse
  }

  func fetchTimelineBucket(server: ImmichServer, session: UserSession, timeBucket: String) async throws -> [RemoteTimelineAsset] {
    timelineAssetsByBucket[timeBucket] ?? []
  }
  func fetchAlbums(server: ImmichServer, session: UserSession) async throws -> [Album] { [] }
  func fetchAlbumAssets(server: ImmichServer, session: UserSession, albumId: String) async throws -> (Album, [RemoteTimelineAsset]) {
    (
      Album(
        id: albumId,
        albumName: "Album",
        description: "",
        assetCount: 0,
        albumThumbnailAssetId: nil,
        createdAt: .distantPast,
        updatedAt: .distantPast,
        isActivityEnabled: false,
        shared: false,
        ownerID: "user-1"
      ),
      []
    )
  }

  func fetchPeople(server: ImmichServer, session: UserSession) async throws -> [Person] { [] }

  func fetchAssetDetail(server: ImmichServer, session: UserSession, assetId: String) async throws -> AssetDetail {
    if let detail = assetDetailsByID[assetId] {
      return detail
    }
    return AssetDetail(
      id: assetId,
      type: "IMAGE",
      originalFileName: "\(assetId).jpg",
      localDateTime: nil,
      fileCreatedAt: nil,
      width: 3000,
      height: 2000,
      fileSizeInByte: 1_024,
      isFavorite: false,
      durationMilliseconds: nil,
      livePhotoVideoId: nil,
      exif: nil,
      tags: []
    )
  }

  func fetchAssetStatistics(server: ImmichServer, session: UserSession) async throws -> AssetStatistics {
    AssetStatistics(total: 0, images: 0, videos: 0)
  }

  func setFavorite(server: ImmichServer, session: UserSession, assetId: String, isFavorite: Bool) async throws {
    favoriteUpdates.append(FavoriteUpdate(assetID: assetId, isFavorite: isFavorite))
    if let favoriteError {
      throw favoriteError
    }
  }

  func updateAssetLocation(
    server: ImmichServer,
    session: UserSession,
    assetId: String,
    latitude: Double,
    longitude: Double
  ) async throws {
    locationUpdates.append(LocationUpdate(assetID: assetId, latitude: latitude, longitude: longitude))
    if let locationUpdateError {
      throw locationUpdateError
    }
  }

  func updateAssetDescription(
    server: ImmichServer,
    session: UserSession,
    assetId: String,
    description: String
  ) async throws {}

  func updateAssetDateTime(
    server: ImmichServer,
    session: UserSession,
    assetId: String,
    date: Date
  ) async throws {
    dateTimeUpdates.append(DateTimeUpdate(assetID: assetId, date: date))
    if let dateTimeUpdateError {
      throw dateTimeUpdateError
    }
  }

  func trashAssets(server: ImmichServer, session: UserSession, assetIds: [String]) async throws {}
  func fetchTrashedAssets(server: ImmichServer, session: UserSession) async throws -> [RemoteTimelineAsset] { [] }
  func restoreAssets(server: ImmichServer, session: UserSession, assetIds: [String]) async throws {}
  func emptyTrash(server: ImmichServer, session: UserSession) async throws {
    if let emptyTrashError {
      throw emptyTrashError
    }
  }
  func searchAssets(server: ImmichServer, session: UserSession, query: String, filters: SearchFilters, page: String?) async throws -> SearchResult {
    searchCalls.append(SearchCall(kind: "smart", query: query, page: page))
    return searchResult
  }

  func searchMetadataText(server: ImmichServer, session: UserSession, query: String, filters: SearchFilters, page: String?) async throws -> SearchResult {
    searchCalls.append(SearchCall(kind: "filename", query: query, page: page))
    return searchResult
  }

  func searchMetadataDescription(server: ImmichServer, session: UserSession, query: String, filters: SearchFilters, page: String?) async throws -> SearchResult {
    searchCalls.append(SearchCall(kind: "description", query: query, page: page))
    return searchResult
  }

  func searchMetadataOCR(server: ImmichServer, session: UserSession, query: String, filters: SearchFilters, page: String?) async throws -> SearchResult {
    searchCalls.append(SearchCall(kind: "ocr", query: query, page: page))
    return searchResult
  }
  func fetchSearchSuggestions(server: ImmichServer, session: UserSession, type: String, filters: [String: String]) async throws -> [String] {
    []
  }

  func fetchPersonAssets(server: ImmichServer, session: UserSession, personId: String) async throws -> [RemoteTimelineAsset] { [] }
  func fetchScreenshots(server: ImmichServer, session: UserSession) async throws -> [RemoteTimelineAsset] { [] }
  func fetchMapMarkers(server: ImmichServer, session: UserSession) async throws -> [MapMarker] { mapMarkersResponse }
  func fetchAlbumMapMarkers(server: ImmichServer, session: UserSession, albumId: String) async throws -> [MapMarker] { mapMarkersResponse }
  func reverseGeocode(server: ImmichServer, session: UserSession, latitude: Double, longitude: Double) async throws -> [ReverseGeocodePlace] {
    reverseGeocodeResponse
  }
  func updateAssets(server: ImmichServer, session: UserSession, assetIds: [String], update: AssetBulkUpdate) async throws {
    bulkAssetUpdates.append(BulkAssetUpdateCall(assetIDs: assetIds, update: update))
  }
  func fetchHiddenAssets(server: ImmichServer, session: UserSession) async throws -> [RemoteTimelineAsset] { hiddenAssetsResponse }
  func fetchAssetEdits(server: ImmichServer, session: UserSession, assetId: String) async throws -> [AssetEditAction] {
    assetEditsByID[assetId] ?? []
  }
  func replaceAssetEdits(server: ImmichServer, session: UserSession, assetId: String, edits: [AssetEditAction]) async throws {
    assetEditsByID[assetId] = edits
  }
  func deleteAssetEdits(server: ImmichServer, session: UserSession, assetId: String) async throws {
    assetEditsByID[assetId] = nil
  }
  func fetchDuplicates(server: ImmichServer, session: UserSession) async throws -> [DuplicateGroup] { duplicatesResponse }
  func resolveDuplicates(server: ImmichServer, session: UserSession, groups: [DuplicateGroup]) async throws {
    resolvedDuplicateGroups.append(contentsOf: groups)
  }
  func updateAssetsLocation(server: ImmichServer, session: UserSession, assetIds: [String], latitude: Double, longitude: Double) async throws {
    bulkLocationUpdates.append(BulkLocationUpdate(assetIDs: assetIds, latitude: latitude, longitude: longitude))
    if let locationUpdateError {
      throw locationUpdateError
    }
  }
  func fetchMemories(server: ImmichServer, session: UserSession) async throws -> [Memory] { [] }

  func downloadOriginalAsset(server: ImmichServer, session: UserSession, assetId: String) async throws -> (Data, String) {
    (Data("image".utf8), "\(assetId).jpg")
  }

  func uploadAsset(
    server: ImmichServer,
    session: UserSession,
    fileURL: URL,
    fileCreatedAt: Date?,
    durationMilliseconds: Int?,
    onProgress: @escaping @Sendable (Double) -> Void
  ) async throws -> String {
    uploadedDurations.append(durationMilliseconds)
    onProgress(1)
    return UUID().uuidString
  }

  func createAlbum(server: ImmichServer, session: UserSession, name: String, description: String, assetIds: [String]) async throws -> Album {
    Album(
      id: UUID().uuidString,
      albumName: name,
      description: description,
      assetCount: assetIds.count,
      albumThumbnailAssetId: assetIds.first,
      createdAt: Date(),
      updatedAt: Date(),
      isActivityEnabled: false,
      shared: false,
      ownerID: session.userID
    )
  }

  func renameAlbum(server: ImmichServer, session: UserSession, albumId: String, newName: String) async throws {}
  func deleteAlbum(server: ImmichServer, session: UserSession, albumId: String) async throws {}
  func addAssetsToAlbum(server: ImmichServer, session: UserSession, albumId: String, assetIds: [String]) async throws {}
  func removeAssetsFromAlbum(server: ImmichServer, session: UserSession, albumId: String, assetIds: [String]) async throws {}
  func fetchAPIKeys(server: ImmichServer, session: UserSession) async throws -> [ImmichAPIKey] { [] }

  func createAPIKey(server: ImmichServer, session: UserSession, name: String, permissions: [String]) async throws -> CreatedAPIKey {
    CreatedAPIKey(
      apiKey: ImmichAPIKey(id: UUID().uuidString, name: name, permissions: permissions, createdAt: Date(), updatedAt: Date()),
      secret: "secret"
    )
  }

  func deleteAPIKey(server: ImmichServer, session: UserSession, id: String) async throws {}
  func fetchTags(server: ImmichServer, session: UserSession) async throws -> [ImmichTag] { [] }
  func upsertTags(server: ImmichServer, session: UserSession, tagNames: [String]) async throws -> [ImmichTag] { [] }
  func tagAssets(server: ImmichServer, session: UserSession, assetIDs: [String], tagIDs: [String]) async throws {}
  func untagAssets(server: ImmichServer, session: UserSession, tagID: String, assetIDs: [String]) async throws {}
  func deleteTag(server: ImmichServer, session: UserSession, id: String) async throws {}
  func fetchAdminUsers(server: ImmichServer, session: UserSession, includeDeleted: Bool) async throws -> [AdminUser] { [] }

  func createAdminUser(
    server: ImmichServer,
    session: UserSession,
    name: String,
    email: String,
    password: String,
    isAdmin: Bool,
    shouldChangePassword: Bool,
    quotaSizeInBytes: Int?,
    storageLabel: String?,
    notify: Bool
  ) async throws -> AdminUser {
    AdminUser(
      id: UUID().uuidString,
      name: name,
      email: email,
      avatarColor: "blue",
      isAdmin: isAdmin,
      shouldChangePassword: shouldChangePassword,
      status: "active",
      createdAt: Date(),
      updatedAt: Date(),
      deletedAt: nil,
      oauthID: "",
      profileChangedAt: Date(),
      profileImagePath: "",
      quotaSizeInBytes: quotaSizeInBytes,
      quotaUsageInBytes: 0,
      storageLabel: storageLabel
    )
  }

  func deleteAdminUser(server: ImmichServer, session: UserSession, id: String, force: Bool) async throws -> AdminUser {
    AdminUser(
      id: id,
      name: "Deleted User",
      email: "deleted@example.com",
      avatarColor: "gray",
      isAdmin: false,
      shouldChangePassword: false,
      status: "deleted",
      createdAt: Date(),
      updatedAt: Date(),
      deletedAt: Date(),
      oauthID: "",
      profileChangedAt: Date(),
      profileImagePath: "",
      quotaSizeInBytes: nil,
      quotaUsageInBytes: 0,
      storageLabel: nil
    )
  }

  func restoreAdminUser(server: ImmichServer, session: UserSession, id: String) async throws -> AdminUser {
    AdminUser(
      id: id,
      name: "Restored User",
      email: "restored@example.com",
      avatarColor: "green",
      isAdmin: false,
      shouldChangePassword: false,
      status: "active",
      createdAt: Date(),
      updatedAt: Date(),
      deletedAt: nil,
      oauthID: "",
      profileChangedAt: Date(),
      profileImagePath: "",
      quotaSizeInBytes: nil,
      quotaUsageInBytes: 0,
      storageLabel: nil
    )
  }

  func startOAuth(server: ImmichServer, redirectUri: String) async throws -> String { "https://example.com/oauth" }
  func finishOAuth(server: ImmichServer, oauthCallbackUrl: String) async throws -> UserSession {
    UserSession(
      accessToken: "oauth-token",
      isAdmin: false,
      shouldChangePassword: false,
      userEmail: "oauth@example.com",
      userID: "oauth-user",
      userName: "OAuth User"
    )
  }
}

import XCTest
@testable import ImmichMacApp
import ImmichAPI
import ImmichCore
import MapKit

final class AppStateTests: XCTestCase {
  private static let defaultsKeys = [
    "immich.serverURL",
    "immich.email",
    "immich.authMethod",
    "immich.photoGridScaleIndex",
  ]
  private static let keychainAccounts = [
    "immich.password",
    "immich.apiKey",
  ]

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
    Self.resetPersistentState()
  }

  override func tearDown() {
    Self.resetPersistentState()
    super.tearDown()
  }

  @MainActor
  func testToggleFavoriteUpdatesVisibleCollectionsAndSyncsServer() async throws {
    let apiClient = MockImmichAPIClient()
    let appState = try await makeSignedInState(apiClient: apiClient)
    let item = makePhotoItem(id: "asset-1", isFavorite: false)

    appState.libraryItems = [item]
    appState.activeAlbumItems = [item]
    appState.activePersonItems = [item]
    appState.rebuildLibrarySections()

    appState.toggleFavorite(for: item.id)

    XCTAssertTrue(appState.libraryItems[0].isFavorite)
    XCTAssertTrue(appState.activeAlbumItems[0].isFavorite)
    XCTAssertTrue(appState.activePersonItems[0].isFavorite)
    XCTAssertEqual(appState.favoritesCount, 1)

    try await eventually {
      let updates = await apiClient.recordedFavoriteUpdates()
      return updates == [FavoriteUpdate(assetID: item.id, isFavorite: true)]
    }
  }

  @MainActor
  func testToggleFavoriteRevertsOptimisticUpdateAfterFailure() async throws {
    let apiClient = MockImmichAPIClient()
    await apiClient.setFavoriteError(TestError.expectedFailure)
    let appState = try await makeSignedInState(apiClient: apiClient)
    let item = makePhotoItem(id: "asset-2", isFavorite: false)

    appState.libraryItems = [item]
    appState.activeAlbumItems = [item]
    appState.rebuildLibrarySections()

    appState.toggleFavorite(for: item.id)

    XCTAssertTrue(appState.libraryItems[0].isFavorite)

    try await eventually {
      appState.libraryItems.first?.isFavorite == false &&
      appState.activeAlbumItems.first?.isFavorite == false &&
      appState.favoritesCount == 0
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
        duration: nil,
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
        duration: "0:08",
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

  @MainActor
  private func makeSignedInState(apiClient: MockImmichAPIClient) async throws -> AppState {
    let appState = AppState(apiClient: apiClient)
    appState.serverURLText = "https://demo.example"

    await appState.connect()
    XCTAssertEqual(appState.appPhase, .login)

    appState.apiKeyText = "test-api-key"
    await appState.signInWithAPIKey()

    XCTAssertEqual(appState.appPhase, .library)
    return appState
  }

  private func makePhotoItem(
    id: String,
    isFavorite: Bool = false,
    isVideo: Bool = false,
    livePhotoVideoID: String? = nil
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
      timeBucketKey: "2026-03-01",
      projectionType: nil,
      aspectRatio: 1.5
    )
  }

  private func makeRemoteAsset(id: String, isTrashed: Bool) -> RemoteTimelineAsset {
    RemoteTimelineAsset(
      id: id,
      city: nil,
      country: nil,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      duration: nil,
      isFavorite: false,
      isImage: true,
      isTrashed: isTrashed,
      latitude: nil,
      longitude: nil,
      livePhotoVideoID: nil,
      ownerID: "user-1",
      projectionType: nil,
      ratio: 1.3,
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

private actor MockImmichAPIClient: ImmichAPIClient {
  private var mapMarkersResponse: [MapMarker] = []
  private var assetDetailsByID: [String: AssetDetail] = [:]
  private var favoriteUpdates: [FavoriteUpdate] = []
  private var favoriteError: Error?

  func setMapMarkersResult(_ markers: [MapMarker]) {
    mapMarkersResponse = markers
  }

  func setAssetDetail(_ detail: AssetDetail, for assetID: String) {
    assetDetailsByID[assetID] = detail
  }

  func setFavoriteError(_ error: Error?) {
    favoriteError = error
  }

  func recordedFavoriteUpdates() -> [FavoriteUpdate] {
    favoriteUpdates
  }

  func fetchServerInfo(server: ImmichServer, apiKey: String?) async throws -> ServerInfo {
    ServerInfo(version: "1.132.0")
  }

  func fetchLoginConfiguration(server: ImmichServer) async throws -> ServerLoginConfiguration {
    ServerLoginConfiguration(
      isInitialized: true,
      isOnboarded: true,
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

  func fetchTimelineBuckets(server: ImmichServer, session: UserSession) async throws -> [TimelineBucketSummary] { [] }
  func fetchTimelineBucket(server: ImmichServer, session: UserSession, timeBucket: String) async throws -> [RemoteTimelineAsset] { [] }
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
      duration: nil,
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

  func trashAssets(server: ImmichServer, session: UserSession, assetIds: [String]) async throws {}
  func fetchTrashedAssets(server: ImmichServer, session: UserSession) async throws -> [RemoteTimelineAsset] { [] }
  func restoreAssets(server: ImmichServer, session: UserSession, assetIds: [String]) async throws {}
  func searchAssets(server: ImmichServer, session: UserSession, query: String) async throws -> SearchResult {
    SearchResult(assets: [], totalCount: 0)
  }

  func fetchPersonAssets(server: ImmichServer, session: UserSession, personId: String) async throws -> [RemoteTimelineAsset] { [] }
  func fetchMapMarkers(server: ImmichServer, session: UserSession) async throws -> [MapMarker] { mapMarkersResponse }
  func fetchMemories(server: ImmichServer, session: UserSession) async throws -> [Memory] { [] }

  func downloadOriginalAsset(server: ImmichServer, session: UserSession, assetId: String) async throws -> (Data, String) {
    (Data("image".utf8), "\(assetId).jpg")
  }

  func uploadAsset(
    server: ImmichServer,
    session: UserSession,
    fileURL: URL,
    onProgress: @escaping @Sendable (Double) -> Void
  ) async throws -> String {
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
  func replaceAsset(server: ImmichServer, session: UserSession, assetId: String, imageData: Data, filename: String) async throws {}
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

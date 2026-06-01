#if canImport(SwiftUI) && canImport(AppKit)
import Foundation
import SwiftUI
import AppKit
import AuthenticationServices
import UniformTypeIdentifiers
import ImmichAPI
import ImmichCore
import ImmichSync

private func oauthCallbackResult(callbackURL: URL?, error: Error?) -> Result<URL, Error> {
  if let error {
    return .failure(error)
  }
  if let callbackURL {
    return .success(callbackURL)
  }
  return .failure(ImmichAPIError.invalidResponse(url: "oauth"))
}

// MARK: - OAuth Presentation Context Provider

private final class OAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
  private let anchor: ASPresentationAnchor

  init(anchor: ASPresentationAnchor) {
    self.anchor = anchor
  }

  nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    anchor
  }
}

private final class OAuthSessionCoordinator: @unchecked Sendable {
  private let presentationContextProvider: OAuthPresentationContext
  private var activeSession: ASWebAuthenticationSession?

  init(presentationContextProvider: OAuthPresentationContext) {
    self.presentationContextProvider = presentationContextProvider
  }

  func authenticate(url: URL, callbackScheme: String) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      let authSession = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
        self?.activeSession = nil
        continuation.resume(with: oauthCallbackResult(callbackURL: callbackURL, error: error))
      }
      authSession.presentationContextProvider = presentationContextProvider
      authSession.prefersEphemeralWebBrowserSession = false
      activeSession = authSession
      authSession.start()
    }
  }
}

// MARK: - App State (replaces ContentViewModel)

@MainActor
final class AppState: ObservableObject {
  private enum StoredCredential {
    static let accessTokenAccount = "immich.accessToken"
    static let passwordAccount = "immich.password"
    static let apiKeyAccount = "immich.apiKey"
    static let authMethodKey = "immich.authMethod"
    static let serverURLKey = "immich.serverURL"
    static let emailKey = "immich.email"
    static let oauthSessionKey = "immich.oauthSession"
  }

  // MARK: - App Phase

  enum AppPhase {
    case launching
    case serverSetup
    case login
    case library
  }

  enum AuthMethod: String, CaseIterable, Identifiable {
    case password = "Password"
    case apiKey = "API Key"

    var id: Self { self }
  }

  // MARK: - Photo Item (unified model for display)

  struct PhotoItem: Identifiable, Sendable {
    enum Source: Hashable, Sendable {
      case localFile(URL)
      case remoteAsset(id: String)
    }

    let id: String
    let source: Source
    var title: String
    var date: Date
    var dateAdded: Date = .distantPast
    var isFavorite: Bool
    let isVideo: Bool
    let isImported: Bool
    let livePhotoVideoID: String?
    let latitude: Double?
    let longitude: Double?
    let durationText: String?
    let city: String?
    let country: String?
    let stackCount: Int?
    let timeBucketKey: String
    let projectionType: String?
    let aspectRatio: CGFloat

    var isLivePhoto: Bool { livePhotoVideoID != nil }
    var isPanorama: Bool {
      projectionType == "EQUIRECTANGULAR" || (!isVideo && aspectRatio > 2.0)
    }
    var dayOfMonth: Int { Calendar(identifier: .gregorian).component(.day, from: date) }
    var gridAspectRatio: CGFloat {
      if aspectRatio.isFinite, aspectRatio > 0 {
        return aspectRatio
      }
      return 1
    }

    var timeLabel: String {
      if let durationText, isVideo { return durationText }
      return ""
    }
  }

  struct LibrarySection: Identifiable {
    let id: String
    let title: String
    let itemCount: Int
    let items: [PhotoItem]
    let representativeItem: PhotoItem?
  }

  enum TimelineViewMode: String, CaseIterable, Identifiable {
    case years = "Years"
    case months = "Months"
    case allPhotos = "All Photos"

    var id: String { rawValue }
  }

  enum LibraryMediaFilter: String, CaseIterable, Identifiable {
    case all = "All Items"
    case photosOnly = "Photos Only"
    case videosOnly = "Videos Only"

    var id: String { rawValue }
  }

  enum LibrarySortMode: String, CaseIterable, Identifiable {
    case dateCaptured = "Date Captured"
    case dateAdded = "Date Added"

    var id: String { rawValue }
  }

  struct UploadRow: Identifiable {
    let id: UUID
    let filename: String
    var progress: Double
    var state: UploadState
  }

  // MARK: - Published State

  // Phase & Auth
  @Published var appPhase: AppPhase = AppState.initialAppPhase()
  @Published var authMethod: AuthMethod = AppState.initialAuthMethod()
  @Published var serverURLText = UserDefaults.standard.string(forKey: StoredCredential.serverURLKey) ?? ""
  @Published var emailText = UserDefaults.standard.string(forKey: StoredCredential.emailKey) ?? ""
  @Published var passwordText = ""
  @Published var apiKeyText = (try? KeychainHelper.load(account: StoredCredential.apiKeyAccount)) ?? ""
  @Published var statusText = "Enter your Immich server URL to continue."
  @Published var isConnecting = false
  @Published var isSigningIn = false
  @Published var loginPageMessage: String?
  @Published var oauthEnabled = false
  @Published var oauthButtonText = "OAuth"
  @Published var passwordLoginEnabled = true
  @Published var connectedServerVersion: String?
  @Published var connectedServerDisplayURL: String?
  @Published var availableReleaseVersion: String?
  @Published var availableReleaseServerVersion: String?
  @Published var showVersionAnnouncement = false
  @Published var currentSession: UserSession?
  @Published var isOAuthSession = UserDefaults.standard.bool(forKey: StoredCredential.oauthSessionKey)

  // Navigation
  @Published var sidebarSelection: SidebarDestination? = .library

  // Library
  @Published var timelineViewMode: TimelineViewMode = .allPhotos
  @Published var libraryMediaFilter: LibraryMediaFilter = .all
  @Published var hideScreenshotsInLibrary = false
  @Published var librarySortMode: LibrarySortMode = .dateCaptured
  @Published var libraryItems: [PhotoItem] = []
  @Published var isLoadingTimeline = false
  @Published var searchText = ""
  @Published var photoGridScaleIndex = AppState.initialPhotoGridScaleIndex()

  // Search
  @Published var searchResults: [PhotoItem] = []
  @Published var isSearching = false
  @Published var searchTotalCount = 0
  @Published var searchError: String?
  @Published var searchType: SearchType = .smart
  @Published var searchFilters = SearchFilters()
  @Published var searchNextPage: String?
  @Published var recentSearches: [String] = []
  private var searchTask: Task<Void, Never>?

  // Album detail
  @Published var activeAlbumID: String?
  @Published var activeAlbumItems: [PhotoItem] = []
  @Published var isLoadingAlbum = false

  // Person detail
  @Published var activePersonID: String?
  @Published var activePersonItems: [PhotoItem] = []
  @Published var isLoadingPerson = false

  // Memory detail
  @Published var activeMemoryID: String?
  @Published var activeMemoryItems: [PhotoItem] = []

  // Trash
  @Published var trashedItems: [PhotoItem] = []
  @Published var isLoadingTrash = false

  // Screenshots (server-side search)
  @Published var screenshotItems: [PhotoItem] = []
  @Published var isLoadingScreenshots = false

  // Viewer
  @Published var selectedItemID: String?
  @Published var isViewingPhoto = false
  @Published var isViewingLivePhoto = false
  @Published var isPeeking = false
  @Published var showInfoPopover = false
  @Published var hoveredItemID: String?
  private var forceTouchConsumed = false

  // Multi-select
  @Published var isMultiSelectMode = false
  @Published var selectedItemIDs: Set<String> = []

  // Album CRUD
  @Published var showCreateAlbumSheet = false
  @Published var showAddToAlbumSheet = false
  @Published var showAPIKeysSheet = false
  @Published var showTagsSheet = false
  @Published var showTagEditorSheet = false
  @Published var showAdminUsersSheet = false
  @Published var newAlbumName = ""
  @Published var newAlbumDescription = ""

  // Collections
  @Published var albums: [Album] = []
  @Published var people: [Person] = []
  @Published var memories: [Memory] = []
  @Published var mapMarkers: [MapMarker] = []
  @Published var isLoadingMap = false
  @Published var isLoadingMapSelection = false
  @Published var selectedMapMarkerID: String?
  @Published var mapSelectionItems: [PhotoItem] = []
  private var lastLoadedMapMarkerIDs: Set<String> = []
  @Published var apiKeys: [ImmichAPIKey] = []
  @Published var tags: [ImmichTag] = []
  @Published var adminUsers: [AdminUser] = []
  @Published var activeTagEditorAssetIDs: [String] = []
  @Published var activeTagEditorCurrentTags: [ImmichTag] = []
  @Published var activeTagEditorTitle = "Edit Tags"
  @Published var hasAdminAccess = false
  @Published var assetStatistics: AssetStatistics?
  @Published var favoritesCount = 0
  @Published var videosCount = 0
  @Published var livePhotosCount = 0
  @Published var panoramasCount = 0

  // Uploads
  @Published var uploadRows: [UploadRow] = []
  @Published var uploadNotification: UploadNotification?
  @Published var isWebSocketConnected = false

  struct UploadNotification: Identifiable, Equatable {
    let id = UUID()
    let filename: String
    let reason: String
    let timestamp: Date

    static func == (lhs: UploadNotification, rhs: UploadNotification) -> Bool {
      lhs.id == rhs.id
    }
  }

  // Editing
  @Published var isEditing = false
  @Published var editingTab: EditingTab = .adjust

  // Pinned items (stored in UserDefaults)
  @Published var pinnedAlbumIDs: Set<String> = {
    Set(UserDefaults.standard.stringArray(forKey: "immich.pinnedAlbums") ?? [])
  }()

  var pinnedAlbums: [Album] {
    albums.filter { pinnedAlbumIDs.contains($0.id) }
  }

  enum EditingTab: String, CaseIterable {
    case adjust = "Adjust"
    case filters = "Filters"
    case crop = "Crop"

    var iconName: String {
      switch self {
      case .adjust: "slider.horizontal.3"
      case .filters: "camera.filters"
      case .crop: "crop.rotate"
      }
    }
  }

  // MARK: - Private State

  private let apiClient: any ImmichAPIClient
  private let uploadQueue = UploadQueue()
  private let webSocketService: any ImmichWebSocketServicing
  private var connectedServer: ImmichServer?
  private var timelineBuckets: [TimelineBucketSummary] = []
  private var loadedTimelineBucketKeys: [String] = []
  private var totalTimelineItemCount = 0
  private var timelineErrorMessage: String?

  struct ThumbnailContext: Sendable {
    let baseURL: URL
    let authHeaderField: String
    let authHeaderValue: String

    func apply(to request: inout URLRequest) {
      request.addValue(authHeaderValue, forHTTPHeaderField: authHeaderField)
    }

    var assetHeaderFields: [String: String] {
      [authHeaderField: authHeaderValue]
    }
  }

  private static let timelinePageSize = 6
  static let supportedImportContentTypes: [UTType] = [.image, .movie]
  private static let fallbackImageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp"]
  private static let fallbackVideoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm", "3gp"]
  private static let photoGridScaleKey = "immich.photoGridScaleIndex"
  private static let dismissedReleaseVersionsKey = "immich.dismissedReleaseVersionsByServer"
  private static let photoGridThumbnailWidths: [CGFloat] = [110, 130, 150, 170, 190, 220, 250]
  private static let defaultPhotoGridScaleIndex = 3
  private static let timelineBucketFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter
  }()
  static let timelineSectionFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "LLLL yyyy"
    return formatter
  }()
  static let timelineYearFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy"
    return formatter
  }()

  private struct SemanticVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    static func parse(_ rawValue: String) -> SemanticVersion? {
      let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }

      let withoutPrefix = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
      let core = withoutPrefix.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? withoutPrefix
      let parts = core.split(separator: ".").map(String.init)

      guard parts.count >= 2,
            let major = Int(parts[0]),
            let minor = Int(parts[1]) else {
        return nil
      }

      let patch = parts.count >= 3 ? (Int(parts[2]) ?? 0) : 0
      return SemanticVersion(major: major, minor: minor, patch: patch)
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
      if lhs.major != rhs.major { return lhs.major < rhs.major }
      if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
      return lhs.patch < rhs.patch
    }
  }

  // MARK: - Computed Properties

  var selectedItem: PhotoItem? {
    guard let selectedItemID else { return nil }
    // Check active album items first, then main library, then trash
    return activeAlbumItems.first { $0.id == selectedItemID }
      ?? activePersonItems.first { $0.id == selectedItemID }
      ?? mapSelectionItems.first { $0.id == selectedItemID }
      ?? activeMemoryItems.first { $0.id == selectedItemID }
      ?? libraryItems.first { $0.id == selectedItemID }
      ?? trashedItems.first { $0.id == selectedItemID }
  }

  var thumbnailContext: ThumbnailContext? {
    guard let connectedServer, let currentSession else { return nil }
    return ThumbnailContext(
      baseURL: connectedServer.baseURL,
      authHeaderField: currentSession.authHeaderField,
      authHeaderValue: currentSession.authHeaderValue
    )
  }

  var filteredItems: [PhotoItem] {
    let sectionFiltered = itemsForCurrentSidebar()

    guard hasActiveSearchQueryOrFilters else {
      return applyVisibleViewOptions(to: sectionFiltered)
    }

    if !searchResults.isEmpty || isSearching || searchError != nil || !searchFilters.isEmpty {
      let scopedResults = searchResults.filter { searchResultBelongsToCurrentSidebar($0) }
      return applyVisibleViewOptions(to: scopedResults)
    }

    return applyVisibleViewOptions(
      to: sectionFiltered.filter {
        $0.title.localizedCaseInsensitiveContains(searchText)
      }
    )
  }

  var hasActiveSearchQueryOrFilters: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !searchFilters.isEmpty
  }

  private func itemsForCurrentSidebar() -> [PhotoItem] {
    switch sidebarSelection {
    case .library, .none:
      return libraryItems
    case .favorites:
      return libraryItems.filter(\.isFavorite)
    case .videos:
      return libraryItems.filter(\.isVideo)
    case .livePhotos:
      return libraryItems.filter(\.isLivePhoto)
    case .panoramas:
      return libraryItems.filter(\.isPanorama)
    case .screenshots:
      return screenshotItems
    case .imports:
      return libraryItems.filter(\.isImported)
    case .album, .pinnedAlbum:
      return activeAlbumItems
    case .person:
      return activePersonItems
    case .map:
      return mapSelectionItems
    case .memory:
      return activeMemoryItems
    case .allPeople, .allMemories:
      return []
    case .recentlyDeleted:
      return trashedItems
    case .allAlbums, .collections:
      return [] // Handled by dedicated views, not LibraryGridView
    }
  }

  private func searchResultBelongsToCurrentSidebar(_ item: PhotoItem) -> Bool {
    switch sidebarSelection {
    case .library, .none:
      return true
    case .favorites:
      return item.isFavorite
    case .videos:
      return item.isVideo
    case .livePhotos:
      return item.isLivePhoto
    case .panoramas:
      return item.isPanorama
    case .screenshots:
      return screenshotItems.contains { $0.id == item.id }
    case .imports:
      return item.isImported
    case .album, .pinnedAlbum:
      return activeAlbumItems.contains { $0.id == item.id }
    case .person:
      return activePersonItems.contains { $0.id == item.id }
    case .map:
      return mapSelectionItems.contains { $0.id == item.id }
    case .memory:
      return activeMemoryItems.contains { $0.id == item.id }
    case .recentlyDeleted:
      return trashedItems.contains { $0.id == item.id }
    case .allAlbums, .collections, .allPeople, .allMemories:
      return false
    }
  }

  private func applyVisibleViewOptions(to items: [PhotoItem]) -> [PhotoItem] {
    guard viewOptionsApplyToCurrentSidebar else {
      return sortItems(items)
    }

    var visibleItems = items
    switch libraryMediaFilter {
    case .all:
      break
    case .photosOnly:
      visibleItems = visibleItems.filter { !$0.isVideo }
    case .videosOnly:
      visibleItems = visibleItems.filter(\.isVideo)
    }

    if hideScreenshotsInLibrary {
      let screenshotIDs = Set(screenshotItems.map(\.id))
      visibleItems = visibleItems.filter { !screenshotIDs.contains($0.id) }
    }

    return sortItems(visibleItems)
  }

  private var viewOptionsApplyToCurrentSidebar: Bool {
    switch sidebarSelection {
    case .library, .none, .favorites, .imports, .album, .pinnedAlbum, .person, .map, .memory:
      return true
    case .videos, .livePhotos, .panoramas, .screenshots, .recentlyDeleted,
         .allAlbums, .collections, .allPeople, .allMemories:
      return false
    }
  }

  private func sortDate(for item: PhotoItem) -> Date {
    switch librarySortMode {
    case .dateCaptured:
      return item.date
    case .dateAdded:
      return item.dateAdded
    }
  }

  private func sortItems(_ items: [PhotoItem]) -> [PhotoItem] {
    items.sorted { lhs, rhs in
      switch librarySortMode {
      case .dateCaptured:
        if lhs.date != rhs.date { return lhs.date > rhs.date }
      case .dateAdded:
        if lhs.dateAdded != rhs.dateAdded { return lhs.dateAdded > rhs.dateAdded }
      }
      return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
    }
  }

  var photoGridThumbnailWidth: CGFloat {
    Self.photoGridThumbnailWidths[photoGridScaleIndex]
  }

  var photoGridSpacing: CGFloat { 8 }

  var photoGridPadding: CGFloat { 12 }

  var canZoomOutPhotoGrid: Bool {
    photoGridScaleIndex > 0
  }

  var canZoomInPhotoGrid: Bool {
    photoGridScaleIndex < Self.photoGridThumbnailWidths.count - 1
  }

  @Published private(set) var librarySections: [LibrarySection] = []
  @Published private(set) var libraryYearSections: [LibrarySection] = []

  var visibleLibrarySections: [LibrarySection] {
    makeMonthSections(from: applyVisibleViewOptions(to: libraryItems))
  }

  var visibleLibraryYearSections: [LibrarySection] {
    makeYearSections(from: applyVisibleViewOptions(to: libraryItems))
  }

  func rebuildLibrarySections() {
    let groupedItems = Dictionary(grouping: libraryItems, by: \.timeBucketKey)
    librarySections = groupedItems.keys.sorted(by: >).compactMap { bucketKey in
      guard let items = groupedItems[bucketKey]?.sorted(by: { $0.date > $1.date }) else { return nil }
      return LibrarySection(
        id: bucketKey,
        title: Self.date(forTimelineBucket: bucketKey).map(Self.timelineSectionFormatter.string(from:)) ?? bucketKey,
        itemCount: items.count,
        items: items,
        representativeItem: items.first
      )
    }
    rebuildLibraryYearSections()
  }

  private func rebuildLibraryYearSections() {
    let calendar = Calendar(identifier: .gregorian)
    let groupedByYear = Dictionary(grouping: libraryItems) { item -> Int in
      calendar.component(.year, from: item.date)
    }
    libraryYearSections = groupedByYear.keys.sorted(by: >).compactMap { year in
      guard let items = groupedByYear[year]?.sorted(by: { $0.date > $1.date }) else { return nil }
      return LibrarySection(
        id: "\(year)",
        title: "\(year)",
        itemCount: items.count,
        items: items,
        representativeItem: items.first
      )
    }
  }

  private func makeMonthSections(from items: [PhotoItem]) -> [LibrarySection] {
    let groupedItems = Dictionary(grouping: items) { item in
      Self.timelineBucketKey(for: sortDate(for: item))
    }
    return groupedItems.keys.sorted(by: >).compactMap { bucketKey in
      guard let items = groupedItems[bucketKey].map(sortItems) else { return nil }
      return LibrarySection(
        id: bucketKey,
        title: Self.date(forTimelineBucket: bucketKey).map(Self.timelineSectionFormatter.string(from:)) ?? bucketKey,
        itemCount: items.count,
        items: items,
        representativeItem: items.first
      )
    }
  }

  private func makeYearSections(from items: [PhotoItem]) -> [LibrarySection] {
    let calendar = Calendar(identifier: .gregorian)
    let groupedByYear = Dictionary(grouping: items) { item -> Int in
      calendar.component(.year, from: sortDate(for: item))
    }
    return groupedByYear.keys.sorted(by: >).compactMap { year in
      guard let items = groupedByYear[year].map(sortItems) else { return nil }
      return LibrarySection(
        id: "\(year)",
        title: "\(year)",
        itemCount: items.count,
        items: items,
        representativeItem: items.first
      )
    }
  }

  private func updateMediaCounts() {
    var fav = 0, vid = 0, live = 0, pano = 0
    for item in libraryItems {
      if item.isFavorite { fav += 1 }
      if item.isVideo { vid += 1 }
      if item.isLivePhoto { live += 1 }
      if item.isPanorama { pano += 1 }
    }
    favoritesCount = fav
    videosCount = vid
    livePhotosCount = live
    panoramasCount = pano
  }

  var canLoadMoreTimeline: Bool {
    loadedTimelineBucketKeys.count < timelineBuckets.count
  }

  var activeUploadCount: Int {
    uploadRows.filter { if case .uploading = $0.state { return true }; if case .queued = $0.state { return true }; return false }.count
  }

  var failedUploadCount: Int {
    uploadRows.filter { if case .failed = $0.state { return true }; return false }.count
  }

  func dismissUploadNotification() {
    withAnimation(ImmichMotion.Curves.structuralMedium) {
      uploadNotification = nil
    }
  }

  var timelineFooterMessage: String? {
    guard sidebarSelection == .library, searchText.isEmpty else { return nil }
    if isLoadingTimeline, !libraryItems.isEmpty { return "Loading more photos…" }
    if canLoadMoreTimeline { return "Load more" }
    return nil
  }

  var itemCountText: String {
    let loaded = libraryItems.filter { !$0.isImported }.count
    if sidebarSelection == .library, totalTimelineItemCount > loaded, searchText.isEmpty {
      return "\(loaded) of \(totalTimelineItemCount) items loaded"
    }
    if sidebarSelection == .map {
      if !mapSelectionItems.isEmpty {
        return "\(mapSelectionItems.count) items in selected place"
      }
      return mapMarkers.isEmpty ? "No mapped items" : "\(mapMarkers.count) mapped items"
    }
    if sidebarSelection == .allPeople {
      return "\(people.filter { !$0.isHidden }.count) people"
    }
    if sidebarSelection == .allMemories {
      return "\(memories.count) memories"
    }
    return "\(filteredItems.count) items"
  }

  var emptyStateTitle: String {
    if hasActiveSearchQueryOrFilters && !isSearching {
      return "No Results"
    }
    return switch sidebarSelection {
    case .library: isLoadingTimeline ? "Loading timeline" : "Library is empty"
    case .map: isLoadingMap ? "Loading map" : "No places yet"
    case .favorites: "No favorites yet"
    case .videos: "No videos yet"
    case .livePhotos: "No Live Photos yet"
    case .panoramas: "No panoramas yet"
    case .screenshots: "No screenshots yet"
    case .imports: "No imports yet"
    case .recentlyDeleted: "Trash is empty"
    default: "No items"
    }
  }

  var emptyStateMessage: String {
    if hasActiveSearchQueryOrFilters && !isSearching {
      if let searchError { return searchError }
      let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmedSearch.isEmpty ? "No items match the active filters." : "No results found for \"\(trimmedSearch)\""
    }
    switch sidebarSelection {
    case .library:
      if isLoadingTimeline { return "Fetching latest from your Immich library." }
      if let msg = timelineErrorMessage { return msg }
      if let s = currentSession { return "Signed in as \(s.userEmail), but timeline is empty." }
      return "Sign in to an Immich server to continue."
    case .imports:
      return "Drag files into the window or use the import button."
    case .map:
      return "Photos and videos with location data will appear here."
    default:
      return "Content will appear here once available."
    }
  }

  // MARK: - Init

  private static func initialAuthMethod() -> AuthMethod {
    if let rawValue = UserDefaults.standard.string(forKey: StoredCredential.authMethodKey),
       let method = AuthMethod(rawValue: rawValue) {
      return method
    }
    if let savedKey = try? KeychainHelper.load(account: StoredCredential.apiKeyAccount), !savedKey.isEmpty {
      return .apiKey
    }
    return .password
  }

  private static func initialPhotoGridScaleIndex() -> Int {
    guard let stored = UserDefaults.standard.object(forKey: photoGridScaleKey) as? Int else {
      return defaultPhotoGridScaleIndex
    }
    return min(max(stored, 0), photoGridThumbnailWidths.count - 1)
  }

  private static func initialAppPhase() -> AppPhase {
    let hasSavedServer = UserDefaults.standard.string(forKey: StoredCredential.serverURLKey) != nil
    let hasSavedAccessToken = (try? KeychainHelper.load(account: StoredCredential.accessTokenAccount))?.isEmpty == false
    let hasSavedAPIKey = (try? KeychainHelper.load(account: StoredCredential.apiKeyAccount))?.isEmpty == false

    if hasSavedServer && (hasSavedAccessToken || hasSavedAPIKey) {
      return .launching
    }
    return .serverSetup
  }

  private func loadStoredCredential(account: String) -> String? {
    guard let value = try? KeychainHelper.load(account: account), !value.isEmpty else {
      return nil
    }
    return value
  }

  private func clearStoredCredentials() {
    for account in [
      StoredCredential.accessTokenAccount,
      StoredCredential.passwordAccount,
      StoredCredential.apiKeyAccount,
    ] {
      do {
        try KeychainHelper.delete(account: account)
      } catch {
        immichLog("[Auth] Failed to delete \(account) from keychain: \(error.localizedDescription)")
      }
    }
  }

  private func persistPasswordSession(_ session: UserSession, email: String, isOAuth: Bool) {
    authMethod = .password
    isOAuthSession = isOAuth
    UserDefaults.standard.set(AuthMethod.password.rawValue, forKey: StoredCredential.authMethodKey)
    UserDefaults.standard.set(email, forKey: StoredCredential.emailKey)
    UserDefaults.standard.set(isOAuth, forKey: StoredCredential.oauthSessionKey)

    do {
      try KeychainHelper.save(account: StoredCredential.accessTokenAccount, password: session.accessToken)
      try? KeychainHelper.delete(account: StoredCredential.passwordAccount)
      try? KeychainHelper.delete(account: StoredCredential.apiKeyAccount)
    } catch {
      immichLog("[Auth] Failed to save access token to keychain: \(error.localizedDescription)")
    }
  }

  private func persistAPIKeySession(apiKey: String, userEmail: String?) {
    authMethod = .apiKey
    isOAuthSession = false
    UserDefaults.standard.set(AuthMethod.apiKey.rawValue, forKey: StoredCredential.authMethodKey)
    UserDefaults.standard.set(false, forKey: StoredCredential.oauthSessionKey)

    do {
      try KeychainHelper.save(account: StoredCredential.apiKeyAccount, password: apiKey)
      try? KeychainHelper.delete(account: StoredCredential.accessTokenAccount)
      try? KeychainHelper.delete(account: StoredCredential.passwordAccount)
    } catch {
      immichLog("[Auth] Failed to save API key to keychain: \(error.localizedDescription)")
    }

    if let userEmail, !userEmail.isEmpty {
      UserDefaults.standard.set(userEmail, forKey: StoredCredential.emailKey)
      emailText = userEmail
    }
  }

  private func restorePasswordSession(server: ImmichServer, accessToken: String) async throws {
    let session = try await apiClient.resumeSession(server: server, accessToken: accessToken)
    currentSession = session
    emailText = session.userEmail
    authMethod = .password
    isOAuthSession = UserDefaults.standard.bool(forKey: StoredCredential.oauthSessionKey)
    resetLibraryState()
    hasAdminAccess = session.isAdmin
    appPhase = .library
    statusText = "Signed in as \(session.userName)"
    await loadInitialData()
  }

  init(
    apiClient: any ImmichAPIClient = URLSessionImmichAPIClient(),
    webSocketService: any ImmichWebSocketServicing = ImmichWebSocketService()
  ) {
    self.apiClient = apiClient
    self.webSocketService = webSocketService
    loadRecentSearches()
  }

  // MARK: - Auth Actions

  func connect() async {
    let trimmed = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), url.scheme?.isEmpty == false else {
      statusText = "Invalid server URL"
      return
    }

    isConnecting = true
    defer { isConnecting = false }

    do {
      let server = ImmichServer(endpointURL: url)
      let info = try await apiClient.fetchServerInfo(server: server, apiKey: nil)
      let config = try await apiClient.fetchLoginConfiguration(server: server)

      connectedServer = server
      connectedServerDisplayURL = trimmed
      connectedServerVersion = info.version
      loginPageMessage = config.loginPageMessage.isEmpty ? nil : config.loginPageMessage
      passwordLoginEnabled = config.passwordLoginEnabled
      oauthEnabled = config.oauthEnabled
      oauthButtonText = config.oauthButtonText.isEmpty ? "OAuth" : config.oauthButtonText
      UserDefaults.standard.set(trimmed, forKey: StoredCredential.serverURLKey)
      appPhase = .login
      statusText = "Connected • Immich \(info.version)"
    } catch {
      statusText = "Connection failed: \(error.localizedDescription)"
    }
  }

  func signIn() async {
    let trimmedEmail = emailText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let connectedServer else { changeServer(); return }
    guard !trimmedEmail.isEmpty else { statusText = "Enter your email address."; return }
    guard !passwordText.isEmpty else { statusText = "Enter your password."; return }

    isSigningIn = true
    defer { isSigningIn = false }

    do {
      let session = try await apiClient.login(server: connectedServer, email: trimmedEmail, password: passwordText)
      emailText = trimmedEmail
      persistPasswordSession(session, email: trimmedEmail, isOAuth: false)
      currentSession = session
      resetLibraryState()
      hasAdminAccess = session.isAdmin
      appPhase = .library
      statusText = "Signed in as \(session.userName)"
      await loadInitialData()
    } catch {
      statusText = "Sign in failed: \(error.localizedDescription)"
    }
  }

  func signInWithAPIKey() async {
    let trimmedKey = apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let connectedServer else { changeServer(); return }
    guard !trimmedKey.isEmpty else {
      statusText = "Enter an API key."
      return
    }

    isSigningIn = true
    defer { isSigningIn = false }

    do {
      let session = try await apiClient.loginWithAPIKey(server: connectedServer, apiKey: trimmedKey)
      persistAPIKeySession(
        apiKey: trimmedKey,
        userEmail: session.userEmail != "API key session" ? session.userEmail : nil
      )
      currentSession = session
      resetLibraryState()
      hasAdminAccess = session.isAdmin
      appPhase = .library
      statusText = "Connected with API key"
      await loadInitialData()
    } catch {
      statusText = "API key sign in failed: \(error.localizedDescription)"
    }
  }

  func autoSignInIfNeeded() {
    guard appPhase == .launching else { return }
    Task {
      await connect()
      guard appPhase == .login else {
        appPhase = .serverSetup
        return
      }

      if authMethod == .apiKey, let storedAPIKey = loadStoredCredential(account: StoredCredential.apiKeyAccount) {
        apiKeyText = storedAPIKey
        await signInWithAPIKey()
      } else if let accessToken = loadStoredCredential(account: StoredCredential.accessTokenAccount),
                let connectedServer {
        do {
          try await restorePasswordSession(server: connectedServer, accessToken: accessToken)
        } catch {
          statusText = "Saved session expired. Please sign in again."
          clearStoredCredentials()
          appPhase = .login
        }
      } else {
        appPhase = .login
      }
    }
  }

  // MARK: - OAuth Login

  func signInWithOAuth() {
    guard let connectedServer else { return }
    isSigningIn = true

    Task {
      do {
        let callbackScheme = "app.immich"
        let redirectUri = "\(callbackScheme):///oauth-callback"
        let oauthURL = try await apiClient.startOAuth(server: connectedServer, redirectUri: redirectUri)
        let presentationAnchor = NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
        let oauthContextProvider = OAuthPresentationContext(anchor: presentationAnchor)
        let oauthSessionCoordinator = OAuthSessionCoordinator(presentationContextProvider: oauthContextProvider)

        guard let url = URL(string: oauthURL) else {
          statusText = "Invalid OAuth URL from server"
          isSigningIn = false
          return
        }

        let callbackURL = try await oauthSessionCoordinator.authenticate(url: url, callbackScheme: callbackScheme)

        let session = try await apiClient.finishOAuth(server: connectedServer, oauthCallbackUrl: callbackURL.absoluteString)
        persistPasswordSession(session, email: session.userEmail, isOAuth: true)
        currentSession = session
        emailText = session.userEmail
        resetLibraryState()
        appPhase = .library
        statusText = "Signed in as \(session.userName)"
        await loadInitialData()
      } catch {
        if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
          statusText = "OAuth login cancelled"
        } else {
          statusText = "OAuth failed: \(error.localizedDescription)"
        }
      }
      isSigningIn = false
    }
  }

  func signOut() {
    webSocketService.disconnect()
    clearStoredCredentials()
    UserDefaults.standard.removeObject(forKey: StoredCredential.authMethodKey)
    UserDefaults.standard.set(false, forKey: StoredCredential.oauthSessionKey)
    currentSession = nil
    isOAuthSession = false
    showVersionAnnouncement = false
    availableReleaseVersion = nil
    availableReleaseServerVersion = nil
    passwordText = ""
    apiKeyText = ""
    resetLibraryState()
    appPhase = .login
    statusText = "Connected • Immich \(connectedServerVersion ?? "")"
  }

  func changeServer() {
    webSocketService.disconnect()
    clearStoredCredentials()
    UserDefaults.standard.removeObject(forKey: StoredCredential.serverURLKey)
    UserDefaults.standard.removeObject(forKey: StoredCredential.emailKey)
    UserDefaults.standard.removeObject(forKey: StoredCredential.authMethodKey)
    UserDefaults.standard.set(false, forKey: StoredCredential.oauthSessionKey)
    isWebSocketConnected = false
    uploadNotification = nil
    showVersionAnnouncement = false
    availableReleaseVersion = nil
    availableReleaseServerVersion = nil
    connectedServer = nil
    connectedServerDisplayURL = nil
    connectedServerVersion = nil
    loginPageMessage = nil
    oauthEnabled = false
    passwordLoginEnabled = true
    serverURLText = ""
    emailText = ""
    passwordText = ""
    apiKeyText = ""
    currentSession = nil
    isOAuthSession = false
    resetLibraryState()
    appPhase = .serverSetup
    statusText = "Enter your Immich server URL to continue."
  }

  private func resetLibraryState() {
    searchText = ""
    searchResults = []
    isSearching = false
    searchTotalCount = 0
    searchError = nil
    searchNextPage = nil
    searchType = .smart
    searchFilters = SearchFilters()
    libraryMediaFilter = .all
    hideScreenshotsInLibrary = false
    librarySortMode = .dateCaptured
    recentSearches = []
    selectedItemID = nil
    isMultiSelectMode = false
    selectedItemIDs = []
    libraryItems = []
    favoritesCount = 0
    videosCount = 0
    livePhotosCount = 0
    isLoadingTimeline = false
    activeAlbumID = nil
    activeAlbumItems = []
    isLoadingAlbum = false
    trashedItems = []
    isLoadingTrash = false
    screenshotItems = []
    isLoadingScreenshots = false
    uploadRows = []
    sidebarSelection = .library
    timelineBuckets = []
    loadedTimelineBucketKeys = []
    totalTimelineItemCount = 0
    timelineErrorMessage = nil
    albums = []
    people = []
    memories = []
    mapMarkers = []
    isLoadingMap = false
    isLoadingMapSelection = false
    selectedMapMarkerID = nil
    mapSelectionItems = []
    apiKeys = []
    tags = []
    adminUsers = []
    activeTagEditorAssetIDs = []
    activeTagEditorCurrentTags = []
    activeTagEditorTitle = "Edit Tags"
    hasAdminAccess = false
    assetStatistics = nil
    isViewingPhoto = false
    isViewingLivePhoto = false
    isPeeking = false
    isEditing = false
    showInfoPopover = false
    showAPIKeysSheet = false
    showTagsSheet = false
    showTagEditorSheet = false
    showAdminUsersSheet = false
    hoveredItemID = nil
    librarySections = []
    panoramasCount = 0
    showVersionAnnouncement = false
    availableReleaseVersion = nil
    availableReleaseServerVersion = nil
  }

  // MARK: - Data Loading

  func loadInitialData() async {
    if let connectedServer, let currentSession {
      webSocketService.delegate = self
      webSocketService.connect(server: connectedServer, userSession: currentSession)
    }
    async let timelineTask: () = loadRemoteTimeline(reset: true)
    async let collectionsTask: () = loadCollections()
    async let versionAnnouncementTask: () = refreshVersionAnnouncement()
    _ = await (timelineTask, collectionsTask, versionAnnouncementTask)
  }

  func dismissVersionAnnouncement() {
    if let connectedServer, let releaseVersion = availableReleaseVersion {
      setDismissedReleaseVersion(releaseVersion, for: connectedServer)
    }
    showVersionAnnouncement = false
    availableReleaseVersion = nil
    availableReleaseServerVersion = nil
  }

  func refreshVersionAnnouncement() async {
    guard hasAdminAccess, let connectedServer, let currentSession else { return }

    do {
      let versionCheck = try await apiClient.fetchVersionCheckState(server: connectedServer, session: currentSession)
      guard let releaseVersion = versionCheck.releaseVersion else { return }
      let serverVersion = connectedServerVersion ?? releaseVersion
      evaluateVersionAnnouncement(
        releaseVersion: releaseVersion,
        serverVersion: serverVersion,
        server: connectedServer
      )
    } catch {
      immichLog("[VersionAnnouncement] Version check failed: \(error.localizedDescription)")
    }
  }

  private func evaluateVersionAnnouncement(
    releaseVersion: String,
    serverVersion: String,
    server: ImmichServer
  ) {
    guard let releaseSemver = SemanticVersion.parse(releaseVersion),
          let serverSemver = SemanticVersion.parse(serverVersion) else {
      return
    }

    guard releaseSemver > serverSemver else { return }
    guard releaseSemver.major != serverSemver.major || releaseSemver.minor != serverSemver.minor else { return }
    guard dismissedReleaseVersion(for: server) != releaseVersion else { return }

    availableReleaseVersion = releaseVersion
    availableReleaseServerVersion = serverVersion
    showVersionAnnouncement = true
    immichLog("[VersionAnnouncement] New release available: \(releaseVersion) (server: \(serverVersion))")
  }

  private func dismissedReleaseVersion(for server: ImmichServer) -> String? {
    let releasesByServer = UserDefaults.standard.dictionary(forKey: Self.dismissedReleaseVersionsKey) as? [String: String] ?? [:]
    return releasesByServer[server.baseURL.absoluteString]
  }

  private func setDismissedReleaseVersion(_ releaseVersion: String, for server: ImmichServer) {
    var releasesByServer = UserDefaults.standard.dictionary(forKey: Self.dismissedReleaseVersionsKey) as? [String: String] ?? [:]
    releasesByServer[server.baseURL.absoluteString] = releaseVersion
    UserDefaults.standard.set(releasesByServer, forKey: Self.dismissedReleaseVersionsKey)
  }

  func loadCollections() async {
    guard let connectedServer, let currentSession else { return }
    // Fire all collection fetches in parallel
    async let albumsResult = apiClient.fetchAlbums(server: connectedServer, session: currentSession)
    async let peopleResult = apiClient.fetchPeople(server: connectedServer, session: currentSession)
    async let statsResult = apiClient.fetchAssetStatistics(server: connectedServer, session: currentSession)
    async let memoriesResult = apiClient.fetchMemories(server: connectedServer, session: currentSession)

    do { albums = try await albumsResult } catch { immichLog("[Collections] Albums failed: \(error)") }
    do { people = try await peopleResult } catch { immichLog("[Collections] People failed: \(error)") }
    do { assetStatistics = try await statsResult } catch { immichLog("[Collections] Stats failed: \(error)") }
    do { memories = try await memoriesResult } catch { immichLog("[Collections] Memories failed: \(error)") }
  }

  @discardableResult
  func loadMapMarkers() async -> String? {
    guard let connectedServer, let currentSession else { return "Not connected to server." }
    isLoadingMap = true
    defer { isLoadingMap = false }

    do {
      let fetchedMarkers = try await apiClient.fetchMapMarkers(server: connectedServer, session: currentSession)
      // Keep obviously bad coordinates out of the UI so the map browser only has to reason
      // about valid positions when computing viewports and selection regions.
      mapMarkers = fetchedMarkers.filter { marker in
        marker.latitude.isFinite &&
        marker.longitude.isFinite &&
        (-90.0 ... 90.0).contains(marker.latitude) &&
        (-180.0 ... 180.0).contains(marker.longitude)
      }
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  @discardableResult
  func selectMapMarker(_ marker: MapMarker) async -> String? {
    await selectMapMarker(marker, markers: [marker])
  }

  @discardableResult
  func selectMapMarker(_ marker: MapMarker, markers: [MapMarker]) async -> String? {
    guard let connectedServer, let currentSession else { return "Not connected to server." }

    let markerIDSet = Set(markers.map(\.id))
    let canReuseSelection =
      selectedMapMarkerID == marker.id &&
      !mapSelectionItems.isEmpty &&
      markerIDSet == lastLoadedMapMarkerIDs

    selectedMapMarkerID = marker.id

    if canReuseSelection {
      return nil
    }

    isLoadingMapSelection = true
    mapSelectionItems = []
    lastLoadedMapMarkerIDs = Set(markers.map(\.id))
    defer { isLoadingMapSelection = false }

    let loadedSelectionItems = await Self.loadMapSelectionItems(
      markers: markers,
      server: connectedServer,
      session: currentSession,
      apiClient: apiClient
    )
    let loadedItems = loadedSelectionItems
      .map(Self.makePhotoItem(from:))
      .sorted { lhs, rhs in
        if lhs.date != rhs.date {
          return lhs.date > rhs.date
        }
        return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
      }

    mapSelectionItems = loadedItems

    if let selectedItemID, loadedItems.contains(where: { $0.id == selectedItemID }) {
      // Keep the current selected asset when it still belongs to this place.
    } else {
      selectedItemID = loadedItems.first?.id
    }

    if loadedItems.isEmpty {
      return "Unable to load items for this place."
    }

    if loadedSelectionItems.contains(where: { !$0.hasFullDetail }) {
      return "Some item details couldn't be loaded, but all assets are shown."
    }

    return nil
  }

  func clearMapSelection() {
    selectedMapMarkerID = nil
    mapSelectionItems = []
    lastLoadedMapMarkerIDs = []
  }

  // MARK: - Search

  func performSearch(query: String) {
    searchTask?.cancel()
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmed.isEmpty || !searchFilters.isEmpty else {
      searchResults = []
      isSearching = false
      searchTotalCount = 0
      searchError = nil
      searchNextPage = nil
      return
    }

    isSearching = true
    searchTask = Task {
      do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
      guard !Task.isCancelled else { return }
      guard let connectedServer, let currentSession else {
        isSearching = false
        return
      }

      do {
        let result = try await performSearchRequest(
          server: connectedServer,
          session: currentSession,
          query: trimmed
        )
        guard !Task.isCancelled else { return }
        searchResults = result.assets.filter { !$0.isTrashed }.map {
          Self.makePhotoItem(from: $0, timeBucket: Self.timelineBucketKey(for: $0.createdAt))
        }
        searchTotalCount = result.totalCount
        searchNextPage = result.nextPage
        searchError = nil
        saveRecentSearch(trimmed)
      } catch {
        guard !Task.isCancelled else { return }
        immichLog("[Search] Search failed (\(searchType.rawValue)): \(error)")
        searchResults = []
        searchTotalCount = 0
        searchNextPage = nil
        searchError = "Search unavailable. Check your server connection."
      }
      isSearching = false
    }
  }

  func loadMoreSearchResults() async {
    guard let page = searchNextPage, !page.isEmpty else { return }
    guard let connectedServer, let currentSession else { return }
    guard !isSearching else { return }

    isSearching = true
    defer { isSearching = false }

    do {
      let result = try await performSearchRequest(
        server: connectedServer,
        session: currentSession,
        query: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
        page: page
      )
      let newItems = result.assets.filter { !$0.isTrashed }.map {
        Self.makePhotoItem(from: $0, timeBucket: Self.timelineBucketKey(for: $0.createdAt))
      }
      searchResults.append(contentsOf: newItems)
      searchTotalCount = result.totalCount
      searchNextPage = result.nextPage
    } catch {
      immichLog("[Search] Pagination failed: \(error)")
    }
  }

  private func performSearchRequest(
    server: ImmichServer,
    session: UserSession,
    query: String,
    page: String? = nil
  ) async throws -> SearchResult {
    switch searchType {
    case .smart where query.isEmpty:
      return try await apiClient.searchMetadataText(
        server: server, session: session, query: query, filters: searchFilters, page: page
      )
    case .smart:
      return try await apiClient.searchAssets(
        server: server, session: session, query: query, filters: searchFilters, page: page
      )
    case .filename:
      return try await apiClient.searchMetadataText(
        server: server, session: session, query: query, filters: searchFilters, page: page
      )
    case .description:
      return try await apiClient.searchMetadataDescription(
        server: server, session: session, query: query, filters: searchFilters, page: page
      )
    case .ocr:
      return try await apiClient.searchMetadataOCR(
        server: server, session: session, query: query, filters: searchFilters, page: page
      )
    }
  }

  func resetSearchState() {
    searchResults = []
    isSearching = false
    searchTotalCount = 0
    searchError = nil
    searchNextPage = nil
  }

  func saveRecentSearch(_ query: String) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    var recent = recentSearches.filter { $0 != trimmed }
    recent.insert(trimmed, at: 0)
    recentSearches = Array(recent.prefix(10))
    UserDefaults.standard.set(recentSearches, forKey: "immich.recentSearches")
  }

  func clearRecentSearches() {
    recentSearches = []
    UserDefaults.standard.removeObject(forKey: "immich.recentSearches")
  }

  func loadRecentSearches() {
    recentSearches = UserDefaults.standard.stringArray(forKey: "immich.recentSearches") ?? []
  }

  // MARK: - Timeline Loading

  func loadRemoteTimeline(reset: Bool) async {
    guard let connectedServer, let currentSession else { return }

    if reset {
      isLoadingTimeline = true
      timelineErrorMessage = nil

      do {
        let buckets = try await apiClient.fetchTimelineBuckets(server: connectedServer, session: currentSession)
        timelineBuckets = buckets.filter { $0.count > 0 }
        loadedTimelineBucketKeys = []
        totalTimelineItemCount = timelineBuckets.reduce(0) { $0 + $1.count }
      } catch {
        timelineErrorMessage = "Timeline could not be loaded: \(error.localizedDescription)"
        isLoadingTimeline = false
        return
      }
    }

    await loadNextTimelinePage()
  }

  func refreshTimelineForCurrentSidebar() async {
    await loadRemoteTimeline(reset: true)
    guard timelineErrorMessage == nil else { return }

    switch sidebarSelection {
    case .videos, .livePhotos, .panoramas:
      await loadCompleteTimelineIfNeeded()
    default:
      break
    }
  }

  func loadNextTimelinePage() async {
    guard let connectedServer, let currentSession else { return }
    guard !isLoadingTimeline || loadedTimelineBucketKeys.isEmpty else { return }

    let nextBuckets = timelineBuckets.dropFirst(loadedTimelineBucketKeys.count).prefix(Self.timelinePageSize)
    guard !nextBuckets.isEmpty else {
      isLoadingTimeline = false
      updateTimelineStatus()
      return
    }

    isLoadingTimeline = true
    defer {
      isLoadingTimeline = false
      updateTimelineStatus()
    }

    do {
      var newItems: [PhotoItem] = []
      var fetchedKeys: [String] = []

      for bucket in nextBuckets {
        let assets = try await apiClient.fetchTimelineBucket(
          server: connectedServer, session: currentSession, timeBucket: bucket.timeBucket
        )
        let items = assets.filter { !$0.isTrashed }.map { Self.makePhotoItem(from: $0, timeBucket: bucket.timeBucket) }
        newItems.append(contentsOf: items)
        fetchedKeys.append(bucket.timeBucket)
      }

      let all = libraryItems + newItems
      let dedup = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
      loadedTimelineBucketKeys.append(contentsOf: fetchedKeys)
      libraryItems = dedup.values.sorted { $0.date > $1.date }
      updateMediaCounts()
      rebuildLibrarySections()
    } catch {
      timelineErrorMessage = "Couldn't load more photos: \(error.localizedDescription)"
    }
  }

  func loadMoreTimelineIfNeeded(after sectionID: String) {
    guard appPhase == .library, sidebarSelection == .library, !hasActiveSearchQueryOrFilters,
          canLoadMoreTimeline, !isLoadingTimeline, loadedTimelineBucketKeys.last == sectionID else { return }
    Task { await loadNextTimelinePage() }
  }

  func loadCompleteTimelineIfNeeded() async {
    guard connectedServer != nil, currentSession != nil else { return }

    if timelineBuckets.isEmpty {
      await loadRemoteTimeline(reset: true)
    }

    var previousLoadedBucketCount = -1
    while canLoadMoreTimeline {
      let currentLoadedBucketCount = loadedTimelineBucketKeys.count
      guard currentLoadedBucketCount != previousLoadedBucketCount else { break }
      previousLoadedBucketCount = currentLoadedBucketCount

      await loadNextTimelinePage()

      if timelineErrorMessage != nil {
        break
      }
    }
  }

  func presentInfo(for itemID: String) {
    selectedItemID = itemID
    showInfoPopover = true
  }

  // MARK: - Item Actions

  func toggleFavorite(for itemID: String) {
    var newVal: Bool?

    if let index = libraryItems.firstIndex(where: { $0.id == itemID }) {
      libraryItems[index].isFavorite.toggle()
      newVal = libraryItems[index].isFavorite
    }

    if let index = activeAlbumItems.firstIndex(where: { $0.id == itemID }) {
      if let newVal {
        activeAlbumItems[index].isFavorite = newVal
      } else {
        activeAlbumItems[index].isFavorite.toggle()
        newVal = activeAlbumItems[index].isFavorite
      }
    }

    if let index = activePersonItems.firstIndex(where: { $0.id == itemID }) {
      if let newVal {
        activePersonItems[index].isFavorite = newVal
      } else {
        activePersonItems[index].isFavorite.toggle()
        newVal = activePersonItems[index].isFavorite
      }
    }

    guard let newVal else { return }
    rebuildLibrarySections()
    updateMediaCounts()

    // Sync with server
    guard let connectedServer, let currentSession else { return }
    Task {
      do {
        try await apiClient.setFavorite(server: connectedServer, session: currentSession, assetId: itemID, isFavorite: newVal)
      } catch {
        // Revert on failure
        if let idx = libraryItems.firstIndex(where: { $0.id == itemID }) {
          libraryItems[idx].isFavorite = !newVal
        }
        if let idx = activeAlbumItems.firstIndex(where: { $0.id == itemID }) {
          activeAlbumItems[idx].isFavorite = !newVal
        }
        if let idx = activePersonItems.firstIndex(where: { $0.id == itemID }) {
          activePersonItems[idx].isFavorite = !newVal
        }
        rebuildLibrarySections()
        updateMediaCounts()
        immichLog("[Favorite] Sync failed: \(error)")
      }
    }
  }

  func trashItem(_ itemID: String) {
    guard let connectedServer, let currentSession else { return }
    libraryItems.removeAll { $0.id == itemID }
    activeAlbumItems.removeAll { $0.id == itemID }
    activePersonItems.removeAll { $0.id == itemID }
    rebuildLibrarySections()
    if selectedItemID == itemID {
      selectedItemID = filteredItems.first?.id
      isViewingPhoto = false
    }
    Task {
      do {
        try await apiClient.trashAssets(server: connectedServer, session: currentSession, assetIds: [itemID])
      } catch {
        immichLog("[Trash] Failed: \(error)")
      }
    }
  }

  // MARK: - Album Loading

  func loadAlbum(_ albumID: String) async {
    guard let connectedServer, let currentSession else { return }
    guard activeAlbumID != albumID else { return }

    activeAlbumID = albumID
    activeAlbumItems = []
    isLoadingAlbum = true
    defer { isLoadingAlbum = false }

    do {
      let (_, assets) = try await apiClient.fetchAlbumAssets(
        server: connectedServer, session: currentSession, albumId: albumID
      )
      activeAlbumItems = assets.filter { !$0.isTrashed }.map {
        Self.makePhotoItem(from: $0, timeBucket: Self.timelineBucketKey(for: $0.createdAt))
      }
    } catch {
      immichLog("[Album] Failed to load album \(albumID): \(error)")
    }
  }

  // MARK: - Person Loading

  func loadPerson(_ personID: String) async {
    guard let connectedServer, let currentSession else { return }
    guard activePersonID != personID else { return }

    activePersonID = personID
    activePersonItems = []
    isLoadingPerson = true
    defer { isLoadingPerson = false }

    do {
      let assets = try await apiClient.fetchPersonAssets(
        server: connectedServer, session: currentSession, personId: personID
      )
      activePersonItems = assets.filter { !$0.isTrashed }.map {
        Self.makePhotoItem(from: $0, timeBucket: Self.timelineBucketKey(for: $0.createdAt))
      }
      rebuildLibrarySections()
    } catch {
      immichLog("[Person] Failed to load person \(personID): \(error)")
    }
  }

  // MARK: - Screenshot Loading

  func loadScreenshots() async {
    guard let connectedServer, let currentSession else { return }
    guard !isLoadingScreenshots else { return }

    screenshotItems = []
    isLoadingScreenshots = true
    defer { isLoadingScreenshots = false }

    do {
      let assets = try await apiClient.fetchScreenshots(
        server: connectedServer, session: currentSession
      )
      screenshotItems = assets.filter { !$0.isTrashed }.map {
        Self.makePhotoItem(from: $0, timeBucket: Self.timelineBucketKey(for: $0.createdAt))
      }
    } catch {
      immichLog("[Screenshots] Failed to load screenshots: \(error)")
    }
  }

  func setLibraryMediaFilter(_ filter: LibraryMediaFilter) {
    libraryMediaFilter = filter
    reconcileSelectionWithVisibleItems()
  }

  func toggleHideScreenshotsInLibrary() {
    hideScreenshotsInLibrary.toggle()
    reconcileSelectionWithVisibleItems()
    if hideScreenshotsInLibrary, screenshotItems.isEmpty {
      Task { await loadScreenshots() }
    }
  }

  func setLibrarySortMode(_ mode: LibrarySortMode) {
    librarySortMode = mode
    reconcileSelectionWithVisibleItems()

    if mode == .dateAdded, canLoadMoreTimeline, timelineBackedSidebarUsesLibraryItems {
      Task {
        await loadCompleteTimelineIfNeeded()
        reconcileSelectionWithVisibleItems()
      }
    }
  }

  private var timelineBackedSidebarUsesLibraryItems: Bool {
    switch sidebarSelection {
    case .library, .none, .favorites, .imports:
      return true
    default:
      return false
    }
  }

  private func reconcileSelectionWithVisibleItems() {
    let visibleIDs = Set(itemsRenderedInCurrentGridMode().map(\.id))
    selectedItemIDs = selectedItemIDs.intersection(visibleIDs)
    if let selectedItemID, !visibleIDs.contains(selectedItemID) {
      self.selectedItemID = itemsRenderedInCurrentGridMode().first?.id
    }
  }

  private func itemsRenderedInCurrentGridMode() -> [PhotoItem] {
    guard (sidebarSelection == .library || sidebarSelection == nil), !hasActiveSearchQueryOrFilters else {
      return filteredItems
    }

    switch timelineViewMode {
    case .years:
      return visibleLibraryYearSections.compactMap { $0.representativeItem ?? $0.items.first }
    case .months:
      return visibleLibrarySections.flatMap(\.items)
    case .allPhotos:
      return filteredItems
    }
  }

  func refreshSearchForCurrentFilters() {
    guard hasActiveSearchQueryOrFilters else { return }
    performSearch(query: searchText)
  }

  // MARK: - Memory Loading

  func loadMemory(_ memoryID: String) {
    guard activeMemoryID != memoryID else { return }
    activeMemoryID = memoryID

    guard let memory = memories.first(where: { $0.id == memoryID }) else {
      activeMemoryItems = []
      return
    }

    activeMemoryItems = memory.assets.filter { !$0.isTrashed }.map {
      Self.makePhotoItem(from: $0, timeBucket: Self.timelineBucketKey(for: $0.createdAt))
    }
  }

  // MARK: - Asset Detail / Tags / API Keys / Admin

  func fetchAssetDetail(_ assetID: String) async throws -> AssetDetail {
    guard let connectedServer, let currentSession else {
      throw ImmichAPIError.requestFailed(statusCode: 0, message: "Not connected to server.")
    }
    return try await apiClient.fetchAssetDetail(server: connectedServer, session: currentSession, assetId: assetID)
  }

  func loadAPIKeys() async throws {
    guard let connectedServer, let currentSession else {
      throw ImmichAPIError.requestFailed(statusCode: 0, message: "Not connected to server.")
    }
    apiKeys = try await apiClient.fetchAPIKeys(server: connectedServer, session: currentSession)
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  func createAPIKey(name: String, permissionsText: String) async throws -> CreatedAPIKey {
    guard let connectedServer, let currentSession else {
      throw ImmichAPIError.requestFailed(statusCode: 0, message: "Not connected to server.")
    }

    let permissions = Self.parseDelimitedValues(permissionsText, fallback: ["all"])
    let created = try await apiClient.createAPIKey(
      server: connectedServer,
      session: currentSession,
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      permissions: permissions
    )

    apiKeys.removeAll { $0.id == created.apiKey.id }
    apiKeys.insert(created.apiKey, at: 0)
    return created
  }

  func deleteAPIKey(_ id: String) async throws {
    guard let connectedServer, let currentSession else {
      throw ImmichAPIError.requestFailed(statusCode: 0, message: "Not connected to server.")
    }

    try await apiClient.deleteAPIKey(server: connectedServer, session: currentSession, id: id)
    apiKeys.removeAll { $0.id == id }
  }

  func loadTags() async throws {
    guard let connectedServer, let currentSession else {
      throw ImmichAPIError.requestFailed(statusCode: 0, message: "Not connected to server.")
    }
    tags = try await apiClient.fetchTags(server: connectedServer, session: currentSession)
  }

  func upsertTags(from rawNames: String) async throws -> [ImmichTag] {
    let names = Self.parseDelimitedValues(rawNames, fallback: [])
    guard !names.isEmpty else { return [] }
    return try await upsertTags(named: names)
  }

  func upsertTags(named names: [String]) async throws -> [ImmichTag] {
    guard let connectedServer, let currentSession else {
      throw ImmichAPIError.requestFailed(statusCode: 0, message: "Not connected to server.")
    }

    let normalized = Self.normalizeTagNames(names)
    guard !normalized.isEmpty else { return [] }

    let upserted = try await apiClient.upsertTags(server: connectedServer, session: currentSession, tagNames: normalized)
    mergeTags(upserted)
    return upserted
  }

  func applyTags(named names: [String], to assetIDs: [String]) async throws -> [ImmichTag] {
    guard let connectedServer, let currentSession else {
      throw ImmichAPIError.requestFailed(statusCode: 0, message: "Not connected to server.")
    }

    let upserted = try await upsertTags(named: names)
    guard !upserted.isEmpty else { return [] }

    try await apiClient.tagAssets(
      server: connectedServer,
      session: currentSession,
      assetIDs: assetIDs,
      tagIDs: upserted.map(\.id)
    )
    return upserted
  }

  func deleteTag(_ id: String) async throws {
    guard let connectedServer, let currentSession else {
      throw ImmichAPIError.requestFailed(statusCode: 0, message: "Not connected to server.")
    }

    try await apiClient.deleteTag(server: connectedServer, session: currentSession, id: id)
    tags.removeAll { $0.id == id }
    activeTagEditorCurrentTags.removeAll { $0.id == id }
  }

  func removeTag(_ tagID: String, from assetIDs: [String]) async throws {
    guard let connectedServer, let currentSession else {
      throw ImmichAPIError.requestFailed(statusCode: 0, message: "Not connected to server.")
    }

    try await apiClient.untagAssets(server: connectedServer, session: currentSession, tagID: tagID, assetIDs: assetIDs)
    activeTagEditorCurrentTags.removeAll { $0.id == tagID }
  }

  func presentTagEditor(for assetIDs: [String], currentTags: [ImmichTag], title: String) {
    activeTagEditorAssetIDs = assetIDs
    activeTagEditorCurrentTags = currentTags.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
    activeTagEditorTitle = title
    showTagEditorSheet = true
  }

  func loadAdminUsers(includeDeleted: Bool = true) async throws {
    guard let connectedServer, let currentSession else {
      throw ImmichAPIError.requestFailed(statusCode: 0, message: "Not connected to server.")
    }

    do {
      adminUsers = try await apiClient.fetchAdminUsers(
        server: connectedServer,
        session: currentSession,
        includeDeleted: includeDeleted
      )
      .sorted(by: Self.sortAdminUsers)
      hasAdminAccess = true
    } catch {
      if Self.isAuthorizationError(error) {
        hasAdminAccess = false
      }
      throw error
    }
  }

  func createAdminUser(
    name: String,
    email: String,
    password: String,
    isAdmin: Bool,
    shouldChangePassword: Bool,
    quotaSizeInBytes: Int?,
    storageLabel: String?,
    notify: Bool
  ) async throws -> AdminUser {
    guard let connectedServer, let currentSession else {
      throw ImmichAPIError.requestFailed(statusCode: 0, message: "Not connected to server.")
    }

    let user = try await apiClient.createAdminUser(
      server: connectedServer,
      session: currentSession,
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      email: email.trimmingCharacters(in: .whitespacesAndNewlines),
      password: password,
      isAdmin: isAdmin,
      shouldChangePassword: shouldChangePassword,
      quotaSizeInBytes: quotaSizeInBytes,
      storageLabel: storageLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
      notify: notify
    )

    upsertAdminUser(user)
    hasAdminAccess = true
    return user
  }

  func deleteAdminUser(_ id: String, force: Bool) async throws -> AdminUser {
    guard let connectedServer, let currentSession else {
      throw ImmichAPIError.requestFailed(statusCode: 0, message: "Not connected to server.")
    }

    let user = try await apiClient.deleteAdminUser(server: connectedServer, session: currentSession, id: id, force: force)
    upsertAdminUser(user)
    return user
  }

  func restoreAdminUser(_ id: String) async throws -> AdminUser {
    guard let connectedServer, let currentSession else {
      throw ImmichAPIError.requestFailed(statusCode: 0, message: "Not connected to server.")
    }

    let user = try await apiClient.restoreAdminUser(server: connectedServer, session: currentSession, id: id)
    upsertAdminUser(user)
    return user
  }

  // MARK: - Download / Export

  @Published var isDownloading = false

  private struct DownloadedAssetPayload {
    let data: Data
    let filename: String
  }

  func downloadAsset(_ assetID: String) {
    guard let connectedServer, let currentSession else { return }
    isDownloading = true
    Task {
      defer { isDownloading = false }
      do {
        let payloads = try await downloadPayloads(
          for: assetID,
          server: connectedServer,
          session: currentSession
        )
        guard let primaryPayload = payloads.first else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = primaryPayload.filename
        panel.canCreateDirectories = true
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
          response = await panel.beginSheetModal(for: window)
        } else {
          response = panel.runModal()
        }
        if response == .OK, let url = panel.url {
          try primaryPayload.data.write(to: url)
          immichLog("[Download] Saved \(primaryPayload.filename) to \(url.path)")

          for companionPayload in payloads.dropFirst() {
            let companionURL = companionDownloadURL(
              nextTo: url,
              companionFilename: companionPayload.filename
            )
            try companionPayload.data.write(to: companionURL)
            immichLog("[Download] Saved \(companionPayload.filename) to \(companionURL.path)")
          }
        }
      } catch {
        immichLog("[Download] Failed: \(error)")
      }
    }
  }

  // MARK: - Share (NSSharingService)

  func shareAsset(_ assetID: String, from view: NSView) {
    guard let connectedServer, let currentSession else { return }
    Task {
      do {
        let payloads = try await downloadPayloads(
          for: assetID,
          server: connectedServer,
          session: currentSession
        )
        guard !payloads.isEmpty else { return }

        let shareFolder = FileManager.default.temporaryDirectory
          .appendingPathComponent("ImmichShare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: shareFolder, withIntermediateDirectories: true)
        let itemURLs = try payloads.map { payload in
          let fileURL = shareFolder.appendingPathComponent(payload.filename)
          try payload.data.write(to: fileURL)
          return fileURL
        }

        let picker = NSSharingServicePicker(items: itemURLs)
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
      } catch {
        immichLog("[Share] Failed: \(error)")
      }
    }
  }

  // MARK: - Trash Loading

  // MARK: - Photo Editing (Save / Export)

  func saveEditedImage(pipeline: PhotoEditingPipeline) {
    guard
      let connectedServer,
      let currentSession,
      let item = selectedItem,
      !item.isVideo
    else { return }
    Task {
      guard let jpegData = await pipeline.renderFinalJPEG() else { return }
      do {
        let filename = "\(item.title.isEmpty ? item.id : item.title).jpg"
        try await apiClient.replaceAsset(
          server: connectedServer,
          session: currentSession,
          assetId: item.id,
          imageData: jpegData,
          filename: filename
        )
        immichLog("[Edit] Saved edited image for asset \(item.id)")
        isEditing = false
        pipeline.resetAll()
      } catch {
        immichLog("[Edit] Save failed: \(error)")
      }
    }
  }

  func exportEditedImage(pipeline: PhotoEditingPipeline) {
    guard let item = selectedItem, !item.isVideo else { return }
    Task {
      let panel = NSSavePanel()
      let defaultName = item.title
      panel.nameFieldStringValue = "\(defaultName)_edited.jpg"
      panel.canCreateDirectories = true
      panel.allowedContentTypes = [.jpeg, .png]
      guard let window = NSApp.keyWindow else { return }
      let response = await panel.beginSheetModal(for: window)
      if response == .OK, let url = panel.url {
        do {
          let dataToWrite: Data
          if url.pathExtension.lowercased() == "png" {
            if let pngData = await pipeline.renderFinalPNG() {
              dataToWrite = pngData
            } else if let jpegFallback = await pipeline.renderFinalJPEG() {
              dataToWrite = jpegFallback
            } else {
              return
            }
          } else {
            guard let jpegData = await pipeline.renderFinalJPEG() else { return }
            dataToWrite = jpegData
          }
          try dataToWrite.write(to: url)
          immichLog("[Edit] Exported to \(url.path)")
        } catch {
          immichLog("[Edit] Export failed: \(error)")
        }
      }
    }
  }

  func loadTrashedAssets() async {
    guard let connectedServer, let currentSession else { return }
    isLoadingTrash = true
    defer { isLoadingTrash = false }

    do {
      let assets = try await apiClient.fetchTrashedAssets(server: connectedServer, session: currentSession)
      trashedItems = assets.map {
        Self.makePhotoItem(from: $0, timeBucket: Self.timelineBucketKey(for: $0.createdAt))
      }
    } catch {
      immichLog("[Trash] Failed to load trashed assets: \(error)")
    }
  }

  func restoreItem(_ itemID: String) {
    guard let connectedServer, let currentSession else { return }
    if let item = trashedItems.first(where: { $0.id == itemID }) {
      trashedItems.removeAll { $0.id == itemID }
      libraryItems.insert(item, at: 0)
      libraryItems.sort { $0.date > $1.date }
      rebuildLibrarySections()
    }
    Task {
      do {
        try await apiClient.restoreAssets(server: connectedServer, session: currentSession, assetIds: [itemID])
      } catch {
        immichLog("[Restore] Failed: \(error)")
      }
    }
  }

  // MARK: - Multi-Select Actions

  func toggleMultiSelect() {
    isMultiSelectMode.toggle()
    if !isMultiSelectMode {
      selectedItemIDs.removeAll()
    }
  }

  func zoomOutPhotoGrid() {
    withAnimation(ImmichMotion.Curves.heroCollapse) {
      setPhotoGridScaleIndex(photoGridScaleIndex - 1)
    }
  }

  func zoomInPhotoGrid() {
    withAnimation(ImmichMotion.Curves.heroCollapse) {
      setPhotoGridScaleIndex(photoGridScaleIndex + 1)
    }
  }

  func toggleItemSelection(_ itemID: String) {
    if selectedItemIDs.contains(itemID) {
      selectedItemIDs.remove(itemID)
    } else {
      selectedItemIDs.insert(itemID)
    }
  }

  func setItemSelection(_ itemID: String, isSelected: Bool) {
    if isSelected {
      selectedItemIDs.insert(itemID)
    } else {
      selectedItemIDs.remove(itemID)
    }
  }

  func selectAllItems() {
    selectedItemIDs = Set(filteredItems.map(\.id))
  }

  func deselectAllItems() {
    selectedItemIDs.removeAll()
  }

  var allItemsSelected: Bool {
    !filteredItems.isEmpty && selectedItemIDs.count == filteredItems.count
  }

  func batchFavorite() {
    for id in selectedItemIDs {
      toggleFavorite(for: id)
    }
  }

  func batchTrash() {
    guard let connectedServer, let currentSession else { return }
    let ids = Array(selectedItemIDs)
    libraryItems.removeAll { ids.contains($0.id) }
    activeAlbumItems.removeAll { ids.contains($0.id) }
    activePersonItems.removeAll { ids.contains($0.id) }
    rebuildLibrarySections()
    selectedItemIDs.removeAll()
    if let selectedItemID, ids.contains(selectedItemID) {
      self.selectedItemID = filteredItems.first?.id
      isViewingPhoto = false
    }
    Task {
      do {
        try await apiClient.trashAssets(server: connectedServer, session: currentSession, assetIds: ids)
      } catch {
        immichLog("[BatchTrash] Failed: \(error)")
      }
    }
  }

  func batchDownload() {
    guard let connectedServer, let currentSession else { return }
    let ids = Array(selectedItemIDs)
    Task {
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.canCreateDirectories = true
      panel.prompt = "Choose Folder"
      let response: NSApplication.ModalResponse
      if let window = NSApp.keyWindow {
        response = await panel.beginSheetModal(for: window)
      } else {
        response = panel.runModal()
      }
      guard response == .OK, let folder = panel.url else { return }

      for id in ids {
        do {
          let payloads = try await downloadPayloads(
            for: id,
            server: connectedServer,
            session: currentSession
          )
          for payload in payloads {
            let fileURL = folder.appendingPathComponent(payload.filename)
            try payload.data.write(to: fileURL)
            immichLog("[BatchDownload] Saved \(payload.filename)")
          }
        } catch {
          immichLog("[BatchDownload] Failed for \(id): \(error)")
        }
      }
    }
  }

  private func downloadPayloads(
    for assetID: String,
    server: ImmichServer,
    session: UserSession
  ) async throws -> [DownloadedAssetPayload] {
    let (primaryData, primaryFilename) = try await apiClient.downloadOriginalAsset(
      server: server,
      session: session,
      assetId: assetID
    )

    var payloads = [DownloadedAssetPayload(data: primaryData, filename: primaryFilename)]

    guard let livePhotoVideoID = try await livePhotoVideoID(for: assetID),
          livePhotoVideoID != assetID else {
      return payloads
    }

    do {
      let (videoData, videoFilename) = try await apiClient.downloadOriginalAsset(
        server: server,
        session: session,
        assetId: livePhotoVideoID
      )
      payloads.append(DownloadedAssetPayload(data: videoData, filename: videoFilename))
    } catch {
      immichLog("[Download] Failed to download Live Photo movie for \(assetID): \(error)")
    }

    return payloads
  }

  private func livePhotoVideoID(for assetID: String) async throws -> String? {
    if let cachedID = photoItem(for: assetID)?.livePhotoVideoID {
      return cachedID
    }
    let detail = try await fetchAssetDetail(assetID)
    return detail.livePhotoVideoId
  }

  private func photoItem(for assetID: String) -> PhotoItem? {
    activeAlbumItems.first { $0.id == assetID }
      ?? activePersonItems.first { $0.id == assetID }
      ?? activeMemoryItems.first { $0.id == assetID }
      ?? libraryItems.first { $0.id == assetID }
      ?? trashedItems.first { $0.id == assetID }
  }

  private func companionDownloadURL(nextTo primaryURL: URL, companionFilename: String) -> URL {
    let ext = URL(fileURLWithPath: companionFilename).pathExtension
    let baseName = primaryURL.deletingPathExtension().lastPathComponent
    let companionName = ext.isEmpty ? companionFilename : "\(baseName).\(ext)"
    return primaryURL.deletingLastPathComponent().appendingPathComponent(companionName)
  }

  // MARK: - Album CRUD

  func createAlbum(name: String, description: String = "", assetIds: [String] = []) async {
    guard let connectedServer, let currentSession else { return }
    do {
      let album = try await apiClient.createAlbum(
        server: connectedServer, session: currentSession,
        name: name, description: description, assetIds: assetIds
      )
      albums.insert(album, at: 0)
      immichLog("[Album] Created: \(album.albumName)")
    } catch {
      immichLog("[Album] Create failed: \(error)")
    }
  }

  func renameAlbum(_ albumID: String, newName: String) async {
    guard let connectedServer, let currentSession else { return }
    do {
      try await apiClient.renameAlbum(
        server: connectedServer, session: currentSession, albumId: albumID, newName: newName
      )
      if let idx = albums.firstIndex(where: { $0.id == albumID }) {
        let old = albums[idx]
        albums[idx] = Album(
          id: old.id, albumName: newName, description: old.description,
          assetCount: old.assetCount, albumThumbnailAssetId: old.albumThumbnailAssetId,
          createdAt: old.createdAt, updatedAt: Date(),
          isActivityEnabled: old.isActivityEnabled, shared: old.shared,
          ownerID: old.ownerID
        )
      }
      immichLog("[Album] Renamed to: \(newName)")
    } catch {
      immichLog("[Album] Rename failed: \(error)")
    }
  }

  func deleteAlbum(_ albumID: String) async {
    guard let connectedServer, let currentSession else { return }
    do {
      try await apiClient.deleteAlbum(server: connectedServer, session: currentSession, albumId: albumID)
      albums.removeAll { $0.id == albumID }
      pinnedAlbumIDs.remove(albumID)
      UserDefaults.standard.set(Array(pinnedAlbumIDs), forKey: "immich.pinnedAlbums")
      if activeAlbumID == albumID {
        activeAlbumID = nil
        activeAlbumItems = []
        sidebarSelection = .allAlbums
      }
      immichLog("[Album] Deleted: \(albumID)")
    } catch {
      immichLog("[Album] Delete failed: \(error)")
    }
  }

  func addAssetsToAlbum(_ albumID: String, assetIds: [String]) async {
    guard let connectedServer, let currentSession else { return }
    do {
      try await apiClient.addAssetsToAlbum(
        server: connectedServer, session: currentSession, albumId: albumID, assetIds: assetIds
      )
      // Update the count
      if let idx = albums.firstIndex(where: { $0.id == albumID }) {
        let old = albums[idx]
        albums[idx] = Album(
          id: old.id, albumName: old.albumName, description: old.description,
          assetCount: old.assetCount + assetIds.count, albumThumbnailAssetId: old.albumThumbnailAssetId,
          createdAt: old.createdAt, updatedAt: Date(),
          isActivityEnabled: old.isActivityEnabled, shared: old.shared,
          ownerID: old.ownerID
        )
      }
      immichLog("[Album] Added \(assetIds.count) assets to \(albumID)")
    } catch {
      immichLog("[Album] Add assets failed: \(error)")
    }
  }

  func removeAssetsFromAlbum(_ albumID: String, assetIds: [String]) async {
    guard let connectedServer, let currentSession else { return }
    do {
      try await apiClient.removeAssetsFromAlbum(
        server: connectedServer, session: currentSession, albumId: albumID, assetIds: assetIds
      )
      activeAlbumItems.removeAll { assetIds.contains($0.id) }
      if let idx = albums.firstIndex(where: { $0.id == albumID }) {
        let old = albums[idx]
        albums[idx] = Album(
          id: old.id, albumName: old.albumName, description: old.description,
          assetCount: max(0, old.assetCount - assetIds.count), albumThumbnailAssetId: old.albumThumbnailAssetId,
          createdAt: old.createdAt, updatedAt: Date(),
          isActivityEnabled: old.isActivityEnabled, shared: old.shared,
          ownerID: old.ownerID
        )
      }
      immichLog("[Album] Removed \(assetIds.count) assets from \(albumID)")
    } catch {
      immichLog("[Album] Remove assets failed: \(error)")
    }
  }

  func selectNextItem() {
    guard !filteredItems.isEmpty else { return }
    guard let selectedItemID,
          let idx = filteredItems.firstIndex(where: { $0.id == selectedItemID }),
          idx < filteredItems.count - 1 else {
      selectedItemID = filteredItems.first?.id
      return
    }
    self.selectedItemID = filteredItems[idx + 1].id
  }

  func selectPreviousItem() {
    guard !filteredItems.isEmpty else { return }
    guard let selectedItemID,
          let idx = filteredItems.firstIndex(where: { $0.id == selectedItemID }),
          idx > 0 else { return }
    self.selectedItemID = filteredItems[idx - 1].id
  }

  var nextItem: PhotoItem? {
    guard !filteredItems.isEmpty else { return nil }
    guard let selectedItemID,
          let idx = filteredItems.firstIndex(where: { $0.id == selectedItemID }),
          idx < filteredItems.count - 1 else {
      return filteredItems.first
    }
    return filteredItems[idx + 1]
  }

  var previousItem: PhotoItem? {
    guard !filteredItems.isEmpty else { return nil }
    guard let selectedItemID,
          let idx = filteredItems.firstIndex(where: { $0.id == selectedItemID }),
          idx > 0 else { return nil }
    return filteredItems[idx - 1]
  }

  // MARK: - Pressure / Force Touch

  func handlePressureChange(stage: Int, pressure: Double) {
    let isDeepPress = stage == 2 || pressure > 0.65

    if isDeepPress {
      if !isViewingLivePhoto && !forceTouchConsumed {
        forceTouchConsumed = true
        if isViewingPhoto {
          withAnimation(ImmichMotion.Curves.interactiveFast) {
            isViewingLivePhoto = true
            isPeeking = false
          }
        } else if let hoveredID = hoveredItemID,
                  let item = libraryItems.first(where: { $0.id == hoveredID }),
                  item.livePhotoVideoID != nil {
          selectedItemID = hoveredID
          withAnimation(ImmichMotion.Curves.interactiveFast) {
            isViewingLivePhoto = true
            isViewingPhoto = true
            isPeeking = true
          }
        }
      }
    } else if pressure < 0.15 {
      forceTouchConsumed = false
      if isViewingLivePhoto {
        withAnimation(ImmichMotion.Curves.structuralShort) {
          isViewingLivePhoto = false
          if isPeeking {
            isViewingPhoto = false
            isPeeking = false
          }
        }
      }
    }
  }

  // MARK: - Import / Upload

  func importFiles(_ urls: [URL]) {
    for url in urls where Self.isSupportedImportURL(url) {
      let uploadItem = UploadItem(fileURL: url)
      let importDate = Self.localCreationDate(for: url) ?? .now
      let addedDate = Date()
      let isVideo = Self.isVideoImportURL(url)
      let item = PhotoItem(
        id: UUID().uuidString,
        source: .localFile(url),
        title: url.deletingPathExtension().lastPathComponent,
        date: importDate,
        dateAdded: addedDate,
        isFavorite: false,
        isVideo: isVideo,
        isImported: true,
        livePhotoVideoID: nil,
        latitude: nil,
        longitude: nil,
        durationText: isVideo ? "Ready" : nil,
        city: nil,
        country: nil,
        stackCount: nil,
        timeBucketKey: Self.timelineBucketKey(for: importDate),
        projectionType: nil,
        aspectRatio: Self.localAspectRatio(for: url, isVideo: isVideo)
      )

      uploadRows.insert(UploadRow(id: uploadItem.id, filename: url.lastPathComponent, progress: 0, state: .queued), at: 0)
      libraryItems.insert(item, at: 0)
      rebuildLibrarySections()

      Task {
        await uploadQueue.enqueue(uploadItem)
        await uploadAsset(uploadItem)
      }
    }
  }

  // MARK: - Pinning

  func togglePinAlbum(_ albumID: String) {
    if pinnedAlbumIDs.contains(albumID) {
      pinnedAlbumIDs.remove(albumID)
    } else {
      pinnedAlbumIDs.insert(albumID)
    }
    UserDefaults.standard.set(Array(pinnedAlbumIDs), forKey: "immich.pinnedAlbums")
  }

  // MARK: - Private Helpers

  private func updateTimelineStatus() {
    guard let session = currentSession else { return }
    if let err = timelineErrorMessage { statusText = err; return }
    let loaded = libraryItems.filter { !$0.isImported }.count
    if totalTimelineItemCount == 0 {
      statusText = "Signed in as \(session.userName) • No assets found"
    } else if canLoadMoreTimeline {
      statusText = "Signed in as \(session.userName) • \(loaded)/\(totalTimelineItemCount) items"
    } else {
      statusText = "Signed in as \(session.userName) • \(loaded) items"
    }
  }

  private func setPhotoGridScaleIndex(_ newValue: Int) {
    let clamped = min(max(newValue, 0), Self.photoGridThumbnailWidths.count - 1)
    guard clamped != photoGridScaleIndex else { return }
    photoGridScaleIndex = clamped
    UserDefaults.standard.set(clamped, forKey: Self.photoGridScaleKey)
  }

  private func uploadAsset(_ item: UploadItem) async {
    guard let connectedServer, let currentSession else {
      updateUploadRow(id: item.id, progress: 0, state: .failed(reason: "Not connected"))
      return
    }
    do {
      let remoteID = try await apiClient.uploadAsset(
        server: connectedServer, session: currentSession, fileURL: item.fileURL,
        onProgress: { [weak self] progress in
          Task { @MainActor in
            self?.updateUploadRow(id: item.id, progress: progress, state: .uploading(progress: progress))
          }
        }
      )
      await uploadQueue.markDone(item)
      updateUploadRow(id: item.id, progress: 1, state: .done)

      // Replace local item with remote asset reference
      if let idx = libraryItems.firstIndex(where: { $0.source == .localFile(item.fileURL) }) {
        let old = libraryItems[idx]
        let oldID = old.id
        libraryItems[idx] = PhotoItem(
          id: remoteID,
          source: .remoteAsset(id: remoteID),
          title: old.title,
          date: old.date,
          dateAdded: old.dateAdded,
          isFavorite: old.isFavorite,
          isVideo: old.isVideo,
          isImported: old.isImported,
          livePhotoVideoID: old.livePhotoVideoID,
          latitude: old.latitude,
          longitude: old.longitude,
          durationText: old.durationText,
          city: old.city,
          country: old.country,
          stackCount: old.stackCount,
          timeBucketKey: old.timeBucketKey,
          projectionType: old.projectionType,
          aspectRatio: old.aspectRatio
        )
        remapSelection(from: oldID, to: remoteID)
        rebuildLibrarySections()
      }
      immichLog("[Upload] Completed: \(item.fileURL.lastPathComponent) -> \(remoteID)")
    } catch {
      await uploadQueue.markFailed(item, reason: error.localizedDescription)
      updateUploadRow(id: item.id, progress: 0, state: .failed(reason: error.localizedDescription))

      if let idx = libraryItems.firstIndex(where: { $0.source == .localFile(item.fileURL) }) {
        libraryItems.remove(at: idx)
        rebuildLibrarySections()
      }

      withAnimation(ImmichMotion.Curves.uploadBannerSpring) {
        uploadNotification = UploadNotification(
          filename: item.fileURL.lastPathComponent,
          reason: error.localizedDescription,
          timestamp: .now
        )
      }

      let notificationID = uploadNotification?.id
      Task {
        try? await Task.sleep(for: .seconds(8))
        if uploadNotification?.id == notificationID {
          dismissUploadNotification()
        }
      }

      immichLog("[Upload] Failed: \(error)")
    }
  }

  private func updateUploadRow(id: UUID, progress: Double, state: UploadState) {
    guard let idx = uploadRows.firstIndex(where: { $0.id == id }) else { return }
    uploadRows[idx].progress = progress
    uploadRows[idx].state = state
  }

  private func remapSelection(from oldID: String, to newID: String) {
    if selectedItemID == oldID {
      selectedItemID = newID
    }
    if selectedItemIDs.remove(oldID) != nil {
      selectedItemIDs.insert(newID)
    }
  }

  private struct LoadedMapSelectionItem: Sendable {
    let detail: AssetDetail?
    let marker: MapMarker

    var hasFullDetail: Bool {
      detail != nil
    }
  }

  private nonisolated static func loadMapSelectionItems(
    markers: [MapMarker],
    server: ImmichServer,
    session: UserSession,
    apiClient: any ImmichAPIClient
  ) async -> [LoadedMapSelectionItem] {
    let concurrencyLimit = min(8, markers.count)
    guard concurrencyLimit > 0 else { return [] }

    return await withTaskGroup(of: LoadedMapSelectionItem.self, returning: [LoadedMapSelectionItem].self) { group in
      var markerIterator = markers.makeIterator()
      var loaded: [LoadedMapSelectionItem] = []

      func addNextTask() {
        guard let marker = markerIterator.next() else { return }
        group.addTask {
          let detail = await loadMapSelectionDetail(
            marker: marker,
            server: server,
            session: session,
            apiClient: apiClient
          )
          return LoadedMapSelectionItem(detail: detail, marker: marker)
        }
      }

      for _ in 0..<concurrencyLimit {
        addNextTask()
      }

      while let result = await group.next() {
        loaded.append(result)
        addNextTask()
      }

      return loaded
    }
  }

  private nonisolated static func loadMapSelectionDetail(
    marker: MapMarker,
    server: ImmichServer,
    session: UserSession,
    apiClient: any ImmichAPIClient
  ) async -> AssetDetail? {
    let maxAttempts = 3
    for attempt in 0..<maxAttempts {
      do {
        return try await apiClient.fetchAssetDetail(server: server, session: session, assetId: marker.id)
      } catch {
        if attempt == maxAttempts - 1 {
          return nil
        }
        let delayNanoseconds = UInt64(150_000_000 * (attempt + 1))
        try? await Task.sleep(nanoseconds: delayNanoseconds)
      }
    }
    return nil
  }

  private static func makePhotoItem(from loadedItem: LoadedMapSelectionItem) -> PhotoItem {
    if let detail = loadedItem.detail {
      let lowercasedType = detail.type.lowercased()
      let isVideo = lowercasedType.contains("video")
      let width = max(CGFloat(detail.width ?? 1), 1)
      let height = max(CGFloat(detail.height ?? 1), 1)
      let fallbackDate = detail.localDateTime ?? detail.fileCreatedAt ?? .distantPast

      return PhotoItem(
        id: detail.id,
        source: .remoteAsset(id: detail.id),
        title: detail.originalFileName,
        date: fallbackDate,
        dateAdded: fallbackDate,
        isFavorite: detail.isFavorite,
        isVideo: isVideo,
        isImported: false,
        livePhotoVideoID: detail.livePhotoVideoId,
        latitude: detail.exif?.latitude ?? loadedItem.marker.latitude,
        longitude: detail.exif?.longitude ?? loadedItem.marker.longitude,
        durationText: isVideo ? detail.duration : nil,
        city: detail.exif?.city ?? loadedItem.marker.city,
        country: detail.exif?.country ?? loadedItem.marker.country,
        stackCount: nil,
        timeBucketKey: timelineBucketKey(for: fallbackDate),
        projectionType: nil,
        aspectRatio: width / height
      )
    }

    let marker = loadedItem.marker
    let titleParts = [marker.city, marker.country]
      .compactMap { value -> String? in
        guard let value, !value.isEmpty else { return nil }
        return value
      }
    let title = titleParts.isEmpty ? "Pinned Photo" : titleParts.joined(separator: ", ")
    let fallbackDate = Date.distantPast

    return PhotoItem(
      id: marker.id,
      source: .remoteAsset(id: marker.id),
      title: title,
      date: fallbackDate,
      isFavorite: false,
      isVideo: false,
      isImported: false,
      livePhotoVideoID: nil,
      latitude: marker.latitude,
      longitude: marker.longitude,
      durationText: nil,
      city: marker.city,
      country: marker.country,
      stackCount: nil,
      timeBucketKey: timelineBucketKey(for: fallbackDate),
      projectionType: nil,
      aspectRatio: 1
    )
  }

  private func mergeTags(_ incomingTags: [ImmichTag]) {
    guard !incomingTags.isEmpty else { return }
    var merged = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
    for tag in incomingTags {
      merged[tag.id] = tag
    }
    tags = merged.values.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
  }

  private func upsertAdminUser(_ user: AdminUser) {
    adminUsers.removeAll { $0.id == user.id }
    adminUsers.append(user)
    adminUsers.sort(by: Self.sortAdminUsers)
  }

  private static func sortAdminUsers(_ lhs: AdminUser, _ rhs: AdminUser) -> Bool {
    if lhs.isDeleted != rhs.isDeleted {
      return !lhs.isDeleted && rhs.isDeleted
    }
    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
  }

  private static func normalizeTagNames(_ names: [String]) -> [String] {
    var seen = Set<String>()
    return names.compactMap { rawName in
      let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      let canonical = trimmed.lowercased()
      guard seen.insert(canonical).inserted else { return nil }
      return trimmed
    }
  }

  private static func parseDelimitedValues(_ rawValue: String, fallback: [String]) -> [String] {
    let values = rawValue
      .split(separator: ",")
      .map(String.init)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    return values.isEmpty ? fallback : values
  }

  private static func isAuthorizationError(_ error: Error) -> Bool {
    guard let apiError = error as? ImmichAPIError else { return false }
    guard case ImmichAPIError.requestFailed(let statusCode, _) = apiError else { return false }
    return statusCode == 401 || statusCode == 403
  }

  static func makePhotoItem(from asset: RemoteTimelineAsset, timeBucket: String) -> PhotoItem {
    let locationText = [asset.city, asset.country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    let title = locationText.isEmpty ? (asset.isImage ? "Photo" : "Video") : locationText

    return PhotoItem(
      id: asset.id,
      source: .remoteAsset(id: asset.id),
      title: title,
      date: asset.createdAt,
      dateAdded: asset.addedAt ?? asset.createdAt,
      isFavorite: asset.isFavorite,
      isVideo: !asset.isImage,
      isImported: false,
      livePhotoVideoID: asset.livePhotoVideoID,
      latitude: asset.latitude,
      longitude: asset.longitude,
      durationText: asset.duration,
      city: asset.city,
      country: asset.country,
      stackCount: asset.stackChildrenCount,
      timeBucketKey: timeBucket,
      projectionType: asset.projectionType,
      aspectRatio: CGFloat(asset.ratio)
    )
  }

  static func isSupportedImportURL(_ url: URL) -> Bool {
    isImageImportURL(url) || isVideoImportURL(url)
  }

  static func isImageImportURL(_ url: URL) -> Bool {
    if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
      return true
    }
    return fallbackImageExtensions.contains(url.pathExtension.lowercased())
  }

  static func isVideoImportURL(_ url: URL) -> Bool {
    if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .movie) || type.conforms(to: .video) {
      return true
    }
    return fallbackVideoExtensions.contains(url.pathExtension.lowercased())
  }

  private static func localCreationDate(for url: URL) -> Date? {
    let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
    guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
    return values.creationDate ?? values.contentModificationDate
  }

  private static func localAspectRatio(for url: URL, isVideo: Bool) -> CGFloat {
    guard !isVideo else { return 16.0 / 9.0 }
    guard let image = NSImage(contentsOf: url), image.size.height > 0 else { return 1 }
    return image.size.width / image.size.height
  }

  private static func timelineBucketKey(for date: Date) -> String {
    let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
    return String(format: "%04d-%02d-01", c.year ?? 1970, c.month ?? 1)
  }

  private static func date(forTimelineBucket value: String) -> Date? {
    timelineBucketFormatter.date(from: value)
  }
}

extension AppState: ImmichWebSocketDelegate {
  func webSocketDidConnect() {
    isWebSocketConnected = true
    immichLog("[WebSocket] Connected — live sync active")
    Task {
      await refreshVersionAnnouncement()
    }
  }

  func webSocketDidDisconnect() {
    isWebSocketConnected = false
    immichLog("[WebSocket] Disconnected")
  }

  func webSocketDidReceiveAssetUpload(assetJSON: [String: Any]) {
    guard let item = parseAssetResponseDTO(assetJSON) else { return }
    guard !libraryItems.contains(where: { $0.id == item.id }) else { return }
    libraryItems.insert(item, at: 0)
    libraryItems.sort { $0.date > $1.date }
    updateMediaCounts()
    rebuildLibrarySections()
    immichLog("[WebSocket] Asset uploaded: \(item.id)")
  }

  func webSocketDidReceiveAssetUpdate(assetJSON: [String: Any]) {
    guard let updated = parseAssetResponseDTO(assetJSON) else { return }
    if let idx = libraryItems.firstIndex(where: { $0.id == updated.id }) {
      libraryItems[idx] = updated
      libraryItems.sort { $0.date > $1.date }
      updateMediaCounts()
      rebuildLibrarySections()
    }
  }

  func webSocketDidReceiveAssetDelete(assetID: String) {
    libraryItems.removeAll { $0.id == assetID }
    if selectedItemID == assetID { selectedItemID = nil }
    selectedItemIDs.remove(assetID)
    updateMediaCounts()
    rebuildLibrarySections()
  }

  func webSocketDidReceiveAssetTrash(assetIDs: [String]) {
    let idSet = Set(assetIDs)
    libraryItems.removeAll { idSet.contains($0.id) }
    if let selected = selectedItemID, idSet.contains(selected) { selectedItemID = nil }
    selectedItemIDs.subtract(idSet)
    updateMediaCounts()
    rebuildLibrarySections()
  }

  func webSocketDidReceiveAssetRestore(assetIDs: [String]) {
    Task {
      await loadRemoteTimeline(reset: true)
    }
  }

  func webSocketDidReceiveReleaseNotification(releaseVersion: String, serverVersion: String?) {
    guard hasAdminAccess, let connectedServer else { return }
    let effectiveServerVersion = serverVersion ?? connectedServerVersion ?? releaseVersion
    evaluateVersionAnnouncement(
      releaseVersion: releaseVersion,
      serverVersion: effectiveServerVersion,
      server: connectedServer
    )
  }

  private func parseAssetResponseDTO(_ json: [String: Any]) -> PhotoItem? {
    guard let id = json["id"] as? String else { return nil }

    let typeString = (json["type"] as? String)?.lowercased() ?? "image"
    let isVideo = typeString.contains("video")

    let isFavorite = json["isFavorite"] as? Bool ?? false
    let isTrashed = json["isTrashed"] as? Bool ?? false
    guard !isTrashed else { return nil }

    let width = max(CGFloat(json["width"] as? Int ?? 1), 1)
    let height = max(CGFloat(json["height"] as? Int ?? 1), 1)

    let dateString = json["localDateTime"] as? String ?? json["fileCreatedAt"] as? String
    let date = dateString.flatMap { Self.parseISO8601Date($0) } ?? .now
    let addedDate = (json["createdAt"] as? String).flatMap { Self.parseISO8601Date($0) } ?? date

    let duration = json["duration"] as? String
    let livePhotoVideoId = json["livePhotoVideoId"] as? String
    let originalFileName = json["originalFileName"] as? String ?? "Photo"

    var city: String?
    var country: String?
    var latitude: Double?
    var longitude: Double?
    if let exif = json["exifInfo"] as? [String: Any] {
      city = exif["city"] as? String
      country = exif["country"] as? String
      latitude = exif["latitude"] as? Double
      longitude = exif["longitude"] as? Double
    }

    return PhotoItem(
      id: id,
      source: .remoteAsset(id: id),
      title: originalFileName,
      date: date,
      dateAdded: addedDate,
      isFavorite: isFavorite,
      isVideo: isVideo,
      isImported: false,
      livePhotoVideoID: livePhotoVideoId,
      latitude: latitude,
      longitude: longitude,
      durationText: isVideo ? duration : nil,
      city: city,
      country: country,
      stackCount: nil,
      timeBucketKey: Self.timelineBucketKey(for: date),
      projectionType: nil,
      aspectRatio: width / height
    )
  }

  private static func parseISO8601Date(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
  }
}
#endif

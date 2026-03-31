#if canImport(SwiftUI) && canImport(AppKit)
import Foundation
import SwiftUI
import AppKit
import AuthenticationServices
import UniformTypeIdentifiers
import ImmichAPI
import ImmichCore
import ImmichSync

// MARK: - App State (replaces ContentViewModel)

@MainActor
final class AppState: ObservableObject {

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

  struct PhotoItem: Identifiable {
    enum Source: Hashable {
      case localFile(URL)
      case remoteAsset(id: String)
    }

    let id: String
    let source: Source
    var title: String
    var date: Date
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
    var isPanorama: Bool { projectionType == "EQUIRECTANGULAR" }
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
  @Published var serverURLText = UserDefaults.standard.string(forKey: "immich.serverURL") ?? ""
  @Published var emailText = UserDefaults.standard.string(forKey: "immich.email") ?? ""
  @Published var passwordText = KeychainHelper.load(account: "immich.password") ?? ""
  @Published var apiKeyText = KeychainHelper.load(account: "immich.apiKey") ?? ""
  @Published var statusText = "Enter your Immich server URL to continue."
  @Published var isConnecting = false
  @Published var isSigningIn = false
  @Published var loginPageMessage: String?
  @Published var oauthEnabled = false
  @Published var oauthButtonText = "OAuth"
  @Published var passwordLoginEnabled = true
  @Published var connectedServerVersion: String?
  @Published var connectedServerDisplayURL: String?
  @Published var currentSession: UserSession?

  // Navigation
  @Published var sidebarSelection: SidebarDestination? = .library

  // Library
  @Published var libraryItems: [PhotoItem] = []
  @Published var isLoadingTimeline = false
  @Published var searchText = ""
  @Published var photoGridScaleIndex = AppState.initialPhotoGridScaleIndex()

  // Smart search
  @Published var searchResults: [PhotoItem] = []
  @Published var isSearching = false
  @Published var searchTotalCount = 0
  private var searchTask: Task<Void, Never>?

  // Album detail
  @Published var activeAlbumID: String?
  @Published var activeAlbumItems: [PhotoItem] = []
  @Published var isLoadingAlbum = false

  // Person detail
  @Published var activePersonID: String?
  @Published var activePersonItems: [PhotoItem] = []
  @Published var isLoadingPerson = false

  // Shared link detail
  @Published var activeSharedLinkID: String?
  @Published var activeSharedLinkItems: [PhotoItem] = []
  var sharedLinkAssets: [String: [RemoteTimelineAsset]] = [:]

  // Memory detail
  @Published var activeMemoryID: String?
  @Published var activeMemoryItems: [PhotoItem] = []

  // Trash
  @Published var trashedItems: [PhotoItem] = []
  @Published var isLoadingTrash = false

  // Viewer
  @Published var selectedItemID: String?
  @Published var isViewingPhoto = false
  @Published var isViewingLivePhoto = false
  @Published var isPeeking = false
  @Published var showInfoPopover = false
  @Published var hoveredItemID: String?

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
  @Published var sharedLinks: [SharedLink] = []
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
  private var connectedServer: ImmichServer?
  private var timelineBuckets: [TimelineBucketSummary] = []
  private var loadedTimelineBucketKeys: [String] = []
  private var totalTimelineItemCount = 0
  private var timelineErrorMessage: String?

  struct ThumbnailContext {
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
  private static let photoGridScaleKey = "immich.photoGridScaleIndex"
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

  // MARK: - Computed Properties

  var selectedItem: PhotoItem? {
    guard let selectedItemID else { return nil }
    // Check active album items first, then main library, then trash
    return activeAlbumItems.first { $0.id == selectedItemID }
      ?? activePersonItems.first { $0.id == selectedItemID }
      ?? activeSharedLinkItems.first { $0.id == selectedItemID }
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
    let sectionFiltered: [PhotoItem] = {
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
        return libraryItems.filter { $0.title.localizedCaseInsensitiveContains("screenshot") }
      case .imports:
        return libraryItems.filter(\.isImported)
      case .album, .pinnedAlbum:
        return activeAlbumItems
      case .person:
        return activePersonItems
      case .sharedLink:
        return activeSharedLinkItems
      case .memory:
        return activeMemoryItems
      case .recentlyDeleted:
        return trashedItems
      case .allAlbums, .collections, .sharedLinks:
        return [] // Handled by dedicated views, not LibraryGridView
      }
    }()

    guard !searchText.isEmpty else { return sectionFiltered }
    // If we have server search results, show those instead of local filter
    if !searchResults.isEmpty || isSearching {
      return searchResults
    }
    return sectionFiltered.filter {
      $0.title.localizedCaseInsensitiveContains(searchText)
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

  func rebuildLibrarySections() {
    let items = libraryItems
    let groupedItems = Dictionary(grouping: items, by: \.timeBucketKey)
    librarySections = groupedItems.keys.sorted(by: >).compactMap { bucketKey in
      guard let items = groupedItems[bucketKey]?.sorted(by: { $0.date > $1.date }) else { return nil }
      return LibrarySection(
        id: bucketKey,
        title: Self.date(forTimelineBucket: bucketKey).map(Self.timelineSectionFormatter.string(from:)) ?? bucketKey,
        itemCount: items.count,
        items: items
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
    return "\(filteredItems.count) items"
  }

  var emptyStateTitle: String {
    switch sidebarSelection {
    case .library: isLoadingTimeline ? "Loading timeline" : "Library is empty"
    case .favorites: "No favorites yet"
    case .videos: "No videos yet"
    case .livePhotos: "No Live Photos yet"
    case .panoramas: "No panoramas yet"
    case .imports: "No imports yet"
    case .recentlyDeleted: "Trash is empty"
    default: "No items"
    }
  }

  var emptyStateMessage: String {
    switch sidebarSelection {
    case .library:
      if isLoadingTimeline { return "Fetching latest from your Immich library." }
      if let msg = timelineErrorMessage { return msg }
      if let s = currentSession { return "Signed in as \(s.userEmail), but timeline is empty." }
      return "Sign in to an Immich server to continue."
    case .imports:
      return "Drag files into the window or use the import button."
    default:
      return "Content will appear here once available."
    }
  }

  // MARK: - Init

  private static func initialAuthMethod() -> AuthMethod {
    if let rawValue = UserDefaults.standard.string(forKey: "immich.authMethod"),
       let method = AuthMethod(rawValue: rawValue) {
      return method
    }
    if let savedKey = KeychainHelper.load(account: "immich.apiKey"), !savedKey.isEmpty {
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
    let hasSavedServer = UserDefaults.standard.string(forKey: "immich.serverURL") != nil
    let hasSavedPasswordLogin =
      UserDefaults.standard.string(forKey: "immich.email") != nil &&
      (KeychainHelper.load(account: "immich.password")?.isEmpty == false)
    let hasSavedAPIKey = KeychainHelper.load(account: "immich.apiKey")?.isEmpty == false

    if hasSavedServer && (hasSavedPasswordLogin || hasSavedAPIKey) {
      return .launching
    }
    return .serverSetup
  }

  init(apiClient: any ImmichAPIClient = URLSessionImmichAPIClient()) {
    self.apiClient = apiClient
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
      UserDefaults.standard.set(trimmed, forKey: "immich.serverURL")
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
      authMethod = .password
      UserDefaults.standard.set(AuthMethod.password.rawValue, forKey: "immich.authMethod")
      UserDefaults.standard.set(trimmedEmail, forKey: "immich.email")
      KeychainHelper.save(account: "immich.password", password: passwordText)
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
      authMethod = .apiKey
      UserDefaults.standard.set(AuthMethod.apiKey.rawValue, forKey: "immich.authMethod")
      KeychainHelper.save(account: "immich.apiKey", password: trimmedKey)
      if session.userEmail != "API key session" {
        UserDefaults.standard.set(session.userEmail, forKey: "immich.email")
        emailText = session.userEmail
      }
      currentSession = session
      resetLibraryState()
      hasAdminAccess = session.isAdmin || session.usesAPIKey
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

      if authMethod == .apiKey, apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
        await signInWithAPIKey()
      } else if emailText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                passwordText.isEmpty == false {
        await signIn()
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
        let redirectUri = "immich://oauth-callback"
        let oauthURL = try await apiClient.startOAuth(server: connectedServer, redirectUri: redirectUri)

        guard let url = URL(string: oauthURL) else {
          statusText = "Invalid OAuth URL from server"
          isSigningIn = false
          return
        }

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
          let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "immich") { callbackURL, error in
            if let error {
              continuation.resume(throwing: error)
            } else if let callbackURL {
              continuation.resume(returning: callbackURL)
            } else {
              continuation.resume(throwing: ImmichAPIError.invalidResponse(url: "oauth"))
            }
          }
          session.prefersEphemeralWebBrowserSession = false
          session.start()
        }

        let session = try await apiClient.finishOAuth(server: connectedServer, oauthCallbackUrl: callbackURL.absoluteString)
        currentSession = session
        emailText = session.userEmail
        UserDefaults.standard.set(session.userEmail, forKey: "immich.email")
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
    currentSession = nil
    passwordText = ""
    apiKeyText = ""
    resetLibraryState()
    appPhase = .login
    statusText = "Connected • Immich \(connectedServerVersion ?? "")"
  }

  func changeServer() {
    connectedServer = nil
    connectedServerDisplayURL = nil
    connectedServerVersion = nil
    loginPageMessage = nil
    oauthEnabled = false
    passwordLoginEnabled = true
    emailText = ""
    passwordText = ""
    apiKeyText = ""
    currentSession = nil
    resetLibraryState()
    appPhase = .serverSetup
    statusText = "Enter your Immich server URL to continue."
  }

  private func resetLibraryState() {
    searchText = ""
    searchResults = []
    isSearching = false
    searchTotalCount = 0
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
    uploadRows = []
    sidebarSelection = .library
    timelineBuckets = []
    loadedTimelineBucketKeys = []
    totalTimelineItemCount = 0
    timelineErrorMessage = nil
    albums = []
    people = []
    memories = []
    sharedLinks = []
    apiKeys = []
    tags = []
    adminUsers = []
    activeTagEditorAssetIDs = []
    activeTagEditorCurrentTags = []
    activeTagEditorTitle = "Edit Tags"
    hasAdminAccess = false
    sharedLinkAssets = [:]
    activeSharedLinkID = nil
    activeSharedLinkItems = []
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
  }

  // MARK: - Data Loading

  func loadInitialData() async {
    async let timelineTask: () = loadRemoteTimeline(reset: true)
    async let collectionsTask: () = loadCollections()
    _ = await (timelineTask, collectionsTask)
  }

  func loadCollections() async {
    guard let connectedServer, let currentSession else { return }
    // Fire all collection fetches in parallel
    async let albumsResult = apiClient.fetchAlbums(server: connectedServer, session: currentSession)
    async let peopleResult = apiClient.fetchPeople(server: connectedServer, session: currentSession)
    async let statsResult = apiClient.fetchAssetStatistics(server: connectedServer, session: currentSession)
    async let memoriesResult = apiClient.fetchMemories(server: connectedServer, session: currentSession)
    async let sharedResult = apiClient.fetchSharedLinks(server: connectedServer, session: currentSession)

    do { albums = try await albumsResult } catch { immichLog("[Collections] Albums failed: \(error)") }
    do { people = try await peopleResult } catch { immichLog("[Collections] People failed: \(error)") }
    do { assetStatistics = try await statsResult } catch { immichLog("[Collections] Stats failed: \(error)") }
    do { memories = try await memoriesResult } catch { immichLog("[Collections] Memories failed: \(error)") }
    do {
      let (links, assets) = try await sharedResult
      sharedLinks = links
      sharedLinkAssets = assets
    } catch { immichLog("[Collections] Shared links failed: \(error)") }
  }

  @discardableResult
  func reloadSharedLinks() async -> String? {
    guard let connectedServer, let currentSession else { return "Not connected to server." }
    do {
      let (links, assets) = try await apiClient.fetchSharedLinks(server: connectedServer, session: currentSession)
      sharedLinks = links
      sharedLinkAssets = assets
      immichLog("[SharedLinks] Loaded \(links.count) links")
      return nil
    } catch {
      immichLog("[SharedLinks] Reload failed: \(error)")
      return error.localizedDescription
    }
  }

  func loadSharedLink(_ linkID: String) {
    guard activeSharedLinkID != linkID else { return }
    activeSharedLinkID = linkID
    let assets = sharedLinkAssets[linkID] ?? []
    activeSharedLinkItems = assets.filter { !$0.isTrashed }.map {
      Self.makePhotoItem(from: $0, timeBucket: Self.timelineBucketKey(for: $0.createdAt))
    }
  }

  // MARK: - Smart Search

  func performSmartSearch(query: String) {
    searchTask?.cancel()
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmed.isEmpty else {
      searchResults = []
      isSearching = false
      searchTotalCount = 0
      return
    }

    isSearching = true
    searchTask = Task {
      // Debounce: wait 300ms so we don't fire on every keystroke
      do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
      guard !Task.isCancelled else { return }
      guard let connectedServer, let currentSession else {
        isSearching = false
        return
      }

      do {
        let result = try await apiClient.searchAssets(
          server: connectedServer, session: currentSession, query: trimmed
        )
        guard !Task.isCancelled else { return }
        searchResults = result.assets.filter { !$0.isTrashed }.map {
          Self.makePhotoItem(from: $0, timeBucket: Self.timelineBucketKey(for: $0.createdAt))
        }
        searchTotalCount = result.totalCount
      } catch {
        guard !Task.isCancelled else { return }
        immichLog("[Search] Smart search failed: \(error)")
      }
      isSearching = false
    }
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
      let dedup = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
      loadedTimelineBucketKeys.append(contentsOf: fetchedKeys)
      libraryItems = dedup.values.sorted { $0.date > $1.date }
      updateMediaCounts()
      rebuildLibrarySections()
    } catch {
      timelineErrorMessage = "Couldn't load more photos: \(error.localizedDescription)"
    }
  }

  func loadMoreTimelineIfNeeded(after sectionID: String) {
    guard appPhase == .library, sidebarSelection == .library, searchText.isEmpty,
          canLoadMoreTimeline, !isLoadingTimeline, loadedTimelineBucketKeys.last == sectionID else { return }
    Task { await loadNextTimelinePage() }
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

    if let index = activeSharedLinkItems.firstIndex(where: { $0.id == itemID }) {
      if let newVal {
        activeSharedLinkItems[index].isFavorite = newVal
      } else {
        activeSharedLinkItems[index].isFavorite.toggle()
        newVal = activeSharedLinkItems[index].isFavorite
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
        if let idx = activeSharedLinkItems.firstIndex(where: { $0.id == itemID }) {
          activeSharedLinkItems[idx].isFavorite = !newVal
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
    activeSharedLinkItems.removeAll { $0.id == itemID }
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
        let (data, filename) = try await apiClient.downloadOriginalAsset(
          server: connectedServer, session: currentSession, assetId: assetID
        )
        // Write to temp file for sharing
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: tempURL)
        let picker = NSSharingServicePicker(items: [tempURL])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
      } catch {
        immichLog("[Share] Failed: \(error)")
      }
    }
  }

  // MARK: - Trash Loading

  // MARK: - Photo Editing (Save / Export)

  func saveEditedImage(pipeline: PhotoEditingPipeline) {
    guard let connectedServer, let currentSession, let item = selectedItem else { return }
    guard let jpegData = pipeline.renderFinalJPEG() else {
      immichLog("[Edit] Failed to render final JPEG")
      return
    }
    Task {
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
    guard let jpegData = pipeline.renderFinalJPEG() else {
      immichLog("[Edit] Failed to render for export")
      return
    }
    Task {
      let panel = NSSavePanel()
      let defaultName = selectedItem?.title ?? "Edited Photo"
      panel.nameFieldStringValue = "\(defaultName)_edited.jpg"
      panel.canCreateDirectories = true
      panel.allowedContentTypes = [.jpeg, .png]
      guard let window = NSApp.keyWindow else { return }
      let response = await panel.beginSheetModal(for: window)
      if response == .OK, let url = panel.url {
        do {
          let dataToWrite: Data
          if url.pathExtension.lowercased() == "png" {
            dataToWrite = pipeline.renderFinalPNG() ?? jpegData
          } else {
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
    withAnimation(.easeInOut(duration: 0.22)) {
      setPhotoGridScaleIndex(photoGridScaleIndex - 1)
    }
  }

  func zoomInPhotoGrid() {
    withAnimation(.easeInOut(duration: 0.22)) {
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
    activeSharedLinkItems.removeAll { ids.contains($0.id) }
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
      ?? activeSharedLinkItems.first { $0.id == assetID }
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
          hasSharedLink: old.hasSharedLink, ownerID: old.ownerID
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
          hasSharedLink: old.hasSharedLink, ownerID: old.ownerID
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
          hasSharedLink: old.hasSharedLink, ownerID: old.ownerID
        )
      }
      immichLog("[Album] Removed \(assetIds.count) assets from \(albumID)")
    } catch {
      immichLog("[Album] Remove assets failed: \(error)")
    }
  }

  func selectNextItem() {
    guard let selectedItemID,
          let idx = filteredItems.firstIndex(where: { $0.id == selectedItemID }),
          idx < filteredItems.count - 1 else {
      selectedItemID = filteredItems.first?.id
      return
    }
    self.selectedItemID = filteredItems[idx + 1].id
  }

  func selectPreviousItem() {
    guard let selectedItemID,
          let idx = filteredItems.firstIndex(where: { $0.id == selectedItemID }),
          idx > 0 else { return }
    self.selectedItemID = filteredItems[idx - 1].id
  }

  // MARK: - Pressure / Force Touch

  func handlePressureChange(stage: Int, pressure: Double) {
    let isDeepPress = stage == 2 || pressure > 0.65

    if isDeepPress {
      if !isViewingLivePhoto {
        if isViewingPhoto {
          withAnimation(.easeInOut(duration: 0.15)) {
            isViewingLivePhoto = true
            isPeeking = false
          }
        } else if let hoveredID = hoveredItemID,
                  let item = libraryItems.first(where: { $0.id == hoveredID }),
                  item.livePhotoVideoID != nil {
          selectedItemID = hoveredID
          withAnimation(.easeInOut(duration: 0.15)) {
            isViewingLivePhoto = true
            isViewingPhoto = true
            isPeeking = true
          }
        }
      }
    } else if pressure < 0.15 {
      if isViewingLivePhoto {
        withAnimation(.easeInOut(duration: 0.2)) {
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
    for url in urls {
      let uploadItem = UploadItem(fileURL: url)
      let isVideo = ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased())
      let item = PhotoItem(
        id: UUID().uuidString,
        source: .localFile(url),
        title: url.deletingPathExtension().lastPathComponent,
        date: .now,
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
        timeBucketKey: Self.timelineBucketKey(for: .now),
        projectionType: nil,
        aspectRatio: Self.localAspectRatio(for: url, isVideo: isVideo)
      )

      uploadRows.insert(UploadRow(id: uploadItem.id, filename: url.lastPathComponent, progress: 0, state: .queued), at: 0)
      libraryItems.insert(item, at: 0)
      rebuildLibrarySections()

      Task {
        await uploadQueue.enqueue(uploadItem)
        await simulateUpload(uploadItem)
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

  private func simulateUpload(_ item: UploadItem) async {
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
        libraryItems[idx] = PhotoItem(
          id: remoteID.isEmpty ? old.id : remoteID,
          source: remoteID.isEmpty ? old.source : .remoteAsset(id: remoteID),
          title: old.title,
          date: old.date,
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
        rebuildLibrarySections()
      }
      immichLog("[Upload] Completed: \(item.fileURL.lastPathComponent) -> \(remoteID)")
    } catch {
      // UploadQueue only exposes markDone (no markFailed); clearing it here so the queue can proceed
      await uploadQueue.markDone(item)
      updateUploadRow(id: item.id, progress: 0, state: .failed(reason: error.localizedDescription))
      immichLog("[Upload] Failed: \(error)")
    }
  }

  private func updateUploadRow(id: UUID, progress: Double, state: UploadState) {
    guard let idx = uploadRows.firstIndex(where: { $0.id == id }) else { return }
    uploadRows[idx].progress = progress
    uploadRows[idx].state = state
  }

  private func mergeTags(_ incomingTags: [ImmichTag]) {
    guard !incomingTags.isEmpty else { return }
    var merged = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
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
#endif

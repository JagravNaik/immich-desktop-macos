import Foundation
import ImmichAPI
import ImmichCore
import ImmichSync

#if canImport(SwiftUI)
import SwiftUI

@MainActor
final class ContentViewModel: ObservableObject {
  enum AppPhase {
    case launching
    case serverSetup
    case login
    case library
  }

  enum SidebarItem: String, CaseIterable, Identifiable {
    case library = "Library"
    case favorites = "Favorites"
    case recents = "Recents"
    case videos = "Videos"
    case imports = "Imports"

    var id: String { rawValue }

    var iconName: String {
      switch self {
      case .library:
        "photo.on.rectangle.angled"
      case .favorites:
        "heart"
      case .recents:
        "clock"
      case .videos:
        "film"
      case .imports:
        "square.and.arrow.down"
      }
    }
  }

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

    var timeLabel: String {
      if let durationText, isVideo {
        return durationText
      }
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

  @Published var appPhase: AppPhase = {
    if UserDefaults.standard.string(forKey: "immich.serverURL") != nil,
       UserDefaults.standard.string(forKey: "immich.email") != nil,
       let pass = UserDefaults.standard.string(forKey: "immich.password"), !pass.isEmpty {
      return .launching
    }
    return .serverSetup
  }()
  @Published var serverURLText = UserDefaults.standard.string(forKey: "immich.serverURL") ?? ""
  @Published var emailText = UserDefaults.standard.string(forKey: "immich.email") ?? ""
  @Published var passwordText = UserDefaults.standard.string(forKey: "immich.password") ?? ""
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
  @Published var isLoadingTimeline = false

  @Published var searchText = ""
  @Published var selectedSidebarItem: SidebarItem = .library
  @Published var selectedItemID: String?
  @Published var isViewingPhoto = false
  @Published var isViewingLivePhoto = false
  @Published var isPeeking = false
  @Published var showInfoPopover = false
  @Published var uploadRows: [UploadRow] = []
  @Published var libraryItems: [PhotoItem] = []
  @Published var hoveredItemID: String?

  func handlePressureChange(stage: Int, pressure: Double) {
    // Detailed logging for debugging
    if pressure > 0.05 {
        immichLog("[Pressure] Stage: \(stage), Pressure: \(String(format: "%.2f", pressure)), Hovered: \(self.hoveredItemID ?? "none"), Viewing: \(self.isViewingPhoto)")
    }

    // Thresholds: Stage 2 is "Deep Press", but we can also use raw pressure for sensitivity
    let isDeepPress = stage == 2 || pressure > 0.65
    
    if isDeepPress {
      if !self.isViewingLivePhoto {
        // Determine which item is being targeted
        if self.isViewingPhoto {
          // Already in viewer, just start playback
          immichLog("[Pressure] Deep press ACTIVATED while in viewer")
          withAnimation(.easeInOut(duration: 0.15)) {
            self.isViewingLivePhoto = true
            self.isPeeking = false
          }
        } else if let hoveredID = self.hoveredItemID,
                  let item = self.libraryItems.first(where: { $0.id == hoveredID }),
                  item.livePhotoVideoID != nil {
          // In grid, start peek
          immichLog("[Pressure] Deep press ACTIVATED from grid on \(hoveredID)")
          self.selectedItemID = hoveredID
          withAnimation(.easeInOut(duration: 0.15)) {
            self.isViewingLivePhoto = true
            self.isViewingPhoto = true
            self.isPeeking = true
          }
        }
      }
    } else if pressure < 0.15 {
      // Released or returning to normal click stage
      if self.isViewingLivePhoto {
        immichLog("[Pressure] Deep press RELEASED. isPeeking: \(self.isPeeking)")
        withAnimation(.easeInOut(duration: 0.2)) {
          self.isViewingLivePhoto = false
          if self.isPeeking {
            self.isViewingPhoto = false
            self.isPeeking = false
          }
        }
      }
    }
  }

  func selectNextItem() {
    guard let selectedItemID, let currentIndex = filteredItems.firstIndex(where: { $0.id == selectedItemID }) else {
      selectedItemID = filteredItems.first?.id
      return
    }
    if currentIndex < filteredItems.count - 1 {
      self.selectedItemID = filteredItems[currentIndex + 1].id
    }
  }

  func selectPreviousItem() {
    guard let selectedItemID, let currentIndex = filteredItems.firstIndex(where: { $0.id == selectedItemID }) else {
      selectedItemID = filteredItems.first?.id
      return
    }
    if currentIndex > 0 {
      self.selectedItemID = filteredItems[currentIndex - 1].id
    }
  }

  var filteredItems: [PhotoItem] {
    let sectionFiltered: [PhotoItem] = switch selectedSidebarItem {
    case .library:
      libraryItems
    case .favorites:
      libraryItems.filter(\.isFavorite)
    case .videos:
      libraryItems.filter(\.isVideo)
    case .imports:
      libraryItems.filter(\.isImported)
    case .recents:
      libraryItems.sorted { $0.date > $1.date }
    }

    guard searchText.isEmpty == false else {
      return sectionFiltered
    }

    return sectionFiltered.filter {
      $0.title.localizedCaseInsensitiveContains(searchText)
    }
  }

  var librarySections: [LibrarySection] {
    guard selectedSidebarItem == .library else {
      return []
    }

    let groupedItems = Dictionary(grouping: filteredItems, by: \.timeBucketKey)
    return groupedItems
      .keys
      .sorted(by: >)
      .compactMap { bucketKey in
        guard let items = groupedItems[bucketKey]?.sorted(by: { $0.date > $1.date }) else {
          return nil
        }

        return LibrarySection(
          id: bucketKey,
          title: Self.date(forTimelineBucket: bucketKey).map(Self.timelineSectionFormatter.string(from:)) ?? bucketKey,
          itemCount: items.count,
          items: items
        )
      }
  }

  var selectedItem: PhotoItem? {
    guard let selectedItemID else { return nil }
    return libraryItems.first(where: { $0.id == selectedItemID })
  }

  var itemCountText: String {
    if selectedSidebarItem == .library, totalTimelineItemCount > loadedRemoteTimelineItemCount, searchText.isEmpty {
      return "\(loadedRemoteTimelineItemCount) of \(totalTimelineItemCount) items loaded"
    }

    return "\(filteredItems.count) items"
  }

  var canLoadMoreTimeline: Bool {
    loadedTimelineBucketKeys.count < timelineBuckets.count
  }

  var timelineFooterMessage: String? {
    guard selectedSidebarItem == .library, searchText.isEmpty else {
      return nil
    }

    if isLoadingTimeline, libraryItems.isEmpty == false {
      return "Loading more photos…"
    }

    if canLoadMoreTimeline {
      return "Load more"
    }

    return nil
  }

  var thumbnailContext: ThumbnailContext? {
    guard let connectedServer, let currentSession else {
      return nil
    }

    return ThumbnailContext(baseURL: connectedServer.baseURL, accessToken: currentSession.accessToken)
  }

  var emptyStateTitle: String {
    switch selectedSidebarItem {
    case .library:
      if isLoadingTimeline {
        return "Loading timeline"
      }

      return "Library is empty"
    case .favorites:
      return "No favorites yet"
    case .recents:
      return "No recent items"
    case .videos:
      return "No videos yet"
    case .imports:
      return "No imports yet"
    }
  }

  var emptyStateMessage: String {
    switch selectedSidebarItem {
    case .library:
      if isLoadingTimeline {
        return "We’re fetching the latest months from your Immich library."
      }

      if let timelineErrorMessage {
        return timelineErrorMessage
      }

      if let session = currentSession {
        return "Signed in as \(session.userEmail), but this timeline does not have any assets yet."
      }

      return "Sign in to an Immich server to continue."
    case .imports:
      return "Use the plus button or drag files into the window to populate this local import view."
    case .favorites, .recents, .videos:
      return "Content will appear here once the corresponding library data is available."
    }
  }

  private let apiClient: any ImmichAPIClient
  private let uploadQueue = UploadQueue()
  private var connectedServer: ImmichServer?
  private var timelineBuckets: [TimelineBucketSummary] = []
  private var loadedTimelineBucketKeys: [String] = []
  private var totalTimelineItemCount = 0
  private var timelineErrorMessage: String?

  struct ThumbnailContext {
    let baseURL: URL
    let accessToken: String
  }

  private var loadedRemoteTimelineItemCount: Int {
    libraryItems.filter { !$0.isImported }.count
  }

  private static let timelinePageSize = 6
  private static let timelineBucketFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter
  }()
  private static let timelineSectionFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "LLLL yyyy"
    return formatter
  }()

  init(apiClient: any ImmichAPIClient = URLSessionImmichAPIClient()) {
    self.apiClient = apiClient
  }

  func connect() async {
    let trimmedServerURL = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let url = URL(string: trimmedServerURL), url.scheme?.isEmpty == false else {
      statusText = "Invalid server URL"
      return
    }

    isConnecting = true
    defer { isConnecting = false }

    do {
      let server = ImmichServer(endpointURL: url)
      let info = try await apiClient.fetchServerInfo(
        server: server,
        apiKey: nil
      )
      let loginConfiguration = try await apiClient.fetchLoginConfiguration(server: server)

      connectedServer = server
      connectedServerDisplayURL = trimmedServerURL
      connectedServerVersion = info.version
      loginPageMessage = loginConfiguration.loginPageMessage.isEmpty ? nil : loginConfiguration.loginPageMessage
      passwordLoginEnabled = loginConfiguration.passwordLoginEnabled
      oauthEnabled = loginConfiguration.oauthEnabled
      oauthButtonText = loginConfiguration.oauthButtonText.isEmpty ? "OAuth" : loginConfiguration.oauthButtonText
      
      UserDefaults.standard.set(trimmedServerURL, forKey: "immich.serverURL")
      
      appPhase = .login
      statusText = "Connected • Immich \(info.version)"
    } catch {
      statusText = "Connection failed: \(error.localizedDescription)"
    }
  }

  func signIn() async {
    let trimmedEmail = emailText.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let connectedServer else {
      changeServer()
      statusText = "Enter your Immich server URL to continue."
      return
    }

    guard trimmedEmail.isEmpty == false else {
      statusText = "Enter your email address."
      return
    }

    guard passwordText.isEmpty == false else {
      statusText = "Enter your password."
      return
    }

    isSigningIn = true
    defer { isSigningIn = false }

    do {
      let session = try await apiClient.login(server: connectedServer, email: trimmedEmail, password: passwordText)
      emailText = trimmedEmail
      UserDefaults.standard.set(trimmedEmail, forKey: "immich.email")
      UserDefaults.standard.set(passwordText, forKey: "immich.password")
      currentSession = session
      selectedSidebarItem = .library
      libraryItems = []
      selectedItemID = nil
      timelineBuckets = []
      loadedTimelineBucketKeys = []
      totalTimelineItemCount = 0
      timelineErrorMessage = nil
      appPhase = .library
      statusText = "Signed in as \(session.userName) • Loading timeline…"
      immichLog("[Auth] Signed in as \(session.userName), calling loadRemoteTimeline...")
      await loadRemoteTimeline(reset: true)
      immichLog("[Auth] loadRemoteTimeline returned, libraryItems.count = \(libraryItems.count)")
    } catch {
      statusText = "Sign in failed: \(error.localizedDescription)"
    }
  }

  func autoSignInIfNeeded() {
    guard appPhase == .launching else { return }
    
    Task {
      await connect()
      if appPhase == .login {
        await signIn()
      } else {
        appPhase = .serverSetup
      }
    }
  }

  func changeServer() {
    connectedServer = nil
    connectedServerDisplayURL = nil
    connectedServerVersion = nil
    loginPageMessage = nil
    oauthEnabled = false
    oauthButtonText = "OAuth"
    passwordLoginEnabled = true
    emailText = ""
    passwordText = ""
    currentSession = nil
    searchText = ""
    uploadRows = []
    libraryItems = []
    isLoadingTimeline = false
    selectedItemID = nil
    selectedSidebarItem = .library
    timelineBuckets = []
    loadedTimelineBucketKeys = []
    totalTimelineItemCount = 0
    timelineErrorMessage = nil
    appPhase = .serverSetup
    statusText = "Enter your Immich server URL to continue."
  }

  func signOut() {
    currentSession = nil
    passwordText = ""
    searchText = ""
    selectedItemID = nil
    libraryItems = []
    isLoadingTimeline = false
    uploadRows = []
    selectedSidebarItem = .library
    timelineBuckets = []
    loadedTimelineBucketKeys = []
    totalTimelineItemCount = 0
    timelineErrorMessage = nil
    appPhase = .login
    statusText = "Connected • Immich \(connectedServerVersion ?? "")"
  }

  func toggleFavorite(for itemID: String) {
    guard let index = libraryItems.firstIndex(where: { $0.id == itemID }) else { return }
    var updatedItems = libraryItems
    updatedItems[index].isFavorite.toggle()
    libraryItems = updatedItems
  }

  func importFiles(_ urls: [URL]) {
    guard urls.isEmpty == false else { return }

    for url in urls {
      let uploadItem = UploadItem(fileURL: url)
      let importedItem = PhotoItem(
        id: UUID().uuidString,
        source: .localFile(url),
        title: url.deletingPathExtension().lastPathComponent,
        date: .now,
        isFavorite: false,
        isVideo: ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()),
        isImported: true,
        livePhotoVideoID: nil,
        latitude: nil,
        longitude: nil,
        durationText: ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) ? "Ready to upload" : nil,
        city: nil,
        country: nil,
        stackCount: nil,
        timeBucketKey: Self.timelineBucketKey(for: .now)
      )

      var updatedUploadRows = uploadRows
      updatedUploadRows.insert(
        UploadRow(id: uploadItem.id, filename: url.lastPathComponent, progress: 0, state: .queued),
        at: 0
      )
      uploadRows = updatedUploadRows

      var updatedLibraryItems = libraryItems
      updatedLibraryItems.insert(importedItem, at: 0)
      libraryItems = updatedLibraryItems
      selectedItemID = importedItem.id

      Task {
        await uploadQueue.enqueue(uploadItem)
        await markUploading(uploadItem)
      }
    }
  }

  func loadMoreTimelineIfNeeded(after sectionID: String) {
    guard
      appPhase == .library,
      selectedSidebarItem == .library,
      searchText.isEmpty,
      canLoadMoreTimeline,
      isLoadingTimeline == false,
      loadedTimelineBucketKeys.last == sectionID
    else {
      return
    }

    Task {
      await loadNextTimelinePage()
    }
  }

  func loadMoreTimeline() async {
    await loadNextTimelinePage()
  }

  private func markUploading(_ item: UploadItem) async {
    for progressStep in stride(from: 0.1, through: 1.0, by: 0.1) {
      guard Task.isCancelled == false else { return }
      await uploadQueue.markUploading(item, progress: progressStep)
      await MainActor.run {
        updateUploadRow(id: item.id, progress: progressStep, state: .uploading(progress: progressStep))
      }
      do {
        try await Task.sleep(for: .milliseconds(120))
      } catch {
        return
      }
    }

    await uploadQueue.markDone(item)
    await MainActor.run {
      updateUploadRow(id: item.id, progress: 1, state: .done)
    }
  }

  private func updateUploadRow(id: UUID, progress: Double, state: UploadState) {
    guard let index = uploadRows.firstIndex(where: { $0.id == id }) else { return }
    var updatedUploadRows = uploadRows
    updatedUploadRows[index].progress = progress
    updatedUploadRows[index].state = state
    uploadRows = updatedUploadRows
  }

  private func loadRemoteTimeline(reset: Bool) async {
    guard let connectedServer, let currentSession else {
      immichLog("[Timeline] loadRemoteTimeline: no server or session")
      return
    }

    if reset {
      isLoadingTimeline = true
      timelineErrorMessage = nil

      do {
        let buckets = try await apiClient.fetchTimelineBuckets(server: connectedServer, session: currentSession)
        timelineBuckets = buckets.filter { $0.count > 0 }
        loadedTimelineBucketKeys = []
        totalTimelineItemCount = timelineBuckets.reduce(0) { $0 + $1.count }
        immichLog("[Timeline] Fetched \(timelineBuckets.count) buckets, total \(totalTimelineItemCount) items")
        if let first = timelineBuckets.first {
          immichLog("[Timeline] First bucket: \(first.timeBucket) (\(first.count) items)")
        }
      } catch {
        immichLog("[Timeline] Bucket fetch failed: \(error)")
        timelineErrorMessage = "We signed in successfully, but the timeline could not be loaded: \(error.localizedDescription)"
        statusText = "Signed in • Timeline failed to load"
        isLoadingTimeline = false
        return
      }
    }

    await loadNextTimelinePage()
  }

  private func loadNextTimelinePage() async {
    guard let connectedServer, let currentSession else {
      return
    }

    guard isLoadingTimeline == false || loadedTimelineBucketKeys.isEmpty else {
      return
    }

    let nextBuckets = timelineBuckets.dropFirst(loadedTimelineBucketKeys.count).prefix(Self.timelinePageSize)
    guard nextBuckets.isEmpty == false else {
      isLoadingTimeline = false
      updateTimelineStatus()
      return
    }

    isLoadingTimeline = true
    timelineErrorMessage = nil
    defer {
      isLoadingTimeline = false
      updateTimelineStatus()
    }

    do {
      var newItems: [PhotoItem] = []
      var fetchedBucketKeys: [String] = []

      for bucket in nextBuckets {
        immichLog("[Timeline] Fetching bucket \(bucket.timeBucket) (expected \(bucket.count) items)...")
        let assets = try await apiClient.fetchTimelineBucket(
          server: connectedServer,
          session: currentSession,
          timeBucket: bucket.timeBucket
        )
        immichLog("[Timeline] Bucket \(bucket.timeBucket): got \(assets.count) assets, \(assets.filter { !$0.isTrashed }.count) non-trashed")
        
        let livePhotos = assets.filter { $0.livePhotoVideoID != nil }
        immichLog("[Timeline] Found \(livePhotos.count) Live Photos in bucket \(bucket.timeBucket)")

        let timelineItems = assets
          .filter { !$0.isTrashed }
          .map { asset in
            Self.makePhotoItem(from: asset, timeBucket: bucket.timeBucket)
          }

        newItems.append(contentsOf: timelineItems)
        fetchedBucketKeys.append(bucket.timeBucket)
      }

      immichLog("[Timeline] Page loaded: \(newItems.count) new items total")
      let allItems = libraryItems + newItems
      let deduplicatedItems = Dictionary(uniqueKeysWithValues: allItems.map { ($0.id, $0) })
      loadedTimelineBucketKeys.append(contentsOf: fetchedBucketKeys)
      libraryItems = deduplicatedItems.values.sorted { $0.date > $1.date }
      immichLog("[Timeline] Library now has \(libraryItems.count) items")

      if selectedItemID == nil {
        selectedItemID = libraryItems.first?.id
      }
    } catch {
      immichLog("[Timeline] Page fetch FAILED: \(error)")
      timelineErrorMessage = "We couldn't load more photos from the timeline: \(error.localizedDescription)"
    }
  }

  private func updateTimelineStatus() {
    guard let session = currentSession else {
      return
    }

    if let timelineErrorMessage {
      statusText = timelineErrorMessage
      return
    }

    if totalTimelineItemCount == 0 {
      statusText = "Signed in as \(session.userName) • No timeline assets found"
      return
    }

    if canLoadMoreTimeline {
      statusText = "Signed in as \(session.userName) • Loaded \(loadedRemoteTimelineItemCount) of \(totalTimelineItemCount) items"
      return
    }

    statusText = "Signed in as \(session.userName) • Loaded \(loadedRemoteTimelineItemCount) items"
  }

  private static func makePhotoItem(from asset: RemoteTimelineAsset, timeBucket: String) -> PhotoItem {
    let locationText = [asset.city, asset.country]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
      .joined(separator: ", ")

    let title: String
    if locationText.isEmpty == false {
      title = locationText
    } else if asset.isImage {
      title = "Photo"
    } else {
      title = "Video"
    }

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
      timeBucketKey: timeBucket
    )
  }

  private static func timelineBucketKey(for date: Date) -> String {
    let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
    let year = components.year ?? 1970
    let month = components.month ?? 1
    return String(format: "%04d-%02d-01", year, month)
  }

  private static func date(forTimelineBucket value: String) -> Date? {
    timelineBucketFormatter.date(from: value)
  }
}
#endif

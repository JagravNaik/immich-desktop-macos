import Foundation
import ImmichAPI
import ImmichCore
import ImmichSync

#if canImport(SwiftUI)
import SwiftUI

@MainActor
final class ContentViewModel: ObservableObject {
  enum AppPhase {
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
    let id: UUID
    var title: String
    var date: Date
    var isFavorite: Bool
    let isVideo: Bool
    let isImported: Bool

    var timeLabel: String {
      if isVideo { return "0:24" }
      return ""
    }
  }

  struct UploadRow: Identifiable {
    let id: UUID
    let filename: String
    var progress: Double
    var state: UploadState
  }

  @Published var appPhase: AppPhase = .serverSetup
  @Published var serverURLText = "http://localhost:2283"
  @Published var emailText = ""
  @Published var passwordText = ""
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

  @Published var searchText = ""
  @Published var selectedSidebarItem: SidebarItem = .library
  @Published var selectedItemID: UUID?
  @Published var uploadRows: [UploadRow] = []
  @Published var libraryItems: [PhotoItem] = []

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

  var selectedItem: PhotoItem? {
    guard let selectedItemID else { return nil }
    return libraryItems.first(where: { $0.id == selectedItemID })
  }

  var emptyStateTitle: String {
    switch selectedSidebarItem {
    case .library:
      "Connected successfully"
    case .favorites:
      "No favorites yet"
    case .recents:
      "No recent items"
    case .videos:
      "No videos yet"
    case .imports:
      "No imports yet"
    }
  }

  var emptyStateMessage: String {
    switch selectedSidebarItem {
    case .library:
      if let session = currentSession {
        return "Signed in as \(session.userEmail). Remote timeline browsing is not implemented in the macOS scaffold yet."
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
      passwordText = ""
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
      currentSession = session
      selectedSidebarItem = .library
      appPhase = .library
      statusText = "Signed in as \(session.userName) • Immich \(connectedServerVersion ?? "")"
    } catch {
      statusText = "Sign in failed: \(error.localizedDescription)"
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
    selectedItemID = nil
    selectedSidebarItem = .library
    appPhase = .serverSetup
    statusText = "Enter your Immich server URL to continue."
  }

  func signOut() {
    currentSession = nil
    passwordText = ""
    searchText = ""
    selectedItemID = nil
    libraryItems = []
    uploadRows = []
    selectedSidebarItem = .library
    appPhase = .login
    statusText = "Connected • Immich \(connectedServerVersion ?? "")"
  }

  func toggleFavorite(for itemID: UUID) {
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
        id: UUID(),
        title: url.deletingPathExtension().lastPathComponent,
        date: .now,
        isFavorite: false,
        isVideo: ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()),
        isImported: true
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

  private func markUploading(_ item: UploadItem) async {
    for progressStep in stride(from: 0.1, through: 1.0, by: 0.1) {
      await uploadQueue.markUploading(item, progress: progressStep)
      await MainActor.run {
        updateUploadRow(id: item.id, progress: progressStep, state: .uploading(progress: progressStep))
      }
      try? await Task.sleep(for: .milliseconds(120))
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
}
#endif

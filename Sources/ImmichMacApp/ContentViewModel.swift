import Foundation
import ImmichAPI
import ImmichCore
import ImmichSync

#if canImport(SwiftUI)
import SwiftUI

@MainActor
final class ContentViewModel: ObservableObject {
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

  @Published var serverURLText = "http://localhost:2283"
  @Published var apiKey = ""
  @Published var statusText = "Not connected"
  @Published var isConnecting = false

  @Published var searchText = ""
  @Published var selectedSidebarItem: SidebarItem = .library
  @Published var selectedItemID: UUID?
  @Published var uploadRows: [UploadRow] = []

  @Published var libraryItems: [PhotoItem] = [
    .init(id: UUID(), title: "Golden Gate", date: .now.addingTimeInterval(-86400 * 2), isFavorite: true, isVideo: false, isImported: false),
    .init(id: UUID(), title: "Weekend Trip", date: .now.addingTimeInterval(-86400 * 5), isFavorite: false, isVideo: true, isImported: false),
    .init(id: UUID(), title: "Family Dinner", date: .now.addingTimeInterval(-86400 * 8), isFavorite: true, isVideo: false, isImported: false),
    .init(id: UUID(), title: "Hiking", date: .now.addingTimeInterval(-86400 * 12), isFavorite: false, isVideo: false, isImported: false),
    .init(id: UUID(), title: "Beach", date: .now.addingTimeInterval(-86400 * 14), isFavorite: false, isVideo: true, isImported: false),
    .init(id: UUID(), title: "Portrait", date: .now.addingTimeInterval(-86400 * 20), isFavorite: false, isVideo: false, isImported: false),
    .init(id: UUID(), title: "City Lights", date: .now.addingTimeInterval(-86400 * 25), isFavorite: true, isVideo: false, isImported: false),
    .init(id: UUID(), title: "Road Trip", date: .now.addingTimeInterval(-86400 * 30), isFavorite: false, isVideo: true, isImported: false),
  ]

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

  private let apiClient: any ImmichAPIClient
  private let uploadQueue = UploadQueue()

  init(apiClient: any ImmichAPIClient = URLSessionImmichAPIClient()) {
    self.apiClient = apiClient
    self.selectedItemID = libraryItems.first?.id
  }

  func connect() async {
    guard let url = URL(string: serverURLText) else {
      statusText = "Invalid server URL"
      return
    }

    isConnecting = true
    defer { isConnecting = false }

    do {
      let info = try await apiClient.fetchServerInfo(
        server: ImmichServer(baseURL: url.appending(path: "api")),
        apiKey: apiKey.isEmpty ? nil : apiKey
      )
      statusText = "Connected • Immich \(info.version)"
    } catch {
      statusText = "Connection failed: \(error.localizedDescription)"
    }
  }

  func toggleFavorite(for itemID: UUID) {
    guard let index = libraryItems.firstIndex(where: { $0.id == itemID }) else { return }
    libraryItems[index].isFavorite.toggle()
  }

  func importFiles(_ urls: [URL]) {
    guard urls.isEmpty == false else { return }

    for url in urls {
      let uploadItem = UploadItem(fileURL: url)
      uploadRows.insert(
        UploadRow(id: uploadItem.id, filename: url.lastPathComponent, progress: 0, state: .queued),
        at: 0
      )

      libraryItems.insert(
        PhotoItem(
          id: UUID(),
          title: url.deletingPathExtension().lastPathComponent,
          date: .now,
          isFavorite: false,
          isVideo: ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()),
          isImported: true
        ),
        at: 0
      )

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
    uploadRows[index].progress = progress
    uploadRows[index].state = state
  }
}
#endif

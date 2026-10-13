#if canImport(SwiftUI) && canImport(AppKit)
import Foundation
import ImmichAPI
import ImmichCore

/// Photos' Image-menu organization commands backed by Immich v3 bulk updates:
/// Set Star Rating (⌥0–⌥5, ⌥] / ⌥[), Show/Hide Photo (⌘L), Adjust Date and Time…, and
/// Utilities ▸ Hidden / Duplicates with Merge Duplicates.
@MainActor
extension AppState {
  private func requireConnection() throws -> (ImmichServer, UserSession) {
    guard let connectedServer, let currentSession else {
      throw ImmichAPIError.requestFailed(statusCode: 0, message: "Not connected to server.")
    }
    return (connectedServer, currentSession)
  }

  // MARK: - Star Rating

  /// `stars` in 1...5 sets a rating; nil removes it (Photos' Remove Rating ⌥0).
  func setRating(_ stars: Int?, for itemIDs: [String]) async throws {
    guard !itemIDs.isEmpty else { return }
    let (server, session) = try requireConnection()
    let clamped = stars.map { min(max($0, 1), 5) }
    try await apiClient.updateAssets(
      server: server,
      session: session,
      assetIds: itemIDs,
      update: AssetBulkUpdate(rating: clamped.map(AssetBulkUpdate.Rating.stars) ?? AssetBulkUpdate.Rating.none)
    )
    for id in itemIDs {
      updatePhotoItemCopies(withID: id) { $0.rating = clamped }
    }
  }

  /// Photos' Increment/Decrement Star Rating (⌥] / ⌥[). Applied per item, as ratings can differ.
  func adjustRating(by delta: Int, for itemIDs: [String]) async throws {
    let grouped = Dictionary(grouping: itemIDs) { id -> Int in
      let current = photoItem(withID: id)?.rating ?? 0
      return min(max(current + delta, 0), 5)
    }
    for (target, ids) in grouped.sorted(by: { $0.key < $1.key }) {
      try await setRating(target == 0 ? nil : target, for: ids)
    }
  }

  // MARK: - Hide / Show

  /// Photos' Show/Hide Photo (⌘L). Hidden items leave every other view and live in Utilities ▸ Hidden.
  func setHidden(_ isHidden: Bool, for itemIDs: [String]) async throws {
    guard !itemIDs.isEmpty else { return }
    let (server, session) = try requireConnection()
    try await apiClient.updateAssets(
      server: server,
      session: session,
      assetIds: itemIDs,
      update: AssetBulkUpdate(visibility: isHidden ? "hidden" : "timeline")
    )

    let ids = Set(itemIDs)
    if isHidden {
      let moved = itemIDs.compactMap(photoItem(withID:))
      removePhotoItemCopies { ids.contains($0.id) }
      let existing = Set(hiddenItems.map(\.id))
      hiddenItems.append(contentsOf: moved.filter { !existing.contains($0.id) })
      hiddenItems.sort { $0.date > $1.date }
    } else {
      let restored = hiddenItems.filter { ids.contains($0.id) }
      hiddenItems.removeAll { ids.contains($0.id) }
      let libraryIDs = Set(libraryItems.map(\.id))
      libraryItems.append(contentsOf: restored.filter { !libraryIDs.contains($0.id) })
      libraryItems.sort { $0.date > $1.date }
    }
    selectedItemIDs.subtract(ids)
    reconcileSelectionWithVisibleItems()
  }

  /// Whether ⌘L should hide (true) or show (false) the targets, matching Photos' toggle title.
  func hideCommandHides(_ itemIDs: [String]) -> Bool {
    let hiddenIDs = Set(hiddenItems.map(\.id))
    return !itemIDs.allSatisfy(hiddenIDs.contains)
  }

  func loadHiddenItems() async {
    guard let connectedServer, let currentSession, !isLoadingHidden else { return }
    isLoadingHidden = true
    defer { isLoadingHidden = false }
    do {
      let assets = try await apiClient.fetchHiddenAssets(server: connectedServer, session: currentSession)
      hiddenItems = assets.filter { !$0.isTrashed }.map {
        Self.makePhotoItem(from: $0, timeBucket: Self.timelineBucketKey(for: $0.createdAt))
      }
      .sorted { $0.date > $1.date }
    } catch {
      immichLog("[Hidden] Failed to load hidden items: \(error)")
    }
  }

  // MARK: - Adjust Date and Time

  func presentAdjustDateTime(for itemIDs: [String]) {
    guard !itemIDs.isEmpty else { return }
    adjustDateTimeItemIDs = itemIDs
    showAdjustDateTimeSheet = true
  }

  /// Photos' Adjust Date and Time: shifts every target by the same offset, optionally setting a time zone.
  func adjustDateTime(for itemIDs: [String], offsetMinutes: Int, timeZone: TimeZone?) async throws {
    guard !itemIDs.isEmpty, offsetMinutes != 0 || timeZone != nil else { return }
    let (server, session) = try requireConnection()
    try await apiClient.updateAssets(
      server: server,
      session: session,
      assetIds: itemIDs,
      update: AssetBulkUpdate(
        dateTimeRelativeMinutes: offsetMinutes == 0 ? nil : offsetMinutes,
        timeZone: timeZone?.identifier
      )
    )
    guard offsetMinutes != 0 else { return }
    let interval = TimeInterval(offsetMinutes * 60)
    for id in itemIDs {
      updatePhotoItemCopies(withID: id) {
        $0.date = $0.date.addingTimeInterval(interval)
        $0.timeBucketKey = Self.timelineBucketKey(for: $0.date)
      }
    }
    libraryItems.sort { $0.date > $1.date }
  }

  // MARK: - Duplicates

  func loadDuplicates() async {
    guard let connectedServer, let currentSession, !isLoadingDuplicates else { return }
    isLoadingDuplicates = true
    defer { isLoadingDuplicates = false }
    do {
      duplicateGroups = try await apiClient.fetchDuplicates(server: connectedServer, session: currentSession)
        .filter { $0.assets.count > 1 }
    } catch {
      immichLog("[Duplicates] Failed to load duplicates: \(error)")
    }
  }

  /// Photos' Merge Duplicates: keeps the suggested best copy and trashes the rest of each group.
  func mergeDuplicates(_ groups: [DuplicateGroup]) async throws {
    guard !groups.isEmpty else { return }
    let (server, session) = try requireConnection()
    try await apiClient.resolveDuplicates(server: server, session: session, groups: groups)
    let mergedGroupIDs = Set(groups.map(\.id))
    let trashedIDs = Set(groups.flatMap(\.suggestedTrashAssetIDs))
    duplicateGroups.removeAll { mergedGroupIDs.contains($0.id) }
    removePhotoItemCopies { trashedIDs.contains($0.id) }
  }
}
#endif

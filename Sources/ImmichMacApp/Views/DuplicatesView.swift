#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import ImmichCore

/// Photos' Utilities ▸ Duplicates: one row per duplicate set with a per-row "Merge N Items"
/// button and a "Merge All" action. Merging keeps Immich's suggested copy and trashes the rest.
struct DuplicatesView: View {
  @ObservedObject var appState: AppState
  let thumbnailStore: ThumbnailStore

  @State private var mergingGroupIDs: Set<String> = []
  @State private var errorMessage: String?
  @State private var isConfirmingMergeAll = false

  var body: some View {
    Group {
      if appState.duplicateGroups.isEmpty {
        ContentUnavailableView(
          appState.isLoadingDuplicates ? "Looking for Duplicates…" : "No Duplicates",
          systemImage: "square.on.square",
          description: Text("Duplicate photos and videos found by Immich appear here.")
        )
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 18) {
            header
            ForEach(appState.duplicateGroups) { group in
              row(for: group)
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
          }
          .padding(20)
          .animation(ImmichMotion.Curves.structuralShort, value: appState.duplicateGroups.map(\.id))
        }
      }
    }
    .alert("Couldn’t Merge Duplicates", isPresented: .constant(errorMessage != nil)) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
    .confirmationDialog(
      "Merge \(appState.duplicateGroups.count) duplicate sets?",
      isPresented: $isConfirmingMergeAll
    ) {
      Button("Merge All") { merge(appState.duplicateGroups) }
    } message: {
      Text("The best copy in each set is kept. The other copies are moved to Recently Deleted.")
    }
  }

  private var header: some View {
    HStack {
      Text(setCountText)
        .font(.headline)
        .foregroundStyle(.secondary)
      Spacer()
      Button("Merge All") { isConfirmingMergeAll = true }
        .disabled(!mergingGroupIDs.isEmpty)
    }
  }

  private var setCountText: String {
    let sets = appState.duplicateGroups.count
    let items = appState.duplicateGroups.reduce(0) { $0 + $1.assets.count }
    return "\(sets) \(sets == 1 ? "set" : "sets") · \(items) items"
  }

  private func row(for group: DuplicateGroup) -> some View {
    let keep = Set(group.keepAssetIDs)
    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(group.assets.first.map { $0.createdAt.formatted(date: .abbreviated, time: .shortened) } ?? "")
          .font(.subheadline)
        Spacer()
        Button(mergingGroupIDs.contains(group.id) ? "Merging…" : "Merge \(group.assets.count) Items") {
          merge([group])
        }
        .disabled(mergingGroupIDs.contains(group.id))
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(group.assets) { asset in
            let item = AppState.makePhotoItem(from: asset, timeBucket: AppState.timelineBucketKey(for: asset.createdAt))
            AssetThumbnailView(item: item, context: appState.thumbnailContext, store: thumbnailStore)
              .frame(width: 140, height: 140)
              .clipShape(RoundedRectangle(cornerRadius: 6))
              .overlay(alignment: .bottomLeading) {
                if keep.contains(asset.id) {
                  Text("Keep")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.thinMaterial, in: Capsule())
                    .padding(6)
                }
              }
              .accessibilityLabel(keep.contains(asset.id) ? "Kept copy" : "Duplicate copy")
          }
        }
      }
    }
    .padding(12)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
  }

  private func merge(_ groups: [DuplicateGroup]) {
    let ids = Set(groups.map(\.id))
    mergingGroupIDs.formUnion(ids)
    Task {
      defer { mergingGroupIDs.subtract(ids) }
      do {
        try await appState.mergeDuplicates(groups)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}
#endif

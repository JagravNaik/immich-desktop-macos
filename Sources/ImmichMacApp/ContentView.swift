#if canImport(SwiftUI)
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct ContentView: View {
  @StateObject var viewModel: ContentViewModel

  private let gridColumns = [
    GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 12),
  ]

  var body: some View {
    NavigationSplitView {
      List(selection: $viewModel.selectedSidebarItem) {
        Section("Library") {
          ForEach(ContentViewModel.SidebarItem.allCases) { item in
            Label(item.rawValue, systemImage: item.iconName)
              .tag(item)
          }
        }

        Section("Connection") {
          TextField("Server URL", text: $viewModel.serverURLText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

          SecureField("API Key", text: $viewModel.apiKey)

          Button {
            Task {
              await viewModel.connect()
            }
          } label: {
            if viewModel.isConnecting {
              ProgressView()
            } else {
              Text("Connect to Immich")
            }
          }
          .disabled(viewModel.isConnecting)
        }

        if viewModel.uploadRows.isEmpty == false {
          Section("Uploads") {
            ForEach(viewModel.uploadRows.prefix(5)) { row in
              VStack(alignment: .leading, spacing: 4) {
                Text(row.filename)
                  .lineLimit(1)
                  .font(.caption)
                ProgressView(value: row.progress)
                  .controlSize(.small)
              }
            }
          }
        }
      }
      .navigationTitle("Photos")
      .listStyle(.sidebar)
    } detail: {
      VStack(spacing: 0) {
        header

        ScrollView {
          LazyVGrid(columns: gridColumns, spacing: 12) {
            ForEach(viewModel.filteredItems) { item in
              PhotoCard(
                item: item,
                isSelected: item.id == viewModel.selectedItemID,
                onSelect: { viewModel.selectedItemID = item.id },
                onFavoriteToggle: { viewModel.toggleFavorite(for: item.id) }
              )
            }
          }
          .padding(16)
        }
        .dropDestination(for: URL.self) { items, _ in
          viewModel.importFiles(items)
          return true
        }

        if let selectedItem = viewModel.selectedItem {
          Divider()
          metadataPanel(for: selectedItem)
        }
      }
      .background(.background)
      .searchable(text: $viewModel.searchText, placement: .toolbar, prompt: "Search")
      .toolbar {
        ToolbarItemGroup(placement: .primaryAction) {
          Button {
            importFromFinder()
          } label: {
            Image(systemName: "plus")
          }

          Button {
          } label: {
            Image(systemName: "square.and.arrow.up")
          }

          Menu {
            Button("Date Captured") {}
            Button("Date Added") {}
          } label: {
            Image(systemName: "arrow.up.arrow.down")
          }
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(viewModel.selectedSidebarItem.rawValue)
        .font(.largeTitle)
        .fontWeight(.semibold)

      HStack {
        Text("\(viewModel.filteredItems.count) items")
          .foregroundStyle(.secondary)

        Spacer()

        Text(viewModel.statusText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(.bar)
  }

  @ViewBuilder
  private func metadataPanel(for item: ContentViewModel.PhotoItem) -> some View {
    HStack(spacing: 24) {
      Label(item.title, systemImage: item.isVideo ? "video" : "photo")
      Label(item.date.formatted(date: .long, time: .shortened), systemImage: "calendar")
      if item.isFavorite {
        Label("Favorite", systemImage: "heart.fill")
      }
      if item.isImported {
        Label("Imported", systemImage: "square.and.arrow.down")
      }
      Spacer()
    }
    .font(.caption)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.regularMaterial)
  }

  private func importFromFinder() {
    #if canImport(AppKit)
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.begin { response in
      guard response == .OK else { return }
      viewModel.importFiles(panel.urls)
    }
    #endif
  }
}

private struct PhotoCard: View {
  let item: ContentViewModel.PhotoItem
  let isSelected: Bool
  let onSelect: () -> Void
  let onFavoriteToggle: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ZStack(alignment: .bottomLeading) {
        RoundedRectangle(cornerRadius: 10)
          .fill(.quaternary)
          .aspectRatio(1, contentMode: .fit)
          .overlay {
            Image(systemName: item.isVideo ? "video" : "photo")
              .font(.system(size: 22, weight: .medium))
              .foregroundStyle(.secondary)
          }

        HStack(spacing: 6) {
          if item.isFavorite {
            Image(systemName: "heart.fill")
          }

          if item.isVideo {
            Image(systemName: "video.fill")
            Text(item.timeLabel)
              .font(.caption2)
          }
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(8)
        .shadow(radius: 3)
      }

      HStack(spacing: 8) {
        Text(item.title)
          .lineLimit(1)

        Spacer()

        Button {
          onFavoriteToggle()
        } label: {
          Image(systemName: item.isFavorite ? "heart.fill" : "heart")
            .foregroundStyle(item.isFavorite ? .red : .secondary)
        }
        .buttonStyle(.plain)
      }

      Text(item.date.formatted(date: .abbreviated, time: .omitted))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(8)
    .background {
      RoundedRectangle(cornerRadius: 12)
        .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }
    .onTapGesture(perform: onSelect)
  }
}
#endif

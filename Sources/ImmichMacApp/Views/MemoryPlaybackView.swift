#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit
import ImmichCore

struct MemoryPlaybackSequence: Equatable {
  private(set) var index = 0

  mutating func advance(by offset: Int, itemCount: Int) {
    guard itemCount > 0 else {
      index = 0
      return
    }

    let normalizedOffset = ((offset % itemCount) + itemCount) % itemCount
    index = ((index % itemCount) + normalizedOffset) % itemCount
  }

  mutating func reset() {
    index = 0
  }
}

struct MemoryPlaybackView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var appState: AppState
  @ObservedObject var thumbnailStore: ThumbnailStore
  let memory: Memory

  @State private var sequence = MemoryPlaybackSequence()
  @State private var isPlaying = true
  @State private var image: NSImage?

  private var items: [AppState.PhotoItem] {
    appState.activeMemoryID == memory.id ? appState.activeMemoryItems : []
  }

  private var currentItem: AppState.PhotoItem? {
    guard items.indices.contains(sequence.index) else { return nil }
    return items[sequence.index]
  }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if let currentItem, let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(24)
          .id(currentItem.id)
          .transition(.opacity)
      } else {
        VStack(spacing: 12) {
          ProgressView()
            .controlSize(.large)
          Text(items.isEmpty ? "Preparing Memory…" : "Loading photo…")
            .foregroundStyle(.white.opacity(0.75))
        }
      }

      VStack(spacing: 0) {
        HStack {
          Button {
            dismiss()
          } label: {
            Label("Close", systemImage: "xmark")
          }
          .accessibilityLabel("Close Memory playback")

          Text(memory.title)
            .font(.headline)
            .lineLimit(1)
            .padding(.leading, 8)

          Spacer()

          Text(items.isEmpty ? "0 of 0" : "\(sequence.index + 1) of \(items.count)")
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)

        Spacer()

        VStack(spacing: 12) {
          if !items.isEmpty {
            ProgressView(value: Double(sequence.index + 1), total: Double(items.count))
              .tint(.white)
              .accessibilityLabel("Memory playback progress")
          }

          HStack(spacing: 28) {
            Button {
              advance(by: -1)
            } label: {
              Image(systemName: "backward.end.fill")
                .font(.title2)
            }
            .help("Previous photo")
            .accessibilityLabel("Previous photo")

            Button {
              isPlaying.toggle()
            } label: {
              Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.title)
                .frame(width: 48, height: 48)
            }
            .help(isPlaying ? "Pause Memory" : "Play Memory")
            .accessibilityLabel(isPlaying ? "Pause Memory" : "Play Memory")

            Button {
              advance(by: 1)
            } label: {
              Image(systemName: "forward.end.fill")
                .font(.title2)
            }
            .help("Next photo")
            .accessibilityLabel("Next photo")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.white)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
      }
      .foregroundStyle(.white)
    }
    .frame(minWidth: 760, minHeight: 520)
    .task {
      appState.loadMemory(memory.id)
    }
    .task(id: currentItem?.id) {
      image = nil
      guard let currentItem else { return }
      let loaded = await thumbnailStore.loadImage(
        for: currentItem,
        context: appState.thumbnailContext,
        size: .preview,
        loadClass: .interactive
      )
      guard !Task.isCancelled else { return }
      withAnimation(ImmichMotion.Curves.structuralShort) {
        image = loaded
      }
    }
    .task(id: isPlaying) {
      guard isPlaying else { return }
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(5))
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        advance(by: 1)
      }
    }
    .onChange(of: items.map(\.id)) { _, _ in
      sequence.reset()
    }
  }

  private func advance(by offset: Int) {
    guard !items.isEmpty else { return }
    withAnimation(ImmichMotion.Curves.structuralMedium) {
      sequence.advance(by: offset, itemCount: items.count)
    }
  }
}
#endif

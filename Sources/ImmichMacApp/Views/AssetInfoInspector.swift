#if canImport(SwiftUI)
import SwiftUI
import MapKit
import ImmichCore
import ImmichAPI

// MARK: - Asset Info Inspector (Photos-style detail panel)

struct AssetInfoInspector: View {
  @ObservedObject var appState: AppState
  let item: AppState.PhotoItem
  @State private var detail: AssetDetail?
  @State private var isLoading = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        headerSection
          .padding(16)

        Divider()

        cameraSection
          .padding(16)

        Divider()

        tagsSection
          .padding(16)

        if let lat = item.latitude, let lon = item.longitude {
          Divider()
          mapSection(lat: lat, lon: lon)
        }
      }
    }
    .frame(width: 300)
    .background(.ultraThinMaterial)
    .task(id: item.id) {
      await loadDetail()
    }
    .onChange(of: appState.showTagEditorSheet) { _, isPresented in
      guard !isPresented else { return }
      Task { await loadDetail() }
    }
  }

  // MARK: - Header

  private var headerSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(detail?.originalFileName ?? item.title)
        .font(.headline)

      HStack(spacing: 4) {
        Text(item.date, style: .date)
        Text("at")
          .foregroundStyle(.tertiary)
        Text(item.date, style: .time)
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)

      if let detail {
        HStack(spacing: 12) {
          if let w = detail.width, let h = detail.height {
            Label("\(w)×\(h)", systemImage: "aspectratio")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if let size = detail.fileSizeInByte {
            Label(formatFileSize(size), systemImage: "doc")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.top, 4)
      }
    }
  }

  // MARK: - Camera / EXIF

  private var cameraSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let exif = detail?.exif {
        // Camera heading
        HStack(spacing: 10) {
          Image(systemName: "camera")
            .font(.title3)
            .foregroundStyle(.secondary)

          VStack(alignment: .leading, spacing: 1) {
            Text([exif.make, exif.model].compactMap { $0 }.joined(separator: " "))
              .font(.subheadline.weight(.medium))
            if let lens = exif.lensModel {
              Text(lens)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }

        // EXIF grid
        HStack(spacing: 0) {
          exifItem(label: "ISO", value: exif.iso.map(String.init) ?? "—")
          Spacer()
          exifItem(label: "FOCAL", value: exif.focalLength.map { "\(Int($0))mm" } ?? "—")
          Spacer()
          exifItem(label: "f/", value: exif.fNumber.map { String(format: "%.1f", $0) } ?? "—")
          Spacer()
          exifItem(label: "SHUTTER", value: exif.exposureTime ?? "—")
        }
      } else if isLoading {
        HStack {
          ProgressView().controlSize(.small)
          Text("Loading metadata…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        HStack(spacing: 10) {
          Image(systemName: "camera")
            .font(.title3)
            .foregroundStyle(.secondary)
          Text("No camera metadata")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func exifItem(label: String, value: String) -> some View {
    VStack(spacing: 2) {
      Text(label)
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.tertiary)
      Text(value)
        .font(.system(size: 12, design: .monospaced))
    }
  }

  // MARK: - Tags

  private var tagsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Tags", systemImage: "tag")
          .font(.headline)
        Spacer()
        Button("Edit Tags…") {
          appState.presentTagEditor(for: [item.id], currentTags: detail?.tags ?? [], title: "Edit Tags")
        }
        .buttonStyle(.plain)
      }

      if let tags = detail?.tags, !tags.isEmpty {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 8)], alignment: .leading, spacing: 8) {
          ForEach(tags) { tag in
            TagPill(title: tag.value, colorHex: tag.color)
          }
        }
      } else if isLoading {
        HStack {
          ProgressView().controlSize(.small)
          Text("Loading tags…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        Text("No tags on this item.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Map

  private func mapSection(lat: Double, lon: Double) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      let location = [item.city, item.country].compactMap { $0 }.joined(separator: ", ")
      if !location.isEmpty {
        Text(location)
          .font(.caption.weight(.medium))
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.black.opacity(0.05))
      }

      Map(initialPosition: .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
      ))) {
        Marker("", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
      }
      .frame(height: 160)
    }
  }

  // MARK: - Helpers

  private func loadDetail() async {
    guard case .remoteAsset(let id) = item.source,
          appState.thumbnailContext != nil,
          appState.currentSession != nil else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      detail = try await appState.fetchAssetDetail(id)
    } catch {
      // Silently fail — just show what we have
    }
  }

  private func formatFileSize(_ bytes: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(bytes))
  }
}
#endif

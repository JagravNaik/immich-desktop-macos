#if canImport(SwiftUI)
import SwiftUI
import MapKit
import ImmichCore

// MARK: - Asset Info Inspector (Photos-style detail panel)

struct AssetInfoInspector: View {
  @ObservedObject var appState: AppState
  let item: AppState.PhotoItem
  var onClose: (() -> Void)? = nil
  @State private var detail: AssetDetail?
  @State private var isLoading = false
  @State private var showsTags = false
  @State private var showsLocationEditor = false
  @State private var captionText = ""
  @State private var savedCaptionText = ""
  @State private var captionError: String?
  @State private var isSavingCaption = false
  @State private var captureDate = Date()
  @State private var savedCaptureDate = Date()
  @State private var captureDateError: String?
  @State private var isSavingCaptureDate = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        headerSection
          .padding(18)

        Divider()
        if case .remoteAsset = item.source {
          captionSection
            .padding(18)
          Divider()
          captureDateSection
            .padding(18)
          Divider()
        }

        cameraSection
          .padding(18)

        Divider()

        tagsSection
          .padding(18)

        Divider()
        mapSection(lat: currentLatitude, lon: currentLongitude)
          .padding(18)
      }
    }
    .frame(width: 420)
    .background(.ultraThinMaterial)
    .task(id: item.id) {
      captionText = ""
      savedCaptionText = ""
      captureDate = item.date
      savedCaptureDate = item.date
      captionError = nil
      captureDateError = nil
      await loadDetail()
    }
    .onChange(of: appState.showTagEditorSheet) { _, isPresented in
      guard !isPresented else { return }
      Task { await loadDetail() }
    }
    .onChange(of: captionText) { _, _ in
      captionError = nil
    }
    .onChange(of: captureDate) { _, _ in
      captureDateError = nil
    }
    .sheet(isPresented: $showsLocationEditor) {
      AssetLocationEditor(initialCoordinate: currentCoordinate) { latitude, longitude in
        try await appState.updateAssetLocation(itemID: item.id, latitude: latitude, longitude: longitude)
        await loadDetail()
      }
    }
  }

  // MARK: - Header

  private var headerSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Info")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

          Text(detail?.originalFileName ?? item.title)
            .font(.headline)
            .lineLimit(2)
        }

        Spacer()

        if let onClose {
          Button {
            onClose()
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.title3)
              .foregroundStyle(.tertiary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Close Info")
        }
      }

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

  // MARK: - Caption

  private var captionSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Caption", systemImage: "text.alignleft")
        .font(.headline)

      ZStack(alignment: .topLeading) {
        TextEditor(text: $captionText)
          .font(.body)
          .frame(minHeight: 84, maxHeight: 120)
          .scrollContentBackground(.hidden)
          .accessibilityLabel("Caption")
          .accessibilityHint("Edit the description for this photo.")

        if captionText.isEmpty {
          Text("Add a caption…")
            .foregroundStyle(.tertiary)
            .padding(.leading, 8)
            .padding(.top, 8)
            .allowsHitTesting(false)
        }
      }
      .padding(4)
      .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(.quaternary, lineWidth: 1)
      }
      .disabled(isSavingCaption)

      HStack(alignment: .firstTextBaseline) {
        if let captionError {
          Text(captionError)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        Button(isSavingCaption ? "Saving…" : "Save Caption") {
          Task { await saveCaption() }
        }
        .disabled(!isCaptionDirty || isSavingCaption)
        .keyboardShortcut(.defaultAction)
      }
    }
  }

  // MARK: - Date & Time

  private var captureDateSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Date & Time", systemImage: "calendar")
        .font(.headline)

      DatePicker(
        "Captured",
        selection: $captureDate,
        displayedComponents: [.date, .hourAndMinute]
      )
      .datePickerStyle(.field)
      .disabled(isSavingCaptureDate)

      HStack(alignment: .firstTextBaseline) {
        if let captureDateError {
          Text(captureDateError)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        Button(isSavingCaptureDate ? "Saving…" : "Save Date & Time") {
          Task { await saveCaptureDate() }
        }
        .disabled(!isCaptureDateDirty || isSavingCaptureDate)
      }
    }
  }

  // MARK: - Camera / EXIF

  private var cameraSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let exif = detail?.exif {
        HStack(spacing: 10) {
          Image(systemName: "camera")
            .font(.title3)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

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

        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
          ForEach(metadataRows(for: exif)) { row in
            GridRow(alignment: .firstTextBaseline) {
              Text(row.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)

              Text(row.value)
                .font(row.usesMonospacedValue ? .system(.subheadline, design: .monospaced) : .subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            }
          }
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
            .accessibilityHidden(true)
          Text("No camera metadata")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
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

        Button(showsTags ? "Hide" : "Show") {
          withAnimation(ImmichMotion.Curves.structuralQuick) {
            showsTags.toggle()
          }
        }
        .buttonStyle(.plain)
      }

      if showsTags {
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
      } else {
        Text(tagSummaryText)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Map

  private func mapSection(lat: Double?, lon: Double?) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Location", systemImage: "map")
          .font(.headline)

        Spacer()

        if case .remoteAsset = item.source {
          Button(lat == nil || lon == nil ? "Add Location" : "Edit Location") {
            showsLocationEditor = true
          }
          .buttonStyle(.borderless)
        }
      }

      let location = [detail?.exif?.city ?? item.city, detail?.exif?.state, detail?.exif?.country ?? item.country]
        .compactMap { value in
          guard let value, !value.isEmpty else { return nil }
          return value
        }
        .joined(separator: ", ")

      if !location.isEmpty {
        Text(location)
          .font(.caption.weight(.medium))
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      }

      if let lat, let lon {
        Map(initialPosition: .region(MKCoordinateRegion(
          center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
          span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        ))) {
          Marker("", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      } else {
        Text("No location information")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Helpers
  private var currentLatitude: Double? { item.latitude ?? detail?.exif?.latitude }

  private var currentLongitude: Double? { item.longitude ?? detail?.exif?.longitude }

  private var currentCoordinate: CLLocationCoordinate2D? {
    guard let latitude = currentLatitude, let longitude = currentLongitude else { return nil }
    return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }

  private var isCaptionDirty: Bool { captionText != savedCaptionText }
  private var isCaptureDateDirty: Bool { captureDate != savedCaptureDate }

  @MainActor
  private func saveCaption() async {
    guard isCaptionDirty, case .remoteAsset = item.source else { return }
    isSavingCaption = true
    defer { isSavingCaption = false }

    do {
      try await appState.updateAssetDescription(itemID: item.id, description: captionText)
      savedCaptionText = captionText
      await loadDetail()
    } catch {
      captionError = error.localizedDescription
    }
  }

  @MainActor
  private func saveCaptureDate() async {
    guard isCaptureDateDirty, case .remoteAsset = item.source else { return }
    isSavingCaptureDate = true
    defer { isSavingCaptureDate = false }

    do {
      try await appState.updateAssetDateTime(itemID: item.id, date: captureDate)
      savedCaptureDate = captureDate
    } catch {
      captureDateError = error.localizedDescription
    }
  }

  private func loadDetail() async {
    detail = nil
    isLoading = false

    guard case .remoteAsset(let id) = item.source,
          appState.thumbnailContext != nil,
          appState.currentSession != nil else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let fetchedDetail = try await appState.fetchAssetDetail(id)
      detail = fetchedDetail
      if !isCaptionDirty {
        captionText = fetchedDetail.exif?.description ?? ""
        savedCaptionText = captionText
      }
      if !isCaptureDateDirty {
        captureDate = fetchedDetail.exif?.dateTimeOriginal ?? fetchedDetail.localDateTime ?? item.date
        savedCaptureDate = captureDate
      }
    } catch {
      detail = nil
    }
  }

  private func formatFileSize(_ bytes: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(bytes))
  }

  private var tagSummaryText: String {
    if isLoading {
      return "Loading tags…"
    }
    guard let tags = detail?.tags else {
      return "No tags on this item."
    }
    if tags.isEmpty {
      return "No tags on this item."
    }
    if tags.count == 1 {
      return "1 tag"
    }
    return "\(tags.count) tags"
  }

  private func metadataRows(for exif: ExifInfo) -> [MetadataRow] {
    var rows: [MetadataRow] = [
      MetadataRow(label: "ISO", value: exif.iso.map(String.init) ?? "—", usesMonospacedValue: true),
      MetadataRow(label: "Focal Length", value: exif.focalLength.map { "\(Int($0)) mm" } ?? "—", usesMonospacedValue: true),
      MetadataRow(label: "Aperture", value: exif.fNumber.map { "f/\(String(format: "%.1f", $0))" } ?? "—", usesMonospacedValue: true),
      MetadataRow(label: "Shutter", value: exif.exposureTime ?? "—", usesMonospacedValue: true),
    ]

    if let dateTimeOriginal = exif.dateTimeOriginal {
      rows.append(MetadataRow(label: "Captured", value: dateTimeOriginal.formatted(date: .abbreviated, time: .shortened)))
    }

    let location = [exif.city, exif.state, exif.country]
      .compactMap { value in
        guard let value, !value.isEmpty else { return nil }
        return value
      }
      .joined(separator: ", ")
    if !location.isEmpty {
      rows.append(MetadataRow(label: "Location", value: location))
    }

    if let rating = exif.rating {
      rows.append(MetadataRow(label: "Rating", value: String(repeating: "★", count: rating)))
    }

    if let description = exif.description, !description.isEmpty {
      rows.append(MetadataRow(label: "Description", value: description))
    }

    return rows
  }
}

private struct MetadataRow: Identifiable {
  let label: String
  let value: String
  var usesMonospacedValue = false

  var id: String { label }
}
#endif

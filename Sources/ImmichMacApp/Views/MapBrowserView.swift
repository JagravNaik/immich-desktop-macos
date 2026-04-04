#if canImport(SwiftUI) && canImport(MapKit) && canImport(AppKit)
import SwiftUI
import MapKit
import AppKit
import ImmichCore

typealias AssetMapMarker = ImmichCore.MapMarker

private struct PlaceGroup: Identifiable {
  let id: String
  let title: String
  let subtitle: String?
  let count: Int
  let marker: AssetMapMarker
  let markers: [AssetMapMarker]
}

private struct MapViewportRequest {
  let id = UUID()
  let region: MKCoordinateRegion
}

// MapKit is surprisingly strict here: invalid spans or center coordinates can throw inside
// `setRegion`, and libraries that straddle the antimeridian need a wrapped longitude arc
// instead of a naive min/max box. This builder keeps every viewport request normalized
// before it ever reaches the embedded MKMapView.
enum MapViewportBuilder {
  private static let minimumLatitudeDelta = 0.08
  private static let minimumLongitudeDelta = 0.08
  private static let maximumLatitudeDelta = 179.9
  private static let maximumLongitudeDelta = 359.9

  static func isValid(marker: AssetMapMarker) -> Bool {
    marker.latitude.isFinite &&
    marker.longitude.isFinite &&
    (-90.0 ... 90.0).contains(marker.latitude) &&
    (-180.0 ... 180.0).contains(marker.longitude)
  }

  static func singleMarkerRegion(for marker: AssetMapMarker) -> MKCoordinateRegion? {
    guard isValid(marker: marker) else { return nil }
    return sanitize(
      MKCoordinateRegion(
        center: marker.coordinate,
        span: MKCoordinateSpan(latitudeDelta: minimumLatitudeDelta, longitudeDelta: minimumLongitudeDelta)
      )
    )
  }

  static func region(containing markers: [AssetMapMarker]) -> MKCoordinateRegion? {
    let validMarkers = markers.filter(isValid(marker:))
    guard let first = validMarkers.first else { return nil }

    var minLatitude = first.latitude
    var maxLatitude = first.latitude

    for marker in validMarkers.dropFirst() {
      minLatitude = min(minLatitude, marker.latitude)
      maxLatitude = max(maxLatitude, marker.latitude)
    }

    let latitudeCenter = clamp((minLatitude + maxLatitude) / 2, min: -89.9, max: 89.9)
    let latitudeDelta = clamp(
      max((maxLatitude - minLatitude) * 1.35, minimumLatitudeDelta),
      min: minimumLatitudeDelta,
      max: maximumLatitudeDelta
    )

    guard let longitudeArc = minimalLongitudeArc(for: validMarkers) else {
      return nil
    }

    let longitudeDelta = clamp(
      max(longitudeArc.span * 1.35, minimumLongitudeDelta),
      min: minimumLongitudeDelta,
      max: maximumLongitudeDelta
    )

    return sanitize(
      MKCoordinateRegion(
        center: CLLocationCoordinate2D(
          latitude: latitudeCenter,
          longitude: longitudeArc.center
        ),
        span: MKCoordinateSpan(
          latitudeDelta: latitudeDelta,
          longitudeDelta: longitudeDelta
        )
      )
    )
  }

  static func sanitize(_ region: MKCoordinateRegion) -> MKCoordinateRegion? {
    guard
      region.center.latitude.isFinite,
      region.center.longitude.isFinite,
      region.span.latitudeDelta.isFinite,
      region.span.longitudeDelta.isFinite
    else {
      return nil
    }

    let latitude = clamp(region.center.latitude, min: -89.9, max: 89.9)
    let longitude = normalizedLongitude(region.center.longitude)
    let latitudeDelta = clamp(
      abs(region.span.latitudeDelta),
      min: minimumLatitudeDelta,
      max: maximumLatitudeDelta
    )
    let longitudeDelta = clamp(
      abs(region.span.longitudeDelta),
      min: minimumLongitudeDelta,
      max: maximumLongitudeDelta
    )

    return MKCoordinateRegion(
      center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
      span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
    )
  }

  private static func minimalLongitudeArc(for markers: [AssetMapMarker]) -> (center: Double, span: Double)? {
    let sortedLongitudes = markers
      .map(\.longitude)
      .map(normalizedLongitudeTo360)
      .sorted()

    guard let first = sortedLongitudes.first else { return nil }
    if sortedLongitudes.count == 1 {
      return (center: normalizedLongitude(first), span: 0)
    }

    var largestGap = -Double.infinity
    var largestGapIndex = 0

    for index in sortedLongitudes.indices {
      let current = sortedLongitudes[index]
      let next = index == sortedLongitudes.index(before: sortedLongitudes.endIndex)
        ? sortedLongitudes[sortedLongitudes.startIndex] + 360
        : sortedLongitudes[sortedLongitudes.index(after: index)]
      let gap = next - current
      if gap > largestGap {
        largestGap = gap
        largestGapIndex = index
      }
    }

    let arcStart = largestGapIndex == sortedLongitudes.index(before: sortedLongitudes.endIndex)
      ? sortedLongitudes[sortedLongitudes.startIndex]
      : sortedLongitudes[sortedLongitudes.index(after: largestGapIndex)]
    let span = max(360 - largestGap, 0)
    let center = normalizedLongitude(arcStart + (span / 2))
    return (center: center, span: span)
  }

  private static func normalizedLongitude(_ longitude: Double) -> Double {
    let normalized = normalizedLongitudeTo360(longitude)
    return normalized > 180 ? normalized - 360 : normalized
  }

  private static func normalizedLongitudeTo360(_ longitude: Double) -> Double {
    var normalized = longitude.truncatingRemainder(dividingBy: 360)
    if normalized < 0 {
      normalized += 360
    }
    return normalized
  }

  private static func clamp(_ value: Double, min minimum: Double, max maximum: Double) -> Double {
    Swift.min(Swift.max(value, minimum), maximum)
  }
}

struct MapBrowserView: View {
  @ObservedObject var appState: AppState
  @ObservedObject var thumbnailStore: ThumbnailStore
  let onOpenAsset: (AppState.PhotoItem, CGRect, NSImage?) -> Void

  @State private var loadError: String?
  @State private var selectionError: String?
  @State private var hasPositionedCamera = false
  @State private var viewportRequest: MapViewportRequest?
  @State private var cachedPlaceGroups: [PlaceGroup] = []

  private let inspectorWidth: CGFloat = 340

  var body: some View {
    HStack(spacing: 0) {
      mapPane
        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)

      Divider()

      inspectorPane
        .frame(width: inspectorWidth)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
    .transaction {
      $0.animation = nil
      $0.disablesAnimations = true
    }
    .animation(nil, value: appState.selectedMapMarkerID)
    .animation(nil, value: appState.isLoadingMapSelection)
    .animation(nil, value: appState.mapSelectionItems.count)
    .task {
      if appState.mapMarkers.isEmpty {
        await refreshMarkers()
      } else {
        cachedPlaceGroups = buildPlaceGroups(from: appState.mapMarkers)
        if !hasPositionedCamera {
          focus(on: appState.mapMarkers)
        }
      }
    }
    .onChange(of: appState.mapMarkers) { _, markers in
      cachedPlaceGroups = buildPlaceGroups(from: markers)
      guard !markers.isEmpty, !hasPositionedCamera else { return }
      focus(on: markers)
    }
  }

  private var mapPane: some View {
    ZStack {
      if appState.isLoadingMap && appState.mapMarkers.isEmpty {
        ProgressView("Loading map…")
          .controlSize(.large)
      } else if appState.mapMarkers.isEmpty {
        ContentUnavailableView(
          "No places yet",
          systemImage: "map",
          description: Text(loadError ?? "Photos and videos with location data will appear here.")
        )
      } else {
        PlacesMapView(
          groups: cachedPlaceGroups,
          selectedMarkerID: appState.selectedMapMarkerID,
          viewportRequest: viewportRequest,
          onSelectMarkerID: { markerID in
            guard let group = cachedPlaceGroups.first(where: { $0.marker.id == markerID }) else { return }
            Task { await selectGroup(group, shouldFocus: false) }
          }
        )
        .overlay(alignment: Alignment.topTrailing) {
          Button {
            Task { await refreshMarkers() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.bordered)
          .padding(14)
        }
      }
    }
  }

  private var inspectorPane: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Places")
          .font(.title2.weight(.semibold))
        Text("\(cachedPlaceGroups.count) places • \(appState.mapMarkers.count) items")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .padding(18)

      if let loadError {
        Text(loadError)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 18)
          .padding(.bottom, 10)
      }

      Divider()

      selectedMarkerSection
        .padding(18)

      Divider()

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          ForEach(cachedPlaceGroups) { group in
            Button {
              Task { await selectGroup(group, shouldFocus: true) }
            } label: {
              HStack(alignment: .top, spacing: 10) {
                Image(systemName: appState.selectedMapMarkerID == group.marker.id ? "mappin.circle.fill" : "map")
                  .foregroundStyle(appState.selectedMapMarkerID == group.marker.id ? Color.accentColor : .secondary)
                  .frame(width: 18, height: 18)
                  .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                  Text(group.title)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.leading)
                  if let subtitle = group.subtitle {
                    Text(subtitle)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }

                Spacer()

                Text("\(group.count)")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.tertiary)
              }
              .padding(10)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                  .fill(appState.selectedMapMarkerID == group.marker.id ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
              )
            }
            .buttonStyle(.plain)
          }
        }
        .padding(18)
      }
    }
  }

  @ViewBuilder
  private var selectedMarkerSection: some View {
    if let group = selectedPlaceGroup {
      let marker = group.marker
      VStack(alignment: .leading, spacing: 12) {
        Label("Selected Location", systemImage: "mappin.and.ellipse")
          .font(.headline)

        VStack(alignment: .leading, spacing: 2) {
          Text(markerLabel(for: marker))
            .font(.subheadline.weight(.medium))
          Text(coordinateLabel(for: marker))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }

        if appState.isLoadingMapSelection {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Loading \(group.count) items…")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } else if !appState.mapSelectionItems.isEmpty {
          VStack(alignment: .leading, spacing: 10) {
            Text("\(appState.mapSelectionItems.count) items at this location")
              .font(.caption)
              .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: true) {
              LazyHStack(alignment: .top, spacing: 10) {
                ForEach(appState.mapSelectionItems) { item in
                  Button {
                    onOpenAsset(
                      item,
                      .zero,
                      thumbnailStore.cachedImage(for: item, context: appState.thumbnailContext, size: .preview)
                        ?? thumbnailStore.cachedImage(for: item, context: appState.thumbnailContext, size: .thumbnail)
                    )
                  } label: {
                    VStack(alignment: .leading, spacing: 6) {
                      AssetThumbnailView(item: item, context: appState.thumbnailContext, store: thumbnailStore)
                        .aspectRatio(item.gridAspectRatio, contentMode: .fill)
                        .frame(width: 110, height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                          RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(appState.selectedItemID == item.id ? Color.accentColor : Color.clear, lineWidth: 2)
                        }

                      Text(item.title)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                      if item.isVideo, let durationText = item.durationText {
                        Text(durationText)
                          .font(.caption2.monospacedDigit())
                          .foregroundStyle(.secondary)
                      }
                    }
                    .frame(width: 110, alignment: .leading)
                  }
                  .buttonStyle(.plain)
                }
              }
              .padding(.vertical, 2)
            }

            HStack {
              if let selectedItem = appState.selectedItem {
                Button("Open Selected") {
                  onOpenAsset(
                    selectedItem,
                    .zero,
                    thumbnailStore.cachedImage(for: selectedItem, context: appState.thumbnailContext, size: .preview)
                      ?? thumbnailStore.cachedImage(for: selectedItem, context: appState.thumbnailContext, size: .thumbnail)
                  )
                }
                .buttonStyle(.borderedProminent)
              }

              Button("Open in Maps") {
                openInMaps(marker)
              }
              .buttonStyle(.bordered)
            }
          }
        } else {
          if let selectionError {
            Text(selectionError)
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Text("Loading asset preview…")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          HStack {
            ProgressView()
              .controlSize(.small)
            Button("Open in Maps") {
              openInMaps(marker)
            }
            .buttonStyle(.bordered)
          }
        }
      }
    } else {
      VStack(alignment: .leading, spacing: 8) {
        Label("Selected Location", systemImage: "mappin.and.ellipse")
          .font(.headline)
        Text("Select a pin on the map to preview an asset and open it in the viewer.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var selectedPlaceGroup: PlaceGroup? {
    guard let selectedMapMarkerID = appState.selectedMapMarkerID else { return nil }
    return cachedPlaceGroups.first { $0.marker.id == selectedMapMarkerID }
  }

  private func buildPlaceGroups(from markers: [AssetMapMarker]) -> [PlaceGroup] {
    let grouped = Dictionary(grouping: markers, by: placeKey(for:))
    return grouped.compactMap { key, markers in
      // Sort deterministically so the representative marker (and thus pin coordinate
      // and selectedMapMarkerID) is stable across refreshes regardless of Dictionary
      // grouping order.
      let sortedMarkers = markers.sorted { lhs, rhs in
        lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
      }
      guard let representative = sortedMarkers.first else { return nil }
      let label = markerLabel(for: representative)
      let parts = label.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      let title = parts.first ?? label
      let subtitle = parts.count > 1 ? parts[1] : nil
      return PlaceGroup(
        id: key,
        title: title,
        subtitle: subtitle,
        count: sortedMarkers.count,
        marker: representative,
        markers: sortedMarkers
      )
    }
    .sorted {
      if $0.count != $1.count {
        return $0.count > $1.count
      }
      return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    }
  }

  private func placeKey(for marker: AssetMapMarker) -> String {
    let city = marker.city?.trimmingCharacters(in: .whitespacesAndNewlines)
    let country = marker.country?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let city, !city.isEmpty, let country, !country.isEmpty {
      return "\(city.lowercased())|\(country.lowercased())"
    }
    if let city, !city.isEmpty {
      return city.lowercased()
    }
    if let country, !country.isEmpty {
      return country.lowercased()
    }
    return marker.id
  }

  private func markerLabel(for marker: AssetMapMarker) -> String {
    let parts = [marker.city, marker.country]
      .compactMap { value -> String? in
        guard let value, !value.isEmpty else { return nil }
        return value
      }
    if !parts.isEmpty {
      return parts.joined(separator: ", ")
    }
    return "Pinned Photo"
  }

  private func coordinateLabel(for marker: AssetMapMarker) -> String {
    String(format: "%.4f, %.4f", marker.latitude, marker.longitude)
  }

  private func refreshMarkers() async {
    loadError = await appState.loadMapMarkers()
    selectionError = nil
    cachedPlaceGroups = buildPlaceGroups(from: appState.mapMarkers)
    if !appState.mapMarkers.isEmpty {
      focus(on: appState.mapMarkers)
    }
  }

  private func selectGroup(_ group: PlaceGroup, shouldFocus: Bool) async {
    selectionError = nil
    if shouldFocus {
      focus(on: group.marker)
    }
    selectionError = await appState.selectMapMarker(group.marker, markers: group.markers)
  }

  private func focus(on marker: AssetMapMarker) {
    guard let region = MapViewportBuilder.singleMarkerRegion(for: marker) else { return }
    viewportRequest = MapViewportRequest(region: region)
  }

  private func focus(on markers: [AssetMapMarker]) {
    guard let region = MapViewportBuilder.region(containing: markers) else { return }
    hasPositionedCamera = true
    viewportRequest = MapViewportRequest(region: region)
  }

  private func openInMaps(_ marker: AssetMapMarker) {
    let coordinate = marker.coordinate
    var components = URLComponents(string: "https://maps.apple.com")
    components?.queryItems = [
      URLQueryItem(name: "ll", value: "\(coordinate.latitude),\(coordinate.longitude)"),
      URLQueryItem(name: "q", value: markerLabel(for: marker)),
    ]
    guard let url = components?.url else { return }
    NSWorkspace.shared.open(url)
  }
}

private extension AssetMapMarker {
  var coordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }
}

private struct PlacesMapView: NSViewRepresentable {
  let groups: [PlaceGroup]
  let selectedMarkerID: String?
  let viewportRequest: MapViewportRequest?
  let onSelectMarkerID: (String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onSelectMarkerID: onSelectMarkerID)
  }

  func makeNSView(context: Context) -> MKMapView {
    let mapView = MKMapView()
    mapView.delegate = context.coordinator
    mapView.mapType = .standard
    mapView.showsCompass = true
    mapView.showsZoomControls = true
    mapView.pointOfInterestFilter = .includingAll
    mapView.register(PlaceAnnotationView.self, forAnnotationViewWithReuseIdentifier: PlaceAnnotationView.reuseIdentifier)
    return mapView
  }

  func updateNSView(_ mapView: MKMapView, context: Context) {
    guard !context.coordinator.isUpdating else { return }
    context.coordinator.isUpdating = true
    defer { context.coordinator.isUpdating = false }

    context.coordinator.onSelectMarkerID = onSelectMarkerID
    context.coordinator.updateAnnotations(groups, on: mapView)
    context.coordinator.applySelection(selectedMarkerID, on: mapView)

    if let viewportRequest {
      context.coordinator.queueViewportRequest(viewportRequest, on: mapView)
    }
  }

  final class Coordinator: NSObject, MKMapViewDelegate {
    var onSelectMarkerID: (String) -> Void
    var lastViewportRequestID: UUID?
    var selectedMarkerID: String?
    var isUpdating = false
    private var annotationSignatures: Set<String> = []
    private var lastAppliedSelectedMarkerID: String?
    private var pendingViewportRequest: MapViewportRequest?
    private var isViewportApplyScheduled = false

    init(onSelectMarkerID: @escaping (String) -> Void) {
      self.onSelectMarkerID = onSelectMarkerID
    }

    func updateAnnotations(_ groups: [PlaceGroup], on mapView: MKMapView) {
      let newSignatures = Set(groups.map { "\($0.id)|\($0.count)|\($0.marker.latitude)|\($0.marker.longitude)|\($0.title)|\($0.subtitle ?? "")" })
      guard newSignatures != annotationSignatures else { return }

      annotationSignatures = newSignatures
      lastAppliedSelectedMarkerID = nil
      mapView.removeAnnotations(mapView.annotations)
      let annotations = groups.map(PlaceAnnotation.init)
      mapView.addAnnotations(annotations)
    }

    func applySelection(_ selectedMarkerID: String?, on mapView: MKMapView) {
      self.selectedMarkerID = selectedMarkerID
      guard lastAppliedSelectedMarkerID != selectedMarkerID else { return }
      lastAppliedSelectedMarkerID = selectedMarkerID
      refreshAnnotationViews(on: mapView)
    }

    func queueViewportRequest(_ request: MapViewportRequest, on mapView: MKMapView) {
      guard lastViewportRequestID != request.id else { return }
      lastViewportRequestID = request.id
      pendingViewportRequest = request
      scheduleViewportApply(on: mapView)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
      guard let annotation = annotation as? PlaceAnnotation else { return nil }
      let view = mapView.dequeueReusableAnnotationView(
        withIdentifier: PlaceAnnotationView.reuseIdentifier,
        for: annotation
      )
      guard let placeView = view as? PlaceAnnotationView else { return view }
      placeView.configure(
        with: annotation,
        isSelected: selectedMarkerID == annotation.group.marker.id
      )
      placeView.onPress = { [weak self] tappedAnnotation in
        self?.onSelectMarkerID(tappedAnnotation.group.marker.id)
      }
      return placeView
    }

    private func refreshAnnotationViews(on mapView: MKMapView) {
      for annotation in mapView.annotations {
        guard
          let placeAnnotation = annotation as? PlaceAnnotation,
          let view = mapView.view(for: annotation) as? PlaceAnnotationView
        else { continue }

        let isSelected = selectedMarkerID == placeAnnotation.group.marker.id
        view.configure(with: placeAnnotation, isSelected: isSelected)
      }
    }

    private func scheduleViewportApply(on mapView: MKMapView) {
      guard !isViewportApplyScheduled else { return }
      isViewportApplyScheduled = true
      DispatchQueue.main.async { [weak self, weak mapView] in
        guard let self, let mapView else { return }
        self.isViewportApplyScheduled = false
        self.applyPendingViewport(on: mapView)
      }
    }

    private func applyPendingViewport(on mapView: MKMapView) {
      guard let request = pendingViewportRequest else { return }
      // `MKMapView.setRegion` can be invoked while SwiftUI is still resizing the AppKit host.
      // Waiting until the map has a real window and non-trivial bounds keeps us out of the
      // `MKWhenSized` layout recursion that caused the earlier crash reports.
      guard mapView.window != nil, mapView.bounds.width > 32, mapView.bounds.height > 32 else {
        scheduleViewportApply(on: mapView)
        return
      }

      guard let region = MapViewportBuilder.sanitize(mapView.regionThatFits(request.region)) else {
        pendingViewportRequest = nil
        return
      }

      pendingViewportRequest = nil
      mapView.setRegion(region, animated: false)
    }
  }
}

private final class PlaceAnnotation: NSObject, MKAnnotation {
  let group: PlaceGroup

  var coordinate: CLLocationCoordinate2D { group.marker.coordinate }
  var title: String? { group.title }
  var subtitle: String? { group.subtitle }

  init(group: PlaceGroup) {
    self.group = group
  }
}

private final class PlaceAnnotationView: MKMarkerAnnotationView {
  static let reuseIdentifier = "ImmichPlaceAnnotationView"

  var onPress: ((PlaceAnnotation) -> Void)?

  override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
    super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    canShowCallout = false
    animatesWhenAdded = false
    titleVisibility = .hidden
    subtitleVisibility = .hidden
    displayPriority = .required
    collisionMode = .circle
  }

  func configure(with annotation: PlaceAnnotation, isSelected: Bool) {
    markerTintColor = isSelected ? .controlAccentColor : .systemRed
    glyphTintColor = .white
    clusteringIdentifier = nil

    if annotation.group.count > 1 {
      glyphText = annotation.group.count > 99 ? "99+" : "\(annotation.group.count)"
      glyphImage = nil
    } else {
      glyphText = nil
      let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
      glyphImage = NSImage(systemSymbolName: "photo", accessibilityDescription: annotation.group.title)?
        .withSymbolConfiguration(configuration)
    }
  }

  override func mouseUp(with event: NSEvent) {
    super.mouseUp(with: event)
    guard let annotation = annotation as? PlaceAnnotation else {
      return
    }

    onPress?(annotation)
  }
}
#endif

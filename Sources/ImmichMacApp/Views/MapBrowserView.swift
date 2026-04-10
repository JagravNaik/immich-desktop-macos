#if canImport(SwiftUI) && canImport(MapKit) && canImport(AppKit)
import SwiftUI
import MapKit
import AppKit
import ImmichCore

typealias AssetMapMarker = ImmichCore.MapMarker

private struct MapViewportRequest {
  let id = UUID()
  let region: MKCoordinateRegion
}

private struct DisplayMapMarker: Identifiable, Hashable {
  let id: String
  let latitude: Double
  let longitude: Double
  let city: String?
  let country: String?
  let members: [AssetMapMarker]

  var coordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }

  var representative: AssetMapMarker {
    members[0]
  }

  var count: Int {
    members.count
  }

  func contains(markerID: String?) -> Bool {
    guard let markerID else { return false }
    return members.contains { $0.id == markerID }
  }
}

private enum MapMarkerAggregator {
  static func aggregate(_ markers: [AssetMapMarker]) -> [DisplayMapMarker] {
    guard markers.count > 1 else {
      return markers.map {
        DisplayMapMarker(
          id: $0.id,
          latitude: $0.latitude,
          longitude: $0.longitude,
          city: $0.city,
          country: $0.country,
          members: [$0]
        )
      }
    }

    let coordinateStep = aggregationStep(for: markers.count)
    var buckets: [BucketKey: [AssetMapMarker]] = [:]
    buckets.reserveCapacity(markers.count)

    for marker in markers {
      let key = BucketKey(marker: marker, coordinateStep: coordinateStep)
      buckets[key, default: []].append(marker)
    }

    return buckets.values
      .map(makeDisplayMarker)
      .sorted { lhs, rhs in
        if lhs.count != rhs.count {
          return lhs.count > rhs.count
        }
        return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
      }
  }

  private struct BucketKey: Hashable {
    let latitudeBucket: Int
    let longitudeBucket: Int
    let city: String
    let country: String

    init(marker: AssetMapMarker, coordinateStep: Double) {
      latitudeBucket = Int((marker.latitude / coordinateStep).rounded())
      longitudeBucket = Int((marker.longitude / coordinateStep).rounded())
      city = marker.city?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
      country = marker.country?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }
  }

  private static func aggregationStep(for markerCount: Int) -> Double {
    switch markerCount {
    case 0..<2_000:
      return 0.0025
    case 2_000..<5_000:
      return 0.005
    case 5_000..<12_000:
      return 0.01
    case 12_000..<25_000:
      return 0.025
    default:
      return 0.05
    }
  }

  private static func makeDisplayMarker(from members: [AssetMapMarker]) -> DisplayMapMarker {
    let representative = members[0]
    let latitude = members.map(\.latitude).reduce(0, +) / Double(members.count)
    let longitude = members.map(\.longitude).reduce(0, +) / Double(members.count)
    let sortedMembers = members.sorted { lhs, rhs in
      if lhs.city != rhs.city {
        return (lhs.city ?? "").localizedCaseInsensitiveCompare(rhs.city ?? "") == .orderedAscending
      }
      if lhs.country != rhs.country {
        return (lhs.country ?? "").localizedCaseInsensitiveCompare(rhs.country ?? "") == .orderedAscending
      }
      return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
    }

    return DisplayMapMarker(
      id: sortedMembers.map(\.id).joined(separator: "|"),
      latitude: latitude,
      longitude: longitude,
      city: representative.city,
      country: representative.country,
      members: sortedMembers
    )
  }
}

private enum MapDisplayMode: String, CaseIterable, Identifiable {
  case map = "Map"
  case satellite = "Satellite"
  case grid = "Grid"

  var id: String { rawValue }

  var mapType: MKMapType {
    switch self {
    case .map:
      return .standard
    case .satellite:
      return .satellite
    case .grid:
      return .hybrid
    }
  }
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
  @State private var displayMode: MapDisplayMode = .map
  @State private var searchText = ""
  @State private var isShowingLocationGallery = false

  var body: some View {
    ZStack {
      mapBackground
      floatingChrome
      if isShowingLocationGallery {
        locationGalleryOverlay
      }
    }
    .clipped()
    .task {
      if appState.mapMarkers.isEmpty {
        await refreshMarkers()
      } else if !hasPositionedCamera {
        focus(on: displayMarkers.isEmpty ? allDisplayMarkers : displayMarkers)
      }
    }
    .onChange(of: appState.mapMarkers) { _, markers in
      guard !markers.isEmpty else { return }
      if !hasPositionedCamera {
        let aggregatedMarkers = MapMarkerAggregator.aggregate(markers)
        focus(on: displayMarkers.isEmpty ? aggregatedMarkers : displayMarkers)
      }
    }
    .onChange(of: searchText) { _, _ in
      selectionError = nil
      let markers = displayMarkers
      guard !markers.isEmpty else { return }
      focus(on: markers)
    }
  }

  private var filteredMarkers: [AssetMapMarker] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return appState.mapMarkers }
    let needle = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

    return appState.mapMarkers.filter { marker in
      [
        marker.city,
        marker.country,
        markerSearchLabel(for: marker),
      ]
        .compactMap { $0 }
        .contains { value in
          value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(needle)
        }
    }
  }

  private var displayMarkers: [DisplayMapMarker] {
    MapMarkerAggregator.aggregate(filteredMarkers)
  }

  private var allDisplayMarkers: [DisplayMapMarker] {
    MapMarkerAggregator.aggregate(appState.mapMarkers)
  }

  private var selectedMarker: DisplayMapMarker? {
    allDisplayMarkers.first { $0.contains(markerID: appState.selectedMapMarkerID) }
  }

  private var mapBackground: some View {
    ZStack {
      if appState.isLoadingMap && appState.mapMarkers.isEmpty {
        ProgressView("Loading map…")
          .controlSize(.large)
          .tint(.white)
      } else if appState.mapMarkers.isEmpty {
        ContentUnavailableView(
          "No places yet",
          systemImage: "map",
          description: Text(loadError ?? "Photos and videos with location data will appear here.")
        )
      } else if filteredMarkers.isEmpty {
        PlacesMapView(
          markers: allDisplayMarkers,
          selectedMarkerID: selectedMarker?.id,
          viewportRequest: viewportRequest,
          mapType: displayMode.mapType,
          thumbnailStore: thumbnailStore,
          thumbnailContext: appState.thumbnailContext,
          onSelectMarkers: handleMarkerSelection,
          onOpenMarkers: handleMarkerOpen
        )
        .overlay {
          ContentUnavailableView(
            "No Matching Places",
            systemImage: "magnifyingglass",
            description: Text("Try a different city or country.")
          )
          .padding(32)
          .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
      } else {
        PlacesMapView(
          markers: displayMarkers,
          selectedMarkerID: selectedMarker?.id,
          viewportRequest: viewportRequest,
          mapType: displayMode.mapType,
          thumbnailStore: thumbnailStore,
          thumbnailContext: appState.thumbnailContext,
          onSelectMarkers: handleMarkerSelection,
          onOpenMarkers: handleMarkerOpen
        )
      }
    }
    .background(Color.black)
  }

  private var floatingChrome: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 16) {
        mapStylePicker
          .padding(.top, 18)

        Spacer(minLength: 0)

        searchBar
          .frame(width: 300)
          .padding(.top, 18)
          .padding(.trailing, 18)
      }

      Spacer(minLength: 0)

      if let marker = selectedMarker, !appState.mapSelectionItems.isEmpty || appState.isLoadingMapSelection || selectionError != nil {
        selectedLocationTray(for: marker)
          .padding(.horizontal, 24)
          .padding(.bottom, 20)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
  }

  private var locationGalleryOverlay: some View {
    ZStack {
      Color.black.opacity(0.4)
        .ignoresSafeArea()
        .onTapGesture {
          isShowingLocationGallery = false
        }

      VStack(spacing: 0) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Text(selectedMarker.map(markerLabel(for:)) ?? "Location")
              .font(.title2.weight(.semibold))
            Text("\(appState.mapSelectionItems.count) item\(appState.mapSelectionItems.count == 1 ? "" : "s")")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Spacer()

          Button {
            isShowingLocationGallery = false
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 13, weight: .bold))
              .frame(width: 28, height: 28)
              .background(.white.opacity(0.08), in: Circle())
          }
          .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)

        Divider()

        LibraryGridView(
          appState: appState,
          thumbnailStore: thumbnailStore,
          heroHiddenItemID: nil,
          onOpenAsset: onOpenAsset,
          onHeroFramesChanged: { _ in }
        )
      }
      .frame(minWidth: 900, minHeight: 620)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
          .strokeBorder(.white.opacity(0.12))
      }
      .shadow(color: .black.opacity(0.28), radius: 30, y: 16)
      .padding(36)
    }
    .zIndex(5)
    .transition(.opacity)
  }

  private var mapStylePicker: some View {
    Picker("Map Style", selection: $displayMode) {
      ForEach(MapDisplayMode.allCases) { mode in
        Text(mode.rawValue)
          .tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .padding(5)
    .background(.ultraThinMaterial, in: Capsule())
    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    .padding(.leading, 18)
    .frame(maxWidth: 320)
  }

  private var searchBar: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("", text: $searchText, prompt: Text("Search Places"))
        .textFieldStyle(.plain)
        .foregroundStyle(.primary)

      if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.ultraThinMaterial, in: Capsule())
    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
  }

  @ViewBuilder
  private func selectedLocationTray(for marker: DisplayMapMarker) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(markerLabel(for: marker))
            .font(.headline.weight(.semibold))
          Text("\(appState.mapSelectionItems.count) item\(appState.mapSelectionItems.count == 1 ? "" : "s")")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Button {
          appState.clearMapSelection()
          selectionError = nil
          isShowingLocationGallery = false
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .bold))
            .frame(width: 28, height: 28)
            .background(.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)

        Button("Open in Maps") {
          openInMaps(marker)
        }
        .buttonStyle(.bordered)
      }

      if appState.isLoadingMapSelection {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Loading nearby photos…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if appState.mapSelectionItems.isEmpty {
        Text(selectionError ?? "No photos available here yet.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          LazyHStack(spacing: 12) {
            ForEach(appState.mapSelectionItems.prefix(18)) { item in
              Button {
                onOpenAsset(item, .zero, heroImage(for: item))
              } label: {
                ZStack(alignment: .bottomLeading) {
                  AssetThumbnailView(item: item, context: appState.thumbnailContext, store: thumbnailStore)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                  if item.isVideo, let durationText = item.durationText {
                    Text(durationText)
                      .font(.caption2.monospacedDigit().weight(.semibold))
                      .padding(.horizontal, 7)
                      .padding(.vertical, 4)
                      .background(.black.opacity(0.7), in: Capsule())
                      .foregroundStyle(.white)
                      .padding(8)
                  }
                }
                .overlay {
                  RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(appState.selectedItemID == item.id ? Color.accentColor : .white.opacity(0.42), lineWidth: appState.selectedItemID == item.id ? 2.5 : 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 14, y: 7)
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.vertical, 2)
        }
      }
    }
    .padding(18)
    .frame(maxWidth: 820, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .strokeBorder(.white.opacity(0.12))
    }
    .shadow(color: .black.opacity(0.2), radius: 18, y: 10)
  }

  private func heroImage(for item: AppState.PhotoItem) -> NSImage? {
    thumbnailStore.cachedImage(for: item, context: appState.thumbnailContext, size: .preview)
      ?? thumbnailStore.cachedImage(for: item, context: appState.thumbnailContext, size: .thumbnail)
  }

  private func markerLabel(for marker: DisplayMapMarker) -> String {
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

  private func markerSearchLabel(for marker: AssetMapMarker) -> String {
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

  private func refreshMarkers() async {
    loadError = await appState.loadMapMarkers()
    selectionError = nil
    let markers = displayMarkers.isEmpty ? allDisplayMarkers : displayMarkers
    if !markers.isEmpty {
      focus(on: markers)
    }
  }

  private func handleMarkerSelection(_ markers: [DisplayMapMarker]) {
    DispatchQueue.main.async {
      Task {
        await selectMarkers(markers)
      }
    }
  }

  private func handleMarkerOpen(_ markers: [DisplayMapMarker]) {
    DispatchQueue.main.async {
      Task {
        await openMarkers(markers)
      }
    }
  }

  private func selectMarkers(_ markers: [DisplayMapMarker]) async {
    guard let first = markers.first else { return }
    selectionError = nil
    isShowingLocationGallery = false

    if markers.count > 1 {
      appState.clearMapSelection()
      focus(on: markers)
      return
    }

    focus(on: first)
    selectionError = await appState.selectMapMarker(first.representative, markers: first.members)
  }

  private func openMarkers(_ markers: [DisplayMapMarker]) async {
    guard let first = markers.first else { return }
    selectionError = nil

    if markers.count > 1 {
      focus(on: markers)
    } else {
      focus(on: first)
    }

    selectionError = await appState.selectMapMarker(first.representative, markers: first.members)
    if selectionError == nil || !appState.mapSelectionItems.isEmpty {
      isShowingLocationGallery = !appState.mapSelectionItems.isEmpty
    }
  }

  private func focus(on marker: DisplayMapMarker) {
    guard let region = MapViewportBuilder.singleMarkerRegion(for: marker.representative) else { return }
    viewportRequest = MapViewportRequest(region: region)
  }

  private func focus(on markers: [DisplayMapMarker]) {
    guard let region = MapViewportBuilder.region(containing: markers.map(\.representative)) else { return }
    hasPositionedCamera = true
    viewportRequest = MapViewportRequest(region: region)
  }

  private func openInMaps(_ marker: DisplayMapMarker) {
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

private extension AppState.PhotoItem {
  static func mapThumbnailPlaceholder(for marker: DisplayMapMarker) -> Self {
    let title = [marker.city, marker.country]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
      .joined(separator: ", ")

    return AppState.PhotoItem(
      id: marker.id,
      source: .remoteAsset(id: marker.representative.id),
      title: title.isEmpty ? "Pinned Photo" : title,
      date: .distantPast,
      isFavorite: false,
      isVideo: false,
      isImported: false,
      livePhotoVideoID: nil,
      latitude: marker.latitude,
      longitude: marker.longitude,
      durationText: nil,
      city: marker.city,
      country: marker.country,
      stackCount: nil,
      timeBucketKey: "map",
      projectionType: nil,
      aspectRatio: 1
    )
  }
}

private struct PlacesMapView: NSViewRepresentable {
  let markers: [DisplayMapMarker]
  let selectedMarkerID: String?
  let viewportRequest: MapViewportRequest?
  let mapType: MKMapType
  let thumbnailStore: ThumbnailStore
  let thumbnailContext: AppState.ThumbnailContext?
  let onSelectMarkers: ([DisplayMapMarker]) -> Void
  let onOpenMarkers: ([DisplayMapMarker]) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      thumbnailStore: thumbnailStore,
      thumbnailContext: thumbnailContext,
      onSelectMarkers: onSelectMarkers,
      onOpenMarkers: onOpenMarkers
    )
  }

  func makeNSView(context: Context) -> MKMapView {
    let mapView = MKMapView()
    mapView.delegate = context.coordinator
    mapView.mapType = mapType
    mapView.showsCompass = false
    mapView.showsZoomControls = false
    mapView.showsScale = false
    mapView.pointOfInterestFilter = .includingAll
    mapView.isPitchEnabled = false
    mapView.register(PhotoMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: PhotoMarkerAnnotationView.reuseIdentifier)
    mapView.register(PhotoClusterAnnotationView.self, forAnnotationViewWithReuseIdentifier: PhotoClusterAnnotationView.reuseIdentifier)
    return mapView
  }

  func updateNSView(_ mapView: MKMapView, context: Context) {
    guard !context.coordinator.isUpdating else { return }
    context.coordinator.isUpdating = true
    defer { context.coordinator.isUpdating = false }

    context.coordinator.onSelectMarkers = onSelectMarkers
    context.coordinator.onOpenMarkers = onOpenMarkers
    context.coordinator.thumbnailContext = thumbnailContext
    context.coordinator.thumbnailStore = thumbnailStore
    context.coordinator.updateAnnotations(markers, on: mapView)
    context.coordinator.applySelection(selectedMarkerID, on: mapView)

    if mapView.mapType != mapType {
      mapView.mapType = mapType
    }

    if let viewportRequest {
      context.coordinator.queueViewportRequest(viewportRequest, on: mapView)
    }
  }

  final class Coordinator: NSObject, MKMapViewDelegate {
    var thumbnailStore: ThumbnailStore
    var thumbnailContext: AppState.ThumbnailContext?
    var onSelectMarkers: ([DisplayMapMarker]) -> Void
    var onOpenMarkers: ([DisplayMapMarker]) -> Void
    var isUpdating = false

    private var annotationSignatures: Set<String> = []
    private var selectedMarkerID: String?
    private var lastAppliedSelectedMarkerID: String?
    private var pendingViewportRequest: MapViewportRequest?
    private var lastViewportRequestID: UUID?
    private var isViewportApplyScheduled = false

    init(
      thumbnailStore: ThumbnailStore,
      thumbnailContext: AppState.ThumbnailContext?,
      onSelectMarkers: @escaping ([DisplayMapMarker]) -> Void,
      onOpenMarkers: @escaping ([DisplayMapMarker]) -> Void
    ) {
      self.thumbnailStore = thumbnailStore
      self.thumbnailContext = thumbnailContext
      self.onSelectMarkers = onSelectMarkers
      self.onOpenMarkers = onOpenMarkers
    }

    func updateAnnotations(_ markers: [DisplayMapMarker], on mapView: MKMapView) {
      let newSignatures = Set(markers.map { "\($0.id)|\($0.latitude)|\($0.longitude)|\($0.city ?? "")|\($0.country ?? "")" })
      guard newSignatures != annotationSignatures else { return }

      annotationSignatures = newSignatures
      lastAppliedSelectedMarkerID = nil
      mapView.removeAnnotations(mapView.annotations)
      mapView.addAnnotations(markers.map(PhotoMapAnnotation.init))
    }

    func applySelection(_ selectedMarkerID: String?, on mapView: MKMapView) {
      self.selectedMarkerID = selectedMarkerID
      guard lastAppliedSelectedMarkerID != selectedMarkerID else { return }
      lastAppliedSelectedMarkerID = selectedMarkerID

      for annotation in mapView.annotations {
        guard let view = mapView.view(for: annotation) else { continue }

        if let markerAnnotation = annotation as? PhotoMapAnnotation,
           let markerView = view as? PhotoMarkerAnnotationView {
          markerView.setSelected(markerAnnotation.marker.id == selectedMarkerID)
        } else if let clusterView = view as? PhotoClusterAnnotationView {
          clusterView.setSelected(false)
        }
      }
    }

    func queueViewportRequest(_ request: MapViewportRequest, on mapView: MKMapView) {
      guard lastViewportRequestID != request.id else { return }
      lastViewportRequestID = request.id
      pendingViewportRequest = request
      scheduleViewportApply(on: mapView)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
      switch annotation {
      case let cluster as MKClusterAnnotation:
        let view = mapView.dequeueReusableAnnotationView(
          withIdentifier: PhotoClusterAnnotationView.reuseIdentifier,
          for: cluster
        )
        guard let clusterView = view as? PhotoClusterAnnotationView else { return view }
        clusterView.configure(
          cluster,
          thumbnailStore: thumbnailStore,
          thumbnailContext: thumbnailContext
        )
        clusterView.onPress = { [weak self] in
          let markers = cluster.memberAnnotations.compactMap { ($0 as? PhotoMapAnnotation)?.marker }
          self?.onSelectMarkers(markers)
        }
        clusterView.onDoublePress = { [weak self] in
          let markers = cluster.memberAnnotations.compactMap { ($0 as? PhotoMapAnnotation)?.marker }
          self?.onOpenMarkers(markers)
        }
        return clusterView

      case let marker as PhotoMapAnnotation:
        let view = mapView.dequeueReusableAnnotationView(
          withIdentifier: PhotoMarkerAnnotationView.reuseIdentifier,
          for: marker
        )
        guard let markerView = view as? PhotoMarkerAnnotationView else { return view }
        markerView.configure(
          marker: marker.marker,
          isSelected: marker.marker.id == selectedMarkerID,
          thumbnailStore: thumbnailStore,
          thumbnailContext: thumbnailContext
        )
        markerView.onPress = { [weak self] in
          self?.onSelectMarkers([marker.marker])
        }
        markerView.onDoublePress = { [weak self] in
          self?.onOpenMarkers([marker.marker])
        }
        return markerView

      default:
        return nil
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
      guard mapView.window != nil, mapView.bounds.width > 32, mapView.bounds.height > 32 else {
        scheduleViewportApply(on: mapView)
        return
      }

      guard let region = MapViewportBuilder.sanitize(mapView.regionThatFits(request.region)) else {
        pendingViewportRequest = nil
        return
      }

      pendingViewportRequest = nil
      mapView.setRegion(region, animated: true)
    }
  }
}

private final class PhotoMapAnnotation: NSObject, MKAnnotation {
  let marker: DisplayMapMarker

  var coordinate: CLLocationCoordinate2D { marker.coordinate }
  var title: String? {
    [marker.city, marker.country]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
      .joined(separator: ", ")
  }

  init(marker: DisplayMapMarker) {
    self.marker = marker
  }
}

private final class PhotoPinCardView: NSView {
  private let imageView = NSImageView()
  private let countLabel = NSTextField(labelWithString: "")
  private let placeholderLayer = CALayer()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = false
    layer?.cornerRadius = 16
    layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
    layer?.borderColor = NSColor.white.withAlphaComponent(0.88).cgColor
    layer?.borderWidth = 2
    layer?.shadowColor = NSColor.black.withAlphaComponent(0.32).cgColor
    layer?.shadowOpacity = 1
    layer?.shadowRadius = 14
    layer?.shadowOffset = CGSize(width: 0, height: 8)

    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.imageScaling = .scaleAxesIndependently
    imageView.wantsLayer = true
    imageView.layer?.cornerRadius = 14
    imageView.layer?.masksToBounds = true
    addSubview(imageView)

    countLabel.translatesAutoresizingMaskIntoConstraints = false
    countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    countLabel.textColor = .white
    countLabel.backgroundColor = .clear
    countLabel.lineBreakMode = .byClipping
    countLabel.maximumNumberOfLines = 1
    countLabel.isHidden = true
    addSubview(countLabel)

    placeholderLayer.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
    placeholderLayer.cornerRadius = 14
    layer?.addSublayer(placeholderLayer)

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
      imageView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

      countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      countLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    placeholderLayer.frame = bounds.insetBy(dx: 2, dy: 2)
  }

  func update(image: NSImage?, count: Int?, selected: Bool) {
    imageView.image = image
    placeholderLayer.isHidden = image != nil
    layer?.borderColor = selected ? NSColor.controlAccentColor.cgColor : NSColor.white.withAlphaComponent(0.88).cgColor
    layer?.borderWidth = selected ? 3 : 2

    if let count, count > 1 {
      countLabel.stringValue = "\(count)"
      countLabel.isHidden = false
    } else {
      countLabel.stringValue = ""
      countLabel.isHidden = true
    }
  }
}

private class BasePhotoAnnotationView: MKAnnotationView {
  let cardView = PhotoPinCardView(frame: NSRect(x: 0, y: 0, width: 76, height: 76))
  var onPress: (() -> Void)?
  var onDoublePress: (() -> Void)?

  override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
    super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
    canShowCallout = false
    collisionMode = .rectangle
    displayPriority = .required
    frame = NSRect(x: 0, y: 0, width: 76, height: 76)
    centerOffset = CGPoint(x: 0, y: -38)
    wantsLayer = false
    addSubview(cardView)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    cardView.frame = bounds
  }

  override func mouseUp(with event: NSEvent) {
    super.mouseUp(with: event)
    if event.clickCount >= 2 {
      onDoublePress?()
    } else {
      onPress?()
    }
  }
}

private final class PhotoMarkerAnnotationView: BasePhotoAnnotationView {
  static let reuseIdentifier = "ImmichPhotoMarkerAnnotationView"

  private var imageTask: Task<Void, Never>?
  private var representedMarkerID: String?

  override func prepareForReuse() {
    super.prepareForReuse()
    imageTask?.cancel()
    imageTask = nil
    representedMarkerID = nil
    cardView.update(image: nil, count: nil, selected: false)
  }

  func configure(
    marker: DisplayMapMarker,
    isSelected: Bool,
    thumbnailStore: ThumbnailStore,
    thumbnailContext: AppState.ThumbnailContext?
  ) {
    clusteringIdentifier = "immich-map-asset"
    representedMarkerID = marker.id
    cardView.update(
      image: thumbnailStore.cachedImage(for: .mapThumbnailPlaceholder(for: marker), context: thumbnailContext, size: .thumbnail),
      count: marker.count,
      selected: isSelected
    )

    imageTask?.cancel()
    imageTask = Task { @MainActor [weak self] in
      let placeholder = AppState.PhotoItem.mapThumbnailPlaceholder(for: marker)
      let image = await thumbnailStore.loadImage(for: placeholder, context: thumbnailContext, size: .thumbnail)
      guard let self, self.representedMarkerID == marker.id else { return }
      self.cardView.update(image: image, count: marker.count, selected: isSelected)
    }
  }

  func setSelected(_ isSelected: Bool) {
    let count = (annotation as? PhotoMapAnnotation)?.marker.count
    cardView.update(image: cardViewImage, count: count, selected: isSelected)
  }

  private var cardViewImage: NSImage? {
    cardView.subviews.compactMap { ($0 as? NSImageView)?.image }.first
  }
}

private final class PhotoClusterAnnotationView: BasePhotoAnnotationView {
  static let reuseIdentifier = "ImmichPhotoClusterAnnotationView"

  private var imageTask: Task<Void, Never>?
  private var representedClusterMemberIDs: [String] = []

  override func prepareForReuse() {
    super.prepareForReuse()
    imageTask?.cancel()
    imageTask = nil
    representedClusterMemberIDs = []
    clusteringIdentifier = nil
    cardView.update(image: nil, count: nil, selected: false)
  }

  func configure(
    _ cluster: MKClusterAnnotation,
    thumbnailStore: ThumbnailStore,
    thumbnailContext: AppState.ThumbnailContext?
  ) {
    let markers = cluster.memberAnnotations.compactMap { ($0 as? PhotoMapAnnotation)?.marker }
    let representative = markers.first
    representedClusterMemberIDs = markers.flatMap(\.members).map(\.id)
    clusteringIdentifier = nil
    let totalCount = markers.reduce(0) { $0 + $1.count }

    if let representative {
      cardView.update(
        image: thumbnailStore.cachedImage(for: .mapThumbnailPlaceholder(for: representative), context: thumbnailContext, size: .thumbnail),
        count: totalCount,
        selected: false
      )
    } else {
      cardView.update(image: nil, count: totalCount, selected: false)
    }

    imageTask?.cancel()
    guard let representative else { return }

    imageTask = Task { @MainActor [weak self] in
      let placeholder = AppState.PhotoItem.mapThumbnailPlaceholder(for: representative)
      let image = await thumbnailStore.loadImage(for: placeholder, context: thumbnailContext, size: .thumbnail)
      guard let self, self.representedClusterMemberIDs == markers.flatMap(\.members).map(\.id) else { return }
      self.cardView.update(image: image, count: totalCount, selected: false)
    }
  }

  func setSelected(_ isSelected: Bool) {
    cardView.update(image: cardViewImage, count: representedClusterMemberIDs.count, selected: isSelected)
  }

  private var cardViewImage: NSImage? {
    cardView.subviews.compactMap { ($0 as? NSImageView)?.image }.first
  }
}
#endif

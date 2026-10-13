#if canImport(SwiftUI)
import SwiftUI
import MapKit

struct AssetLocationEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State private var selectedCoordinate: CLLocationCoordinate2D?
  @State private var cameraPosition: MapCameraPosition
  @State private var placeQuery = ""
  @State private var placeResults: [MKMapItem] = []
  @State private var isSearchingPlaces = false
  @State private var errorMessage: String?
  @State private var isSaving = false

  private let onSave: @MainActor (Double, Double) async throws -> Void

  init(
    initialCoordinate: CLLocationCoordinate2D?,
    onSave: @escaping @MainActor (Double, Double) async throws -> Void
  ) {
    self.onSave = onSave
    _selectedCoordinate = State(initialValue: initialCoordinate)
    if let initialCoordinate {
      _cameraPosition = State(initialValue: .region(MKCoordinateRegion(
        center: initialCoordinate,
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
      )))
    } else {
      _cameraPosition = State(initialValue: .automatic)
    }
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 8) {
          TextField("Search places", text: $placeQuery)
            .textFieldStyle(.roundedBorder)
            .onSubmit { Task { await searchPlaces() } }
            .disabled(isSearchingPlaces || isSaving)

          Button {
            Task { await searchPlaces() }
          } label: {
            if isSearchingPlaces {
              ProgressView()
                .controlSize(.small)
                .frame(width: 18, height: 18)
            } else {
              Image(systemName: "magnifyingglass")
                .frame(width: 18, height: 18)
            }
          }
          .buttonStyle(.bordered)
          .disabled(placeQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearchingPlaces || isSaving)
          .accessibilityLabel("Search places")
        }

        if !placeResults.isEmpty {
          ScrollView {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(placeResults.indices, id: \.self) { index in
                let place = placeResults[index]
                Button {
                  selectPlace(place)
                } label: {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(place.name ?? place.placemark.title ?? "Place")
                      .font(.body)
                      .lineLimit(1)
                    let subtitle = placeSubtitle(place)
                    if !subtitle.isEmpty {
                      Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .contentShape(Rectangle())
                  .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(placeAccessibilityLabel(place))
              }
            }
          }
          .frame(maxHeight: 112)
        }

        MapReader { proxy in
          Map(position: $cameraPosition) {
            if let selectedCoordinate {
              Marker("Selected Location", coordinate: selectedCoordinate)
            }
          }
          .onTapGesture(coordinateSpace: .local) { point in
            guard let coordinate = proxy.convert(point, from: .local) else { return }
            selectedCoordinate = coordinate
            errorMessage = nil
          }
          .accessibilityLabel("Map. Tap to choose a location.")
        }
        .frame(minHeight: 280)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

        if let selectedCoordinate {
          Label(
            String(format: "%.5f, %.5f", selectedCoordinate.latitude, selectedCoordinate.longitude),
            systemImage: "mappin.and.ellipse"
          )
          .font(.callout.monospacedDigit())
        } else {
          Text("Tap the map or search for a place to choose this photo’s location.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        if let errorMessage {
          Text(errorMessage)
            .font(.callout)
            .foregroundStyle(.red)
        }
      }
      .padding(16)
      .navigationTitle("Edit Location")
      .onChange(of: placeQuery) { _, _ in
        placeResults = []
        errorMessage = nil
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(isSaving ? "Saving…" : "Save") {
            Task { await save() }
          }
          .disabled(selectedCoordinate == nil || isSaving)
          .keyboardShortcut(.defaultAction)
        }
      }
    }
    .frame(minWidth: 480, minHeight: 580)
  }

  @MainActor
  private func searchPlaces() async {
    let query = placeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return }

    isSearchingPlaces = true
    errorMessage = nil
    defer { isSearchingPlaces = false }

    do {
      placeResults = try await Self.searchPlaces(matching: query).mapItems
    } catch {
      placeResults = []
      errorMessage = "Place search failed: \(error.localizedDescription)"
    }
  }

  /// `MKLocalSearch.Response` isn't Sendable; run the search off the main actor and box the items.
  private struct PlaceSearchResults: @unchecked Sendable {
    let mapItems: [MKMapItem]
  }

  private nonisolated static func searchPlaces(matching query: String) async throws -> PlaceSearchResults {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    let response = try await MKLocalSearch(request: request).start()
    return PlaceSearchResults(mapItems: response.mapItems)
  }

  private func selectPlace(_ place: MKMapItem) {
    let coordinate = place.placemark.coordinate
    selectedCoordinate = coordinate
    errorMessage = nil
    placeQuery = place.name ?? place.placemark.title ?? placeQuery
    let region = MKCoordinateRegion(
      center: coordinate,
      span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
    )
    withAnimation(.easeInOut(duration: 0.35)) {
      cameraPosition = .region(region)
    }
    placeResults = []
  }

  private func placeSubtitle(_ place: MKMapItem) -> String {
    [
      place.placemark.subLocality,
      place.placemark.locality,
      place.placemark.administrativeArea,
      place.placemark.country,
    ]
    .compactMap { $0 }
    .filter { !$0.isEmpty }
    .joined(separator: ", ")
  }

  private func placeAccessibilityLabel(_ place: MKMapItem) -> String {
    let name = place.name ?? place.placemark.title ?? "Place"
    let subtitle = placeSubtitle(place)
    return subtitle.isEmpty ? name : "\(name), \(subtitle)"
  }

  @MainActor
  private func save() async {
    guard let selectedCoordinate else { return }
    isSaving = true
    defer { isSaving = false }

    do {
      try await onSave(selectedCoordinate.latitude, selectedCoordinate.longitude)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
#endif

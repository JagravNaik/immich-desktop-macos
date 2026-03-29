#if canImport(SwiftUI)
import SwiftUI
import MapKit

struct AssetInfoPopover: View {
  let item: ContentViewModel.PhotoItem

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header Section
      headerSection
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)

      Divider()

      // Metadata Section (Camera Info)
      metadataSection
        .padding(16)

      Divider()

      // Map Section
      if let latitude = item.latitude, let longitude = item.longitude {
        mapSection(lat: latitude, lon: longitude)
      } else {
        noLocationSection
          .padding(16)
      }
    }
    .frame(width: 320)
    .background(.ultraThinMaterial)
  }

  private var headerSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Add a Title")
        .font(.subheadline)
        .italic()
        .foregroundStyle(.secondary)
      
      Text(item.id) // Using ID as temporary filename
        .font(.headline)
      
      HStack(spacing: 4) {
        Text(item.date, style: .date)
        Text(item.date, style: .time)
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
    }
  }

  private var metadataSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Image(systemName: "camera")
          .font(.title2)
          .foregroundStyle(.secondary)
          
        VStack(alignment: .leading, spacing: 2) {
          Text("Camera Metadata")
            .font(.subheadline.weight(.medium))
          Text("Immich-captured asset")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      
      // EXIF Grid (Simplified placeholders for now)
      HStack {
        exifItem(label: "ISO", value: "---")
        Spacer()
        exifItem(label: "FOCAL", value: "---")
        Spacer()
        exifItem(label: "EV", value: "0")
        Spacer()
        exifItem(label: "f/", value: "---")
        Spacer()
        exifItem(label: "SHUTTER", value: "---")
      }
    }
  }

  private func exifItem(label: String, value: String) -> some View {
    VStack(spacing: 2) {
      Text(label)
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(size: 11))
    }
  }

  private func mapSection(lat: Double, lon: Double) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text([item.city, item.country].compactMap { $0 }.joined(separator: ", "))
        .font(.caption.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.1))

      Map(initialPosition: .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
      ))) {
        Marker("", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
      }
      .frame(height: 180)
      .clipShape(RoundedRectangle(cornerRadius: 0))
    }
  }

  private var noLocationSection: some View {
    HStack {
      Image(systemName: "mappin.slash")
        .foregroundStyle(.secondary)
      Text("No Location Information")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.vertical, 20)
  }
}
#endif

#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI

/// Photos' Image ▸ Adjust Date and Time… (IPXAdjustAssetsDateTimeViewController): shows the
/// original date of the first selected item, an adjusted date, and a time zone. Every selected
/// item shifts by the same offset, which Immich applies with `dateTimeRelative`.
struct AdjustDateTimeSheet: View {
  @ObservedObject var appState: AppState
  @Environment(\.dismiss) private var dismiss

  @State private var adjustedDate: Date
  @State private var timeZoneIdentifier: String
  @State private var isSaving = false
  @State private var errorMessage: String?

  private let originalDate: Date
  private let originalTimeZoneIdentifier = TimeZone.current.identifier

  init(appState: AppState) {
    self.appState = appState
    let first = appState.adjustDateTimeItemIDs.lazy.compactMap(appState.photoItem(withID:)).first
    let date = first?.date ?? Date()
    originalDate = date
    _adjustedDate = State(initialValue: date)
    _timeZoneIdentifier = State(initialValue: TimeZone.current.identifier)
  }

  private var itemCount: Int { appState.adjustDateTimeItemIDs.count }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(itemCount > 1 ? "Adjust Date and Time of \(itemCount) Items" : "Adjust Date and Time")
        .font(.headline)

      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
        GridRow {
          Text("Original:").foregroundStyle(.secondary)
          Text(originalDate.formatted(date: .long, time: .standard))
        }
        GridRow {
          Text("Adjusted:").foregroundStyle(.secondary)
          DatePicker("Adjusted", selection: $adjustedDate, displayedComponents: [.date, .hourAndMinute])
            .labelsHidden()
        }
        GridRow {
          Text("Time Zone:").foregroundStyle(.secondary)
          Picker("Time Zone", selection: $timeZoneIdentifier) {
            ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { identifier in
              Text(identifier.replacingOccurrences(of: "_", with: " ")).tag(identifier)
            }
          }
          .labelsHidden()
          .frame(maxWidth: 280)
        }
      }

      if itemCount > 1 {
        Text("The selected items keep their spacing; each moves by the same amount.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let errorMessage {
        Text(errorMessage).font(.caption).foregroundStyle(.red)
      }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(isSaving ? "Adjusting…" : "Adjust") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(isSaving || !hasChanges)
      }
    }
    .padding(20)
    .frame(width: 460)
  }

  private var offsetMinutes: Int {
    Int((adjustedDate.timeIntervalSince(originalDate) / 60).rounded())
  }

  private var hasChanges: Bool {
    offsetMinutes != 0 || timeZoneIdentifier != originalTimeZoneIdentifier
  }

  private func save() {
    isSaving = true
    errorMessage = nil
    let timeZone = timeZoneIdentifier == originalTimeZoneIdentifier ? nil : TimeZone(identifier: timeZoneIdentifier)
    Task {
      defer { isSaving = false }
      do {
        try await appState.adjustDateTime(
          for: appState.adjustDateTimeItemIDs,
          offsetMinutes: offsetMinutes,
          timeZone: timeZone
        )
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}
#endif

#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import ImmichCore
import SwiftUI

// MARK: - Toolbar Search Field (Photos-style expand/collapse with search type)

struct ToolbarSearchField: View {
  @Binding var text: String
  @Binding var isPresented: Bool
  @Binding var searchType: SearchType
  @Binding var searchFilters: SearchFilters
  var onTextChange: ((String) -> Void)?
  var onFilterToggle: (() -> Void)?
  var onSuggestionsRequested: (() -> Void)?

  private let collapsedWidth: CGFloat = 36
  private let expandedWidth: CGFloat = 260

  var body: some View {
    ZStack(alignment: .trailing) {
      if isPresented {
        HStack(spacing: 0) {
          SearchTypePicker(selection: $searchType)
            .frame(width: 28, height: 24)

          SearchFieldWrapper(
            text: $text,
            onEscape: collapse,
            onTextChange: onTextChange,
            onSubmit: onTextChange.map { handler in
              { handler($0) }
            }
          )
          .frame(height: 24)

          if !searchFilters.isEmpty {
            Button {
              onFilterToggle?()
            } label: {
              Image(systemName: "line.3.horizontal.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.blue)
                .frame(width: 20, height: 24)
            }
            .buttonStyle(.plain)
            .help("Active filters")
          }
        }
        .frame(width: expandedWidth, height: 24)
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(.quaternary, lineWidth: 0.5)
        )
        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .trailing)))
      } else {
        Button {
          expand()
        } label: {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 13, weight: .medium))
            .frame(width: collapsedWidth, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Search (⌘F)")
        .accessibilityLabel("Search")
        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .trailing)))
      }
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.82), value: isPresented)
  }

  private func expand() {
    isPresented = true
  }

  private func collapse() {
    text = ""
    isPresented = false
  }
}

// MARK: - Search Type Picker

private struct SearchTypePicker: View {
  @Binding var selection: SearchType

  private var icon: String {
    switch selection {
    case .smart: "sparkles"
    case .filename: "doc.text"
    case .description: "text.bubble"
    case .ocr: "text.viewfinder"
    }
  }

  var body: some View {
    Menu {
      ForEach(SearchType.allCases) { type in
        Button {
          selection = type
        } label: {
          Label(type.rawValue, systemImage: Self.icon(for: type))
        }
        .buttonStyle(.borderless)
      }
    } label: {
      Image(systemName: icon)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .help("Search type: \(selection.rawValue)")
  }

  private static func icon(for type: SearchType) -> String {
    switch type {
    case .smart: "sparkles"
    case .filename: "doc.text"
    case .description: "text.bubble"
    case .ocr: "text.viewfinder"
    }
  }
}

// MARK: - NSSearchField Wrapper

private struct SearchFieldWrapper: NSViewRepresentable {
  @Binding var text: String
  var onEscape: () -> Void
  var onTextChange: ((String) -> Void)?
  var onSubmit: ((String) -> Void)?

  func makeNSView(context: Context) -> FocusableSearchField {
    let field = FocusableSearchField()
    field.placeholderString = "Search"
    field.bezelStyle = .roundedBezel
    field.focusRingType = .none
    field.delegate = context.coordinator
    field.onEscape = onEscape
    field.sendsSearchStringImmediately = true
    field.sendsWholeSearchString = false
    field.controlSize = .small
    field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    field.isBordered = false
    field.drawsBackground = false

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      field.window?.makeFirstResponder(field)
    }
    return field
  }

  func updateNSView(_ nsView: FocusableSearchField, context: Context) {
    if nsView.stringValue != text {
      nsView.stringValue = text
    }
    nsView.onEscape = onEscape
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, onTextChange: onTextChange)
  }

  class Coordinator: NSObject, NSSearchFieldDelegate {
    @Binding var text: String
    var onTextChange: ((String) -> Void)?

    init(text: Binding<String>, onTextChange: ((String) -> Void)?) {
      _text = text
      self.onTextChange = onTextChange
    }

    func controlTextDidChange(_ obj: Notification) {
      guard let field = obj.object as? NSSearchField else { return }
      text = field.stringValue
      onTextChange?(field.stringValue)
    }
  }
}

// MARK: - FocusableSearchField

final class FocusableSearchField: NSSearchField {
  var onEscape: (() -> Void)?

  override func cancelOperation(_ sender: Any?) {
    if !stringValue.isEmpty {
      stringValue = ""
      sendAction(action, to: target)
      return
    }
    onEscape?()
  }

  override var acceptsFirstResponder: Bool { true }

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result, let editor = currentEditor() {
      editor.selectAll(nil)
    }
    return result
  }
}

// MARK: - Search Suggestions Overlay

struct SearchSuggestionsOverlay: View {
  let recentSearches: [String]
  let onSelect: (String) -> Void
  let onClearAll: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Recent Searches")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Clear") {
          onClearAll()
        }
        .font(.caption)
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      Divider()

      ForEach(recentSearches, id: \.self) { query in
        Button {
          onSelect(query)
        } label: {
          HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
              .font(.system(size: 11))
              .foregroundStyle(.tertiary)
              .frame(width: 16)
            Text(query)
              .font(.callout)
              .lineLimit(1)
            Spacer()
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
      }
    }
    .frame(width: 260)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
  }
}
#endif

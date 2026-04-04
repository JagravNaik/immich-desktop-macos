#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SwiftUI

// MARK: - Toolbar Search Field (Photos-style expand/collapse)

struct ToolbarSearchField: View {
  @Binding var text: String
  @Binding var isPresented: Bool
  var onTextChange: ((String) -> Void)?

  private let collapsedWidth: CGFloat = 36
  private let expandedWidth: CGFloat = 220

  var body: some View {
    ZStack(alignment: .trailing) {
      if isPresented {
        SearchFieldWrapper(
          text: $text,
          onEscape: collapse,
          onTextChange: onTextChange
        )
        .frame(width: expandedWidth, height: 24)
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

// MARK: - NSSearchField Wrapper

private struct SearchFieldWrapper: NSViewRepresentable {
  @Binding var text: String
  var onEscape: () -> Void
  var onTextChange: ((String) -> Void)?

  func makeNSView(context: Context) -> FocusableSearchField {
    let field = FocusableSearchField()
    field.placeholderString = "Search"
    field.bezelStyle = .roundedBezel
    field.focusRingType = .exterior
    field.delegate = context.coordinator
    field.onEscape = onEscape
    field.sendsSearchStringImmediately = true
    field.sendsWholeSearchString = false
    field.controlSize = .small
    field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

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
#endif

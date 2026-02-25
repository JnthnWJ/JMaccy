import Sauce
import Defaults
import SwiftUI

struct KeyHandlingView<Content: View>: View {
  @Binding var searchQuery: String
  @FocusState.Binding var searchFocused: Bool
  @Binding var shelfSearchExpanded: Bool
  @ViewBuilder let content: () -> Content

  @Environment(AppState.self) private var appState
  @State private var keyEventMonitor: Any?

  var body: some View {
    content()
      .onAppear {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
          self.handleKeyDown(event) ? nil : event
        }
      }
      .onDisappear {
        if let keyEventMonitor {
          NSEvent.removeMonitor(keyEventMonitor)
          self.keyEventMonitor = nil
        }
      }
  }

  @MainActor
  private func handleKeyDown(_ event: NSEvent) -> Bool {
    let keyChord = KeyChord(event)
    let shelfMode = appState.shelfModeEnabled
    let searchInputActive = shelfMode && (NSApp.keyWindow?.firstResponder is NSTextView)

    // Ignore input when candidate window is open
    // https://stackoverflow.com/questions/73677444/how-to-detect-the-candidate-window-when-using-japanese-keyboard
    if searchFocused,
       let inputClient = NSApp.keyWindow?.firstResponder as? NSTextInputClient,
       inputClient.hasMarkedText() {
      return false
    }

    switch keyChord {
    case .clearHistory:
      if let item = appState.footer.items.first(where: { $0.title == "clear" }),
         item.confirmation != nil,
         let suppressConfirmation = item.suppressConfirmation {
        if suppressConfirmation.wrappedValue {
          item.action()
        } else {
          item.showConfirmation = true
        }
        return true
      } else {
        return false
      }
    case .clearHistoryAll:
      if let item = appState.footer.items.first(where: { $0.title == "clear_all" }),
         item.confirmation != nil,
         let suppressConfirmation = item.suppressConfirmation {
        if suppressConfirmation.wrappedValue {
          item.action()
        } else {
          item.showConfirmation = true
        }
        return true
      } else {
        return false
      }
    case .clearSearch:
      searchQuery = ""
      if shelfMode {
        shelfSearchExpanded = false
        searchFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
      }
      return true
    case .deleteCurrentItem:
      if appState.navigator.pasteStackSelected {
        appState.removePasteStack()
      } else {
        appState.deleteSelection()
      }
      return true
    case .deleteOneCharFromSearch:
      if shelfMode {
        shelfSearchExpanded = true
      }
      searchFocused = true
      _ = searchQuery.popLast()
      return true
    case .deleteLastWordFromSearch:
      if shelfMode {
        shelfSearchExpanded = true
      }
      searchFocused = true
      let newQuery = searchQuery.split(separator: " ").dropLast().joined(separator: " ")
      if newQuery.isEmpty {
        searchQuery = ""
      } else {
        searchQuery = "\(newQuery) "
      }

      return true
    case .moveToNext:
      guard !shelfMode else {
        return false
      }
      guard NSApp.characterPickerWindow == nil else {
        return false
      }

      appState.navigator.highlightNext()
      return true
    case .moveToLast:
      guard !shelfMode else {
        return false
      }
      guard NSApp.characterPickerWindow == nil else {
        return false
      }

      appState.navigator.highlightLast()
      return true
    case .moveToPrevious:
      guard !shelfMode else {
        return false
      }
      guard NSApp.characterPickerWindow == nil else {
        return false
      }

      appState.navigator.highlightPrevious()
      return true
    case .moveToFirst:
      guard !shelfMode else {
        return false
      }
      guard NSApp.characterPickerWindow == nil else {
        return false
      }

      appState.navigator.highlightFirst()
      return true
    case .extendToNext:
      guard !shelfMode else {
        return false
      }
      guard NSApp.characterPickerWindow == nil else {
        return false
      }
      guard AppState.shared.multiSelectionEnabled else {
        return false
      }
      appState.navigator.extendHighlightToNext()
      return true
    case .extendToLast:
      guard !shelfMode else {
        return false
      }
      guard NSApp.characterPickerWindow == nil else {
        return false
      }
      guard AppState.shared.multiSelectionEnabled else {
        return false
      }
      appState.navigator.extendHighlightToLast()
      return true
    case .extendToPrevious:
      guard !shelfMode else {
        return false
      }
      guard NSApp.characterPickerWindow == nil else {
        return false
      }
      guard AppState.shared.multiSelectionEnabled else {
        return false
      }
      appState.navigator.extendHighlightToPrevious()
      return true
    case .extendToFirst:
      guard !shelfMode else {
        return false
      }
      guard NSApp.characterPickerWindow == nil else {
        return false
      }
      guard AppState.shared.multiSelectionEnabled else {
        return false
      }
      appState.navigator.extendHighlightToFirst()
      return true
    case .openPreferences:
      appState.openPreferences()
      return true
    case .focusSearch:
      if shelfMode {
        shelfSearchExpanded = true
        DispatchQueue.main.async {
          searchFocused = true
        }
      } else {
        searchFocused = true
      }
      return true
    case .pinOrUnpin:
      appState.togglePin()
      return true
    case .selectCurrentItem:
      appState.select()
      return true
    case .moveToLeft:
      guard shelfMode else {
        return false
      }
      appState.navigator.highlightShelfPrevious()
      return true
    case .moveToRight:
      guard shelfMode else {
        return false
      }
      appState.navigator.highlightShelfNext()
      return true
    case .toggleShelfPreview:
      guard shelfMode, !searchInputActive else {
        return false
      }
      appState.shelfPreview.toggle()
      appState.popup.needsResize = true
      return true
    case .close:
      if shelfMode, appState.shelfPreview.isOpen {
        appState.shelfPreview.close()
        appState.popup.needsResize = true
        return true
      }
      appState.popup.close()
      return true
    case .togglePreview:
      guard !shelfMode else {
        return false
      }
      appState.preview.togglePreview()
      return true
    default:
      ()
    }

    if let item = appState.history.pressedShortcutItem {
      appState.navigator.select(item: item)
      Task {
        try? await Task.sleep(for: .milliseconds(50))
        appState.history.select(item)
      }
      return true
    }

    return false
  }
}

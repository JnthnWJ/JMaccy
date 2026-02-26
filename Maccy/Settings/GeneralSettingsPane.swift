import AppKit
import Carbon.HIToolbox
import SwiftUI
import Defaults
import KeyboardShortcuts
import LaunchAtLogin
import Settings

struct GeneralSettingsPane: View {
  private let notificationsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.notifications?id=\(Bundle.main.bundleIdentifier ?? "")"
  )

  @Default(.searchMode) private var searchMode

  @State private var copyModifier = HistoryItemAction.copy.modifierFlags.description
  @State private var pasteModifier = HistoryItemAction.paste.modifierFlags.description
  @State private var pasteWithoutFormatting = HistoryItemAction.pasteWithoutFormatting.modifierFlags.description

  @State private var updater = SoftwareUpdater()

  var body: some View {
    Settings.Container(contentWidth: 450) {
      Settings.Section(title: "", bottomDivider: true) {
        LaunchAtLogin.Toggle {
          Text("LaunchAtLogin", tableName: "GeneralSettings")
        }
        Toggle(isOn: $updater.automaticallyChecksForUpdates) {
          Text("CheckForUpdates", tableName: "GeneralSettings")
        }
        Button(
          action: { updater.checkForUpdates() },
          label: { Text("CheckNow", tableName: "GeneralSettings") }
        )
      }

      Settings.Section(label: { Text("Open", tableName: "GeneralSettings") }) {
        KeyboardShortcuts.Recorder(for: .popup, onChange: { newShortcut in
          if newShortcut == nil {
            // No shortcut is recorded. Remove keys monitor
            AppState.shared.popup.deinitEventsMonitor()
          } else {
            // User is using shortcut. Ensure keys monitor is initialized
            AppState.shared.popup.initEventsMonitor()
          }
        })
          .help(Text("OpenTooltip", tableName: "GeneralSettings"))
      }

      Settings.Section(label: { Text("Pin", tableName: "GeneralSettings") }) {
        KeyboardShortcuts.Recorder(for: .pin)
          .help(Text("PinTooltip", tableName: "GeneralSettings"))
      }
      Settings.Section(label: { Text("Delete", tableName: "GeneralSettings") }
      ) {
        SingleKeyShortcutRecorder(for: .delete)
          .help(Text("DeleteTooltip", tableName: "GeneralSettings"))
      }
      Settings.Section(
        bottomDivider: true,
        label: { Text("ShowPreview", tableName: "GeneralSettings") }
      ) {
        SingleKeyShortcutRecorder(for: .togglePreview)
          .help(Text("ShowPreviewTooltip", tableName: "GeneralSettings"))
      }

      Settings.Section(
        bottomDivider: true,
        label: { Text("Search", tableName: "GeneralSettings") }
      ) {
        Picker("", selection: $searchMode) {
          ForEach(Search.Mode.allCases) { mode in
            Text(mode.description)
          }
        }
        .labelsHidden()
        .frame(width: 180, alignment: .leading)
      }

      Settings.Section(
        bottomDivider: true,
        label: { Text("Behavior", tableName: "GeneralSettings") }
      ) {
        Defaults.Toggle(key: .pasteByDefault) {
          Text("PasteAutomatically", tableName: "GeneralSettings")
        }
        .onChange(refreshModifiers)
        .fixedSize()

        Defaults.Toggle(key: .removeFormattingByDefault) {
          Text("PasteWithoutFormatting", tableName: "GeneralSettings")
        }
        .onChange(refreshModifiers)
        .fixedSize()

        Text(String(
          format: NSLocalizedString("Modifiers", tableName: "GeneralSettings", comment: ""),
          copyModifier, pasteModifier, pasteWithoutFormatting
        ))
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.gray)
        .controlSize(.small)
      }

      Settings.Section(title: "") {
        if let notificationsURL = notificationsURL {
          Link(destination: notificationsURL, label: {
            Text("NotificationsAndSounds", tableName: "GeneralSettings")
          })
        }
      }
    }
  }

  private func refreshModifiers(_ sender: Sendable) {
    copyModifier = HistoryItemAction.copy.modifierFlags.description
    pasteModifier = HistoryItemAction.paste.modifierFlags.description
    pasteWithoutFormatting = HistoryItemAction.pasteWithoutFormatting.modifierFlags.description
  }
}

private struct SingleKeyShortcutRecorder: NSViewRepresentable {
  let name: KeyboardShortcuts.Name
  let onChange: ((KeyboardShortcuts.Shortcut?) -> Void)?

  init(
    for name: KeyboardShortcuts.Name,
    onChange: ((KeyboardShortcuts.Shortcut?) -> Void)? = nil
  ) {
    self.name = name
    self.onChange = onChange
  }

  func makeNSView(context: Context) -> SingleKeyShortcutRecorderField {
    SingleKeyShortcutRecorderField(for: name, onChange: onChange)
  }

  func updateNSView(_ nsView: SingleKeyShortcutRecorderField, context: Context) {
    nsView.shortcutName = name
    nsView.onChange = onChange
  }
}

private final class SingleKeyShortcutRecorderField: NSSearchField, NSSearchFieldDelegate {
  private static let shortcutDidChange = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")
  private let minimumWidth: CGFloat = 130
  private var canBecomeKey = false
  private var eventMonitor: Any?
  private var shortcutChangeObserver: NSObjectProtocol?
  private var windowDidResignKeyObserver: NSObjectProtocol?
  private var windowDidBecomeKeyObserver: NSObjectProtocol?
  private var cancelButton: NSButtonCell?

  var shortcutName: KeyboardShortcuts.Name {
    didSet {
      guard shortcutName != oldValue else { return }
      setStringValue(name: shortcutName)
    }
  }

  var onChange: ((KeyboardShortcuts.Shortcut?) -> Void)?

  override var canBecomeKeyView: Bool { canBecomeKey }

  override var intrinsicContentSize: NSSize {
    var size = super.intrinsicContentSize
    size.width = minimumWidth
    return size
  }

  private var showsCancelButton: Bool {
    get { (cell as? NSSearchFieldCell)?.cancelButtonCell != nil }
    set {
      (cell as? NSSearchFieldCell)?.cancelButtonCell = newValue ? cancelButton : nil
    }
  }

  init(
    for name: KeyboardShortcuts.Name,
    onChange: ((KeyboardShortcuts.Shortcut?) -> Void)? = nil
  ) {
    self.shortcutName = name
    self.onChange = onChange

    super.init(frame: .zero)
    delegate = self
    placeholderString = "Record Shortcut"
    alignment = .center
    (cell as? NSSearchFieldCell)?.searchButtonCell = nil
    setContentHuggingPriority(.defaultHigh, for: .horizontal)
    setContentHuggingPriority(.defaultHigh, for: .vertical)

    cancelButton = (cell as? NSSearchFieldCell)?.cancelButtonCell
    setStringValue(name: name)
    setUpEvents()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    stopMonitoring()
    if let shortcutChangeObserver {
      NotificationCenter.default.removeObserver(shortcutChangeObserver)
    }
    if let windowDidResignKeyObserver {
      NotificationCenter.default.removeObserver(windowDidResignKeyObserver)
    }
    if let windowDidBecomeKeyObserver {
      NotificationCenter.default.removeObserver(windowDidBecomeKeyObserver)
    }
  }

  override func viewDidMoveToWindow() {
    guard let window else {
      removeWindowObservers()
      windowDidResignKeyObserver = nil
      windowDidBecomeKeyObserver = nil
      endRecording()
      return
    }

    removeWindowObservers()
    windowDidResignKeyObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification,
      object: window,
      queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      endRecording()
      window.makeFirstResponder(nil)
    }

    windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification,
      object: window,
      queue: nil
    ) { [weak self] _ in
      self?.preventBecomingKey()
    }

    preventBecomingKey()
  }

  override func becomeFirstResponder() -> Bool {
    let shouldBecomeFirstResponder = super.becomeFirstResponder()
    guard shouldBecomeFirstResponder else {
      return false
    }

    placeholderString = "Press Shortcut"
    showsCancelButton = !stringValue.isEmpty
    hideCaret()
    startMonitoring()

    return true
  }

  func controlTextDidChange(_ object: Notification) {
    if stringValue.isEmpty {
      saveShortcut(nil)
    }

    showsCancelButton = !stringValue.isEmpty

    if stringValue.isEmpty {
      focus()
    }
  }

  func controlTextDidEndEditing(_ object: Notification) {
    endRecording()
  }

  private func setUpEvents() {
    shortcutChangeObserver = NotificationCenter.default.addObserver(
      forName: Self.shortcutDidChange,
      object: nil,
      queue: nil
    ) { [weak self] notification in
      guard
        let self,
        let nameInNotification = notification.userInfo?["name"] as? KeyboardShortcuts.Name,
        nameInNotification == self.shortcutName
      else {
        return
      }

      self.setStringValue(name: self.shortcutName)
    }
  }

  private func setStringValue(name: KeyboardShortcuts.Name) {
    stringValue = KeyboardShortcuts.Shortcut(name: name).map { "\($0)" } ?? ""
    showsCancelButton = !stringValue.isEmpty
  }

  private func saveShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) {
    KeyboardShortcuts.setShortcut(shortcut, for: shortcutName)
    onChange?(shortcut)
  }

  private func startMonitoring() {
    guard eventMonitor == nil else { return }
    eventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown, .leftMouseUp, .rightMouseUp]
    ) { [weak self] event in
      guard let self else {
        return event
      }

      let clickPoint = convert(event.locationInWindow, from: nil)
      let clickMargin = 3.0

      if (event.type == .leftMouseUp || event.type == .rightMouseUp),
         !bounds.insetBy(dx: -clickMargin, dy: -clickMargin).contains(clickPoint) {
        blur()
        return event
      }

      guard event.type == .keyDown else {
        return nil
      }

      if event.modifiers.isEmpty, event.keyCode == UInt16(kVK_Tab) {
        blur()
        return event
      }

      if event.modifiers.isEmpty, event.keyCode == UInt16(kVK_Escape) {
        blur()
        return nil
      }

      guard let shortcut = KeyboardShortcuts.Shortcut(event: event) else {
        NSSound.beep()
        return nil
      }

      stringValue = "\(shortcut)"
      showsCancelButton = true

      saveShortcut(shortcut)
      blur()

      return nil
    }
  }

  private func stopMonitoring() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
  }

  private func endRecording() {
    stopMonitoring()
    placeholderString = "Record Shortcut"
    showsCancelButton = !stringValue.isEmpty
    restoreCaret()
  }

  private func preventBecomingKey() {
    canBecomeKey = false

    DispatchQueue.main.async { [self] in
      canBecomeKey = true
    }
  }

  private func removeWindowObservers() {
    if let windowDidResignKeyObserver {
      NotificationCenter.default.removeObserver(windowDidResignKeyObserver)
    }
    if let windowDidBecomeKeyObserver {
      NotificationCenter.default.removeObserver(windowDidBecomeKeyObserver)
    }
  }
}

private extension NSEvent {
  var modifiers: ModifierFlags {
    modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function])
  }
}

private extension NSTextField {
  func hideCaret() {
    (currentEditor() as? NSTextView)?.insertionPointColor = .clear
  }

  func restoreCaret() {
    (currentEditor() as? NSTextView)?.insertionPointColor = .labelColor
  }
}

private extension NSView {
  func focus() {
    window?.makeFirstResponder(self)
  }

  func blur() {
    window?.makeFirstResponder(nil)
  }
}

#Preview {
  GeneralSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}

import AppKit
import Defaults
import Foundation
import Settings
import SwiftUI
import UniformTypeIdentifiers

private final class ShelfAuxiliaryPanel: NSPanel {
  private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
  private let onClose: () -> Void

  init(contentRect: NSRect, identifier: String, onClose: @escaping () -> Void) {
    self.onClose = onClose

    super.init(
      contentRect: contentRect,
      styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )

    self.identifier = NSUserInterfaceItemIdentifier(identifier)
    animationBehavior = .none
    isFloatingPanel = true
    level = .statusBar
    collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    titlebarSeparatorStyle = .none
    isMovable = false
    isMovableByWindowBackground = false
    hasShadow = true
    hidesOnDeactivate = false
    isOpaque = false
    backgroundColor = .clear

    contentView = hostingView
  }

  func updateRootView(_ view: AnyView) {
    hostingView.rootView = view
  }

  override var canBecomeKey: Bool {
    true
  }

  override var canBecomeMain: Bool {
    false
  }

  override func close() {
    super.close()
    onClose()
  }
}

private final class ShelfImageEditSession {
  let itemID: UUID
  let fileURL: URL
  private(set) var lastDataHash: Int

  private let fileDescriptor: CInt
  private var source: DispatchSourceFileSystemObject?

  init?(itemID: UUID, fileURL: URL, initialData: Data, onChange: @escaping () -> Void) {
    self.itemID = itemID
    self.fileURL = fileURL
    lastDataHash = initialData.hashValue

    let fd = Darwin.open(fileURL.path, O_EVTONLY)
    guard fd != -1 else {
      return nil
    }

    fileDescriptor = fd

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .extend, .attrib, .rename],
      queue: .main
    )
    source.setEventHandler(handler: onChange)
    source.setCancelHandler {
      Darwin.close(fd)
    }
    source.resume()

    self.source = source
  }

  deinit {
    source?.cancel()
    source = nil
  }

  func setLastDataHash(_ hash: Int) {
    lastDataHash = hash
  }

  func stop() {
    source?.cancel()
    source = nil
  }
}

@Observable
class ShelfPreview {
  var isOpen = false
  var isTextEditorOpen = false
  var pointerX: CGFloat = 0
  var editingText = ""

  @ObservationIgnored private var cardFrames: [UUID: NSRect] = [:]
  @ObservationIgnored private var currentItemID: UUID?
  @ObservationIgnored private var editingItemID: UUID?

  @ObservationIgnored private var previewPanel: ShelfAuxiliaryPanel?
  @ObservationIgnored private var textEditorPanel: ShelfAuxiliaryPanel?

  @ObservationIgnored private var imageEditSession: ShelfImageEditSession?
  @ObservationIgnored private var imageImportTask: Task<Void, Never>?

  var canShareSelection: Bool {
    guard let item = AppState.shared.navigator.leadHistoryItem else {
      return false
    }

    return !shareItems(for: item).isEmpty
  }

  var canEditSelection: Bool {
    guard let item = AppState.shared.navigator.leadHistoryItem else {
      return false
    }

    switch item.shelfCardType {
    case .image, .text, .link, .richText:
      return true
    case .file:
      return false
    }
  }

  func updateCardFrame(itemID: UUID, frame: NSRect) {
    if let current = cardFrames[itemID],
       abs(current.origin.x - frame.origin.x) < 0.25,
       abs(current.origin.y - frame.origin.y) < 0.25,
       abs(current.size.width - frame.size.width) < 0.25,
       abs(current.size.height - frame.size.height) < 0.25 {
      return
    }

    cardFrames[itemID] = frame

    guard isOpen, currentItemID == itemID else {
      return
    }

    refreshPreviewPanel(animated: true)
  }

  func removeCardFrame(itemID: UUID) {
    cardFrames.removeValue(forKey: itemID)

    guard isOpen, currentItemID == itemID else {
      return
    }

    refreshPreviewPanel(animated: true)
  }

  func updateLeadSelection() {
    let newSelection = AppState.shared.navigator.leadHistoryItem?.id
    guard currentItemID != newSelection else {
      if isOpen {
        refreshPreviewPanel(animated: true)
      }
      return
    }

    currentItemID = newSelection

    if currentItemID == nil {
      close()
      closeEditor()
      return
    }

    if isOpen {
      refreshPreviewPanel(animated: true)
    }

    if isTextEditorOpen, editingItemID != currentItemID {
      closeEditor()
    }
  }

  func open() {
    guard AppState.shared.shelfModeEnabled else {
      return
    }

    guard AppState.shared.navigator.leadHistoryItem != nil else {
      return
    }

    currentItemID = AppState.shared.navigator.leadHistoryItem?.id
    isOpen = true
    refreshPreviewPanel(animated: false)
  }

  func close() {
    guard isOpen else {
      return
    }

    isOpen = false

    guard let panel = previewPanel, panel.isVisible else {
      return
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      panel.animator().alphaValue = 0
    } completionHandler: {
      panel.orderOut(nil)
      panel.alphaValue = 1
    }
  }

  func closeEditor() {
    guard isTextEditorOpen else {
      return
    }

    isTextEditorOpen = false
    editingItemID = nil

    guard let panel = textEditorPanel, panel.isVisible else {
      return
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.1
      panel.animator().alphaValue = 0
    } completionHandler: {
      panel.orderOut(nil)
      panel.alphaValue = 1
    }
  }

  @discardableResult
  func closeEditorIfOpen() -> Bool {
    guard isTextEditorOpen else {
      return false
    }

    closeEditor()
    return true
  }

  @discardableResult
  func closePreviewIfOpen() -> Bool {
    guard isOpen else {
      return false
    }

    close()
    return true
  }

  func closeAll() {
    closeEditor()
    close()
    imageEditSession?.stop()
    imageEditSession = nil
    imageImportTask?.cancel()
    imageImportTask = nil
  }

  func toggle() {
    if isOpen {
      close()
    } else {
      open()
    }
  }

  func shareSelection() {
    guard let item = AppState.shared.navigator.leadHistoryItem else {
      return
    }

    let items = shareItems(for: item)
    guard !items.isEmpty,
          let panel = previewPanel,
          let contentView = panel.contentView else {
      return
    }

    let picker = NSSharingServicePicker(items: items)
    let anchorRect = NSRect(x: contentView.bounds.maxX - 54, y: contentView.bounds.maxY - 30, width: 1, height: 1)
    picker.show(relativeTo: anchorRect, of: contentView, preferredEdge: .minY)
  }

  func editSelection() {
    guard let item = AppState.shared.navigator.leadHistoryItem else {
      return
    }

    switch item.shelfCardType {
    case .image:
      startImageEditing(item)
    case .text, .link, .richText:
      openTextEditor(for: item)
    case .file:
      break
    }
  }

  func updateEditingText(_ value: String) {
    editingText = value
  }

  @MainActor
  func saveTextEditor() {
    guard let editingItemID else {
      closeEditor()
      return
    }

    AppState.shared.history.updateTextContent(for: editingItemID, newValue: editingText)
    closeEditor()
    refreshPreviewPanel(animated: false)
  }

  func promptForImageEditor() {
    _ = chooseImageEditor()
  }

  func clearImageEditor() {
    Defaults[.shelfPreviewImageEditorBundleID] = nil
  }

  private func shareItems(for item: HistoryItemDecorator) -> [Any] {
    if item.hasImage {
      if let image = item.item.image {
        return [image]
      }
      return []
    }

    if !item.item.fileURLs.isEmpty {
      return item.item.fileURLs
    }

    let text = item.item.previewableText
    if text.isEmpty {
      return []
    }
    return [text]
  }

  private func openTextEditor(for item: HistoryItemDecorator) {
    editingItemID = item.id
    editingText = item.item.previewableText
    isTextEditorOpen = true

    let panel = ensureTextEditorPanel()
    panel.updateRootView(makeTextEditorView())

    let finalFrame = textEditorFrame()
    let startFrame = scaledFrame(from: finalFrame, scale: 0.96, yOffset: -8)

    panel.setFrame(startFrame, display: false)
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    panel.makeKey()

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.14
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      panel.animator().setFrame(finalFrame, display: true)
      panel.animator().alphaValue = 1
    }
  }

  private func startImageEditing(_ item: HistoryItemDecorator) {
    guard let editorURL = resolveImageEditorURL(promptIfMissing: true) else {
      return
    }

    guard let imageData = item.item.imageData else {
      return
    }

    let tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("maccy-shelf-preview-edits", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

    let fileURL = tempDirectory.appendingPathComponent("\(item.id.uuidString).png")
    do {
      try imageData.write(to: fileURL, options: [.atomic])
    } catch {
      return
    }

    startImageEditSession(itemID: item.id, fileURL: fileURL, initialData: imageData)

    NSWorkspace.shared.open(
      [fileURL],
      withApplicationAt: editorURL,
      configuration: NSWorkspace.OpenConfiguration(),
      completionHandler: nil
    )
  }

  private func startImageEditSession(itemID: UUID, fileURL: URL, initialData: Data) {
    imageImportTask?.cancel()
    imageImportTask = nil

    imageEditSession?.stop()
    imageEditSession = nil

    imageEditSession = ShelfImageEditSession(itemID: itemID, fileURL: fileURL, initialData: initialData) { [weak self] in
      guard let self else { return }
      scheduleEditedImageImport()
    }
  }

  private func scheduleEditedImageImport() {
    imageImportTask?.cancel()
    imageImportTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(220))
      guard !Task.isCancelled, let self else { return }
      importEditedImageIfNeeded()
    }
  }

  @MainActor
  private func importEditedImageIfNeeded() {
    guard let session = imageEditSession else {
      return
    }

    guard let data = try? Data(contentsOf: session.fileURL), !data.isEmpty else {
      return
    }

    let hash = data.hashValue
    guard hash != session.lastDataHash else {
      return
    }

    session.setLastDataHash(hash)
    let type = pasteboardType(for: session.fileURL)

    AppState.shared.history.replaceImageContent(for: session.itemID, imageData: data, type: type)
    refreshPreviewPanel(animated: false)
  }

  private func pasteboardType(for url: URL) -> NSPasteboard.PasteboardType {
    switch url.pathExtension.lowercased() {
    case "png":
      return .png
    case "jpg", "jpeg":
      return .jpeg
    case "heic":
      return .heic
    case "tif", "tiff":
      return .tiff
    default:
      return .png
    }
  }

  private func resolveImageEditorURL(promptIfMissing: Bool) -> URL? {
    if let bundleID = Defaults[.shelfPreviewImageEditorBundleID],
       let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
      return url
    }

    Defaults[.shelfPreviewImageEditorBundleID] = nil

    guard promptIfMissing else {
      return nil
    }

    return chooseImageEditor()
  }

  @discardableResult
  private func chooseImageEditor() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.directoryURL = URL(fileURLWithPath: "/Applications")

    guard panel.runModal() == .OK,
          let url = panel.url,
          let bundle = Bundle(url: url),
          let bundleID = bundle.bundleIdentifier else {
      return nil
    }

    Defaults[.shelfPreviewImageEditorBundleID] = bundleID
    return url
  }

  private func refreshPreviewPanel(animated: Bool) {
    guard isOpen,
          let item = AppState.shared.navigator.leadHistoryItem else {
      return
    }

    currentItemID = item.id

    let panel = ensurePreviewPanel()
    panel.updateRootView(makePreviewView())

    let finalFrame = previewFrame(for: item)

    if panel.isVisible {
      if animated {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.11
          context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
          panel.animator().setFrame(finalFrame, display: true)
        }
      } else {
        panel.setFrame(finalFrame, display: true)
      }
      return
    }

    let startFrame = scaledFrame(from: finalFrame, scale: 0.97, yOffset: -10)
    panel.setFrame(startFrame, display: false)
    panel.alphaValue = 0
    panel.orderFrontRegardless()

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.14
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      panel.animator().setFrame(finalFrame, display: true)
      panel.animator().alphaValue = 1
    }
  }

  private func previewFrame(for item: HistoryItemDecorator) -> NSRect {
    let referenceScreen = AppState.shared.appDelegate?.panel.screen?.visibleFrame
      ?? NSScreen.forPopup?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

    var size = preferredPreviewSize(for: item, screenFrame: referenceScreen)
    size.width = min(size.width, referenceScreen.width - 24)
    size.height = min(size.height, referenceScreen.height - 24)

    let anchorRect = anchorRect(in: referenceScreen)
    var originX = anchorRect.midX - size.width / 2
    originX = max(referenceScreen.minX + 12, min(originX, referenceScreen.maxX - size.width - 12))

    var originY = anchorRect.maxY + 18
    originY = min(originY, referenceScreen.maxY - size.height - 12)
    originY = max(originY, referenceScreen.minY + 12)

    pointerX = max(28, min(size.width - 28, anchorRect.midX - originX))

    return NSRect(origin: NSPoint(x: originX, y: originY), size: size)
  }

  private func preferredPreviewSize(for item: HistoryItemDecorator, screenFrame: NSRect) -> NSSize {
    if item.hasImage {
      let width = min(max(760, screenFrame.width * 0.74), 1280)
      let height = min(max(460, screenFrame.height * 0.62), 920)
      return NSSize(width: width, height: height)
    }

    let width = min(max(620, screenFrame.width * 0.52), 980)
    let height = min(max(360, screenFrame.height * 0.45), 680)
    return NSSize(width: width, height: height)
  }

  private func textEditorFrame() -> NSRect {
    let screenFrame = AppState.shared.appDelegate?.panel.screen?.visibleFrame
      ?? NSScreen.forPopup?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

    let size = NSSize(
      width: min(max(560, screenFrame.width * 0.48), 920),
      height: min(max(320, screenFrame.height * 0.42), 620)
    )

    let referenceFrame = previewPanel?.frame ?? AppState.shared.appDelegate?.panel.frame ?? screenFrame

    var originX = referenceFrame.midX - size.width / 2
    originX = max(screenFrame.minX + 12, min(originX, screenFrame.maxX - size.width - 12))

    var originY = referenceFrame.maxY + 12
    if originY + size.height > screenFrame.maxY - 12 {
      originY = referenceFrame.minY - size.height - 12
    }
    if originY < screenFrame.minY + 12 {
      originY = screenFrame.midY - size.height / 2
    }

    return NSRect(x: originX, y: originY, width: size.width, height: size.height)
  }

  private func anchorRect(in screenFrame: NSRect) -> NSRect {
    if let currentItemID,
       let frame = cardFrames[currentItemID] {
      return frame
    }

    if let popupFrame = AppState.shared.appDelegate?.panel.frame {
      return NSRect(
        x: popupFrame.midX - 1,
        y: popupFrame.maxY - 1,
        width: 2,
        height: 2
      )
    }

    return NSRect(
      x: screenFrame.midX - 1,
      y: screenFrame.minY + 1,
      width: 2,
      height: 2
    )
  }

  private func scaledFrame(from frame: NSRect, scale: CGFloat, yOffset: CGFloat) -> NSRect {
    let width = frame.width * scale
    let height = frame.height * scale
    let x = frame.midX - width / 2
    let y = frame.midY - height / 2 + yOffset
    return NSRect(x: x, y: y, width: width, height: height)
  }

  private func ensurePreviewPanel() -> ShelfAuxiliaryPanel {
    if let panel = previewPanel {
      return panel
    }

    let panel = ShelfAuxiliaryPanel(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
      identifier: "org.p0deje.Maccy.shelfPreview",
      onClose: { [weak self] in
        self?.isOpen = false
      }
    )
    panel.updateRootView(makePreviewView())
    panel.contentView?.setAccessibilityIdentifier("shelf-preview-popup")
    previewPanel = panel

    return panel
  }

  private func ensureTextEditorPanel() -> ShelfAuxiliaryPanel {
    if let panel = textEditorPanel {
      return panel
    }

    let panel = ShelfAuxiliaryPanel(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
      identifier: "org.p0deje.Maccy.shelfTextEditor",
      onClose: { [weak self] in
        self?.isTextEditorOpen = false
        self?.editingItemID = nil
      }
    )
    panel.isMovable = true
    panel.isMovableByWindowBackground = true
    panel.updateRootView(makeTextEditorView())
    panel.contentView?.setAccessibilityIdentifier("shelf-text-editor")
    textEditorPanel = panel

    return panel
  }

  private func makePreviewView() -> AnyView {
    AnyView(
      ShelfPreviewPopupView()
        .environment(AppState.shared)
    )
  }

  private func makeTextEditorView() -> AnyView {
    AnyView(
      ShelfTextEditorPopupView()
        .environment(AppState.shared)
    )
  }
}

@Observable
class AppState: Sendable {
  static let shared = AppState(history: History.shared, footer: Footer())

  let multiSelectionEnabled = false

  var appDelegate: AppDelegate?
  var popup: Popup
  var history: History
  var footer: Footer
  var navigator: NavigationManager
  var preview: SlideoutController
  var shelfPreview = ShelfPreview()

  var effectivePopupLayoutMode: PopupLayoutMode {
    if #available(macOS 26.0, *) {
      return Defaults[.popupLayoutMode]
    }
    return .list
  }

  var shelfModeEnabled: Bool {
    return effectivePopupLayoutMode == .shelf
  }

  var searchVisible: Bool {
    if !Defaults[.showSearch] { return false }
    switch Defaults[.searchVisibility] {
    case .always: return true
    case .duringSearch: return !history.searchQuery.isEmpty
    }
  }

  var menuIconText: String {
    var title = history.unpinnedItems.first?.text.shortened(to: 100)
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    title.unicodeScalars.removeAll(where: CharacterSet.newlines.contains)
    return title.shortened(to: 20)
  }

  private let about = About()
  private var settingsWindowController: SettingsWindowController?

  init(history: History, footer: Footer) {
    self.history = history
    self.footer = footer
    popup = Popup()
    navigator = NavigationManager(history: history, footer: footer)
    preview = SlideoutController(
      onContentResize: { contentWidth in
        Defaults[.windowSize].width = contentWidth
      },
      onSlideoutResize: { previewWidth in
        Defaults[.previewWidth] = previewWidth
      })
    preview.contentWidth = Defaults[.windowSize].width
    preview.slideoutWidth = Defaults[.previewWidth]
  }

  @MainActor
  func select() {
    if !navigator.selection.isEmpty {
      if navigator.isMultiSelectInProgress {
        navigator.isManualMultiSelect = false
        history.startPasteStack(selection: &navigator.selection)
      } else {
        history.select(navigator.selection.first)
      }
    } else if let item = footer.selectedItem {
      // TODO: Use item.suppressConfirmation, but it's not updated!
      if item.confirmation != nil, Defaults[.suppressClearAlert] == false {
        item.showConfirmation = true
      } else {
        item.action()
      }
    } else {
      Clipboard.shared.copy(history.searchQuery)
      history.searchQuery = ""
    }
  }

  @MainActor
  func togglePin() {
    withTransaction(Transaction()) {
      navigator.selection.forEach { _, item in
        history.togglePin(item)
      }
    }
  }

  @MainActor
  func removePasteStack() {
    history.interruptPasteStack()
    navigator.highlightFirst()
  }

  @MainActor
  func deleteSelection() {
    guard let leadItem = navigator.leadHistoryItem else { return }
    let nextUnselectedItem: HistoryItemDecorator?
    if shelfModeEnabled {
      nextUnselectedItem = history.items.item(after: leadItem) { $0.isVisible && !$0.isSelected }
        ?? history.items.item(before: leadItem) { $0.isVisible && !$0.isSelected }
    } else {
      nextUnselectedItem = history.visibleItems.nearest(to: leadItem) { !$0.isSelected }
    }

    withTransaction(Transaction()) {
      navigator.selection.forEach { _, item in
        history.delete(item)
      }
      navigator.select(item: nextUnselectedItem)
    }
  }

  func openAbout() {
    about.openAbout(nil)
  }

  @MainActor
  func openPreferences() { // swiftlint:disable:this function_body_length
    if settingsWindowController == nil {
      settingsWindowController = SettingsWindowController(
        panes: [
          Settings.Pane(
            identifier: Settings.PaneIdentifier.general,
            title: NSLocalizedString("Title", tableName: "GeneralSettings", comment: ""),
            toolbarIcon: NSImage.gearshape!
          ) {
            GeneralSettingsPane()
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.storage,
            title: NSLocalizedString("Title", tableName: "StorageSettings", comment: ""),
            toolbarIcon: NSImage.externaldrive!
          ) {
            StorageSettingsPane()
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.appearance,
            title: NSLocalizedString("Title", tableName: "AppearanceSettings", comment: ""),
            toolbarIcon: NSImage.paintpalette!
          ) {
            AppearanceSettingsPane()
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.pins,
            title: NSLocalizedString("Title", tableName: "PinsSettings", comment: ""),
            toolbarIcon: NSImage.pincircle!
          ) {
            PinsSettingsPane()
              .environment(self)
              .modelContainer(Storage.shared.container)
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.ignore,
            title: NSLocalizedString("Title", tableName: "IgnoreSettings", comment: ""),
            toolbarIcon: NSImage.nosign!
          ) {
            IgnoreSettingsPane()
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.advanced,
            title: NSLocalizedString("Title", tableName: "AdvancedSettings", comment: ""),
            toolbarIcon: NSImage.gearshape2!
          ) {
            AdvancedSettingsPane()
          }
        ]
      )
    }
    settingsWindowController?.show()
    settingsWindowController?.window?.orderFrontRegardless()
  }

  func quit() {
    NSApp.terminate(self)
  }
}

import AppKit
import Defaults
import Foundation
import Logging
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

struct ShelfPreviewPlacement {
  let frame: NSRect
  let pointerX: CGFloat
  let isValid: Bool
  let selectedCardIsFullyVisible: Bool

  static let invalid = ShelfPreviewPlacement(
    frame: .zero,
    pointerX: 0,
    isValid: false,
    selectedCardIsFullyVisible: false
  )
}

enum ShelfPreviewLayoutMetrics {
  static let screenMargin: CGFloat = 12
  static let pointerWidth: CGFloat = 42
  static let pointerHeight: CGFloat = 16
  static let pointerHorizontalInset: CGFloat = 10
  static let pointerVerticalOffset: CGFloat = -0.5
  static let pointerContainerHeight: CGFloat = 15
  static let pointerBorderGapInset: CGFloat = 4
  static let pointerBorderGapHeight: CGFloat = 2
  static let popupOuterPadding: CGFloat = 6
  static let pointerTouchGap: CGFloat = 0

  static var pointerCenterInset: CGFloat {
    pointerHorizontalInset + pointerWidth / 2
  }

  static var pointerTipOffsetFromWindowBottom: CGFloat {
    popupOuterPadding + pointerContainerHeight - (pointerHeight + pointerVerticalOffset)
  }
}

protocol ShelfPreviewAnchor: AnyObject {
  func currentFrameInScreen() -> NSRect?
}

private final class WeakShelfPreviewAnchorBox {
  private weak var base: AnyObject?

  var anchor: (any ShelfPreviewAnchor)? {
    base as? any ShelfPreviewAnchor
  }

  init(anchor: any ShelfPreviewAnchor) {
    base = anchor
  }
}

final class ShelfPreviewAnchorRegistry {
  private var anchors: [UUID: WeakShelfPreviewAnchorBox] = [:]

  func register(itemID: UUID, anchor: any ShelfPreviewAnchor) {
    pruneReleasedAnchors()
    anchors[itemID] = WeakShelfPreviewAnchorBox(anchor: anchor)
  }

  func unregister(itemID: UUID, anchor: any ShelfPreviewAnchor) {
    pruneReleasedAnchors()

    guard let currentAnchor = anchors[itemID]?.anchor else {
      anchors.removeValue(forKey: itemID)
      return
    }

    guard currentAnchor === anchor else {
      return
    }

    anchors.removeValue(forKey: itemID)
  }

  func currentFrame(for itemID: UUID) -> NSRect? {
    pruneReleasedAnchors()
    return anchors[itemID]?.anchor?.currentFrameInScreen()
  }

  func retainOnly(_ itemIDs: Set<UUID>) {
    pruneReleasedAnchors()

    let staleItemIDs = anchors.keys.filter { !itemIDs.contains($0) }
    for itemID in staleItemIDs {
      anchors.removeValue(forKey: itemID)
    }
  }

  func removeAll() {
    anchors.removeAll()
  }

  private func pruneReleasedAnchors() {
    let releasedItemIDs = anchors.compactMap { itemID, box in
      box.anchor == nil ? itemID : nil
    }

    for itemID in releasedItemIDs {
      anchors.removeValue(forKey: itemID)
    }
  }
}

@Observable
class ShelfPreview {
  var isOpen = false
  var isTextEditorOpen = false
  var pointerX: CGFloat = 0
  var editingText = ""

  @ObservationIgnored private var logger: Logger = {
    var logger = Logger(label: "org.p0deje.Maccy.shelfPreview.debug")
    logger.logLevel = .debug
    return logger
  }()
  @ObservationIgnored private let anchorRegistry = ShelfPreviewAnchorRegistry()
  @ObservationIgnored private weak var carouselClipView: NSClipView?
  @ObservationIgnored private var currentItemID: UUID?
  @ObservationIgnored private var editingItemID: UUID?

  @ObservationIgnored private var previewPanel: ShelfAuxiliaryPanel?
  @ObservationIgnored private var textEditorPanel: ShelfAuxiliaryPanel?

  @ObservationIgnored private var imageEditSession: ShelfImageEditSession?
  @ObservationIgnored private var imageImportTask: Task<Void, Never>?
  @ObservationIgnored private var pendingOpenTask: Task<Void, Never>?
  @ObservationIgnored private var pendingOpenRequestID: UUID?

  var canShareSelection: Bool {
    canShare(item: AppState.shared.navigator.leadHistoryItem)
  }

  var canEditSelection: Bool {
    canEdit(item: AppState.shared.navigator.leadHistoryItem)
  }

  func canShare(item: HistoryItemDecorator?) -> Bool {
    guard let item else {
      return false
    }

    return !shareItems(for: item).isEmpty
  }

  func canEdit(item: HistoryItemDecorator?) -> Bool {
    guard let item else {
      return false
    }

    switch item.shelfCardType {
    case .image, .text, .link, .richText:
      return true
    case .file:
      return false
    }
  }

  func registerCardAnchor(itemID: UUID, anchor: any ShelfPreviewAnchor) {
    anchorRegistry.register(itemID: itemID, anchor: anchor)
    logger.debug("registerCardAnchor item=\(itemID) selected=\(String(describing: currentItemID)) isOpen=\(isOpen)")
    guard isOpen, currentItemID == itemID else {
      return
    }

    refreshPreviewPanel(animated: false)
  }

  func unregisterCardAnchor(itemID: UUID, anchor: any ShelfPreviewAnchor) {
    anchorRegistry.unregister(itemID: itemID, anchor: anchor)
    logger.debug("unregisterCardAnchor item=\(itemID) selected=\(String(describing: currentItemID)) isOpen=\(isOpen)")
    guard isOpen, currentItemID == itemID else {
      return
    }

    refreshPreviewPanel(animated: false)
  }

  func cardAnchorDidChange(itemID: UUID) {
    guard isOpen, currentItemID == itemID else {
      return
    }

    logger.debug(
      "cardAnchorDidChange item=\(itemID) frame=\(Self.describeRect(currentCardFrame(for: itemID))) viewport=\(Self.describeRect(currentCarouselViewportFrame()))"
    )
    refreshPreviewPanel(animated: false)
  }

  func bindCarouselClipView(_ clipView: NSClipView?) {
    guard carouselClipView !== clipView else {
      return
    }

    carouselClipView = clipView
    logger.debug("bindCarouselClipView clipBound=\(clipView != nil)")
    guard isOpen else {
      return
    }

    refreshPreviewPanel(animated: false)
  }

  func carouselViewportDidChange() {
    guard isOpen else {
      return
    }

    logger.debug("carouselViewportDidChange viewport=\(Self.describeRect(currentCarouselViewportFrame()))")
    refreshPreviewPanel(animated: false)
  }

  func syncVisibleShelfItemIDs(_ itemIDs: Set<UUID>) {
    anchorRegistry.retainOnly(itemIDs)
    logger.debug(
      "syncVisibleShelfItemIDs visibleCount=\(itemIDs.count) selected=\(String(describing: currentItemID)) selectedStillVisible=\(currentItemID.map(itemIDs.contains) ?? false)"
    )

    guard isOpen else {
      return
    }

    refreshPreviewPanel(animated: false)
  }

  func currentCardFrame(for itemID: UUID) -> NSRect? {
    anchorRegistry.currentFrame(for: itemID)
  }

  func selectedCardIsFullyVisible() -> Bool {
    guard let frame = currentSelectedCardFrame() else {
      return false
    }

    return Self.isCardFullyVisible(frame: frame, in: currentCarouselViewportFrame())
  }

  func updateLeadSelection() {
    let newSelection = AppState.shared.navigator.leadHistoryItem?.id
    logger.debug("updateLeadSelection old=\(String(describing: currentItemID)) new=\(String(describing: newSelection)) isOpen=\(isOpen)")
    guard currentItemID != newSelection else {
      if isOpen {
        refreshPreviewPanel(animated: true)
      }
      return
    }

    cancelPendingOpen()
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
    logger.debug(
      "open requested shelfMode=\(AppState.shared.shelfModeEnabled) selected=\(String(describing: AppState.shared.navigator.leadHistoryItem?.id)) isOpen=\(isOpen)"
    )
    guard AppState.shared.shelfModeEnabled else {
      logger.debug("open aborted because shelf mode is disabled")
      return
    }

    guard let item = AppState.shared.navigator.leadHistoryItem else {
      logger.debug("open aborted because no lead history item is selected")
      return
    }

    cancelPendingOpen()
    currentItemID = item.id

    if renderPreviewPanel(for: item, animated: false) {
      isOpen = true
      logger.debug("open succeeded immediately item=\(item.id)")
      return
    }

    logger.debug("open requires retry item=\(item.id)")
    scheduleOpenRetry(for: item.id)
  }

  func close() {
    cancelPendingOpen()

    guard isOpen else {
      return
    }

    logger.debug("close preview panel selected=\(String(describing: currentItemID))")
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
    let hadPendingOpen = pendingOpenTask != nil
    cancelPendingOpen()

    guard isOpen else {
      return hadPendingOpen
    }

    close()
    return true
  }

  func closeAll() {
    cancelPendingOpen()
    closeEditor()
    close()
    imageEditSession?.stop()
    imageEditSession = nil
    imageImportTask?.cancel()
    imageImportTask = nil
    anchorRegistry.removeAll()
    carouselClipView = nil
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

    share(item: item)
  }

  func share(item: HistoryItemDecorator) {
    let items = shareItems(for: item)
    guard !items.isEmpty else {
      return
    }

    let previewContentView = (previewPanel?.isVisible == true) ? previewPanel?.contentView : nil
    guard let contentView = previewContentView
      ?? AppState.shared.appDelegate?.panel.contentView
      ?? NSApp.keyWindow?.contentView else {
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

    edit(item: item)
  }

  func edit(item: HistoryItemDecorator) {
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
      if isOpen {
        logger.debug("refreshPreviewPanel skipped because lead history item is nil")
      }
      return
    }

    guard renderPreviewPanel(for: item, animated: animated) else {
      logger.debug("refreshPreviewPanel failed render for item=\(item.id); closing")
      close()
      return
    }
  }

  @discardableResult
  private func renderPreviewPanel(for item: HistoryItemDecorator, animated: Bool) -> Bool {
    currentItemID = item.id

    guard let selectedCardFrame = currentCardFrame(for: item.id) else {
      logger.debug("renderPreviewPanel missing selected card frame item=\(item.id)")
      return false
    }

    let carouselViewportFrame = currentCarouselViewportFrame()
    guard Self.isCardFullyVisible(frame: selectedCardFrame, in: carouselViewportFrame) else {
      logger.debug(
        "renderPreviewPanel selected card not fully visible item=\(item.id) card=\(Self.describeRect(selectedCardFrame)) viewport=\(Self.describeRect(carouselViewportFrame))"
      )
      return false
    }

    let referenceScreen = AppState.shared.appDelegate?.panel.screen?.visibleFrame
      ?? NSScreen.forPopup?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let placement = Self.computePreviewPlacement(
      preferredSize: preferredPreviewSize(for: item, screenFrame: referenceScreen),
      minimumSize: minimumPreviewSize(for: item, screenFrame: referenceScreen),
      selectedCardFrame: selectedCardFrame,
      carouselViewportFrame: carouselViewportFrame,
      screenFrame: referenceScreen
    )

    guard placement.isValid else {
      logger.debug(
        "renderPreviewPanel invalid placement item=\(item.id) card=\(Self.describeRect(selectedCardFrame)) viewport=\(Self.describeRect(carouselViewportFrame)) screen=\(Self.describeRect(referenceScreen))"
      )
      return false
    }

    pointerX = placement.pointerX

    let panel = ensurePreviewPanel()
    panel.updateRootView(makePreviewView())

    let finalFrame = placement.frame

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
      logger.debug("renderPreviewPanel updated existing panel item=\(item.id) frame=\(Self.describeRect(finalFrame))")
      return true
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

    logger.debug("renderPreviewPanel opened panel item=\(item.id) frame=\(Self.describeRect(finalFrame))")
    return true
  }

  private func cancelPendingOpen() {
    if let pendingOpenRequestID {
      logger.debug("cancelPendingOpen requestID=\(pendingOpenRequestID)")
    }
    pendingOpenTask?.cancel()
    pendingOpenTask = nil
    pendingOpenRequestID = nil
  }

  private func scheduleOpenRetry(for itemID: UUID) {
    let requestID = UUID()
    pendingOpenRequestID = requestID
    logger.debug("scheduleOpenRetry requestID=\(requestID) item=\(itemID)")
    pendingOpenTask = Task { @MainActor [weak self] in
      for attempt in 1...20 {
        try? await Task.sleep(for: .milliseconds(16))
        guard !Task.isCancelled,
              let self,
              AppState.shared.shelfModeEnabled,
              let item = AppState.shared.navigator.leadHistoryItem,
              item.id == itemID,
              self.currentItemID == itemID else {
          self?.logger.debug("openRetry aborted requestID=\(requestID) attempt=\(attempt)")
          self?.clearPendingOpen(ifMatches: requestID)
          return
        }

        if self.renderPreviewPanel(for: item, animated: false) {
          self.isOpen = true
          self.logger.debug("openRetry succeeded requestID=\(requestID) attempt=\(attempt) item=\(itemID)")
          self.clearPendingOpen(ifMatches: requestID)
          return
        }

        self.logger.debug(
          "openRetry waiting requestID=\(requestID) attempt=\(attempt) item=\(itemID) frame=\(Self.describeRect(self.currentCardFrame(for: itemID))) viewport=\(Self.describeRect(self.currentCarouselViewportFrame()))"
        )
      }

      self?.logger.debug("openRetry exhausted requestID=\(requestID) item=\(itemID)")
      self?.clearPendingOpen(ifMatches: requestID)
    }
  }

  private func clearPendingOpen(ifMatches requestID: UUID) {
    guard pendingOpenRequestID == requestID else {
      return
    }

    logger.debug("clearPendingOpen requestID=\(requestID)")
    pendingOpenTask = nil
    pendingOpenRequestID = nil
  }

  private func currentSelectedCardFrame() -> NSRect? {
    guard let currentItemID else {
      return nil
    }

    return currentCardFrame(for: currentItemID)
  }

  private func currentCarouselViewportFrame() -> NSRect? {
    guard let carouselClipView,
          let window = carouselClipView.window else {
      return nil
    }

    let viewportInWindow = carouselClipView.convert(carouselClipView.bounds, to: nil)
    return window.convertToScreen(viewportInWindow)
  }

  private static func describeRect(_ rect: NSRect?) -> String {
    guard let rect else {
      return "nil"
    }

    let normalized = rect.standardized
    return "x=\(Int(normalized.minX.rounded())) y=\(Int(normalized.minY.rounded())) w=\(Int(normalized.width.rounded())) h=\(Int(normalized.height.rounded()))"
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

  private func minimumPreviewSize(for item: HistoryItemDecorator, screenFrame: NSRect) -> NSSize {
    if item.hasImage {
      let width = min(max(520, screenFrame.width * 0.40), 900)
      let height = min(max(240, screenFrame.height * 0.24), 560)
      return NSSize(width: width, height: height)
    }

    let width = min(max(420, screenFrame.width * 0.33), 780)
    let height = min(max(200, screenFrame.height * 0.22), 460)
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
    originX = max(
      screenFrame.minX + ShelfPreviewLayoutMetrics.screenMargin,
      min(originX, screenFrame.maxX - size.width - ShelfPreviewLayoutMetrics.screenMargin)
    )

    var originY = referenceFrame.maxY + ShelfPreviewLayoutMetrics.screenMargin
    if originY + size.height > screenFrame.maxY - ShelfPreviewLayoutMetrics.screenMargin {
      originY = referenceFrame.minY - size.height - ShelfPreviewLayoutMetrics.screenMargin
    }
    if originY < screenFrame.minY + ShelfPreviewLayoutMetrics.screenMargin {
      originY = screenFrame.midY - size.height / 2
    }

    return NSRect(x: originX, y: originY, width: size.width, height: size.height)
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

  static func computePreviewPlacement(
    preferredSize: NSSize,
    minimumSize: NSSize,
    selectedCardFrame: NSRect?,
    carouselViewportFrame: NSRect?,
    screenFrame: NSRect
  ) -> ShelfPreviewPlacement {
    guard let selectedCardFrame else {
      return .invalid
    }

    let cardFrame = selectedCardFrame.standardized
    let cardFullyVisible = isCardFullyVisible(frame: cardFrame, in: carouselViewportFrame)
    guard cardFullyVisible else {
      return ShelfPreviewPlacement(
        frame: .zero,
        pointerX: 0,
        isValid: false,
        selectedCardIsFullyVisible: false
      )
    }

    let horizontalMargin = ShelfPreviewLayoutMetrics.screenMargin
    let availableWidth = screenFrame.width - horizontalMargin * 2
    guard availableWidth > 0 else {
      return .invalid
    }

    let clampedMinimumWidth = min(max(1, minimumSize.width), availableWidth)
    let clampedPreferredWidth = min(max(clampedMinimumWidth, preferredSize.width), availableWidth)
    guard clampedPreferredWidth > 0 else {
      return .invalid
    }

    let originY = cardFrame.maxY - ShelfPreviewLayoutMetrics.pointerTouchGap - ShelfPreviewLayoutMetrics.pointerTipOffsetFromWindowBottom
    guard originY >= screenFrame.minY + horizontalMargin else {
      return .invalid
    }

    let availableHeight = (screenFrame.maxY - horizontalMargin) - originY
    let height = min(preferredSize.height, availableHeight)
    guard height > 0 else {
      return .invalid
    }

    var originX = cardFrame.midX - clampedPreferredWidth / 2
    originX = max(screenFrame.minX + horizontalMargin, min(originX, screenFrame.maxX - clampedPreferredWidth - horizontalMargin))

    let pointerInset = ShelfPreviewLayoutMetrics.pointerCenterInset
    guard clampedPreferredWidth > pointerInset * 2 else {
      return .invalid
    }

    let pointerX = max(pointerInset, min(clampedPreferredWidth - pointerInset, cardFrame.midX - originX))

    return ShelfPreviewPlacement(
      frame: NSRect(x: originX, y: originY, width: clampedPreferredWidth, height: height),
      pointerX: pointerX,
      isValid: true,
      selectedCardIsFullyVisible: true
    )
  }

  static func isCardFullyVisible(frame: NSRect, in viewportFrame: NSRect?) -> Bool {
    guard let viewportFrame else {
      return true
    }

    let normalizedViewport = viewportFrame.standardized
    let normalizedCard = frame.standardized
    let epsilon: CGFloat = 0.5
    let adjustedCard = normalizedCard.insetBy(dx: epsilon, dy: epsilon)
    return normalizedViewport.contains(adjustedCard)
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
    let selectedItems = navigator.selection.items
    let nextUnselectedItem: HistoryItemDecorator?
    if shelfModeEnabled {
      nextUnselectedItem = history.items.item(after: leadItem) { $0.isVisible && !$0.isSelected }
        ?? history.items.item(before: leadItem) { $0.isVisible && !$0.isSelected }
    } else {
      nextUnselectedItem = history.visibleItems.nearest(to: leadItem) { !$0.isSelected }
    }

    withTransaction(Transaction()) {
      history.delete(selectedItems)
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

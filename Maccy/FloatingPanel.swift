import Defaults
import SwiftUI

// An NSPanel subclass that implements floating panel traits.
// https://stackoverflow.com/questions/46023769/how-to-show-a-window-without-stealing-focus-on-macos
class FloatingPanel<Content: View>: NSPanel, NSWindowDelegate {
  private var shelfWidthRatio: CGFloat { 0.88 }
  private var shelfBottomInset: CGFloat { 24 }
  private var shelfHorizontalInset: CGFloat { 16 }
  private var shelfMaxHeightRatio: CGFloat { 0.65 }

  var isPresented: Bool = false
  var statusBarButton: NSStatusBarButton?
  let onClose: () -> Void

  override var isMovable: Bool {
    get { !AppState.shared.shelfModeEnabled && Defaults[.popupPosition] != .statusItem }
    set {}
  }

  init(
    contentRect: NSRect,
    identifier: String = "",
    statusBarButton: NSStatusBarButton? = nil,
    onClose: @escaping () -> Void,
    view: () -> Content
  ) {
    self.onClose = onClose

    super.init(
        contentRect: contentRect,
        styleMask: [.nonactivatingPanel, .resizable, .closable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )

    self.statusBarButton = statusBarButton
    self.identifier = NSUserInterfaceItemIdentifier(identifier)

    Defaults[.windowSize] = contentRect.size
    delegate = self

    animationBehavior = .none
    isFloatingPanel = true
    level = .statusBar
    collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    isMovableByWindowBackground = true
    hidesOnDeactivate = false
    backgroundColor = .clear
    titlebarSeparatorStyle = .none

    // Hide all traffic light buttons
    standardWindowButton(.closeButton)?.isHidden = true
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true

    contentView = NSHostingView(
      rootView: view()
        // The safe area is ignored because the title bar still interferes with the geometry
        .ignoresSafeArea()
        .gesture(DragGesture()
          .onEnded { _ in
            if !AppState.shared.shelfModeEnabled {
              self.saveWindowPosition()
            }
        })
    )
    contentView?.layer?.cornerRadius = Popup.cornerRadius + Popup.horizontalPadding
  }

  private func shelfFrame(height: CGFloat) -> NSRect? {
    guard let screenFrame = NSScreen.forPopup?.visibleFrame else {
      return nil
    }

    let maxWidth = max(420, screenFrame.width - shelfHorizontalInset * 2)
    let minWidth = min(maxWidth, 720)
    let width = min(max(screenFrame.width * shelfWidthRatio, minWidth), maxWidth)
    let maxHeight = screenFrame.height * shelfMaxHeightRatio
    let finalHeight = min(max(height, Popup.minimumShelfHeight), maxHeight)
    let originX = screenFrame.midX - width / 2
    let originY = screenFrame.minY + shelfBottomInset
    return NSRect(x: originX, y: originY, width: width, height: finalHeight)
  }

  func toggle(height: CGFloat, at popupPosition: PopupPosition = Defaults[.popupPosition]) {
    if isPresented {
      close()
    } else {
      open(height: height, at: popupPosition)
    }
  }

  func open(height: CGFloat, at popupPosition: PopupPosition = Defaults[.popupPosition]) {
    if AppState.shared.shelfModeEnabled {
      styleMask.remove(.resizable)
      isMovableByWindowBackground = false
      if let frame = shelfFrame(height: height) {
        setFrame(frame, display: true)
      }
    } else {
      styleMask.insert(.resizable)
      isMovableByWindowBackground = true
      let size = Defaults[.windowSize]
      setContentSize(NSSize(width: min(frame.width, size.width), height: min(height, size.height)))
      setFrameOrigin(popupPosition.origin(size: frame.size, statusBarButton: statusBarButton))
    }

    orderFrontRegardless()
    makeKey()
    isPresented = true

    if popupPosition == .statusItem {
      DispatchQueue.main.async {
        self.statusBarButton?.isHighlighted = true
      }
    }
  }

  func verticallyResize(to newHeight: CGFloat) {
    if AppState.shared.shelfModeEnabled, let newFrame = shelfFrame(height: newHeight) {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        animator().setFrame(newFrame, display: true)
      }
      return
    }

    var newSize = frame.size
    newSize.height = newHeight
    var newOrigin = frame.origin
    if !AppState.shared.shelfModeEnabled {
      newOrigin.y += (frame.height - newSize.height)
    }

    NSAnimationContext.runAnimationGroup { (context) in
      context.duration = 0.2
      animator().setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
    }
  }

  func determinePreviewPlacement() {
    let preview = AppState.shared.preview
    guard !preview.state.isOpen else { return }
    let newSize = preview.computeSizeWithPreview(frame.size, state: .open)
    preview.placement = preview.computePlacement(window: self, for: newSize)
  }

  func saveWindowPosition() {
    guard !AppState.shared.shelfModeEnabled else { return }

    if let screenFrame = screen?.visibleFrame {
      // Only store the size of the window without the preview
      let width = AppState.shared.preview.contentWidth

      let anchorX = frame.minX + width / 2 - screenFrame.minX
      let anchorY = frame.maxY - screenFrame.minY
      Defaults[.windowPosition] = NSPoint(x: anchorX / screenFrame.width, y: anchorY / screenFrame.height)
    }
  }

  func saveWindowFrame(frame: NSRect) {
    guard !AppState.shared.shelfModeEnabled else { return }

    Defaults[.windowSize] = frame.size
    saveWindowPosition()
  }

  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    guard !AppState.shared.shelfModeEnabled else { return frame.size }

    let preview = AppState.shared.preview

    if inLiveResize && preview.resizingMode == .none {
      let screenPoint = NSEvent.mouseLocation
      let windowPoint = convertPoint(fromScreen: screenPoint)
      let location: SlideoutPlacement = windowPoint.x <= frame.width / 2 ? .left : .right
      if (location == preview.placement) && preview.state == .open {
        preview.startResize(mode: .slideout)
      } else {
        preview.startResize(mode: .content)
      }
    }

    var finalFrameSize = frameSize
    var minContent = preview.minimumContentWidth
    var minPreview = 0.0

    if inLiveResize && preview.resizingMode != .none {
      if preview.resizingMode == .content && preview.state == .open {
        minPreview = preview.slideoutWidth
      }
      if preview.resizingMode == .slideout {
        minPreview = preview.minimumSlideoutWidth
        minContent = preview.contentWidth
      }
    }
    finalFrameSize.width = max(finalFrameSize.width, minContent + minPreview)

    if !AppState.shared.preview.state.isAnimating {
      var size = frame.size
      // Only store the size of the window without the preview
      size.width = AppState.shared.preview.contentWidth
      saveWindowFrame(frame: NSRect(origin: frame.origin, size: size))
    }

    return finalFrameSize
  }

  func windowWillMove(_ notification: Notification) {
    guard !AppState.shared.shelfModeEnabled else { return }
    determinePreviewPlacement()
  }

  func windowDidMove(_ notification: Notification) {
    guard !AppState.shared.shelfModeEnabled else { return }
    determinePreviewPlacement()
  }

  func windowWillStartLiveResize(_ notification: Notification) {
    guard !AppState.shared.shelfModeEnabled else { return }
    AppState.shared.preview.cancelAutoOpen()
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    guard !AppState.shared.shelfModeEnabled else { return }
    AppState.shared.preview.startAutoOpen()
    AppState.shared.preview.endResize()
  }

  func windowDidBecomeKey(_ notification: Notification) {
    guard !AppState.shared.shelfModeEnabled else { return }
    AppState.shared.preview.enableAutoOpen()

    if AppState.shared.navigator.leadHistoryItem != nil {
      AppState.shared.preview.startAutoOpen()
    }
  }

  func windowDidResignKey(_ notification: Notification) {
    guard !AppState.shared.shelfModeEnabled else { return }
    AppState.shared.preview.disableAutoOpen()
  }

  // Close automatically when out of focus, e.g. outside click.
  override func resignKey() {
    super.resignKey()
    // Don't hide if confirmation is shown.
    if NSApp.alertWindow == nil {
      close()
    }
  }

  override func close() {
    super.close()
    AppState.shared.preview.state = .closed
    isPresented = false
    statusBarButton?.isHighlighted = false
    onClose()
  }

  // Allow text inputs inside the panel can receive focus
  override var canBecomeKey: Bool {
    return true
  }
}

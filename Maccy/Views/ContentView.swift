import Defaults
import SwiftData
import SwiftUI

struct ContentView: View {
  @State private var appState = AppState.shared
  @State private var modifierFlags = ModifierFlags()
  @State private var scenePhase: ScenePhase = .background
  @State private var shelfSearchExpanded = false

  @FocusState private var searchFocused: Bool

  var body: some View {
    ZStack {
      if #available(macOS 26.0, *) {
        GlassEffectView()
      } else {
        VisualEffectView()
      }

      KeyHandlingView(
        searchQuery: $appState.history.searchQuery,
        searchFocused: $searchFocused,
        shelfSearchExpanded: $shelfSearchExpanded
      ) {
        if appState.shelfModeEnabled {
          ShelfContentView(
            searchQuery: $appState.history.searchQuery,
            searchFocused: $searchFocused,
            searchExpanded: $shelfSearchExpanded
          )
        } else {
          listContent
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .task {
        try? await appState.history.load()
      }
    }
    .animation(.easeInOut(duration: 0.2), value: appState.searchVisible)
    .environment(appState)
    .environment(modifierFlags)
    .environment(\.scenePhase, scenePhase)
    // FloatingPanel is not a scene, so let's implement custom scenePhase..
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
      if let window = $0.object as? NSWindow,
         let bundleIdentifier = Bundle.main.bundleIdentifier,
         window.identifier == NSUserInterfaceItemIdentifier(bundleIdentifier) {
        scenePhase = .active
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) {
      if let window = $0.object as? NSWindow,
         let bundleIdentifier = Bundle.main.bundleIdentifier,
         window.identifier == NSUserInterfaceItemIdentifier(bundleIdentifier) {
        scenePhase = .background
      }
    }
  }

  private var listContent: some View {
    VStack(spacing: 0) {
      SlideoutView(controller: appState.preview) {
        HeaderView(
          controller: appState.preview,
          searchFocused: $searchFocused
        )

        VStack(alignment: .leading, spacing: 0) {
          HistoryListView(
            searchQuery: $appState.history.searchQuery,
            searchFocused: $searchFocused
          )

          FooterView(footer: appState.footer)
        }
        .animation(.default.speed(3), value: appState.history.items)
        .animation(
          .default.speed(3),
          value: appState.history.pasteStack?.id
        )
        .padding(.horizontal, Popup.horizontalPadding)
        .onAppear {
          searchFocused = true
        }
        .onMouseMove {
          appState.navigator.isKeyboardNavigating = false
        }
      } slideout: {
        SlideoutContentView()
      }
      .frame(minHeight: 0)
      .layoutPriority(1)
    }
  }
}

private struct ShelfContentView: View {
  @Binding var searchQuery: String
  @FocusState.Binding var searchFocused: Bool
  @Binding var searchExpanded: Bool

  @Environment(AppState.self) private var appState
  @Environment(ModifierFlags.self) private var modifierFlags
  @Environment(\.scenePhase) private var scenePhase

  private var shelfItems: [HistoryItemDecorator] {
    appState.history.pinnedItems.filter(\.isVisible) + appState.history.unpinnedItems.filter(\.isVisible)
  }

  var body: some View {
    VStack(spacing: 10) {
      if appState.shelfPreview.isOpen {
        ShelfPreviewPanelView()
          .transition(.opacity.combined(with: .move(edge: .bottom)))
      }

      ShelfTopStripView(
        searchQuery: $searchQuery,
        searchFocused: $searchFocused,
        searchExpanded: $searchExpanded
      )

      ShelfCarouselView(items: shelfItems)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 14)
    .animation(.easeInOut(duration: 0.16), value: appState.shelfPreview.isOpen)
    .onAppear {
      appState.shelfPreview.close()
      searchFocused = false
      searchExpanded = false
      appState.navigator.highlightShelfFirst()
      appState.popup.needsResize = true
      DispatchQueue.main.async {
        if let window = NSApp.keyWindow {
          window.makeFirstResponder(window.contentView)
        }
      }
    }
    .onChange(of: scenePhase) {
      if scenePhase == .active {
        searchFocused = false
        searchExpanded = false
        appState.navigator.isKeyboardNavigating = true
        if appState.navigator.leadHistoryItem == nil {
          appState.navigator.highlightShelfFirst()
        }
        DispatchQueue.main.async {
          if let window = NSApp.keyWindow {
            window.makeFirstResponder(window.contentView)
          }
        }
      } else {
        searchFocused = false
        searchExpanded = false
        searchQuery = ""
        modifierFlags.flags = []
        appState.navigator.isKeyboardNavigating = true
        appState.shelfPreview.close()
      }
      appState.popup.needsResize = true
    }
    .onChange(of: appState.shelfPreview.isOpen) {
      appState.popup.needsResize = true
    }
    .background {
      GeometryReader { geo in
        Color.clear
          .task(id: appState.popup.needsResize) {
            try? await Task.sleep(for: .milliseconds(10))
            guard !Task.isCancelled else { return }

            if appState.popup.needsResize {
              appState.popup.resize(height: geo.size.height)
            }
        }
      }
    }
  }
}

private struct ShelfTopStripView: View {
  private struct TagChip: Identifiable {
    let key: String
    let color: Color

    var id: String { key }
  }

  @Binding var searchQuery: String
  @FocusState.Binding var searchFocused: Bool
  @Binding var searchExpanded: Bool

  @Environment(AppState.self) private var appState
  @Default(.showSearch) private var showSearch
  @State private var showActions = false
  @State private var selectedTag = "shelf_chip_code"

  private let chips = [
    TagChip(key: "shelf_chip_clipboard", color: .white.opacity(0.95)),
    TagChip(key: "shelf_chip_links", color: .orange),
    TagChip(key: "shelf_chip_notes", color: .yellow),
    TagChip(key: "shelf_chip_emails", color: .green),
    TagChip(key: "shelf_chip_code", color: .purple)
  ]

  private var isSearchExpanded: Bool {
    showSearch && (searchExpanded || !searchQuery.isEmpty)
  }

  private var searchWidth: CGFloat {
    isSearchExpanded ? 340 : 26
  }

  private var sideRailWidth: CGFloat {
    max(searchWidth, 64)
  }

  var body: some View {
    HStack(spacing: 12) {
      HStack {
        if showSearch {
          if isSearchExpanded {
            ShelfSearchFieldView(
              placeholder: "search_placeholder",
              query: $searchQuery,
              focused: searchFocused
            ) {
              appState.select()
            }
            .focused($searchFocused)
            .frame(width: searchWidth, height: 40, alignment: .leading)
          } else {
            Button {
              searchExpanded = true
              DispatchQueue.main.async {
                searchFocused = true
              }
            } label: {
              Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: searchWidth, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }
      .frame(width: sideRailWidth, alignment: .leading)
      .animation(.easeInOut(duration: 0.15), value: isSearchExpanded)

      GeometryReader { geo in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 4) {
            ForEach(chips) { chip in
              Button {
                selectedTag = chip.key
              } label: {
                HStack(spacing: 7) {
                  Circle()
                    .fill(chip.color)
                    .frame(width: 7, height: 7)

                  Text(LocalizedStringKey(chip.key))
                    .font(.callout)
                    .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(selectedTag == chip.key ? .primary : .secondary)
                .background(
                  selectedTag == chip.key
                    ? Color.white.opacity(0.16)
                    : Color.clear,
                  in: Capsule()
                )
                .contentShape(Capsule())
              }
              .buttonStyle(.plain)
            }
          }
          .frame(minWidth: geo.size.width, alignment: .center)
        }
      }
      .frame(maxWidth: .infinity, alignment: .center)

      HStack(spacing: 12) {
        Button {
          // Placeholder UI to match the shelf controls in Paste.
        } label: {
          Image(systemName: "plus")
            .font(.title3)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)

        Button {
          showActions.toggle()
        } label: {
          Image(systemName: "ellipsis")
            .font(.title3)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showActions, arrowEdge: .top) {
          VStack(spacing: 2) {
            ForEach(appState.footer.items) { item in
              FooterItemView(item: item)
                .frame(width: 250)
            }
          }
          .padding(8)
        }
      }
      .frame(width: sideRailWidth, alignment: .trailing)
    }
    .frame(height: 40)
    .onChange(of: searchFocused) {
      if !searchFocused && searchQuery.isEmpty {
        searchExpanded = false
      } else if searchFocused {
        searchExpanded = true
      }
    }
  }
}

private struct ShelfSearchFieldView: View {
  let placeholder: LocalizedStringKey
  @Binding var query: String
  let focused: Bool
  let onSubmit: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.title3)
        .foregroundStyle(.secondary)

      TextField(placeholder, text: $query)
        .disableAutocorrection(true)
        .lineLimit(1)
        .textFieldStyle(.plain)
        .onSubmit {
          onSubmit()
        }

      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      } else {
        Image(systemName: "line.3.horizontal.decrease")
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 14)
    .frame(height: 40)
    .background(.white.opacity(0.08), in: Capsule())
    .overlay(
      Capsule()
        .strokeBorder(
          focused ? Color.accentColor.opacity(0.95) : Color.white.opacity(0.22),
          lineWidth: focused ? 2.5 : 1
        )
    )
  }
}

private struct ShelfCarouselView: View {
  let items: [HistoryItemDecorator]

  @Environment(AppState.self) private var appState

  var body: some View {
    Group {
      if items.isEmpty {
        Text("shelf_no_results")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
      } else {
        ScrollViewReader { proxy in
          ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 14) {
              ForEach(items) { item in
                ShelfCardView(item: item)
                  .id(item.id)
              }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 10)
          }
          .frame(height: 248)
          .background(alignment: .topLeading) {
            ShelfWheelBridge()
              .frame(width: 0, height: 0)
          }
          .onAppear {
            if let selectedId = appState.navigator.leadSelection {
              proxy.scrollTo(selectedId, anchor: .center)
            }
          }
          .onChange(of: appState.navigator.leadSelection) {
            if let selectedId = appState.navigator.leadSelection {
              withAnimation(.easeInOut(duration: 0.15)) {
                proxy.scrollTo(selectedId, anchor: .center)
              }
            }
          }
        }
      }
    }
    .frame(minHeight: 248)
  }
}

private struct ShelfCardView: View {
  @Bindable var item: HistoryItemDecorator

  @Environment(AppState.self) private var appState

  private var isSelected: Bool {
    appState.navigator.leadSelection == item.id
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(LocalizedStringKey(item.shelfTypeKey))
            .font(.headline)
            .lineLimit(1)
          Text(item.shelfRelativeTime)
            .font(.caption)
            .opacity(0.85)
        }

        Spacer(minLength: 0)

        AppImageView(appImage: item.applicationImage, size: NSSize(width: 22, height: 22))

        if item.isPinned {
          Image(systemName: "pin.fill")
            .font(.caption)
        }
      }
      .foregroundStyle(.white)
      .padding(10)
      .background(item.shelfHeaderColor)

      Group {
        if let image = item.thumbnailImage {
          Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        } else {
          VStack(alignment: .leading, spacing: 8) {
            Text(item.title.isEmpty ? item.text.shortened(to: 80) : item.title.shortened(to: 80))
              .font(.headline)
              .lineLimit(2)

            if !item.shelfExcerpt.isEmpty {
              Text(item.shelfExcerpt)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(5)
            }

            Spacer(minLength: 0)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .padding(10)
        }
      }
      .background(Color(nsColor: .windowBackgroundColor).opacity(0.86))

      HStack {
        Text(item.shelfMetadata)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
    }
    .frame(width: 260, height: 220)
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.28), lineWidth: isSelected ? 3 : 1)
    )
    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    .onAppear {
      item.ensureThumbnailImage()
    }
    .onTapGesture {
      if isSelected {
        Task {
          appState.history.select(item)
        }
      } else {
        appState.navigator.select(item: item)
      }
    }
  }
}

private struct ShelfWheelBridge: NSViewRepresentable {
  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> BridgeView {
    let view = BridgeView()
    view.onAttach = { [weak coordinator = context.coordinator, weak view] in
      guard let coordinator, let view else { return }
      coordinator.attach(to: view)
    }
    return view
  }

  func updateNSView(_ nsView: BridgeView, context: Context) {
    nsView.onAttach?()
  }

  static func dismantleNSView(_ nsView: BridgeView, coordinator: Coordinator) {
    coordinator.detach()
  }

  final class BridgeView: NSView {
    var onAttach: (() -> Void)?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      onAttach?()
    }

    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      onAttach?()
    }
  }

  final class Coordinator {
    private weak var scrollView: NSScrollView?
    private var monitor: Any?

    deinit {
      detach()
    }

    func attach(to view: NSView) {
      guard let scrollView = findScrollView(from: view) else { return }

      self.scrollView = scrollView
      scrollView.hasHorizontalScroller = false
      scrollView.hasVerticalScroller = false

      installMonitor()
    }

    func detach() {
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
      scrollView = nil
    }

    private func installMonitor() {
      guard monitor == nil else { return }

      monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        guard let self,
              let scrollView = self.scrollView,
              let documentView = scrollView.documentView,
              let window = scrollView.window else {
          return event
        }

        if event.window !== window {
          return event
        }

        let pointInScrollView = scrollView.convert(event.locationInWindow, from: nil)
        guard scrollView.bounds.contains(pointInScrollView) else {
          return event
        }

        // Keep native horizontal trackpad gestures.
        if abs(event.scrollingDeltaX) > 0.01 {
          return event
        }

        let deltaY = event.scrollingDeltaY
        guard abs(deltaY) > 0.01 else {
          return event
        }

        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 14
        let translatedDeltaX = -deltaY * multiplier
        let visibleWidth = scrollView.contentView.bounds.width
        let maxX = max(0, documentView.bounds.width - visibleWidth)
        guard maxX > 0 else {
          return event
        }

        var origin = scrollView.contentView.bounds.origin
        let newX = min(max(origin.x + translatedDeltaX, 0), maxX)
        guard newX != origin.x else {
          return event
        }

        origin.x = newX
        scrollView.contentView.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        return nil
      }
    }

    private func findScrollView(from view: NSView) -> NSScrollView? {
      var current: NSView? = view
      while let candidate = current {
        if let scrollView = candidate.enclosingScrollView {
          return scrollView
        }
        current = candidate.superview
      }
      return nil
    }
  }
}

private struct ShelfPreviewPanelView: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ToolbarView()

      if let item = appState.navigator.leadHistoryItem {
        PreviewItemView(item: item)
      } else {
        Text("shelf_no_selection")
          .foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 320, alignment: .topLeading)
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(.white.opacity(0.22), lineWidth: 1)
    )
  }
}

#Preview {
  ContentView()
    .environment(\.locale, .init(identifier: "en"))
    .modelContainer(Storage.shared.container)
}

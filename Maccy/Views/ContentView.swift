import Defaults
import SwiftData
import SwiftUI

struct ContentView: View {
  @State private var appState = AppState.shared
  @State private var modifierFlags = ModifierFlags()
  @State private var scenePhase: ScenePhase = .background

  @FocusState private var searchFocused: Bool

  var body: some View {
    ZStack {
      if #available(macOS 26.0, *) {
        GlassEffectView()
      } else {
        VisualEffectView()
      }

      KeyHandlingView(searchQuery: $appState.history.searchQuery, searchFocused: $searchFocused) {
        if appState.shelfModeEnabled {
          ShelfContentView(
            searchQuery: $appState.history.searchQuery,
            searchFocused: $searchFocused
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

      ShelfTopStripView(searchQuery: $searchQuery, searchFocused: $searchFocused)

      ShelfCarouselView(items: shelfItems)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
    .animation(.easeInOut(duration: 0.16), value: appState.shelfPreview.isOpen)
    .onAppear {
      appState.shelfPreview.close()
      searchFocused = false
      appState.navigator.highlightShelfFirst()
      appState.popup.needsResize = true
    }
    .onChange(of: scenePhase) {
      if scenePhase == .active {
        appState.navigator.isKeyboardNavigating = true
        if appState.navigator.leadHistoryItem == nil {
          appState.navigator.highlightShelfFirst()
        }
      } else {
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
    .onMouseMove {
      appState.navigator.isKeyboardNavigating = false
    }
  }
}

private struct ShelfTopStripView: View {
  @Binding var searchQuery: String
  @FocusState.Binding var searchFocused: Bool

  @Environment(AppState.self) private var appState
  @State private var showActions = false

  private let chips = [
    "shelf_chip_clipboard",
    "shelf_chip_links",
    "shelf_chip_notes",
    "shelf_chip_emails",
    "shelf_chip_code"
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        if appState.searchVisible {
          SearchFieldView(placeholder: "search_placeholder", query: $searchQuery)
            .focused($searchFocused)
            .frame(maxWidth: 280)
        }

        Spacer(minLength: 0)

        Button {
          showActions.toggle()
        } label: {
          Image(systemName: "ellipsis.circle")
            .font(.title3)
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

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(chips, id: \.self) { key in
            Text(LocalizedStringKey(key))
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 12)
              .padding(.vertical, 5)
              .background(.white.opacity(0.25), in: Capsule())
          }
        }
      }
    }
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
          ScrollView(.horizontal) {
            LazyHStack(spacing: 14) {
              ForEach(items) { item in
                ShelfCardView(item: item)
                  .id(item.id)
              }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 2)
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
    .frame(minHeight: 230)
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
    .hoverSelectionId(item.id)
    .onAppear {
      item.ensureThumbnailImage()
    }
    .onTapGesture {
      Task {
        appState.history.select(item)
      }
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

import Defaults
import Logging
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

  private func defocusShelfSearch() {
    guard searchFocused else { return }

    searchFocused = false
    DispatchQueue.main.async {
      if let window = NSApp.keyWindow {
        window.makeFirstResponder(window.contentView)
      }
    }
  }

  var body: some View {
    VStack(spacing: 2) {
      ShelfTopStripView(
        searchQuery: $searchQuery,
        searchFocused: $searchFocused,
        searchExpanded: $searchExpanded,
        onOutsideSearchInteraction: defocusShelfSearch
      )

      ShelfCarouselView(
        items: shelfItems,
        onOutsideSearchInteraction: defocusShelfSearch
      )
    }
    .padding(.horizontal, 8)
    .padding(.top, 8)
    .padding(.bottom, 12)
    .onAppear {
      appState.shelfPreview.closeAll()
      searchFocused = false
      searchExpanded = false
      appState.navigator.highlightShelfFirst()
      appState.shelfPreview.updateLeadSelection()
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
        appState.shelfPreview.closeAll()
      }
      appState.popup.needsResize = true
    }
    .onChange(of: appState.navigator.leadSelection) {
      appState.shelfPreview.updateLeadSelection()
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
  private enum TagPresentation {
    case full
    case dotOnly
  }

  private struct TagChip: Identifiable {
    let id: String
    let accessibilityID: String
    let title: String
    let color: Color
    let tagID: UUID?
  }

  @Binding var searchQuery: String
  @FocusState.Binding var searchFocused: Bool
  @Binding var searchExpanded: Bool
  let onOutsideSearchInteraction: () -> Void

  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme
  @Default(.showSearch) private var showSearch
  @State private var showActions = false
  @State private var showCreateTagPopover = false
  @State private var showRenameTagPopover = false
  @State private var showDeleteTagConfirmation = false
  @State private var newTagName = ""
  @State private var newTagColor: ShelfTagColor = .blue
  @State private var renameTagID: UUID?
  @State private var renameTagName = ""
  @State private var deleteTagID: UUID?
  @State private var deleteTagName = ""

  private var chips: [TagChip] {
    let tags = appState.history.tags
    let slugCounts = Dictionary(grouping: tags, by: { normalizedTagIdentifier($0.name) })
      .mapValues { $0.count }
    let allChip = TagChip(
      id: "all",
      accessibilityID: "all",
      title: NSLocalizedString("shelf_tag_all", comment: ""),
      color: .white.opacity(0.95),
      tagID: nil
    )
    let tagChips = tags.map { tag in
      let slug = normalizedTagIdentifier(tag.name)
      let accessibilityID = slug == "all" || slugCounts[slug, default: 0] > 1
        ? "\(slug)-\(tag.id.uuidString.lowercased())"
        : slug
      return TagChip(
        id: tag.id.uuidString,
        accessibilityID: accessibilityID,
        title: tag.name,
        color: tag.color.color,
        tagID: tag.id
      )
    }

    return [allChip] + tagChips
  }

  private var isSearchExpanded: Bool {
    showSearch && (searchExpanded || !searchQuery.isEmpty)
  }

  private var trailingActionsWidth: CGFloat {
    44
  }

  private var trailingActionsInset: CGFloat {
    trailingActionsWidth + 12
  }

  // Room for the selection ring, which extends 3pt beyond each dot.
  private let dotRailInset: CGFloat = 4

  private var dotRailWidth: CGFloat {
    CGFloat(chips.count * 12 + max(chips.count - 1, 0) * 14) + dotRailInset * 2
  }

  private func preferredTagRailWidth(_ presentation: TagPresentation) -> CGFloat {
    switch presentation {
    case .dotOnly:
      return dotRailWidth
    case .full:
      let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
      let chipWidth = chips.reduce(CGFloat.zero) { width, chip in
        let titleWidth = (chip.title as NSString).size(withAttributes: [.font: font]).width
        return width + ceil(titleWidth) + 38
      }
      return chipWidth + CGFloat(max(chips.count - 1, 0) * 4)
    }
  }

  private func tagRailWidth(
    availableWidth: CGFloat,
    presentation: TagPresentation,
    expandedSearchWidth: CGFloat
  ) -> CGFloat {
    let searchWidth: CGFloat = showSearch ? (isSearchExpanded ? expandedSearchWidth : 24) : 0
    let addTagWidth: CGFloat = isSearchExpanded ? 0 : 20
    let spacingCount = (showSearch ? 1 : 0) + (isSearchExpanded ? 0 : 1)
    let remainingWidth = availableWidth - trailingActionsInset - searchWidth - addTagWidth
      - CGFloat(spacingCount * 12)
    return min(preferredTagRailWidth(presentation), max(24, remainingWidth))
  }

  private var selectedTagForegroundColor: Color {
    colorScheme == .light ? .white : .primary
  }

  private var selectedTagBackgroundColor: Color {
    colorScheme == .light ? Color.black.opacity(0.38) : Color.white.opacity(0.16)
  }

  private var selectedTagRingColor: Color {
    colorScheme == .light ? Color.black.opacity(0.72) : Color.white.opacity(0.95)
  }

  private func preferredExpandedSearchWidth(availableWidth: CGFloat) -> CGFloat {
    let preferred = max(320, min(620, availableWidth - 260))
    let reservedTagWidth = min(dotRailWidth, max(60, availableWidth * 0.25))
    let maxAllowed = max(120, availableWidth - trailingActionsInset - reservedTagWidth - 12)
    return min(preferred, maxAllowed)
  }

  @ViewBuilder
  private func tagView(for chip: TagChip, presentation: TagPresentation) -> some View {
    let isSelected = appState.history.selectedTagID == chip.tagID

    switch presentation {
    case .full:
      HStack(spacing: 7) {
        Circle()
          .fill(chip.color)
          .frame(width: 7, height: 7)

        Text(verbatim: chip.title)
          .font(.callout)
          .lineLimit(1)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .foregroundStyle(isSelected ? selectedTagForegroundColor : .secondary)
      .background(
        isSelected ? selectedTagBackgroundColor : Color.clear,
        in: Capsule()
      )
      .contentShape(Capsule())
    case .dotOnly:
      Circle()
        .fill(chip.color)
        .frame(width: 12, height: 12)
        .overlay {
          Circle()
            .strokeBorder(
              isSelected ? selectedTagRingColor : Color.white.opacity(0),
              lineWidth: 2
            )
            .padding(-3)
        }
        .contentShape(Circle())
    }
  }

  private func normalizedTagIdentifier(_ value: String) -> String {
    let lowered = value.lowercased()
    let raw = lowered.unicodeScalars.map { scalar -> Character in
      if CharacterSet.alphanumerics.contains(scalar) {
        return Character(scalar)
      }
      return "-"
    }
    let collapsed = String(raw)
      .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

    return collapsed.isEmpty ? "tag" : collapsed
  }

  private func tagAccessibilityIdentifier(for chip: TagChip, presentation: TagPresentation) -> String {
    switch presentation {
    case .dotOnly:
      return "shelf-tag-dot-\(chip.accessibilityID)"
    case .full:
      return "shelf-tag-full-\(chip.accessibilityID)"
    }
  }

  @ViewBuilder
  private func tagButton(for chip: TagChip, presentation: TagPresentation) -> some View {
    if let tagID = chip.tagID {
      Button {
        onOutsideSearchInteraction()
        appState.history.selectTag(tagID)
      } label: {
        tagView(for: chip, presentation: presentation)
      }
      .buttonStyle(.plain)
      .contextMenu {
        Button("shelf_tag_rename") {
          renameTagID = tagID
          renameTagName = chip.title
          showRenameTagPopover = true
        }
        Button("shelf_tag_delete", role: .destructive) {
          deleteTagID = tagID
          deleteTagName = chip.title
          showDeleteTagConfirmation = true
        }
      }
      .dropDestination(for: String.self) { items, _ in
        guard let rawItemID = items.first,
              let itemID = UUID(uuidString: rawItemID) else {
          return false
        }

        onOutsideSearchInteraction()
        return appState.history.assignTag(tagID: tagID, toItemID: itemID)
      }
      .accessibilityIdentifier(tagAccessibilityIdentifier(for: chip, presentation: presentation))
    } else {
      Button {
        onOutsideSearchInteraction()
        appState.history.selectTag(nil)
      } label: {
        tagView(for: chip, presentation: presentation)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier(tagAccessibilityIdentifier(for: chip, presentation: presentation))
    }
  }

  private var canCreateTag: Bool {
    return appState.history.isTagNameAvailable(newTagName)
  }

  private var canRenameTag: Bool {
    guard let renameTagID else { return false }
    return appState.history.isTagNameAvailable(renameTagName, excludingID: renameTagID)
  }

  private var showCreateTagNameError: Bool {
    return !newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !canCreateTag
  }

  private var showRenameTagNameError: Bool {
    return !renameTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !canRenameTag
  }

  private func resetCreateTagForm() {
    newTagName = ""
    newTagColor = .blue
  }

  private func submitCreateTag() {
    guard let tag = appState.history.createTag(name: newTagName, color: newTagColor) else {
      return
    }

    appState.history.selectTag(tag.id)
    showCreateTagPopover = false
    resetCreateTagForm()
  }

  private func submitRenameTag() {
    guard let renameTagID else {
      return
    }

    guard appState.history.renameTag(id: renameTagID, to: renameTagName) else {
      return
    }

    self.renameTagID = nil
    renameTagName = ""
    showRenameTagPopover = false
  }

  var body: some View {
    GeometryReader { geo in
      let tagPresentation: TagPresentation = isSearchExpanded ? .dotOnly : .full
      let expandedSearchWidth = preferredExpandedSearchWidth(availableWidth: geo.size.width)
      let railWidth = tagRailWidth(
        availableWidth: geo.size.width,
        presentation: tagPresentation,
        expandedSearchWidth: expandedSearchWidth
      )

      ZStack(alignment: .trailing) {
        HStack(spacing: 12) {
          if showSearch {
            if isSearchExpanded {
              ShelfSearchFieldView(
                placeholder: "search_placeholder",
                query: $searchQuery,
                focused: searchFocused
              ) {
                appState.select(flags: .currentModifierFlags)
              }
              .focused($searchFocused)
              .frame(width: expandedSearchWidth, height: 40)
              .accessibilityIdentifier("shelf-search-field")
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
                  .frame(width: 24, height: 40)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("shelf-search-toggle")
            }
          }

          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: tagPresentation == .dotOnly ? 14 : 4) {
              ForEach(chips) { chip in
                tagButton(for: chip, presentation: tagPresentation)
              }
            }
            .padding(.horizontal, tagPresentation == .dotOnly ? dotRailInset : 0)
            .frame(height: 40)
          }
          .frame(width: railWidth, height: 40)

          if !isSearchExpanded {
            Button {
              onOutsideSearchInteraction()
              resetCreateTagForm()
              showCreateTagPopover = true
            } label: {
              Image(systemName: "plus")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("shelf-add-tag")
            .popover(isPresented: $showCreateTagPopover, arrowEdge: .top) {
              VStack(alignment: .leading, spacing: 12) {
                Text("shelf_tag_create_title")
                  .font(.headline)

                TextField("shelf_tag_name_placeholder", text: $newTagName)
                  .textFieldStyle(.roundedBorder)
                  .accessibilityIdentifier("shelf-tag-name-input")

                ShelfTagColorPicker(selectedColor: $newTagColor)
                  .accessibilityIdentifier("shelf-tag-color-picker")

                if showCreateTagNameError {
                  Text("shelf_tag_name_exists")
                    .font(.caption)
                    .foregroundStyle(.red)
                }

                HStack {
                  Spacer()
                  Button("clear_alert_cancel") {
                    showCreateTagPopover = false
                    resetCreateTagForm()
                  }
                  Button("shelf_tag_create_action") {
                    submitCreateTag()
                  }
                  .disabled(!canCreateTag)
                  .keyboardShortcut(.defaultAction)
                  .accessibilityIdentifier("shelf-tag-create-confirm")
                }
              }
              .padding(14)
              .frame(width: 300)
            }
          }
        }
        .padding(.trailing, trailingActionsInset)
        .frame(maxWidth: .infinity, alignment: .center)

        Button {
          onOutsideSearchInteraction()
          showActions.toggle()
        } label: {
          Image(systemName: "ellipsis")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(width: trailingActionsWidth, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("shelf-actions")
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
      .frame(maxWidth: .infinity, alignment: .trailing)
      .animation(.easeInOut(duration: 0.18), value: isSearchExpanded)
    }
    .frame(height: 40)
    .accessibilityIdentifier("shelf-top-strip")
    .popover(isPresented: $showRenameTagPopover, arrowEdge: .top) {
      VStack(alignment: .leading, spacing: 12) {
        Text("shelf_tag_rename_title")
          .font(.headline)

        TextField("shelf_tag_name_placeholder", text: $renameTagName)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("shelf-tag-rename-input")

        if showRenameTagNameError {
          Text("shelf_tag_name_exists")
            .font(.caption)
            .foregroundStyle(.red)
        }

        HStack {
          Spacer()
          Button("clear_alert_cancel") {
            showRenameTagPopover = false
            renameTagID = nil
            renameTagName = ""
          }
          Button("shelf_tag_rename_action") {
            submitRenameTag()
          }
          .disabled(!canRenameTag)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("shelf-tag-rename-confirm")
        }
      }
      .padding(14)
      .frame(width: 300)
    }
    .alert(
      Text("shelf_tag_delete_title"),
      isPresented: $showDeleteTagConfirmation
    ) {
      Button("clear_alert_cancel", role: .cancel) {
        deleteTagID = nil
        deleteTagName = ""
      }
      Button("shelf_tag_delete", role: .destructive) {
        if let deleteTagID {
          appState.history.deleteTag(id: deleteTagID)
        }
        self.deleteTagID = nil
        deleteTagName = ""
      }
    } message: {
      Text(String(format: NSLocalizedString("shelf_tag_delete_message", comment: ""), deleteTagName))
    }
    .onChange(of: searchFocused) {
      if searchFocused {
        searchExpanded = true
      } else if searchQuery.isEmpty {
        searchExpanded = false
      }
    }
  }
}

private struct ShelfTagColorPicker: View {
  @Binding var selectedColor: ShelfTagColor
  @Environment(\.colorScheme) private var colorScheme

  private var selectedOuterRingColor: Color {
    colorScheme == .light ? Color.black.opacity(0.7) : Color.white.opacity(0.96)
  }

  private var selectedInnerRingColor: Color {
    colorScheme == .light ? Color.white.opacity(0.92) : Color.black.opacity(0.5)
  }

  var body: some View {
    HStack(spacing: 10) {
      ForEach(ShelfTagColor.allCases) { color in
        Button {
          selectedColor = color
        } label: {
          Circle()
            .fill(color.color)
            .frame(width: 16, height: 16)
            .overlay {
              Circle()
                .strokeBorder(Color.white.opacity(0.2), lineWidth: selectedColor == color ? 0 : 1)
                .padding(-2)
            }
            .overlay {
              if selectedColor == color {
                Circle()
                  .strokeBorder(selectedOuterRingColor, lineWidth: 2)
                  .padding(-5)
              }
            }
            .overlay {
              if selectedColor == color {
                Circle()
                  .strokeBorder(selectedInnerRingColor, lineWidth: 1.25)
                  .padding(-3.5)
              }
            }
        }
        .buttonStyle(.plain)
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
        .accessibilityIdentifier("shelf-search-input")
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
  private enum SelectionSource {
    case pointer
    case keyboardOrProgrammatic
  }

  let items: [HistoryItemDecorator]
  let onOutsideSearchInteraction: () -> Void

  @Environment(AppState.self) private var appState
  @State private var pendingSelectionSource: SelectionSource = .keyboardOrProgrammatic
  @State private var pendingPointerSelectionId: UUID?

  private func handleCardTap(id: UUID) {
    onOutsideSearchInteraction()

    guard let tappedItem = items.first(where: { $0.id == id }) else { return }

    if appState.navigator.leadSelection == id {
      let flags = NSEvent.ModifierFlags.currentModifierFlags
      Task {
        appState.history.select(tappedItem, flags: flags)
      }
      return
    }

    pendingSelectionSource = .pointer
    pendingPointerSelectionId = id
    appState.navigator.select(item: tappedItem)
  }

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
                ShelfCardView(
                  item: item,
                  isSelected: appState.navigator.leadSelection == item.id,
                  onCardTap: handleCardTap
                )
                  .id(item.id)
              }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
            .background {
              ShelfWheelBridge()
                .frame(width: 0, height: 0)
            }
          }
          .frame(height: 236)
          .accessibilityIdentifier("shelf-carousel")
          .onAppear {
            if let selectedId = appState.navigator.leadSelection {
              proxy.scrollTo(selectedId, anchor: .center)
            }
          }
          .task(id: items.map(\.id)) {
            var logger = Logger(label: "org.p0deje.Maccy.shelfPreview.debug")
            logger.logLevel = .debug
            logger.debug(
              "shelf items changed count=\(items.count) selected=\(String(describing: appState.navigator.leadSelection))"
            )
            appState.shelfPreview.syncVisibleShelfItemIDs(Set(items.map(\.id)))
          }
          .task(id: appState.navigator.leadSelection) {
            guard let selectedId = appState.navigator.leadSelection else {
              pendingSelectionSource = .keyboardOrProgrammatic
              pendingPointerSelectionId = nil
              return
            }

            let selectionSource = pendingSelectionSource
            pendingSelectionSource = .keyboardOrProgrammatic

            if selectionSource == .pointer,
               pendingPointerSelectionId == selectedId {
              pendingPointerSelectionId = nil
              return
            }
            pendingPointerSelectionId = nil

            try? await Task.sleep(for: .milliseconds(10))
            guard !Task.isCancelled else { return }

            withAnimation(.easeInOut(duration: 0.15)) {
              proxy.scrollTo(selectedId, anchor: .center)
            }
          }
        }
      }
    }
    .frame(minHeight: 236)
  }
}

private struct ShelfCardView: View {
  @Bindable var item: HistoryItemDecorator
  let isSelected: Bool
  let onCardTap: (UUID) -> Void
  @Environment(AppState.self) private var appState
  @Default(.showHexColorSwatch) private var showHexColorSwatch

  var body: some View {
    let hasImage = item.hasImage
    let thumbnailImage = item.thumbnailImage
    let cardTitle = item.shelfDisplayTitle.shortened(to: 80)
    let cardBodyText = item.shelfExcerpt.isEmpty ? cardTitle : item.shelfExcerpt
    let shelfContentBackgroundColor = showHexColorSwatch ? item.shelfContentBackgroundColor : nil
    let shelfContentForegroundColor = showHexColorSwatch ? item.shelfContentForegroundColor : nil
    let bodyBackgroundColor = shelfContentBackgroundColor ?? Color(nsColor: .windowBackgroundColor).opacity(0.86)
    let metadataBackgroundColor = shelfContentBackgroundColor ?? Color(nsColor: .windowBackgroundColor).opacity(0.9)
    let bodyTextColor = shelfContentForegroundColor ?? .secondary
    let metadataTextColor = shelfContentForegroundColor?.opacity(0.88) ?? .secondary

    Button {
      onCardTap(item.id)
    } label: {
      VStack(spacing: 0) {
        HStack(alignment: .top, spacing: 8) {
          VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: cardTitle)
              .font(.headline)
              .lineLimit(1)
            Text(item.shelfRelativeTime)
              .font(.caption)
              .opacity(0.85)
          }

          Spacer(minLength: 0)

          if !item.isTagged {
            AppImageView(appImage: item.applicationImage, size: NSSize(width: 22, height: 22))
          }

          if item.isPinned {
            Image(systemName: "pin.fill")
              .font(.caption)
          }
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(item.shelfHeaderColor)

        Group {
          if hasImage {
            GeometryReader { geometry in
              if let image = thumbnailImage {
                let containerWidth = geometry.size.width
                let safeImageWidth = max(image.size.width, 1)
                let renderedImageHeight = containerWidth * image.size.height / safeImageWidth

                Image(nsImage: image)
                  .resizable()
                  // Keep the top of screenshots visible; crop from the bottom when needed.
                  .frame(width: containerWidth, height: renderedImageHeight, alignment: .top)
                  .frame(width: containerWidth, height: geometry.size.height, alignment: .top)
              } else {
                ProgressView()
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
              }
            }
              .clipped()
          } else {
            VStack(alignment: .leading, spacing: 8) {
              Text(cardBodyText)
                .font(.body)
                .foregroundStyle(bodyTextColor)
                .lineLimit(7)

              Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
          }
        }
        .background(bodyBackgroundColor)

        HStack {
          Text(item.shelfMetadata)
            .font(.caption)
            .foregroundStyle(metadataTextColor)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(metadataBackgroundColor)
      }
      .frame(width: 260, height: 220)
      .background(.ultraThinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.28), lineWidth: isSelected ? 3 : 1)
      )
      .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
      .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .background {
        ShelfCardFrameReporter(itemID: item.id)
      }
    }
    .buttonStyle(.plain)
    .draggable(item.id.uuidString)
    .accessibilityIdentifier("shelf-card")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: cardTitle))
    .accessibilityValue(Text(verbatim: isSelected ? "selected" : "unselected"))
    .contextMenu {
      if item.hasImage {
        Button("Copy Image Text") {
          appState.history.copyImageText(from: item)
        }
        .disabled(!item.canCopyImageText)
      }

      Button("shelf_paste_without_formatting") {
        appState.history.pasteWithoutFormatting(item)
      }

      Button("shelf_item_rename") {
        appState.history.promptRenameItem(item)
      }

      Menu("shelf_assign_tag") {
        if item.isTagged {
          Button("shelf_tag_remove_item") {
            appState.history.removeTag(from: item)
          }

          Divider()
        }

        if appState.history.tags.isEmpty {
          Button("shelf_assign_tag_none") {}
            .disabled(true)
        } else {
          ForEach(appState.history.tags) { tag in
            Button {
              _ = appState.history.assignTag(tagID: tag.id, toItemID: item.id)
            } label: {
              if item.item.tag?.id == tag.id {
                Label(tag.name, systemImage: "checkmark")
              } else {
                Text(verbatim: tag.name)
              }
            }
          }
        }
      }

      Button("Edit") {
        let itemToEdit = item
        DispatchQueue.main.async {
          appState.navigator.select(item: itemToEdit)
          appState.shelfPreview.editSelection()
        }
      }
      .disabled(!appState.shelfPreview.canEdit(item: item))

      Button("Share") {
        appState.shelfPreview.share(item: item)
      }
      .disabled(!appState.shelfPreview.canShare(item: item))
    }
    .onAppear {
      item.ensureThumbnailImage()
    }
  }
}

private struct ShelfCardFrameReporter: NSViewRepresentable {
  let itemID: UUID
  @Environment(AppState.self) private var appState
  private let logger: Logger = {
    var logger = Logger(label: "org.p0deje.Maccy.shelfPreview.debug")
    logger.logLevel = .debug
    return logger
  }()

  func makeNSView(context: Context) -> ReporterView {
    let view = ReporterView()
    view.itemID = itemID
    view.appState = appState
    logger.debug("reporter makeNSView item=\(itemID)")
    appState.shelfPreview.registerCardAnchor(itemID: itemID, anchor: view)
    return view
  }

  func updateNSView(_ nsView: ReporterView, context: Context) {
    if let previousItemID = nsView.itemID,
       previousItemID != itemID {
      logger.debug("reporter updateNSView rebind old=\(previousItemID) new=\(itemID)")
      (nsView.appState ?? appState)?.shelfPreview.unregisterCardAnchor(itemID: previousItemID, anchor: nsView)
    }
    nsView.itemID = itemID
    nsView.appState = appState
    logger.debug("reporter updateNSView register item=\(itemID)")
    appState.shelfPreview.registerCardAnchor(itemID: itemID, anchor: nsView)
    nsView.notifyAnchorDidChange()
  }

  static func dismantleNSView(_ nsView: ReporterView, coordinator: ()) {
    var logger = Logger(label: "org.p0deje.Maccy.shelfPreview.debug")
    logger.logLevel = .debug
    if let itemID = nsView.itemID {
      logger.debug("reporter dismantle item=\(itemID)")
      (nsView.appState ?? AppState.shared).shelfPreview.unregisterCardAnchor(itemID: itemID, anchor: nsView)
    }
    nsView.teardown()
  }

  final class ReporterView: NSView, ShelfPreviewAnchor {
    private let logger: Logger = {
      var logger = Logger(label: "org.p0deje.Maccy.shelfPreview.debug")
      logger.logLevel = .debug
      return logger
    }()
    weak var appState: AppState?
    var itemID: UUID?
    private weak var observedClipView: NSClipView?
    private weak var observedWindow: NSWindow?
    private var clipBoundsObserver: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?
    private var windowMoveObserver: NSObjectProtocol?
    private var windowResizeObserver: NSObjectProtocol?

    deinit {
      teardown()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      logger.debug("reporter viewDidMoveToWindow item=\(String(describing: itemID)) hasWindow=\(window != nil)")
      configureClipObservation()
      configureFrameObservation()
      configureWindowObservation()
      notifyAnchorDidChange()
    }

    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      logger.debug("reporter viewDidMoveToSuperview item=\(String(describing: itemID))")
      configureClipObservation()
      configureFrameObservation()
      configureWindowObservation()
      notifyAnchorDidChange()
    }

    override func layout() {
      super.layout()
      notifyAnchorDidChange()
    }

    func teardown() {
      stopObservingClipBounds()
      stopObservingFrameChanges()
      stopObservingWindowChanges()
    }

    private func configureClipObservation() {
      guard let clipView = enclosingScrollView?.contentView else {
        logger.debug("reporter clip observation unavailable item=\(String(describing: itemID))")
        stopObservingClipBounds()
        return
      }

      guard observedClipView !== clipView else {
        return
      }

      stopObservingClipBounds()
      observedClipView = clipView
      clipView.postsBoundsChangedNotifications = true
      logger.debug("reporter observing clip bounds item=\(String(describing: itemID))")
      clipBoundsObserver = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: clipView,
        queue: .main
      ) { [weak self] _ in
        self?.notifyAnchorDidChange()
      }
    }

    private func stopObservingClipBounds() {
      if let clipBoundsObserver {
        NotificationCenter.default.removeObserver(clipBoundsObserver)
        self.clipBoundsObserver = nil
      }
      observedClipView = nil
    }

    private func configureFrameObservation() {
      guard frameObserver == nil else {
        return
      }

      postsFrameChangedNotifications = true
      frameObserver = NotificationCenter.default.addObserver(
        forName: NSView.frameDidChangeNotification,
        object: self,
        queue: .main
      ) { [weak self] _ in
        self?.notifyAnchorDidChange()
      }
    }

    private func stopObservingFrameChanges() {
      if let frameObserver {
        NotificationCenter.default.removeObserver(frameObserver)
        self.frameObserver = nil
      }
    }

    private func configureWindowObservation() {
      guard let window else {
        logger.debug("reporter window observation unavailable item=\(String(describing: itemID))")
        stopObservingWindowChanges()
        return
      }

      guard observedWindow !== window else {
        return
      }

      stopObservingWindowChanges()
      observedWindow = window
      logger.debug("reporter observing window movement item=\(String(describing: itemID))")
      windowMoveObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didMoveNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        self?.notifyAnchorDidChange()
      }
      windowResizeObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didResizeNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        self?.notifyAnchorDidChange()
      }
    }

    private func stopObservingWindowChanges() {
      if let windowMoveObserver {
        NotificationCenter.default.removeObserver(windowMoveObserver)
        self.windowMoveObserver = nil
      }
      if let windowResizeObserver {
        NotificationCenter.default.removeObserver(windowResizeObserver)
        self.windowResizeObserver = nil
      }
      observedWindow = nil
    }

    func currentFrameInScreen() -> NSRect? {
      guard let window else {
        if itemID == appState?.navigator.leadHistoryItem?.id {
          logger.debug("reporter frame lookup has no window for selected item=\(String(describing: itemID))")
        }
        return nil
      }

      let frameInWindow = convert(bounds, to: nil)
      let frameInScreen = window.convertToScreen(frameInWindow)
      if itemID == appState?.navigator.leadHistoryItem?.id {
        logger.debug(
          "reporter frame lookup for selected item=\(String(describing: itemID)) frame=\(Self.describeRect(frameInScreen))"
        )
      }
      return frameInScreen
    }

    func notifyAnchorDidChange() {
      guard let appState,
            let itemID else {
        return
      }

      if itemID == appState.navigator.leadHistoryItem?.id {
        logger.debug("reporter notifyAnchorDidChange selected item=\(itemID)")
      }
      appState.shelfPreview.cardAnchorDidChange(itemID: itemID)
    }

    private static func describeRect(_ rect: NSRect) -> String {
      let normalized = rect.standardized
      return "x=\(Int(normalized.minX.rounded())) y=\(Int(normalized.minY.rounded())) w=\(Int(normalized.width.rounded())) h=\(Int(normalized.height.rounded()))"
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
    private let logger: Logger = {
      var logger = Logger(label: "org.p0deje.Maccy.shelfPreview.debug")
      logger.logLevel = .debug
      return logger
    }()
    private weak var scrollView: NSScrollView?
    private weak var observedWindow: NSWindow?
    private var monitor: Any?
    private var clipBoundsObserver: NSObjectProtocol?
    private var windowMoveObserver: NSObjectProtocol?
    private var windowResizeObserver: NSObjectProtocol?

    deinit {
      detach()
    }

    func attach(to view: NSView) {
      guard let scrollView = findScrollView(from: view) else { return }
      logger.debug("wheel attach hasWindow=\(scrollView.window != nil)")

      if self.scrollView !== scrollView {
        stopObservingClipBounds()
        self.scrollView = scrollView
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        observeClipBounds(of: scrollView)
      }

      AppState.shared.shelfPreview.bindCarouselClipView(scrollView.contentView)
      configureWindowObservation(window: scrollView.window)
      installMonitor()
      notifyViewportDidChange()
    }

    func detach() {
      logger.debug("wheel detach")
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
      stopObservingClipBounds()
      stopObservingWindow()
      AppState.shared.shelfPreview.bindCarouselClipView(nil)
      scrollView = nil
    }

    private func observeClipBounds(of scrollView: NSScrollView) {
      let clipView = scrollView.contentView
      clipView.postsBoundsChangedNotifications = true
      logger.debug("wheel observing clip bounds")
      clipBoundsObserver = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: clipView,
        queue: .main
      ) { [weak self] _ in
        self?.notifyViewportDidChange()
      }
    }

    private func stopObservingClipBounds() {
      if let clipBoundsObserver {
        NotificationCenter.default.removeObserver(clipBoundsObserver)
        self.clipBoundsObserver = nil
      }
    }

    private func configureWindowObservation(window: NSWindow?) {
      guard let window else {
        logger.debug("wheel window observation unavailable")
        stopObservingWindow()
        return
      }

      guard observedWindow !== window else {
        return
      }

      stopObservingWindow()
      observedWindow = window
      logger.debug("wheel observing window movement")
      windowMoveObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didMoveNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        self?.notifyViewportDidChange()
      }
      windowResizeObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didResizeNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        self?.notifyViewportDidChange()
      }
    }

    private func stopObservingWindow() {
      if let windowMoveObserver {
        NotificationCenter.default.removeObserver(windowMoveObserver)
        self.windowMoveObserver = nil
      }
      if let windowResizeObserver {
        NotificationCenter.default.removeObserver(windowResizeObserver)
        self.windowResizeObserver = nil
      }
      observedWindow = nil
    }

    private func notifyViewportDidChange() {
      logger.debug("wheel viewport changed")
      AppState.shared.shelfPreview.carouselViewportDidChange()
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
        guard scrollView.bounds.contains(pointInScrollView) else { return event }

        let horizontalDelta = event.hasPreciseScrollingDeltas
          ? event.scrollingDeltaX
          : event.deltaX

        // Keep native horizontal scrolling gestures.
        if abs(horizontalDelta) > 0.01 {
          return event
        }

        let deltaY = event.hasPreciseScrollingDeltas
          ? event.scrollingDeltaY
          : event.deltaY
        guard abs(deltaY) > 0.01 else { return event }

        if !event.hasPreciseScrollingDeltas {
          if deltaY < 0 {
            AppState.shared.navigator.highlightShelfNext()
          } else {
            AppState.shared.navigator.highlightShelfPrevious()
          }
          return nil
        }

        let translatedDeltaX = -deltaY
        let visibleWidth = scrollView.contentView.bounds.width
        let maxX = max(0, documentView.bounds.width - visibleWidth)
        guard maxX > 0 else { return event }

        var origin = scrollView.contentView.bounds.origin
        let newX = min(max(origin.x + translatedDeltaX, 0), maxX)
        guard newX != origin.x else { return event }

        origin.x = newX
        scrollView.contentView.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        self.notifyViewportDidChange()

        return nil
      }
    }

    private func findScrollView(from view: NSView) -> NSScrollView? {
      var current: NSView? = view
      while let candidate = current {
        if let scrollView = candidate.enclosingScrollView {
          return scrollView
        }
        if let nearbyScrollView = findDescendantScrollView(in: candidate) {
          return nearbyScrollView
        }
        current = candidate.superview
      }

      if let windowContentView = view.window?.contentView,
         let windowScrollView = findDescendantScrollView(in: windowContentView) {
        return windowScrollView
      }

      return nil
    }

    private func findDescendantScrollView(in view: NSView) -> NSScrollView? {
      for subview in view.subviews {
        if let scrollView = subview as? NSScrollView {
          return scrollView
        }
        if let descendant = findDescendantScrollView(in: subview) {
          return descendant
        }
      }
      return nil
    }
  }
}

private struct ShelfTextEditorAppearanceBridge: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      configure(from: view)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async {
      configure(from: nsView)
    }
  }

  private func configure(from view: NSView) {
    guard let scrollView = findScrollView(from: view),
          let textView = scrollView.documentView as? NSTextView else {
      return
    }

    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.backgroundColor = .clear
    scrollView.hasHorizontalScroller = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay

    textView.drawsBackground = false
    textView.backgroundColor = .clear
    textView.textColor = .labelColor
    textView.insertionPointColor = .labelColor
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

// Popover body and pointer as one path, so fill and outline have no seam where they meet.
private struct ShelfPopoverShape: Shape {
  var pointerX: CGFloat?
  var inset: CGFloat = 0

  func path(in rect: CGRect) -> Path {
    let metrics = ShelfPreviewLayoutMetrics.self
    let bounds = rect.insetBy(dx: inset, dy: inset)
    let radius = metrics.cornerRadius - inset
    let bottom = rect.maxY - (pointerX == nil ? 0 : metrics.pointerHeight) - inset
    let topLeft = CGPoint(x: bounds.minX, y: bounds.minY)
    let topRight = CGPoint(x: bounds.maxX, y: bounds.minY)
    let bottomRight = CGPoint(x: bounds.maxX, y: bottom)
    let bottomLeft = CGPoint(x: bounds.minX, y: bottom)

    var path = Path()
    path.move(to: CGPoint(x: bounds.minX + radius, y: bounds.minY))
    path.addArc(tangent1End: topRight, tangent2End: bottomRight, radius: radius)
    path.addArc(tangent1End: bottomRight, tangent2End: bottomLeft, radius: radius)

    if let pointerX {
      let edgeInset = metrics.pointerCenterInset - metrics.popupOuterPadding
      let x = max(edgeInset, min(pointerX - metrics.popupOuterPadding, rect.width - edgeInset))
      let half = metrics.pointerWidth / 2
      let height = bounds.maxY - bottom
      let tipRadius: CGFloat = 4.5
      let shoulderRadius: CGFloat = 12
      // Straight flanks rounded at the tip and blended into the edge at the shoulders.
      // Push the sharp tip down by however much the rounding shaves off it.
      let halfAngle = atan(half / height)
      let tip = CGPoint(x: x, y: bounds.maxY + tipRadius / sin(halfAngle) - tipRadius)
      let rightBase = CGPoint(x: x + half, y: bottom)
      let leftBase = CGPoint(x: x - half, y: bottom)

      path.addArc(tangent1End: rightBase, tangent2End: tip, radius: shoulderRadius)
      path.addArc(tangent1End: tip, tangent2End: leftBase, radius: tipRadius)
      path.addArc(tangent1End: leftBase, tangent2End: bottomLeft, radius: shoulderRadius)
    }

    path.addArc(tangent1End: bottomLeft, tangent2End: topLeft, radius: radius)
    path.addArc(tangent1End: topLeft, tangent2End: topRight, radius: radius)
    path.closeSubpath()
    return path
  }
}

private struct ShelfPopoverButtonStyle: ButtonStyle {
  var prominent = false

  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.body.weight(prominent ? .semibold : .medium))
      .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
      .padding(.horizontal, 14)
      .frame(minWidth: 30, minHeight: 30)
      .background(
        Capsule().fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(0.08)))
      )
      .contentShape(Capsule())
      .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.4))
  }
}

private struct ShelfPopoverShell<Leading: View, Title: View, Trailing: View, Content: View>: View {
  let pointerX: CGFloat?
  @ViewBuilder let leading: Leading
  @ViewBuilder let title: Title
  @ViewBuilder let trailing: Trailing
  @ViewBuilder let content: Content

  private typealias Metrics = ShelfPreviewLayoutMetrics

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        leading
        Spacer(minLength: 12)
        trailing
      }
      .overlay {
        title
          .allowsHitTesting(false)
      }
      .padding(.horizontal, Metrics.shellInset + 2)
      .frame(height: 48)

      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.contentCornerRadius, style: .continuous))
        .padding([.horizontal, .bottom], Metrics.shellInset)
    }
    .padding(.bottom, pointerX == nil ? 0 : Metrics.pointerHeight)
    .background {
      ShelfPopoverShape(pointerX: pointerX)
        .fill(.regularMaterial)
    }
    .overlay {
      ShelfPopoverShape(pointerX: pointerX, inset: 0.5)
        .stroke(.white.opacity(0.35), lineWidth: 1)
        .allowsHitTesting(false)
    }
    .padding(Metrics.popupOuterPadding)
  }
}

private struct ShelfPopoverTitle: View {
  let title: Text
  let subtitle: String

  var body: some View {
    VStack(spacing: 1) {
      title
        .font(.headline)
      if !subtitle.isEmpty {
        Text(verbatim: subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .lineLimit(1)
  }
}

struct ShelfPreviewPopupView: View {
  @Environment(AppState.self) private var appState

  private var item: HistoryItemDecorator? {
    appState.navigator.leadHistoryItem
  }

  private func pluralized(_ count: Int, singular: String, plural: String) -> String {
    if count == 1 {
      return "\(count) \(singular)"
    }
    return "\(count) \(plural)"
  }

  private var textStats: (characters: Int, words: Int, lines: Int) {
    let value = item?.item.previewableText ?? ""
    let words = value
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .count
    let lines = max(1, value.components(separatedBy: .newlines).count)
    return (characters: value.count, words: words, lines: lines)
  }

  private var footerText: String {
    guard let item else {
      return ""
    }

    if item.hasImage, let pixelSize = item.item.imagePixelSize {
      return "\(Int(pixelSize.width))×\(Int(pixelSize.height))"
    }

    let stats = textStats
    return [
      pluralized(stats.characters, singular: "character", plural: "characters"),
      pluralized(stats.words, singular: "word", plural: "words"),
      pluralized(stats.lines, singular: "line", plural: "lines")
    ].joined(separator: "  ·  ")
  }

  private func pointerTipProbe(in size: CGSize) -> some View {
    let inset = ShelfPreviewLayoutMetrics.pointerCenterInset
    let tipX = max(inset, min(appState.shelfPreview.pointerX, size.width - inset))
    let tipY = size.height - ShelfPreviewLayoutMetrics.pointerTipOffsetFromWindowBottom

    return Color.black.opacity(0.001)
      .frame(width: 2, height: 2)
      .position(x: tipX, y: tipY)
      .accessibilityElement()
      .accessibilityLabel("Pointer Tip")
      .accessibilityIdentifier("shelf-preview-pointer-tip")
      .allowsHitTesting(false)
  }

  @ViewBuilder
  private var previewContent: some View {
    if let item {
      if item.hasImage {
        AsyncView<NSImage?, _, _> {
          await item.asyncGetPreviewImage()
        } content: { image in
          if let image {
            Image(nsImage: image)
              .resizable()
              .scaledToFit()
              .padding(10)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            ProgressView()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        } placeholder: {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else {
        ScrollView {
          Text(item.item.previewableText)
            .font(.body)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
      }
    } else {
      Text("shelf_no_selection")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
  }

  var body: some View {
    ShelfPopoverShell(pointerX: appState.shelfPreview.pointerX) {
      Button {
        appState.shelfPreview.close()
      } label: {
        Image(systemName: "xmark")
          .font(.body.weight(.semibold))
      }
      .buttonStyle(ShelfPopoverButtonStyle())
      .accessibilityLabel("Close")
      .accessibilityIdentifier("shelf-preview-close")
    } title: {
      ShelfPopoverTitle(
        title: Text(LocalizedStringKey(item?.shelfTypeKey ?? "shelf_no_selection")),
        subtitle: footerText
      )
    } trailing: {
      Button {
        appState.shelfPreview.shareSelection()
      } label: {
        Image(systemName: "square.and.arrow.up")
          .font(.body.weight(.medium))
      }
      .buttonStyle(ShelfPopoverButtonStyle())
      .disabled(!appState.shelfPreview.canShareSelection)
      .accessibilityLabel("Share")
      .accessibilityIdentifier("shelf-preview-share")

      Button("Edit") {
        appState.shelfPreview.editSelection()
      }
      .buttonStyle(ShelfPopoverButtonStyle(prominent: true))
      .disabled(!appState.shelfPreview.canEditSelection)
      .accessibilityLabel("Edit")
      .accessibilityIdentifier("shelf-preview-edit")
    } content: {
      previewContent
    }
    .overlay {
      GeometryReader { geo in
        pointerTipProbe(in: geo.size)
      }
    }
  }
}

struct ShelfTextEditorPopupView: View {
  @Environment(AppState.self) private var appState
  @FocusState private var editorFocused: Bool

  private func pluralized(_ count: Int, singular: String, plural: String) -> String {
    if count == 1 {
      return "\(count) \(singular)"
    }
    return "\(count) \(plural)"
  }

  private var statsText: String {
    let value = appState.shelfPreview.editingText
    let words = value
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .count
    let lines = max(1, value.components(separatedBy: .newlines).count)
    return [
      pluralized(value.count, singular: "character", plural: "characters"),
      pluralized(words, singular: "word", plural: "words"),
      pluralized(lines, singular: "line", plural: "lines")
    ].joined(separator: "  ·  ")
  }

  var body: some View {
    ShelfPopoverShell(pointerX: appState.shelfPreview.editorPointerX) {
      Button("Cancel") {
        appState.shelfPreview.closeEditor()
      }
      .buttonStyle(ShelfPopoverButtonStyle())
      .accessibilityLabel("Cancel")
      .accessibilityIdentifier("shelf-text-editor-cancel")
    } title: {
      ShelfPopoverTitle(title: Text("Edit Text"), subtitle: statsText)
    } trailing: {
      Button("Save") {
        appState.shelfPreview.saveTextEditor()
      }
      .buttonStyle(ShelfPopoverButtonStyle(prominent: true))
      .keyboardShortcut(.defaultAction)
      .accessibilityLabel("Save")
      .accessibilityIdentifier("shelf-text-editor-save")
    } content: {
      TextEditor(
        text: Binding(
          get: { appState.shelfPreview.editingText },
          set: { appState.shelfPreview.updateEditingText($0) }
        )
      )
      .font(.body)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .focused($editorFocused)
      .foregroundStyle(.primary)
      .background(ShelfTextEditorAppearanceBridge())
    }
    .onAppear {
      DispatchQueue.main.async {
        editorFocused = true
      }
    }
  }
}

#Preview {
  ContentView()
    .environment(\.locale, .init(identifier: "en"))
    .modelContainer(Storage.shared.container)
}

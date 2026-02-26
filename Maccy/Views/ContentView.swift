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
    VStack(spacing: 10) {
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
    .padding(.vertical, 14)
    .onAppear {
      appState.shelfPreview.closeAll()
      appState.history.selectTag(nil)
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
    let allChip = TagChip(
      id: "all",
      title: NSLocalizedString("shelf_tag_all", comment: ""),
      color: .white.opacity(0.95),
      tagID: nil
    )
    let tagChips = appState.history.tags.map { tag in
      TagChip(
        id: normalizedTagIdentifier(tag.name),
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

  private var dotRailWidth: CGFloat {
    CGFloat(chips.count) * 20
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
    let maxAllowed = max(210, availableWidth - trailingActionsInset - dotRailWidth - 44)
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
      return "shelf-tag-dot-\(chip.id)"
    case .full:
      return "shelf-tag-full-\(chip.id)"
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

      ZStack(alignment: .trailing) {
        HStack(spacing: 12) {
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

          HStack(spacing: tagPresentation == .dotOnly ? 14 : 4) {
            ForEach(chips) { chip in
              tagButton(for: chip, presentation: tagPresentation)
            }
          }

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
      Task {
        appState.history.select(tappedItem)
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
            .padding(.vertical, 10)
          }
          .frame(height: 248)
          .accessibilityIdentifier("shelf-carousel")
          .background(alignment: .topLeading) {
            ShelfWheelBridge()
              .frame(width: 0, height: 0)
          }
          .onAppear {
            if let selectedId = appState.navigator.leadSelection {
              proxy.scrollTo(selectedId, anchor: .center)
            }
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
    .frame(minHeight: 248)
  }
}

private struct ShelfCardView: View {
  @Bindable var item: HistoryItemDecorator
  let isSelected: Bool
  let onCardTap: (UUID) -> Void
  @Environment(AppState.self) private var appState

  var body: some View {
    Button {
      onCardTap(item.id)
    } label: {
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
          if let image = item.thumbnailImage {
            GeometryReader { geometry in
              let containerWidth = geometry.size.width
              let safeImageWidth = max(image.size.width, 1)
              let renderedImageHeight = containerWidth * image.size.height / safeImageWidth

              Image(nsImage: image)
                .resizable()
                // Keep the top of screenshots visible; crop from the bottom when needed.
                .frame(width: containerWidth, height: renderedImageHeight, alignment: .top)
                .frame(width: containerWidth, height: geometry.size.height, alignment: .top)
            }
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
      .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .background {
        ShelfCardFrameReporter(itemID: item.id)
      }
    }
    .buttonStyle(.plain)
    .draggable(item.id.uuidString)
    .accessibilityIdentifier("shelf-card")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: item.title.isEmpty ? item.text.shortened(to: 80) : item.title.shortened(to: 80)))
    .accessibilityValue(Text(verbatim: isSelected ? "selected" : "unselected"))
    .contextMenu {
      if item.isTagged {
        Button("shelf_tag_remove_item") {
          appState.history.removeTag(from: item)
        }
      }
    }
    .onAppear {
      item.ensureThumbnailImage()
    }
    .onDisappear {
      appState.shelfPreview.removeCardFrame(itemID: item.id)
    }
  }
}

private struct ShelfCardFrameReporter: NSViewRepresentable {
  let itemID: UUID
  @Environment(AppState.self) private var appState

  func makeNSView(context: Context) -> ReporterView {
    let view = ReporterView()
    view.itemID = itemID
    view.appState = appState
    return view
  }

  func updateNSView(_ nsView: ReporterView, context: Context) {
    nsView.itemID = itemID
    nsView.appState = appState
    nsView.reportFrame()
  }

  static func dismantleNSView(_ nsView: ReporterView, coordinator: ()) {
    if let itemID = nsView.itemID {
      AppState.shared.shelfPreview.removeCardFrame(itemID: itemID)
    }
  }

  final class ReporterView: NSView {
    weak var appState: AppState?
    var itemID: UUID?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      reportFrame()
    }

    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      reportFrame()
    }

    override func layout() {
      super.layout()
      reportFrame()
    }

    func reportFrame() {
      guard let appState,
            let itemID,
            let window else {
        return
      }

      let frameInWindow = convert(bounds, to: nil)
      let frameInScreen = window.convertToScreen(frameInWindow)
      appState.shelfPreview.updateCardFrame(itemID: itemID, frame: frameInScreen)
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

private struct ShelfPreviewPointerShape: Shape {
  func path(in rect: CGRect) -> Path {
    let tip = CGPoint(x: rect.midX, y: rect.maxY)
    let leftControl1 = CGPoint(x: rect.minX + rect.width * 0.20, y: rect.minY)
    let leftControl2 = CGPoint(x: rect.midX - rect.width * 0.24, y: rect.maxY * 0.9)
    let rightControl1 = CGPoint(x: rect.midX + rect.width * 0.24, y: rect.maxY * 0.9)
    let rightControl2 = CGPoint(x: rect.maxX - rect.width * 0.20, y: rect.minY)

    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addCurve(to: tip, control1: leftControl1, control2: leftControl2)
    path.addCurve(
      to: CGPoint(x: rect.maxX, y: rect.minY),
      control1: rightControl1,
      control2: rightControl2
    )
    path.closeSubpath()
    return path
  }
}

private struct ShelfPreviewPointerOutlineShape: Shape {
  func path(in rect: CGRect) -> Path {
    let tip = CGPoint(x: rect.midX, y: rect.maxY)
    let leftControl1 = CGPoint(x: rect.minX + rect.width * 0.20, y: rect.minY)
    let leftControl2 = CGPoint(x: rect.midX - rect.width * 0.24, y: rect.maxY * 0.9)
    let rightControl1 = CGPoint(x: rect.midX + rect.width * 0.24, y: rect.maxY * 0.9)
    let rightControl2 = CGPoint(x: rect.maxX - rect.width * 0.20, y: rect.minY)

    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addCurve(to: tip, control1: leftControl1, control2: leftControl2)
    path.addCurve(
      to: CGPoint(x: rect.maxX, y: rect.minY),
      control1: rightControl1,
      control2: rightControl2
    )
    return path
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

    if let image = item.item.image {
      return "\(Int(image.size.width)) x \(Int(image.size.height))"
    }

    let stats = textStats
    return [
      pluralized(stats.characters, singular: "character", plural: "characters"),
      pluralized(stats.words, singular: "word", plural: "words"),
      pluralized(stats.lines, singular: "line", plural: "lines")
    ].joined(separator: "  ·  ")
  }

  @ViewBuilder
  private var previewContent: some View {
    if let item {
      if item.hasImage {
        AsyncView<NSImage?, _, _> {
          await item.asyncGetPreviewImage()
        } content: { image in
          Group {
            if let image {
              Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
              ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
          }
        } placeholder: {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
      } else {
        ScrollView {
          Text(item.item.previewableText)
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.82))
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
    } else {
      Text("shelf_no_selection")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          Button {
            appState.shelfPreview.close()
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.title3)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Close")
          .accessibilityIdentifier("shelf-preview-close")

          Text(LocalizedStringKey(item?.shelfTypeKey ?? "shelf_no_selection"))
            .font(.headline)
            .lineLimit(1)

          Spacer(minLength: 0)

          Button {
            appState.shelfPreview.shareSelection()
          } label: {
            Image(systemName: "square.and.arrow.up")
              .font(.title3)
          }
          .buttonStyle(.plain)
          .disabled(!appState.shelfPreview.canShareSelection)
          .accessibilityLabel("Share")
          .accessibilityIdentifier("shelf-preview-share")

          Button {
            appState.shelfPreview.editSelection()
          } label: {
            Text("Edit")
              .font(.headline)
          }
          .buttonStyle(.plain)
          .disabled(!appState.shelfPreview.canEditSelection)
          .accessibilityLabel("Edit")
          .accessibilityIdentifier("shelf-preview-edit")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        Divider()

        previewContent
          .padding(14)
          .frame(maxWidth: .infinity, maxHeight: .infinity)

        Divider()

        HStack {
          Text(verbatim: footerText)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
      }
      .background(.ultraThickMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .strokeBorder(.white.opacity(0.26), lineWidth: 1)
      }

      GeometryReader { geo in
        let pointerWidth: CGFloat = 42
        let pointerHeight: CGFloat = 16
        let pointerInset: CGFloat = 10
        let pointerOffset = max(
          pointerInset,
          min(appState.shelfPreview.pointerX - pointerWidth / 2, geo.size.width - pointerWidth - pointerInset)
        )

        ShelfPreviewPointerShape()
          .fill(.ultraThickMaterial)
          .frame(width: pointerWidth, height: pointerHeight)
          .overlay {
            ShelfPreviewPointerOutlineShape()
              .stroke(
                .white.opacity(0.26),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
              )
          }
          .offset(x: pointerOffset, y: -0.5)
      }
      .frame(height: 15)
    }
    .padding(6)
    .background(Color.clear)
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
    VStack(spacing: 0) {
      HStack {
        Text("Edit Text")
          .font(.headline)

        Spacer(minLength: 0)

        Button("Cancel") {
          appState.shelfPreview.closeEditor()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel")
        .accessibilityIdentifier("shelf-text-editor-cancel")

        Button("Save") {
          appState.shelfPreview.saveTextEditor()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .accessibilityLabel("Save")
        .accessibilityIdentifier("shelf-text-editor-save")
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 11)

      Divider()

      TextEditor(
        text: Binding(
          get: { appState.shelfPreview.editingText },
          set: { appState.shelfPreview.updateEditingText($0) }
        )
      )
      .font(.body)
      .padding(10)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .focused($editorFocused)
      .background(Color.black.opacity(0.83))
      .foregroundStyle(.white)

      Divider()

      HStack {
        Text(verbatim: statsText)
          .font(.callout)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
    }
    .background(.ultraThickMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(.white.opacity(0.26), lineWidth: 1)
    }
    .padding(6)
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

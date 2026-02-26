// swiftlint:disable file_length
import AppKit.NSRunningApplication
import Defaults
import Foundation
import Logging
import Observation
import Sauce
import Settings
import SwiftData

@Observable
class History: ItemsContainer { // swiftlint:disable:this type_body_length
  static let shared = History()
  let logger = Logger(label: "org.p0deje.Maccy")

  var items: [HistoryItemDecorator] = []
  var pasteStack: PasteStack?
  var tags: [HistoryTag] = []
  var selectedTagID: UUID? {
    didSet {
      guard oldValue != selectedTagID else { return }

      applyCurrentFilters()
      if AppState.shared.shelfModeEnabled {
        AppState.shared.navigator.highlightShelfFirst()
      }
      AppState.shared.popup.needsResize = true
    }
  }

  var pinnedItems: [HistoryItemDecorator] { items.filter(\.isPinned) }
  var unpinnedItems: [HistoryItemDecorator] { items.filter(\.isUnpinned) }

  var searchQuery: String = "" {
    didSet {
      guard oldValue != searchQuery else { return }

      throttler.throttle { [self] in
        applyCurrentFilters()

        if searchQuery.isEmpty {
          if AppState.shared.shelfModeEnabled {
            AppState.shared.navigator.highlightShelfFirst()
          } else {
            AppState.shared.navigator.select(item: unpinnedItems.first)
          }
        } else {
          AppState.shared.navigator.highlightFirst()
        }

        AppState.shared.popup.needsResize = true
      }
    }
  }

  var pressedShortcutItem: HistoryItemDecorator? {
    guard let event = NSApp.currentEvent else {
      return nil
    }

    let modifierFlags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting(.capsLock)

    guard HistoryItemAction(modifierFlags) != .unknown else {
      return nil
    }

    let key = Sauce.shared.key(for: Int(event.keyCode))
    return items.first { $0.shortcuts.contains(where: { $0.key == key }) }
  }

  private let search = Search()
  private let sorter = Sorter()
  private let throttler = Throttler(minimumDelay: 0.2)

  @ObservationIgnored
  private var sessionLog: [Int: HistoryItem] = [:]

  // The distinction between `all` and `items` is the following:
  // - `all` stores all history items, even the ones that are currently hidden by a search
  // - `items` stores only visible history items, updated during a search
  @ObservationIgnored
  var all: [HistoryItemDecorator] = []

  init() {
    Task {
      for await _ in Defaults.updates(.pasteByDefault, initial: false) {
        updateShortcuts()
      }
    }

    Task {
      for await _ in Defaults.updates(.sortBy, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.pinTo, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.showSpecialSymbols, initial: false) {
        for item in items {
          await updateTitle(item: item, title: item.item.generateTitle())
        }
      }
    }

    Task {
      for await _ in Defaults.updates(.imageMaxHeight, initial: false) {
        for item in items {
          await item.cleanupImages()
        }
      }
    }
  }

  @MainActor
  func load() async throws {
    let descriptor = FetchDescriptor<HistoryItem>()
    let results = try Storage.shared.context.fetch(descriptor)
    all = sorter.sort(results).map { HistoryItemDecorator($0) }
    loadTags()

    limitHistorySize(to: Defaults[.size])
    applyCurrentFilters()

    updateShortcuts()
    // Ensure that panel size is proper *after* loading all items.
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  private func limitHistorySize(to maxSize: Int) {
    let unpinned = all.filter(\.isUnpinned)
    if unpinned.count >= maxSize {
      unpinned[maxSize...].forEach(delete)
    }
  }

  @MainActor
  func insertIntoStorage(_ item: HistoryItem) throws {
    logger.info("Inserting item with id '\(item.title)'")
    Storage.shared.context.insert(item)
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()
  }

  @discardableResult
  @MainActor
  func add(_ item: HistoryItem) -> HistoryItemDecorator {
    if #available(macOS 15.0, *) {
      try? History.shared.insertIntoStorage(item)
    } else {
      // On macOS 14 the history item needs to be inserted into storage directly after creating it.
      // It was already inserted after creation in Clipboard.swift
    }

    var removedItemIndex: Int?
    if let existingHistoryItem = findSimilarItem(item) {
      if isModified(item) == nil {
        item.contents = existingHistoryItem.contents
      }
      item.firstCopiedAt = existingHistoryItem.firstCopiedAt
      item.numberOfCopies += existingHistoryItem.numberOfCopies
      item.pin = existingHistoryItem.pin
      item.title = existingHistoryItem.title
      item.tag = existingHistoryItem.tag
      if !item.fromMaccy {
        item.application = existingHistoryItem.application
      }
      logger.info("Removing duplicate item '\(item.title)'")
      Storage.shared.context.delete(existingHistoryItem)
      removedItemIndex = all.firstIndex(where: { $0.item == existingHistoryItem })
      if let removedItemIndex {
        all.remove(at: removedItemIndex)
      }
    } else {
      Task {
        Notifier.notify(body: item.title, sound: .write)
      }
    }

    // Remove exceeding items. Do this after the item is added to avoid removing something
    // if a duplicate was found as then the size already stayed the same.
    limitHistorySize(to: Defaults[.size] - 1)

    sessionLog[Clipboard.shared.changeCount] = item

    var itemDecorator: HistoryItemDecorator
    if let pin = item.pin {
      itemDecorator = HistoryItemDecorator(item, shortcuts: KeyShortcut.create(character: pin))
      // Keep pins in the same place.
      if let removedItemIndex {
        all.insert(itemDecorator, at: removedItemIndex)
      }
    } else {
      itemDecorator = HistoryItemDecorator(item)

      let sortedItems = sorter.sort(all.map(\.item) + [item])
      if let index = sortedItems.firstIndex(of: item) {
        all.insert(itemDecorator, at: index)
      }

      AppState.shared.popup.needsResize = true
    }

    applyCurrentFilters()
    updateUnpinnedShortcuts()
    AppState.shared.popup.needsResize = true

    return itemDecorator
  }

  @MainActor
  private func withLogging(_ msg: String, _ block: () throws -> Void) rethrows {
    func dataCounts() -> String {
      let historyItemCount = try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItem>())
      let historyContentCount = try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItemContent>())
      return "HistoryItem=\(historyItemCount ?? 0) HistoryItemContent=\(historyContentCount ?? 0)"
    }

    logger.info("\(msg) Before: \(dataCounts())")
    try? block()
    logger.info("\(msg) After: \(dataCounts())")
  }

  @MainActor
  func clear() {
    withLogging("Clearing history") {
      all.forEach { item in
        if item.isUnpinned {
          cleanup(item)
        }
      }
      all.removeAll(where: \.isUnpinned)
      sessionLog.removeValues { $0.pin == nil }
      applyCurrentFilters()

      try? Storage.shared.context.transaction {
        try? Storage.shared.context.delete(
          model: HistoryItem.self,
          where: #Predicate { $0.pin == nil }
        )
        try? Storage.shared.context.delete(
          model: HistoryItemContent.self,
          where: #Predicate { $0.item?.pin == nil }
        )
      }
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func clearAll() {
    withLogging("Clearing all history") {
      all.forEach { item in
        cleanup(item)
      }
      all.removeAll()
      sessionLog.removeAll()
      applyCurrentFilters()

      try? Storage.shared.context.delete(model: HistoryItem.self)
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func delete(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    cleanup(item)
    withLogging("Removing history item") {
      Storage.shared.context.delete(item.item)
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }

    all.removeAll { $0 == item }
    sessionLog.removeValues { $0 == item.item }

    applyCurrentFilters()
    updateUnpinnedShortcuts()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  @discardableResult
  func updateTextContent(for itemID: UUID, newValue: String) -> Bool {
    guard let item = all.first(where: { $0.id == itemID }) else {
      return false
    }

    let plainTextType = NSPasteboard.PasteboardType.string.rawValue
    let removableTypes: Set<String> = [
      NSPasteboard.PasteboardType.string.rawValue,
      NSPasteboard.PasteboardType.rtf.rawValue,
      NSPasteboard.PasteboardType.html.rawValue
    ]
    item.item.contents.removeAll { removableTypes.contains($0.type) }

    if let data = newValue.data(using: .utf8) {
      if let existingIndex = item.item.contents.firstIndex(where: { $0.type == plainTextType }) {
        item.item.contents[existingIndex].value = data
      } else {
        item.item.contents.append(
          HistoryItemContent(type: plainTextType, value: data)
        )
      }
    }

    item.item.title = item.item.generateTitle()
    item.title = item.item.title
    item.attributedTitle = nil

    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()

    applyCurrentFilters()
    AppState.shared.popup.needsResize = true

    return true
  }

  @MainActor
  @discardableResult
  func replaceImageContent(
    for itemID: UUID,
    imageData: Data,
    type: NSPasteboard.PasteboardType = .png
  ) -> Bool {
    guard let item = all.first(where: { $0.id == itemID }) else {
      return false
    }

    let removableTypes: Set<String> = [
      NSPasteboard.PasteboardType.tiff.rawValue,
      NSPasteboard.PasteboardType.png.rawValue,
      NSPasteboard.PasteboardType.jpeg.rawValue,
      NSPasteboard.PasteboardType.heic.rawValue
    ]
    item.item.contents.removeAll { removableTypes.contains($0.type) }
    item.item.contents.append(
      HistoryItemContent(type: type.rawValue, value: imageData)
    )

    item.item.title = item.item.generateTitle()
    item.title = item.item.title
    item.attributedTitle = nil
    item.cleanupImages()
    item.ensureThumbnailImage()

    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()

    applyCurrentFilters()
    AppState.shared.popup.needsResize = true

    return true
  }

  @MainActor
  private func cleanup(_ item: HistoryItemDecorator) {
    item.cleanupImages()
  }

  private func currentModifierFlags() -> NSEvent.ModifierFlags {
    return NSApp.currentEvent?.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function]) ?? []
  }

  @MainActor
  func select(_ item: HistoryItemDecorator?) {
    guard let item else {
      return
    }

    let modifierFlags = currentModifierFlags()

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
      Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      if Defaults[.pasteByDefault] {
        Clipboard.shared.paste()
      }
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .paste:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
        Clipboard.shared.paste()
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
  }

  @MainActor
  func startPasteStack(selection: inout Selection<HistoryItemDecorator>) {
    guard AppState.shared.multiSelectionEnabled else { return }
    guard let item = selection.first else { return }
    PasteStack.initializeIfNeeded()

    let modifierFlags = currentModifierFlags()

    let stack = PasteStack(items: selection.items, modifierFlags: modifierFlags)
    pasteStack = stack

    logger.info("Initialising PasteStack with \(stack.items.count) items")
    logger.info("Copying \(item.item.title) from PasteStack")

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
      Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .paste:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
  }

  func handlePasteStack() {
    guard let stack = pasteStack else {
      return
    }

    guard let pasted = stack.items.first else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("PasteStack pasted \(pasted.item.title)")

    stack.items.removeFirst()

    guard let item = stack.items.first else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("Copying \(item.item.title) from PasteStack. \(stack.items.count) items remaining in stack.")

    Task {
      if stack.modifierFlags.isEmpty {
        await Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      } else {
        switch HistoryItemAction(stack.modifierFlags) {
        case .copy:
          await Clipboard.shared.copy(item.item)
        case .paste:
          await Clipboard.shared.copy(item.item)
        case .pasteWithoutFormatting:
          await Clipboard.shared.copy(item.item, removeFormatting: true)
        case .unknown:
          return
        }
      }
    }
  }

  func interruptPasteStack() {
    guard pasteStack != nil else {
      return
    }
    logger.info("Interrupting PasteStack")
    pasteStack = nil
  }

  @MainActor
  func togglePin(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    item.togglePin()

    let sortedItems = sorter.sort(all.map(\.item))
    if let currentIndex = all.firstIndex(of: item),
       let newIndex = sortedItems.firstIndex(of: item.item) {
      all.remove(at: currentIndex)
      all.insert(item, at: newIndex)
    }

    applyCurrentFilters()

    searchQuery = ""
    updateUnpinnedShortcuts()
    if item.isUnpinned {
      AppState.shared.navigator.scrollTarget = item.id
    }
  }

  @MainActor
  private func findSimilarItem(_ item: HistoryItem) -> HistoryItem? {
    let descriptor = FetchDescriptor<HistoryItem>()
    if let all = try? Storage.shared.context.fetch(descriptor) {
      let duplicates = all.filter({ $0 == item || $0.supersedes(item) })
      if duplicates.count > 1 {
        return duplicates.first(where: { $0 != item })
      } else {
        return isModified(item)
      }
    }

    return item
  }

  private func isModified(_ item: HistoryItem) -> HistoryItem? {
    if let modified = item.modified, sessionLog.keys.contains(modified) {
      return sessionLog[modified]
    }

    return nil
  }

  @MainActor
  func selectTag(_ id: UUID?) {
    selectedTagID = id
  }

  @MainActor
  @discardableResult
  func createTag(name: String, color: ShelfTagColor) -> HistoryTag? {
    let normalizedName = normalizeTagName(name)
    guard !normalizedName.isEmpty else { return nil }
    guard isTagNameAvailable(normalizedName) else { return nil }

    let tag = HistoryTag(name: normalizedName, colorKey: color.rawValue)
    Storage.shared.context.insert(tag)
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()
    loadTags()
    AppState.shared.popup.needsResize = true

    return tag
  }

  @MainActor
  @discardableResult
  func renameTag(id: UUID, to newName: String) -> Bool {
    guard let tag = tags.first(where: { $0.id == id }) else { return false }

    let normalizedName = normalizeTagName(newName)
    guard !normalizedName.isEmpty else { return false }
    guard isTagNameAvailable(normalizedName, excludingID: id) else { return false }

    tag.name = normalizedName
    tag.updatedAt = Date.now
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()
    loadTags()
    AppState.shared.popup.needsResize = true

    return true
  }

  @MainActor
  func deleteTag(id: UUID) {
    guard let tag = tags.first(where: { $0.id == id }) else { return }

    if selectedTagID == id {
      selectedTagID = nil
    }

    Storage.shared.context.delete(tag)
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()
    loadTags()
    applyCurrentFilters()
    AppState.shared.popup.needsResize = true
  }

  @MainActor
  @discardableResult
  func assignTag(tagID: UUID, toItemID itemID: UUID) -> Bool {
    guard let item = all.first(where: { $0.id == itemID }) else { return false }
    guard let tag = tags.first(where: { $0.id == tagID }) else { return false }

    item.item.tag = tag
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()
    applyCurrentFilters()

    return true
  }

  @MainActor
  func removeTag(from item: HistoryItemDecorator) {
    item.item.tag = nil
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()
    applyCurrentFilters()
  }

  @MainActor
  func isTagNameAvailable(_ name: String, excludingID: UUID? = nil) -> Bool {
    let normalizedName = normalizeTagName(name)
    guard !normalizedName.isEmpty else { return false }

    return !tags.contains { tag in
      guard tag.id != excludingID else { return false }
      return tag.name.compare(normalizedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
  }

  @MainActor
  func normalizeTagName(_ value: String) -> String {
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @MainActor
  private func loadTags() {
    let descriptor = FetchDescriptor<HistoryTag>(
      sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.name)]
    )
    tags = (try? Storage.shared.context.fetch(descriptor)) ?? []

    if let selectedTagID, !tags.contains(where: { $0.id == selectedTagID }) {
      self.selectedTagID = nil
    }
  }

  private func filteredItemsByTag() -> [HistoryItemDecorator] {
    guard AppState.shared.shelfModeEnabled, let selectedTagID else {
      return all
    }

    return all.filter { $0.item.tag?.id == selectedTagID }
  }

  private func applyCurrentFilters() {
    let searched = search.search(string: searchQuery, within: filteredItemsByTag())
    updateItems(searched, query: searchQuery)
  }

  private func updateItems(_ newItems: [Search.SearchResult], query: String) {
    items = newItems.map { result in
      let item = result.object
      item.highlight(query, result.ranges)

      return item
    }

    updateUnpinnedShortcuts()
  }

  private func updateShortcuts() {
    for item in pinnedItems {
      if let pin = item.item.pin {
        item.shortcuts = KeyShortcut.create(character: pin)
      }
    }

    updateUnpinnedShortcuts()
  }

  @MainActor
  private func updateTitle(item: HistoryItemDecorator, title: String) {
    item.title = title
    item.item.title = title
  }

  private func updateUnpinnedShortcuts() {
    let visibleUnpinnedItems = unpinnedItems.filter(\.isVisible)
    for item in visibleUnpinnedItems {
      item.shortcuts = []
    }

    var index = 1
    for item in visibleUnpinnedItems.prefix(9) {
      item.shortcuts = KeyShortcut.create(character: String(index))
      index += 1
    }
  }
}

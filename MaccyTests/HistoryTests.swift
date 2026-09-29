import AppKit
import Defaults
import SwiftData
import XCTest
@testable import Maccy

@MainActor
class HistoryTests: XCTestCase { // swiftlint:disable:this type_body_length
  let savedSize = Defaults[.size]
  let savedSortBy = Defaults[.sortBy]
  let savedPopupLayoutMode = Defaults[.popupLayoutMode]
  let savedSearchMode = Defaults[.searchMode]
  let savedShelfPreviewImageEditorBundleID = Defaults[.shelfPreviewImageEditorBundleID]
  let savedPinTo = Defaults[.pinTo]
  let history = History.shared

  override func setUp() {
    super.setUp()
    history.clearAll()
    try? Storage.shared.context.delete(model: HistoryTag.self)
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()
    history.tags.removeAll()
    history.selectTag(nil)
    Defaults[.size] = 10
    Defaults[.sortBy] = .firstCopiedAt
    Defaults[.popupLayoutMode] = .list
    Defaults[.searchMode] = .exact
    Defaults[.shelfPreviewImageEditorBundleID] = nil
    Defaults[.pinTo] = .bottom
  }

  override func tearDown() {
    super.tearDown()
    Defaults[.size] = savedSize
    Defaults[.sortBy] = savedSortBy
    Defaults[.popupLayoutMode] = savedPopupLayoutMode
    Defaults[.searchMode] = savedSearchMode
    Defaults[.shelfPreviewImageEditorBundleID] = savedShelfPreviewImageEditorBundleID
    Defaults[.pinTo] = savedPinTo
  }

  func testDefaultIsEmpty() {
    XCTAssertEqual(history.items, [])
  }

  func testAdding() {
    let first = history.add(historyItem("foo"))
    let second = history.add(historyItem("bar"))
    XCTAssertEqual(history.items, [second, first])
  }

  func testAddingPersistedDuplicate() throws {
    let first = historyItem("foo")
    first.title = "xyz"
    first.application = "iTerm.app"
    let firstDecorator = history.add(first)
    first.pin = "f"

    let third = historyItem("foo")
    third.application = "Xcode.app"
    let transferredContents = first.contents
    let merged = history.add(third)

    XCTAssertEqual(history.all, [merged])
    XCTAssertEqual(Set(merged.item.contents), Set(transferredContents))
    XCTAssertTrue(merged.item.lastCopiedAt > merged.item.firstCopiedAt)
    XCTAssertEqual(merged.item.numberOfCopies, 2)
    XCTAssertEqual(merged.item.pin, "f")
    XCTAssertEqual(merged.item.title, "xyz")
    XCTAssertEqual(merged.item.application, "iTerm.app")
    try assertStorageCounts(items: 1, contents: 1)
  }

  func testAddingUnsavedDuplicate() throws {
    guard #available(macOS 15.0, *) else {
      throw XCTSkip("Incoming history items are inserted before add on macOS 14")
    }

    let first = historyItem("foo")
    first.title = "xyz"
    first.application = "iTerm.app"
    history.add(first)
    first.pin = "f"

    let second = historyItem("foo", persisted: false)
    second.application = "Xcode.app"
    let transferredContents = first.contents
    let merged = history.add(second)

    XCTAssertEqual(history.all, [merged])
    XCTAssertEqual(Set(merged.item.contents), Set(transferredContents))
    XCTAssertTrue(merged.item.lastCopiedAt > merged.item.firstCopiedAt)
    XCTAssertEqual(merged.item.numberOfCopies, 2)
    XCTAssertEqual(merged.item.pin, "f")
    XCTAssertEqual(merged.item.title, "xyz")
    XCTAssertEqual(merged.item.application, "iTerm.app")
    try assertStorageCounts(items: 1, contents: 1)
  }

  func testAddingItemThatIsSupersededByExisting() throws {
    let firstContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.rtf.rawValue,
        value: "two".data(using: .utf8)!
      )
    ]
    let firstItem = HistoryItem()
    Storage.shared.context.insert(firstItem)
    firstItem.application = "Maccy.app"
    firstItem.contents = firstContents
    firstItem.title = firstItem.generateTitle()
    history.add(firstItem)

    let secondContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      )
    ]
    let secondItem = HistoryItem()
    Storage.shared.context.insert(secondItem)
    secondItem.application = "Maccy.app"
    secondItem.contents = secondContents
    secondItem.title = secondItem.generateTitle()
    let second = history.add(secondItem)

    XCTAssertEqual(history.items, [second])
    XCTAssertEqual(Set(history.items[0].item.contents), Set(firstContents))
    try assertStorageCounts(items: 1, contents: firstContents.count)
  }

  func testAddingItemWithDifferentModifiedType() {
    let firstContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.modified.rawValue,
        value: "1".data(using: .utf8)!
      )
    ]
    let firstItem = HistoryItem()
    Storage.shared.context.insert(firstItem)
    firstItem.contents = firstContents
    history.add(firstItem)

    let secondContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.modified.rawValue,
        value: "2".data(using: .utf8)!
      )
    ]
    let secondItem = HistoryItem()
    Storage.shared.context.insert(secondItem)
    secondItem.contents = secondContents
    let second = history.add(secondItem)

    XCTAssertEqual(history.items, [second])
    XCTAssertEqual(Set(history.items[0].item.contents), Set(firstContents))
  }

  func testAddingItemFromMaccy() {
    let firstContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)
      )
    ]
    let first = HistoryItem()
    Storage.shared.context.insert(first)
    first.application = "Xcode.app"
    first.contents = firstContents
    history.add(first)

    let secondContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.fromMaccy.rawValue,
        value: "".data(using: .utf8)
      )
    ]
    let second = HistoryItem()
    Storage.shared.context.insert(second)
    second.application = "Maccy.app"
    second.contents = secondContents
    let secondDecorator = history.add(second)

    XCTAssertEqual(history.items, [secondDecorator])
    XCTAssertEqual(history.items[0].item.application, "Xcode.app")
    XCTAssertEqual(Set(history.items[0].item.contents), Set(firstContents))
  }

  func testModifiedAfterCopying() {
    history.add(historyItem("foo"))

    let modifiedItem = historyItem("bar")
    modifiedItem.contents.append(HistoryItemContent(
      type: NSPasteboard.PasteboardType.modified.rawValue,
      value: String(Clipboard.shared.changeCount).data(using: .utf8)
    ))
    let modifiedItemDecorator = history.add(modifiedItem)

    XCTAssertEqual(history.items, [modifiedItemDecorator])
    XCTAssertEqual(history.items[0].text, "bar")
  }

  func testClearingUnpinned() throws {
    let pinned = history.add(historyItem("foo"))
    pinned.togglePin()
    history.add(historyItem("bar"))
    let orphan = HistoryItemContent(
      type: NSPasteboard.PasteboardType.string.rawValue,
      value: "orphan".data(using: .utf8)
    )
    Storage.shared.context.insert(orphan)
    try Storage.shared.context.save()

    history.clear()

    XCTAssertEqual(history.items, [pinned])
    try assertStorageCounts(items: 1, contents: 1)
  }

  func testClearingAll() throws {
    history.add(historyItem("foo"))
    let pinned = history.add(historyItem("bar"))
    pinned.togglePin()
    Storage.shared.context.insert(HistoryItemContent(
      type: NSPasteboard.PasteboardType.string.rawValue,
      value: "orphan".data(using: .utf8)
    ))
    try Storage.shared.context.save()

    history.clearAll()

    XCTAssertEqual(history.items, [])
    try assertStorageCounts(items: 0, contents: 0)
  }

  func testMaxSize() throws {
    var items: [HistoryItemDecorator] = []
    for index in 0...10 {
      items.append(history.add(historyItem(String(index))))
    }

    XCTAssertEqual(history.items.count, 10)
    XCTAssertTrue(history.items.contains(items[10]))
    XCTAssertFalse(history.items.contains(items[0]))
    try assertStorageCounts(items: 10, contents: 10)
  }

  func testMaxSizeIgnoresPinned() {
    var items: [HistoryItemDecorator] = []

    let item = history.add(historyItem("0"))
    items.append(item)
    item.togglePin()

    for index in 1...11 {
      items.append(history.add(historyItem(String(index))))
    }

    XCTAssertEqual(history.items.count, 11)
    XCTAssertTrue(history.items.contains(items[10]))
    XCTAssertTrue(history.items.contains(items[0]))
    XCTAssertFalse(history.items.contains(items[1]))
  }

  func testMaxSizeIsChanged() {
    var items: [HistoryItemDecorator] = []
    for index in 0...10 {
      items.append(history.add(historyItem(String(index))))
    }
    Defaults[.size] = 5
    history.add(historyItem("11"))

    XCTAssertEqual(history.items.count, 5)
    XCTAssertTrue(history.items.contains(items[10]))
    XCTAssertFalse(history.items.contains(items[5]))
  }

  func testReaddingBottomMostPinnedItemAtFullCapacity() {
    // Regression test for a crash when re-copying (invoking) the bottom-most
    // pinned item while history is at full capacity and pins are sorted to the
    // bottom. The stale insert index used to trap with an out-of-bounds insert.
    // Issue link: https://github.com/p0deje/Maccy/issues/1466
    // `pinTo` is restored to its default value(.top) in `tearDown`.
    Defaults[.pinTo] = .bottom

    // Pin an item; `history.togglePin` re-sorts `all`, so with `.bottom` the
    // pinned item ends up as the last element.
    let pinned = history.add(historyItem("pinned"))
    history.togglePin(pinned)

    // Fill unpinned history to full capacity.
    for index in 0..<Defaults[.size] {
      history.add(historyItem(String(index)))
    }

    XCTAssertEqual(history.all.last, pinned)

    // Re-copy the pinned item. It is detected as a duplicate, removed and
    // re-inserted while `limitHistorySize` trims an exceeding unpinned item.
    // Before the fix this inserted at a stale, out-of-bounds index and crashed.
    let readded = history.add(historyItem("pinned"))

    XCTAssertTrue(history.all.contains(readded))
    XCTAssertEqual(history.all.filter(\.isPinned).count, 1)
  }

  func testRemoving() throws {
    let foo = history.add(historyItem("foo"))
    let bar = history.add(historyItem("bar"))
    history.delete(foo)
    XCTAssertEqual(history.items, [bar])
    try assertStorageCounts(items: 1, contents: 1)
  }

  func testTagCRUD() {
    XCTAssertEqual(history.tags.count, 0)

    let created = history.createTag(name: "Work", color: .blue)
    XCTAssertNotNil(created)
    XCTAssertEqual(history.tags.count, 1)
    XCTAssertEqual(history.tags.first?.name, "Work")
    XCTAssertEqual(history.tags.first?.colorKey, ShelfTagColor.blue.rawValue)

    XCTAssertNil(history.createTag(name: "work", color: .teal))
    XCTAssertEqual(history.tags.count, 1)

    let renamed = history.renameTag(id: created!.id, to: "Inbox")
    XCTAssertTrue(renamed)
    XCTAssertEqual(history.tags.first?.name, "Inbox")

    history.deleteTag(id: created!.id)
    XCTAssertEqual(history.tags.count, 0)
  }

  func testAssignMoveAndRemoveTag() {
    let first = history.add(historyItem("foo"))
    let second = history.add(historyItem("bar"))
    let work = history.createTag(name: "Work", color: .emerald)!
    let code = history.createTag(name: "Code", color: .indigo)!

    XCTAssertTrue(history.assignTag(tagID: work.id, toItemID: first.id))
    XCTAssertEqual(first.item.tag?.id, work.id)
    XCTAssertNil(second.item.tag)

    XCTAssertTrue(history.assignTag(tagID: code.id, toItemID: first.id))
    XCTAssertEqual(first.item.tag?.id, code.id)

    history.removeTag(from: first)
    XCTAssertNil(first.item.tag)
  }

  func testRenameItemUpdatesTitle() {
    let first = history.add(historyItem("foo"))

    XCTAssertTrue(history.renameItem(id: first.id, to: "  Important Snippet  "))
    XCTAssertEqual(first.item.title, "Important Snippet")
    XCTAssertEqual(first.item.customTitle, "Important Snippet")
    XCTAssertEqual(first.title, "Important Snippet")
  }

  func testRenameItemRejectsEmptyTitles() {
    let first = history.add(historyItem("foo"))
    let originalTitle = first.title

    XCTAssertFalse(history.renameItem(id: first.id, to: "   "))
    XCTAssertEqual(first.title, originalTitle)
  }

  func testLoadBackfillsLegacyCustomTitle() async throws {
    let item = historyItem("foo")
    item.title = "Legacy title"
    item.customTitle = nil
    _ = history.add(item)

    try await history.load()

    let loaded = history.items.first(where: { $0.id == item.id })
    XCTAssertEqual(loaded?.item.customTitle, "Legacy title")
  }

  func testTagAndSearchFiltersIntersectInShelfMode() {
    Defaults[.popupLayoutMode] = .shelf

    let alpha = history.add(historyItem("alpha text"))
    let beta = history.add(historyItem("beta text"))
    let gamma = history.add(historyItem("gamma text"))
    let work = history.createTag(name: "Work", color: .orange)!
    let links = history.createTag(name: "Links", color: .teal)!

    XCTAssertTrue(history.assignTag(tagID: work.id, toItemID: alpha.id))
    XCTAssertTrue(history.assignTag(tagID: work.id, toItemID: beta.id))
    XCTAssertTrue(history.assignTag(tagID: links.id, toItemID: gamma.id))

    history.selectTag(work.id)
    XCTAssertEqual(Set(history.items.map(\.id)), Set([alpha.id, beta.id]))

    history.searchQuery = "alpha"
    waitForSearchThrottle()
    XCTAssertEqual(history.items.count, 1)
    XCTAssertEqual(history.items.first?.id, alpha.id)

    history.searchQuery = ""
    waitForSearchThrottle()
    XCTAssertEqual(Set(history.items.map(\.id)), Set([alpha.id, beta.id]))

    history.selectTag(nil)
    XCTAssertEqual(Set(history.items.map(\.id)), Set([alpha.id, beta.id, gamma.id]))
  }

  func testAddingSamePreservesTag() {
    let first = history.add(historyItem("foo"))
    let work = history.createTag(name: "Work", color: .blue)!
    XCTAssertTrue(history.assignTag(tagID: work.id, toItemID: first.id))

    _ = history.add(historyItem("foo"))

    XCTAssertEqual(history.items.count, 1)
    XCTAssertEqual(history.items.first?.item.tag?.id, work.id)
  }

  func testClearAllKeepsTags() {
    let first = history.add(historyItem("foo"))
    let work = history.createTag(name: "Work", color: .blue)!
    XCTAssertTrue(history.assignTag(tagID: work.id, toItemID: first.id))
    XCTAssertEqual(history.tags.count, 1)

    history.clearAll()

    XCTAssertEqual(history.items.count, 0)
    XCTAssertEqual(history.tags.count, 1)
    XCTAssertEqual(history.tags.first?.id, work.id)
  }

  func testShelfDeleteSelectionPrefersItemOnRight() {
    Defaults[.popupLayoutMode] = .shelf

    let oldest = history.add(historyItem("oldest"))
    let middle = history.add(historyItem("middle"))
    _ = history.add(historyItem("newest"))

    AppState.shared.navigator.select(item: middle)
    AppState.shared.deleteSelection()

    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem?.id, oldest.id)
  }

  func testShelfDeleteSelectionFallsBackToLeftWhenDeletingLastVisibleItem() {
    Defaults[.popupLayoutMode] = .shelf

    let oldest = history.add(historyItem("oldest"))
    let middle = history.add(historyItem("middle"))
    _ = history.add(historyItem("newest"))

    AppState.shared.navigator.select(item: oldest)
    AppState.shared.deleteSelection()

    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem?.id, middle.id)
  }

  func testShelfClosedSelectionMovesToNewestAfterClipboardCopy() {
    Defaults[.popupLayoutMode] = .shelf

    _ = history.add(historyItem("oldest"))
    let middle = history.add(historyItem("middle"))

    AppState.shared.navigator.select(item: middle)
    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem?.id, middle.id)

    history.handleNewClipboardCopy(historyItem("newest"))

    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem?.id, history.items.first?.id)
    XCTAssertNotEqual(AppState.shared.navigator.leadHistoryItem?.id, middle.id)
  }

  func testShelfClosedSelectionClearsWhenNewestClipboardCopyIsFilteredOut() {
    Defaults[.popupLayoutMode] = .shelf

    let taggedItem = history.add(historyItem("tagged"))
    let work = history.createTag(name: "Work", color: .blue)!
    XCTAssertTrue(history.assignTag(tagID: work.id, toItemID: taggedItem.id))
    history.selectTag(work.id)

    AppState.shared.navigator.select(item: taggedItem)
    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem?.id, taggedItem.id)

    history.handleNewClipboardCopy(historyItem("untagged"))

    XCTAssertNil(AppState.shared.navigator.leadHistoryItem)
  }

  func testLoadReusesExistingDecorators() async throws {
    let first = history.add(historyItem("foo"))
    history.add(historyItem("bar"))

    try await history.load()
    let reloaded = history.all.first { $0.id == first.id }

    XCTAssertTrue(reloaded === first)
  }

  func testDecoratorIsReleasedWhileItsItemIsAlive() {
    let item = historyItem("foo")
    weak var weakDecorator: HistoryItemDecorator?

    autoreleasepool {
      let decorator = HistoryItemDecorator(item)
      weakDecorator = decorator
    }

    XCTAssertNil(weakDecorator)
  }

  func testAddingSameDoesNotLeaveOrphanedContents() {
    history.add(historyItem("foo"))
    history.add(historyItem("foo"))
    history.add(historyItem("foo"))

    XCTAssertEqual(history.all.count, 1)
    XCTAssertEqual(orphanedContentCount(), 0)
  }

  func testUpdateTextContentDoesNotLeaveOrphanedContents() {
    let item = history.add(historyItem("foo"))

    history.updateTextContent(for: item.id, newValue: "bar")
    history.updateTextContent(for: item.id, newValue: "baz")

    XCTAssertEqual(item.item.text, "baz")
    XCTAssertEqual(item.item.contents.count, 1)
    XCTAssertEqual(orphanedContentCount(), 0)
  }

  func testReplaceImageContentDoesNotLeaveOrphanedContents() {
    let image = NSImage(named: "NSApplicationIcon")!
    let item = history.add(historyItem(image))
    let pngData = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!

    history.replaceImageContent(for: item.id, imageData: pngData)
    history.replaceImageContent(for: item.id, imageData: pngData)

    XCTAssertEqual(orphanedContentCount(), 0)
  }

  func testLoadPurgesOrphanedContents() async throws {
    let orphan = HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data("orphan".utf8))
    Storage.shared.context.insert(orphan)
    Storage.shared.context.processPendingChanges()
    try Storage.shared.context.save()
    XCTAssertEqual(orphanedContentCount(), 1)

    history.add(historyItem("foo"))
    try await history.load()

    XCTAssertEqual(orphanedContentCount(), 0)
    XCTAssertEqual(history.all.first?.item.text, "foo")
  }

  func testUpdateTextContentReplacesItemText() {
    let item = history.add(historyItem("foo"))

    let didUpdate = history.updateTextContent(for: item.id, newValue: "updated text")

    XCTAssertTrue(didUpdate)
    XCTAssertEqual(item.item.previewableText, "updated text")
    XCTAssertEqual(item.item.text, "updated text")
    XCTAssertEqual(item.item.contents.filter { $0.type == NSPasteboard.PasteboardType.string.rawValue }.count, 1)
  }

  func testUpdateTextContentDoesNotMutateSystemClipboard() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString("clipboard-sentinel", forType: .string)

    let item = history.add(historyItem("foo"))
    _ = history.updateTextContent(for: item.id, newValue: "edited value")

    XCTAssertEqual(pasteboard.string(forType: .string), "clipboard-sentinel")
  }

  func testReplaceImageContentUpdatesImageDimensions() {
    let original = NSImage(size: NSSize(width: 40, height: 40))
    original.lockFocus()
    NSColor.blue.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 40, height: 40)).fill()
    original.unlockFocus()

    let replacement = NSImage(size: NSSize(width: 120, height: 48))
    replacement.lockFocus()
    NSColor.red.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 120, height: 48)).fill()
    replacement.unlockFocus()

    let item = history.add(historyItem(original))
    let didReplace = history.replaceImageContent(
      for: item.id,
      imageData: replacement.tiffRepresentation ?? Data(),
      type: .tiff
    )

    XCTAssertTrue(didReplace)
    XCTAssertEqual(item.item.image?.size, replacement.size)
  }

  func testShelfPreviewImageEditorBundleIDRoundtrip() {
    let previous = Defaults[.shelfPreviewImageEditorBundleID]
    Defaults[.shelfPreviewImageEditorBundleID] = "com.apple.Preview"

    XCTAssertEqual(Defaults[.shelfPreviewImageEditorBundleID], "com.apple.Preview")

    Defaults[.shelfPreviewImageEditorBundleID] = nil
    XCTAssertNil(Defaults[.shelfPreviewImageEditorBundleID])
    Defaults[.shelfPreviewImageEditorBundleID] = previous
  }

  private func orphanedContentCount() -> Int {
    let descriptor = FetchDescriptor<HistoryItemContent>(predicate: #Predicate { $0.item == nil })
    return (try? Storage.shared.context.fetchCount(descriptor)) ?? -1
  }

  func testCleaningUpOrphanedContents() throws {
    let live = history.add(historyItem("live"))
    let liveContent = live.item.contents[0]
    for value in ["orphan-1", "orphan-2"] {
      Storage.shared.context.insert(HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value.data(using: .utf8)
      ))
    }
    try Storage.shared.context.save()

    XCTAssertEqual(Storage.shared.purgeOrphanedContents(), 2)
    XCTAssertEqual(Storage.shared.purgeOrphanedContents(), 0)
    XCTAssertEqual(live.item.contents, [liveContent])
    try assertStorageCounts(items: 1, contents: 1)
  }

  private func assertStorageCounts(
    items: Int,
    contents: Int,
    orphaned: Int = 0,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let context = Storage.shared.context
    context.processPendingChanges()
    try context.save()
    XCTAssertEqual(
      try context.fetchCount(FetchDescriptor<HistoryItem>()),
      items,
      file: file,
      line: line
    )
    XCTAssertEqual(
      try context.fetchCount(FetchDescriptor<HistoryItemContent>()),
      contents,
      file: file,
      line: line
    )
    XCTAssertEqual(
      try context.fetchCount(FetchDescriptor<HistoryItemContent>(
        predicate: #Predicate { $0.item == nil }
      )),
      orphaned,
      file: file,
      line: line
    )
  }

  private func historyItem(_ value: String, persisted: Bool = true) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value.data(using: .utf8)
      )
    ]
    let item = HistoryItem()
    if persisted {
      Storage.shared.context.insert(item)
    }
    item.contents = contents
    item.numberOfCopies = 1
    item.title = item.generateTitle()

    return item
  }

  private func historyItem(_ image: NSImage) -> HistoryItem {
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.tiff.rawValue,
        value: image.tiffRepresentation
      )
    ]
    item.numberOfCopies = 1
    item.title = item.generateTitle()

    return item
  }

  private func waitForSearchThrottle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.35))
  }
}

private final class FakeShelfPreviewAnchor: ShelfPreviewAnchor {
  var frame: NSRect?

  init(frame: NSRect?) {
    self.frame = frame
  }

  func currentFrameInScreen() -> NSRect? {
    return frame
  }
}

@MainActor
final class ShelfPreviewAnchorRegistryTests: XCTestCase {

  func testCurrentFrameReflectsLiveAnchorChanges() {
    let registry = ShelfPreviewAnchorRegistry()
    let itemID = UUID()
    let anchor = FakeShelfPreviewAnchor(frame: NSRect(x: 10, y: 20, width: 30, height: 40))

    registry.register(itemID: itemID, anchor: anchor)
    XCTAssertEqual(registry.currentFrame(for: itemID), anchor.frame)

    anchor.frame = NSRect(x: 50, y: 60, width: 70, height: 80)
    XCTAssertEqual(registry.currentFrame(for: itemID), anchor.frame)
  }

  func testCurrentFrameDoesNotFallbackToAnotherItemAfterUnregister() {
    let registry = ShelfPreviewAnchorRegistry()
    let firstItemID = UUID()
    let secondItemID = UUID()
    let firstAnchor = FakeShelfPreviewAnchor(frame: NSRect(x: 10, y: 20, width: 30, height: 40))
    let secondAnchor = FakeShelfPreviewAnchor(frame: NSRect(x: 110, y: 120, width: 130, height: 140))

    registry.register(itemID: firstItemID, anchor: firstAnchor)
    registry.register(itemID: secondItemID, anchor: secondAnchor)
    registry.unregister(itemID: firstItemID, anchor: firstAnchor)

    XCTAssertNil(registry.currentFrame(for: firstItemID))
    XCTAssertEqual(registry.currentFrame(for: secondItemID), secondAnchor.frame)
  }

  func testSyncVisibleShelfItemIDsPrunesRemovedAnchors() {
    let preview = ShelfPreview()
    let visibleItemID = UUID()
    let removedItemID = UUID()
    let visibleAnchor = FakeShelfPreviewAnchor(frame: NSRect(x: 10, y: 20, width: 30, height: 40))
    let removedAnchor = FakeShelfPreviewAnchor(frame: NSRect(x: 110, y: 120, width: 130, height: 140))

    preview.registerCardAnchor(itemID: visibleItemID, anchor: visibleAnchor)
    preview.registerCardAnchor(itemID: removedItemID, anchor: removedAnchor)
    preview.syncVisibleShelfItemIDs([visibleItemID])

    XCTAssertEqual(preview.currentCardFrame(for: visibleItemID), visibleAnchor.frame)
    XCTAssertNil(preview.currentCardFrame(for: removedItemID))
  }
}

final class ShelfPreviewPlacementTests: XCTestCase {
  func testPlacementCentersPointerWhenAnchorHasRoom() {
    let placement = ShelfPreview.computePreviewPlacement(
      preferredSize: NSSize(width: 700, height: 460),
      minimumSize: NSSize(width: 420, height: 200),
      selectedCardFrame: NSRect(x: 600, y: 60, width: 260, height: 220),
      carouselViewportFrame: NSRect(x: 0, y: 0, width: 1600, height: 300),
      screenFrame: NSRect(x: 0, y: 0, width: 1600, height: 900)
    )

    XCTAssertTrue(placement.isValid)
    XCTAssertTrue(placement.selectedCardIsFullyVisible)
    XCTAssertEqual(placement.frame.origin.x, 380, accuracy: 0.01)
    XCTAssertEqual(placement.pointerX, 350, accuracy: 0.01)
  }

  func testPlacementClampsPointerNearLeftEdge() {
    let placement = ShelfPreview.computePreviewPlacement(
      preferredSize: NSSize(width: 700, height: 460),
      minimumSize: NSSize(width: 420, height: 200),
      selectedCardFrame: NSRect(x: 0, y: 60, width: 40, height: 220),
      carouselViewportFrame: NSRect(x: 0, y: 0, width: 1600, height: 300),
      screenFrame: NSRect(x: 0, y: 0, width: 1600, height: 900)
    )

    XCTAssertTrue(placement.isValid)
    XCTAssertEqual(placement.frame.minX, ShelfPreviewLayoutMetrics.screenMargin, accuracy: 0.01)
    XCTAssertEqual(placement.pointerX, ShelfPreviewLayoutMetrics.pointerCenterInset, accuracy: 0.01)
  }

  func testPlacementShrinksHeightWhenVerticalSpaceIsLimited() {
    let screenFrame = NSRect(x: 0, y: 0, width: 1200, height: 500)
    let cardFrame = NSRect(x: 470, y: 60, width: 260, height: 220)
    let placement = ShelfPreview.computePreviewPlacement(
      preferredSize: NSSize(width: 700, height: 360),
      minimumSize: NSSize(width: 420, height: 200),
      selectedCardFrame: cardFrame,
      carouselViewportFrame: NSRect(x: 0, y: 0, width: 1200, height: 320),
      screenFrame: screenFrame
    )

    let expectedOriginY = cardFrame.maxY - ShelfPreviewLayoutMetrics.pointerTipOffsetFromWindowBottom
    let expectedAvailableHeight = screenFrame.maxY - ShelfPreviewLayoutMetrics.screenMargin - expectedOriginY

    XCTAssertTrue(placement.isValid)
    XCTAssertEqual(placement.frame.minY, expectedOriginY, accuracy: 0.01)
    XCTAssertEqual(placement.frame.height, expectedAvailableHeight, accuracy: 0.01)
    XCTAssertLessThan(placement.frame.height, 360)
  }

  func testPlacementIsInvalidWhenSelectedCardIsPartiallyOutsideViewport() {
    let placement = ShelfPreview.computePreviewPlacement(
      preferredSize: NSSize(width: 700, height: 460),
      minimumSize: NSSize(width: 420, height: 200),
      selectedCardFrame: NSRect(x: 460, y: 60, width: 90, height: 220),
      carouselViewportFrame: NSRect(x: 100, y: 0, width: 400, height: 300),
      screenFrame: NSRect(x: 0, y: 0, width: 1600, height: 900)
    )

    XCTAssertFalse(placement.isValid)
    XCTAssertFalse(placement.selectedCardIsFullyVisible)
  }
}

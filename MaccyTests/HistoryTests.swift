import AppKit
import CloudKit
import Defaults
import SwiftData
import XCTest
@testable import Maccy

@MainActor
class HistoryTests: XCTestCase {
  let savedSize = Defaults[.size]
  let savedSortBy = Defaults[.sortBy]
  let savedPopupLayoutMode = Defaults[.popupLayoutMode]
  let savedSearchMode = Defaults[.searchMode]
  let savedShelfPreviewImageEditorBundleID = Defaults[.shelfPreviewImageEditorBundleID]
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
  }

  override func tearDown() {
    super.tearDown()
    Defaults[.size] = savedSize
    Defaults[.sortBy] = savedSortBy
    Defaults[.popupLayoutMode] = savedPopupLayoutMode
    Defaults[.searchMode] = savedSearchMode
    Defaults[.shelfPreviewImageEditorBundleID] = savedShelfPreviewImageEditorBundleID
  }

  func testDefaultIsEmpty() {
    XCTAssertEqual(history.items, [])
  }

  func testAdding() {
    let first = history.add(historyItem("foo"))
    let second = history.add(historyItem("bar"))
    XCTAssertEqual(history.items, [second, first])
  }

  func testAddingSame() {
    let first = historyItem("foo")
    first.title = "xyz"
    first.application = "iTerm.app"
    let firstDecorator = history.add(first)
    first.pin = "f"

    let secondDecorator = history.add(historyItem("bar"))

    let third = historyItem("foo")
    third.application = "Xcode.app"
    history.add(third)

    XCTAssertEqual(history.items, [firstDecorator, secondDecorator])
    XCTAssertTrue(history.items[0].item.lastCopiedAt > history.items[0].item.firstCopiedAt)
    // TODO: This works in reality but fails in tests?!
    // XCTAssertEqual(history.items[0].item.numberOfCopies, 2)
    XCTAssertEqual(history.items[0].item.pin, "f")
    XCTAssertEqual(history.items[0].item.title, "xyz")
    XCTAssertEqual(history.items[0].item.application, "iTerm.app")
  }

  func testAddingItemThatIsSupersededByExisting() {
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

  func testClearingUnpinned() {
    let pinned = history.add(historyItem("foo"))
    pinned.togglePin()
    history.add(historyItem("bar"))
    history.clear()
    XCTAssertEqual(history.items, [pinned])
  }

  func testClearingAll() {
    history.add(historyItem("foo"))
    history.clear()
    XCTAssertEqual(history.items, [])
  }

  func testMaxSize() {
    var items: [HistoryItemDecorator] = []
    for index in 0...10 {
      items.append(history.add(historyItem(String(index))))
    }

    XCTAssertEqual(history.items.count, 10)
    XCTAssertTrue(history.items.contains(items[10]))
    XCTAssertFalse(history.items.contains(items[0]))
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

  func testRemoving() {
    let foo = history.add(historyItem("foo"))
    let bar = history.add(historyItem("bar"))
    history.delete(foo)
    XCTAssertEqual(history.items, [bar])
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

  private func historyItem(_ value: String) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value.data(using: .utf8)
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
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

private struct RemoteHistoryContentSnapshot: Codable {
  var type: String
  var value: Data?
}

private struct RemoteHistoryItemSnapshot: Codable {
  var id: UUID
  var application: String?
  var firstCopiedAt: Date
  var lastCopiedAt: Date
  var updatedAt: Date
  var tagAssignmentUpdatedAt: Date
  var numberOfCopies: Int
  var pin: String?
  var tagID: UUID?
  var title: String
  var contents: [RemoteHistoryContentSnapshot]
  var isDeleted: Bool
  var shared: Bool
}

private final class MockCloudKitHistoryStore: CloudKitHistoryStore {
  private(set) var itemRecords: [CKRecord]
  private(set) var tagRecords: [CKRecord]
  private(set) var saveCount = 0
  var fetchItemDelay: TimeInterval = 0
  var onItemFetch: (() -> Void)?

  init(itemRecords: [CKRecord] = [], tagRecords: [CKRecord] = []) {
    self.itemRecords = itemRecords
    self.tagRecords = tagRecords
  }

  func fetchItemRecords() async throws -> [CKRecord] {
    onItemFetch?()
    if fetchItemDelay > 0 {
      try? await Task.sleep(for: .milliseconds(Int(fetchItemDelay * 1_000)))
    }
    return itemRecords
  }

  func fetchTagRecords() async throws -> [CKRecord] {
    return tagRecords
  }

  func fetchVaultMetadataRecord() async throws -> CKRecord? {
    return nil
  }

  func save(records: [CKRecord]) async throws {
    saveCount += 1
    for record in records {
      switch record.recordType {
      case "MaccyEncryptedItem":
        upsert(record: record, records: &itemRecords)
      case "MaccyEncryptedTag":
        upsert(record: record, records: &tagRecords)
      default:
        continue
      }
    }
  }

  func itemSnapshot(id: UUID) -> RemoteHistoryItemSnapshot? {
    let recordName = "item-\(id)"
    guard let record = itemRecords.first(where: { $0.recordID.recordName == recordName }),
          let blob = record["blob"] as? Data else {
      return nil
    }

    return try? JSONDecoder().decode(RemoteHistoryItemSnapshot.self, from: blob)
  }

  private func upsert(record: CKRecord, records: inout [CKRecord]) {
    if let index = records.firstIndex(where: { $0.recordID == record.recordID }) {
      records[index] = record
    } else {
      records.append(record)
    }
  }
}

@MainActor
final class SyncReliabilityTests: XCTestCase {
  private var savedSyncEnabled = false
  private var savedEncryptionEnabled = false
  private var savedSyncScope: SyncScope = .all
  private var savedItemTombstones: Data?
  private var savedTagTombstones: Data?

  override func setUp() {
    super.setUp()
    savedSyncEnabled = Defaults[.syncEnabled]
    savedEncryptionEnabled = Defaults[.encryptionEnabled]
    savedSyncScope = Defaults[.syncScope]
    savedItemTombstones = Defaults[.syncItemTombstones]
    savedTagTombstones = Defaults[.syncTagTombstones]

    Defaults[.syncEnabled] = true
    Defaults[.encryptionEnabled] = false
    Defaults[.syncScope] = .all
    Defaults[.syncItemTombstones] = nil
    Defaults[.syncTagTombstones] = nil
    wipeRuntimeStorage()
  }

  override func tearDown() {
    Defaults[.syncEnabled] = savedSyncEnabled
    Defaults[.encryptionEnabled] = savedEncryptionEnabled
    Defaults[.syncScope] = savedSyncScope
    Defaults[.syncItemTombstones] = savedItemTombstones
    Defaults[.syncTagTombstones] = savedTagTombstones
    wipeRuntimeStorage()
    super.tearDown()
  }

  func testDeleteDuringInFlightSyncDoesNotResurrectItem() async {
    let id = UUID()
    let item = insertItem(id: id, text: "keep")
    let remoteRecord = makeRemoteRecord(item: item)
    let store = MockCloudKitHistoryStore(itemRecords: [remoteRecord])
    store.fetchItemDelay = 0.25

    let fetchStarted = expectation(description: "fetch started")
    store.onItemFetch = { fetchStarted.fulfill() }

    let manager = SyncEncryptionManager(cloudStore: store, configureSyncObservers: false)
    await manager.requestSync(trigger: "manual", coalesceMutationBurst: false)
    await fulfillment(of: [fetchStarted], timeout: 2.0)

    if let local = findItem(id: id) {
      Storage.shared.context.delete(local)
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }
    manager.recordDeletedItem(id: id)
    manager.handleHistoryMutation()

    let isIdle = await manager.waitForSyncIdle(maxWait: 5.0)
    XCTAssertTrue(isIdle)
    XCTAssertNil(findItem(id: id))
    XCTAssertEqual(store.itemSnapshot(id: id)?.isDeleted, true)
    XCTAssertGreaterThan(manager.diagnosticsStalePassCount, 0)
  }

  func testBurstDeletesCoalesceAndFullyConverge() async {
    let ids = (0..<40).map { _ in UUID() }
    let localItems = ids.map { insertItem(id: $0, text: "item-\($0.uuidString.prefix(4))") }
    let remoteRecords = localItems.map(makeRemoteRecord)
    let store = MockCloudKitHistoryStore(itemRecords: remoteRecords)
    let manager = SyncEncryptionManager(cloudStore: store, configureSyncObservers: false)

    for item in localItems {
      Storage.shared.context.delete(item)
    }
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()

    for id in ids {
      manager.recordDeletedItem(id: id)
      manager.handleHistoryMutation()
    }

    let isIdle = await manager.waitForSyncIdle(maxWait: 8.0)
    XCTAssertTrue(isIdle)
    let remaining = (try? Storage.shared.context.fetch(FetchDescriptor<HistoryItem>()).count) ?? 0
    XCTAssertEqual(remaining, 0)
    XCTAssertTrue(ids.allSatisfy { store.itemSnapshot(id: $0)?.isDeleted == true })
    XCTAssertLessThan(store.saveCount, ids.count)
  }

  func testNoDroppedSyncTriggerWhilePassInProgress() async {
    let id = UUID()
    let item = insertItem(id: id, text: "original")
    let store = MockCloudKitHistoryStore(itemRecords: [makeRemoteRecord(item: item)])
    store.fetchItemDelay = 0.3

    let fetchStarted = expectation(description: "fetch started")
    store.onItemFetch = { fetchStarted.fulfill() }

    let manager = SyncEncryptionManager(cloudStore: store, configureSyncObservers: false)
    await manager.requestSync(trigger: "manual", coalesceMutationBurst: false)
    await fulfillment(of: [fetchStarted], timeout: 2.0)

    if let local = findItem(id: id) {
      local.title = "updated"
      local.updatedAt = Date.now.addingTimeInterval(10)
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }
    manager.handleHistoryMutation()

    let isIdle = await manager.waitForSyncIdle(maxWait: 5.0)
    XCTAssertTrue(isIdle)
    XCTAssertGreaterThanOrEqual(manager.diagnosticsPassCount, 2)
    XCTAssertEqual(store.itemSnapshot(id: id)?.title, "updated")
    XCTAssertEqual(store.itemSnapshot(id: id)?.isDeleted, false)
  }

  func testDeleteWinsAgainstConcurrentRemoteUpdateSameID() async {
    let id = UUID()
    let localItem = insertItem(id: id, text: "local")
    let remoteUpdatedRecord = makeRemoteRecord(
      id: id,
      text: "remote-newer",
      updatedAt: Date.now.addingTimeInterval(120),
      isDeleted: false
    )
    let store = MockCloudKitHistoryStore(itemRecords: [remoteUpdatedRecord])
    let manager = SyncEncryptionManager(cloudStore: store, configureSyncObservers: false)

    Storage.shared.context.delete(localItem)
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()
    manager.recordDeletedItem(id: id)
    manager.handleHistoryMutation()

    let isIdle = await manager.waitForSyncIdle(maxWait: 5.0)
    XCTAssertTrue(isIdle)
    XCTAssertNil(findItem(id: id))
    XCTAssertEqual(store.itemSnapshot(id: id)?.isDeleted, true)
  }

  func testBulkDeleteEmitsSingleMutationSyncTrigger() async {
    let ids = (0..<12).map { _ in UUID() }
    let localItems = ids.map { insertItem(id: $0, text: "bulk-\($0.uuidString.prefix(4))") }
    let store = MockCloudKitHistoryStore(itemRecords: localItems.map(makeRemoteRecord))
    let manager = SyncEncryptionManager(cloudStore: store, configureSyncObservers: false)

    for item in localItems {
      Storage.shared.context.delete(item)
    }
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()

    manager.recordDeletedItems(ids: ids)
    manager.handleHistoryMutation()

    let isIdle = await manager.waitForSyncIdle(maxWait: 5.0)
    XCTAssertTrue(isIdle)
    XCTAssertEqual(manager.diagnosticsPassCount, 1)
    XCTAssertEqual(store.saveCount, 1)
    XCTAssertTrue(ids.allSatisfy { store.itemSnapshot(id: $0)?.isDeleted == true })
  }

  private func wipeRuntimeStorage() {
    try? Storage.shared.context.delete(model: HistoryItem.self)
    try? Storage.shared.context.delete(model: HistoryTag.self)
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()
  }

  @discardableResult
  private func insertItem(id: UUID, text: String) -> HistoryItem {
    let now = Date.now
    let item = HistoryItem(
      contents: [HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(text.utf8))]
    )
    item.id = id
    item.title = text
    item.firstCopiedAt = now
    item.lastCopiedAt = now
    item.updatedAt = now
    item.tagAssignmentUpdatedAt = now
    Storage.shared.context.insert(item)
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()
    return item
  }

  private func findItem(id: UUID) -> HistoryItem? {
    let descriptor = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.id == id }
    )
    return try? Storage.shared.context.fetch(descriptor).first
  }

  private func makeRemoteRecord(item: HistoryItem) -> CKRecord {
    makeRemoteRecord(
      id: item.id,
      text: item.title,
      updatedAt: item.updatedAt,
      isDeleted: false
    )
  }

  private func makeRemoteRecord(
    id: UUID,
    text: String,
    updatedAt: Date,
    isDeleted: Bool
  ) -> CKRecord {
    let snapshot = RemoteHistoryItemSnapshot(
      id: id,
      application: nil,
      firstCopiedAt: updatedAt,
      lastCopiedAt: updatedAt,
      updatedAt: updatedAt,
      tagAssignmentUpdatedAt: updatedAt,
      numberOfCopies: isDeleted ? 0 : 1,
      pin: nil,
      tagID: nil,
      title: isDeleted ? "" : text,
      contents: isDeleted ? [] : [RemoteHistoryContentSnapshot(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(text.utf8))],
      isDeleted: isDeleted,
      shared: !isDeleted
    )

    let zoneID = CKRecordZone.ID(zoneName: "MaccyHistoryZone", ownerName: CKCurrentUserDefaultName)
    let recordID = CKRecord.ID(recordName: "item-\(id)", zoneID: zoneID)
    let record = CKRecord(recordType: "MaccyEncryptedItem", recordID: recordID)
    if let payload = try? JSONEncoder().encode(snapshot) {
      record["blob"] = payload as CKRecordValue
    }
    record["encrypted"] = NSNumber(booleanLiteral: false)
    return record
  }
}

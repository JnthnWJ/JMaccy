import XCTest
import Defaults
@testable import Maccy

@MainActor
class HistoryTests: XCTestCase {
  let savedSize = Defaults[.size]
  let savedSortBy = Defaults[.sortBy]
  let savedPopupLayoutMode = Defaults[.popupLayoutMode]
  let savedSearchMode = Defaults[.searchMode]
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
  }

  override func tearDown() {
    super.tearDown()
    Defaults[.size] = savedSize
    Defaults[.sortBy] = savedSortBy
    Defaults[.popupLayoutMode] = savedPopupLayoutMode
    Defaults[.searchMode] = savedSearchMode
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

  private func waitForSearchThrottle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.35))
  }
}

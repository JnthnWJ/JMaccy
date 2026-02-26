import Foundation
import SwiftData

@Model
class HistoryTag {
  var id: UUID = UUID()
  var name: String = ""
  var colorKey: String = ShelfTagColor.blue.rawValue
  var createdAt: Date = Date.now
  var updatedAt: Date = Date.now

  @Relationship(deleteRule: .nullify, inverse: \HistoryItem.tag)
  var items: [HistoryItem] = []

  init(name: String, colorKey: String) {
    self.name = name
    self.colorKey = colorKey
    self.createdAt = Date.now
    self.updatedAt = Date.now
  }

  var color: ShelfTagColor {
    return ShelfTagColor(rawValue: colorKey) ?? .blue
  }
}

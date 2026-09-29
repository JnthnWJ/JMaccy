import Foundation
import SwiftData

@MainActor
class Storage {
  static let shared = Storage()

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  var size: String {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).allValues.first?.value as? Int64, size > 1 else {
      return ""
    }

    return ByteCountFormatter().string(fromByteCount: size)
  }

  private let url = URL.applicationSupportDirectory.appending(path: "Maccy/Storage.sqlite")

  init() {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    #if DEBUG
    let isTesting = CommandLine.arguments.contains("enable-testing")
    #else
    let isTesting = false
    #endif

    var config = ModelConfiguration(url: url, cloudKitDatabase: .none)

    #if DEBUG
    if isTesting {
      config = ModelConfiguration(nil, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    }
    #endif

    container = Self.loadPlainContainer(config: config, recoverURL: isTesting ? nil : url)
  }

  /// Deletes contents that no longer belong to any item.
  ///
  /// Replacing an item's contents only detaches the old ones, so older builds left them behind
  /// (including every sync pass, which re-created all contents), and they kept all their data.
  @discardableResult
  func purgeOrphanedContents() -> Int {
    let predicate = #Predicate<HistoryItemContent> { $0.item == nil }
    let orphanCount = (try? context.fetchCount(FetchDescriptor(predicate: predicate))) ?? 0
    guard orphanCount > 0 else { return 0 }

    do {
      try context.delete(model: HistoryItemContent.self, where: predicate)
    } catch {
      let orphans = (try? context.fetch(FetchDescriptor(predicate: predicate))) ?? []
      orphans.forEach { context.delete($0) }
    }
    context.processPendingChanges()
    try? context.save()
    return orphanCount
  }

  private static func loadPlainContainer(config: ModelConfiguration, recoverURL: URL?) -> ModelContainer {
    do {
      return try ModelContainer(for: HistoryItem.self, HistoryTag.self, configurations: config)
    } catch {
      guard let recoverURL else {
        return makeInMemoryPlainContainer(after: error)
      }

      quarantineStoreFiles(at: recoverURL, storeLabel: "plain", initialError: error)

      do {
        return try ModelContainer(for: HistoryItem.self, HistoryTag.self, configurations: config)
      } catch {
        return makeInMemoryPlainContainer(after: error)
      }
    }
  }

  private static func makeInMemoryPlainContainer(after error: Error) -> ModelContainer {
    NSLog("[Maccy] Failed to load plain SwiftData store. Falling back to in-memory store. Error: \(error.localizedDescription)")
    do {
      return try ModelContainer(
        for: HistoryItem.self,
        HistoryTag.self,
        configurations: ModelConfiguration(nil, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
      )
    } catch {
      fatalError("Cannot load plain database: \(error.localizedDescription).")
    }
  }

  private static func quarantineStoreFiles(at storeURL: URL, storeLabel: String, initialError: Error) {
    let fileManager = FileManager.default
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
    let timestamp = formatter.string(from: .now)
      .replacingOccurrences(of: ":", with: "-")
    let quarantineDir = storeURL
      .deletingLastPathComponent()
      .appending(path: "StoreRecovery")
      .appending(path: "\(storeLabel)-\(timestamp)-\(UUID().uuidString)")

    do {
      try fileManager.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
      for candidate in storeFileURLs(for: storeURL) where fileManager.fileExists(atPath: candidate.path) {
        let destination = quarantineDir.appending(path: candidate.lastPathComponent)
        do {
          try fileManager.moveItem(at: candidate, to: destination)
        } catch {
          try? fileManager.removeItem(at: candidate)
        }
      }
      NSLog(
        "[Maccy] Recovered \(storeLabel) SwiftData store from open failure. Error: \(initialError.localizedDescription). Backup: \(quarantineDir.path)"
      )
    } catch {
      NSLog("[Maccy] Failed to quarantine \(storeLabel) SwiftData store after open failure: \(error.localizedDescription)")
      for candidate in storeFileURLs(for: storeURL) where fileManager.fileExists(atPath: candidate.path) {
        try? fileManager.removeItem(at: candidate)
      }
    }
  }

  static func storeFileURLs(for storeURL: URL) -> [URL] {
    [
      storeURL,
      URL(fileURLWithPath: storeURL.path + "-wal"),
      URL(fileURLWithPath: storeURL.path + "-shm")
    ]
  }
}


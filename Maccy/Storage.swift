import AppKit
import CryptoKit
import Darwin
import Defaults
import Foundation
import Logging
import SwiftData

enum RuntimeDiagnostics {
  private static let logger = Logger(label: "org.p0deje.Maccy.diagnostics")
  private static let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .memory
    return formatter
  }()

  private static var liveShelfReporterViews = 0
  private static var liveShelfWheelCoordinators = 0

  static var enabled: Bool { Defaults[.memoryLeakDiagnosticsEnabled] }

  static func residentMemoryBytes() -> UInt64? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)

    let result = withUnsafeMutablePointer(to: &info) { infoPointer in
      infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPointer, &count)
      }
    }

    guard result == KERN_SUCCESS else {
      return nil
    }

    return UInt64(info.resident_size)
  }

  static func format<T: BinaryInteger>(bytes: T) -> String {
    byteFormatter.string(fromByteCount: Int64(bytes))
  }

  // The message is an autoclosure so that callers don't pay for building it (some messages sum up
  // snapshot sizes) while diagnostics are disabled, which is the default.
  static func log(_ message: @autoclosure () -> String) {
    guard enabled else { return }

    let message = message()
    if let residentMemoryBytes = residentMemoryBytes() {
      logger.notice("[rss=\(format(bytes: residentMemoryBytes))] \(message)")
    } else {
      logger.notice("\(message)")
    }
  }

  static func shelfReporterCreated(itemID: UUID?) {
    guard enabled else { return }
    liveShelfReporterViews += 1
    log("shelf reporter created item=\(itemID?.uuidString ?? "nil") live=\(liveShelfReporterViews)")
  }

  static func shelfReporterDestroyed(itemID: UUID?) {
    guard enabled else { return }
    liveShelfReporterViews = max(0, liveShelfReporterViews - 1)
    log("shelf reporter destroyed item=\(itemID?.uuidString ?? "nil") live=\(liveShelfReporterViews)")
  }

  static func shelfWheelAttached() {
    guard enabled else { return }
    liveShelfWheelCoordinators += 1
    log("shelf wheel attached live=\(liveShelfWheelCoordinators)")
  }

  static func shelfWheelDetached() {
    guard enabled else { return }
    liveShelfWheelCoordinators = max(0, liveShelfWheelCoordinators - 1)
    log("shelf wheel detached live=\(liveShelfWheelCoordinators)")
  }
}

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

// MARK: - Legacy encrypted vault

// Earlier builds could keep history encrypted in a separate store. These are its record types and
// the plaintext format of their blobs, kept only so that `LegacyVaultMigration` can read old vaults.
@Model
class EncryptedHistoryItemRecord {
  var id: UUID = UUID()
  var blob: Data = Data()

  init(id: UUID, blob: Data) {
    self.id = id
    self.blob = blob
  }
}

@Model
class EncryptedHistoryTagRecord {
  var id: UUID = UUID()
  var blob: Data = Data()

  init(id: UUID, blob: Data) {
    self.id = id
    self.blob = blob
  }
}

private struct LegacyVaultContent: Decodable {
  var type: String
  var value: Data?
}

// Builds with iCloud sync also stored deletion markers (`isDeleted == true`) in the vault.
private struct LegacyVaultItem: Decodable {
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
  var customTitle: String?
  var contents: [LegacyVaultContent]
  var isDeleted: Bool
}

private struct LegacyVaultTag: Decodable {
  var id: UUID
  var name: String
  var colorKey: String
  var createdAt: Date
  var updatedAt: Date
  var isDeleted: Bool
}

/// Moves history out of the encrypted vault used by earlier builds into the regular store, once.
///
/// Decrypting needs the vault password, so the user is asked for it. They can postpone the import
/// (the vault is kept until the next launch) or delete the vault without importing it.
@MainActor
struct LegacyVaultMigration {
  enum PasswordResponse {
    case password(String)
    case later
    case delete
  }

  enum Outcome: Equatable {
    case nothingToMigrate
    case imported(items: Int, tags: Int)
    case postponed
    case deleted
  }

  static let defaultVaultURL = URL.applicationSupportDirectory.appending(path: "Maccy/EncryptedStorage.sqlite")

  static let legacyDefaultsKeys = [
    "encryptionEnabled",
    "encryptionSalt",
    "encryptionVerifier",
    "unlockPolicy",
    "unlockTimeoutMinutes",
    "encryptedVaultVersion",
    "syncEnabled",
    "syncScope",
    "cloudSyncStatus",
    "syncItemTombstones",
    "syncTagTombstones"
  ]

  private static let verifierData = Data("maccy-vault-verifier-v1".utf8)
  private static let batchSize = 25

  var vaultURL = defaultVaultURL
  var defaults = UserDefaults.standard
  var destination: ModelContainer = Storage.shared.container
  var askForPassword: (_ isRetry: Bool) -> PasswordResponse = Self.promptForPassword
  var confirmDeletion: () -> Bool = Self.promptToConfirmDeletion

  private let logger = Logger(label: "org.p0deje.Maccy.vaultMigration")

  @discardableResult
  func runIfNeeded() -> Outcome {
    guard FileManager.default.fileExists(atPath: vaultURL.path) else {
      removeLegacyDefaults()
      return .nothingToMigrate
    }

    guard let vault = try? ModelContainer(
      for: EncryptedHistoryItemRecord.self,
      EncryptedHistoryTagRecord.self,
      configurations: ModelConfiguration(url: vaultURL, cloudKitDatabase: .none)
    ) else {
      logger.error("Unable to open the legacy encrypted vault; leaving it in place")
      return .postponed
    }

    let recordCount = ((try? vault.mainContext.fetchCount(FetchDescriptor<EncryptedHistoryItemRecord>())) ?? 0)
      + ((try? vault.mainContext.fetchCount(FetchDescriptor<EncryptedHistoryTagRecord>())) ?? 0)
    guard recordCount > 0 else {
      deleteVault()
      return .nothingToMigrate
    }

    guard let salt = defaults.data(forKey: "encryptionSalt"),
          let verifier = defaults.data(forKey: "encryptionVerifier") else {
      // Without the salt and verifier the vault can't be decrypted anymore.
      logger.error("Legacy encrypted vault has \(recordCount) records but no credentials; deleting it")
      deleteVault()
      return .deleted
    }

    var isRetry = false
    while true {
      switch askForPassword(isRetry) {
      case .later:
        return .postponed
      case .delete:
        guard confirmDeletion() else { continue }
        deleteVault()
        return .deleted
      case .password(let password):
        let key = Self.deriveKey(password: password, salt: salt)
        guard let decrypted = try? Self.decrypt(verifier, with: key), decrypted == Self.verifierData else {
          isRetry = true
          continue
        }

        // Importing skips items that already exist, so a failed import can safely run again next launch.
        guard let outcome = importVault(vault, key: key) else {
          return .postponed
        }
        deleteVault()
        return outcome
      }
    }
  }

  private func importVault(_ vault: ModelContainer, key: SymmetricKey) -> Outcome? {
    guard let tagIDs = importTags(from: vault, key: key) else {
      return nil
    }

    // Items are imported in batches with short-lived contexts, so that only one batch of
    // decrypted history (which can contain large images) is in memory at a time.
    var importedItems = 0
    var offset = 0
    var saveError: Error?
    while saveError == nil {
      let batchImported: Int? = autoreleasepool {
        var descriptor = FetchDescriptor<EncryptedHistoryItemRecord>()
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = Self.batchSize
        let records = (try? ModelContext(vault).fetch(descriptor)) ?? []
        guard !records.isEmpty else { return nil }

        let context = ModelContext(destination)
        let existingIDs = Set(((try? context.fetch(FetchDescriptor<HistoryItem>())) ?? []).map(\.id))
        let tags = ((try? context.fetch(FetchDescriptor<HistoryTag>())) ?? []).filter { tagIDs.contains($0.id) }
        let tagsByID = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var count = 0
        for record in records {
          guard let plaintext = try? Self.decrypt(record.blob, with: key),
                let snapshot = try? JSONDecoder().decode(LegacyVaultItem.self, from: plaintext),
                !snapshot.isDeleted,
                !existingIDs.contains(snapshot.id) else {
            continue
          }

          let item = HistoryItem(contents: snapshot.contents.map { HistoryItemContent(type: $0.type, value: $0.value) })
          item.id = snapshot.id
          item.application = snapshot.application
          item.firstCopiedAt = snapshot.firstCopiedAt
          item.lastCopiedAt = snapshot.lastCopiedAt
          item.updatedAt = snapshot.updatedAt
          item.tagAssignmentUpdatedAt = snapshot.tagAssignmentUpdatedAt
          item.numberOfCopies = snapshot.numberOfCopies
          item.pin = snapshot.pin
          item.title = snapshot.title
          item.customTitle = snapshot.customTitle
          context.insert(item)
          item.tag = snapshot.tagID.flatMap { tagsByID[$0] }
          count += 1
        }

        do {
          try context.save()
        } catch {
          saveError = error
        }
        offset += records.count
        return count
      }

      guard let batchImported else { break }
      importedItems += batchImported
    }

    if let saveError {
      logger.error("Failed to import the legacy encrypted vault; keeping it: \(saveError.localizedDescription)")
      return nil
    }

    logger.info("Imported \(importedItems) items and \(tagIDs.count) tags from the legacy encrypted vault")
    return .imported(items: importedItems, tags: tagIDs.count)
  }

  private func importTags(from vault: ModelContainer, key: SymmetricKey) -> Set<UUID>? {
    let records = (try? ModelContext(vault).fetch(FetchDescriptor<EncryptedHistoryTagRecord>())) ?? []
    let context = ModelContext(destination)
    let existingTags = (try? context.fetch(FetchDescriptor<HistoryTag>())) ?? []
    let existingIDs = Set(existingTags.map(\.id))

    var tagIDs = existingIDs
    for record in records {
      guard let plaintext = try? Self.decrypt(record.blob, with: key),
            let snapshot = try? JSONDecoder().decode(LegacyVaultTag.self, from: plaintext),
            !snapshot.isDeleted,
            !existingIDs.contains(snapshot.id) else {
        continue
      }

      let tag = HistoryTag(name: snapshot.name, colorKey: snapshot.colorKey)
      tag.id = snapshot.id
      tag.createdAt = snapshot.createdAt
      tag.updatedAt = snapshot.updatedAt
      context.insert(tag)
      tagIDs.insert(tag.id)
    }

    do {
      try context.save()
    } catch {
      logger.error("Failed to import tags from the legacy encrypted vault: \(error.localizedDescription)")
      return nil
    }
    return tagIDs.subtracting(existingIDs)
  }

  private func deleteVault() {
    for url in Storage.storeFileURLs(for: vaultURL) where FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.removeItem(at: url)
    }
    removeLegacyDefaults()
  }

  private func removeLegacyDefaults() {
    Self.legacyDefaultsKeys.forEach { defaults.removeObject(forKey: $0) }
  }

  private static func deriveKey(password: String, salt: Data) -> SymmetricKey {
    var data = salt + Data(password.utf8)
    for _ in 0..<100_000 {
      data = Data(SHA256.hash(data: data))
    }
    return SymmetricKey(data: data)
  }

  private static func decrypt(_ data: Data, with key: SymmetricKey) throws -> Data {
    let box = try AES.GCM.SealedBox(combined: data)
    return try AES.GCM.open(box, using: key)
  }

  private static func promptForPassword(isRetry: Bool) -> PasswordResponse {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = localized("LegacyVaultImportTitle", fallback: "Import Encrypted History")
    let body = localized(
      "LegacyVaultImportBody",
      fallback: "Encryption has been removed from Maccy. Enter your encryption password to move your existing "
        + "clipboard history into regular storage. Until then, it isn't shown."
    )
    alert.informativeText = isRetry
      ? "\(localized("LegacyVaultImportWrongPassword", fallback: "Incorrect password."))\n\n\(body)"
      : body

    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    alert.addButton(withTitle: localized("LegacyVaultImportConfirm", fallback: "Import"))
    alert.addButton(withTitle: localized("LegacyVaultImportLater", fallback: "Not Now"))
    alert.addButton(withTitle: localized("LegacyVaultImportDelete", fallback: "Delete History…"))

    switch alert.runModal() {
    case .alertFirstButtonReturn:
      return .password(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    case .alertThirdButtonReturn:
      return .delete
    default:
      return .later
    }
  }

  private static func promptToConfirmDeletion() -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = localized("LegacyVaultDeleteTitle", fallback: "Delete Encrypted History?")
    alert.informativeText = localized(
      "LegacyVaultDeleteBody",
      fallback: "Your encrypted clipboard history and tags will be permanently deleted without being imported."
    )
    alert.addButton(withTitle: localized("LegacyVaultDeleteConfirm", fallback: "Delete"))
    alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
    alert.buttons.first?.hasDestructiveAction = true
    return alert.runModal() == .alertFirstButtonReturn
  }

  private static func localized(_ key: String, fallback: String) -> String {
    Bundle.main.localizedString(forKey: key, value: fallback, table: "StorageSettings")
  }
}

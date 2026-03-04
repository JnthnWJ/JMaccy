import AppKit
import CloudKit
import CryptoKit
import Defaults
import Foundation
import Logging
import Observation
import Security
import SwiftData

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

private struct HistoryContentSnapshot: Codable {
  var type: String
  var value: Data?
}

private struct HistoryItemSnapshot: Codable {
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
  var contents: [HistoryContentSnapshot]
  var isDeleted: Bool
  var shared: Bool
}

private struct HistoryTagSnapshot: Codable {
  var id: UUID
  var name: String
  var colorKey: String
  var createdAt: Date
  var updatedAt: Date
  var isDeleted: Bool
}

private struct SyncSnapshot {
  var items: [UUID: HistoryItemSnapshot]
  var tags: [UUID: HistoryTagSnapshot]
}

protocol HistoryRepository {
  @MainActor func fetchItems() throws -> [HistoryItem]
  @MainActor func fetchTags() throws -> [HistoryTag]
  @MainActor func save() throws
}

struct PlainHistoryRepository: HistoryRepository {
  @MainActor
  func fetchItems() throws -> [HistoryItem] {
    try Storage.shared.context.fetch(FetchDescriptor<HistoryItem>())
  }

  @MainActor
  func fetchTags() throws -> [HistoryTag] {
    try Storage.shared.context.fetch(FetchDescriptor<HistoryTag>())
  }

  @MainActor
  func save() throws {
    try Storage.shared.context.save()
  }
}

struct EncryptedHistoryRepository: HistoryRepository {
  @MainActor
  func fetchItems() throws -> [HistoryItem] {
    try Storage.shared.context.fetch(FetchDescriptor<HistoryItem>())
  }

  @MainActor
  func fetchTags() throws -> [HistoryTag] {
    try Storage.shared.context.fetch(FetchDescriptor<HistoryTag>())
  }

  @MainActor
  func save() throws {
    try Storage.shared.context.save()
    SyncEncryptionManager.shared.persistEncryptedVaultFromRuntime()
  }
}

protocol CloudKitHistoryStore {
  func fetchItemRecords() async throws -> [CKRecord]
  func fetchTagRecords() async throws -> [CKRecord]
  func fetchVaultMetadataRecord() async throws -> CKRecord?
  func save(records: [CKRecord]) async throws
}

private struct CloudStoreUnavailableError: Error {}

final class UnavailableCloudKitHistoryStore: CloudKitHistoryStore {
  func fetchItemRecords() async throws -> [CKRecord] {
    throw CloudStoreUnavailableError()
  }

  func fetchTagRecords() async throws -> [CKRecord] {
    throw CloudStoreUnavailableError()
  }

  func fetchVaultMetadataRecord() async throws -> CKRecord? {
    throw CloudStoreUnavailableError()
  }

  func save(records: [CKRecord]) async throws {
    throw CloudStoreUnavailableError()
  }
}

final class CloudKitHistoryStoreImpl: CloudKitHistoryStore {
  private struct RetryPlan {
    var records: [CKRecord]
    var delayNanoseconds: UInt64
  }

  private let itemType = "MaccyEncryptedItem"
  private let tagType = "MaccyEncryptedTag"
  private let vaultMetadataType = "MaccyVaultMetadata"
  private let vaultMetadataRecordName = "vault-metadata"
  private let maxRecordsPerSaveBatch = 100
  private let maxBytesPerSaveBatch = 4_000_000
  private let maxSaveRetryAttempts = 3
  private let requestTimeoutSeconds: TimeInterval = 30
  private let resourceTimeoutSeconds: TimeInterval = 120
  private let zoneID = CKRecordZone.ID(zoneName: "MaccyHistoryZone", ownerName: CKCurrentUserDefaultName)
  private let database = CKContainer.default().privateCloudDatabase

  func fetchItemRecords() async throws -> [CKRecord] {
    try await ensureZone()
    return try await fetchRecords(type: itemType)
  }

  func fetchTagRecords() async throws -> [CKRecord] {
    try await ensureZone()
    return try await fetchRecords(type: tagType)
  }

  func fetchVaultMetadataRecord() async throws -> CKRecord? {
    try await ensureZone()
    let records = try await fetchRecords(type: vaultMetadataType)
    return records.first(where: { $0.recordID.recordName == vaultMetadataRecordName }) ?? records.first
  }

  func save(records: [CKRecord]) async throws {
    guard !records.isEmpty else { return }
    try await ensureZone()

    for batch in makeSaveBatches(from: records) {
      try await saveBatchWithRetry(records: batch)
    }
  }

  private func saveBatchWithRetry(records: [CKRecord]) async throws {
    var attempt = 0
    var recordsToSave = records

    while true {
      do {
        try await saveBatch(records: recordsToSave)
        return
      } catch {
        guard let retryPlan = retryPlan(for: error, attempt: attempt, records: recordsToSave) else {
          throw error
        }
        attempt += 1
        recordsToSave = retryPlan.records
        if retryPlan.delayNanoseconds > 0 {
          try? await Task.sleep(nanoseconds: retryPlan.delayNanoseconds)
        }
      }
    }
  }

  private func saveBatch(records: [CKRecord]) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let op = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
      op.savePolicy = .changedKeys
      op.isAtomic = false
      configureTimeouts(for: op)
      op.modifyRecordsCompletionBlock = { _, _, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: ())
        }
      }
      self.database.add(op)
    }
  }

  private func ensureZone() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let zone = CKRecordZone(zoneID: zoneID)
      let op = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: nil)
      configureTimeouts(for: op)
      op.modifyRecordZonesCompletionBlock = { _, _, error in
        if let error {
          if error.localizedDescription.localizedCaseInsensitiveContains("already exists") {
            continuation.resume(returning: ())
          } else {
            continuation.resume(throwing: error)
          }
        } else {
          continuation.resume(returning: ())
        }
      }
      self.database.add(op)
    }
  }

  private func fetchRecords(type: String) async throws -> [CKRecord] {
    let allRecords = try await fetchAllRecordsInZone()
    return allRecords.filter { $0.recordType == type }
  }

  private func fetchAllRecordsInZone() async throws -> [CKRecord] {
    try await withCheckedThrowingContinuation { continuation in
      var records: [CKRecord] = []
      var zoneLevelError: Error?

      let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
      config.previousServerChangeToken = nil

      let op = CKFetchRecordZoneChangesOperation(
        recordZoneIDs: [zoneID],
        configurationsByRecordZoneID: [zoneID: config]
      )
      configureTimeouts(for: op)
      op.recordChangedBlock = { record in
        records.append(record)
      }
      op.recordZoneFetchCompletionBlock = { _, _, _, _, error in
        if zoneLevelError == nil, let error {
          zoneLevelError = error
        }
      }
      op.fetchRecordZoneChangesCompletionBlock = { error in
        if let zoneLevelError {
          continuation.resume(throwing: zoneLevelError)
          return
        }

        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: records)
        }
      }
      self.database.add(op)
    }
  }

  private func makeSaveBatches(from records: [CKRecord]) -> [[CKRecord]] {
    var batches: [[CKRecord]] = []
    var currentBatch: [CKRecord] = []
    var currentBatchBytes = 0

    for record in records {
      let recordBytes = estimatedRecordSize(for: record)
      let recordWouldOverflowCount = currentBatch.count >= maxRecordsPerSaveBatch
      let recordWouldOverflowSize = !currentBatch.isEmpty && currentBatchBytes + recordBytes > maxBytesPerSaveBatch

      if recordWouldOverflowCount || recordWouldOverflowSize {
        batches.append(currentBatch)
        currentBatch = []
        currentBatchBytes = 0
      }

      currentBatch.append(record)
      currentBatchBytes += recordBytes
    }

    if !currentBatch.isEmpty {
      batches.append(currentBatch)
    }

    return batches
  }

  private func estimatedRecordSize(for record: CKRecord) -> Int {
    var size = 512
    if let blob = record["blob"] as? Data {
      size += blob.count
    }
    if let salt = record["salt"] as? Data {
      size += salt.count
    }
    if let verifier = record["verifier"] as? Data {
      size += verifier.count
    }
    return size
  }

  private func retryPlan(for error: Error, attempt: Int, records: [CKRecord]) -> RetryPlan? {
    guard attempt < maxSaveRetryAttempts else { return nil }
    guard let ckError = extractCloudError(error) else { return nil }

    if ckError.code == .partialFailure,
       let partialErrors = partialErrorsByRecordID(from: error), !partialErrors.isEmpty {
      let retryableRecordIDs = Set(partialErrors.compactMap { recordID, partialError in
        isRetryable(partialError) ? recordID : nil
      })

      guard !retryableRecordIDs.isEmpty else { return nil }

      let retryRecords = records.filter { retryableRecordIDs.contains($0.recordID) }
      guard !retryRecords.isEmpty else { return nil }

      let delay = partialErrors.values.reduce(UInt64(0)) { max($0, retryDelayNanoseconds(for: $1, attempt: attempt)) }
      return RetryPlan(records: retryRecords, delayNanoseconds: delay)
    }

    guard isRetryable(ckError) else { return nil }
    return RetryPlan(records: records, delayNanoseconds: retryDelayNanoseconds(for: ckError, attempt: attempt))
  }

  private func extractCloudError(_ error: Error) -> CKError? {
    if let ckError = error as? CKError {
      if ckError.code == .partialFailure,
         let partialErrors = partialErrorsByRecordID(from: error) {
        for nestedError in partialErrors.values {
          if let nestedCloudError = extractCloudError(nestedError) {
            return nestedCloudError
          }
        }
      }
      return ckError
    }

    let nsError = error as NSError
    if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
      return extractCloudError(underlyingError)
    }
    return nil
  }

  private func partialErrorsByRecordID(from error: Error) -> [CKRecord.ID: CKError]? {
    let nsError = error as NSError
    guard let partialErrors = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Any] else {
      return nil
    }

    var output: [CKRecord.ID: CKError] = [:]
    for (key, value) in partialErrors {
      guard let recordID = key as? CKRecord.ID,
            let nestedError = value as? Error,
            let cloudError = extractCloudError(nestedError) else {
        continue
      }
      output[recordID] = cloudError
    }
    return output
  }

  private func isRetryable(_ error: CKError) -> Bool {
    switch error.code {
    case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy, .internalError:
      return true
    default:
      return false
    }
  }

  private func retryDelayNanoseconds(for error: CKError, attempt: Int) -> UInt64 {
    if let retryAfter = (error.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue {
      return max(0, UInt64(retryAfter * 1_000_000_000))
    }

    let backoffSeconds = min(8.0, pow(2.0, Double(attempt)))
    return UInt64(backoffSeconds * 1_000_000_000)
  }

  private func configureTimeouts(for operation: CKOperation) {
    operation.configuration.timeoutIntervalForRequest = requestTimeoutSeconds
    operation.configuration.timeoutIntervalForResource = resourceTimeoutSeconds
  }
}

@MainActor
@Observable
class HistorySyncEngine {
  static let shared = HistorySyncEngine()

  private var handler: ((String) async -> Void)?
  private var loopTask: Task<Void, Never>?

  func configure(handler: @escaping (String) async -> Void) {
    self.handler = handler
  }

  func start() {
    guard loopTask == nil else { return }
    loopTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.handler?("periodic")
        try? await Task.sleep(for: .seconds(45))
      }
    }
  }

  func stop() {
    loopTask?.cancel()
    loopTask = nil
  }

  func requestSync(trigger: String) {
    Task { [weak self] in
      await self?.handler?(trigger)
    }
  }
}

@MainActor
@Observable
class SyncEncryptionManager {
  private enum SyncPassResult {
    case success
    case staleMutationDetected
    case skipped
  }

  enum LockReason {
    case startup
    case sleep
    case timer
    case strictAction
    case manual
  }

  static let shared = SyncEncryptionManager()

  var isLocked = false
  var isSyncInProgress = false
  var statusText = ""

  private let logger = Logger(label: "org.p0deje.Maccy.sync")
  private let cloudStore: CloudKitHistoryStore
  private let maxCloudBlobBytes = 900_000
  private let zoneID = CKRecordZone.ID(zoneName: "MaccyHistoryZone", ownerName: CKCurrentUserDefaultName)
  private let vaultMetadataType = "MaccyVaultMetadata"
  private let vaultMetadataRecordName = "vault-metadata"
  private var runtimeKey: SymmetricKey?
  private var lockTimerTask: Task<Void, Never>?
  private var notifiedCapturePause = false
  private var itemTombstones: [UUID: Date] = [:]
  private var tagTombstones: [UUID: Date] = [:]
  private var localMutationRevision: UInt64 = 0
  private var needsAnotherPass = false
  private var syncTask: Task<Void, Never>?
  private var pendingTriggers: Set<String> = []
  private var coalescedTriggerCount = 0
  private(set) var diagnosticsPassCount = 0
  private(set) var diagnosticsStalePassCount = 0

  init(cloudStore: CloudKitHistoryStore? = nil, configureSyncObservers: Bool = true) {
    if let cloudStore {
      self.cloudStore = cloudStore
    } else if Self.canInitializeCloudKitStore() {
      self.cloudStore = CloudKitHistoryStoreImpl()
    } else {
      self.cloudStore = UnavailableCloudKitHistoryStore()
      Defaults[.cloudSyncStatus] = .unavailable
      statusText = NSLocalizedString("CloudSyncStatusUnavailable", tableName: "StorageSettings", comment: "")
    }
    loadTombstones()

    if configureSyncObservers {
      HistorySyncEngine.shared.configure { [weak self] trigger in
        let shouldCoalesce = trigger == "mutation"
        await self?.requestSync(trigger: trigger, coalesceMutationBurst: shouldCoalesce)
      }

      Task {
        for await _ in Defaults.updates(.syncEnabled, initial: false) {
          if Defaults[.syncEnabled] {
            HistorySyncEngine.shared.start()
            HistorySyncEngine.shared.requestSync(trigger: "sync-enabled")
          } else {
            HistorySyncEngine.shared.stop()
            syncTask?.cancel()
            pendingTriggers.removeAll()
            needsAnotherPass = false
          }
        }
      }
    }
  }

  func bootstrap() {
    if Defaults[.encryptionEnabled] {
      Storage.shared.activateEncryptedRuntime()
      isLocked = true

      if Defaults[.encryptionSalt] == nil || Defaults[.encryptionVerifier] == nil {
        Task { [weak self] in
          await self?.resolveBootstrapCredentials()
        }
      } else {
        unlockWithPrompt()
      }
    } else {
      Storage.shared.activatePlainRuntime()
      isLocked = false
    }

    if Defaults[.syncEnabled] {
      HistorySyncEngine.shared.start()
      HistorySyncEngine.shared.requestSync(trigger: "bootstrap")
    }
  }

  func canCaptureClipboard() -> Bool {
    !(Defaults[.encryptionEnabled] && isLocked)
  }

  func notifyCapturePausedIfNeeded() {
    guard !notifiedCapturePause else { return }
    notifiedCapturePause = true
    Notifier.notify(body: NSLocalizedString("CapturePausedLocked", tableName: "StorageSettings", comment: ""), sound: nil)
  }

  func recordActivity() {
    notifiedCapturePause = false
    resetTimerLockIfNeeded()
  }

  private func markLocalMutation(reason: String) {
    localMutationRevision &+= 1
    logger.debug("Mutation revision=\(localMutationRevision) reason='\(reason)'")
  }

  func recordProtectedActionCompleted() {
    recordActivity()
    if Defaults[.unlockPolicy] == .strictPerAction {
      lock(reason: .strictAction)
    }
  }

  func handleSystemSleep() {
    guard Defaults[.unlockPolicy].locksOnSleep else { return }
    guard !isLocked else { return }
    lock(reason: .sleep)
  }

  func handleHistoryMutation() {
    recordActivity()
    markLocalMutation(reason: "history-mutation")
    if Defaults[.encryptionEnabled] {
      persistEncryptedVaultFromRuntime()
    }
    if Defaults[.syncEnabled] {
      Task { [weak self] in
        await self?.requestSync(trigger: "mutation", coalesceMutationBurst: true)
      }
    }
  }

  func handleSyncScopeChanged() {
    let now = Date.now
    let descriptor = FetchDescriptor<HistoryItem>()
    if let items = try? Storage.shared.context.fetch(descriptor) {
      for item in items {
        item.updatedAt = now
      }
      try? Storage.shared.context.save()
    }
    handleHistoryMutation()
  }

  func manualSyncFromUI() {
    Task { [weak self] in
      await self?.requestSync(trigger: "manual", coalesceMutationBurst: false)
    }
  }

  func enableEncryptionFromUI() {
    Task { [weak self] in
      await self?.enableEncryptionFlowFromUI()
    }
  }

  func changePasswordFromUI() {
    Task { [weak self] in
      await self?.changePasswordFlowFromUI()
    }
  }

  func disableEncryptionAndWipeFromUI() {
    let isConfigured = Defaults[.encryptionSalt] != nil || Defaults[.encryptionVerifier] != nil
    guard Defaults[.encryptionEnabled] || isConfigured else { return }

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = NSLocalizedString("DisableEncryptionWipeTitle", tableName: "StorageSettings", comment: "")
    alert.informativeText = NSLocalizedString("DisableEncryptionWipeBody", tableName: "StorageSettings", comment: "")
    alert.addButton(withTitle: NSLocalizedString("DisableEncryptionWipeConfirm", tableName: "StorageSettings", comment: ""))
    alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

    guard alert.runModal() == .alertFirstButtonReturn else {
      Defaults[.encryptionEnabled] = true
      return
    }

    clearCredentials()
    wipeAllData()
    Defaults[.encryptionEnabled] = false
    isLocked = false
    Storage.shared.activatePlainRuntime()

    Task {
      try? await History.shared.load()
    }
  }

  func resetEncryptedVaultFromUI() {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = NSLocalizedString("ResetEncryptedVaultTitle", tableName: "StorageSettings", comment: "")
    alert.informativeText = NSLocalizedString("ResetEncryptedVaultBody", tableName: "StorageSettings", comment: "")
    alert.addButton(withTitle: NSLocalizedString("ResetEncryptedVaultConfirm", tableName: "StorageSettings", comment: ""))
    alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

    guard alert.runModal() == .alertFirstButtonReturn else { return }

    wipeAllData()
    lock(reason: .manual)
  }

  func unlockWithPrompt() {
    let title = NSLocalizedString("VaultUnlockTitle", tableName: "StorageSettings", comment: "")
    let defaultMessage = NSLocalizedString("VaultUnlockBody", tableName: "StorageSettings", comment: "")
    let failedMessage = NSLocalizedString("VaultStatusUnlockFailed", tableName: "StorageSettings", comment: "")
    var informativeText = defaultMessage

    while true {
      guard let password = promptForPassword(title: title, informativeText: informativeText) else {
        return
      }

      if unlock(password: password) {
        return
      }

      informativeText = "\(failedMessage)\n\n\(defaultMessage)"
    }
  }

  @discardableResult
  func changePassword(currentPassword: String, newPassword: String) async -> Bool {
    guard Defaults[.encryptionEnabled] else { return false }
    guard !newPassword.isEmpty else { return false }

    guard let currentKey = verifiedKey(for: currentPassword) else {
      statusText = NSLocalizedString("VaultStatusUnlockFailed", tableName: "StorageSettings", comment: "")
      return false
    }

    if Defaults[.syncEnabled] {
      _ = await waitForSyncIdle(maxWait: 5.0)
    }

    let wasLocked = isLocked
    runtimeKey = currentKey
    isLocked = false

    if wasLocked {
      loadRuntimeFromEncryptedVault()
    }

    if Defaults[.syncEnabled], let remoteSnapshot = try? await fetchRemoteSnapshot() {
      var mergedSnapshot = merge(local: buildLocalSnapshot(), remote: remoteSnapshot)
      resolveTagNameConflicts(&mergedSnapshot)
      applySnapshotToRuntime(mergedSnapshot)
    }

    let snapshot = buildLocalSnapshot()
    setPassword(newPassword)
    persistEncryptedVaultFromRuntime()

    var didUpdateCloudPassword = !Defaults[.syncEnabled]
    if Defaults[.syncEnabled] {
      do {
        let records = try buildCloudRecords(from: snapshot)
        try await cloudStore.save(records: records)
        Defaults[.cloudSyncStatus] = .healthy
        didUpdateCloudPassword = true
      } catch {
        let syncStatus = mapCloudError(error)
        Defaults[.cloudSyncStatus] = syncStatus
      }
    }

    statusText = didUpdateCloudPassword
      ? localizedStorageSettingsString(key: "VaultStatusPasswordChanged", fallback: "Encryption password updated.")
      : localizedStorageSettingsString(
          key: "VaultStatusPasswordChangedPendingSync",
          fallback: "Encryption password updated locally. iCloud sync will retry when it becomes available."
        )
    resetTimerLockIfNeeded()

    Task {
      try? await History.shared.load()
    }

    return true
  }

  @discardableResult
  func unlock(password: String) -> Bool {
    guard let key = verifiedKey(for: password) else {
      statusText = NSLocalizedString("VaultStatusUnlockFailed", tableName: "StorageSettings", comment: "")
      return false
    }

    runtimeKey = key
    isLocked = false
    statusText = NSLocalizedString("VaultStatusUnlocked", tableName: "StorageSettings", comment: "")

    if Defaults[.encryptionEnabled] {
      Storage.shared.activateEncryptedRuntime()
      loadRuntimeFromEncryptedVault()
    }

    Task {
      try? await History.shared.load()
    }

    resetTimerLockIfNeeded()
    return true
  }

  func lock(reason: LockReason) {
    guard Defaults[.encryptionEnabled] else { return }

    persistEncryptedVaultFromRuntime()
    runtimeKey = nil
    isLocked = true
    lockTimerTask?.cancel()
    lockTimerTask = nil
    Storage.shared.clearRuntimeHistory()
    statusText = NSLocalizedString("VaultStatusLocked", tableName: "StorageSettings", comment: "")

    Task {
      try? await History.shared.load()
    }

    if reason != .strictAction {
      Notifier.notify(body: NSLocalizedString("VaultLockedMessage", tableName: "StorageSettings", comment: ""), sound: nil)
    }
  }

  func recordDeletedItem(id: UUID, updatedAt: Date = .now) {
    recordDeletedItems(ids: [id], updatedAt: updatedAt)
  }

  func recordDeletedTag(id: UUID, updatedAt: Date = .now) {
    recordDeletedTags(ids: [id], updatedAt: updatedAt)
  }

  func recordDeletedItems(ids: [UUID], updatedAt: Date = .now) {
    guard !ids.isEmpty else { return }
    for id in ids {
      itemTombstones[id] = updatedAt
    }
    persistTombstones()
    markLocalMutation(reason: "item-tombstones")
  }

  func recordDeletedTags(ids: [UUID], updatedAt: Date = .now) {
    guard !ids.isEmpty else { return }
    for id in ids {
      tagTombstones[id] = updatedAt
    }
    persistTombstones()
    markLocalMutation(reason: "tag-tombstones")
  }

  func persistEncryptedVaultFromRuntime() {
    guard Defaults[.encryptionEnabled], let key = runtimeKey else { return }

    let snapshot = buildLocalSnapshot()
    let context = Storage.shared.encryptedContext

    let oldItems = (try? context.fetch(FetchDescriptor<EncryptedHistoryItemRecord>())) ?? []
    let oldTags = (try? context.fetch(FetchDescriptor<EncryptedHistoryTagRecord>())) ?? []

    let wantedItemIDs = Set(snapshot.items.keys)
    let wantedTagIDs = Set(snapshot.tags.keys)

    for old in oldItems where !wantedItemIDs.contains(old.id) {
      context.delete(old)
    }
    for old in oldTags where !wantedTagIDs.contains(old.id) {
      context.delete(old)
    }

    for item in snapshot.items.values {
      guard let data = try? JSONEncoder().encode(item),
            let sealed = try? encrypt(data, with: key) else { continue }
      if let existing = oldItems.first(where: { $0.id == item.id }) {
        existing.blob = sealed
      } else {
        context.insert(EncryptedHistoryItemRecord(id: item.id, blob: sealed))
      }
    }

    for tag in snapshot.tags.values {
      guard let data = try? JSONEncoder().encode(tag),
            let sealed = try? encrypt(data, with: key) else { continue }
      if let existing = oldTags.first(where: { $0.id == tag.id }) {
        existing.blob = sealed
      } else {
        context.insert(EncryptedHistoryTagRecord(id: tag.id, blob: sealed))
      }
    }

    context.processPendingChanges()
    try? context.save()
  }

  func reconcileAndSync(trigger: String) async {
    await requestSync(trigger: trigger, coalesceMutationBurst: false)
  }

  func requestSync(trigger: String, coalesceMutationBurst: Bool = false) async {
    guard Defaults[.syncEnabled] else { return }

    pendingTriggers.insert(trigger)
    needsAnotherPass = true

    if coalesceMutationBurst {
      coalescedTriggerCount += 1
      logger.debug("Queued coalesced sync trigger='\(trigger)' count=\(coalescedTriggerCount)")
    }

    guard syncTask == nil else { return }

    syncTask = Task { [weak self] in
      await self?.drainSyncPasses(initialCoalesce: coalesceMutationBurst)
    }
  }

  private func drainSyncPasses(initialCoalesce: Bool) async {
    isSyncInProgress = true
    defer {
      isSyncInProgress = false
      syncTask = nil
      if !Task.isCancelled, needsAnotherPass, Defaults[.syncEnabled] {
        Task { [weak self] in
          await self?.requestSync(trigger: "rerun", coalesceMutationBurst: false)
        }
      }
    }

    guard Defaults[.syncEnabled] else { return }
    guard !Defaults[.encryptionEnabled] || !isLocked else { return }

    var shouldCoalesce = initialCoalesce
    var passIndex = 0
    var stalePassCount = 0

    while !Task.isCancelled && (needsAnotherPass || !pendingTriggers.isEmpty) {
      guard Defaults[.syncEnabled] else { return }
      guard !Defaults[.encryptionEnabled] || !isLocked else { return }

      if shouldCoalesce {
        try? await Task.sleep(for: .milliseconds(250))
      }

      shouldCoalesce = false
      needsAnotherPass = false

      let triggers = pendingTriggers.sorted()
      pendingTriggers.removeAll()
      let trigger = triggers.isEmpty ? "unknown" : triggers.joined(separator: ",")

      passIndex += 1
      diagnosticsPassCount += 1
      let startedAt = Date.now
      let revisionAtPassStart = localMutationRevision
      logger.info(
        "Sync pass \(passIndex) start trigger='\(trigger)' revision=\(revisionAtPassStart) coalescedTriggers=\(coalescedTriggerCount)"
      )

      let result = await runSyncPass(trigger: trigger, revisionAtPassStart: revisionAtPassStart)
      let durationMs = Int(Date.now.timeIntervalSince(startedAt) * 1_000)

      switch result {
      case .success:
        logger.info("Sync pass \(passIndex) end status=success durationMs=\(durationMs)")
      case .staleMutationDetected:
        stalePassCount += 1
        diagnosticsStalePassCount += 1
        needsAnotherPass = true
        logger.notice(
          "Sync pass \(passIndex) end status=stale durationMs=\(durationMs) revisionNow=\(localMutationRevision)"
        )
      case .skipped:
        logger.notice("Sync pass \(passIndex) end status=skipped durationMs=\(durationMs)")
        return
      }
    }

    if stalePassCount > 0 {
      logger.notice("Sync drain completed with stalePasses=\(stalePassCount)")
    }
    coalescedTriggerCount = 0
  }

  func waitForSyncIdle(maxWait seconds: TimeInterval = 5.0) async -> Bool {
    let deadline = Date.now.addingTimeInterval(seconds)
    while syncTask != nil || isSyncInProgress || needsAnotherPass || !pendingTriggers.isEmpty {
      if Date.now >= deadline {
        return false
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return true
  }

  private func runSyncPass(trigger: String, revisionAtPassStart: UInt64) async -> SyncPassResult {
    guard Defaults[.syncEnabled] else { return .skipped }
    guard !Defaults[.encryptionEnabled] || !isLocked else { return .skipped }

    do {
      try await hydrateLocalVaultCredentialsFromCloudIfNeeded()
      let local = buildLocalSnapshot()
      let remote = try await fetchRemoteSnapshot()
      var merged = merge(local: local, remote: remote)
      resolveTagNameConflicts(&merged)

      if revisionAtPassStart != localMutationRevision {
        logger.notice(
          "Skipping stale sync pass trigger='\(trigger)' revisionStart=\(revisionAtPassStart) revisionNow=\(localMutationRevision)"
        )
        return .staleMutationDetected
      }

      logger.debug("Applying merged snapshot items=\(merged.items.count) tags=\(merged.tags.count) trigger='\(trigger)'")
      applySnapshotToRuntime(merged)

      if Defaults[.encryptionEnabled] {
        persistEncryptedVaultFromRuntime()
      }

      try await cloudStore.save(records: try buildCloudRecords(from: merged))
      Defaults[.cloudSyncStatus] = .healthy
      statusText = NSLocalizedString("CloudSyncStatusHealthy", tableName: "StorageSettings", comment: "")

      Task {
        try? await History.shared.load()
      }
      return .success
    } catch {
      let syncStatus = mapCloudError(error)
      Defaults[.cloudSyncStatus] = syncStatus
      statusText = cloudErrorStatusText(syncStatus, error: error)
      logger.error("Cloud sync failed trigger='\(trigger)' \(self.describeCloudError(error))")
      return .success
    }
  }

  private func fetchRemoteSnapshot() async throws -> SyncSnapshot {
    let itemRecords = try await cloudStore.fetchItemRecords()
    let tagRecords = try await cloudStore.fetchTagRecords()

    var items: [UUID: HistoryItemSnapshot] = [:]
    var tags: [UUID: HistoryTagSnapshot] = [:]

    for record in itemRecords {
      guard let blob = record["blob"] as? Data else { continue }
      let encrypted = (record["encrypted"] as? NSNumber)?.boolValue ?? false
      guard let snapshot = decodeItem(blob: blob, encrypted: encrypted) else { continue }
      items[snapshot.id] = snapshot
    }

    for record in tagRecords {
      guard let blob = record["blob"] as? Data else { continue }
      let encrypted = (record["encrypted"] as? NSNumber)?.boolValue ?? false
      guard let snapshot = decodeTag(blob: blob, encrypted: encrypted) else { continue }
      tags[snapshot.id] = snapshot
    }

    return SyncSnapshot(items: items, tags: tags)
  }

  private func buildCloudRecords(from snapshot: SyncSnapshot) throws -> [CKRecord] {
    var records: [CKRecord] = []

    for item in snapshot.items.values {
      let (cloudValue, blob, encrypted) = try cloudRecordPayload(for: item)

      let recordID = CKRecord.ID(recordName: "item-\(cloudValue.id)", zoneID: zoneID)
      let record = CKRecord(recordType: "MaccyEncryptedItem", recordID: recordID)
      record["blob"] = blob as CKRecordValue
      record["encrypted"] = NSNumber(booleanLiteral: encrypted)
      records.append(record)
    }

    for tag in snapshot.tags.values {
      let recordID = CKRecord.ID(recordName: "tag-\(tag.id)", zoneID: zoneID)
      let record = CKRecord(recordType: "MaccyEncryptedTag", recordID: recordID)
      let payload = try JSONEncoder().encode(tag)
      let (blob, encrypted) = try encodeForCloud(payload)
      record["blob"] = blob as CKRecordValue
      record["encrypted"] = NSNumber(booleanLiteral: encrypted)
      records.append(record)
    }

    if let vaultRecord = buildVaultMetadataRecord() {
      records.append(vaultRecord)
    }

    return records
  }

  private func cloudRecordPayload(for item: HistoryItemSnapshot) throws -> (HistoryItemSnapshot, Data, Bool) {
    if item.shared && !item.isDeleted {
      let payload = try JSONEncoder().encode(item)
      let (blob, encrypted) = try encodeForCloud(payload)
      if blob.count <= maxCloudBlobBytes {
        return (item, blob, encrypted)
      }

      logger.warning("Skipping oversized cloud item id='\(item.id.uuidString)' bytes=\(blob.count)")
    }

    let tombstone = cloudTombstone(for: item)
    let payload = try JSONEncoder().encode(tombstone)
    let (blob, encrypted) = try encodeForCloud(payload)
    return (tombstone, blob, encrypted)
  }

  private func cloudTombstone(for item: HistoryItemSnapshot) -> HistoryItemSnapshot {
    HistoryItemSnapshot(
      id: item.id,
      application: nil,
      firstCopiedAt: item.firstCopiedAt,
      lastCopiedAt: item.lastCopiedAt,
      updatedAt: item.updatedAt,
      tagAssignmentUpdatedAt: item.tagAssignmentUpdatedAt,
      numberOfCopies: 0,
      pin: nil,
      tagID: nil,
      title: "",
      contents: [],
      isDeleted: true,
      shared: false
    )
  }

  private func buildLocalSnapshot() -> SyncSnapshot {
    var items: [UUID: HistoryItemSnapshot] = [:]
    var tags: [UUID: HistoryTagSnapshot] = [:]

    let modelItems = (try? Storage.shared.context.fetch(FetchDescriptor<HistoryItem>())) ?? []
    let modelTags = (try? Storage.shared.context.fetch(FetchDescriptor<HistoryTag>())) ?? []

    for tag in modelTags {
      tags[tag.id] = HistoryTagSnapshot(
        id: tag.id,
        name: tag.name,
        colorKey: tag.colorKey,
        createdAt: tag.createdAt,
        updatedAt: tag.updatedAt,
        isDeleted: false
      )
    }

    for (id, updatedAt) in tagTombstones {
      tags[id] = HistoryTagSnapshot(
        id: id,
        name: "",
        colorKey: ShelfTagColor.blue.rawValue,
        createdAt: updatedAt,
        updatedAt: updatedAt,
        isDeleted: true
      )
    }

    for item in modelItems {
      items[item.id] = HistoryItemSnapshot(
        id: item.id,
        application: item.application,
        firstCopiedAt: item.firstCopiedAt,
        lastCopiedAt: item.lastCopiedAt,
        updatedAt: item.updatedAt,
        tagAssignmentUpdatedAt: item.tagAssignmentUpdatedAt,
        numberOfCopies: item.numberOfCopies,
        pin: item.pin,
        tagID: item.tag?.id,
        title: item.title,
        contents: item.contents.map { HistoryContentSnapshot(type: $0.type, value: $0.value) },
        isDeleted: false,
        shared: isItemInScope(item)
      )
    }

    for (id, updatedAt) in itemTombstones {
      items[id] = HistoryItemSnapshot(
        id: id,
        application: nil,
        firstCopiedAt: updatedAt,
        lastCopiedAt: updatedAt,
        updatedAt: updatedAt,
        tagAssignmentUpdatedAt: updatedAt,
        numberOfCopies: 0,
        pin: nil,
        tagID: nil,
        title: "",
        contents: [],
        isDeleted: true,
        shared: false
      )
    }

    return SyncSnapshot(items: items, tags: tags)
  }

  private func merge(local: SyncSnapshot, remote: SyncSnapshot) -> SyncSnapshot {
    var tags = local.tags
    for (id, remoteTag) in remote.tags {
      if let localTag = tags[id] {
        if localTag.isDeleted || remoteTag.isDeleted {
          var deleted = localTag.isDeleted ? localTag : remoteTag
          deleted.isDeleted = true
          deleted.updatedAt = max(localTag.updatedAt, remoteTag.updatedAt)
          tags[id] = deleted
          continue
        }

        tags[id] = remoteTag.updatedAt > localTag.updatedAt ? remoteTag : localTag
      } else {
        tags[id] = remoteTag
      }
    }

    var items = local.items
    for (id, remoteItem) in remote.items {
      if let localItem = items[id] {
        if localItem.isDeleted || remoteItem.isDeleted {
          var deleted = localItem.isDeleted ? localItem : remoteItem
          deleted.isDeleted = true
          deleted.updatedAt = max(localItem.updatedAt, remoteItem.updatedAt)
          deleted.tagAssignmentUpdatedAt = max(localItem.tagAssignmentUpdatedAt, remoteItem.tagAssignmentUpdatedAt)
          deleted.application = nil
          deleted.numberOfCopies = 0
          deleted.pin = nil
          deleted.tagID = nil
          deleted.title = ""
          deleted.contents = []
          deleted.shared = false
          items[id] = deleted
          continue
        }

        var winner = localItem.updatedAt >= remoteItem.updatedAt ? localItem : remoteItem
        if localItem.tagAssignmentUpdatedAt > winner.tagAssignmentUpdatedAt {
          winner.tagID = localItem.tagID
          winner.tagAssignmentUpdatedAt = localItem.tagAssignmentUpdatedAt
        }
        if remoteItem.tagAssignmentUpdatedAt > winner.tagAssignmentUpdatedAt {
          winner.tagID = remoteItem.tagID
          winner.tagAssignmentUpdatedAt = remoteItem.tagAssignmentUpdatedAt
        }
        items[id] = winner
      } else {
        items[id] = remoteItem
      }
    }

    let deletedItemCount = items.values.filter(\.isDeleted).count
    let deletedTagCount = tags.values.filter(\.isDeleted).count
    logger.debug("Merged snapshot items=\(items.count) deletedItems=\(deletedItemCount) tags=\(tags.count) deletedTags=\(deletedTagCount)")

    return SyncSnapshot(items: items, tags: tags)
  }

  private func resolveTagNameConflicts(_ snapshot: inout SyncSnapshot) {
    let groups = Dictionary(grouping: snapshot.tags.values.filter { !$0.isDeleted }) {
      $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    for (_, grouped) in groups where grouped.count > 1 {
      guard let canonical = grouped.min(by: { lhs, rhs in
        if lhs.createdAt == rhs.createdAt {
          return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.createdAt < rhs.createdAt
      }) else {
        continue
      }

      for duplicate in grouped where duplicate.id != canonical.id {
        for (itemID, item) in snapshot.items where item.tagID == duplicate.id && !item.isDeleted {
          var updated = item
          updated.tagID = canonical.id
          updated.tagAssignmentUpdatedAt = max(updated.tagAssignmentUpdatedAt, Date.now)
          snapshot.items[itemID] = updated
        }

        var deleted = duplicate
        deleted.isDeleted = true
        deleted.updatedAt = max(deleted.updatedAt, Date.now)
        snapshot.tags[duplicate.id] = deleted
      }
    }
  }

  private func applySnapshotToRuntime(_ snapshot: SyncSnapshot) {
    let context = Storage.shared.context

    var tagsByID: [UUID: HistoryTag] = [:]
    let existingTags = (try? context.fetch(FetchDescriptor<HistoryTag>())) ?? []
    for tag in existingTags { tagsByID[tag.id] = tag }

    for tagSnapshot in snapshot.tags.values {
      if tagSnapshot.isDeleted {
        if let existing = tagsByID[tagSnapshot.id] {
          context.delete(existing)
        }
        tagTombstones[tagSnapshot.id] = tagSnapshot.updatedAt
        continue
      }

      let model = tagsByID[tagSnapshot.id] ?? HistoryTag(name: tagSnapshot.name, colorKey: tagSnapshot.colorKey)
      if tagsByID[tagSnapshot.id] == nil {
        model.id = tagSnapshot.id
        context.insert(model)
      }
      model.name = tagSnapshot.name
      model.colorKey = tagSnapshot.colorKey
      model.createdAt = tagSnapshot.createdAt
      model.updatedAt = tagSnapshot.updatedAt
      tagsByID[tagSnapshot.id] = model
      tagTombstones.removeValue(forKey: tagSnapshot.id)
    }

    var itemsByID: [UUID: HistoryItem] = [:]
    let existingItems = (try? context.fetch(FetchDescriptor<HistoryItem>())) ?? []
    for item in existingItems { itemsByID[item.id] = item }

    for itemSnapshot in snapshot.items.values {
      if itemSnapshot.isDeleted {
        if let existing = itemsByID[itemSnapshot.id] {
          context.delete(existing)
        }
        itemTombstones[itemSnapshot.id] = itemSnapshot.updatedAt
        continue
      }

      let model = itemsByID[itemSnapshot.id] ?? HistoryItem(contents: [])
      if itemsByID[itemSnapshot.id] == nil {
        model.id = itemSnapshot.id
        context.insert(model)
      }

      model.application = itemSnapshot.application
      model.firstCopiedAt = itemSnapshot.firstCopiedAt
      model.lastCopiedAt = itemSnapshot.lastCopiedAt
      model.updatedAt = itemSnapshot.updatedAt
      model.tagAssignmentUpdatedAt = itemSnapshot.tagAssignmentUpdatedAt
      model.numberOfCopies = itemSnapshot.numberOfCopies
      model.pin = itemSnapshot.pin
      model.title = itemSnapshot.title
      model.contents = itemSnapshot.contents.map { HistoryItemContent(type: $0.type, value: $0.value) }
      model.tag = itemSnapshot.tagID.flatMap { tagsByID[$0] }

      itemsByID[itemSnapshot.id] = model
      itemTombstones.removeValue(forKey: itemSnapshot.id)
    }

    context.processPendingChanges()
    try? context.save()
    persistTombstones()
  }

  private func migratePlainToEncryptedRuntime(password: String) {
    _ = password
    Storage.shared.activatePlainRuntime()
    let plainContext = Storage.shared.plainContext

    let plainItems = (try? plainContext.fetch(FetchDescriptor<HistoryItem>())) ?? []
    let plainTags = (try? plainContext.fetch(FetchDescriptor<HistoryTag>())) ?? []

    Storage.shared.activateEncryptedRuntime()
    let runtime = Storage.shared.context

    for tag in plainTags {
      let copy = HistoryTag(name: tag.name, colorKey: tag.colorKey)
      copy.id = tag.id
      copy.createdAt = tag.createdAt
      copy.updatedAt = tag.updatedAt
      runtime.insert(copy)
    }

    let runtimeTags = (try? runtime.fetch(FetchDescriptor<HistoryTag>())) ?? []
    let tagMap = Dictionary(uniqueKeysWithValues: runtimeTags.map { ($0.id, $0) })

    for item in plainItems {
      let copy = HistoryItem(contents: item.contents.map { HistoryItemContent(type: $0.type, value: $0.value) })
      copy.id = item.id
      copy.application = item.application
      copy.firstCopiedAt = item.firstCopiedAt
      copy.lastCopiedAt = item.lastCopiedAt
      copy.updatedAt = item.updatedAt
      copy.tagAssignmentUpdatedAt = item.tagAssignmentUpdatedAt
      copy.numberOfCopies = item.numberOfCopies
      copy.pin = item.pin
      copy.title = item.title
      copy.tag = item.tag.flatMap { tagMap[$0.id] }
      runtime.insert(copy)
    }

    runtime.processPendingChanges()
    try? runtime.save()

    runtimeKey = deriveKey(password: password, salt: Defaults[.encryptionSalt] ?? Data())
    persistEncryptedVaultFromRuntime()
    Storage.shared.clearPlainHistory()
  }

  private func loadRuntimeFromEncryptedVault() {
    guard let key = runtimeKey else { return }

    Storage.shared.clearRuntimeHistory()
    let itemRecords = (try? Storage.shared.encryptedContext.fetch(FetchDescriptor<EncryptedHistoryItemRecord>())) ?? []
    let tagRecords = (try? Storage.shared.encryptedContext.fetch(FetchDescriptor<EncryptedHistoryTagRecord>())) ?? []

    var snapshot = SyncSnapshot(items: [:], tags: [:])

    for tagRecord in tagRecords {
      guard let decrypted = try? decrypt(tagRecord.blob, with: key),
            let snapshotTag = try? JSONDecoder().decode(HistoryTagSnapshot.self, from: decrypted) else {
        continue
      }
      snapshot.tags[snapshotTag.id] = snapshotTag
    }

    for itemRecord in itemRecords {
      guard let decrypted = try? decrypt(itemRecord.blob, with: key),
            let snapshotItem = try? JSONDecoder().decode(HistoryItemSnapshot.self, from: decrypted) else {
        continue
      }
      snapshot.items[snapshotItem.id] = snapshotItem
    }

    applySnapshotToRuntime(snapshot)
  }

  private func wipeAllData() {
    Storage.shared.clearEncryptedHistory()
    Storage.shared.clearRuntimeHistory()
    Storage.shared.clearPlainHistory()
    itemTombstones.removeAll()
    tagTombstones.removeAll()
    persistTombstones()
    Defaults[.syncEnabled] = false
  }

  private func isItemInScope(_ item: HistoryItem) -> Bool {
    switch Defaults[.syncScope] {
    case .all:
      return true
    case .pinnedOnly:
      return item.pin != nil
    case .textOnly:
      return item.text != nil || item.rtfData != nil || item.htmlData != nil
    }
  }

  private func mapCloudError(_ error: Error) -> CloudSyncStatus {
    if error is CloudStoreUnavailableError {
      return .unavailable
    }

    if let ck = extractCloudError(error) {
      switch ck.code {
      case .notAuthenticated: return .authRequired
      case .quotaExceeded: return .quotaExceeded
      case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
        return .unavailable
      default: return .error
      }
    }
    return .error
  }

  private func cloudErrorStatusText(_ status: CloudSyncStatus, error: Error) -> String {
    guard status == .error, let ckError = extractCloudError(error) else {
      return status.description
    }

    switch ckError.code {
    case .badContainer, .missingEntitlement, .permissionFailure:
      return "iCloud setup issue (\(ckError.code)). Verify container and signing setup."
    default:
      return "\(status.description) (\(ckError.code))"
    }
  }

  private func extractCloudError(_ error: Error) -> CKError? {
    if let ckError = error as? CKError {
      if ckError.code == .partialFailure,
         let partialErrors = (ckError as NSError).userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Any] {
        for value in partialErrors.values {
          if let nestedError = value as? Error,
             let nestedCloudError = extractCloudError(nestedError) {
            return nestedCloudError
          }
        }
      }
      return ckError
    }

    let nsError = error as NSError
    if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
      return extractCloudError(underlyingError)
    }

    if let partialErrors = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Any] {
      for value in partialErrors.values {
        if let nestedError = value as? Error,
           let ckError = extractCloudError(nestedError) {
          return ckError
        }
      }
    }

    return nil
  }

  private func describeCloudError(_ error: Error) -> String {
    if let ckError = extractCloudError(error) {
      let nsError = ckError as NSError
      return "code=\(ckError.code) domain=\(nsError.domain) message=\(nsError.localizedDescription)"
    }

    let nsError = error as NSError
    return "domain=\(nsError.domain) code=\(nsError.code) message=\(nsError.localizedDescription)"
  }

  private func buildVaultMetadataRecord() -> CKRecord? {
    guard Defaults[.encryptionEnabled],
          let salt = Defaults[.encryptionSalt],
          let verifier = Defaults[.encryptionVerifier] else {
      return nil
    }

    let recordID = CKRecord.ID(recordName: vaultMetadataRecordName, zoneID: zoneID)
    let record = CKRecord(recordType: vaultMetadataType, recordID: recordID)
    record["salt"] = salt as CKRecordValue
    record["verifier"] = verifier as CKRecordValue
    record["vaultVersion"] = NSNumber(value: Defaults[.encryptedVaultVersion])
    return record
  }

  private func hydrateLocalVaultCredentialsFromCloudIfNeeded() async throws {
    let isConfigured = Defaults[.encryptionSalt] != nil && Defaults[.encryptionVerifier] != nil
    guard !isConfigured else { return }

    guard let record = try await cloudStore.fetchVaultMetadataRecord(),
          let salt = record["salt"] as? Data,
          let verifier = record["verifier"] as? Data else {
      return
    }

    Defaults[.encryptionSalt] = salt
    Defaults[.encryptionVerifier] = verifier
  }

  private func resolveBootstrapCredentials() async {
    if Defaults[.syncEnabled] {
      try? await hydrateLocalVaultCredentialsFromCloudIfNeeded()
    }

    if Defaults[.encryptionSalt] == nil || Defaults[.encryptionVerifier] == nil {
      guard let password = promptForNewPassword() else {
        Defaults[.encryptionEnabled] = false
        isLocked = false
        Storage.shared.activatePlainRuntime()
        return
      }
      setPassword(password)
      _ = unlock(password: password)
      return
    }

    unlockWithPrompt()
  }

  private func enableEncryptionFlowFromUI() async {
    if Defaults[.syncEnabled] {
      try? await hydrateLocalVaultCredentialsFromCloudIfNeeded()
    }

    let isConfigured = Defaults[.encryptionSalt] != nil && Defaults[.encryptionVerifier] != nil
    if isConfigured {
      Defaults[.encryptionEnabled] = true
      Storage.shared.activateEncryptedRuntime()
      isLocked = true
      unlockWithPrompt()
      return
    }

    guard let password = promptForNewPassword() else {
      Defaults[.encryptionEnabled] = false
      return
    }

    setPassword(password)
    migratePlainToEncryptedRuntime(password: password)
    Defaults[.encryptionEnabled] = true
    _ = unlock(password: password)
  }

  private func changePasswordFlowFromUI() async {
    let verifyTitle = localizedStorageSettingsString(
      key: "VaultChangeVerifyTitle",
      fallback: "Verify Current Password"
    )
    let verifyBody = localizedStorageSettingsString(
      key: "VaultChangeVerifyBody",
      fallback: "Enter your current encryption password before setting a new one."
    )
    let failedMessage = NSLocalizedString("VaultStatusUnlockFailed", tableName: "StorageSettings", comment: "")
    var verifyMessage = verifyBody
    var currentPassword: String?

    while currentPassword == nil {
      guard let candidate = promptForPassword(title: verifyTitle, informativeText: verifyMessage) else {
        return
      }

      guard verifiedKey(for: candidate) != nil else {
        verifyMessage = "\(failedMessage)\n\n\(verifyBody)"
        continue
      }

      currentPassword = candidate
    }

    guard let currentPassword else { return }

    guard let newPassword = promptForNewPassword(
      title: localizedStorageSettingsString(
        key: "VaultChangeTitle",
        fallback: "Change Encryption Password"
      ),
      informativeText: localizedStorageSettingsString(
        key: "VaultChangeBody",
        fallback: "Set a new password used to encrypt clipboard history on disk and in iCloud sync."
      ),
      actionTitle: localizedStorageSettingsString(
        key: "ChangePassword",
        fallback: "Change password"
      ),
      mismatchMessage: localizedStorageSettingsString(
        key: "VaultPasswordChangeMismatch",
        fallback: "New passwords did not match. The password was not changed."
      )
    ) else {
      return
    }

    _ = await changePassword(currentPassword: currentPassword, newPassword: newPassword)
  }

  private func encodeForCloud(_ data: Data) throws -> (Data, Bool) {
    if Defaults[.encryptionEnabled], let key = runtimeKey {
      return (try encrypt(data, with: key), true)
    }
    return (data, false)
  }

  private func decodeItem(blob: Data, encrypted: Bool) -> HistoryItemSnapshot? {
    let raw: Data
    if encrypted {
      guard let key = runtimeKey,
            let decrypted = try? decrypt(blob, with: key) else { return nil }
      raw = decrypted
    } else {
      raw = blob
    }
    return try? JSONDecoder().decode(HistoryItemSnapshot.self, from: raw)
  }

  private func decodeTag(blob: Data, encrypted: Bool) -> HistoryTagSnapshot? {
    let raw: Data
    if encrypted {
      guard let key = runtimeKey,
            let decrypted = try? decrypt(blob, with: key) else { return nil }
      raw = decrypted
    } else {
      raw = blob
    }
    return try? JSONDecoder().decode(HistoryTagSnapshot.self, from: raw)
  }

  private func setPassword(_ password: String) {
    let salt = Data.secureRandom(count: 16)
    let key = deriveKey(password: password, salt: salt)
    let verifier = (try? encrypt(Self.verifierData, with: key)) ?? Data()
    Defaults[.encryptionSalt] = salt
    Defaults[.encryptionVerifier] = verifier
    runtimeKey = key
  }

  private func clearCredentials() {
    Defaults[.encryptionSalt] = nil
    Defaults[.encryptionVerifier] = nil
    runtimeKey = nil
  }

  private func resetTimerLockIfNeeded() {
    lockTimerTask?.cancel()
    lockTimerTask = nil

    guard Defaults[.encryptionEnabled], !isLocked else { return }
    guard Defaults[.unlockPolicy] == .timer else { return }

    let timeout = max(1, Defaults[.unlockTimeoutMinutes])
    lockTimerTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Double(timeout * 60)))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self?.lock(reason: .timer)
      }
    }
  }

  private static let verifierData = Data("maccy-vault-verifier-v1".utf8)

  private static func canInitializeCloudKitStore() -> Bool {
    #if DEBUG
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
      return false
    }
    #endif

    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    let appIdentifier = SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil)
    let iCloudContainers = SecTaskCopyValueForEntitlement(
      task,
      "com.apple.developer.icloud-container-identifiers" as CFString,
      nil
    )

    let hasAppIdentifier = (appIdentifier as? String)?.isEmpty == false
    let hasContainers = (iCloudContainers as? [String])?.isEmpty == false
    return hasAppIdentifier && hasContainers
  }

  private func deriveKey(password: String, salt: Data) -> SymmetricKey {
    var data = salt + Data(password.utf8)
    for _ in 0..<100_000 {
      data = Data(SHA256.hash(data: data))
    }
    return SymmetricKey(data: data)
  }

  private func encrypt(_ data: Data, with key: SymmetricKey) throws -> Data {
    let box = try AES.GCM.seal(data, using: key)
    guard let combined = box.combined else {
      throw NSError(domain: "MaccyEncryption", code: -1)
    }
    return combined
  }

  private func decrypt(_ data: Data, with key: SymmetricKey) throws -> Data {
    let box = try AES.GCM.SealedBox(combined: data)
    return try AES.GCM.open(box, using: key)
  }

  private func verifiedKey(for password: String) -> SymmetricKey? {
    guard let salt = Defaults[.encryptionSalt],
          let verifier = Defaults[.encryptionVerifier] else {
      return nil
    }

    let key = deriveKey(password: password, salt: salt)
    guard let decrypted = try? decrypt(verifier, with: key), decrypted == Self.verifierData else {
      return nil
    }

    return key
  }

  private func localizedStorageSettingsString(key: String, fallback: String) -> String {
    Bundle.main.localizedString(forKey: key, value: fallback, table: "StorageSettings")
  }

  private func promptForPassword(title: String, informativeText: String, actionTitle: String? = nil) -> String? {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = title
    alert.informativeText = informativeText

    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    alert.accessoryView = field
    alert.addButton(withTitle: actionTitle ?? NSLocalizedString("Unlock", tableName: "StorageSettings", comment: ""))
    alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func promptForNewPassword(
    title: String = NSLocalizedString("VaultCreateTitle", tableName: "StorageSettings", comment: ""),
    informativeText: String = NSLocalizedString("VaultCreateBody", tableName: "StorageSettings", comment: ""),
    actionTitle: String = NSLocalizedString("SetPassword", tableName: "StorageSettings", comment: ""),
    mismatchMessage: String = NSLocalizedString("VaultPasswordMismatch", tableName: "StorageSettings", comment: "")
  ) -> String? {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = title
    alert.informativeText = informativeText

    let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    password.placeholderString = NSLocalizedString("VaultPasswordLabel", tableName: "StorageSettings", comment: "")
    let confirm = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    confirm.placeholderString = NSLocalizedString("VaultPasswordConfirmLabel", tableName: "StorageSettings", comment: "")

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.distribution = .fill
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.addArrangedSubview(password)
    stack.addArrangedSubview(confirm)

    let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
    accessory.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
      stack.topAnchor.constraint(equalTo: accessory.topAnchor),
      stack.bottomAnchor.constraint(equalTo: accessory.bottomAnchor)
    ])

    alert.accessoryView = accessory
    alert.addButton(withTitle: actionTitle)
    alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

    guard alert.runModal() == .alertFirstButtonReturn else { return nil }

    let value = password.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let confirmation = confirm.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    guard value == confirmation else {
      Notifier.notify(body: mismatchMessage, sound: nil)
      return nil
    }
    return value
  }

  private func loadTombstones() {
    itemTombstones = decodeTombstones(data: Defaults[.syncItemTombstones])
    tagTombstones = decodeTombstones(data: Defaults[.syncTagTombstones])
  }

  private func persistTombstones() {
    Defaults[.syncItemTombstones] = encodeTombstones(itemTombstones)
    Defaults[.syncTagTombstones] = encodeTombstones(tagTombstones)
  }

  private func encodeTombstones(_ value: [UUID: Date]) -> Data? {
    let mapped = Dictionary(uniqueKeysWithValues: value.map { ($0.key.uuidString, $0.value) })
    return try? JSONEncoder().encode(mapped)
  }

  private func decodeTombstones(data: Data?) -> [UUID: Date] {
    guard let data,
          let mapped = try? JSONDecoder().decode([String: Date].self, from: data) else {
      return [:]
    }

    var result: [UUID: Date] = [:]
    for (id, date) in mapped {
      if let uuid = UUID(uuidString: id) {
        result[uuid] = date
      }
    }
    return result
  }
}

@MainActor
class Storage {
  static let shared = Storage()

  var container: ModelContainer { runtimeContainer }
  var context: ModelContext { runtimeContainer.mainContext }
  var plainContext: ModelContext { plainContainer.mainContext }
  var encryptedContext: ModelContext { encryptedContainer.mainContext }

  var size: String {
    let plainSize = (try? plainURL.resourceValues(forKeys: [.fileSizeKey]).allValues.first?.value as? Int64) ?? 0
    let encryptedSize = (try? encryptedURL.resourceValues(forKeys: [.fileSizeKey]).allValues.first?.value as? Int64) ?? 0
    let total = max(0, plainSize) + max(0, encryptedSize)
    guard total > 1 else { return "" }
    return ByteCountFormatter().string(fromByteCount: total)
  }

  private var runtimeContainer: ModelContainer
  private let plainContainer: ModelContainer
  private let encryptedContainer: ModelContainer

  private let plainURL = URL.applicationSupportDirectory.appending(path: "Maccy/Storage.sqlite")
  private let encryptedURL = URL.applicationSupportDirectory.appending(path: "Maccy/EncryptedStorage.sqlite")

  init() {
    try? FileManager.default.createDirectory(at: plainURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    #if DEBUG
    let isTesting = CommandLine.arguments.contains("enable-testing")
    #else
    let isTesting = false
    #endif

    var plainConfig = ModelConfiguration(url: plainURL, cloudKitDatabase: .none)
    var encryptedConfig = ModelConfiguration(url: encryptedURL, cloudKitDatabase: .none)

    #if DEBUG
    if isTesting {
      plainConfig = ModelConfiguration(nil, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
      encryptedConfig = ModelConfiguration(nil, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    }
    #endif

    plainContainer = Self.loadPlainContainer(config: plainConfig, recoverURL: isTesting ? nil : plainURL)
    encryptedContainer = Self.loadEncryptedContainer(config: encryptedConfig, recoverURL: isTesting ? nil : encryptedURL)
    runtimeContainer = plainContainer
  }

  func activateEncryptedRuntime() {
    let inMemory = ModelConfiguration(nil, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    if let container = try? ModelContainer(for: HistoryItem.self, HistoryTag.self, configurations: inMemory) {
      runtimeContainer = container
    }
  }

  func activatePlainRuntime() {
    runtimeContainer = plainContainer
  }

  func clearRuntimeHistory() {
    try? context.delete(model: HistoryItem.self)
    try? context.delete(model: HistoryTag.self)
    context.processPendingChanges()
    try? context.save()
  }

  func clearPlainHistory() {
    let context = plainContext
    try? context.delete(model: HistoryItem.self)
    try? context.delete(model: HistoryTag.self)
    context.processPendingChanges()
    try? context.save()
  }

  func clearEncryptedHistory() {
    let context = encryptedContext
    try? context.delete(model: EncryptedHistoryItemRecord.self)
    try? context.delete(model: EncryptedHistoryTagRecord.self)
    context.processPendingChanges()
    try? context.save()
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

  private static func loadEncryptedContainer(config: ModelConfiguration, recoverURL: URL?) -> ModelContainer {
    do {
      return try ModelContainer(
        for: EncryptedHistoryItemRecord.self,
        EncryptedHistoryTagRecord.self,
        configurations: config
      )
    } catch {
      guard let recoverURL else {
        return makeInMemoryEncryptedContainer(after: error)
      }

      quarantineStoreFiles(at: recoverURL, storeLabel: "encrypted", initialError: error)

      do {
        return try ModelContainer(
          for: EncryptedHistoryItemRecord.self,
          EncryptedHistoryTagRecord.self,
          configurations: config
        )
      } catch {
        return makeInMemoryEncryptedContainer(after: error)
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

  private static func makeInMemoryEncryptedContainer(after error: Error) -> ModelContainer {
    NSLog("[Maccy] Failed to load encrypted SwiftData store. Falling back to in-memory store. Error: \(error.localizedDescription)")
    do {
      return try ModelContainer(
        for: EncryptedHistoryItemRecord.self,
        EncryptedHistoryTagRecord.self,
        configurations: ModelConfiguration(nil, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
      )
    } catch {
      fatalError("Cannot load encrypted database: \(error.localizedDescription).")
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
      for candidate in storeSidecarURLs(for: storeURL) where fileManager.fileExists(atPath: candidate.path) {
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
      for candidate in storeSidecarURLs(for: storeURL) where fileManager.fileExists(atPath: candidate.path) {
        try? fileManager.removeItem(at: candidate)
      }
    }
  }

  private static func storeSidecarURLs(for storeURL: URL) -> [URL] {
    [
      storeURL,
      URL(fileURLWithPath: storeURL.path + "-wal"),
      URL(fileURLWithPath: storeURL.path + "-shm")
    ]
  }
}

private extension Data {
  static func secureRandom(count: Int) -> Data {
    var buffer = [UInt8](repeating: 0, count: count)
    if SecRandomCopyBytes(kSecRandomDefault, count, &buffer) == errSecSuccess {
      return Data(buffer)
    }
    return Data((0..<count).map { _ in UInt8.random(in: 0...255) })
  }
}
